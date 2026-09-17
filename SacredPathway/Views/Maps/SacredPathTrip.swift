import SwiftUI
import MapKit
import CoreLocation

// =============================================================================
// MARK: - Sacred Path multi-stop trip planning
// -----------------------------------------------------------------------------
// A trip is an ordered list of stops (pickup, delivery, fuel, parking, rest,
// weigh, custom, current location). Drivers build a trip, then start in-app
// Sacred Path navigation. Trips persist locally (UserDefaults) for reuse.
// =============================================================================

enum SacredPathStopKind: String, Codable, CaseIterable, Identifiable {
    case currentLocation
    case pickup
    case delivery
    case fuel
    case parking
    case restArea
    case weigh
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentLocation: return "Current Location"
        case .pickup:          return "Pickup"
        case .delivery:        return "Delivery"
        case .fuel:            return "Fuel"
        case .parking:         return "Truck Parking"
        case .restArea:        return "Rest Area"
        case .weigh:           return "Weigh Station"
        case .custom:          return "Custom Address"
        }
    }

    var symbol: String {
        switch self {
        case .currentLocation: return "location.fill"
        case .pickup:          return "shippingbox.fill"
        case .delivery:        return "house.fill"
        case .fuel:            return "fuelpump.fill"
        case .parking:         return "parkingsign.square.fill"
        case .restArea:        return "bed.double.fill"
        case .weigh:           return "scalemass.fill"
        case .custom:          return "mappin.circle.fill"
        }
    }

    /// Seeds the add-stop search for service kinds; nil for free-form/custom.
    var searchSeed: String? {
        switch self {
        case .fuel:     return "truck stop diesel"
        case .parking:  return "truck parking"
        case .restArea: return "rest area"
        case .weigh:    return "weigh station"
        default:        return nil
        }
    }

    var tint: Color {
        switch self {
        case .currentLocation: return .spGreenAccent
        case .pickup:          return .spGold
        case .delivery:        return .spDanger
        case .fuel:            return .spGold
        case .parking:         return .spGreenAccent
        case .restArea:        return .spGreenAccent
        case .weigh:           return .spWarning
        case .custom:          return .spTextSecondary
        }
    }
}

struct SacredPathStop: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: SacredPathStopKind
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var destination: SacredPathDestination {
        SacredPathDestination(name: name, latitude: latitude, longitude: longitude)
    }
}

struct SacredPathTrip: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var stops: [SacredPathStop]
    var createdAt: Date = Date()
}

struct SacredPathLeg: Identifiable, Hashable {
    var id = UUID()
    var fromName: String
    var toName: String
    var miles: Double
    var seconds: TimeInterval
}

// MARK: - Trip store (current working trip + saved trips)

@MainActor
final class SacredPathTripStore: ObservableObject {
    static let shared = SacredPathTripStore()

    @Published var stops: [SacredPathStop] = []
    @Published private(set) var savedTrips: [SacredPathTrip] = []

    private let savedKey = "sph.sacredPath.savedTrips.v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func addStop(_ stop: SacredPathStop) {
        stops.append(stop)
    }

    func remove(at offsets: IndexSet) {
        stops.remove(atOffsets: offsets)
    }

    func move(from source: IndexSet, to destination: Int) {
        stops.move(fromOffsets: source, toOffset: destination)
    }

    func clear() {
        stops.removeAll()
    }

    /// Ordered stops for in-app navigation (the driver's current location is the
    /// origin, so a current-location entry is dropped from the sequence).
    var navigationStops: [SacredPathDestination] {
        stops.filter { $0.kind != .currentLocation }.map { $0.destination }
    }

    func saveCurrent(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trip = SacredPathTrip(name: trimmed.isEmpty ? "Trip \(savedTrips.count + 1)" : trimmed, stops: stops)
        savedTrips.insert(trip, at: 0)
        persist()
    }

    func load(_ trip: SacredPathTrip) {
        stops = trip.stops
    }

    func deleteTrip(_ trip: SacredPathTrip) {
        savedTrips.removeAll { $0.id == trip.id }
        persist()
    }

    private func persist() {
        if let data = try? encoder.encode(savedTrips) {
            UserDefaults.standard.set(data, forKey: savedKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let decoded = try? decoder.decode([SacredPathTrip].self, from: data) else { return }
        savedTrips = decoded
    }
}

// MARK: - Multi-leg routing

enum SacredPathTripRouter {
    /// Computes drive legs between consecutive stops using MKDirections.
    /// `origin` (live GPS) is prepended when the first stop is not a current
    /// location, so totals reflect the real start of the trip.
    static func legs(for stops: [SacredPathStop], origin: CLLocationCoordinate2D?) async -> [SacredPathLeg] {
        // Build an ordered coordinate/name sequence.
        var points: [(name: String, coord: CLLocationCoordinate2D)] = []
        if let origin, stops.first?.kind != .currentLocation {
            points.append(("Current Location", origin))
        }
        for stop in stops {
            if stop.kind == .currentLocation, let origin {
                points.append(("Current Location", origin))
            } else {
                points.append((stop.name, stop.coordinate))
            }
        }
        guard points.count >= 2 else { return [] }

        var legs: [SacredPathLeg] = []
        for index in 0..<(points.count - 1) {
            let from = points[index]
            let to = points[index + 1]
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coord))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coord))
            request.transportType = .automobile
            if let route = try? await MKDirections(request: request).calculate(), let first = route.routes.first {
                legs.append(SacredPathLeg(fromName: from.name, toName: to.name,
                                          miles: first.distance / 1609.344, seconds: first.expectedTravelTime))
            } else {
                // Fall back to straight-line so totals still render.
                let a = CLLocation(latitude: from.coord.latitude, longitude: from.coord.longitude)
                let b = CLLocation(latitude: to.coord.latitude, longitude: to.coord.longitude)
                let miles = a.distance(from: b) / 1609.344
                legs.append(SacredPathLeg(fromName: from.name, toName: to.name,
                                          miles: miles, seconds: miles / 55.0 * 3600))
            }
        }
        return legs
    }
}

// MARK: - Trip planner UI

struct SacredPathTripPlannerView: View {
    @ObservedObject private var store = SacredPathTripStore.shared
    @ObservedObject private var location = LocationManager.shared

    @State private var legs: [SacredPathLeg] = []
    @State private var isCalculating = false
    @State private var showAddStop = false
    @State private var showSaveSheet = false
    @State private var saveName = ""

    private var totalMiles: Double { legs.reduce(0) { $0 + $1.miles } }
    private var totalSeconds: TimeInterval { legs.reduce(0) { $0 + $1.seconds } }

    var body: some View {
        List {
            stopsSection
            if store.stops.count >= 1 { totalsSection }
            if !store.savedTrips.isEmpty { savedTripsSection }
        }
        .scrollContentBackground(.hidden)
        .background(Color.spBackground)
        .navigationTitle("Plan a Trip")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton().tint(Color.spGold) }
            ToolbarItem(placement: .topBarLeading) {
                Button("Save") { showSaveSheet = true }
                    .tint(Color.spGold)
                    .disabled(store.stops.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) { startBar }
        .onAppear { location.startUpdating() }
        .task(id: store.stops) { await recalcLegs() }
        .sheet(isPresented: $showAddStop) {
            SacredPathAddStopView { stop in
                store.addStop(stop)
                showAddStop = false
            }
        }
        .alert("Save Trip", isPresented: $showSaveSheet) {
            TextField("Trip name", text: $saveName)
            Button("Save") { store.saveCurrent(name: saveName); saveName = "" }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Save this \(store.stops.count)-stop trip to reuse later.")
        }
    }

    private var stopsSection: some View {
        Section("Stops") {
            if store.stops.isEmpty {
                Text("Add pickups, deliveries, fuel, parking, and rest stops to build your trip.")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .listRowBackground(Color.spCardBg)
            }
            ForEach(Array(store.stops.enumerated()), id: \.element.id) { index, stop in
                HStack(spacing: 12) {
                    Image(systemName: stop.kind.symbol)
                        .foregroundStyle(stop.kind.tint)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.spTextPrimary)
                            .lineLimit(1)
                        Text(legLabel(forStopIndex: index) ?? stop.kind.title)
                            .font(.caption2)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    Spacer()
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.spGold)
                }
                .listRowBackground(Color.spCardBg)
            }
            .onDelete { store.remove(at: $0) }
            .onMove { store.move(from: $0, to: $1) }

            Button {
                showAddStop = true
            } label: {
                Label("Add Stop", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spGold)
            }
            .listRowBackground(Color.spCardBg)
        }
    }

    private var totalsSection: some View {
        Section("Trip Totals") {
            HStack {
                Label("Total distance", systemImage: "ruler.fill").foregroundStyle(Color.spTextSecondary)
                Spacer()
                if isCalculating { ProgressView().tint(Color.spGold) }
                else { Text("\(Int(totalMiles.rounded())) mi").font(.subheadline.weight(.bold)).foregroundStyle(Color.spTextPrimary) }
            }
            .listRowBackground(Color.spCardBg)
            HStack {
                Label("Total drive time", systemImage: "clock.fill").foregroundStyle(Color.spTextSecondary)
                Spacer()
                Text(SacredPathFormat.formatDuration(totalSeconds))
                    .font(.subheadline.weight(.bold)).foregroundStyle(Color.spTextPrimary)
            }
            .listRowBackground(Color.spCardBg)
        }
    }

    private var savedTripsSection: some View {
        Section("Saved Trips") {
            ForEach(store.savedTrips) { trip in
                Button {
                    store.load(trip)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trip.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.spTextPrimary)
                            Text("\(trip.stops.count) stops").font(.caption2).foregroundStyle(Color.spTextSecondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.down.circle").foregroundStyle(Color.spGold)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { store.deleteTrip(trip) } label: { Label("Delete", systemImage: "trash") }
                }
                .listRowBackground(Color.spCardBg)
            }
        }
    }

    private var startBar: some View {
        Group {
            if store.navigationStops.count >= 1 {
                VStack(spacing: 8) {
                    NavigationLink {
                        SacredPathNavigationModeView(stops: store.navigationStops, route: nil,
                                                     profile: TruckProfileStore.shared.profile)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "location.north.line.fill")
                            Text(store.navigationStops.count == 1 ? "Start Navigation" : "Start Trip (\(store.navigationStops.count) stops)")
                                .font(.subheadline.weight(.bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(Color.spDarkGreen, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spGold.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    OpenInMapsButtons(stops: store.navigationStops)
                    SacredPathDisclaimer(compact: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color.spCardBg)
                .overlay(Rectangle().fill(Color.spGold.opacity(0.5)).frame(height: 1), alignment: .top)
            }
        }
    }

    private func legLabel(forStopIndex index: Int) -> String? {
        // legs may be offset by 1 when a live-GPS origin was prepended.
        let offset = legs.count == store.stops.count ? 0 : 1
        let legIndex = index - 1 + offset
        guard legs.indices.contains(legIndex) else { return nil }
        let leg = legs[legIndex]
        return "\(Int(leg.miles.rounded())) mi · \(SacredPathFormat.formatDuration(leg.seconds))"
    }

    private func recalcLegs() async {
        guard store.stops.count >= 1 else { legs = []; return }
        isCalculating = true
        legs = await SacredPathTripRouter.legs(for: store.stops, origin: location.coordinate)
        isCalculating = false
    }
}

// MARK: - Add-stop sheet

struct SacredPathAddStopView: View {
    let onAdd: (SacredPathStop) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var location = LocationManager.shared
    @State private var kind: SacredPathStopKind = .delivery
    @State private var query = ""
    @State private var results: [SacredPathStop] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            List {
                Section("Stop type") {
                    Picker("Type", selection: $kind) {
                        ForEach(SacredPathStopKind.allCases) { k in
                            Label(k.title, systemImage: k.symbol).tag(k)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.spGold)
                    .listRowBackground(Color.spCardBg)
                    .onChange(of: kind) { _, newKind in
                        if newKind == .currentLocation {
                            addCurrentLocation()
                        } else if let seed = newKind.searchSeed {
                            query = seed
                            Task { await search() }
                        }
                    }
                }

                if kind != .currentLocation {
                    Section("Search") {
                        HStack {
                            TextField("Address, city, or place", text: $query)
                                .foregroundStyle(Color.spTextPrimary)
                                .submitLabel(.search)
                                .onSubmit { Task { await search() } }
                            if isSearching { ProgressView().tint(Color.spGold) }
                        }
                        .listRowBackground(Color.spCardBg)
                    }

                    Section("Results") {
                        if results.isEmpty {
                            Text("Search for a destination to add it as a \(kind.title.lowercased()) stop.")
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                                .listRowBackground(Color.spCardBg)
                        }
                        ForEach(results) { stop in
                            Button {
                                onAdd(stop)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: kind.symbol).foregroundStyle(kind.tint).frame(width: 24)
                                    Text(stop.name).font(.subheadline).foregroundStyle(Color.spTextPrimary).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").foregroundStyle(Color.spGold)
                                }
                            }
                            .listRowBackground(Color.spCardBg)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.spBackground)
            .navigationTitle("Add Stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(Color.spGold)
                }
            }
            .onAppear { location.startUpdating() }
        }
    }

    private func addCurrentLocation() {
        guard let coordinate = location.coordinate else { return }
        onAdd(SacredPathStop(kind: .currentLocation, name: "Current Location",
                             latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        if let coordinate = location.coordinate {
            request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 400_000, longitudinalMeters: 400_000)
        }
        if let response = try? await MKLocalSearch(request: request).start() {
            results = response.mapItems.compactMap { item in
                let coord = item.placemark.coordinate
                guard CLLocationCoordinate2DIsValid(coord), let name = item.name else { return nil }
                return SacredPathStop(kind: kind, name: name, latitude: coord.latitude, longitude: coord.longitude)
            }
        }
        isSearching = false
    }
}
