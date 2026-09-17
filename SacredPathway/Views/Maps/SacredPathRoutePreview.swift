import SwiftUI
import MapKit
import CoreLocation
import Combine

// =============================================================================
// MARK: - Sacred Path route preview (planning only, GPS-free)
// -----------------------------------------------------------------------------
// This screen is a trip-planning preview: it shows the driver the route line,
// distance, estimated drive time, and trucking resources along the way. There
// is no turn-by-turn guidance (in-app navigation was removed 2026-09-17).
//
//   * SacredPathRouteModel        — MKDirections used ONLY to draw a preview
//                                   line + estimate distance/time (no guidance)
//   * SacredPathRoutePreviewView  — preview map + route summary
//
// `SacredPathDestination`, `SacredPathFormat`, `SacredPathExternalMaps`, and
// `SacredPathDisclaimer` live in SacredPathSupport.swift.
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
