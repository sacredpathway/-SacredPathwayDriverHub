import Foundation
import SwiftUI
import MapKit
import Combine
import CoreLocation

// =============================================================================
// MARK: - RateMapViewModel (MVVM)
// -----------------------------------------------------------------------------
// Owns the Rate Map's presentation state: the selected equipment filter, the
// map camera, the selected market, and the derived markets list for the current
// filter. Reads from FreightRateService + LocationManager (both shared) and
// never talks to a concrete data provider.
// =============================================================================

@MainActor
final class RateMapViewModel: ObservableObject {
    @Published var equipment: EquipmentType = .dryVan
    @Published var selectedMarket: FreightMarket?
    @Published var cameraPosition: MapCameraPosition

    private let rates: FreightRateService
    private let location: LocationManager
    private let locationPreference = MapLocationPreferenceStore.shared
    private var cancellables = Set<AnyCancellable>()
    private var didCenterOnTruck = false

    init(rates: FreightRateService? = nil,
         location: LocationManager? = nil) {
        self.rates = rates ?? .shared
        self.location = location ?? .shared
        // Default to a continental-US framing until we get a fix.
        self.cameraPosition = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
            span: MKCoordinateSpan(latitudeDelta: 38, longitudeDelta: 42)
        ))
    }

    var snapshot: FreightRateSnapshot { rates.snapshot }
    var isLoading: Bool { rates.isLoading }
    var lastUpdated: Date? { rates.lastUpdated }
    var lastError: String? { rates.lastError }

    var markets: [FreightMarket] { rates.snapshot.markets }

    var nationalAverages: [EquipmentType: Double] { rates.snapshot.nationalAverages }

    var userCoordinate: CLLocationCoordinate2D? { locationPreference.effectiveCoordinate }

    /// Begin live data + location and auto-center on the truck on first fix.
    func onAppear() {
        location.startUpdating()
        rates.startAutoRefresh(around: locationPreference.effectiveCoordinate)

        location.$location
            .compactMap { $0?.coordinate }
            .sink { [weak self] coord in
                guard let self, !self.didCenterOnTruck, self.locationPreference.mode == .currentLocation else { return }
                self.didCenterOnTruck = true
                self.centerOnTruck(coord)
            }
            .store(in: &cancellables)

        locationPreference.$manualLocation
            .sink { [weak self] _ in
                guard let self,
                      self.locationPreference.mode == .manualLocation,
                      let coord = self.locationPreference.effectiveCoordinate else { return }
                self.centerOnTruck(coord)
                Task { await self.rates.refresh(around: coord, force: true) }
            }
            .store(in: &cancellables)
    }

    func onDisappear() {
        location.stopUpdating()
        cancellables.removeAll()
    }

    func refresh() async {
        await rates.refresh(around: locationPreference.effectiveCoordinate, force: true)
    }

    func color(for market: FreightMarket) -> Color {
        switch market.strength(for: equipment) {
        case .strong:  return .spSuccess
        case .average: return .spWarning
        case .weak:    return .spDanger
        }
    }

    func centerOnTruck() {
        guard let coord = locationPreference.effectiveCoordinate else {
            location.requestOneShot()
            return
        }
        centerOnTruck(coord)
    }

    private func centerOnTruck(_ coord: CLLocationCoordinate2D) {
        withAnimation(.easeInOut) {
            cameraPosition = .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 6)
            ))
        }
    }

    func formattedNationalAverage(_ equipment: EquipmentType) -> String {
        let v = nationalAverages[equipment] ?? 0
        return v > 0 ? String(format: "$%.2f", v) : "—"
    }

    var updatedAgoText: String {
        guard let last = lastUpdated else { return "—" }
        let mins = Int(Date().timeIntervalSince(last) / 60)
        if mins <= 0 { return "Just now" }
        if mins == 1 { return "1 min ago" }
        if mins < 60 { return "\(mins) min ago" }
        let hrs = mins / 60
        return hrs == 1 ? "1 hr ago" : "\(hrs) hrs ago"
    }
}
