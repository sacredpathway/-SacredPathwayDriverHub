import SwiftUI
import MapKit

// =============================================================================
// MARK: - WeatherMapView (Live Weather Map)
// -----------------------------------------------------------------------------
// Interactive radar weather map with OpenWeatherMap raster tile overlays
// (precip/snow, wind, clouds, temp), live conditions, zoom/pan, "Follow My
// Truck" mode, and an always-visible user location. SwiftUI's Map can't host an
// arbitrary MKTileOverlay, so the map itself is a UIViewRepresentable around
// MKMapView; the chrome (layer switcher, conditions panel, controls) is SwiftUI.
// =============================================================================

struct WeatherMapView: View {
    @ObservedObject var viewModel: WeatherMapViewModel
    var compact: Bool = false
    @State private var forecastExpanded = false

    var body: some View {
        ZStack(alignment: .top) {
            WeatherMapRepresentable(
                region: $viewModel.region,
                tileTemplate: viewModel.tileTemplate(),
                reloadToken: viewModel.overlayReloadToken,
                followTruck: viewModel.followTruck
            )
            .ignoresSafeArea(edges: compact ? [] : .bottom)

            VStack(spacing: 8) {
                if !viewModel.isConfigured {
                    apiKeyBanner
                }
                layerPicker
                if !compact, let c = viewModel.conditions {
                    ConditionsPanel(conditions: c, alerts: viewModel.providerAlerts)
                }
                Spacer()
            }
            .padding(compact ? 8 : 12)

            VStack(spacing: 8) {
                Spacer()
                if !compact, viewModel.isConfigured {
                    ForecastPanel(isExpanded: $forecastExpanded)
                        .padding(.horizontal, 12)
                }
                HStack {
                    followButton
                    Spacer()
                    centerButton
                }
                .padding(compact ? 8 : 12)
            }
        }
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
    }

    // MARK: API key missing banner (graceful degrade)
    private var apiKeyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.spWarning)
            Text("Add your OpenWeatherMap API key to enable live radar overlays.")
                .font(.caption)
                .foregroundStyle(Color.spTextPrimary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Layer switcher
    private var layerPicker: some View {
        Picker("Layer", selection: Binding(
            get: { viewModel.layer },
            set: { viewModel.changeLayer($0) }
        )) {
            ForEach(WeatherLayer.allCases) { layer in
                Image(systemName: layer.systemImage).tag(layer)
            }
        }
        .pickerStyle(.segmented)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Follow My Truck
    private var followButton: some View {
        Button {
            viewModel.toggleFollow()
        } label: {
            Label(viewModel.followTruck ? "Following" : "Follow My Truck",
                  systemImage: viewModel.followTruck ? "location.fill.viewfinder" : "location.viewfinder")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(viewModel.followTruck ? Color.spDarkGreen : Color.spBlack.opacity(0.7),
                            in: Capsule())
                .overlay(Capsule().stroke(Color.spGold.opacity(0.6), lineWidth: 1))
        }
    }

    private var centerButton: some View {
        Button {
            viewModel.centerOnTruck()
        } label: {
            Image(systemName: "scope")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(11)
                .background(Color.spDarkGreen, in: Circle())
                .overlay(Circle().stroke(Color.spGold.opacity(0.6), lineWidth: 1))
        }
    }
}

// =============================================================================
// MARK: - Conditions panel
// =============================================================================
private struct ConditionsPanel: View {
    let conditions: WeatherConditions
    let alerts: [WeatherAlertEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: conditions.kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.spGold)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Int(conditions.temperatureF))°F")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.spTextPrimary)
                    Text(conditions.summary)
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                Spacer()
                if let place = conditions.placeName {
                    Text(place)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 14) {
                metric("wind", "\(Int(conditions.windSpeedMph)) mph \(conditions.windCompass)")
                metric("eye", String(format: "%.1f mi", conditions.visibilityMiles))
                metric("thermometer.variable", "Feels \(Int(conditions.feelsLikeF))°")
            }

            ForEach(alerts.prefix(2)) { alert in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.spDanger)
                        .font(.caption)
                    Text(alert.event)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.spGold.opacity(0.3), lineWidth: 1)
        )
    }

    private func metric(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color.spGold)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.spTextPrimary)
        }
    }
}

// =============================================================================
// MARK: - Forecast panel (slide-up hourly strip + daily rows)
// -----------------------------------------------------------------------------
// Expandable panel anchored above the bottom map controls. Collapsed it's a
// slim "Forecast" handle; expanded it shows the next ~24h as a horizontal
// strip (time, icon, temp, rain %) and the multi-day outlook as rows (day,
// icon, rain %, wind, hi/lo). Data comes from ForecastService (One Call 3.0
// with silent 2.5 fallback) and refreshes as the truck moves.
// =============================================================================
@MainActor
private struct ForecastPanel: View {
    @Binding var isExpanded: Bool
    @ObservedObject private var forecasts = ForecastService.shared
    @ObservedObject private var location = LocationManager.shared

    var body: some View {
        VStack(spacing: 0) {
            handle
            if isExpanded {
                if let forecast = forecasts.nearMeForecast {
                    content(forecast)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().tint(Color.spGold)
                        Text("Loading forecast…")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.spGold.opacity(0.3), lineWidth: 1)
        )
        .task(id: location.location) {
            await forecasts.refreshNearMe(at: location.coordinate)
        }
    }

    private var handle: some View {
        Button {
            withAnimation(.spring(duration: 0.3)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.spGold)
                Text("Forecast")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.spTextSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func content(_ forecast: WeatherForecast) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Hourly strip — next ~24h.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(forecast.hourly) { hour in
                        VStack(spacing: 3) {
                            Text(hour.date, format: .dateTime.hour())
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.spTextSecondary)
                            Image(systemName: hour.kind.systemImage)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.spGold)
                            Text("\(Int(hour.temperatureF))°")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.spTextPrimary)
                            Text("\(Int(hour.precipProbability * 100))%")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(hour.precipProbability >= 0.5
                                                 ? Color.spWarning : Color.spTextSecondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            Divider().background(Color.spGold.opacity(0.2))

            // Daily rows — up to 7 days.
            VStack(spacing: 6) {
                ForEach(forecast.daily.prefix(7)) { day in
                    HStack(spacing: 8) {
                        Text(day.date, format: .dateTime.weekday(.abbreviated))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.spTextPrimary)
                            .frame(width: 34, alignment: .leading)
                        Image(systemName: day.kind.systemImage)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.spGold)
                            .frame(width: 20)
                        Text("\(Int(day.precipProbability * 100))%")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(day.precipProbability >= 0.5
                                             ? Color.spWarning : Color.spTextSecondary)
                            .frame(width: 32, alignment: .leading)
                        Label("\(Int(day.windSpeedMph)) mph", systemImage: "wind")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.spTextSecondary)
                        Spacer()
                        Text("\(Int(day.highF))° / \(Int(day.lowF))°")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.spTextPrimary)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 10)
    }
}

// =============================================================================
// MARK: - MKMapView representable (hosts the OWM tile overlay)
// -----------------------------------------------------------------------------
// Standard base map + a single MKTileOverlay for the active weather layer.
// Reloads the overlay when the layer or refresh token changes. Honors
// Follow-My-Truck by recentering when the bound region's center moves while the
// user isn't actively dragging.
// =============================================================================
struct WeatherMapRepresentable: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let tileTemplate: String?
    let reloadToken: UUID
    let followTruck: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.pointOfInterestFilter = .excludingAll
        map.setRegion(region, animated: false)
        context.coordinator.installOverlay(on: map, template: tileTemplate)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Reload overlay if the layer template or refresh token changed.
        if context.coordinator.lastTemplate != tileTemplate ||
            context.coordinator.lastToken != reloadToken {
            context.coordinator.lastTemplate = tileTemplate
            context.coordinator.lastToken = reloadToken
            context.coordinator.installOverlay(on: map, template: tileTemplate)
        }

        // Recenter when following the truck and the bound center moved beyond a
        // small threshold (avoids fighting the user's manual pans).
        if followTruck, !context.coordinator.userIsInteracting {
            let current = map.region.center
            let target = region.center
            if abs(current.latitude - target.latitude) > 0.05 ||
                abs(current.longitude - target.longitude) > 0.05 {
                map.setCenter(target, animated: true)
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: WeatherMapRepresentable
        var lastTemplate: String?
        var lastToken: UUID
        var userIsInteracting = false
        private weak var currentOverlay: MKTileOverlay?

        init(_ parent: WeatherMapRepresentable) {
            self.parent = parent
            self.lastTemplate = parent.tileTemplate
            self.lastToken = parent.reloadToken
        }

        func installOverlay(on map: MKMapView, template: String?) {
            if let existing = currentOverlay {
                map.removeOverlay(existing)
                currentOverlay = nil
            }
            guard let template, !template.isEmpty else { return }
            let overlay = MKTileOverlay(urlTemplate: template)
            overlay.canReplaceMapContent = false
            map.addOverlay(overlay, level: .aboveLabels)
            currentOverlay = overlay
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tile)
                renderer.alpha = 0.75 // let the base map show through
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // Detect manual interaction so Follow mode doesn't yank the map back.
            if let gestures = mapView.subviews.first?.gestureRecognizers {
                userIsInteracting = gestures.contains {
                    $0.state == .began || $0.state == .changed
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            userIsInteracting = false
            // Push the visible region back up so SwiftUI state stays in sync.
            DispatchQueue.main.async { [weak self] in
                self?.parent.region = mapView.region
            }
        }
    }
}
