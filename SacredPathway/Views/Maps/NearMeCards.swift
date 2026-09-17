import SwiftUI
import CoreLocation
import Combine

// =============================================================================
// MARK: - Dashboard "Near Me" Cards
// -----------------------------------------------------------------------------
// Two compact cards for the Owner-Operator / Carrier dashboard:
//   * WeatherNearMeCard — current conditions, temp, wind, alert status.
//   * RateNearMeCard     — nearest market, RPM, trend, load-demand indicator.
// Both tap through to the Maps tab content (presented as a sheet so they work
// from inside the dashboard's own NavigationStack without disturbing tabs).
// Driver role never shows these because DriverRootView uses a different
// dashboard view — these are only inserted into DashboardView.
// =============================================================================

// MARK: - Weather Near Me

@MainActor
struct WeatherNearMeCard: View {
    @StateObject private var weather = WeatherService.shared
    @ObservedObject private var alerts = AlertEngine.shared
    @ObservedObject private var location = LocationManager.shared
    @ObservedObject private var forecasts = ForecastService.shared
    @State private var showMaps = false

    var body: some View {
        Button { showMaps = true } label: { cardBody }
            .buttonStyle(.plain)
            .onAppear {
                location.startUpdating()
                weather.startAutoRefresh(at: { LocationManager.shared.coordinate })
            }
            .task(id: location.location) {
                await forecasts.refreshNearMe(at: location.coordinate)
            }
            .sheet(isPresented: $showMaps) {
                MapsHubSheet(initialMode: .weather)
            }
    }

    /// Rain chance over the next forecast hour(s), 0–100, when available.
    private var rainChancePercent: Int? {
        guard let p = forecasts.nearMeForecast?.hourly.first?.precipProbability else { return nil }
        return Int(p * 100)
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Weather Near Me", systemImage: "cloud.sun.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spGold)
                Spacer()
                alertBadge
            }

            if let c = weather.snapshot?.conditions {
                HStack(spacing: 12) {
                    Image(systemName: c.kind.systemImage)
                        .font(.system(size: 30))
                        .foregroundStyle(Color.spGold)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Int(c.temperatureF))°F")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.spTextPrimary)
                        Text(c.summary)
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let rain = rainChancePercent {
                            Label("\(rain)% rain", systemImage: "drop.fill")
                        }
                        Label("\(Int(c.windSpeedMph)) mph", systemImage: "wind")
                        Label(String(format: "%.0f mi", c.visibilityMiles), systemImage: "eye.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                }
            } else {
                placeholder("Getting conditions near you…")
            }
        }
        .padding()
        .background(Color.spCardBg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.spGold.opacity(0.2), lineWidth: 1))
    }

    private var alertBadge: some View {
        Group {
            if !forecasts.activeSevereAlerts.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.octagon.fill")
                    Text("Severe")
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.spDanger, in: Capsule())
            } else if let latest = alerts.latestActive {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(latest.severity.label)
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(latest.severity.color, in: Capsule())
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Clear")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.spSuccess)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        HStack {
            ProgressView().tint(Color.spGold)
            Text(text).font(.caption).foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

// MARK: - Rate Near Me

struct RateNearMeCard: View {
    @StateObject private var rates = FreightRateService.shared
    @ObservedObject private var location = LocationManager.shared
    @State private var showMaps = false
    @State private var equipment: EquipmentType = .dryVan

    private var market: FreightMarket? {
        rates.nearestMarket(to: location.coordinate)
    }

    var body: some View {
        Button { showMaps = true } label: { cardBody }
            .buttonStyle(.plain)
            .onAppear {
                location.startUpdating()
                rates.startAutoRefresh(around: LocationManager.shared.coordinate)
            }
            .sheet(isPresented: $showMaps) {
                MapsHubSheet(initialMode: .rate)
            }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Rate Near Me", systemImage: "dollarsign.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spGold)
                Spacer()
                if let m = market {
                    Text(m.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                        .lineLimit(1)
                }
            }

            if let m = market, let rate = m.rate(for: equipment) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "$%.2f", rate.ratePerMile))
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(strengthColor(rate.strength))
                    Text("/mi")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: rate.trend.systemImage)
                        Text(rate.trend.displayName)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(trendColor(rate.trend))
                }

                HStack(spacing: 8) {
                    demandIndicator(rate.loadToTruckRatio)
                    Spacer()
                    Picker("", selection: $equipment) {
                        ForEach(EquipmentType.allCases) { eq in
                            Text(eq.shortName).tag(eq)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
            } else {
                placeholder("Finding your market…")
            }
        }
        .padding()
        .background(Color.spCardBg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.spGold.opacity(0.2), lineWidth: 1))
    }

    private func demandIndicator(_ ltr: Double) -> some View {
        let (label, color): (String, Color) = {
            if ltr >= 4.5 { return ("High demand", .spSuccess) }
            if ltr >= 2.5 { return ("Moderate demand", .spWarning) }
            return ("Soft demand", .spDanger)
        }()
        return HStack(spacing: 5) {
            Image(systemName: "chart.bar.fill").font(.caption2)
            Text("\(label) · \(String(format: "%.1f", ltr)) LTR")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
    }

    private func placeholder(_ text: String) -> some View {
        HStack {
            ProgressView().tint(Color.spGold)
            Text(text).font(.caption).foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func strengthColor(_ s: RateStrength) -> Color {
        switch s {
        case .strong: return .spSuccess
        case .average: return .spWarning
        case .weak: return .spDanger
        }
    }

    private func trendColor(_ t: MarketTrend) -> Color {
        switch t {
        case .up: return .spSuccess
        case .flat: return .spTextSecondary
        case .down: return .spDanger
        }
    }
}

// MARK: - Sheet wrapper so cards can open the Maps content with a chosen mode.

private struct MapsHubSheet: View {
    let initialMode: MapsMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MapsHubModeContainer(initialMode: initialMode)
                .navigationTitle("Maps")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(Color.spGold)
                    }
                }
        }
    }
}

/// Lightweight container that reuses the Rate/Weather views with a preset mode.
private struct MapsHubModeContainer: View {
    let initialMode: MapsMode
    @State private var mode: MapsMode
    @StateObject private var rateVM = RateMapViewModel()
    @StateObject private var weatherVM = WeatherMapViewModel()

    init(initialMode: MapsMode) {
        self.initialMode = initialMode
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Map Mode", selection: $mode) {
                ForEach(MapsMode.allCases) { m in
                    Label(m.rawValue, systemImage: m.systemImage).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)

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
        .background(Color.spBackground.ignoresSafeArea())
    }
}
