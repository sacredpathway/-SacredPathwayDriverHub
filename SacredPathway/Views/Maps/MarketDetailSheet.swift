import SwiftUI

// =============================================================================
// MARK: - MarketDetailSheet
// -----------------------------------------------------------------------------
// Tapping a market pin presents this: city, state, average rate per mile,
// load-to-truck ratio, and market trend for the selected equipment, plus a
// compact breakdown across all three equipment types.
// =============================================================================

struct MarketDetailSheet: View {
    let market: FreightMarket
    let equipment: EquipmentType
    @Environment(\.dismiss) private var dismiss

    private var headlineRate: EquipmentRate? { market.rate(for: equipment) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    headlineCard
                    breakdownSection
                }
                .padding()
            }
            .background(Color.spBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.spGold)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(market.city)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Color.spTextPrimary)
            Text(stateName(market.state))
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headlineCard: some View {
        VStack(spacing: 12) {
            HStack {
                Label(equipment.displayName, systemImage: equipment.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spGold)
                Spacer()
                strengthBadge(market.strength(for: equipment))
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(headlineRate.map { String(format: "$%.2f", $0.ratePerMile) } ?? "—")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.spTextPrimary)
                Text("/ mi")
                    .font(.headline)
                    .foregroundStyle(Color.spTextSecondary)
            }

            HStack(spacing: 0) {
                stat("Load-to-Truck",
                     headlineRate.map { String(format: "%.1f", $0.loadToTruckRatio) } ?? "—",
                     "loads : truck")
                divider
                trendStat(headlineRate?.trend ?? .flat)
            }
        }
        .padding()
        .background(Color.spCardBg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.spGold.opacity(0.25), lineWidth: 1))
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("All Equipment")
                .font(.headline)
                .foregroundStyle(Color.spTextPrimary)

            VStack(spacing: 0) {
                ForEach(EquipmentType.allCases) { eq in
                    if let rate = market.rate(for: eq) {
                        HStack {
                            Label(eq.displayName, systemImage: eq.systemImage)
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextPrimary)
                            Spacer()
                            Text(String(format: "%.1f LTR", rate.loadToTruckRatio))
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                            Image(systemName: rate.trend.systemImage)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(trendColor(rate.trend))
                            Text(String(format: "$%.2f", rate.ratePerMile))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(strengthColor(rate.strength))
                                .frame(width: 64, alignment: .trailing)
                        }
                        .padding(.vertical, 10)
                        if eq != EquipmentType.allCases.last {
                            Divider().overlay(Color.spGold.opacity(0.15))
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(Color.spCardBg, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: helpers
    private var divider: some View {
        Rectangle().fill(Color.spGold.opacity(0.2)).frame(width: 1, height: 40)
    }

    private func stat(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.spTextSecondary)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.spTextPrimary)
            Text(caption)
                .font(.system(size: 9))
                .foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func trendStat(_ trend: MarketTrend) -> some View {
        VStack(spacing: 2) {
            Text("TREND")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.spTextSecondary)
            HStack(spacing: 4) {
                Image(systemName: trend.systemImage)
                Text(trend.displayName)
            }
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(trendColor(trend))
            Text("vs last period")
                .font(.system(size: 9))
                .foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func strengthBadge(_ strength: RateStrength) -> some View {
        Text(strength.displayName.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(strengthColor(strength), in: Capsule())
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

    private func stateName(_ code: String) -> String {
        let map: [String: String] = [
            "AL":"Alabama","AZ":"Arizona","CA":"California","CO":"Colorado","FL":"Florida",
            "GA":"Georgia","IL":"Illinois","IN":"Indiana","MN":"Minnesota","MO":"Missouri",
            "NC":"North Carolina","NJ":"New Jersey","OH":"Ohio","OK":"Oklahoma","OR":"Oregon",
            "PA":"Pennsylvania","TN":"Tennessee","TX":"Texas","UT":"Utah","WA":"Washington"
        ]
        return map[code] ?? code
    }
}
