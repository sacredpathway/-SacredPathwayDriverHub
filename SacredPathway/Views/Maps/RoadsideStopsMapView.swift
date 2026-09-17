import SwiftUI
import MapKit

/// Whether Sacred Path shows its stops on the map or as a scrollable list.
enum SacredPathMapLayout {
    case map
    case list
}

struct SacredPathMapView: View {
    @EnvironmentObject private var supabase: SupabaseService
    @StateObject private var viewModel = SacredPathMapViewModel()
    @ObservedObject private var location = LocationManager.shared
    @ObservedObject private var store = SacredPathStore.shared
    @ObservedObject private var subscriptions = SubscriptionService.shared
    @State private var showSavedStops = false
    @State private var showNearby = false
    /// Map vs. list presentation of the same (filtered) set of stops.
    @State private var layout: SacredPathMapLayout = .map

    var body: some View {
        ZStack(alignment: .top) {
            Color.spBackground.ignoresSafeArea()

            if layout == .map {
                mapLayer
            }

            VStack(spacing: 8) {
                sacredPathHeader
                layoutToggle
                filterChips
                amenityFilterChips
                statusBar
                if layout == .list {
                    listContent
                }
                Spacer(minLength: 0)
            }
            .padding(12)

            if layout == .map {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            nearbyStopsButton
                            savedStopsButton
                        }
                        Spacer()
                        VStack(spacing: 10) {
                            followToggleButton
                            centerButton
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onAppear {
            viewModel.onAppear()
            syncNearbyReports()
        }
        .onDisappear { viewModel.onDisappear() }
        .onChange(of: location.location?.timestamp) { _, _ in
            viewModel.onLocationUpdate()
            syncNearbyReports()
        }
        .sheet(item: $viewModel.selectedStop) { stop in
            SacredPathPlaceDetailSheet(stop: stop)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSavedStops) {
            SavedSacredPathPlacesView { stop in
                showSavedStops = false
                viewModel.selectedStop = stop
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showNearby) {
            NearbySacredPathPlacesView(
                stops: viewModel.visibleStops,
                location: location.location
            ) { stop in
                showNearby = false
                viewModel.selectedStop = stop
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var mapLayer: some View {
        Map(position: $viewModel.cameraPosition) {
            UserAnnotation()

            ForEach(viewModel.visibleStops) { stop in
                Annotation(stop.name, coordinate: stop.coordinate) {
                    // A Button reliably captures taps inside a MapKit annotation;
                    // .onTapGesture is frequently swallowed by the Map's own
                    // gesture recognizers (this was why tapping a stop didn't
                    // open its detail page).
                    Button {
                        viewModel.selectedStop = stop
                    } label: {
                        SacredPathPin(
                            brand: TruckStopBrand.detect(from: stop.name),
                            category: stop.category,
                            isSaved: store.isSaved(stop),
                            parkingStatus: store.parkingReports[stop.id]?.status
                        )
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        // A real user pan drops follow so the camera stops fighting the driver.
        // DragGesture fires only on touch — never on our programmatic camera
        // animations — so follow is dropped intentionally, not by self-motion.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12).onChanged { _ in
                viewModel.userInteractedWithMap()
            }
        )
        .ignoresSafeArea(edges: .bottom)
    }

    private var sacredPathHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sacred Path")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.spTextPrimary)
            Text("Truck Stop Locator & Trip Planner")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.spGold)
            Text("Find truck stops, fuel, rest areas, scales, and parking. Start in-app Sacred Path navigation when you are ready.")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SacredPathDisclaimer(compact: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.spGold.opacity(0.25), lineWidth: 1))
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SacredPathCategory.allCases) { category in
                    Button {
                        withAnimation(.spring(duration: 0.2)) {
                            viewModel.toggle(category)
                        }
                    } label: {
                        Label(category.shortTitle, systemImage: category.systemImage)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(viewModel.activeCategories.contains(category) ? .white : Color.spTextPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(viewModel.activeCategories.contains(category) ? Color.spDarkGreen : Color.spCardBg)
                            )
                            .overlay(
                                Capsule().stroke(Color.spGold.opacity(0.45), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 1)
        }
    }

    /// Amenity narrowing chips (Showers / DEF / Food / Overnight Parking). Gold
    /// fill when active to visually separate them from the green category chips.
    private var amenityFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SacredPathAmenityFilter.allCases) { filter in
                    let isOn = viewModel.activeAmenityFilters.contains(filter)
                    Button {
                        withAnimation(.spring(duration: 0.2)) {
                            viewModel.toggleAmenity(filter)
                        }
                    } label: {
                        Label(filter.title, systemImage: filter.systemImage)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(isOn ? Color.spDarkGreen : Color.spTextPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(isOn ? Color.spGold : Color.spCardBg)
                            )
                            .overlay(
                                Capsule().stroke(Color.spGold.opacity(0.45), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(filter.title) filter")
                    .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : [.isButton])
                }
            }
            .padding(.horizontal, 1)
        }
    }

    /// Map vs. List switch. Both views read the same filtered `visibleStops`,
    /// so category + amenity chips apply to the list exactly as they do the map.
    private var layoutToggle: some View {
        Picker("View", selection: $layout) {
            Label("Map", systemImage: "map.fill").tag(SacredPathMapLayout.map)
            Label("List", systemImage: "list.bullet").tag(SacredPathMapLayout.list)
        }
        .pickerStyle(.segmented)
    }

    /// Distance-sorted list of the currently visible stops (truck stops, rest
    /// areas, parking, fuel, scales, repair — whatever the chips allow). Tapping
    /// a row opens the same detail sheet as a map pin.
    @ViewBuilder
    private var listContent: some View {
        let sorted = viewModel.visibleStops.sorted {
            ($0.distanceMiles(from: location.location) ?? .greatestFiniteMagnitude) <
            ($1.distanceMiles(from: location.location) ?? .greatestFiniteMagnitude)
        }
        if sorted.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: viewModel.isSearching ? "mappin.and.ellipse" : "mappin.slash")
                    .font(.largeTitle)
                    .foregroundStyle(Color.spTextSecondary)
                Text(viewModel.isSearching
                     ? "Finding stops near you…"
                     : "No stops match your filters here. Try turning chips off or moving the map.")
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(sorted) { stop in
                    Button {
                        viewModel.selectedStop = stop
                    } label: {
                        listRow(stop)
                    }
                    .listRowBackground(Color.spCardBg)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func listRow(_ stop: SacredPathPlace) -> some View {
        HStack(spacing: 12) {
            Image(systemName: stop.category.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.spDarkGreen))
                .overlay(Circle().stroke(Color.spGold.opacity(0.5), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                    .lineLimit(1)
                Text(stop.category.title)
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .lineLimit(1)
                if !stop.amenities.isEmpty {
                    Text(stop.amenities.prefix(4).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 4) {
                if let miles = stop.distanceMiles(from: location.location) {
                    Text(String(format: "%.0f mi", miles))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.spGold)
                }
                if store.isSaved(stop) {
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.spGold)
                }
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusBar: some View {
        if viewModel.isSearching || viewModel.message != nil {
            HStack(spacing: 8) {
                if viewModel.isSearching {
                    ProgressView().tint(Color.spGold)
                } else {
                    Image(systemName: location.isDenied ? "location.slash.fill" : "info.circle.fill")
                        .foregroundStyle(Color.spGold)
                }
                Text(viewModel.isSearching ? "Exploring Sacred Path nearby..." : viewModel.message ?? "")
                    .font(.caption)
                    .foregroundStyle(Color.spTextPrimary)
                    .lineLimit(3)
                Spacer(minLength: 0)
                if location.isDenied {
                    Button("Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spGold)
                }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.spGold.opacity(0.25), lineWidth: 1))
        }
    }

    private var nearbyStopsButton: some View {
        Button {
            showNearby = true
        } label: {
            Label("Nearby Stops", systemImage: "list.bullet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.spDarkGreen.opacity(0.92), in: Capsule())
                .overlay(Capsule().stroke(Color.spGold.opacity(0.6), lineWidth: 1))
        }
        .accessibilityLabel("Show nearby stops list")
    }

    private var savedStopsButton: some View {
        Button {
            showSavedStops = true
        } label: {
            Label("Saved Places", systemImage: "bookmark.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.spBlack.opacity(0.78), in: Capsule())
                .overlay(Capsule().stroke(Color.spGold.opacity(0.6), lineWidth: 1))
        }
    }

    /// Recenter — re-enables follow and snaps back onto the truck. Pulses gold
    /// while the driver has panned away (follow off) to invite a tap.
    private var centerButton: some View {
        Button {
            viewModel.recenter()
        } label: {
            Image(systemName: viewModel.followMode ? "location.fill" : "location.north.line.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(11)
                .background(viewModel.followMode ? Color.spDarkGreen : Color.spGold, in: Circle())
                .overlay(Circle().stroke(Color.spGold.opacity(0.6), lineWidth: 1))
        }
            .accessibilityLabel(viewModel.followMode ? "Centered on truck" : "Recenter on truck")
    }

    /// Follow Truck toggle — turns continuous truck-follow on/off explicitly.
    private var followToggleButton: some View {
        Button {
            if viewModel.followMode {
                viewModel.followMode = false
            } else {
                viewModel.recenter()
            }
        } label: {
            Label(viewModel.followMode ? "Following" : "Follow Truck",
                  systemImage: viewModel.followMode ? "scope" : "location.viewfinder")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background((viewModel.followMode ? Color.spDarkGreen : Color.spBlack.opacity(0.78)), in: Capsule())
                .overlay(Capsule().stroke(Color.spGold.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Toggle Follow Truck mode")
    }

    private func syncNearbyReports() {
        Task {
            await store.syncIfPossible(
                supabase: supabase,
                role: subscriptions.entitledAccountRole,
                center: location.coordinate,
                radiusMeters: 80_000
            )
        }
    }
}

private struct SacredPathPin: View {
    let brand: TruckStopBrand?
    let category: SacredPathCategory
    let isSaved: Bool
    let parkingStatus: ParkingReportStatus?

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Image(systemName: category.systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(brand != nil ? 7 : 9)
                    .background(Circle().fill(pinColor))
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: brand != nil ? 2 : 1.2))

                if isSaved {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.spGoldLight)
                        .padding(3)
                        .background(Circle().fill(Color.spBlack.opacity(0.85)))
                        .offset(x: 5, y: -5)
                }

                if let parkingStatus {
                    Image(systemName: parkingStatus.systemImage)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(parkingColor(parkingStatus))
                        .padding(3)
                        .background(Circle().fill(Color.spBlack.opacity(0.85)))
                        .offset(x: -9, y: 9)
                }
            }

            // Brand name shown as TEXT (nominative use). No trademarked logo
            // artwork is rendered — see TruckStopBrand for the legal note.
            if let brand {
                Text(brand.label)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(pinColor))
                    .fixedSize()
            }
        }
    }

    private var pinColor: Color {
        if let brand {
            let c = brand.rgb
            return Color(red: c.r, green: c.g, blue: c.b)
        }
        switch category {
        case .truckStops: return Color.spDarkGreen
        case .restAreas: return Color.spGreenAccent
        case .fuel: return Color.spGold
        case .scales: return Color.spWarning
        case .weighStations: return Color.spDanger
        case .parking: return Color.blue
        case .repair: return Color.gray
        case .hotels: return Color.purple
        }
    }

    private func parkingColor(_ status: ParkingReportStatus) -> Color {
        switch status {
        case .available: return Color.spGreenAccent
        case .limited: return Color.spWarning
        case .full: return Color.spDanger
        case .unknown: return Color.spTextSecondary
        }
    }
}

private struct SacredPathPlaceDetailSheet: View {
    let stop: SacredPathPlace
    @EnvironmentObject private var supabase: SupabaseService
    @ObservedObject private var location = LocationManager.shared
    @ObservedObject private var store = SacredPathStore.shared
    @ObservedObject private var subscriptions = SubscriptionService.shared
    @State private var reportNotes = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(stop.category.title, systemImage: stop.category.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.spGold)
                        Text(stop.name)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Color.spTextPrimary)
                        Text(distanceText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.spCardBg)

                Section("Details") {
                    detailRow("mappin.and.ellipse", stop.address)
                    detailRow("clock.fill", stop.openStatus ?? "Hours unavailable")
                    if !stop.amenities.isEmpty {
                        detailRow("checklist", stop.amenities.joined(separator: ", "))
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Parking Report") {
                    TextField("Optional notes", text: $reportNotes, axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.sentences)
                        .foregroundStyle(Color.spTextPrimary)

                    ForEach(ParkingReportStatus.allCases) { status in
                        Button {
                            Task {
                                await store.reportParking(
                                    status,
                                    notes: reportNotes,
                                    for: stop,
                                    supabase: supabase,
                                    role: subscriptions.entitledAccountRole
                                )
                            }
                        } label: {
                            HStack {
                                Label(status.title, systemImage: status.systemImage)
                                Spacer()
                                if store.parkingReports[stop.id]?.status == status {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.spGold)
                                }
                            }
                        }
                        .foregroundStyle(Color.spTextPrimary)
                    }

                    if let report = store.parkingReports[stop.id] {
                        Text("Latest community report: \(report.status.title) at \(report.updatedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                        if let summary = store.parkingReportSummaries[stop.id] {
                            Text(summaryText(summary))
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                        if let notes = report.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section {
                    // Start in-app Sacred Path navigation.
                    OpenInMapsMenu(
                        name: stop.name,
                        latitude: stop.latitude,
                        longitude: stop.longitude
                    )

                    Button {
                        Task {
                            if store.isSaved(stop) {
                                await store.remove(stop, supabase: supabase)
                            } else {
                                await store.save(stop, supabase: supabase, role: subscriptions.entitledAccountRole)
                            }
                        }
                    } label: {
                        Label(store.isSaved(stop) ? "Remove Saved Place" : "Save Place",
                              systemImage: store.isSaved(stop) ? "bookmark.slash.fill" : "bookmark.fill")
                            .frame(maxWidth: .infinity)
                    }

                    SacredPathDisclaimer(compact: true)
                }
                .font(.headline)
                .listRowBackground(Color.spCardBg)
            }
            .scrollContentBackground(.hidden)
            .background(Color.spBackground)
            .navigationTitle("Sacred Path")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Color.spGold)
    }

    private var distanceText: String {
        guard let miles = stop.distanceMiles(from: location.location) else {
            return "Distance unavailable"
        }
        return String(format: "%.1f miles away", miles)
    }

    private func detailRow(_ image: String, _ text: String) -> some View {
        Label {
            Text(text)
                .foregroundStyle(Color.spTextPrimary)
        } icon: {
            Image(systemName: image)
                .foregroundStyle(Color.spGold)
        }
    }

    private func summaryText(_ summary: SacredPathParkingReportSummary) -> String {
        "\(summary.totalReports) recent report\(summary.totalReports == 1 ? "" : "s") · Plenty \(summary.availableCount) · Some \(summary.limitedCount) · Full \(summary.fullCount) · Unknown \(summary.unknownCount)"
    }
}

private struct SavedSacredPathPlacesView: View {
    @EnvironmentObject private var supabase: SupabaseService
    @ObservedObject private var store = SacredPathStore.shared
    let onSelect: (SacredPathPlace) -> Void

    var body: some View {
        NavigationStack {
            List {
                if store.savedStops.isEmpty {
                    ContentUnavailableView(
                        "No Saved Places",
                        systemImage: "bookmark",
                        description: Text("Places you save from Sacred Path will show up here.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(store.savedStops) { stop in
                        Button {
                            onSelect(stop)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: stop.category.systemImage)
                                    .foregroundStyle(Color.spGold)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(stop.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.spTextPrimary)
                                    Text(stop.category.title)
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                    Text(stop.address)
                                        .font(.caption2)
                                        .foregroundStyle(Color.spTextSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.spTextSecondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task {
                                    await store.remove(stop, supabase: supabase)
                                }
                            } label: {
                                Label("Remove", systemImage: "trash.fill")
                            }
                        }
                        .listRowBackground(Color.spCardBg)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.spBackground)
            .navigationTitle("Saved Places")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Color.spGold)
    }
}

/// A guaranteed-reliable path from a stop to its detail sheet: a distance-sorted
/// list of the currently visible stops. Tapping a row opens the same detail
/// sheet as tapping a map marker — so even if a marker tap is ever missed, the
/// driver always has a working way in.
private struct NearbySacredPathPlacesView: View {
    let stops: [SacredPathPlace]
    let location: CLLocation?
    let onSelect: (SacredPathPlace) -> Void

    private var sorted: [SacredPathPlace] {
        guard let location else { return stops }
        return stops.sorted {
            ($0.distanceMiles(from: location) ?? .greatestFiniteMagnitude) <
            ($1.distanceMiles(from: location) ?? .greatestFiniteMagnitude)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if sorted.isEmpty {
                    ContentUnavailableView(
                        "No Nearby Stops",
                        systemImage: "mappin.slash",
                        description: Text("Move the map or check location access to find stops along your route.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(sorted) { stop in
                        Button {
                            onSelect(stop)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: stop.category.systemImage)
                                    .foregroundStyle(Color.spGold)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(stop.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.spTextPrimary)
                                    Text(stop.category.title)
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                }
                                Spacer()
                                if let miles = stop.distanceMiles(from: location) {
                                    Text(String(format: "%.0f mi", miles))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.spTextSecondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.spTextSecondary)
                            }
                        }
                        .listRowBackground(Color.spCardBg)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.spBackground)
            .navigationTitle("Nearby Stops")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Color.spGold)
    }
}

#Preview {
    SacredPathMapView()
}
