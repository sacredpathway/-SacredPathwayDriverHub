import SwiftUI
import CoreLocation
import MapKit

// =============================================================================
// MARK: - MapsHubView
// -----------------------------------------------------------------------------
// The single "Maps" tab added to the Owner-Operator and Carrier roots. Hosts a
// segmented switcher between the Live Rate Map, the Live Weather Map, Sacred
// Path, or "Both"
// (a stacked split view). This keeps the app at five tabs (no iOS "More"
// overflow) while delivering both features.
// =============================================================================

/// Local feature flags for the Maps module. Lets the whole feature be disabled
/// from one place without touching the tab code (mirrors the app's existing
/// FeatureFlags pattern). `enabled` is the master switch.
enum MapFeatureFlags {
    /// Master switch for the Maps tab + dashboard cards. Safe to ship `true`;
    /// flip to `false` to fully hide the feature with zero other edits.
    static let enabled = true
    /// Show the two "Near Me" cards on the Owner-Op / Carrier dashboard.
    static let dashboardCardsEnabled = true
}

enum MapsMode: String, CaseIterable, Identifiable {
    case rate = "Rate"
    case weather = "Weather"
    case stops = "Sacred Path"
    case both = "Both"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .rate:    return "dollarsign.circle.fill"
        case .weather: return "cloud.sun.fill"
        case .stops:   return "mappin.and.ellipse"
        case .both:    return "square.split.1x2.fill"
        }
    }
}

struct MapsHubView: View {
    @State private var mode: MapsMode = .rate
    @StateObject private var rateVM = RateMapViewModel()
    @StateObject private var weatherVM = WeatherMapViewModel()
    @ObservedObject private var locationPreference = MapLocationPreferenceStore.shared
    @ObservedObject private var location = LocationManager.shared
    @State private var showingLocationSearch = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()

                // Runs the ~1 Hz location → near-me forecast refresh in its OWN
                // view so this body (and the segmented mode picker) does not
                // rebuild on every GPS fix. Before this, tapping "Sacred Path"
                // often needed two presses because the first tap landed during a
                // location-driven re-render of the picker.
                MapsNearMeRefresher()

                VStack(spacing: 0) {
                    // The severe-weather banner observes the forecast object in a
                    // child view, so its frequent updates don't re-render the
                    // picker either.
                    SevereWeatherBannerHost()

                    locationControl
                        .padding(.horizontal)
                        .padding(.top, 8)

                    modePicker
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 6)

                    content
                }
            }
            .navigationTitle("Maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.spBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        DriverAlertsView()
                    } label: {
                        AlertBellLabel()
                    }
                }
            }
        }
        .tint(Color.spGold)
        .onAppear {
            location.requestAuthorizationIfNeeded()
            location.startUpdating()
        }
        .onDisappear {
            location.stopUpdating()
        }
        .sheet(isPresented: $showingLocationSearch) {
            MapLocationSearchView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var locationControl: some View {
        HStack(spacing: 10) {
            Image(systemName: locationPreference.mode == .currentLocation ? "location.fill" : "mappin.and.ellipse")
                .foregroundStyle(Color.spGold)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(locationPreference.statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                    .lineLimit(1)
                if locationPreference.mode == .currentLocation && location.coordinate == nil && !location.isDenied {
                    Text("Detecting driver GPS...")
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary)
                } else if location.isDenied && locationPreference.mode == .currentLocation {
                    Text("Search manually or enable location in Settings.")
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary)
                }
            }

            Spacer(minLength: 8)

            Button(locationPreference.mode == .currentLocation ? "Change Location" : "Use Current Location") {
                if locationPreference.mode == .currentLocation {
                    showingLocationSearch = true
                } else {
                    locationPreference.useCurrentLocation()
                }
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.spGold)
        }
        .padding(10)
        .background(Color.spCardBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spGold.opacity(0.22), lineWidth: 1))
    }

    private var modePicker: some View {
        Picker("Map Mode", selection: $mode) {
            ForEach(MapsMode.allCases) { m in
                Label(m.rawValue, systemImage: m.systemImage).tag(m)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .rate:
            RateMapView(viewModel: rateVM)
        case .weather:
            WeatherMapView(viewModel: weatherVM)
        case .stops:
            SacredPathHubView()
        case .both:
            GeometryReader { geo in
                VStack(spacing: 0) {
                    RateMapView(viewModel: rateVM, compact: true)
                        .frame(height: geo.size.height / 2)
                    Divider().background(Color.spGold.opacity(0.4))
                    WeatherMapView(viewModel: weatherVM, compact: true)
                        .frame(height: geo.size.height / 2)
                }
            }
        }
    }
}

// =============================================================================
// MARK: - Location / forecast isolation helpers
// -----------------------------------------------------------------------------
// These two tiny views absorb the high-frequency location + forecast updates so
// MapsHubView's body — and the segmented mode picker inside it — stays stable
// between GPS fixes. This is what fixes the "tap Sacred Path twice" bug.
// =============================================================================

/// Invisible worker: refreshes the near-me forecast whenever the GPS fix
/// changes, without forcing the host view to re-render.
private struct MapsNearMeRefresher: View {
    @ObservedObject private var location = LocationManager.shared
    @ObservedObject private var preference = MapLocationPreferenceStore.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: refreshID) {
                await ForecastService.shared.refreshNearMe(at: preference.effectiveCoordinate)
            }
    }

    private var refreshID: String {
        let manual = preference.manualLocation.map { "\($0.latitude),\($0.longitude)" } ?? "none"
        let current = location.location?.timestamp.timeIntervalSince1970 ?? 0
        return "\(preference.mode.rawValue)|\(manual)|\(current)"
    }
}

/// Hosts the severe-weather banner and its own dismissal state, observing the
/// forecast service here instead of in MapsHubView.
private struct SevereWeatherBannerHost: View {
    @ObservedObject private var forecasts = ForecastService.shared
    /// Alert ids the user dismissed this session — the banner stays gone for
    /// those but reappears if a NEW severe alert lands.
    @State private var dismissedAlertIds: Set<String> = []

    private var severeBannerAlert: WeatherAlertEvent? {
        forecasts.activeSevereAlerts.first { !dismissedAlertIds.contains($0.id) }
    }

    var body: some View {
        if let alert = severeBannerAlert {
            SevereWeatherBanner(alert: alert, onDismiss: {
                withAnimation {
                    _ = dismissedAlertIds.insert(alert.id)
                }
            })
        }
    }
}

// =============================================================================
// MARK: - Severe weather banner
// -----------------------------------------------------------------------------
// Slim, dismissable notification strip shown above the mode picker when a
// severe weather alert (NWS via One Call, or heuristic on the 2.5 fallback) is
// active near the driver. Visual treatment mirrors LocalModeBanner: HStack on
// spCardBg with a hairline bottom rule, warning-colored iconography.
// =============================================================================
struct SevereWeatherBanner: View {
    let alert: WeatherAlertEvent
    var onDismiss: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.spWarning)
                .font(.subheadline)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(alert.event)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                    .lineLimit(1)
                Text(bannerDetail)
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spTextSecondary)
                    .padding(6)
                    .background(Color.spCardBgLight, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss severe weather alert")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.spCardBg)
        .overlay(
            Rectangle()
                .fill(Color.spWarning.opacity(0.45))
                .frame(height: 1),
            alignment: .bottom
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Severe weather alert: \(alert.event)")
    }

    private var bannerDetail: String {
        let until = alert.end.formatted(date: .omitted, time: .shortened)
        let desc = alert.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if desc.isEmpty { return "Active until \(until)" }
        return "\(desc.prefix(90)) · Until \(until)"
    }
}

// Small reusable bell that badges when there are active alerts.
struct AlertBellLabel: View {
    @ObservedObject private var engine = AlertEngine.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "bell.fill")
                .foregroundStyle(Color.spGold)
            if let count = activeCount, count > 0 {
                Text("\(min(count, 9))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(Color.spDanger))
                    .offset(x: 8, y: -8)
            }
        }
    }

    private var activeCount: Int? {
        let c = engine.activeAlerts.count
        return c > 0 ? c : nil
    }
}

#Preview {
    MapsHubView()
}

private struct MapLocationSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var preference = MapLocationPreferenceStore.shared
    @State private var query = ""
    @State private var results: [ManualMapLocation] = []
    @State private var isSearching = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Color.spTextSecondary)
                        TextField("City/state, ZIP, address, or truck stop", text: $query)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.search)
                            .onSubmit { search() }
                    }

                    Button {
                        preference.useCurrentLocation()
                        dismiss()
                    } label: {
                        Label("Use Current Location", systemImage: "location.fill")
                    }
                    .foregroundStyle(Color.spGold)
                }
                .listRowBackground(Color.spCardBg)

                if isSearching {
                    Section {
                        HStack {
                            ProgressView().tint(Color.spGold)
                            Text("Searching...")
                                .foregroundStyle(Color.spTextSecondary)
                        }
                    }
                    .listRowBackground(Color.spCardBg)
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    .listRowBackground(Color.spCardBg)
                }

                Section("Results") {
                    ForEach(results, id: \.displayName) { result in
                        Button {
                            preference.saveManualLocation(result)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.spTextPrimary)
                                Text(String(format: "%.4f, %.4f", result.latitude, result.longitude))
                                    .font(.caption2)
                                    .foregroundStyle(Color.spTextSecondary)
                            }
                        }
                    }
                }
                .listRowBackground(Color.spCardBg)
            }
            .scrollContentBackground(.hidden)
            .background(Color.spBackground)
            .navigationTitle("Map Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Search") { search() }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(Color.spGold)
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isSearching = true
        message = nil
        results = []
        Task {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = q
            request.resultTypes = [.address, .pointOfInterest]
            let response = try? await MKLocalSearch(request: request).start()
            let mapped = (response?.mapItems ?? []).prefix(12).compactMap { item -> ManualMapLocation? in
                let coord = item.placemark.coordinate
                guard CLLocationCoordinate2DIsValid(coord) else { return nil }
                let city = item.placemark.locality ?? ""
                let state = item.placemark.administrativeArea ?? ""
                let fallback = [city, state].filter { !$0.isEmpty }.joined(separator: ", ")
                let display = item.name ?? (fallback.isEmpty ? q : fallback)
                return ManualMapLocation(
                    city: city,
                    state: state,
                    latitude: coord.latitude,
                    longitude: coord.longitude,
                    displayName: display
                )
            }
            await MainActor.run {
                results = Array(mapped)
                isSearching = false
                if results.isEmpty {
                    message = "No matching location found. Try a city/state, ZIP code, address, or truck stop name."
                }
            }
        }
    }
}
