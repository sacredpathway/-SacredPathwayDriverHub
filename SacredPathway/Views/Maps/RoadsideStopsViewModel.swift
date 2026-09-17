import Foundation
import CoreLocation
import MapKit
import SwiftUI

@MainActor
final class SacredPathMapViewModel: ObservableObject {
    @Published var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795),
            span: MKCoordinateSpan(latitudeDelta: 28, longitudeDelta: 38)
        )
    )
    @Published var activeCategories: Set<SacredPathCategory> = Set(SacredPathCategory.allCases)
    /// Amenity chips (Showers / DEF / Food / Overnight Parking). Empty = no
    /// amenity narrowing. When one or more are active, a stop must carry ALL of
    /// them to remain visible.
    @Published var activeAmenityFilters: Set<SacredPathAmenityFilter> = []
    @Published private(set) var stops: [SacredPathPlace] = []
    @Published var selectedStop: SacredPathPlace?
    @Published var isSearching = false
    @Published var message: String?

    /// Live truck-follow. ON = camera tracks the truck every fix; a user pan or
    /// the Follow toggle turns it OFF and reveals the Recenter button.
    @Published var followMode = true

    private let location = LocationManager.shared
    private let locationPreference = MapLocationPreferenceStore.shared
    private var searchTask: Task<Void, Never>?
    private var hasCenteredOnTruck = false

    // Heading smoothing (course-based low-pass) so the follow camera glides.
    private var smoothedHeading: Double = 0
    private var hasHeading = false
    // Distance gate: POI search runs only after meaningful movement, never on
    // every GPS fix — keeps live following separate from truck-stop loading.
    private var lastSearchLocation: CLLocation?
    private let searchRefreshMeters: CLLocationDistance = 5_000
    private var isHighAccuracyActive = false

    // Camera throttle: at highway speed GPS fixes arrive several times per
    // second. Animating the camera on every fix stacks overlapping 1s
    // animations and is the main "laggy while moving" symptom. We coalesce
    // camera follow to at most ~1 update / 0.6s (forceImmediate bypasses it).
    private var lastCameraUpdate: Date = .distantPast
    private let minCameraInterval: TimeInterval = 0.6

    var visibleStops: [SacredPathPlace] {
        stops.filter { stop in
            guard activeCategories.contains(stop.category) else { return false }
            guard !activeAmenityFilters.isEmpty else { return true }
            return activeAmenityFilters.allSatisfy { $0.matches(stop) }
        }
    }

    func onAppear() {
        location.startUpdating()
        if locationPreference.mode == .currentLocation, !isHighAccuracyActive {
            isHighAccuracyActive = true
            location.beginHighAccuracy()   // navigation-grade GPS while this map is open
        }
        followMode = true
        refresh()
    }

    func onDisappear() {
        searchTask?.cancel()
        if isHighAccuracyActive {
            isHighAccuracyActive = false
            location.endHighAccuracy()
        }
        location.stopUpdating()
    }

    /// Called on every GPS fix from the view. Cheap camera follow runs every
    /// time; the heavier POI search is distance-gated so it never throttles the
    /// map. (Separates live GPS tracking from truck-stop loading.)
    func onLocationUpdate() {
        if locationPreference.mode == .manualLocation {
            guard let coordinate = locationPreference.effectiveCoordinate else {
                message = "Choose a manual location to explore Sacred Path."
                return
            }
            followMode = false
            centerOnTruckIfNeeded(coordinate)
            searchTask?.cancel()
            searchTask = Task { await searchNearby(coordinate: coordinate) }
            return
        }

        if location.isDenied {
            stops = []
            message = "Location permission is off. Turn on location access to explore Sacred Path."
            return
        }
        guard let current = location.location else { return }
        updateFollowCamera(current)

        if let last = lastSearchLocation, current.distance(from: last) < searchRefreshMeters {
            return
        }
        lastSearchLocation = current
        searchTask?.cancel()
        searchTask = Task { await searchNearby(coordinate: current.coordinate) }
    }

    func refresh() {
        if locationPreference.mode == .manualLocation {
            guard let coordinate = locationPreference.effectiveCoordinate else {
                message = "Choose a manual location to explore Sacred Path."
                return
            }
            followMode = false
            centerOnTruckIfNeeded(coordinate)
            lastSearchLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            searchTask?.cancel()
            searchTask = Task { await searchNearby(coordinate: coordinate) }
            return
        }

        if location.isDenied {
            stops = []
            message = "Location permission is off. Turn on location access to explore Sacred Path."
            return
        }

        guard let current = location.location else {
            location.requestAuthorizationIfNeeded()
            location.requestOneShot()
            message = "Waiting for your current location to explore Sacred Path."
            return
        }

        centerOnTruckIfNeeded(current.coordinate)
        updateFollowCamera(current)
        lastSearchLocation = current
        searchTask?.cancel()
        searchTask = Task { await searchNearby(coordinate: current.coordinate) }
    }

    func toggle(_ category: SacredPathCategory) {
        if activeCategories.contains(category), activeCategories.count > 1 {
            activeCategories.remove(category)
        } else {
            activeCategories.insert(category)
        }
    }

    /// Toggle an amenity chip on/off. Amenity filters are additive narrowing —
    /// turning them all off restores the full category view.
    func toggleAmenity(_ filter: SacredPathAmenityFilter) {
        if activeAmenityFilters.contains(filter) {
            activeAmenityFilters.remove(filter)
        } else {
            activeAmenityFilters.insert(filter)
        }
    }

    /// Re-enable follow and snap the camera back onto the truck (Recenter button).
    func recenter() {
        followMode = true
        if let current = location.location {
            updateFollowCamera(current, forceImmediate: true)
        } else {
            location.requestOneShot()
        }
    }

    /// User panned the map — drop follow so the camera stops fighting them.
    func userInteractedWithMap() {
        if followMode { followMode = false }
    }

    /// Smooth, heading-up camera that keeps the truck in the lower third of the
    /// screen (centered slightly ahead along the direction of travel).
    private func updateFollowCamera(_ current: CLLocation, forceImmediate: Bool = false) {
        guard followMode else { return }
        let coordinate = current.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }

        // Coalesce rapid fixes so we don't stack overlapping camera animations.
        if !forceImmediate {
            let now = Date()
            guard now.timeIntervalSince(lastCameraUpdate) >= minCameraInterval else { return }
            lastCameraUpdate = now
        } else {
            lastCameraUpdate = Date()
        }

        // Heading from GPS course while moving; hold last otherwise so the camera
        // never spins while stopped or on a noisy fix.
        if current.course >= 0, current.speed >= 2.0, current.horizontalAccuracy >= 0, current.horizontalAccuracy <= 30 {
            if !hasHeading {
                smoothedHeading = current.course
                hasHeading = true
            } else {
                var delta = current.course - smoothedHeading
                while delta > 180 { delta -= 360 }
                while delta < -180 { delta += 360 }
                smoothedHeading = Self.normalizeAngle(smoothedHeading + delta * 0.25)
            }
        }
        let heading = hasHeading ? smoothedHeading : 0
        let mps = max(0, current.speed)
        let distance = min(3000, max(650, 650 + mps * 45))
        let aheadMeters = min(420, 90 + mps * 10)
        let center = Self.project(coordinate, distanceMeters: aheadMeters, bearing: heading)
        let camera = MapCamera(centerCoordinate: center, distance: distance, heading: heading, pitch: 45)
        if forceImmediate {
            withAnimation(.easeOut(duration: 0.35)) { cameraPosition = .camera(camera) }
        } else {
            withAnimation(.linear(duration: minCameraInterval)) { cameraPosition = .camera(camera) }
        }
    }

    private func centerOnTruckIfNeeded(_ coordinate: CLLocationCoordinate2D) {
        guard !hasCenteredOnTruck else { return }
        hasCenteredOnTruck = true
        cameraPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.45, longitudeDelta: 0.45)
            )
        )
    }

    static func normalizeAngle(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }

    /// Project a coordinate forward by `distanceMeters` along `bearing`.
    static func project(_ coordinate: CLLocationCoordinate2D, distanceMeters: CLLocationDistance, bearing: CLLocationDirection) -> CLLocationCoordinate2D {
        let earthRadius = 6_371_000.0
        let bearingRad = bearing * .pi / 180
        let lat1 = coordinate.latitude * .pi / 180
        let lon1 = coordinate.longitude * .pi / 180
        let angular = distanceMeters / earthRadius
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearingRad))
        let lon2 = lon1 + atan2(sin(bearingRad) * sin(angular) * cos(lat1),
                                cos(angular) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    private func searchNearby(coordinate: CLLocationCoordinate2D) async {
        isSearching = true
        message = nil
        let region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 80_000,
            longitudinalMeters: 80_000
        )

        // Build the full list of (query, category) work items, then run them with
        // BOUNDED concurrency. The old code awaited all ~19 MKLocalSearch calls
        // one-at-a-time (serial) — the single biggest source of map lag. Running
        // them in parallel with a small cap cuts a 5–16s "Searching…" down to
        // ~1–2s while staying under Apple's MKLocalSearch rate limits.
        struct Work { let query: String; let category: SacredPathCategory }
        let workItems: [Work] = SacredPathCategory.allCases.flatMap { category in
            category.searchQueries.map { Work(query: $0, category: category) }
        }

        let maxConcurrent = 6
        var found: [SacredPathPlace] = []
        var index = 0

        await withTaskGroup(of: [SacredPathPlace].self) { group in
            // Prime the group up to the concurrency cap.
            func addNext() {
                guard index < workItems.count else { return }
                let item = workItems[index]
                index += 1
                group.addTask { [region] in
                    await self.search(query: item.query, category: item.category, region: region)
                }
            }
            for _ in 0..<min(maxConcurrent, workItems.count) { addNext() }

            while let results = await group.next() {
                if Task.isCancelled { group.cancelAll(); return }
                found.append(contentsOf: results)
                addNext()   // refill the pipeline as each finishes
            }
        }
        if Task.isCancelled { return }

        let currentLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        stops = dedupe(found)
            .sorted { left, right in
                let l = CLLocation(latitude: left.latitude, longitude: left.longitude)
                let r = CLLocation(latitude: right.latitude, longitude: right.longitude)
                return currentLocation.distance(from: l) < currentLocation.distance(from: r)
            }
            .prefix(80)
            .map { $0 }
        isSearching = false
        if stops.isEmpty {
            message = "No Sacred Path places found nearby. Try again after moving the map or checking location access."
        }
    }

    // nonisolated so the parallel task group runs these off the main actor
    // (it touches no instance state) — keeps the UI thread free while searching.
    private func search(query: String, category: SacredPathCategory, region: MKCoordinateRegion) async -> [SacredPathPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = region
        request.resultTypes = .pointOfInterest

        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.compactMap { SacredPathPlace(mapItem: $0, category: category) }
        } catch {
            return []
        }
    }

    private func dedupe(_ stops: [SacredPathPlace]) -> [SacredPathPlace] {
        var seen = Set<String>()
        var unique: [SacredPathPlace] = []
        for stop in stops {
            let key = stop.id
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(stop)
        }
        return unique
    }
}

extension SacredPathPlace {
    init?(mapItem: MKMapItem, category: SacredPathCategory) {
        let coordinate = mapItem.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate),
              let name = mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }

        let address = [
            mapItem.placemark.subThoroughfare,
            mapItem.placemark.thoroughfare,
            mapItem.placemark.locality,
            mapItem.placemark.administrativeArea
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let roundedLat = (coordinate.latitude * 10_000).rounded() / 10_000
        let roundedLon = (coordinate.longitude * 10_000).rounded() / 10_000
        let stableID = "\(name.lowercased())|\(roundedLat)|\(roundedLon)"

        self.init(
            id: stableID,
            name: name,
            category: category,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            address: address.isEmpty ? "Address unavailable" : address,
            phoneNumber: mapItem.phoneNumber,
            urlString: mapItem.url?.absoluteString,
            openStatus: nil,
            amenities: SacredPathPlace.amenities(for: category, name: name),
            appleMapsPlaceID: nil,
            appleMapsPointOfInterestCategory: mapItem.pointOfInterestCategory?.rawValue
        )
    }

    static func amenities(for category: SacredPathCategory, name: String) -> [String] {
        var values: [String] = []
        switch category {
        case .truckStops:
            values = ["Truck access", "Fuel nearby", "Parking likely"]
        case .restAreas:
            values = ["Restrooms", "Parking"]
        case .fuel:
            values = ["Fuel"]
        case .scales:
            values = ["Truck scale"]
        case .weighStations:
            values = ["Weigh station"]
        case .parking:
            values = ["Parking"]
        case .repair:
            values = ["Repair service"]
        case .hotels:
            values = ["Lodging", "Truck parking nearby"]
        }

        let lowercased = name.lowercased()

        // A recognized major travel-center brand, or a name that reads like a
        // full-service truck stop / travel plaza. These reliably offer driver
        // services (showers, DEF lanes, hot food).
        let isTravelCenter = TruckStopBrand.detect(from: name) != nil
            || lowercased.contains("travel center")
            || lowercased.contains("travel plaza")
            || lowercased.contains("travel stop")
            || lowercased.contains("truck stop")
            || lowercased.contains("truck plaza")

        // Showers — full-service travel centers / truck stops.
        if category == .truckStops && isTravelCenter {
            values.append("Showers")
        }
        // DEF — truck stops and diesel/truck fuel locations carry DEF at the lane.
        if category == .truckStops
            || isTravelCenter
            || (category == .fuel && (lowercased.contains("diesel") || lowercased.contains("truck"))) {
            values.append("DEF")
        }
        // Food — travel centers (restaurants / QSR inside) and named eateries.
        if (category == .truckStops && isTravelCenter)
            || lowercased.contains("restaurant")
            || lowercased.contains("diner")
            || lowercased.contains("cafe")
            || lowercased.contains("grill")
            || lowercased.contains("subway")
            || lowercased.contains("mcdonald")
            || lowercased.contains("wendy")
            || lowercased.contains("arby")
            || lowercased.contains("denny") {
            values.append("Food")
        }
        // Overnight parking — truck stops, rest areas, and dedicated truck parking.
        if category == .truckStops || category == .restAreas || category == .parking {
            values.append("Overnight parking")
        }

        if lowercased.contains("tire") {
            values.append("Tires")
        }
        if lowercased.contains("wash") {
            values.append("Truck wash")
        }
        return Array(Set(values)).sorted()
    }
}
