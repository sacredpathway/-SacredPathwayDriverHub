import Foundation
import CoreLocation
import Combine

// =============================================================================
// MARK: - FreightRateService
// -----------------------------------------------------------------------------
// The abstraction the brief requires. The UI binds to `FreightRateService`
// (an ObservableObject) and NEVER to a concrete data source. The actual data
// comes from any type conforming to `FreightRateProviding`. Today that's the
// bundled `MockFreightRateProvider`; tomorrow it can be a DAT, Truckstop, or
// SONAR provider with zero view changes — you only swap the provider passed to
// `FreightRateService(provider:)` (or flip `Config.FreightRate.activeProvider`).
//
// Responsibilities:
//   * Hold the current snapshot + loading / error state for the views.
//   * Auto-refresh every 15 minutes while active.
//   * Cache the last good snapshot to disk and hydrate from it on launch
//     (instant data + offline support).
// =============================================================================

/// Pluggable freight-rate data source. A real integration implements this and
/// returns the same provider-agnostic `FreightRateSnapshot` the mock returns.
protocol FreightRateProviding: Sendable {
    /// Fetch the latest market snapshot. `region` is the visible map area (or a
    /// radius around the truck) so real providers can scope the query; the mock
    /// ignores it and returns the national board.
    func fetchSnapshot(around coordinate: CLLocationCoordinate2D?) async throws -> FreightRateSnapshot
}

@MainActor
final class FreightRateService: ObservableObject {
    static let shared = FreightRateService()

    @Published private(set) var snapshot: FreightRateSnapshot = .empty
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?

    /// 15-minute automatic refresh, per spec.
    nonisolated static let refreshInterval: TimeInterval = 15 * 60

    private var provider: FreightRateProviding
    private var refreshTask: Task<Void, Never>?
    private var hydrated = false

    init(provider: FreightRateProviding = MockFreightRateProvider()) {
        self.provider = provider
    }

    /// Hot-swap the data source at runtime (e.g. when a DAT token is added).
    /// The UI is untouched — it just starts seeing the new provider's data on
    /// the next refresh.
    func setProvider(_ newProvider: FreightRateProviding) {
        provider = newProvider
        Task { await refresh(around: nil, force: true) }
    }

    /// Load cached snapshot from disk so views render instantly/offline.
    func hydrateFromCacheIfNeeded() async {
        guard !hydrated else { return }
        hydrated = true
        if let cached = await MapCacheStore.shared.load(FreightRateSnapshot.self,
                                                        key: MapCacheKey.freightSnapshot) {
            snapshot = cached
            lastUpdated = cached.capturedAt
        }
    }

    /// Begin the auto-refresh loop. Idempotent — call from `onAppear`.
    func startAutoRefresh(around coordinate: CLLocationCoordinate2D? = nil) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.hydrateFromCacheIfNeeded()
            await self.refresh(around: coordinate)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await self.refresh(around: coordinate)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Manual / pull-to-refresh. `force` ignores the freshness guard.
    func refresh(around coordinate: CLLocationCoordinate2D?, force: Bool = false) async {
        if !force, let last = lastUpdated,
           Date().timeIntervalSince(last) < 60 {
            return // debounce rapid refreshes
        }
        isLoading = true
        lastError = nil
        do {
            let fresh = try await provider.fetchSnapshot(around: coordinate)
            snapshot = fresh
            lastUpdated = fresh.capturedAt
            await MapCacheStore.shared.save(fresh, key: MapCacheKey.freightSnapshot)
        } catch {
            // Keep showing the last good (cached) snapshot; surface the error.
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    // Convenience for the dashboard card / "Rate Near Me".
    func nearestMarket(to coordinate: CLLocationCoordinate2D?) -> FreightMarket? {
        guard let coordinate else { return snapshot.markets.first }
        return snapshot.nearestMarket(to: coordinate)
    }
}

// =============================================================================
// MARK: - MockFreightRateProvider
// -----------------------------------------------------------------------------
// Realistic, deterministic-but-lively mock covering 24 major U.S. freight
// markets across all three equipment types. Values jitter slightly per refresh
// (±a few cents, trend may flip) so the map visibly "lives" during testing,
// while staying inside believable RPM bands. Replace with a real provider by
// conforming a new type to FreightRateProviding — nothing else changes.
// =============================================================================

struct MockFreightRateProvider: FreightRateProviding {

    /// Base market definitions: id, city, state, lat, lon, and a base RPM per
    /// equipment. Refresh-time jitter is layered on top.
    private struct Base {
        let id: String; let city: String; let state: String
        let lat: Double; let lon: Double
        let van: Double; let reefer: Double; let flat: Double
        let ltr: Double // base load-to-truck ratio
    }

    private static let markets: [Base] = [
        Base(id: "ATL", city: "Atlanta",       state: "GA", lat: 33.749,  lon: -84.388,  van: 2.18, reefer: 2.55, flat: 2.70, ltr: 4.8),
        Base(id: "DAL", city: "Dallas",        state: "TX", lat: 32.776,  lon: -96.797,  van: 2.02, reefer: 2.40, flat: 2.85, ltr: 3.6),
        Base(id: "HOU", city: "Houston",       state: "TX", lat: 29.760,  lon: -95.369,  van: 1.95, reefer: 2.30, flat: 2.95, ltr: 3.1),
        Base(id: "LAX", city: "Los Angeles",   state: "CA", lat: 34.052,  lon: -118.244, van: 1.78, reefer: 2.20, flat: 2.25, ltr: 2.4),
        Base(id: "ONT", city: "Ontario",       state: "CA", lat: 34.063,  lon: -117.651, van: 1.82, reefer: 2.28, flat: 2.30, ltr: 2.7),
        Base(id: "CHI", city: "Chicago",       state: "IL", lat: 41.878,  lon: -87.630,  van: 2.22, reefer: 2.62, flat: 2.55, ltr: 5.2),
        Base(id: "PHL", city: "Philadelphia",  state: "PA", lat: 39.953,  lon: -75.165,  van: 2.05, reefer: 2.48, flat: 2.40, ltr: 4.1),
        Base(id: "NYC", city: "Newark",        state: "NJ", lat: 40.735,  lon: -74.172,  van: 2.30, reefer: 2.70, flat: 2.45, ltr: 6.0),
        Base(id: "MIA", city: "Miami",         state: "FL", lat: 25.762,  lon: -80.192,  van: 1.70, reefer: 2.05, flat: 2.10, ltr: 1.9),
        Base(id: "LAK", city: "Lakeland",      state: "FL", lat: 28.039,  lon: -81.950,  van: 2.12, reefer: 2.66, flat: 2.35, ltr: 4.6),
        Base(id: "MEM", city: "Memphis",       state: "TN", lat: 35.149,  lon: -90.049,  van: 2.10, reefer: 2.50, flat: 2.50, ltr: 4.4),
        Base(id: "NSH", city: "Nashville",     state: "TN", lat: 36.162,  lon: -86.781,  van: 2.16, reefer: 2.54, flat: 2.58, ltr: 4.7),
        Base(id: "CLT", city: "Charlotte",     state: "NC", lat: 35.227,  lon: -80.843,  van: 2.14, reefer: 2.52, flat: 2.52, ltr: 4.5),
        Base(id: "IND", city: "Indianapolis",  state: "IN", lat: 39.768,  lon: -86.158,  van: 2.20, reefer: 2.58, flat: 2.56, ltr: 4.9),
        Base(id: "CMH", city: "Columbus",      state: "OH", lat: 39.961,  lon: -82.999,  van: 2.18, reefer: 2.56, flat: 2.54, ltr: 4.8),
        Base(id: "KC",  city: "Kansas City",   state: "MO", lat: 39.100,  lon: -94.578,  van: 2.06, reefer: 2.44, flat: 2.62, ltr: 3.7),
        Base(id: "DEN", city: "Denver",        state: "CO", lat: 39.739,  lon: -104.990, van: 1.92, reefer: 2.30, flat: 2.48, ltr: 2.9),
        Base(id: "PHX", city: "Phoenix",       state: "AZ", lat: 33.448,  lon: -112.074, van: 1.88, reefer: 2.32, flat: 2.34, ltr: 2.8),
        Base(id: "SLC", city: "Salt Lake City",state: "UT", lat: 40.760,  lon: -111.891, van: 1.96, reefer: 2.36, flat: 2.60, ltr: 3.2),
        Base(id: "SEA", city: "Seattle",       state: "WA", lat: 47.606,  lon: -122.332, van: 1.86, reefer: 2.30, flat: 2.40, ltr: 2.6),
        Base(id: "PDX", city: "Portland",      state: "OR", lat: 45.515,  lon: -122.679, van: 1.90, reefer: 2.34, flat: 2.42, ltr: 2.7),
        Base(id: "MSP", city: "Minneapolis",   state: "MN", lat: 44.978,  lon: -93.265,  van: 2.08, reefer: 2.46, flat: 2.50, ltr: 3.9),
        Base(id: "STL", city: "St. Louis",     state: "MO", lat: 38.627,  lon: -90.199,  van: 2.10, reefer: 2.48, flat: 2.52, ltr: 4.0),
        Base(id: "OKC", city: "Oklahoma City", state: "OK", lat: 35.468,  lon: -97.516,  van: 2.00, reefer: 2.38, flat: 2.72, ltr: 3.4)
    ]

    func fetchSnapshot(around coordinate: CLLocationCoordinate2D?) async throws -> FreightRateSnapshot {
        // Simulate light network latency so loading states are exercised.
        try? await Task.sleep(nanoseconds: 250_000_000)

        // Deterministic-per-15-min jitter seed so the board is stable within a
        // refresh window but moves between windows.
        let window = Int(Date().timeIntervalSince1970 / FreightRateService.refreshInterval)

        var markets: [FreightMarket] = []
        var vanSum = 0.0, reeferSum = 0.0, flatSum = 0.0

        for base in Self.markets {
            let jv = Self.jitter(base.id, window, salt: 1)
            let jr = Self.jitter(base.id, window, salt: 2)
            let jf = Self.jitter(base.id, window, salt: 3)
            let jl = Self.jitter(base.id, window, salt: 4)

            let van = max(1.20, base.van + jv * 0.18)
            let reefer = max(1.50, base.reefer + jr * 0.20)
            let flat = max(1.50, base.flat + jf * 0.22)
            let ltrVan = max(0.3, base.ltr + jl * 1.6)

            vanSum += van; reeferSum += reefer; flatSum += flat

            let rates: [EquipmentType: EquipmentRate] = [
                .dryVan: EquipmentRate(equipment: .dryVan, ratePerMile: van,
                                       loadToTruckRatio: ltrVan,
                                       trend: Self.trend(base.id, window, salt: 1)),
                .reefer: EquipmentRate(equipment: .reefer, ratePerMile: reefer,
                                       loadToTruckRatio: max(0.3, ltrVan * 0.85),
                                       trend: Self.trend(base.id, window, salt: 2)),
                .flatbed: EquipmentRate(equipment: .flatbed, ratePerMile: flat,
                                        loadToTruckRatio: max(0.3, ltrVan * 0.7),
                                        trend: Self.trend(base.id, window, salt: 3))
            ]

            markets.append(FreightMarket(id: base.id, city: base.city, state: base.state,
                                         latitude: base.lat, longitude: base.lon,
                                         rates: rates))
        }

        let n = Double(Self.markets.count)
        let nationalAverages: [EquipmentType: Double] = [
            .dryVan: (vanSum / n * 100).rounded() / 100,
            .reefer: (reeferSum / n * 100).rounded() / 100,
            .flatbed: (flatSum / n * 100).rounded() / 100
        ]

        return FreightRateSnapshot(markets: markets,
                                   nationalAverages: nationalAverages,
                                   capturedAt: Date())
    }

    // Stable pseudo-random in [-1, 1] from a string id + window + salt.
    private static func jitter(_ id: String, _ window: Int, salt: Int) -> Double {
        var hasher = Hasher()
        hasher.combine(id); hasher.combine(window); hasher.combine(salt)
        let h = UInt64(bitPattern: Int64(hasher.finalize()))
        let unit = Double(h % 1000) / 1000.0          // [0,1)
        return unit * 2 - 1                            // [-1,1)
    }

    private static func trend(_ id: String, _ window: Int, salt: Int) -> MarketTrend {
        let j = jitter(id, window, salt: salt + 10)
        if j > 0.33 { return .up }
        if j < -0.33 { return .down }
        return .flat
    }
}
