import Foundation
import CoreLocation
import Combine

// =============================================================================
// MARK: - WeatherService
// -----------------------------------------------------------------------------
// ObservableObject the Weather Map + "Weather Near Me" card bind to. Backed by
// a pluggable `WeatherProviding` source (OpenWeatherMap today). Mirrors
// FreightRateService: auto-refresh, disk cache, offline-first, provider-
// agnostic UI.
//
// Tile overlays: OpenWeatherMap serves raster map layers (precip, wind, etc.)
// as standard {z}/{x}/{y} tiles. `tileURLTemplate(for:)` returns a template
// MapKit's MKTileOverlay consumes directly — no per-tile networking in Swift.
//
// API-key handling: the key is NEVER hard-coded in source. It is read at
// runtime from Config.Weather.openWeatherMapAPIKey, which resolves from the
// Info.plist key `OpenWeatherMapAPIKey` (populated by a build setting /
// xcconfig that is git-ignored). If no key is present, conditions degrade
// gracefully and the map shows the base map without overlays.
// =============================================================================

/// Pluggable weather source. Returns provider-agnostic snapshots and, for map
/// layers, a tile URL template. A future provider (Apple WeatherKit, a Supabase
/// proxy, etc.) implements this with no UI changes.
protocol WeatherProviding: Sendable {
    func fetchSnapshot(at coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot
    /// `{z}/{x}/{y}` template for a raster overlay layer, or nil if unsupported.
    func tileURLTemplate(for layer: WeatherLayer) -> String?
    var isConfigured: Bool { get }
}

enum WeatherServiceError: LocalizedError {
    case notConfigured
    case badResponse(Int)
    case decoding
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Weather API key is not configured."
        case .badResponse(let code): return "Weather service returned \(code)."
        case .decoding: return "Could not read the weather response."
        }
    }
}

@MainActor
final class WeatherService: ObservableObject {
    static let shared = WeatherService()

    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?

    /// Conditions refresh cadence (10 min). Tiles are refreshed by the map view
    /// reloading the overlay on the same cadence.
    static let refreshInterval: TimeInterval = 10 * 60

    private var provider: WeatherProviding
    private var refreshTask: Task<Void, Never>?
    private var hydrated = false

    init(provider: WeatherProviding = OpenWeatherMapProvider()) {
        self.provider = provider
    }

    var isConfigured: Bool { provider.isConfigured }

    func setProvider(_ newProvider: WeatherProviding) {
        provider = newProvider
    }

    func tileURLTemplate(for layer: WeatherLayer) -> String? {
        provider.tileURLTemplate(for: layer)
    }

    func hydrateFromCacheIfNeeded() async {
        guard !hydrated else { return }
        hydrated = true
        if let cached = await MapCacheStore.shared.load(WeatherSnapshot.self,
                                                        key: MapCacheKey.weatherSnapshot) {
            snapshot = cached
            lastUpdated = cached.capturedAt
        }
    }

    func startAutoRefresh(at coordinateProvider: @escaping () -> CLLocationCoordinate2D?) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.hydrateFromCacheIfNeeded()
            if let c = coordinateProvider() { await self.refresh(at: c) }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
                if Task.isCancelled { break }
                if let c = coordinateProvider() { await self.refresh(at: c) }
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh(at coordinate: CLLocationCoordinate2D, force: Bool = false) async {
        if !force, let last = lastUpdated,
           let snap = snapshot,
           snap.nearestCoordinateMatches(coordinate),
           Date().timeIntervalSince(last) < 60 {
            return
        }
        isLoading = true
        lastError = nil
        do {
            let fresh = try await provider.fetchSnapshot(at: coordinate)
            snapshot = fresh
            lastUpdated = fresh.capturedAt
            await MapCacheStore.shared.save(fresh, key: MapCacheKey.weatherSnapshot)
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }
}

// =============================================================================
// MARK: - OpenWeatherMapProvider
// -----------------------------------------------------------------------------
// Concrete provider using OpenWeatherMap:
//   * Current conditions: /data/2.5/weather (free tier).
//   * Alerts: /data/3.0/onecall (One Call 3.0; `alerts` array). If the key is
//     not subscribed to One Call, alerts are simply omitted — conditions still
//     work, and the provider-side NWS alerts can be added later.
//   * Tiles: https://tile.openweathermap.org/map/{layer}/{z}/{x}/{y}.png?appid=KEY
// =============================================================================

struct OpenWeatherMapProvider: WeatherProviding {

    private var apiKey: String { Config.Weather.openWeatherMapAPIKey }

    var isConfigured: Bool { !apiKey.isEmpty }

    func tileURLTemplate(for layer: WeatherLayer) -> String? {
        guard isConfigured else { return nil }
        return "https://tile.openweathermap.org/map/\(layer.rawValue)/{z}/{x}/{y}.png?appid=\(apiKey)"
    }

    func fetchSnapshot(at coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot {
        guard isConfigured else { throw WeatherServiceError.notConfigured }

        async let conditions = fetchCurrent(at: coordinate)
        async let alerts = fetchAlerts(at: coordinate)

        let c = try await conditions
        let a = (try? await alerts) ?? []
        return WeatherSnapshot(conditions: c, alerts: a, capturedAt: Date())
    }

    // MARK: Current conditions — /data/2.5/weather
    private func fetchCurrent(at coordinate: CLLocationCoordinate2D) async throws -> WeatherConditions {
        var comps = URLComponents(string: "https://api.openweathermap.org/data/2.5/weather")!
        comps.queryItems = [
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(coordinate.longitude)),
            URLQueryItem(name: "units", value: "imperial"),
            URLQueryItem(name: "appid", value: apiKey)
        ]
        let data: Data
        do {
            data = try await ReliableHTTPClient.shared.data(for: URLRequest(url: comps.url!))
        } catch ReliableHTTPError.httpStatus(let code) {
            throw WeatherServiceError.badResponse(code)
        }
        guard let dto = try? JSONDecoder().decode(OWMCurrentDTO.self, from: data) else {
            throw WeatherServiceError.decoding
        }
        return dto.toConditions(at: coordinate)
    }

    // MARK: Alerts — /data/3.0/onecall (optional subscription)
    private func fetchAlerts(at coordinate: CLLocationCoordinate2D) async throws -> [WeatherAlertEvent] {
        var comps = URLComponents(string: "https://api.openweathermap.org/data/3.0/onecall")!
        comps.queryItems = [
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(coordinate.longitude)),
            URLQueryItem(name: "exclude", value: "minutely,hourly,daily,current"),
            URLQueryItem(name: "units", value: "imperial"),
            URLQueryItem(name: "appid", value: apiKey)
        ]
        guard let data = try? await ReliableHTTPClient.shared.data(
            for: URLRequest(url: comps.url!)
        ) else {
            // One Call may be unsubscribed (401/429). Treat as "no alerts".
            return []
        }
        guard let dto = try? JSONDecoder().decode(OWMOneCallDTO.self, from: data) else {
            return []
        }
        return dto.alerts?.enumerated().map { idx, a in
            WeatherAlertEvent(
                id: "\(a.event)-\(a.start)-\(idx)",
                event: a.event,
                senderName: a.sender_name,
                start: Date(timeIntervalSince1970: a.start),
                end: Date(timeIntervalSince1970: a.end),
                description: a.description
            )
        } ?? []
    }
}

// =============================================================================
// MARK: - OpenWeatherMap DTOs (decode-only, never leak past the provider)
// =============================================================================

private struct OWMCurrentDTO: Decodable {
    struct Weather: Decodable { let id: Int; let main: String; let description: String }
    struct Main: Decodable { let temp: Double; let feels_like: Double; let humidity: Int }
    struct Wind: Decodable { let speed: Double; let deg: Double; let gust: Double? }
    let weather: [Weather]
    let main: Main
    let wind: Wind
    let visibility: Int?
    let name: String?

    func toConditions(at coordinate: CLLocationCoordinate2D) -> WeatherConditions {
        let first = weather.first
        let kind = OWMCurrentDTO.kind(fromCode: first?.id ?? 0, temperatureF: main.temp)
        // OWM visibility is in meters (max 10000). Convert to miles.
        let visMiles = Double(visibility ?? 10_000) / 1609.34
        return WeatherConditions(
            coordinate: CodableCoordinate(coordinate),
            placeName: (name?.isEmpty == false) ? name : nil,
            kind: kind,
            summary: (first?.description ?? "—").capitalizedFirst,
            temperatureF: main.temp,
            feelsLikeF: main.feels_like,
            windSpeedMph: wind.speed,
            windGustMph: wind.gust,
            windDirectionDegrees: wind.deg,
            visibilityMiles: visMiles,
            humidityPercent: main.humidity,
            capturedAt: Date()
        )
    }

    /// OWM condition code → normalized kind. Codes per OWM docs.
    static func kind(fromCode code: Int, temperatureF: Double) -> WeatherConditionKind {
        switch code {
        case 200...232: return .thunderstorm
        case 300...321: return .drizzle
        case 500...531: return .rain
        case 600...622: return .snow
        case 701, 711, 721, 741: return .fog
        case 731, 751, 761, 762: return .fog
        case 771, 781: return .wind
        case 800: return temperatureF >= 100 ? .extremeHeat : .clear
        case 801...804: return .clouds
        default: return temperatureF >= 100 ? .extremeHeat : .unknown
        }
    }
}

private struct OWMOneCallDTO: Decodable {
    struct Alert: Decodable {
        let sender_name: String?
        let event: String
        let start: TimeInterval
        let end: TimeInterval
        let description: String
    }
    let alerts: [Alert]?
}

private extension String {
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return String(f).uppercased() + dropFirst()
    }
}

// =============================================================================
// MARK: - Forecast fetching (One Call 3.0 → free 2.5 fallback)
// -----------------------------------------------------------------------------
// Preferred: /data/3.0/onecall (true hourly, 8-day daily, NWS alerts). If the
// key is not subscribed to One Call (HTTP 401/403), we silently fall back to
// the free endpoints: /data/2.5/forecast (5-day / 3-hour) whose entries become
// the "hourly" strip and are aggregated into daily min/max buckets, with severe
// conditions derived heuristically into the same WeatherAlertEvent model.
// =============================================================================

extension OpenWeatherMapProvider {

    func fetchForecast(at coordinate: CLLocationCoordinate2D) async throws -> WeatherForecast {
        guard isConfigured else { throw WeatherServiceError.notConfigured }
        do {
            return try await fetchOneCallForecast(at: coordinate)
        } catch WeatherServiceError.badResponse(let code) where code == 401 || code == 403 {
            // Key not subscribed to One Call 3.0 — degrade to the free tier.
            return try await fetchLegacyForecast(at: coordinate)
        }
    }

    // MARK: One Call 3.0 — /data/3.0/onecall
    private func fetchOneCallForecast(at coordinate: CLLocationCoordinate2D) async throws -> WeatherForecast {
        var comps = URLComponents(string: "https://api.openweathermap.org/data/3.0/onecall")!
        comps.queryItems = [
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(coordinate.longitude)),
            URLQueryItem(name: "exclude", value: "minutely,current"),
            URLQueryItem(name: "units", value: "imperial"),
            URLQueryItem(name: "appid", value: Config.Weather.openWeatherMapAPIKey)
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WeatherServiceError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let dto = try? JSONDecoder().decode(OWMOneCallForecastDTO.self, from: data) else {
            throw WeatherServiceError.decoding
        }

        let hourly: [HourlyForecastPoint] = (dto.hourly ?? []).prefix(24).map { h in
            HourlyForecastPoint(
                date: Date(timeIntervalSince1970: h.dt),
                temperatureF: h.temp,
                kind: OWMCurrentDTO.kind(fromCode: h.weather.first?.id ?? 0, temperatureF: h.temp),
                precipProbability: min(max(h.pop ?? 0, 0), 1),
                windSpeedMph: h.wind_speed,
                windGustMph: h.wind_gust,
                visibilityMiles: h.visibility.map { Double($0) / 1609.34 }
            )
        }

        let daily: [DailyForecastPoint] = (dto.daily ?? []).prefix(8).map { d in
            DailyForecastPoint(
                date: Date(timeIntervalSince1970: d.dt),
                highF: d.temp.max,
                lowF: d.temp.min,
                kind: OWMCurrentDTO.kind(fromCode: d.weather.first?.id ?? 0, temperatureF: d.temp.max),
                precipProbability: min(max(d.pop ?? 0, 0), 1),
                windSpeedMph: d.wind_speed
            )
        }

        let alerts: [WeatherAlertEvent] = dto.alerts?.enumerated().map { idx, a in
            WeatherAlertEvent(
                id: "\(a.event)-\(a.start)-\(idx)",
                event: a.event,
                senderName: a.sender_name,
                start: Date(timeIntervalSince1970: a.start),
                end: Date(timeIntervalSince1970: a.end),
                description: a.description
            )
        } ?? []

        return WeatherForecast(
            coordinate: CodableCoordinate(coordinate),
            placeName: nil,
            hourly: hourly,
            daily: daily,
            alerts: alerts,
            source: .oneCall,
            capturedAt: Date()
        )
    }

    // MARK: Free fallback — /data/2.5/forecast (5-day / 3-hour)
    private func fetchLegacyForecast(at coordinate: CLLocationCoordinate2D) async throws -> WeatherForecast {
        var comps = URLComponents(string: "https://api.openweathermap.org/data/2.5/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(coordinate.longitude)),
            URLQueryItem(name: "units", value: "imperial"),
            URLQueryItem(name: "appid", value: Config.Weather.openWeatherMapAPIKey)
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WeatherServiceError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let dto = try? JSONDecoder().decode(OWMForecast5DTO.self, from: data) else {
            throw WeatherServiceError.decoding
        }

        // 3-hourly entries double as the hourly strip (next ~24h = 9 entries).
        let hourly: [HourlyForecastPoint] = dto.list.prefix(9).map { e in
            HourlyForecastPoint(
                date: Date(timeIntervalSince1970: e.dt),
                temperatureF: e.main.temp,
                kind: OWMCurrentDTO.kind(fromCode: e.weather.first?.id ?? 0, temperatureF: e.main.temp),
                precipProbability: min(max(e.pop ?? 0, 0), 1),
                windSpeedMph: e.wind.speed,
                windGustMph: e.wind.gust,
                visibilityMiles: e.visibility.map { Double($0) / 1609.34 }
            )
        }

        // Aggregate the 3-hourly entries into daily min/max/condition buckets.
        var byDay: [Date: [OWMForecast5DTO.Entry]] = [:]
        let calendar = Calendar.current
        for entry in dto.list {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: entry.dt))
            byDay[day, default: []].append(entry)
        }
        let daily: [DailyForecastPoint] = byDay.keys.sorted().compactMap { day in
            guard let items = byDay[day], !items.isEmpty else { return nil }
            let high = items.map { $0.main.temp_max }.max() ?? 0
            let low = items.map { $0.main.temp_min }.min() ?? 0
            let worst = items
                .map { OWMCurrentDTO.kind(fromCode: $0.weather.first?.id ?? 0, temperatureF: $0.main.temp) }
                .max(by: { $0.hazardRank < $1.hazardRank }) ?? .unknown
            return DailyForecastPoint(
                date: day,
                highF: high,
                lowF: low,
                kind: worst,
                precipProbability: min(max(items.compactMap { $0.pop }.max() ?? 0, 0), 1),
                windSpeedMph: items.map { $0.wind.speed }.max() ?? 0
            )
        }

        return WeatherForecast(
            coordinate: CodableCoordinate(coordinate),
            placeName: dto.city?.name,
            hourly: hourly,
            daily: daily,
            alerts: Self.deriveSevereAlerts(from: Array(dto.list.prefix(8))),
            source: .legacy,
            capturedAt: Date()
        )
    }

    /// Heuristic severe alerts for the 2.5 fallback (no provider `alerts`):
    /// wind ≥ 40 mph, thunderstorm/tornado/blizzard/ice condition codes, or
    /// visibility under half a mile in the next ~24h.
    private static func deriveSevereAlerts(from entries: [OWMForecast5DTO.Entry]) -> [WeatherAlertEvent] {
        struct Window { var start: TimeInterval; var end: TimeInterval; var detail: String }
        var windows: [String: Window] = [:]

        func note(_ event: String, _ entry: OWMForecast5DTO.Entry, _ detail: String) {
            let end = entry.dt + 3 * 3600
            if var w = windows[event] {
                w.start = min(w.start, entry.dt)
                w.end = max(w.end, end)
                windows[event] = w
            } else {
                windows[event] = Window(start: entry.dt, end: end, detail: detail)
            }
        }

        for entry in entries {
            let gust = entry.wind.gust ?? entry.wind.speed
            if entry.wind.speed >= 40 || gust >= 40 {
                note("High Wind Warning", entry,
                     "Winds to \(Int(max(entry.wind.speed, gust))) mph expected. Dangerous for high-profile vehicles.")
            }
            let code = entry.weather.first?.id ?? 0
            switch code {
            case 200...232:
                note("Thunderstorm Warning", entry,
                     "Thunderstorms expected — lightning, downpours, and gusty winds possible.")
            case 781:
                note("Tornado Warning", entry, "Tornado conditions indicated. Seek shelter; do not drive through the area.")
            case 602, 622:
                note("Blizzard / Heavy Snow Warning", entry, "Heavy snow expected. Whiteout conditions possible.")
            case 611...616:
                note("Ice / Sleet Warning", entry, "Freezing precipitation expected — roads may ice over quickly.")
            default:
                break
            }
            if let vis = entry.visibility, Double(vis) / 1609.34 < 0.5 {
                note("Dense Fog Warning", entry, "Visibility under half a mile expected. Low beams; reduce speed.")
            }
        }

        return windows.map { event, w in
            WeatherAlertEvent(
                id: "derived-\(event)-\(Int(w.start))",
                event: event,
                senderName: nil,
                start: Date(timeIntervalSince1970: w.start),
                end: Date(timeIntervalSince1970: w.end),
                description: w.detail
            )
        }
        .sorted { $0.start < $1.start }
    }
}

// MARK: One Call 3.0 / 2.5 forecast DTOs (decode-only)

private struct OWMOneCallForecastDTO: Decodable {
    struct WeatherDesc: Decodable { let id: Int; let main: String; let description: String }
    struct Hourly: Decodable {
        let dt: TimeInterval
        let temp: Double
        let wind_speed: Double
        let wind_gust: Double?
        let pop: Double?
        let visibility: Int?
        let weather: [WeatherDesc]
    }
    struct DailyTemp: Decodable { let min: Double; let max: Double }
    struct Daily: Decodable {
        let dt: TimeInterval
        let temp: DailyTemp
        let wind_speed: Double
        let pop: Double?
        let weather: [WeatherDesc]
    }
    struct Alert: Decodable {
        let sender_name: String?
        let event: String
        let start: TimeInterval
        let end: TimeInterval
        let description: String
    }
    let hourly: [Hourly]?
    let daily: [Daily]?
    let alerts: [Alert]?
}

private struct OWMForecast5DTO: Decodable {
    struct WeatherDesc: Decodable { let id: Int; let main: String; let description: String }
    struct Main: Decodable { let temp: Double; let temp_min: Double; let temp_max: Double }
    struct Wind: Decodable { let speed: Double; let gust: Double? }
    struct City: Decodable { let name: String? }
    struct Entry: Decodable {
        let dt: TimeInterval
        let main: Main
        let weather: [WeatherDesc]
        let wind: Wind
        let pop: Double?
        let visibility: Int?
    }
    let list: [Entry]
    let city: City?
}

/// Ordering used to pick the "worst" condition when aggregating 3-hourly
/// entries into a daily bucket and when summarizing route segments.
private extension WeatherConditionKind {
    var hazardRank: Int {
        switch self {
        case .thunderstorm: return 7
        case .snow:         return 6
        case .fog:          return 5
        case .rain:         return 4
        case .wind:         return 3
        case .drizzle:      return 2
        case .extremeHeat:  return 2
        case .clouds:       return 1
        case .clear, .unknown: return 0
        }
    }
}

// =============================================================================
// MARK: - ForecastService
// -----------------------------------------------------------------------------
// Singleton the forecast panel, "Weather Near Me" card, severe banner, and
// RouteWeatherService all read. Caches per-coordinate forecasts (memory +
// MapCacheStore disk) with a 30-minute TTL, mirroring WeatherService's
// offline-first pattern. Missing API key → every call returns nil; no crashes.
// =============================================================================

@MainActor
final class ForecastService: ObservableObject {
    static let shared = ForecastService()

    /// Forecast for the truck's current position — drives the forecast panel,
    /// the dashboard card extras, and the severe banner.
    @Published private(set) var nearMeForecast: WeatherForecast?

    static let cacheTTL: TimeInterval = 30 * 60

    private let provider = OpenWeatherMapProvider()
    private var memoryCache: [String: WeatherForecast] = [:]

    var isConfigured: Bool { provider.isConfigured }

    /// Severe alerts active (or starting within 6h) at the truck's position.
    var activeSevereAlerts: [WeatherAlertEvent] {
        nearMeForecast?.activeAlerts ?? []
    }

    /// Coordinates are bucketed to ~0.25° (~17 mi) so nearby fixes share a
    /// cache entry and route sampling doesn't hammer the API.
    private static func cacheKey(for coordinate: CLLocationCoordinate2D) -> String {
        let lat = (coordinate.latitude * 4).rounded() / 4
        let lon = (coordinate.longitude * 4).rounded() / 4
        return "weather_forecast_v1_\(lat)_\(lon)"
    }

    /// Fetch (or serve from cache) the forecast for a coordinate. Nil-safe:
    /// returns nil when the key is missing or the network + cache both fail.
    func forecast(at coordinate: CLLocationCoordinate2D) async -> WeatherForecast? {
        guard provider.isConfigured else { return nil }
        let key = Self.cacheKey(for: coordinate)

        if let cached = memoryCache[key], cached.isFresh(ttl: Self.cacheTTL) {
            return cached
        }
        if let disk = await MapCacheStore.shared.load(WeatherForecast.self, key: key),
           disk.isFresh(ttl: Self.cacheTTL) {
            memoryCache[key] = disk
            return disk
        }

        guard let fresh = try? await provider.fetchForecast(at: coordinate) else {
            // Offline: a stale cache beats nothing.
            if let stale = memoryCache[key] { return stale }
            return await MapCacheStore.shared.load(WeatherForecast.self, key: key)
        }
        memoryCache[key] = fresh
        await MapCacheStore.shared.save(fresh, key: key)
        return fresh
    }

    /// Refresh the truck-position forecast and route any active severe alerts
    /// into the existing AlertEngine (dashboard badge + local notifications).
    func refreshNearMe(at coordinate: CLLocationCoordinate2D?) async {
        guard let coordinate, provider.isConfigured else { return }
        if let f = nearMeForecast, f.isFresh(ttl: Self.cacheTTL), f.coordinateMatches(coordinate) {
            return
        }
        guard let fresh = await forecast(at: coordinate) else { return }
        nearMeForecast = fresh
        let severe = fresh.activeAlerts
        if !severe.isEmpty {
            await AlertEngine.shared.ingestSevereWeather(severe, at: coordinate,
                                                         placeName: fresh.placeName)
        }
    }
}

// =============================================================================
// MARK: - Road-condition analysis
// -----------------------------------------------------------------------------
// Pure functions that turn hourly forecast points into RoadCondition warnings.
// Thresholds per the trucking spec: ice ≤ 34°F + precip, heavy rain ≥ 60% PoP,
// dense fog < 0.5 mi visibility, high wind ≥ 30 mph sustained (high-profile).
// =============================================================================

enum RoadConditionAnalyzer {

    /// Conditions over a window of hourly points (typically the next ~12h).
    static func conditions(in hourly: [HourlyForecastPoint]) -> [RoadCondition] {
        var found = Set<RoadCondition>()
        for h in hourly {
            let precipLikely = h.precipProbability >= 0.3 ||
                [.rain, .drizzle, .snow, .thunderstorm].contains(h.kind)
            if h.temperatureF <= 34, precipLikely {
                found.insert(.iceRisk)
            }
            if h.kind == .snow {
                found.insert(.snow)
            }
            if h.precipProbability >= 0.6, h.kind == .rain || h.kind == .thunderstorm {
                found.insert(.heavyRain)
            }
            if h.kind == .fog || (h.visibilityMiles ?? 10) < 0.5 {
                found.insert(.denseFog)
            }
            if h.windSpeedMph >= 30 || (h.windGustMph ?? 0) >= 40 {
                found.insert(.highWind)
            }
        }
        return found.sorted {
            ($0.severity, $0.riskWeight) > ($1.severity, $1.riskWeight)
        }
    }
}

extension RoadCondition {
    /// Contribution to the 0–100 route risk score (worst condition dominates).
    var riskWeight: Int {
        switch self {
        case .iceRisk:   return 75
        case .snow:      return 60
        case .denseFog:  return 60
        case .heavyRain: return 45
        case .highWind:  return 40
        }
    }
}

// =============================================================================
// MARK: - RouteWeatherService
// -----------------------------------------------------------------------------
// Samples 3–5 points along the straight line between origin and destination
// (or through supplied waypoints), pulls a forecast for each via
// ForecastService's cache, and condenses everything into a RouteWeatherRisk.
// Nil-safe end to end: missing key, failed geocode, or zero reachable
// forecasts all return nil so callers can hide the UI silently.
// =============================================================================

@MainActor
final class RouteWeatherService {
    static let shared = RouteWeatherService()
    private init() {}

    /// Assess a route between two coordinates (optionally via waypoints).
    func assessRoute(from origin: CLLocationCoordinate2D,
                     to destination: CLLocationCoordinate2D,
                     waypoints: [CLLocationCoordinate2D] = []) async -> RouteWeatherRisk? {
        guard Config.Weather.isConfigured else { return nil }

        let samples = Self.samplePoints(from: origin, to: destination, waypoints: waypoints)
        var segments: [RouteSegmentWeather] = []

        for point in samples {
            guard let forecast = await ForecastService.shared.forecast(at: point) else { continue }
            let window = Array(forecast.hourly.prefix(12))
            guard !window.isEmpty else { continue }

            let worst = window.max(by: { $0.kind.hazardRank < $1.kind.hazardRank }) ?? window[0]
            segments.append(RouteSegmentWeather(
                coordinate: CodableCoordinate(point),
                placeName: forecast.placeName,
                kind: worst.kind,
                temperatureF: worst.temperatureF,
                windSpeedMph: window.map { $0.windSpeedMph }.max() ?? 0,
                precipProbability: window.map { $0.precipProbability }.max() ?? 0,
                roadConditions: RoadConditionAnalyzer.conditions(in: window)
            ))
        }
        guard !segments.isEmpty else { return nil }

        let segmentScores = segments.map(Self.score(for:))
        let worstScore = segmentScores.max() ?? 0
        // Each additional hazardous segment nudges the score up — a route
        // that's bad the whole way is riskier than one bad spot.
        let extraHazards = segmentScores.filter { $0 >= 25 }.count
        let score = min(worstScore + max(0, extraHazards - 1) * 5, 100)

        let allConditions = segments.flatMap { $0.roadConditions }
        var seen = Set<RoadCondition>()
        let deduped = allConditions
            .sorted { ($0.severity, $0.riskWeight) > ($1.severity, $1.riskWeight) }
            .filter { seen.insert($0).inserted }

        return RouteWeatherRisk(
            score: score,
            level: RouteRiskLevel(score: score),
            segments: segments,
            roadConditions: deduped,
            worstSummary: Self.summary(for: segments, scores: segmentScores),
            capturedAt: Date()
        )
    }

    /// Convenience for screens that only have place strings (e.g. a Load's
    /// origin/destination). Geocodes both ends; nil on any failure.
    func assessRoute(fromPlace origin: String, toPlace destination: String) async -> RouteWeatherRisk? {
        guard Config.Weather.isConfigured else { return nil }
        // CLGeocoder prefers sequential requests — do not run these in parallel.
        guard let o = await Self.geocode(origin) else { return nil }
        guard let d = await Self.geocode(destination) else { return nil }
        return await assessRoute(from: o, to: d)
    }

    // MARK: Internals

    private static func geocode(_ place: String) async -> CLLocationCoordinate2D? {
        let trimmed = sanitizedPlace(place)
        guard !trimmed.isEmpty else { return nil }
        let placemarks = try? await CLGeocoder().geocodeAddressString(trimmed)
        return placemarks?.first?.location?.coordinate
    }

    /// Load origin/destination strings often carry rate-con labels like
    /// "Pickup Dallas, TX" or "Delivery: El Paso, TX" that break CLGeocoder.
    /// Strip a single leading label word (with optional colon) before lookup.
    static func sanitizedPlace(_ place: String) -> String {
        var trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = ["pickup", "pick up", "delivery", "deliver to", "deliver",
                      "drop off", "dropoff", "drop", "origin", "destination",
                      "dest", "from", "to"]
        let lower = trimmed.lowercased()
        for label in labels {
            for suffix in [": ", ":", " "] {
                let prefix = label + suffix
                if lower.hasPrefix(prefix), trimmed.count > prefix.count {
                    trimmed = String(trimmed.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed
                }
            }
        }
        return trimmed
    }

    /// 3–5 sample points: endpoints plus 1–3 interpolated interior points
    /// scaled by route length (or the caller's waypoints, capped at 3).
    static func samplePoints(from origin: CLLocationCoordinate2D,
                             to destination: CLLocationCoordinate2D,
                             waypoints: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var points = [origin]
        if waypoints.isEmpty {
            let meters = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
                .distance(from: CLLocation(latitude: destination.latitude,
                                           longitude: destination.longitude))
            let interior = meters < 200_000 ? 1 : (meters < 800_000 ? 2 : 3)
            for i in 1...interior {
                let t = Double(i) / Double(interior + 1)
                points.append(CLLocationCoordinate2D(
                    latitude: origin.latitude + (destination.latitude - origin.latitude) * t,
                    longitude: origin.longitude + (destination.longitude - origin.longitude) * t
                ))
            }
        } else {
            points.append(contentsOf: waypoints.prefix(3))
        }
        points.append(destination)
        return points
    }

    private static func score(for segment: RouteSegmentWeather) -> Int {
        var score = segment.roadConditions.map { $0.riskWeight }.max() ?? 0
        // Stacked hazards compound.
        if segment.roadConditions.count > 1 {
            score += (segment.roadConditions.count - 1) * 8
        }
        // Precip likelihood adds up to 15 points even without a named hazard.
        score += Int(segment.precipProbability * 15)
        return min(score, 100)
    }

    private static func summary(for segments: [RouteSegmentWeather], scores: [Int]) -> String {
        guard let worstIdx = scores.indices.max(by: { scores[$0] < scores[$1] }),
              worstIdx < segments.count else { return "Conditions look clear" }
        let worst = segments[worstIdx]
        guard let top = worst.roadConditions.first else {
            return "Conditions look clear along this route"
        }
        let position: String
        if worstIdx == 0 { position = "near pickup" }
        else if worstIdx == segments.count - 1 { position = "near delivery" }
        else { position = "mid-route" }
        if let place = worst.placeName, !place.isEmpty {
            return "\(top.title) near \(place)"
        }
        return "\(top.title) \(position)"
    }
}
