import Foundation
import CoreLocation
import MapKit
import SwiftUI

// =============================================================================
// MARK: - Sacred Path truck routing & intelligence architecture
// -----------------------------------------------------------------------------
// Provider seams for the data Apple's frameworks do NOT supply (truck-legal
// routing, low-bridge / weight / hazmat restrictions, posted speed limits).
// The navigation engine talks to these protocols so a real backend (HERE,
// TomTom, Trucker Path, or a Supabase-hosted restriction set) can be dropped in
// later WITHOUT touching the UI or the engine. Default providers are safe
// (return nothing) so the app never invents restriction data it can't verify.
// =============================================================================

// MARK: Truck profile

enum TruckTrailerType: String, Codable, CaseIterable, Identifiable {
    case dryVan
    case reefer
    case flatbed
    case stepDeck
    case tanker
    case lowboy
    case carHauler
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dryVan:    return "Dry Van"
        case .reefer:    return "Reefer"
        case .flatbed:   return "Flatbed"
        case .stepDeck:  return "Step Deck"
        case .tanker:    return "Tanker"
        case .lowboy:    return "Lowboy"
        case .carHauler: return "Car Hauler"
        case .other:     return "Other"
        }
    }
}

struct SacredPathTruckProfile: Codable, Equatable {
    var heightFeet: Int
    var heightInches: Int
    var lengthFeet: Int
    var widthFeet: Int = 8
    var widthInches: Int = 6
    var grossWeightLbs: Int
    var axles: Int
    var hasHazmat: Bool
    // New routing inputs (defaulted so existing initializers keep compiling).
    var trailerType: TruckTrailerType = .dryVan
    var avoidTolls: Bool = false
    var avoidFerries: Bool = false
    var preferTruckStops: Bool = true
    var preferHighways: Bool = true

    static let defaultOwnerOperator = SacredPathTruckProfile(
        heightFeet: 13,
        heightInches: 6,
        lengthFeet: 53,
        grossWeightLbs: 80_000,
        axles: 5,
        hasHazmat: false
    )

    var heightTotalFeet: Double { Double(heightFeet) + Double(heightInches) / 12.0 }
    var widthTotalFeet: Double { Double(widthFeet) + Double(widthInches) / 12.0 }
    var heightMeters: Double { heightTotalFeet * 0.3048 }
    var widthMeters: Double { widthTotalFeet * 0.3048 }
    var weightMetricTons: Double { Double(grossWeightLbs) * 0.00045359237 }

    var summaryLine: String {
        var parts = ["\(heightFeet)′\(heightInches)″ H", "\(widthFeet)′\(widthInches)″ W", "\(grossWeightLbs / 1000)k lb", "\(lengthFeet)′"]
        if hasHazmat { parts.append("Hazmat") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Local truck-profile store (persisted, no network)

@MainActor
final class TruckProfileStore: ObservableObject {
    static let shared = TruckProfileStore()

    @Published var profile: SacredPathTruckProfile {
        didSet { persist() }
    }

    private let key = "sph.truckProfile.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(SacredPathTruckProfile.self, from: data) {
            profile = decoded
        } else {
            profile = .defaultOwnerOperator
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: Navigation route model

struct SacredPathNavigationStep {
    let instruction: String
    let coordinate: CLLocationCoordinate2D
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    let maneuverType: String
}

struct SacredPathNavigationRoute {
    let coordinates: [CLLocationCoordinate2D]
    let steps: [SacredPathNavigationStep]
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    let providerName: String
    let isTruckAware: Bool
    let limitations: [String]

    var boundingCoordinates: [CLLocationCoordinate2D] {
        coordinates.isEmpty ? steps.map(\.coordinate) : coordinates
    }
}

// MARK: Truck route restrictions

enum TruckRestrictionKind: String, Codable, CaseIterable {
    case lowBridge
    case weightLimit
    case lengthLimit
    case widthLimit
    case hazmat
    case noTrucks
    case weighStation
    case steepGrade

    var symbol: String {
        switch self {
        case .lowBridge:    return "arrow.up.and.down.square.fill"
        case .weightLimit:  return "scalemass.fill"
        case .lengthLimit:  return "ruler.fill"
        case .widthLimit:   return "arrow.left.and.right.square.fill"
        case .hazmat:       return "exclamationmark.triangle.fill"
        case .noTrucks:     return "nosign"
        case .weighStation: return "building.columns.fill"
        case .steepGrade:   return "mountain.2.fill"
        }
    }

    var title: String {
        switch self {
        case .lowBridge:    return "Low Bridge"
        case .weightLimit:  return "Weight Limit"
        case .lengthLimit:  return "Length Limit"
        case .widthLimit:   return "Width Limit"
        case .hazmat:       return "Hazmat Restriction"
        case .noTrucks:     return "No Trucks"
        case .weighStation: return "Weigh Station"
        case .steepGrade:   return "Steep Grade"
        }
    }
}

struct TruckRouteRestriction: Identifiable, Hashable {
    let id: UUID
    let kind: TruckRestrictionKind
    let title: String
    let detail: String
    let latitude: Double
    let longitude: Double

    init(id: UUID = UUID(), kind: TruckRestrictionKind, title: String? = nil, detail: String, latitude: Double, longitude: Double) {
        self.id = id
        self.kind = kind
        self.title = title ?? kind.title
        self.detail = detail
        self.latitude = latitude
        self.longitude = longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Backend seam for truck-legal restriction data. A real implementation calls
/// HERE / TomTom / Trucker Path or a Supabase restriction table.
protocol TruckRouteRestrictionProvider {
    func restrictions(along route: SacredPathNavigationRoute, profile: SacredPathTruckProfile) async -> [TruckRouteRestriction]
}

/// Default: no third-party truck-restriction backend is wired yet, so this
/// returns nothing rather than fabricating restriction data.
struct DefaultTruckRouteRestrictionProvider: TruckRouteRestrictionProvider {
    func restrictions(along route: SacredPathNavigationRoute, profile: SacredPathTruckProfile) async -> [TruckRouteRestriction] { [] }
}

/// Backend seam for posted speed limits (Apple provides no speed-limit API).
protocol PostedSpeedLimitProvider {
    func speedLimitMph(at coordinate: CLLocationCoordinate2D) async -> Int?
}

struct DefaultPostedSpeedLimitProvider: PostedSpeedLimitProvider {
    func speedLimitMph(at coordinate: CLLocationCoordinate2D) async -> Int? { nil }
}

// MARK: Profile-aware routing service

/// Single routing entry point for active navigation. The truck profile is
/// already threaded through so a verified provider can honor
/// height/weight/hazmat without signature changes.
struct SacredPathTruckRoutingService {
    var restrictionProvider: TruckRouteRestrictionProvider = DefaultTruckRouteRestrictionProvider()

    func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        profile: SacredPathTruckProfile
    ) async throws -> SacredPathNavigationRoute? {
        await TruckRoutingResolver.route(from: origin, to: destination, profile: profile)?.route
    }
}

// MARK: Sacred Path intelligence (upcoming services)

enum SacredPathPOIKind: String, CaseIterable, Identifiable {
    case fuel
    case parking
    case restArea
    case scales
    case service
    case weather

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fuel:     return "Fuel"
        case .parking:  return "Truck Parking"
        case .restArea: return "Rest Area"
        case .scales:   return "Scale House"
        case .service:  return "Truck Service"
        case .weather:  return "Weather Alert"
        }
    }

    var symbol: String {
        switch self {
        case .fuel:     return "fuelpump.fill"
        case .parking:  return "parkingsign.square.fill"
        case .restArea: return "bed.double.fill"
        case .scales:   return "scalemass.fill"
        case .service:  return "wrench.and.screwdriver.fill"
        case .weather:  return "cloud.bolt.rain.fill"
        }
    }

    /// MKLocalSearch natural-language queries. `.weather` is injected from the
    /// forecast service, not searched, so it has none.
    var searchQueries: [String] {
        switch self {
        case .fuel:     return ["truck stop diesel", "travel center"]
        case .parking:  return ["truck parking"]
        case .restArea: return ["rest area"]
        case .scales:   return ["weigh station", "CAT scale"]
        case .service:  return ["truck repair", "tire shop"]
        case .weather:  return []
        }
    }
}

struct SacredPathUpcomingPOI: Identifiable, Hashable {
    let id: UUID
    let kind: SacredPathPOIKind
    let name: String
    let detail: String
    let latitude: Double
    let longitude: Double
    /// Distance ahead in miles. Negative means "not a distance" (e.g. weather alert).
    let distanceMiles: Double

    init(id: UUID = UUID(), kind: SacredPathPOIKind, name: String, detail: String = "", latitude: Double, longitude: Double, distanceMiles: Double) {
        self.id = id
        self.kind = kind
        self.name = name
        self.detail = detail
        self.latitude = latitude
        self.longitude = longitude
        self.distanceMiles = distanceMiles
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var distanceText: String {
        if distanceMiles < 0 { return "Ahead" }
        if distanceMiles < 1 { return "<1 mi" }
        return "\(Int(distanceMiles.rounded())) mi"
    }
}

// MARK: MKPolyline helper

extension MKPolyline {
    /// Safe extraction of the polyline's coordinates via getCoordinates.
    func sacredPathCoordinates() -> [CLLocationCoordinate2D] {
        guard pointCount > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: pointCount
        )
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

// =============================================================================
// MARK: - Truck routing provider architecture (Task 4)
// -----------------------------------------------------------------------------
// Pluggable routing seam. The protocol lets routing providers change without
// rewriting the engine or UI. Candidate integrations: PC*Miler, Trimble CoPilot,
// HERE Truck Routing, TomTom Truck Routing, TruckMap, SmartTruckRoute.
// =============================================================================

/// Result of a routing request. `isTruckSafe` is true ONLY when a verified
/// truck-routing provider produced the route (never for the Apple fallback).
struct TruckRouteResult {
    let route: SacredPathNavigationRoute
    let isTruckSafe: Bool
    let providerName: String
}

protocol TruckRoutingProvider {
    /// Human-readable provider name shown in diagnostics / settings.
    var name: String { get }
    /// True only when this provider applies real truck restrictions.
    var providesTruckSafeRouting: Bool { get }
    /// Returns a route or throws. Honors the truck profile when supported.
    func calculateRoute(from origin: CLLocationCoordinate2D,
                        to destination: CLLocationCoordinate2D,
                        profile: SacredPathTruckProfile) async throws -> TruckRouteResult
}

enum TruckRoutingError: Error { case noRoute, notImplemented }

/// Mapbox Directions route provider. It keeps navigation in-app, returns full
/// GeoJSON route geometry plus maneuver steps, and passes truck dimensions where
/// the Directions API supports them (`max_height`, `max_width`, `max_weight`).
struct MapboxTruckRoutingProvider: TruckRoutingProvider {
    let name = "Mapbox Directions"
    let providesTruckSafeRouting = true

    func calculateRoute(from origin: CLLocationCoordinate2D,
                        to destination: CLLocationCoordinate2D,
                        profile: SacredPathTruckProfile) async throws -> TruckRouteResult {
        guard let token = Self.accessToken, !token.isEmpty else { throw TruckRoutingError.notImplemented }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.mapbox.com"
        components.path = "/directions/v5/mapbox/driving-traffic/\(origin.longitude),\(origin.latitude);\(destination.longitude),\(destination.latitude)"
        var query: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "alternatives", value: "false"),
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "steps", value: "true"),
            URLQueryItem(name: "banner_instructions", value: "true"),
            URLQueryItem(name: "voice_instructions", value: "true"),
            URLQueryItem(name: "annotations", value: "distance,duration,maxspeed"),
            URLQueryItem(name: "max_height", value: String(format: "%.2f", min(10, max(0, profile.heightMeters)))),
            URLQueryItem(name: "max_width", value: String(format: "%.2f", min(10, max(0, profile.widthMeters)))),
            URLQueryItem(name: "max_weight", value: String(format: "%.2f", min(100, max(0, profile.weightMetricTons))))
        ]
        var excludes: [String] = []
        if profile.avoidTolls { excludes.append("toll") }
        if profile.avoidFerries { excludes.append("ferry") }
        if !excludes.isEmpty {
            query.append(URLQueryItem(name: "exclude", value: excludes.joined(separator: ",")))
        }
        components.queryItems = query
        guard let url = components.url else { throw TruckRoutingError.noRoute }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TruckRoutingError.noRoute }
        let decoded = try JSONDecoder().decode(MapboxDirectionsResponse.self, from: data)
        guard let first = decoded.routes.first else { throw TruckRoutingError.noRoute }

        let coordinates = first.geometry.coordinates.map {
            CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0])
        }
        let steps = first.legs.flatMap(\.steps).map { step in
            let maneuverCoord = step.maneuver.location
            let instruction = step.bannerInstructions?.first?.primary.text
                ?? step.maneuver.instruction
                ?? "Continue ahead"
            return SacredPathNavigationStep(
                instruction: instruction,
                coordinate: CLLocationCoordinate2D(latitude: maneuverCoord[1], longitude: maneuverCoord[0]),
                distance: step.distance,
                expectedTravelTime: step.duration,
                maneuverType: step.maneuver.type ?? ""
            )
        }
        let limitations = [
            "Mapbox truck constraints cover height, width, and weight where restriction coverage exists.",
            "Hazmat and tunnel-category routing require a deeper HERE/Trimble integration."
        ]
        let route = SacredPathNavigationRoute(
            coordinates: coordinates,
            steps: steps.isEmpty ? [SacredPathNavigationStep(instruction: "Continue to \(destination.latitude), \(destination.longitude)", coordinate: destination, distance: first.distance, expectedTravelTime: first.duration, maneuverType: "arrive")] : steps,
            distance: first.distance,
            expectedTravelTime: first.duration,
            providerName: name,
            isTruckAware: true,
            limitations: limitations
        )
        return TruckRouteResult(route: route, isTruckSafe: true, providerName: name)
    }

    private static var accessToken: String? {
        if let token = Bundle.main.object(forInfoDictionaryKey: "MapboxAccessToken") as? String,
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !token.contains("$(") {
            return token
        }
        return ProcessInfo.processInfo.environment["MAPBOX_ACCESS_TOKEN"]
    }
}

private struct MapboxDirectionsResponse: Decodable {
    struct Route: Decodable {
        struct Geometry: Decodable { let coordinates: [[Double]] }
        let geometry: Geometry
        let distance: Double
        let duration: Double
        let legs: [Leg]
    }
    struct Leg: Decodable { let steps: [Step] }
    struct Step: Decodable {
        struct Maneuver: Decodable {
            let location: [Double]
            let instruction: String?
            let type: String?
        }
        struct BannerInstruction: Decodable {
            struct Primary: Decodable { let text: String }
            let primary: Primary
        }
        let distance: Double
        let duration: Double
        let maneuver: Maneuver
        let bannerInstructions: [BannerInstruction]?

        enum CodingKeys: String, CodingKey {
            case distance
            case duration
            case maneuver
            case bannerInstructions = "bannerInstructions"
        }
    }
    let routes: [Route]
}

/// Deterministic mock for tests/previews — direct route, flagged as a mock.
struct MockTruckRoutingProvider: TruckRoutingProvider {
    let name = "Mock"
    let providesTruckSafeRouting = false

    func calculateRoute(from origin: CLLocationCoordinate2D,
                        to destination: CLLocationCoordinate2D,
                        profile: SacredPathTruckProfile) async throws -> TruckRouteResult {
        let start = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let end = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
        let distance = start.distance(from: end)
        let duration = max(60, distance / 24.6)
        let route = SacredPathNavigationRoute(
            coordinates: Self.interpolate(from: origin, to: destination, count: 80),
            steps: [
                SacredPathNavigationStep(instruction: "Head toward destination", coordinate: origin, distance: distance * 0.92, expectedTravelTime: duration * 0.92, maneuverType: "depart"),
                SacredPathNavigationStep(instruction: "Arrive at destination", coordinate: destination, distance: distance * 0.08, expectedTravelTime: duration * 0.08, maneuverType: "arrive")
            ],
            distance: distance,
            expectedTravelTime: duration,
            providerName: name,
            isTruckAware: false,
            limitations: ["Offline fallback draws a direct route and is not truck restriction aware."]
        )
        return TruckRouteResult(route: route, isTruckSafe: false, providerName: name)
    }

    private static func interpolate(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, count: Int) -> [CLLocationCoordinate2D] {
        guard count > 1 else { return [origin, destination] }
        return (0..<count).map { index in
            let t = Double(index) / Double(count - 1)
            return CLLocationCoordinate2D(
                latitude: origin.latitude + (destination.latitude - origin.latitude) * t,
                longitude: origin.longitude + (destination.longitude - origin.longitude) * t
            )
        }
    }
}

/// Seam for a future verified truck-routing backend (PC*Miler / Trimble / HERE /
/// TomTom / TruckMap / SmartTruckRoute). Not wired yet. When integrated, set
/// `providesTruckSafeRouting = true` and return `isTruckSafe: true` ONLY for
/// verified truck-legal routes.
struct FutureTruckRoutingProvider: TruckRoutingProvider {
    let name = "Truck Routing (not configured)"
    let providesTruckSafeRouting = false

    func calculateRoute(from origin: CLLocationCoordinate2D,
                        to destination: CLLocationCoordinate2D,
                        profile: SacredPathTruckProfile) async throws -> TruckRouteResult {
        throw TruckRoutingError.notImplemented
    }
}

/// Chooses the active provider. Tries the configured truck provider first, then
/// falls back to the offline mock so the in-app navigation surface still opens.
@MainActor
enum TruckRoutingResolver {
    static var truckProvider: TruckRoutingProvider? = MapboxTruckRoutingProvider()
    static let fallback: TruckRoutingProvider = MockTruckRoutingProvider()

    static func route(from origin: CLLocationCoordinate2D,
                     to destination: CLLocationCoordinate2D,
                     profile: SacredPathTruckProfile) async -> TruckRouteResult? {
        if let truckProvider {
            do {
                let result = try await truckProvider.calculateRoute(from: origin, to: destination, profile: profile)
                return result
            } catch {
                await MainActor.run {
                    SacredPathMapDiagnosticsStore.shared.lastRouteError = "\(truckProvider.name): \(error.localizedDescription)"
                }
                print("[SacredPath][RouteProvider] \(truckProvider.name) failed: \(error.localizedDescription)")
            }
        }
        do {
            return try await fallback.calculateRoute(from: origin, to: destination, profile: profile)
        } catch {
            await MainActor.run {
                SacredPathMapDiagnosticsStore.shared.lastRouteError = "\(fallback.name): \(error.localizedDescription)"
            }
            print("[SacredPath][RouteProvider] \(fallback.name) failed: \(error.localizedDescription)")
            return nil
        }
    }
}

// =============================================================================
// MARK: - Truck Profile settings UI (Task 5)
// =============================================================================

struct TruckProfileSettingsView: View {
    @ObservedObject private var store = TruckProfileStore.shared

    var body: some View {
        Form {
            Section("Dimensions") {
                Stepper(value: $store.profile.heightFeet, in: 8...16) {
                    labeled("Height (ft)", "\(store.profile.heightFeet)")
                }
                Stepper(value: $store.profile.heightInches, in: 0...11) {
                    labeled("Height (in)", "\(store.profile.heightInches)")
                }
                Stepper(value: $store.profile.lengthFeet, in: 20...80) {
                    labeled("Length (ft)", "\(store.profile.lengthFeet)")
                }
                Stepper(value: $store.profile.widthFeet, in: 7...10) {
                    labeled("Width (ft)", "\(store.profile.widthFeet)")
                }
                Stepper(value: $store.profile.widthInches, in: 0...11) {
                    labeled("Width (in)", "\(store.profile.widthInches)")
                }
                Stepper(value: $store.profile.grossWeightLbs, in: 10_000...105_000, step: 1_000) {
                    labeled("Gross weight", "\(store.profile.grossWeightLbs / 1000)k lb")
                }
                Stepper(value: $store.profile.axles, in: 2...9) {
                    labeled("Axles", "\(store.profile.axles)")
                }
            }
            Section("Equipment") {
                Picker("Trailer", selection: $store.profile.trailerType) {
                    ForEach(TruckTrailerType.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Hazmat", isOn: $store.profile.hasHazmat)
            }
            Section("Routing Preferences") {
                Toggle("Avoid tolls", isOn: $store.profile.avoidTolls)
                Toggle("Avoid ferries", isOn: $store.profile.avoidFerries)
                Toggle("Prefer truck stops", isOn: $store.profile.preferTruckStops)
                Toggle("Prefer highways", isOn: $store.profile.preferHighways)
            }
            Section {
                Text("Sacred Path uses the configured in-app route provider for active navigation. Your profile is stored on-device and will feed deeper verified truck-routing providers as they are connected.")
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
            }
        }
        .navigationTitle("Truck Profile")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.spGold)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.spTextSecondary)
            Spacer()
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(Color.spTextPrimary)
        }
    }
}
