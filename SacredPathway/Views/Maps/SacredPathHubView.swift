import SwiftUI
import MapKit
import CoreLocation

// =============================================================================
// MARK: - Sacred Path Hub
// -----------------------------------------------------------------------------
// Sacred Path is Driver Hub's TRUCK STOP LOCATOR and TRIP PLANNER for
// Owner-Operator and Carrier users. It helps drivers find trucking resources
// (truck stops, rest areas, fuel, parking, scales, repairs), plan trips, and
// start Driver Hub's in-app Sacred Path navigation.
//
// Sections:
//   * Trip planning   — current location + destination entry + plan action
//   * Truck-safe route info (preview placeholder)
//   * Nearby truck parking & rest areas (live layer → SacredPathMapView)
//   * Fuel stops & travel centers (preview placeholder, opens parking map)
//   * Weather along route (preview placeholder)
//
// Gating is inherited from the Maps tab: this view is only reachable from the
// Owner-Operator and Carrier roots. The Driver role has no Maps tab and never
// reaches Sacred Path.
// =============================================================================

struct SacredPathHubView: View {
    @StateObject private var route = SacredPathRouteViewModel()
    @ObservedObject private var location = LocationManager.shared
    @FocusState private var destinationFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                routePlannerCard
                laneBidCard
                aiTripPlannerCard
                truckProfileCard
                truckSafeGuidanceCard
                parkingLayerCard
                fuelStopsCard
                weatherAlongRouteCard
                footerNote
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.spBackground)
        .onAppear {
            location.startUpdating()
            Task { await route.refreshCurrentLocation() }
        }
        .onChange(of: location.location?.timestamp) { _, _ in
            Task { await route.refreshCurrentLocation() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.spGold)
                Text("Sacred Path")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.spTextPrimary)
            }
            Text("Truck stop locator & trip planner — find truck stops, rest areas, fuel, parking, and scales, then plan a trip inside Driver Hub.")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Route planner

    private var routePlannerCard: some View {
        SacredPathCard(
            icon: "point.topleft.down.to.point.bottomright.curvepath.fill",
            title: "Route Planning",
            accessory: PreviewPill(text: "Beta")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                // Current location
                HStack(spacing: 10) {
                    Image(systemName: "dot.circle.and.cursorarrow")
                        .foregroundStyle(Color.spGreenAccent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Current location")
                            .font(.caption2)
                            .foregroundStyle(Color.spTextSecondary)
                        Text(route.currentPlaceName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.spTextPrimary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if location.isDenied {
                        Button("Enable") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.spGold)
                    }
                }

                // Intermediate stops (added with the + button below). Each is a
                // waypoint the route passes through before the destination.
                ForEach($route.waypoints) { $wp in
                    HStack(spacing: 10) {
                        Image(systemName: "smallcircle.filled.circle.fill")
                            .foregroundStyle(Color.spGold)
                            .frame(width: 22)
                        TextField("Stop — city, address, or business", text: $wp.text)
                            .textInputAutocapitalization(.words)
                            .foregroundStyle(Color.spTextPrimary)
                        Button {
                            withAnimation { route.removeWaypoint(wp.id) }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(Color.spTextSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove stop")
                    }
                }

                // + Add stop — sits between current location and destination so
                // the driver can insert one or more stops along the way.
                Button {
                    withAnimation { route.addWaypoint() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add stop")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.spGold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.spGold.opacity(0.10), in: Capsule())
                    .overlay(Capsule().stroke(Color.spGold.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a stop between your location and destination")

                Divider().overlay(Color.spGold.opacity(0.18))

                // Destination entry
                HStack(spacing: 10) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(Color.spDanger)
                        .frame(width: 22)
                    TextField("Destination — city, address, or business", text: $route.destination)
                        .focused($destinationFocused)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.go)
                        .foregroundStyle(Color.spTextPrimary)
                        .onSubmit { planRoute() }
                    if !route.destination.isEmpty {
                        Button {
                            route.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.spTextSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Plan action
                Button(action: planRoute) {
                    HStack(spacing: 8) {
                        if route.isPlanning {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        }
                        Text(route.isPlanning ? "Planning…" : "Plan Truck-Safe Route")
                            .font(.subheadline.weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .foregroundStyle(.white)
                    .background(Color.spDarkGreen, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spGold.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(route.isPlanning)

                if let message = route.planMessage {
                    Label(message, systemImage: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }

                if let summary = route.routeSummary {
                    routePreview(summary)
                }
            }
        }
    }

    private func routePreview(_ summary: SacredPathRouteViewModel.RouteSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(summary.destinationName, systemImage: "flag.checkered")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                    .lineLimit(1)
                Spacer()
                if summary.stops.count > 1 {
                    Text("\(summary.stops.count - 1) stop\(summary.stops.count - 1 == 1 ? "" : "s") on the way")
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary)
                }
            }
            Text("See truck stops, fuel, rest areas, and parking along your route.")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            NavigationLink {
                SacredPathRoutePreviewView(
                    stops: summary.stops,
                    currentPlaceName: route.currentPlaceName
                )
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "map.fill")
                    Text("Preview Trip")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .padding(.horizontal, 12)
                .foregroundStyle(.white)
                .background(Color.spDarkGreen, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spGold.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.spCardBgLight, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spGreenAccent.opacity(0.35), lineWidth: 1))
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.spGold)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
        }
    }

    // MARK: AI Trip Planner (HOS + fuel planning)

    private var aiTripPlannerCard: some View {
        NavigationLink {
            AITripPlannerView()
        } label: {
            SacredPathCard(
                icon: "sparkles",
                title: "AI Trip Planner",
                accessory: PreviewPill(text: "Plan")
            ) {
                HStack {
                    Text("Plan hours, fuel stops, and rest before you roll — get a legal, on-time plan with your 30-minute break and 10/34-hour resets. Works with or without Motive.")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.spTextSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var laneBidCard: some View {
        NavigationLink {
            AILaneBidView()
        } label: {
            SacredPathCard(
                icon: "chart.line.uptrend.xyaxis",
                title: "AI Lane Bid",
                accessory: PreviewPill(text: "New")
            ) {
                HStack {
                    Text("Enter pickup, delivery, miles, fuel, equipment, and broker offer to get minimum, target, and strong-ask bid guidance.")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.spTextSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Truck profile (equipment for routing)

    private var truckProfileCard: some View {
        NavigationLink {
            TruckProfileSettingsView()
        } label: {
            SacredPathCard(
                icon: "truck.box.fill",
                title: "Truck Profile",
                accessory: PreviewPill(text: "Edit")
            ) {
                HStack {
                    Text("Set your height, weight, length, axles, trailer, and routing preferences. Used to plan truck-friendly routes as routing providers come online.")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.spTextSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Truck-safe guidance (placeholder)

    private var truckSafeGuidanceCard: some View {
        SacredPathCard(
            icon: "ruler.fill",
            title: "Truck-Safe Route Info",
            accessory: PreviewPill(text: "Coming soon")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sacred Path will flag low bridges, weight and length limits, and restricted roads to be aware of, based on your equipment profile. Always follow posted signs and official truck routes.")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                FlowChips(items: ["13′6″ height", "80,000 lb", "53′ length", "Hazmat", "No-truck roads"])
            }
        }
    }

    // MARK: Parking layer (live)

    private var parkingLayerCard: some View {
        NavigationLink {
            SacredPathMapView()
                .navigationTitle("Truck Parking & Rest Areas")
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            SacredPathCard(
                icon: "parkingsign.circle.fill",
                title: "Nearby Truck Parking & Rest Areas",
                accessory: LivePill()
            ) {
                HStack {
                    Text("Live map of truck stops, rest areas, scales, and community parking reports along your route.")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.spTextSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Fuel stops (placeholder, opens parking map)

    private var fuelStopsCard: some View {
        NavigationLink {
            SacredPathMapView()
                .navigationTitle("Fuel & Travel Centers")
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            SacredPathCard(
                icon: "fuelpump.fill",
                title: "Fuel Stops & Travel Centers",
                accessory: PreviewPill(text: "Preview")
            ) {
                HStack {
                    Text("Find diesel and travel centers on the map now. Lane fuel pricing and cost-to-fill planning are coming.")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.spTextSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Weather along route (placeholder)

    private var weatherAlongRouteCard: some View {
        SacredPathCard(
            icon: "cloud.sun.rain.fill",
            title: "Weather Along Route",
            accessory: PreviewPill(text: "Coming soon")
        ) {
            Text("Severe-weather and road-condition alerts for your planned lane. For now, check live conditions on the Weather map in the Maps tab.")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footerNote: some View {
        VStack(spacing: 8) {
            SacredPathDisclaimer()
                .padding(12)
                .background(Color.spCardBg, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spGold.opacity(0.18), lineWidth: 1))

            Text("Sacred Path is available to Owner-Operator and Carrier accounts.")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
        }
    }

    private func planRoute() {
        destinationFocused = false
        Task { await route.planRoute() }
    }
}

// =============================================================================
// MARK: - Route view model
// =============================================================================

@MainActor
final class SacredPathRouteViewModel: ObservableObject {
    /// A single intermediate-stop text entry between the origin and destination.
    struct StopField: Identifiable {
        let id = UUID()
        var text: String = ""
    }

    @Published var currentPlaceName: String = "Locating…"
    @Published var destination: String = ""
    /// Optional intermediate stops, in order, between current location and the
    /// destination. Added via the "+" button in the route planner.
    @Published var waypoints: [StopField] = []
    @Published var routeSummary: RouteSummary?
    @Published var isPlanning = false
    @Published var planMessage: String?

    private let geocoder = CLGeocoder()
    private let location = LocationManager.shared
    private let locationPreference = MapLocationPreferenceStore.shared
    /// Last coordinate we reverse-geocoded, so we can skip redundant lookups.
    private var lastGeocodedCoordinate: CLLocationCoordinate2D?

    struct RouteSummary {
        /// Ordered stops to route THROUGH, ending at the destination. The origin
        /// (current location) is not included. For a single-destination trip
        /// this has one element.
        let stops: [SacredPathDestination]
        let distanceMiles: Double
        let estimatedHours: Double

        var destinationName: String { stops.last?.name ?? "Destination" }

        var driveTimeText: String {
            if estimatedHours < 1 {
                return "\(Int((estimatedHours * 60).rounded())) min"
            }
            let hours = Int(estimatedHours)
            let minutes = Int(((estimatedHours - Double(hours)) * 60).rounded())
            return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
        }
    }

    func addWaypoint() {
        waypoints.append(StopField())
    }

    func removeWaypoint(_ id: UUID) {
        waypoints.removeAll { $0.id == id }
    }

    func refreshCurrentLocation() async {
        if locationPreference.mode == .manualLocation {
            currentPlaceName = locationPreference.manualLocation?.displayName ?? "Manual location"
            return
        }

        guard let coordinate = location.coordinate else {
            currentPlaceName = location.isDenied ? "Location is off" : "Locating…"
            return
        }
        // Skip redundant reverse-geocodes — the city/state label only changes
        // when the truck moves a meaningful distance. Without this the hub
        // re-rendered on every GPS fix, which made its buttons feel laggy.
        if let last = lastGeocodedCoordinate,
           CLLocation(latitude: last.latitude, longitude: last.longitude)
               .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) < 800 {
            return
        }
        let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let placemark = try? await geocoder.reverseGeocodeLocation(loc).first {
            let parts = [placemark.locality, placemark.administrativeArea].compactMap { $0 }
            currentPlaceName = parts.isEmpty
                ? String(format: "%.3f, %.3f", coordinate.latitude, coordinate.longitude)
                : parts.joined(separator: ", ")
        } else {
            currentPlaceName = String(format: "%.3f, %.3f", coordinate.latitude, coordinate.longitude)
        }
        lastGeocodedCoordinate = coordinate
    }

    func clear() {
        destination = ""
        waypoints = []
        routeSummary = nil
        planMessage = nil
    }

    func planRoute() async {
        let query = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            planMessage = "Enter a destination to preview a truck-safe route."
            return
        }
        guard let origin = locationPreference.effectiveCoordinate else {
            planMessage = location.isDenied
                ? "Turn on location access to plan a route."
                : "Waiting for your current location…"
            return
        }

        isPlanning = true
        planMessage = nil
        routeSummary = nil

        // Resolve, in order: each non-empty intermediate stop, then the
        // destination. Each lookup is biased toward the previous point so
        // "truck stop" or a city resolves to the one actually on the way.
        var resolved: [SacredPathDestination] = []
        var searchCenter = origin
        let queries = waypoints.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } + [query]

        for q in queries {
            guard let place = await resolvePlace(q, near: searchCenter) else {
                planMessage = "Couldn't find \"\(q)\". Try a city, full address, or business name."
                isPlanning = false
                return
            }
            resolved.append(place)
            searchCenter = place.coordinate
        }

        guard !resolved.isEmpty else {
            isPlanning = false
            return
        }

        // Straight-line estimate through all stops (the preview map computes the
        // true driving route). 55 mph average for the time estimate.
        var meters: CLLocationDistance = 0
        var prev = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        for stop in resolved {
            let next = CLLocation(latitude: stop.latitude, longitude: stop.longitude)
            meters += prev.distance(from: next)
            prev = next
        }
        let miles = meters / 1609.344
        routeSummary = RouteSummary(
            stops: resolved,
            distanceMiles: miles,
            estimatedHours: miles / 55.0
        )
        isPlanning = false
    }

    /// Geocode a free-text place biased toward `center`, returning a named stop.
    private func resolvePlace(_ query: String, near center: CLLocationCoordinate2D) async -> SacredPathDestination? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        request.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: 2_000_000,
            longitudinalMeters: 2_000_000
        )
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else {
            return nil
        }
        let c = item.placemark.coordinate
        return SacredPathDestination(name: item.name ?? query, latitude: c.latitude, longitude: c.longitude)
    }
}

// =============================================================================
// MARK: - Reusable building blocks
// =============================================================================

private struct SacredPathCard<Accessory: View, Content: View>: View {
    let icon: String
    let title: String
    let accessory: Accessory
    let content: () -> Content

    init(icon: String, title: String, accessory: Accessory, @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spGold)
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.spTextPrimary)
                Spacer(minLength: 8)
                accessory
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.spCardBg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.spGold.opacity(0.2), lineWidth: 1))
    }
}

private struct PreviewPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.spGold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.spGold.opacity(0.14), in: Capsule())
    }
}

private struct LivePill: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.spGreenAccent).frame(width: 6, height: 6)
            Text("Live")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.spGreenAccent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.spGreenAccent.opacity(0.14), in: Capsule())
    }
}

private struct FlowChips: View {
    let items: [String]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.spCardBgLight, in: Capsule())
                        .overlay(Capsule().stroke(Color.spGold.opacity(0.3), lineWidth: 1))
                }
            }
            .padding(.horizontal, 1)
        }
    }
}

private enum LaneBidUrgency: String, CaseIterable, Identifiable {
    case flexible = "Flexible"
    case normal = "Normal"
    case urgent = "Urgent"

    var id: String { rawValue }

    var marginBoost: Double {
        switch self {
        case .flexible: return 0.10
        case .normal: return 0.15
        case .urgent: return 0.20
        }
    }
}

private struct LaneBidRecommendation {
    let minimumBid: Double
    let targetBid: Double
    let strongBid: Double
    let ratePerMile: Double
    let estimatedFuelCost: Double
    let estimatedProfit: Double
    let riskLevel: String
    let reasoning: [String]
    let warning: String?
    let action: String
}

private enum LaneBidCalculator {
    static func calculate(
        loadedMiles: Double,
        deadheadMiles: Double,
        weight: Double,
        fuelPrice: Double,
        brokerOffer: Double,
        operatingCostPerMile: Double,
        urgency: LaneBidUrgency
    ) -> LaneBidRecommendation {
        let totalMiles = max(1, loadedMiles + deadheadMiles)
        let mpg = weight >= 40_000 ? 6.0 : (weight >= 25_000 ? 6.5 : 7.0)
        let baseCost = totalMiles * operatingCostPerMile
        let fuelEstimate = (totalMiles / mpg) * fuelPrice
        let minimumBid = (baseCost + fuelEstimate) * 1.15
        let targetBid = minimumBid * (1 + urgency.marginBoost)
        let strongBid = targetBid * 1.10
        let ratePerMile = targetBid / totalMiles
        let profitAtTarget = targetBid - baseCost - fuelEstimate
        let profitAtOffer = brokerOffer - baseCost - fuelEstimate

        let risk: String
        if brokerOffer > 0, brokerOffer < minimumBid {
            risk = "High"
        } else if deadheadMiles / totalMiles > 0.25 || urgency == .urgent {
            risk = "Medium"
        } else {
            risk = "Low"
        }

        let warning = brokerOffer > 0 && brokerOffer < minimumBid
            ? "Broker offer is below your minimum safe bid by \(money(minimumBid - brokerOffer))."
            : nil
        let action = brokerOffer <= 0
            ? "Open at \(money(strongBid)) and be prepared to settle near \(money(targetBid))."
            : (profitAtOffer >= profitAtTarget * 0.85
               ? "Offer is workable. Accept only if pickup timing and detention risk look clean."
               : "Counter at \(money(targetBid)); reject below \(money(minimumBid)).")

        let reasoning = [
            "Total miles: \(Int(totalMiles.rounded())) loaded + deadhead.",
            "Fuel estimate uses \(String(format: "%.1f", mpg)) MPG and \(money(fuelPrice))/gal.",
            "Minimum bid covers operating cost, fuel, and a 15% safety margin.",
            urgency == .urgent ? "Urgency adds a stronger target margin." : "Target bid adds negotiation room above minimum."
        ]

        return LaneBidRecommendation(
            minimumBid: minimumBid,
            targetBid: targetBid,
            strongBid: strongBid,
            ratePerMile: ratePerMile,
            estimatedFuelCost: fuelEstimate,
            estimatedProfit: profitAtTarget,
            riskLevel: risk,
            reasoning: reasoning,
            warning: warning,
            action: action
        )
    }

    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }
}

private struct AILaneBidView: View {
    @State private var pickupCity = ""
    @State private var pickupState = ""
    @State private var deliveryCity = ""
    @State private var deliveryState = ""
    @State private var pickupDate = Date()
    @State private var deliveryDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var loadedMiles = "650"
    @State private var deadheadMiles = "45"
    @State private var weight = "42000"
    @State private var equipmentType = "Dry Van"
    @State private var fuelPrice = "3.85"
    @State private var brokerOffer = "2200"
    @State private var operatingCostPerMile = "1.65"
    @State private var urgency: LaneBidUrgency = .normal
    @State private var recommendation: LaneBidRecommendation?

    private let equipmentTypes = ["Dry Van", "Reefer", "Flatbed", "Step Deck", "Power Only"]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                inputCard
                if let recommendation {
                    resultCard(recommendation)
                }
                disclaimer
            }
            .padding(16)
        }
        .background(Color.spBackground)
        .navigationTitle("AI Lane Bid")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Calculate") { calculate() }
                    .font(.subheadline.weight(.bold))
            }
        }
        .onAppear { calculate() }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lane")
                .font(.headline)
                .foregroundStyle(Color.spTextPrimary)

            HStack {
                field("Pickup city", text: $pickupCity)
                field("State", text: $pickupState, width: 82)
            }
            HStack {
                field("Delivery city", text: $deliveryCity)
                field("State", text: $deliveryState, width: 82)
            }

            DatePicker("Pickup date", selection: $pickupDate, displayedComponents: .date)
            DatePicker("Delivery date", selection: $deliveryDate, displayedComponents: .date)

            Picker("Equipment", selection: $equipmentType) {
                ForEach(equipmentTypes, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)

            HStack {
                field("Loaded miles", text: $loadedMiles, keyboard: .decimalPad)
                field("Deadhead", text: $deadheadMiles, keyboard: .decimalPad)
            }
            HStack {
                field("Weight", text: $weight, keyboard: .decimalPad)
                field("Fuel $/gal", text: $fuelPrice, keyboard: .decimalPad)
            }
            HStack {
                field("Broker offer", text: $brokerOffer, keyboard: .decimalPad)
                field("Cost/mi", text: $operatingCostPerMile, keyboard: .decimalPad)
            }

            Picker("Urgency", selection: $urgency) {
                ForEach(LaneBidUrgency.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Button(action: calculate) {
                Label("Calculate Bid", systemImage: "sparkles")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(Color.spDarkGreen, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spGold.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.spCardBg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.spGold.opacity(0.2), lineWidth: 1))
    }

    private func resultCard(_ rec: LaneBidRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended Bid: \(LaneBidCalculator.money(rec.targetBid))")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.spGold)

            HStack(spacing: 10) {
                bidMetric("Minimum", rec.minimumBid)
                bidMetric("Target", rec.targetBid)
                bidMetric("Strong Ask", rec.strongBid)
            }

            Divider().background(Color.spGold.opacity(0.2))

            HStack(spacing: 16) {
                smallMetric("RPM", String(format: "$%.2f", rec.ratePerMile))
                smallMetric("Fuel", LaneBidCalculator.money(rec.estimatedFuelCost))
                smallMetric("Profit", LaneBidCalculator.money(rec.estimatedProfit))
                smallMetric("Risk", rec.riskLevel)
            }

            if let warning = rec.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spWarning)
            }

            Text(rec.action)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Reasoning")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.spTextSecondary)
                ForEach(rec.reasoning, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
            }
        }
        .padding(14)
        .background(Color.spCardBg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.spGold.opacity(0.2), lineWidth: 1))
    }

    private var disclaimer: some View {
        Text("Bid estimates are suggestions only. Final rate depends on market conditions, broker negotiation, equipment, fuel, and driver costs.")
            .font(.caption)
            .foregroundStyle(Color.spTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background(Color.spCardBgLight, in: RoundedRectangle(cornerRadius: 12))
    }

    private func field(_ title: String, text: Binding<String>, width: CGFloat? = nil, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.spTextSecondary)
            TextField(title, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.words)
                .padding(10)
                .background(Color.spCardBgLight, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Color.spTextPrimary)
        }
        .frame(width: width)
    }

    private func bidMetric(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LaneBidCalculator.money(value))
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.spTextPrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func smallMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.spTextPrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
        }
    }

    private func calculate() {
        recommendation = LaneBidCalculator.calculate(
            loadedMiles: number(loadedMiles),
            deadheadMiles: number(deadheadMiles),
            weight: number(weight),
            fuelPrice: number(fuelPrice),
            brokerOffer: number(brokerOffer),
            operatingCostPerMile: number(operatingCostPerMile),
            urgency: urgency
        )
    }

    private func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: "")) ?? 0
    }
}

#Preview {
    NavigationStack {
        SacredPathHubView()
    }
}
