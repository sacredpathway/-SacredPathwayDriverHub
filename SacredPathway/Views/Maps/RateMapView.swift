import SwiftUI
import MapKit

// =============================================================================
// MARK: - RateMapView (Live Freight Rate Map)
// -----------------------------------------------------------------------------
// Full-screen interactive U.S. map of freight markets, color-coded by rate
// strength (green/yellow/red), filterable by equipment, with national average
// RPMs and a "Center On My Truck" control. Built on the iOS 17 SwiftUI Map.
// The user's location is always shown via `UserAnnotation()`.
// =============================================================================

struct RateMapView: View {
    @ObservedObject var viewModel: RateMapViewModel
    /// `compact` trims chrome for the stacked "Both" layout.
    var compact: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            mapLayer

            VStack(spacing: 8) {
                if !compact {
                    nationalAveragesBar
                }
                equipmentFilter
                Spacer()
            }
            .padding(compact ? 8 : 12)

            VStack {
                Spacer()
                HStack {
                    legend
                    Spacer()
                    centerButton
                }
                .padding(compact ? 8 : 12)
            }
        }
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .sheet(item: $viewModel.selectedMarket) { market in
            MarketDetailSheet(market: market, equipment: viewModel.equipment)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: Map
    private var mapLayer: some View {
        Map(position: $viewModel.cameraPosition) {
            UserAnnotation()

            ForEach(viewModel.markets) { market in
                Annotation(market.title, coordinate: market.coordinate) {
                    MarketPin(
                        rpm: market.ratePerMile(for: viewModel.equipment),
                        color: viewModel.color(for: market),
                        trend: market.rate(for: viewModel.equipment)?.trend ?? .flat
                    )
                    .onTapGesture { viewModel.selectedMarket = market }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .ignoresSafeArea(edges: compact ? [] : .bottom)
    }

    // MARK: National averages
    private var nationalAveragesBar: some View {
        HStack(spacing: 0) {
            avgCell("Dry Van", viewModel.formattedNationalAverage(.dryVan), .dryVan)
            divider
            avgCell("Reefer", viewModel.formattedNationalAverage(.reefer), .reefer)
            divider
            avgCell("Flatbed", viewModel.formattedNationalAverage(.flatbed), .flatbed)
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.spGold.opacity(0.3), lineWidth: 1)
        )
    }

    private func avgCell(_ title: String, _ value: String, _ eq: EquipmentType) -> some View {
        VStack(spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.spTextSecondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(viewModel.equipment == eq ? Color.spGold : Color.spTextPrimary)
            Text("avg RPM")
                .font(.system(size: 8))
                .foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(Color.spGold.opacity(0.25)).frame(width: 1, height: 32)
    }

    // MARK: Equipment filter
    private var equipmentFilter: some View {
        Picker("Equipment", selection: $viewModel.equipment) {
            ForEach(EquipmentType.allCases) { eq in
                Text(eq.displayName).tag(eq)
            }
        }
        .pickerStyle(.segmented)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Legend
    private var legend: some View {
        HStack(spacing: 10) {
            legendDot(.spSuccess, "Strong")
            legendDot(.spWarning, "Avg")
            legendDot(.spDanger, "Weak")
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).foregroundStyle(Color.spTextPrimary)
        }
    }

    // MARK: Center on my truck
    private var centerButton: some View {
        Button {
            viewModel.centerOnTruck()
        } label: {
            Label("Center On My Truck", systemImage: "location.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.spDarkGreen, in: Capsule())
                .overlay(Capsule().stroke(Color.spGold.opacity(0.6), lineWidth: 1))
        }
    }
}

// MARK: - Market pin
private struct MarketPin: View {
    let rpm: Double
    let color: Color
    let trend: MarketTrend

    var body: some View {
        VStack(spacing: 2) {
            Text(rpm > 0 ? String(format: "$%.2f", rpm) : "—")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(color, in: Capsule())
                .overlay(
                    Capsule().stroke(.white.opacity(0.85), lineWidth: 1.2)
                )
                .overlay(alignment: .topTrailing) {
                    Image(systemName: trend.systemImage)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Circle().fill(color.opacity(0.95)))
                        .offset(x: 5, y: -5)
                }
            Image(systemName: "triangle.fill")
                .font(.system(size: 7))
                .foregroundStyle(color)
                .rotationEffect(.degrees(180))
                .offset(y: -2)
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}
