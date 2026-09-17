import Foundation
import CoreLocation
import Combine

// =============================================================================
// MARK: - LocationManager
// -----------------------------------------------------------------------------
// Single source of truth for the user's ("the truck's") live GPS position.
// Wraps CLLocationManager as an ObservableObject so any SwiftUI view or service
// can observe `location` and `authorizationStatus`. Shared singleton because
// both map tabs, both dashboard cards, and the AlertEngine all need the same
// position — running multiple CLLocationManagers wastes battery.
//
// Behavior:
//   * Requests "When In Use" authorization on demand (never at launch).
//   * Continuous updates while the app is active (vehicle accuracy).
//   * Pauses automatically when no observer needs it (start/stop refcount).
//   * Publishes a Combine subject the AlertEngine subscribes to.
// =============================================================================

@MainActor
final class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()

    @Published private(set) var location: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var heading: CLLocationDirection?
    @Published private(set) var isUpdating = false

    /// Emits every fresh fix; AlertEngine and view models subscribe.
    let locationPublisher = PassthroughSubject<CLLocation, Never>()

    private let manager = CLLocationManager()
    /// Number of active consumers; updates run only while > 0.
    private var startCount = 0
    /// Number of consumers (live-follow maps) needing navigation-grade GPS.
    /// While > 0 we switch to bestForNavigation + a tight distanceFilter so the
    /// truck marker keeps up; at 0 we fall back to the battery-friendly profile
    /// that Weather / Rate Map / Near Me rely on.
    private var highAccuracyCount = 0

    private override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        applyAccuracyProfile()
    }

    /// Re-applies accuracy/filter based on whether any live-follow map is active.
    private func applyAccuracyProfile() {
        if highAccuracyCount > 0 {
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            // 12 m (was 5): at highway speed a 5 m filter fires ~6 fixes/sec,
            // flooding the follow-camera and causing visible map stutter. 12 m
            // keeps following smooth while cutting redundant fixes ~60%.
            manager.distanceFilter = 12           // meters — smooth truck following
            manager.pausesLocationUpdatesAutomatically = false
        } else {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 50           // plenty for market/weather granularity
            manager.pausesLocationUpdatesAutomatically = true
        }
    }

    /// Request navigation-grade GPS (call on a live-follow map's onAppear).
    /// Balanced by `endHighAccuracy()`. Safe to nest.
    func beginHighAccuracy() {
        highAccuracyCount += 1
        applyAccuracyProfile()
    }

    /// Release one navigation-grade request; reverts to battery-friendly at 0.
    func endHighAccuracy() {
        highAccuracyCount = max(0, highAccuracyCount - 1)
        applyAccuracyProfile()
    }

    var coordinate: CLLocationCoordinate2D? { location?.coordinate }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse ||
        authorizationStatus == .authorizedAlways
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    /// Ask for permission if we don't have it yet. Safe to call repeatedly.
    func requestAuthorizationIfNeeded() {
        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Begin (or join) continuous updates. Balanced by `stopUpdating()`.
    func startUpdating() {
        requestAuthorizationIfNeeded()
        startCount += 1
        guard isAuthorized else { return }
        if !isUpdating {
            isUpdating = true
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
        }
    }

    /// Release one consumer; stops the hardware when the last one leaves.
    func stopUpdating() {
        startCount = max(0, startCount - 1)
        if startCount == 0, isUpdating {
            isUpdating = false
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
        }
    }

    /// One-shot request used by cards that just need a current fix.
    func requestOneShot() {
        requestAuthorizationIfNeeded()
        guard isAuthorized else { return }
        manager.requestLocation()
    }
}

enum MapLocationMode: String, Codable, CaseIterable, Identifiable {
    case currentLocation = "current_location"
    case manualLocation = "manual_location"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .currentLocation: return "Use Current Location"
        case .manualLocation: return "Manual Location"
        }
    }
}

struct ManualMapLocation: Codable, Equatable {
    var city: String
    var state: String
    var latitude: Double
    var longitude: Double
    var displayName: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@MainActor
final class MapLocationPreferenceStore: ObservableObject {
    static let shared = MapLocationPreferenceStore()

    @Published private(set) var mode: MapLocationMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    @Published private(set) var manualLocation: ManualMapLocation? {
        didSet { saveManualLocation() }
    }

    private static let modeKey = "map_location_mode"
    private static let manualLocationKey = "map_manual_location"
    private let location = LocationManager.shared

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.modeKey) ?? MapLocationMode.currentLocation.rawValue
        mode = MapLocationMode(rawValue: raw) ?? .currentLocation
        if let data = UserDefaults.standard.data(forKey: Self.manualLocationKey) {
            manualLocation = try? JSONDecoder().decode(ManualMapLocation.self, from: data)
        }
    }

    var effectiveCoordinate: CLLocationCoordinate2D? {
        switch mode {
        case .currentLocation:
            return location.coordinate
        case .manualLocation:
            return manualLocation?.coordinate
        }
    }

    var statusText: String {
        switch mode {
        case .currentLocation:
            return location.isDenied ? "Location permission is off" : "Using your current location"
        case .manualLocation:
            return manualLocation?.displayName ?? "Manual location not set"
        }
    }

    var isManualReady: Bool {
        mode == .manualLocation && manualLocation != nil
    }

    func useCurrentLocation() {
        mode = .currentLocation
        location.requestAuthorizationIfNeeded()
        location.requestOneShot()
    }

    func saveManualLocation(_ location: ManualMapLocation) {
        manualLocation = location
        mode = .manualLocation
    }

    private func saveManualLocation() {
        guard let manualLocation else {
            UserDefaults.standard.removeObject(forKey: Self.manualLocationKey)
            return
        }
        if let data = try? JSONEncoder().encode(manualLocation) {
            UserDefaults.standard.set(data, forKey: Self.manualLocationKey)
        }
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didChangeAuthorization status: CLAuthorizationStatus) {
        MainActor.assumeIsolated {
            self.authorizationStatus = status
            // If a consumer asked to start before authorization resolved, honor
            // it now that we're authorized.
            if self.isAuthorized, self.startCount > 0, !self.isUpdating {
                self.isUpdating = true
                self.manager.startUpdatingLocation()
                if CLLocationManager.headingAvailable() {
                    self.manager.startUpdatingHeading()
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        // Drop stale or wildly inaccurate fixes.
        guard latest.horizontalAccuracy >= 0,
              latest.horizontalAccuracy < 200,
              abs(latest.timestamp.timeIntervalSinceNow) < 30 else { return }
        MainActor.assumeIsolated {
            self.location = latest
            self.locationPublisher.send(latest)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let trueHeading = newHeading.trueHeading
        MainActor.assumeIsolated {
            self.heading = trueHeading
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // Non-fatal: keep last known location. A denied/networkless GPS simply
        // means the maps fall back to the cached snapshot's region.
    }
}
