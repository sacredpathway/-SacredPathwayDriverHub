import SwiftUI
import MapKit
import CoreLocation
import Combine
import WebKit

// =============================================================================
// MARK: - Sacred Path route preview (planning only, GPS-free)
// -----------------------------------------------------------------------------
// This screen is a trip-planning preview: it shows the driver the route line,
// distance, estimated drive time, and trucking resources, then starts in-app
// Sacred Path navigation when the driver is ready.
//
//   * SacredPathRouteModel        — MKDirections used ONLY to draw a preview
//                                   line + estimate distance/time (no guidance)
//   * SacredPathRoutePreviewView  — preview map + in-app navigation action
//
// `SacredPathDestination`, `SacredPathFormat`, `SacredPathExternalMaps`,
// `OpenInMapsButtons`, and `SacredPathDisclaimer` live in SacredPathSupport
// (the former support file).
// =============================================================================

@MainActor
final class SacredPathRouteModel: ObservableObject {
    @Published var routePolyline: MKPolyline?
    @Published var distanceMiles: Double?
    @Published var etaText: String?
    @Published var isLoading = false
    @Published var errorText: String?
    /// Trucking resources found along the planned route.
    @Published var alongRouteStops: [SacredPathPlace] = []
    @Published var isLoadingStops = false

    /// Computes a multi-leg preview route (current location → each stop in order)
    /// to draw the line and estimate distance/time, then finds trucking
    /// resources along it. Planning information only — Driver Hub does not guide.
    func computeRoute(from origin: CLLocationCoordinate2D?, through stops: [SacredPathDestination]) async {
        guard let origin, !stops.isEmpty else {
            errorText = "Waiting for your current location…"
            return
        }
        isLoading = true
        errorText = nil

        let points = [origin] + stops.map { $0.coordinate }
        var combined: [CLLocationCoordinate2D] = []
        var totalDistance: CLLocationDistance = 0
        var totalTime: TimeInterval = 0
        var anyLeg = false

        for index in 0..<(points.count - 1) {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: points[index]))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: points[index + 1]))
            request.transportType = .automobile
            if let route = try? await MKDirections(request: request).calculate().routes.first {
                combined.append(contentsOf: route.polyline.sacredPathCoordinates())
                totalDistance += route.distance
                totalTime += route.expectedTravelTime
                anyLeg = true
            }
        }

        if anyLeg, combined.count > 1 {
            routePolyline = MKPolyline(coordinates: combined, count: combined.count)
            distanceMiles = totalDistance / 1609.344
            etaText = SacredPathFormat.formatDuration(totalTime)
            isLoading = false
            await searchAlongRoute(combined)
        } else {
            errorText = "No drivable route found to those stops."
            isLoading = false
        }
    }

    /// Samples points along the route and searches each for truck stops, fuel,
    /// rest areas, and parking. Results publish progressively as the scan walks
    /// the route, so pins appear without waiting for the whole sweep.
    private func searchAlongRoute(_ coords: [CLLocationCoordinate2D]) async {
        isLoadingStops = true
        defer { isLoadingStops = false }

        let samples = Self.sample(coords, spacingMeters: 64_000, maxSamples: 7)
        // Useful driver stops along the way: truck stops, fuel, rest areas,
        // parking/safe stops, and hotels/lodging.
        let categories: [SacredPathCategory] = [.truckStops, .fuel, .restAreas, .parking, .hotels]
        var found: [SacredPathPlace] = []
        var seen = Set<String>()

        for center in samples {
            let region = MKCoordinateRegion(center: center, latitudinalMeters: 24_000, longitudinalMeters: 24_000)
            for category in categories {
                guard let query = category.searchQueries.first else { continue }
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                request.region = region
                request.resultTypes = .pointOfInterest
                guard let response = try? await MKLocalSearch(request: request).start() else { continue }
                for item in response.mapItems.prefix(4) {
                    guard let place = SacredPathPlace(mapItem: item, category: category),
                          !seen.contains(place.id) else { continue }
                    seen.insert(place.id)
                    found.append(place)
                }
            }
            alongRouteStops = Array(found.prefix(120))
        }
    }

    /// Points spaced ~`spacingMeters` apart along the route (plus the far end).
    static func sample(_ coords: [CLLocationCoordinate2D], spacingMeters: CLLocationDistance, maxSamples: Int) -> [CLLocationCoordinate2D] {
        guard let first = coords.first else { return [] }
        var result: [CLLocationCoordinate2D] = [first]
        var last = CLLocation(latitude: first.latitude, longitude: first.longitude)
        for coord in coords.dropFirst() {
            let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            if loc.distance(from: last) >= spacingMeters {
                result.append(coord)
                last = loc
                if result.count >= maxSamples { break }
            }
        }
        if let end = coords.last, result.count < maxSamples,
           CLLocation(latitude: end.latitude, longitude: end.longitude).distance(from: last) > spacingMeters / 2 {
            result.append(end)
        }
        return result
    }
}

// =============================================================================
// MARK: - Route preview (custom along-route map)
// =============================================================================

struct SacredPathRoutePreviewView: View {
    let stops: [SacredPathDestination]
    let currentPlaceName: String

    @ObservedObject private var location = LocationManager.shared
    @StateObject private var model = SacredPathRouteModel()
    @State private var camera: MapCameraPosition = .automatic
    @State private var activeCategories: Set<SacredPathCategory> = [.truckStops, .fuel, .restAreas, .parking, .hotels]
    @State private var selectedStop: SacredPathPlace?

    init(stops: [SacredPathDestination], currentPlaceName: String) {
        self.stops = stops
        self.currentPlaceName = currentPlaceName
    }

    /// Convenience for a single destination.
    init(destination: SacredPathDestination, currentPlaceName: String) {
        self.stops = [destination]
        self.currentPlaceName = currentPlaceName
    }

    private var visibleAlongRoute: [SacredPathPlace] {
        model.alongRouteStops.filter { activeCategories.contains($0.category) }
    }

    var body: some View {
        VStack(spacing: 0) {
            mapLayer
            filterBar
            controls
        }
        .background(Color.spBackground)
        .navigationTitle("Trip Preview")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { location.startUpdating() }
        .task {
            await model.computeRoute(from: location.coordinate, through: stops)
        }
        .onChange(of: model.routePolyline != nil) { _, hasRoute in
            // Frame the whole route once it's ready so the streaming along-route
            // pins don't keep re-zooming the map.
            if hasRoute, let rect = model.routePolyline?.boundingMapRect {
                let padded = rect.insetBy(dx: -rect.size.width * 0.2, dy: -rect.size.height * 0.2)
                withAnimation { camera = .rect(padded) }
            }
        }
        .sheet(item: $selectedStop) { stop in
            alongStopSheet(stop)
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
        }
    }

    private var mapLayer: some View {
        Map(position: $camera) {
            UserAnnotation()

            if let polyline = model.routePolyline {
                MapPolyline(polyline)
                    .stroke(Color.spGold, lineWidth: 6)
            }

            // The driver's chosen stops: waypoints numbered gold, destination red.
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                Marker(
                    stop.name,
                    systemImage: index == stops.count - 1 ? "flag.checkered" : "\(index + 1).circle.fill",
                    coordinate: stop.coordinate
                )
                .tint(index == stops.count - 1 ? Color.spDanger : Color.spGold)
            }

            // Trucking resources discovered along the route.
            ForEach(visibleAlongRoute) { place in
                Annotation(place.name, coordinate: place.coordinate) {
                    Button {
                        selectedStop = place
                    } label: {
                        Image(systemName: place.category.systemImage)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Circle().fill(categoryColor(place.category)))
                            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if model.isLoadingStops {
                HStack(spacing: 6) {
                    ProgressView().tint(Color.spGold)
                    Text("Finding stops…")
                        .font(.caption2)
                        .foregroundStyle(Color.spTextPrimary)
                }
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(10)
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([SacredPathCategory.truckStops, .fuel, .restAreas, .parking, .hotels], id: \.self) { category in
                    let on = activeCategories.contains(category)
                    Button {
                        withAnimation(.spring(duration: 0.2)) {
                            if on { activeCategories.remove(category) } else { activeCategories.insert(category) }
                        }
                    } label: {
                        Label(category.shortTitle, systemImage: category.systemImage)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(on ? .white : Color.spTextPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(on ? categoryColor(category) : Color.spCardBg))
                            .overlay(Capsule().stroke(Color.spGold.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(Color.spBackground)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            endpointRow(icon: "dot.circle.and.cursorarrow", tint: Color.spGreenAccent,
                        title: "From", value: currentPlaceName)
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                let isDestination = index == stops.count - 1
                endpointRow(
                    icon: isDestination ? "mappin.circle.fill" : "smallcircle.filled.circle.fill",
                    tint: isDestination ? Color.spDanger : Color.spGold,
                    title: isDestination ? "To" : "Stop \(index + 1)",
                    value: stop.name
                )
            }

            if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView().tint(Color.spGold)
                    Text("Estimating your trip…")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
            } else if let error = model.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.spWarning)
            } else {
                HStack(spacing: 18) {
                    metric(model.distanceMiles.map { "\(Int($0.rounded()))" } ?? "—", "miles")
                    metric(model.etaText ?? "—", "est. drive time")
                    if !model.alongRouteStops.isEmpty {
                        metric("\(model.alongRouteStops.count)", "stops on route")
                    }
                }
            }

            // In-app turn-by-turn truck GPS.
            NavigationLink {
                SacredPathNavigationModeView(stops: stops, route: nil, profile: TruckProfileStore.shared.profile)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "location.north.line.fill")
                    Text("Start Navigation")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .foregroundStyle(.white)
                .background(Color.spDarkGreen, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spGold.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)

            // Or start in-app navigation from the preview.
            OpenInMapsButtons(stops: stops)

            SacredPathDisclaimer()
        }
        .padding(16)
        .background(Color.spCardBg)
    }

    private func alongStopSheet(_ stop: SacredPathPlace) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: stop.category.systemImage)
                    .foregroundStyle(.white)
                    .padding(9)
                    .background(Circle().fill(categoryColor(stop.category)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(stop.name)
                        .font(.headline)
                        .foregroundStyle(Color.spTextPrimary)
                        .lineLimit(2)
                    Text(stop.category.title)
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                Spacer()
            }

            if !stop.amenities.isEmpty {
                Text(stop.amenities.prefix(5).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }

            OpenInMapsButtons(stops: [SacredPathDestination(name: stop.name, latitude: stop.latitude, longitude: stop.longitude)])

            SacredPathDisclaimer(compact: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.spBackground)
    }

    private func categoryColor(_ category: SacredPathCategory) -> Color {
        switch category {
        case .truckStops: return Color.spDarkGreen
        case .fuel: return Color.spGold
        case .restAreas: return Color.spGreenAccent
        case .parking: return Color.blue
        case .hotels: return Color.purple
        default: return Color.spDarkGreen
        }
    }

    private func endpointRow(icon: String, tint: Color, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                    .lineLimit(1)
            }
            Spacer()
        }
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
}

#Preview {
    NavigationStack {
        SacredPathRoutePreviewView(
            stops: [SacredPathDestination(name: "Dallas, TX", latitude: 32.7767, longitude: -96.7970)],
            currentPlaceName: "Oklahoma City, OK"
        )
    }
}


// =============================================================================
// MARK: - In-app navigation driving screen (restored)
// =============================================================================

struct SacredPathNavigationModeView: View {
    @StateObject private var engine: SacredPathNavigationEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAIActions = false
    @State private var aiResult: String?
    @State private var satelliteLayer = false
    @State private var showRouteMarkers = true
    #if DEBUG
    @State private var showDebug = false
    #endif

    init(destination: SacredPathDestination, route: SacredPathNavigationRoute?, profile: SacredPathTruckProfile = .defaultOwnerOperator) {
        _engine = StateObject(wrappedValue: SacredPathNavigationEngine(destination: destination, route: route, profile: profile))
    }

    init(stops: [SacredPathDestination], route: SacredPathNavigationRoute?, profile: SacredPathTruckProfile = .defaultOwnerOperator) {
        _engine = StateObject(wrappedValue: SacredPathNavigationEngine(stops: stops, route: route, profile: profile))
    }

    var body: some View {
        ZStack {
            mapLayer

            GeometryReader { proxy in
                navigationChrome(screenWidth: proxy.size.width, screenHeight: proxy.size.height)
            }

            #if DEBUG
            if let warning = SacredPathTileProvider.active.debugWarning {
                missingTileKeyWarning(warning)
            }
            if showDebug { debugOverlay }
            debugToggle
            #endif
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { engine.resyncOnResume() }
        }
        .confirmationDialog("Sacred Path AI", isPresented: $showAIActions, titleVisibility: .visible) {
            Button("Reroute now") {
                engine.requestReroute()
                aiResult = "Rerouting from your current location."
            }
            Button("Find truck parking") {
                aiResult = engine.nearestPOI(.parking).map { "Nearest truck parking: \($0.name), \($0.distanceText) ahead." }
                    ?? "No truck parking found nearby yet."
            }
            Button("Find fuel") {
                aiResult = engine.nearestPOI(.fuel).map { "Nearest fuel: \($0.name), \($0.distanceText) ahead." }
                    ?? "No fuel stops found nearby yet."
            }
            Button("Explain delay") {
                aiResult = engine.isRerouting
                    ? "Recalculating your route due to a recent change."
                    : "No major delays detected on your current route."
            }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Sacred Path AI", isPresented: Binding(get: { aiResult != nil }, set: { if !$0 { aiResult = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(aiResult ?? "")
        }
    }

    #if DEBUG
    private var debugOverlay: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("spd \(engine.speedMph) mph")
            Text(String(format: "crs %.0f°", engine.debugCourse))
            Text(String(format: "hdg %.0f°", engine.displayHeadingDeg))
            Text(String(format: "cam %.0f°", engine.debugCameraHeadingDeg))
            Text(String(format: "rot %.0f°", engine.truckRotationDeg))
            Text(String(format: "acc %.0fm", engine.debugAccuracy))
            Text("rr: \(engine.lastRerouteReason)")
            Text("sim: \(engine.isSimulationRunning ? "on" : "off")")
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(6)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 86)
        .padding(.trailing, 10)
        .allowsHitTesting(false)
    }

    private var debugToggle: some View {
        VStack(spacing: 6) {
            Button { showDebug.toggle() } label: {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(6)
                    .background(Color.black.opacity(0.4), in: Circle())
            }
            Button { engine.toggleRouteSimulation() } label: {
                Image(systemName: engine.isSimulationRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(6)
                    .background(Color.black.opacity(0.4), in: Circle())
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 86)
        .padding(.leading, 10)
    }
    #endif

    // Non-Apple/non-Google active trucking map. MapLibre GL renders production
    // tiles inside Driver Hub; native GPS/route state feeds it.
    private var mapLayer: some View {
        SacredPathActiveTruckMapView(engine: engine, provider: .mapLibre, showRouteMarkers: showRouteMarkers)
            .ignoresSafeArea()
    }

    #if DEBUG
    private func missingTileKeyWarning(_ warning: String) -> some View {
        Text(warning)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.black)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.spGold.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.15), lineWidth: 1)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 86)
            .padding(.horizontal, 72)
            .allowsHitTesting(false)
    }
    #endif

    // MARK: Truck GPS chrome

    private func navigationChrome(screenWidth: CGFloat, screenHeight: CGFloat) -> some View {
        let landscape = screenWidth > screenHeight
        let bannerHeight: CGFloat = landscape ? 92 : 164
        let bottomHeight: CGFloat = landscape ? 68 : 118
        let sideInset: CGFloat = landscape ? 12 : 18

        return ZStack {
            topManeuverBanner(screenWidth: screenWidth, bannerHeight: bannerHeight, compact: landscape)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)

            compassButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, bannerHeight + (landscape ? 8 : 18))
                .padding(.leading, sideInset)

            if engine.followMode {
                leftServiceStack(compact: landscape)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: landscape ? .topLeading : .bottomLeading)
                    .padding(.leading, sideInset)
                    .padding(.top, landscape ? bannerHeight + 70 : 0)
                    .padding(.bottom, landscape ? 0 : bottomHeight + 16)

                if !landscape {
                    speedBox
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, sideInset)
                        .padding(.bottom, bottomHeight + 18)
                }
            } else {
                overviewLeftTools(compact: landscape)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, bannerHeight + (landscape ? 68 : 108))
                    .padding(.leading, sideInset)

                recenterButton(compact: landscape)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, bottomHeight + 26)

                hereScaleMark
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 24)
                    .padding(.bottom, bottomHeight + 104)

                rightTopTools(compact: landscape)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, bannerHeight + (landscape ? 8 : 18))
                    .padding(.trailing, sideInset)

                zoomStack(compact: landscape)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, sideInset)
            }

            rightActionStack(compact: landscape)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: landscape ? .topTrailing : .bottomTrailing)
                .padding(.trailing, sideInset)
                .padding(.top, landscape ? bannerHeight + 8 : 0)
                .padding(.bottom, landscape ? 0 : bottomHeight + 24)

            bottomArea(compact: landscape)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, landscape ? 18 : 0)
                .padding(.bottom, 0)
        }
    }

    private func overviewLeftTools(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 16) {
            overviewToolButton(icon: "line.3.horizontal.decrease", title: "Filters") {
                showAIActions = true
            }
            overviewToolButton(icon: showRouteMarkers ? "eye.slash.fill" : "eye.fill", title: showRouteMarkers ? "Hide" : "Show") {
                showRouteMarkers.toggle()
            }
            overviewToolButton(icon: "arrow.clockwise", title: "Reroute") {
                engine.requestReroute()
            }
        }
    }

    private func overviewToolButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .heavy))
                    .frame(height: 19)
                Text(title)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(width: 66, height: 54)
            .background(Color(red: 0.20, green: 0.20, blue: 0.20).opacity(0.96), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 5, y: 3)
        }
        .buttonStyle(.plain)
    }

    private func rightTopTools(compact: Bool) -> some View {
        VStack(spacing: compact ? 10 : 24) {
            railButton(satelliteLayer ? "satellite.fill" : "satellite", tint: .white) {
                satelliteLayer.toggle()
            }
            railButton(engine.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill", tint: .white) {
                engine.voiceEnabled.toggle()
            }
        }
    }

    private func zoomStack(compact: Bool) -> some View {
        VStack(spacing: 0) {
            Button { engine.zoomIn() } label: {
                Text("+")
                    .font(.system(size: compact ? 34 : 46, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 66, height: compact ? 56 : 72)
            }
            Divider()
                .frame(width: 58)
                .overlay(Color.white.opacity(0.4))
            Button { engine.zoomOut() } label: {
                Text("-")
                    .font(.system(size: compact ? 34 : 46, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 66, height: compact ? 56 : 72)
            }
        }
        .buttonStyle(.plain)
        .background(Color(red: 0.20, green: 0.20, blue: 0.20).opacity(0.96), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 5, y: 3)
    }

    private func recenterButton(compact: Bool) -> some View {
        Button {
            engine.recenter()
        } label: {
            Text("RE-CENTER")
                .font(.system(size: compact ? 20 : 27, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.36, green: 0.58, blue: 1.0))
                .padding(.horizontal, compact ? 22 : 34)
                .frame(height: compact ? 52 : 66)
                .background(Color(red: 0.20, green: 0.20, blue: 0.20).opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.30), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
    }

    private var hereScaleMark: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("299 mi")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Rectangle()
                .fill(Color.white)
                .frame(width: 58, height: 2)
            Text("Here")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .rotationEffect(.degrees(-42))
                .foregroundStyle(.white.opacity(0.88))
        }
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        .allowsHitTesting(false)
    }

    private func topManeuverBanner(screenWidth: CGFloat, bannerHeight: CGFloat, compact: Bool) -> some View {
        HStack(alignment: .center, spacing: compact ? 12 : 24) {
            Image(systemName: engine.maneuverSymbol)
                .font(.system(size: compact ? 34 : 64, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: compact ? 46 : 76)
                .minimumScaleFactor(0.65)

            VStack(alignment: .leading, spacing: compact ? 3 : 8) {
                Text(bannerDistanceText)
                    .font(.system(size: compact ? 27 : 50, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(roadOrInstruction)
                    .font(.system(size: compact ? 17 : 27, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: compact ? 10 : 16) {
                endNavigationButton
                Button {
                    engine.voiceEnabled.toggle()
                } label: {
                    Image(systemName: engine.voiceEnabled ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: compact ? 18 : 27, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: compact ? 32 : 44, height: compact ? 32 : 44)
                        .background(Color.white.opacity(0.001), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(engine.voiceEnabled ? "Mute voice guidance" : "Unmute voice guidance")

                if engine.isRerouting { reroutingPill }
            }
        }
        .padding(.top, compact ? 10 : 42)
        .padding(.horizontal, compact ? 14 : 24)
        .padding(.bottom, compact ? 8 : 18)
        .frame(width: screenWidth, height: bannerHeight, alignment: .center)
        .background(
            LinearGradient(
                colors: [Color.black, Color(red: 0.19, green: 0.19, blue: 0.19)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
    }

    private var roadOrInstruction: String {
        let road = engine.currentRoadName.trimmingCharacters(in: .whitespaces)
        return road.isEmpty ? engine.primaryInstruction : road
    }

    private var bannerDistanceText: String {
        let raw = engine.distanceToManeuverText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.replacingOccurrences(of: ",", with: "")
        guard normalized.lowercased().hasSuffix("mi") else { return raw }
        let numberText = normalized.replacingOccurrences(of: "mi", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let miles = Double(numberText), miles >= 100 else { return raw }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let rounded = NSNumber(value: Int(miles.rounded()))
        return "\(formatter.string(from: rounded) ?? "\(Int(miles.rounded()))") mi"
    }

    private var voiceButton: some View {
        Button {
            engine.voiceEnabled.toggle()
        } label: {
            Image(systemName: engine.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(11)
                .background(Color.spDarkGreen.opacity(0.92), in: Circle())
                .overlay(Circle().stroke(Color.spGold.opacity(0.5), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var reroutingPill: some View {
        HStack(spacing: 8) {
            ProgressView().tint(Color.spGold)
            Text("Rerouting…")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
    }

    private var endNavigationButton: some View {
        Button {
            engine.stop()
            dismiss()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.heavy))
                Text("End")
                    .font(.caption2.weight(.heavy))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.24), radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End navigation")
    }

    // MARK: Intelligence strip

    private var intelligenceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(engine.upcomingPOIs) { poi in
                    HStack(spacing: 8) {
                        Image(systemName: poi.kind.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(poiTint(poi.kind))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(poi.kind.title)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.spTextSecondary)
                            Text(poi.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.spTextPrimary)
                                .lineLimit(1)
                        }
                        Text(poi.distanceText)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(poiTint(poi.kind))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.spCardBg, in: Capsule())
                    .overlay(Capsule().stroke(Color.spGold.opacity(0.22), lineWidth: 1))
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private func poiTint(_ kind: SacredPathPOIKind) -> Color {
        switch kind {
        case .fuel:     return Color.spGold
        case .parking:  return Color.spGreenAccent
        case .restArea: return Color.spGreenAccent
        case .scales:   return Color.spWarning
        case .service:  return Color.spTextSecondary
        case .weather:  return Color.spDanger
        }
    }

    // MARK: Slim bottom tray (speed · limit · miles · ETA)

    private var dashboard: some View {
        HStack(spacing: 0) {
            dashMetric(value: "\(engine.speedMph)", unit: "MPH",
                       highlight: isSpeeding ? Color.spDanger : Color.spGoldLight)
            dashDivider
            dashMetric(value: engine.postedSpeedLimitMph.map { "\($0)" } ?? "--", unit: "LIMIT",
                       highlight: Color.spTextPrimary)
            dashDivider
            dashMetric(value: "\(Int(engine.remainingMiles.rounded()))", unit: "MI LEFT",
                       highlight: Color.spTextPrimary)
            dashDivider
            dashMetric(value: engine.etaText, unit: "ETA",
                       highlight: Color.spGoldLight)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .background(Color.spCardBg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.spGold.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    private var endButton: some View {
        Button {
            engine.stop()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .padding(11)
                .background(Color.spDanger, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End Navigation")
    }

    // MARK: Side controls

    private var compassButton: some View {
        Button {
            engine.recenter()
        } label: {
            ZStack {
                Circle()
                    .fill(Color(red: 0.13, green: 0.14, blue: 0.14).opacity(0.9))
                    .frame(width: 48, height: 48)
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1.4))
                Image(systemName: "location.north.fill")
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .rotationEffect(.degrees(engine.displayHeadingDeg))
                Image(systemName: "triangle.fill")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Color.red)
                    .offset(y: -9)
            }
            .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recenter map")
    }

    private func railButton(_ icon: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(Color(red: 0.20, green: 0.20, blue: 0.20).opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
    }

    private func leftServiceStack(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            serviceDistanceTile(kind: .fuel, badge: "K", fallbackMiles: 39)
            serviceDistanceTile(kind: .parking, badge: "P", fallbackMiles: 42)
            combinedServiceTile(compact: compact)
            moreStopsButton
        }
    }

    private func serviceDistanceTile(kind: SacredPathPOIKind, badge: String, fallbackMiles: Int) -> some View {
        let miles = engine.nearestPOI(kind)?.distanceText ?? "\(fallbackMiles) mi"
        return HStack(spacing: 9) {
            Text(badge)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 25, height: 25)
                .background(Circle().fill(serviceBadgeColor(kind)))
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
            Text(miles.replacingOccurrences(of: " ", with: ""))
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 34)
        .background(Color(red: 0.21, green: 0.21, blue: 0.21).opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.24), radius: 4, y: 2)
    }

    private func combinedServiceTile(compact: Bool) -> some View {
        let miles = engine.nearestPOI(.restArea)?.distanceText ?? "96 mi"
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                miniBadge("T", color: .orange)
                miniBadge("P", color: .cyan)
            }
            Text(miles.replacingOccurrences(of: " ", with: ""))
                .font(.system(size: compact ? 18 : 28, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 6 : 8)
        .frame(width: compact ? 86 : 96, height: compact ? 44 : 62)
        .background(Color(red: 0.21, green: 0.21, blue: 0.21).opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.24), radius: 4, y: 2)
    }

    private var moreStopsButton: some View {
        Button {
            showAIActions = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .heavy))
                Text("More")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color(red: 0.21, green: 0.21, blue: 0.21).opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.24), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More route stops")
    }

    private func rightActionStack(compact: Bool) -> some View {
        VStack(spacing: compact ? 10 : 18) {
            railButton("plus.message.fill", tint: Color.spGold) { showAIActions = true }
            railButton("point.topleft.down.curvedto.point.bottomright.up", tint: .white) { engine.routeOverview() }
            if engine.followMode {
                railButton("location.fill", tint: .white) { engine.recenter() }
            }
        }
    }

    private func miniBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 23, height: 23)
            .background(Circle().fill(color))
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
    }

    private func serviceBadgeColor(_ kind: SacredPathPOIKind) -> Color {
        switch kind {
        case .fuel: return Color.red
        case .parking: return Color.cyan
        case .restArea: return Color.green
        case .scales: return Color.orange
        case .service: return Color.gray
        case .weather: return Color.blue
        }
    }

    private var aiButton: some View {
        Button { showAIActions = true } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(LinearGradient.darkGreen, in: Circle())
                .overlay(Circle().stroke(Color.spGold, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sacred Path AI")
    }

    // MARK: Bottom area (service pills + trip panel + speed box)

    private func bottomArea(compact: Bool) -> some View {
        tripPanel(compact: compact)
    }

    private var servicePills: some View {
        HStack(spacing: 8) {
            servicePill(.fuel)
            servicePill(.parking)
            servicePill(.restArea)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func servicePill(_ kind: SacredPathPOIKind) -> some View {
        if let poi = engine.nearestPOI(kind) {
            HStack(spacing: 5) {
                Image(systemName: kind.symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(poiTint(kind))
                Text(poi.distanceText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.spTextPrimary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.spGold.opacity(0.25), lineWidth: 1))
        }
    }

    private func tripPanel(compact: Bool) -> some View {
        HStack(spacing: compact ? 12 : 20) {
            Image(systemName: "box.truck.fill")
                .font(.system(size: compact ? 25 : 44, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.82))
                .frame(width: compact ? 40 : 72)

            VStack(spacing: compact ? 2 : 5) {
                HStack(spacing: compact ? 6 : 8) {
                    Text("\(Int(engine.remainingMiles.rounded()))mi")
                        .font(.system(size: compact ? 19 : 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    Text("|")
                        .font(.system(size: compact ? 14 : 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(engine.remainingTimeText)
                        .font(.system(size: compact ? 19 : 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
                Text(arrivalSummaryText)
                    .font(.system(size: compact ? 13 : 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }

            Spacer(minLength: 6)

            Button {
                showAIActions = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: compact ? 12 : 20, weight: .heavy))
                    Text("More")
                        .font(.system(size: compact ? 10 : 16, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(Color.black.opacity(0.7))
                .frame(width: compact ? 48 : 70, height: compact ? 42 : 68)
                .background(Color.white.opacity(0.28), in: RoundedRectangle(cornerRadius: compact ? 12 : 16))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, compact ? 10 : 18)
        .padding(.trailing, compact ? 10 : 16)
        .padding(.vertical, compact ? 7 : 16)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.16, green: 0.16, blue: 0.16).opacity(0.98), in: RoundedRectangle(cornerRadius: compact ? 18 : 28, style: .continuous))
        .shadow(color: .black.opacity(0.38), radius: 10, y: -3)
    }

    private var speedBox: some View {
        VStack(spacing: 0) {
            Text("\(engine.speedMph)")
                .font(.system(size: 25, weight: .heavy, design: .rounded))
                .foregroundStyle(isSpeeding ? Color.red : Color.cyan)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("MPH")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 68, height: 68)
        .background(Color(red: 0.20, green: 0.20, blue: 0.20).opacity(0.96), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.26), radius: 5, y: 2)
    }

    private var arrivalSummaryText: String {
        let text = engine.etaText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "--" : text
    }

    private var isSpeeding: Bool {
        guard let limit = engine.postedSpeedLimitMph else { return false }
        return engine.speedMph > limit
    }

    private func dashMetric(value: String, unit: String, highlight: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(highlight)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var dashDivider: some View {
        Rectangle()
            .fill(Color.spGold.opacity(0.2))
            .frame(width: 1, height: 28)
    }
}

@MainActor
final class SacredPathMapDiagnosticsStore: ObservableObject {
    static let shared = SacredPathMapDiagnosticsStore()

    @Published var activeRenderer = "MapLibre"
    @Published var tileProviderName = "Unknown"
    @Published var routingProviderName = "Routing"
    @Published var tileKeyPresent = false
    @Published var lastGPSUpdateAt: Date?
    @Published var lastTileError: String?
    @Published var lastRouteError: String?

    private init() {
        update(tileProvider: SacredPathTileProvider.active)
    }

    func update(tileProvider: SacredPathTileProvider) {
        tileProviderName = tileProvider.displayName
        tileKeyPresent = tileProvider.keyPresent
    }
}

enum SacredPathTileProviderKind: String {
    case mapTilerProduction
    case osmDebugFallback
    case hereFuture
    case tomTomFuture
    case selfHostedFuture
    case missingProductionConfiguration
}

struct SacredPathTileProvider {
    let kind: SacredPathTileProviderKind
    let displayName: String
    let tileTemplate: String
    let attribution: String
    let keyPresent: Bool
    let productionReady: Bool
    let debugWarning: String?

    static var active: SacredPathTileProvider {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "MapLibreTileURLTemplate") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = (Bundle.main.object(forInfoDictionaryKey: "MapTilerAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasTemplate = !configured.isEmpty && !configured.contains("$(")
        let hasKey = !key.isEmpty && !key.contains("$(")

        if hasTemplate, hasKey {
            return SacredPathTileProvider(
                kind: .mapTilerProduction,
                displayName: "MapTiler",
                tileTemplate: configured,
                attribution: "MapTiler / OpenStreetMap contributors",
                keyPresent: true,
                productionReady: true,
                debugWarning: nil
            )
        }

        #if DEBUG
        return SacredPathTileProvider(
            kind: .osmDebugFallback,
            displayName: "OSM debug fallback",
            tileTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
            attribution: "OpenStreetMap contributors",
            keyPresent: false,
            productionReady: false,
            debugWarning: "DEBUG: MAPTILER_API_KEY missing. Using public OSM tiles for local testing only."
        )
        #else
        return SacredPathTileProvider(
            kind: .missingProductionConfiguration,
            displayName: "Missing production tile provider",
            tileTemplate: "https://tiles.invalid/sacred-pathway-maptiler-key-required/{z}/{x}/{y}.png",
            attribution: "",
            keyPresent: false,
            productionReady: false,
            debugWarning: nil
        )
        #endif
    }

    static let futureProviders = [
        SacredPathTileProviderKind.hereFuture,
        .tomTomFuture,
        .selfHostedFuture
    ]
}

enum SacredPathActiveMapProvider: String {
    case mapLibre

    var title: String { "MapLibre" }

    var requiredSetup: String {
        "Bundled MapLibre JS/CSS. Production rendering requires a non-Apple/non-Google tile provider such as MapTiler via MAPTILER_API_KEY."
    }
}

#if DEBUG
struct SacredPathMapDiagnosticsView: View {
    @ObservedObject private var diagnostics = SacredPathMapDiagnosticsStore.shared

    var body: some View {
        List {
            Section("Renderer") {
                diagnosticRow("Active renderer", diagnostics.activeRenderer)
                diagnosticRow("Tile provider", diagnostics.tileProviderName)
                diagnosticRow("Routing provider", diagnostics.routingProviderName)
            }

            Section("Keys") {
                diagnosticRow("MapTiler key present", diagnostics.tileKeyPresent ? "Yes" : "No")
            }

            Section("Live Signals") {
                diagnosticRow("Last GPS update", diagnostics.lastGPSUpdateAt.map { Self.relativeFormatter.localizedString(for: $0, relativeTo: Date()) } ?? "No GPS update yet")
                diagnosticRow("Last tile error", diagnostics.lastTileError ?? "None")
                diagnosticRow("Last route error", diagnostics.lastRouteError ?? "None")
            }

            Section("Provider Slots") {
                diagnosticRow("Production", "MapTiler")
                diagnosticRow("Debug fallback", "OpenStreetMap public tiles")
                diagnosticRow("Future", "HERE / TomTom / self-hosted tiles")
            }
        }
        .navigationTitle("Map Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.spTextSecondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
#endif

struct SacredPathActiveTruckMapView: UIViewRepresentable {
    @ObservedObject var engine: SacredPathNavigationEngine
    let provider: SacredPathActiveMapProvider
    let showRouteMarkers: Bool

    func makeCoordinator() -> Coordinator { Coordinator(provider: provider) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "sacredPathLog")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.0, green: 0.025, blue: 0.028, alpha: 1)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        context.coordinator.webView = webView
        webView.loadHTMLString(context.coordinator.html, baseURL: Bundle.main.resourceURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.webView = webView
        context.coordinator.showRouteMarkers = showRouteMarkers
        context.coordinator.sync(engine: engine)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sacredPathLog")
        coordinator.webView = nil
        coordinator.pendingScript = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        let provider: SacredPathActiveMapProvider
        var isReady = false
        var pendingScript: String?
        var showRouteMarkers = true
        private var lastOverviewID = 0
        private var lastSyncAt = Date.distantPast
        private let minimumSyncInterval: TimeInterval = 0.45

        init(provider: SacredPathActiveMapProvider) {
            self.provider = provider
            super.init()
            SacredPathMapDiagnosticsStore.shared.activeRenderer = provider.title
            SacredPathMapDiagnosticsStore.shared.update(tileProvider: SacredPathTileProvider.active)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "sacredPathLog" else { return }
            let text = "\(message.body)"
            if text.localizedCaseInsensitiveContains("error") || text.localizedCaseInsensitiveContains("tile") {
                SacredPathMapDiagnosticsStore.shared.lastTileError = text
            }
            print("[SacredPath][MapProvider] \(message.body)")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            print("[SacredPath][MapProvider] \(provider.title) loaded")
            if let pendingScript {
                evaluate(pendingScript)
                self.pendingScript = nil
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[SacredPath][MapProvider] load failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[SacredPath][MapProvider] provisional load failed: \(error.localizedDescription)")
        }

        func sync(engine: SacredPathNavigationEngine) {
            let overviewChanged = engine.overviewRequestID != lastOverviewID
            let now = Date()
            if !overviewChanged, now.timeIntervalSince(lastSyncAt) < minimumSyncInterval {
                return
            }
            lastSyncAt = now

            let route = engine.route?.coordinates ?? []
            let remaining = engine.remainingRouteCoordinates.isEmpty ? route : engine.remainingRouteCoordinates
            let payload: [String: Any] = [
                "provider": provider.title,
                "route": lineString(route, maxPoints: 420),
                "remaining": lineString(remaining, maxPoints: 420),
                "traveled": lineString(engine.traveledRouteCoordinates, maxPoints: 220),
                "truck": engine.currentCoordinate.map { point($0) } ?? NSNull(),
                "destination": point(engine.destination.coordinate),
                "heading": engine.displayHeadingDeg,
                "speed": engine.speedMph,
                "follow": engine.followMode,
                "zoom": zoom(for: engine),
                "tileTemplate": tileProvider.tileTemplate,
                "tileAttribution": tileProvider.attribution,
                "tileProductionReady": tileProvider.productionReady,
                "showRouteMarkers": showRouteMarkers,
                "pois": routeMarkerPayload(route: route, upcoming: engine.upcomingPOIs)
            ]

            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else {
                print("[SacredPath][MapProvider] provider payload encode failed")
                return
            }
            SacredPathMapDiagnosticsStore.shared.update(tileProvider: tileProvider)
            SacredPathMapDiagnosticsStore.shared.routingProviderName = engine.routeProviderName

            var script = "window.SacredPathMap && window.SacredPathMap.update(\(json));"
            if overviewChanged {
                lastOverviewID = engine.overviewRequestID
                script += "window.SacredPathMap && window.SacredPathMap.overview();"
            }
            if isReady {
                evaluate(script)
            } else {
                pendingScript = script
            }
        }

        private func routeMarkerPayload(route: [CLLocationCoordinate2D],
                                        upcoming: [SacredPathUpcomingPOI]) -> [[String: Any]] {
            let live: [[String: Any]] = upcoming.prefix(10).map { poi in
                [
                    "name": poi.name,
                    "kind": poi.kind.title,
                    "symbol": poi.kind.rawValue,
                    "coordinate": point(poi.coordinate)
                ] as [String: Any]
            }

            guard route.count >= 4 else { return live }
            let symbols = ["fuel", "parking", "restArea", "service", "scales", "weather", "parking", "fuel", "service", "restArea"]
            let targetCount = min(22, max(10, route.count / 14))
            let stride = max(1, route.count / targetCount)
            let generated: [[String: Any]] = route.enumerated().compactMap { index, coordinate in
                guard index % stride == 0, CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                let symbol = symbols[(index / stride) % symbols.count]
                return [
                    "name": "Route stop",
                    "kind": symbol,
                    "symbol": symbol,
                    "coordinate": point(coordinate)
                ] as [String: Any]
            }

            return live + generated
        }

        private func evaluate(_ script: String) {
            webView?.evaluateJavaScript(script) { _, error in
                if let error {
                    SacredPathMapDiagnosticsStore.shared.lastTileError = error.localizedDescription
                    print("[SacredPath][MapProvider] JS error: \(error.localizedDescription)")
                }
            }
        }

        private func point(_ coordinate: CLLocationCoordinate2D) -> [Double] {
            guard CLLocationCoordinate2DIsValid(coordinate),
                  coordinate.longitude.isFinite,
                  coordinate.latitude.isFinite else {
                return [0, 0]
            }
            return [coordinate.longitude, coordinate.latitude]
        }

        private func lineString(_ coordinates: [CLLocationCoordinate2D], maxPoints: Int) -> [[Double]] {
            let valid = coordinates.filter {
                CLLocationCoordinate2DIsValid($0) && $0.longitude.isFinite && $0.latitude.isFinite
            }
            guard valid.count > maxPoints, maxPoints > 2 else {
                return valid.map { [$0.longitude, $0.latitude] }
            }
            let stride = max(1, valid.count / maxPoints)
            var sampled = valid.enumerated().compactMap { index, coordinate in
                index % stride == 0 ? [coordinate.longitude, coordinate.latitude] : nil
            }
            if let last = valid.last {
                sampled.append([last.longitude, last.latitude])
            }
            return sampled
        }

        private func zoom(for engine: SacredPathNavigationEngine) -> Double {
            let speed = Double(engine.speedMph)
            let base = speed > 55 ? 15.0 : (speed > 25 ? 15.6 : 16.3)
            return max(12.0, min(17.3, base - log2(max(0.75, engine.cameraZoom))))
        }

        private var hasBundledMapLibreAssets: Bool {
            let hasJS = Bundle.main.url(forResource: "maplibre-gl", withExtension: "js") != nil
            let hasCSS = Bundle.main.url(forResource: "maplibre-gl", withExtension: "css") != nil
            if !hasJS { print("[SacredPath][MapProvider] bundled maplibre-gl.js missing") }
            if !hasCSS { print("[SacredPath][MapProvider] bundled maplibre-gl.css missing") }
            return hasJS && hasCSS
        }

        private var tileProvider: SacredPathTileProvider {
            let provider = SacredPathTileProvider.active
            if let warning = provider.debugWarning {
                print("[SacredPath][MapProvider] \(warning)")
            } else if !provider.productionReady {
                print("[SacredPath][MapProvider] production tile provider missing; public OSM fallback is disabled outside DEBUG")
            }
            return provider
        }

        private func jsStringLiteral(_ value: String) -> String {
            guard let data = try? JSONEncoder().encode(value),
                  let encoded = String(data: data, encoding: .utf8) else {
                return "\"\""
            }
            return encoded
        }

        var html: String {
            """
            <!doctype html>
            <html>
            <head>
              <meta name="viewport" content="initial-scale=1,maximum-scale=1,user-scalable=no,width=device-width">
              <link rel="stylesheet" href="maplibre-gl.css">
              <style>
                html, body, #map { margin: 0; width: 100%; height: 100%; background: #00090a; overflow: hidden; }
                .maplibregl-control-container { display: none; }
                .truck-marker {
                  width: 34px; height: 62px; border-radius: 7px;
                  background: linear-gradient(#e83a31 0 40%, #dff5ff 40% 100%);
                  border: 2px solid rgba(255,255,255,.82);
                  box-shadow: 0 5px 12px rgba(0,0,0,.48);
                  display: flex; align-items: center; justify-content: center;
                }
                .truck-marker:before {
                  content: ""; width: 16px; height: 10px; border-radius: 2px;
                  background: rgba(255,255,255,.85); transform: translateY(-14px);
                }
                .dest-marker {
                  width: 26px; height: 26px; border-radius: 50%;
                  background: #a32121; border: 3px solid white;
                  box-shadow: 0 3px 8px rgba(0,0,0,.28);
                }
                .poi-marker {
                  width: 34px; height: 42px; border-radius: 16px 16px 16px 4px;
                  background: #12a2cc; border: 3px solid white;
                  box-shadow: 0 3px 0 rgba(0,0,0,.28), 0 4px 10px rgba(0,0,0,.44);
                  transform: rotate(-45deg);
                  display: flex; align-items: center; justify-content: center;
                }
                .poi-marker span {
                  transform: rotate(45deg);
                  color: white; font: 900 17px -apple-system, BlinkMacSystemFont, sans-serif;
                  text-shadow: 0 1px 1px rgba(0,0,0,.35);
                }
                .provider {
                  display: none;
                  position: absolute; left: 50%; top: 126px; transform: translateX(-50%);
                  font: 700 11px -apple-system, BlinkMacSystemFont, sans-serif;
                  color: #1c1b18; background: rgba(255,255,255,.82);
                  border: 1px solid rgba(216,175,79,.45); border-radius: 999px;
                  padding: 6px 10px; z-index: 2; backdrop-filter: blur(8px);
                }
              </style>
              <script src="maplibre-gl.js"></script>
            </head>
            <body>
              <div id="map"></div>
              <div id="provider" class="provider">MapLibre</div>
              <script>
                var lastPayload = null;
                function nativeLog(message) {
                  try {
                    window.webkit.messageHandlers.sacredPathLog.postMessage(message);
                  } catch (e) {
                    console.log(message);
                  }
                }
                nativeLog('booting MapLibre active navigation');
                if (typeof maplibregl === 'undefined') {
                  nativeLog('map error: bundled MapLibre JS did not load');
                  document.getElementById('provider').textContent = 'MapLibre asset failed';
                  window.SacredPathMap = { update: function(payload) { lastPayload = payload; }, overview: function() {} };
                } else {
                const emptyLine = { type: 'Feature', geometry: { type: 'LineString', coordinates: [] }, properties: {} };
                const map = new maplibregl.Map({
                  container: 'map',
                  attributionControl: false,
                  interactive: true,
                  center: [-96.7970, 32.7767],
                  zoom: 14.8,
                  pitch: 50,
                  bearing: 0,
                  style: {
                    version: 8,
                    sources: {
                      truckTiles: {
                        type: 'raster',
                        tiles: [\(jsStringLiteral(tileProvider.tileTemplate))],
                        tileSize: 256,
                        attribution: \(jsStringLiteral(tileProvider.attribution))
                      }
                    },
                    layers: [
                      { id: 'truckTiles', type: 'raster', source: 'truckTiles', paint: { 'raster-saturation': -0.82, 'raster-contrast': 0.32, 'raster-brightness-min': 0.0, 'raster-brightness-max': 0.34 } }
                    ]
                  }
                });
                map.on('error', e => nativeLog('map error: ' + ((e && e.error && e.error.message) || 'unknown')));
                map.on('data', e => {
                  if (e.dataType === 'source' && e.sourceId === 'truckTiles' && e.isSourceLoaded === false) {
                    nativeLog('tile source loading');
                  }
                });
                const truckEl = document.createElement('div');
                truckEl.className = 'truck-marker';
                const truckMarker = new maplibregl.Marker({ element: truckEl, rotationAlignment: 'map', pitchAlignment: 'map' }).setLngLat([-96.7970, 32.7767]).addTo(map);
                const destEl = document.createElement('div');
                destEl.className = 'dest-marker';
                const destMarker = new maplibregl.Marker({ element: destEl }).setLngLat([-96.7970, 32.7767]).addTo(map);
                let poiMarkers = [];
                let currentTileTemplate = \(jsStringLiteral(tileProvider.tileTemplate));
                function feature(coords) { return { type: 'Feature', geometry: { type: 'LineString', coordinates: coords || [] }, properties: {} }; }
                function installLayers() {
                  if (map.getSource('remaining')) return;
                  map.addSource('traveled', { type: 'geojson', data: emptyLine });
                  map.addSource('remaining', { type: 'geojson', data: emptyLine });
                  map.addLayer({ id: 'traveled-shadow', type: 'line', source: 'traveled', layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': '#000000', 'line-opacity': .45, 'line-width': 13 } });
                  map.addLayer({ id: 'traveled', type: 'line', source: 'traveled', layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': '#1b78ff', 'line-opacity': .28, 'line-width': 8 } });
                  map.addLayer({ id: 'remaining-shadow', type: 'line', source: 'remaining', layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': '#001934', 'line-opacity': .72, 'line-width': 15 } });
                  map.addLayer({ id: 'remaining', type: 'line', source: 'remaining', layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': '#2490ff', 'line-width': 10 } });
                }
                function setLine(id, coords) {
                  const src = map.getSource(id);
                  if (src) src.setData(feature(coords));
                }
                function poiStyle(symbol) {
                  if (symbol === 'fuel') return { color: '#f15a3c', label: 'T' };
                  if (symbol === 'parking') return { color: '#1698c8', label: 'P' };
                  if (symbol === 'restArea') return { color: '#15b989', label: 'W' };
                  if (symbol === 'scales') return { color: '#f2cf47', label: '⚖' };
                  if (symbol === 'service') return { color: '#f3f3f3', label: '✚', text: '#333' };
                  if (symbol === 'weather') return { color: '#ef4b32', label: '!' };
                  return { color: '#1698c8', label: '•' };
                }
                function rebuildPois(pois, showMarkers) {
                  poiMarkers.forEach(m => m.remove());
                  poiMarkers = [];
                  if (!showMarkers) return;
                  (pois || []).forEach(p => {
                    if (!p.coordinate) return;
                    const style = poiStyle(p.symbol);
                    const el = document.createElement('div');
                    el.className = 'poi-marker';
                    el.style.background = style.color;
                    const label = document.createElement('span');
                    label.textContent = style.label;
                    if (style.text) label.style.color = style.text;
                    el.appendChild(label);
                    poiMarkers.push(new maplibregl.Marker({ element: el }).setLngLat(p.coordinate).addTo(map));
                  });
                }
                function boundsFor(coords) {
                  if (!coords || !coords.length) return null;
                  const b = new maplibregl.LngLatBounds(coords[0], coords[0]);
                  coords.forEach(c => b.extend(c));
                  return b;
                }
                map.on('load', () => {
                  installLayers();
                  window.SacredPathReady = true;
                  if (lastPayload) window.SacredPathMap.update(lastPayload);
                });
                window.SacredPathMap = {
                  update: function(payload) {
                    lastPayload = payload;
                    document.getElementById('provider').textContent = payload.tileProductionReady ? 'MapLibre + production tiles' : 'MapLibre + OSM dev tiles';
                    if (!map.loaded()) return;
                    installLayers();
                    const src = map.getSource('truckTiles');
                    if (src && payload.tileTemplate && currentTileTemplate !== payload.tileTemplate) {
                      nativeLog('switching tile provider: ' + (payload.tileProductionReady ? 'production' : 'development fallback'));
                      map.removeLayer('truckTiles');
                      map.removeSource('truckTiles');
                      map.addSource('truckTiles', { type: 'raster', tiles: [payload.tileTemplate], tileSize: 256, attribution: payload.tileAttribution || '' });
                      map.addLayer({ id: 'truckTiles', type: 'raster', source: 'truckTiles', paint: { 'raster-saturation': -0.82, 'raster-contrast': 0.32, 'raster-brightness-min': 0.0, 'raster-brightness-max': 0.34 } }, 'traveled-shadow');
                      currentTileTemplate = payload.tileTemplate;
                    }
                    setLine('traveled', payload.traveled || []);
                    setLine('remaining', payload.remaining || payload.route || []);
                    if (payload.destination) destMarker.setLngLat(payload.destination);
                    if (payload.truck) {
                      truckMarker.setLngLat(payload.truck);
                      truckMarker.setRotation(payload.heading || 0);
                      if (payload.follow) {
                        map.easeTo({
                          center: payload.truck,
                          bearing: payload.heading || 0,
                          pitch: 52,
                          zoom: payload.zoom || 15.2,
                          duration: 430,
                          easing: t => t
                        });
                      }
                    }
                    rebuildPois(payload.pois || [], payload.showRouteMarkers !== false);
                  },
                  overview: function() {
                    const coords = (lastPayload && (lastPayload.route || lastPayload.remaining)) || [];
                    const b = boundsFor(coords);
                    if (b) map.fitBounds(b, { padding: { top: 110, left: 55, right: 55, bottom: 170 }, duration: 600, bearing: 0, pitch: 0 });
                  }
                };
                }
              </script>
            </body>
            </html>
            """
        }
    }
}

// =============================================================================
// MARK: - Custom in-app trucking map (no Apple Maps/MapKit in active nav)
// -----------------------------------------------------------------------------
// A fast, low-clutter route renderer for active driving. The provider supplies
// route coordinates and turn steps; this view draws the live navigation surface
// directly so the truck puck can stay current with the GPS fix instead of being
// paced by Apple Maps camera/annotation behavior.
// =============================================================================

struct SacredPathTruckMapView: View {
    @ObservedObject var engine: SacredPathNavigationEngine
    var satellite: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    drawBackground(context: &context, size: size)
                    drawRoute(engine.traveledRouteCoordinates, context: &context, size: size, color: Color.spGold.opacity(0.24), width: 7)
                    drawRoute(engine.remainingRouteCoordinates.isEmpty ? engine.route?.coordinates ?? [] : engine.remainingRouteCoordinates,
                              context: &context, size: size, color: Color.spGold, width: 8)
                }
                .background(satellite ? Color(red: 0.12, green: 0.13, blue: 0.11) : Color(red: 0.96, green: 0.95, blue: 0.91))

                destinationMarker(size: proxy.size)

                ForEach(engine.upcomingPOIs.prefix(8)) { poi in
                    if let point = screenPoint(for: poi.coordinate, size: proxy.size) {
                        poiMarker(poi)
                            .position(point)
                    }
                }

                if let point = engine.currentCoordinate.flatMap({ screenPoint(for: $0, size: proxy.size) }) {
                    truckPuck
                        .position(point)
                        .animation(.linear(duration: 0.45), value: engine.currentCoordinate?.latitude)
                        .animation(.linear(duration: 0.45), value: engine.currentCoordinate?.longitude)
                }

                providerPill
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 126)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in engine.followMode = false }
            )
            .onTapGesture(count: 2) { engine.zoomIn() }
        }
    }

    private var truckPuck: some View {
        ZStack {
            Circle()
                .fill(Color.spDarkGreen)
                .frame(width: 42, height: 42)
                .overlay(Circle().stroke(Color.spGoldLight, lineWidth: 3))
                .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
            Image(systemName: "location.north.fill")
                .font(.system(size: 19, weight: .heavy))
                .foregroundStyle(Color.spGoldLight)
                .rotationEffect(.degrees(engine.truckRotationDeg))
        }
        .accessibilityLabel("Truck location")
    }

    private func destinationMarker(size: CGSize) -> some View {
        Group {
            if let point = screenPoint(for: engine.destination.coordinate, size: size) {
                Image(systemName: "flag.checkered.circle.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.spDanger)
                    .background(Circle().fill(.white))
                    .position(point)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            }
        }
    }

    private func poiMarker(_ poi: SacredPathUpcomingPOI) -> some View {
        Image(systemName: poi.kind.symbol)
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(poi.kind == .fuel ? .black : .white)
            .frame(width: 25, height: 25)
            .background(Circle().fill(poiColor(poi.kind)))
            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.2))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .accessibilityLabel(poi.name)
    }

    private var providerPill: some View {
        HStack(spacing: 7) {
            Image(systemName: engine.routeLimitations.isEmpty ? "road.lanes" : "exclamationmark.triangle.fill")
                .font(.caption2.weight(.bold))
            Text(engine.routeProviderName)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.spTextPrimary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.spGold.opacity(0.28), lineWidth: 1))
        .allowsHitTesting(false)
    }

    private func drawBackground(context: inout GraphicsContext, size: CGSize) {
        let roadColor = satellite ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
        let highwayColor = satellite ? Color.spGold.opacity(0.34) : Color.spGold.opacity(0.24)
        let minorStride: CGFloat = 58
        var grid = Path()
        var x: CGFloat = -minorStride
        while x < size.width + minorStride {
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x + size.height * 0.28, y: size.height))
            x += minorStride
        }
        var y: CGFloat = -minorStride
        while y < size.height + minorStride {
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y + size.width * 0.12))
            y += minorStride
        }
        context.stroke(grid, with: .color(roadColor), lineWidth: 1)

        var highway = Path()
        highway.move(to: CGPoint(x: -30, y: size.height * 0.55))
        highway.addCurve(to: CGPoint(x: size.width + 30, y: size.height * 0.38),
                         control1: CGPoint(x: size.width * 0.28, y: size.height * 0.44),
                         control2: CGPoint(x: size.width * 0.62, y: size.height * 0.66))
        context.stroke(highway, with: .color(highwayColor), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
        context.stroke(highway, with: .color(.white.opacity(satellite ? 0.08 : 0.45)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    private func drawRoute(_ coordinates: [CLLocationCoordinate2D],
                           context: inout GraphicsContext,
                           size: CGSize,
                           color: Color,
                           width: CGFloat) {
        guard coordinates.count >= 2 else { return }
        var path = Path()
        var started = false
        for coordinate in coordinates {
            guard let point = screenPoint(for: coordinate, size: size) else { continue }
            if started {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                started = true
            }
        }
        context.stroke(path, with: .color(.black.opacity(satellite ? 0.45 : 0.15)), style: StrokeStyle(lineWidth: width + 4, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private func screenPoint(for coordinate: CLLocationCoordinate2D, size: CGSize) -> CGPoint? {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let center = mapCenter
        let meters = metersFrom(center: center, coordinate: coordinate)
        let heading = engine.followMode ? engine.displayHeadingDeg : 0
        let rotated = rotate(meters, by: -heading)
        let scale = metersPerPoint(size: size)
        let anchorY = engine.followMode ? size.height * 0.62 : size.height * 0.5
        return CGPoint(x: size.width * 0.5 + rotated.x / scale,
                       y: anchorY - rotated.y / scale)
    }

    private var mapCenter: CLLocationCoordinate2D {
        if engine.followMode, let current = engine.currentCoordinate {
            return current
        }
        let coords = engine.route?.boundingCoordinates ?? []
        guard !coords.isEmpty else { return engine.currentCoordinate ?? engine.destination.coordinate }
        let lat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
        let lon = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func metersPerPoint(size: CGSize) -> CGFloat {
        if !engine.followMode {
            let coords = engine.route?.boundingCoordinates ?? []
            guard coords.count >= 2 else { return 12 }
            let center = mapCenter
            let points = coords.map { metersFrom(center: center, coordinate: $0) }
            let width = max(500, (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0))
            let height = max(500, (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0))
            return max(CGFloat(width) / max(1, size.width * 0.74),
                       CGFloat(height) / max(1, size.height * 0.58))
        }
        let speedMps = Double(engine.speedMph) * 0.44704
        let base = min(16, max(4.5, 5.2 + speedMps * 0.08))
        return CGFloat(base * engine.cameraZoom)
    }

    private func metersFrom(center: CLLocationCoordinate2D, coordinate: CLLocationCoordinate2D) -> CGPoint {
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = metersPerDegreeLat * cos(center.latitude * .pi / 180)
        return CGPoint(
            x: (coordinate.longitude - center.longitude) * metersPerDegreeLon,
            y: (coordinate.latitude - center.latitude) * metersPerDegreeLat
        )
    }

    private func rotate(_ point: CGPoint, by degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let cosValue = cos(radians)
        let sinValue = sin(radians)
        return CGPoint(
            x: point.x * cosValue - point.y * sinValue,
            y: point.x * sinValue + point.y * cosValue
        )
    }

    private func poiColor(_ kind: SacredPathPOIKind) -> Color {
        switch kind {
        case .fuel: return Color.spGold
        case .parking: return Color.spDarkGreen
        case .restArea: return Color.spGreenAccent
        case .scales: return Color.spWarning
        case .service: return Color.spTextSecondary
        case .weather: return Color.spDanger
        }
    }
}
