import Foundation
import CoreLocation

// =============================================================================
// MARK: - Weather Models
// -----------------------------------------------------------------------------
// Provider-agnostic weather value types for the Weather Map, the dashboard
// "Weather Near Me" card, and the AlertEngine. OpenWeatherMap is the first
// concrete provider (see WeatherService), but nothing here references OWM —
// any future provider maps its payload onto these structs.
// =============================================================================

/// OpenWeatherMap raster tile layers used as MapKit overlays. The rawValue is
/// the exact OWM layer code embedded in the tile URL template. Adding a layer
/// later (e.g. clouds) is a one-line change here with zero UI edits.
enum WeatherLayer: String, CaseIterable, Identifiable, Codable, Hashable {
    case precipitation = "precipitation_new"
    case clouds        = "clouds_new"
    case wind          = "wind_new"
    case temperature   = "temp_new"
    case pressure      = "pressure_new"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .precipitation: return "Rain / Snow"
        case .clouds:        return "Clouds"
        case .wind:          return "Wind"
        case .temperature:   return "Temp"
        case .pressure:      return "Pressure"
        }
    }

    var systemImage: String {
        switch self {
        case .precipitation: return "cloud.rain.fill"
        case .clouds:        return "cloud.fill"
        case .wind:          return "wind"
        case .temperature:   return "thermometer.medium"
        case .pressure:      return "gauge.with.dots.needle.bottom.50percent"
        }
    }
}

/// Normalized weather condition family derived from the provider's condition
/// code. Used for iconography and by the AlertEngine for road-impact logic.
enum WeatherConditionKind: String, Codable, Hashable {
    case clear, clouds, rain, drizzle, thunderstorm, snow, fog, wind, extremeHeat, unknown

    var systemImage: String {
        switch self {
        case .clear:        return "sun.max.fill"
        case .clouds:       return "cloud.fill"
        case .rain:         return "cloud.rain.fill"
        case .drizzle:      return "cloud.drizzle.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        case .snow:         return "cloud.snow.fill"
        case .fog:          return "cloud.fog.fill"
        case .wind:         return "wind"
        case .extremeHeat:  return "thermometer.sun.fill"
        case .unknown:      return "questionmark.circle"
        }
    }
}

/// Current conditions at a coordinate. All measurements are stored in metric
/// (provider native) and exposed via imperial helpers the UI uses directly.
struct WeatherConditions: Codable, Hashable {
    let coordinate: CodableCoordinate
    let placeName: String?
    let kind: WeatherConditionKind
    let summary: String           // e.g. "Light snow"
    let temperatureF: Double
    let feelsLikeF: Double
    let windSpeedMph: Double
    let windGustMph: Double?
    let windDirectionDegrees: Double
    let visibilityMiles: Double
    let humidityPercent: Int
    let capturedAt: Date

    /// 16-point compass label for the wind direction.
    var windCompass: String {
        let dirs = ["N","NNE","NE","ENE","E","ESE","SE","SSE",
                    "S","SSW","SW","WSW","W","WNW","NW","NNW"]
        let idx = Int((windDirectionDegrees / 22.5).rounded()) % 16
        return dirs[(idx + 16) % 16]
    }
}

/// A Codable wrapper so CLLocationCoordinate2D can live inside cached snapshots.
struct CodableCoordinate: Codable, Hashable {
    let latitude: Double
    let longitude: Double

    init(_ c: CLLocationCoordinate2D) {
        latitude = c.latitude
        longitude = c.longitude
    }

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A provider-issued weather alert (e.g. NWS event surfaced through OWM One Call).
struct WeatherAlertEvent: Codable, Hashable, Identifiable {
    let id: String
    let event: String          // "Winter Storm Warning"
    let senderName: String?
    let start: Date
    let end: Date
    let description: String
}

/// Full weather snapshot for a location: current conditions plus any active
/// provider alerts. The tile overlays are fetched separately as map tiles.
struct WeatherSnapshot: Codable, Hashable {
    let conditions: WeatherConditions
    let alerts: [WeatherAlertEvent]
    let capturedAt: Date

    func nearestCoordinateMatches(_ coordinate: CLLocationCoordinate2D, toleranceMeters: Double = 25_000) -> Bool {
        let a = CLLocation(latitude: conditions.coordinate.latitude,
                           longitude: conditions.coordinate.longitude)
        let b = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return a.distance(from: b) <= toleranceMeters
    }
}

// =============================================================================
// MARK: - Forecast Models (hourly / daily / route weather)
// -----------------------------------------------------------------------------
// Provider-agnostic forecast value types. OpenWeatherMap One Call 3.0 is the
// preferred source (hourly + daily + alerts); the free /data/2.5/forecast
// endpoint is the silent fallback (3-hourly entries aggregated into daily
// buckets). Nothing here references OWM — see ForecastService in
// WeatherService.swift for the fetch + fallback logic.
// =============================================================================

/// Which upstream endpoint produced a forecast. Used only for diagnostics and
/// for knowing whether alerts came from the provider or were derived.
enum ForecastSource: String, Codable, Hashable {
    case oneCall   // /data/3.0/onecall — true hourly, 8-day daily, NWS alerts
    case legacy    // /data/2.5/forecast — 3-hourly, 5-day, heuristic alerts
}

/// One hourly (or 3-hourly on the legacy endpoint) forecast point.
struct HourlyForecastPoint: Codable, Hashable, Identifiable {
    let date: Date
    let temperatureF: Double
    let kind: WeatherConditionKind
    /// Probability of precipitation, 0...1.
    let precipProbability: Double
    let windSpeedMph: Double
    let windGustMph: Double?
    let visibilityMiles: Double?

    var id: Date { date }
}

/// One daily forecast point (min/max + dominant condition).
struct DailyForecastPoint: Codable, Hashable, Identifiable {
    let date: Date
    let highF: Double
    let lowF: Double
    let kind: WeatherConditionKind
    /// Probability of precipitation, 0...1.
    let precipProbability: Double
    let windSpeedMph: Double

    var id: Date { date }
}

/// Hourly + daily forecast for a coordinate, plus any severe alerts (provider
/// issued on One Call; heuristically derived on the legacy fallback).
struct WeatherForecast: Codable, Hashable {
    let coordinate: CodableCoordinate
    let placeName: String?
    /// Next ~24h (legacy fallback: 3-hour steps).
    let hourly: [HourlyForecastPoint]
    /// Up to 7-8 days (legacy fallback: 5-6 days).
    let daily: [DailyForecastPoint]
    let alerts: [WeatherAlertEvent]
    let source: ForecastSource
    let capturedAt: Date

    func isFresh(ttl: TimeInterval = 30 * 60) -> Bool {
        Date().timeIntervalSince(capturedAt) < ttl
    }

    func coordinateMatches(_ other: CLLocationCoordinate2D, toleranceMeters: Double = 25_000) -> Bool {
        let a = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let b = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return a.distance(from: b) <= toleranceMeters
    }

    /// Alerts whose window overlaps "now" (small lead-in so an alert starting
    /// within the next 6h still surfaces to a driver planning a leg).
    var activeAlerts: [WeatherAlertEvent] {
        let now = Date()
        return alerts.filter { $0.start <= now.addingTimeInterval(6 * 3600) && $0.end >= now }
    }
}

// =============================================================================
// MARK: - Road Conditions
// =============================================================================

/// Road-impact condition derived from forecast data for a location. Each case
/// carries a severity and a driver-facing message tuned for CDL drivers.
enum RoadCondition: String, Codable, CaseIterable, Hashable, Identifiable {
    case iceRisk
    case snow
    case heavyRain
    case denseFog
    case highWind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iceRisk:   return "Ice Risk"
        case .snow:      return "Snow"
        case .heavyRain: return "Heavy Rain"
        case .denseFog:  return "Dense Fog"
        case .highWind:  return "High Wind"
        }
    }

    var systemImage: String {
        switch self {
        case .iceRisk:   return "thermometer.snowflake"
        case .snow:      return "cloud.snow.fill"
        case .heavyRain: return "cloud.heavyrain.fill"
        case .denseFog:  return "cloud.fog.fill"
        case .highWind:  return "wind"
        }
    }

    var severity: DriverAlertSeverity {
        switch self {
        case .iceRisk, .denseFog: return .warning
        case .snow, .heavyRain, .highWind: return .watch
        }
    }

    /// Driver-facing guidance shown in route-weather lists.
    var driverMessage: String {
        switch self {
        case .iceRisk:
            return "Temps near freezing with precipitation — ice possible on bridges and ramps. Slow down and avoid hard braking."
        case .snow:
            return "Snow expected on this stretch. Reduce speed, increase following distance, and check chain requirements."
        case .heavyRain:
            return "Heavy rain likely — hydroplaning risk. Increase following distance and watch standing water."
        case .denseFog:
            return "Dense fog expected — visibility may drop under half a mile. Low beams, reduce speed."
        case .highWind:
            return "Sustained high wind — use caution with empty or high-profile trailers; expect crosswinds on exposed lanes."
        }
    }
}

// =============================================================================
// MARK: - Route Weather Risk
// =============================================================================

/// Bucketed route-weather risk derived from the 0–100 score.
enum RouteRiskLevel: String, Codable, Hashable {
    case low, moderate, high, severe

    init(score: Int) {
        switch score {
        case ..<25:   self = .low
        case 25..<50: self = .moderate
        case 50..<75: self = .high
        default:      self = .severe
        }
    }

    var label: String {
        switch self {
        case .low:      return "Low"
        case .moderate: return "Moderate"
        case .high:     return "High"
        case .severe:   return "Severe"
        }
    }
}

/// Weather at one sampled point along a route — worst conditions over the next
/// ~12 hours at that point.
struct RouteSegmentWeather: Codable, Hashable, Identifiable {
    let coordinate: CodableCoordinate
    let placeName: String?
    let kind: WeatherConditionKind
    let temperatureF: Double
    let windSpeedMph: Double
    /// Max probability of precipitation over the window, 0...1.
    let precipProbability: Double
    let roadConditions: [RoadCondition]

    var id: String { "\(coordinate.latitude),\(coordinate.longitude)" }
}

/// Output of RouteWeatherService.assessRoute — a 0–100 score, its level, the
/// per-segment worst conditions, and the de-duplicated road-condition warnings.
struct RouteWeatherRisk: Codable, Hashable {
    /// 0 (clear) ... 100 (dangerous).
    let score: Int
    let level: RouteRiskLevel
    let segments: [RouteSegmentWeather]
    /// Union of segment conditions, worst severity first.
    let roadConditions: [RoadCondition]
    /// Short human summary of the worst stretch, e.g. "Snow near Amarillo".
    let worstSummary: String
    let capturedAt: Date
}
