import Foundation
import SwiftUI
import MapKit
import Combine
import CoreLocation

// =============================================================================
// MARK: - WeatherMapViewModel (MVVM)
// -----------------------------------------------------------------------------
// Presentation state for the Weather Map: the active OWM tile layer, the
// "Follow My Truck" toggle, the map region (driven into the UIKit MKMapView
// representable), and the live conditions panel. Bridges WeatherService +
// LocationManager + AlertEngine.
// =============================================================================

@MainActor
final class WeatherMapViewModel: ObservableObject {
    @Published var layer: WeatherLayer = .precipitation
    @Published var followTruck: Bool = true
    @Published var region: MKCoordinateRegion
    /// Bumped to tell the representable to reload its tile overlay (refresh).
    @Published var overlayReloadToken = UUID()

    private let weather: WeatherService
    private let location: LocationManager
    private let alerts: AlertEngine
    private let locationPreference = MapLocationPreferenceStore.shared
    private var cancellables = Set<AnyCancellable>()
    private var didInitialCenter = false

    init(weather: WeatherService? = nil,
         location: LocationManager? = nil,
         alerts: AlertEngine? = nil) {
        self.weather = weather ?? .shared
        self.location = location ?? .shared
        self.alerts = alerts ?? .shared
        self.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
            span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 34)
        )
    }

    var conditions: WeatherConditions? { weather.snapshot?.conditions }
    var providerAlerts: [WeatherAlertEvent] { weather.snapshot?.alerts ?? [] }
    var isLoading: Bool { weather.isLoading }
    var isConfigured: Bool { weather.isConfigured }
    var lastError: String? { weather.lastError }
    var userCoordinate: CLLocationCoordinate2D? { locationPreference.effectiveCoordinate }

    func tileTemplate() -> String? { weather.tileURLTemplate(for: layer) }

    func onAppear() {
        location.startUpdating()
        weather.startAutoRefresh(at: { [weak self] in self?.locationPreference.effectiveCoordinate })

        // Center + first fetch on the first good fix.
        location.$location
            .compactMap { $0?.coordinate }
            .sink { [weak self] coord in
                guard let self else { return }
                guard self.locationPreference.mode == .currentLocation else { return }
                if !self.didInitialCenter {
                    self.didInitialCenter = true
                    self.region = MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4)
                    )
                } else if self.followTruck {
                    self.region.center = coord
                }
            }
            .store(in: &cancellables)

        locationPreference.$manualLocation
            .sink { [weak self] _ in
                guard let self,
                      self.locationPreference.mode == .manualLocation,
                      let coord = self.locationPreference.effectiveCoordinate else { return }
                self.didInitialCenter = true
                self.region = MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4)
                )
                Task {
                    await self.weather.refresh(at: coord, force: true)
                    self.overlayReloadToken = UUID()
                }
            }
            .store(in: &cancellables)

        // When a fresh snapshot lands, run the AlertEngine for the truck spot.
        weather.$snapshot
            .compactMap { $0 }
            .sink { [weak self] snap in
                guard let self, let coord = self.locationPreference.effectiveCoordinate else { return }
                Task { await self.alerts.evaluate(snapshot: snap, at: coord) }
            }
            .store(in: &cancellables)
    }

    func onDisappear() {
        location.stopUpdating()
        cancellables.removeAll()
    }

    func refresh() async {
        guard let coord = locationPreference.effectiveCoordinate else {
            location.requestOneShot()
            return
        }
        await weather.refresh(at: coord, force: true)
        overlayReloadToken = UUID()
    }

    func changeLayer(_ newLayer: WeatherLayer) {
        layer = newLayer
        overlayReloadToken = UUID()
    }

    func centerOnTruck() {
        guard let coord = locationPreference.effectiveCoordinate else {
            location.requestOneShot()
            return
        }
        region = MKCoordinateRegion(center: coord, span: region.span)
    }

    func toggleFollow() {
        followTruck.toggle()
        if followTruck { centerOnTruck() }
    }
}
