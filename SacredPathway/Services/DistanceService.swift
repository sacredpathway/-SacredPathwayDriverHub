import Foundation
import CoreLocation
import MapKit

// =============================================================================
// DistanceService
// -----------------------------------------------------------------------------
// Free, Apple-only distance calculator for pickup → delivery legs.
//
// PIPELINE
// --------
// 1. Forward-geocode each "City, ST" string with `CLGeocoder` (Apple).
//    No API key. Online-only.
// 2. Ask `MKDirections` for a driving route between the two coordinates and
//    return the route's `distance` in miles (kDirectionsTransportType.automobile).
// 3. If MKDirections cannot return a route (offline, ferry-only, no road
//    connection, no permission, rate-limited), fall back to `CLLocation`'s
//    great-circle `distance(from:)` and label it `.estimatedStraightLine`.
// 4. If even geocoding fails, return `.unavailable` so the caller leaves the
//    miles field blank for manual entry.
//
// HARD RULES — DO NOT CHANGE
//  * No Google Maps API. No paid mileage API. No keys.
//  * Apple frameworks only: `CLGeocoder`, `MKDirections`, `CLLocation`.
//  * No `NSLocationWhenInUseUsageDescription` needed — we never ask for the
//    device's location. Forward geocoding strings is permission-free.
//
// USAGE
//   let result = await DistanceService.shared.distance(
//       from: "Carlisle, PA",
//       to:   "Ocala, FL"
//   )
//   switch result {
//   case .driving(let miles):           // turn-by-turn driving distance
//   case .estimatedStraightLine(let m): // great-circle, label "Estimated"
//   case .unavailable(let reason):      // leave miles blank
//   }
// =============================================================================

@MainActor
final class DistanceService {
    static let shared = DistanceService()
    private init() {}

    // MARK: - Result type

    enum DistanceResult: Equatable {
        /// Real driving distance from `MKDirections`. Trustworthy.
        case driving(miles: Double)
        /// Geocoding succeeded but no driving route was returned. Great-circle
        /// distance — caller MUST label this "Estimated" in the UI.
        case estimatedStraightLine(miles: Double)
        /// Geocoding or all fallbacks failed. Caller should leave miles blank.
        case unavailable(reason: String)

        /// True if the UI should show an "Estimated" badge.
        var isEstimate: Bool {
            if case .estimatedStraightLine = self { return true }
            return false
        }

        /// The numeric miles, or nil if unavailable.
        var miles: Double? {
            switch self {
            case .driving(let m), .estimatedStraightLine(let m): return m
            case .unavailable: return nil
            }
        }
    }

    // MARK: - Public API

    /// Calculate distance between two free-form "City, ST" strings.
    ///
    /// Both inputs are normalized — trailing whitespace, ZIP, etc. are
    /// tolerated. Returns `.unavailable` if either string is empty or
    /// unparseable.
    func distance(from origin: String, to destination: String) async -> DistanceResult {
        let originTrim = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let destTrim   = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originTrim.isEmpty, !destTrim.isEmpty else {
            return .unavailable(reason: "Pickup or delivery is empty")
        }

        // 1. Geocode both endpoints.
        async let originCoord = geocode(originTrim)
        async let destCoord   = geocode(destTrim)
        let (oResult, dResult) = await (originCoord, destCoord)

        guard let o = oResult else {
            return .unavailable(reason: "Couldn't find \(originTrim)")
        }
        guard let d = dResult else {
            return .unavailable(reason: "Couldn't find \(destTrim)")
        }

        // 2. Try driving directions first.
        if let drivingMiles = await drivingDistance(from: o, to: d) {
            return .driving(miles: drivingMiles)
        }

        // 3. Fall back to great-circle.
        let line = greatCircleMiles(from: o, to: d)
        return .estimatedStraightLine(miles: line)
    }

    /// Convenience for the common pickup → delivery case used by the load
    /// form. Returns the rounded integer miles plus the `isEstimate` flag.
    func roundedMiles(from origin: String, to destination: String) async -> (miles: Int, isEstimate: Bool)? {
        let result = await distance(from: origin, to: destination)
        guard let m = result.miles else { return nil }
        return (Int(m.rounded()), result.isEstimate)
    }

    // MARK: - Geocoding

    /// Forward-geocode "City, ST" → CLLocationCoordinate2D using Apple's free
    /// `CLGeocoder`. Returns nil on any failure.
    private func geocode(_ query: String) async -> CLLocationCoordinate2D? {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.geocodeAddressString(
                query,
                in: nil,
                preferredLocale: Locale(identifier: "en_US")
            )
            // Prefer the first placemark with a usable location.
            if let coord = placemarks.first?.location?.coordinate {
                return coord
            }
        } catch {
            #if DEBUG
            print("[DistanceService] geocode failed for '\(query)': \(error)")
            #endif
        }
        return nil
    }

    // MARK: - Driving distance

    /// Ask MapKit for a driving route. Returns miles or nil if no route.
    private func drivingDistance(from origin: CLLocationCoordinate2D,
                                 to destination: CLLocationCoordinate2D) async -> Double? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false

        let directions = MKDirections(request: request)
        do {
            let response = try await directions.calculate()
            // distance is in meters; convert to miles (1 meter = 0.000621371 miles).
            if let route = response.routes.first {
                return route.distance * 0.000621371
            }
        } catch {
            #if DEBUG
            print("[DistanceService] MKDirections failed: \(error)")
            #endif
        }
        return nil
    }

    // MARK: - Fallback

    /// Great-circle distance — the absolute floor when MKDirections refuses.
    /// Add ~12% to approximate road winding factor; clearer than raw line-
    /// of-sight which always under-estimates real driving distance.
    private func greatCircleMiles(from a: CLLocationCoordinate2D,
                                  to b: CLLocationCoordinate2D) -> Double {
        let aLoc = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let bLoc = CLLocation(latitude: b.latitude, longitude: b.longitude)
        let meters = aLoc.distance(from: bLoc)
        let straightMiles = meters * 0.000621371
        let roadAdjustment = 1.12
        return straightMiles * roadAdjustment
    }
}
