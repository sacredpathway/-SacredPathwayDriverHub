import SwiftUI

// =============================================================================
//  SettlementOverviewSection — company financial tiles with a date filter
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). All figures come from
//  `SettlementInsights.dashboard`. Estimated profit is labelled as such.
// =============================================================================

struct SettlementOverviewSection: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var repo = SettlementRepository.shared
    @ObservedObject private var loadsSync = LoadsSyncService.shared
    @ObservedObject private var payWeek = PayWeekService.shared
    @ObservedObject private var localExpenses = LocalExpensesRepository.shared

    @State private var preset: SettlementDateRangePreset = .thisWeek
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var cloudExpenses: [Expense] = []

    private var range: SettlementDateRange {
        SettlementDateRange.preset(
            preset,
            firstWeekday: payWeek.firstWeekday,
            custom: SettlementDateRange(start: min(customStart, customEnd), end: max(customStart, customEnd)))
    }

    private var expenses: [Expense] {
        AppMode.shared.isLocal ? localExpenses.expenses : cloudExpenses
    }

    private var metrics: SettlementDashboardMetrics {
        SettlementInsights.dashboard(
            ledger: repo.ledger,
            loads: loadsSync.loads,
            expenses: expenses,
            range: range)
    }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        let m = metrics
        let showCompany = repo.viewer.can(.viewCompanyFinancials)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OVERVIEW")
                    .font(.caption.weight(.heavy))
                    .tracking(1.2)
                    .foregroundStyle(Color.spTextSecondary)
                Spacer()
                Picker("Range", selection: $preset) {
                    ForEach(SettlementDateRangePreset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.menu)
            }
            if preset == .custom {
                HStack {
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                        .labelsHidden()
                    Text("to").foregroundStyle(Color.spTextSecondary)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date)
                        .labelsHidden()
                }
            }
            Text(range.description)
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)

            LazyVGrid(columns: columns, spacing: 10) {
                SettlementMetricTile(title: "Gross Revenue", value: m.grossRevenue.formatted,
                                     icon: "arrow.up.right", tint: .spGreenAccent)
                SettlementMetricTile(title: "Driver Pay", value: m.driverPay.formatted,
                                     icon: "person.fill", footnote: "approved + paid")
                SettlementMetricTile(title: "Completed Loads", value: "\(m.completedLoads)",
                                     icon: "checkmark.seal.fill", tint: .spSuccess)
                SettlementMetricTile(title: "Pending Loads", value: "\(m.pendingLoads)",
                                     icon: "clock.fill", tint: .spWarning)
                if showCompany {
                    SettlementMetricTile(title: "Fuel", value: m.fuel.formatted,
                                         icon: "fuelpump.fill", tint: .spDanger)
                    SettlementMetricTile(title: "Other Expenses", value: m.otherExpenses.formatted,
                                         icon: "creditcard.fill", tint: .spDanger)
                    SettlementMetricTile(title: "Company Retained", value: m.companyRetained.formatted,
                                         icon: "building.columns.fill")
                    SettlementMetricTile(title: "Estimated Profit", value: m.estimatedProfit.formatted,
                                         icon: "chart.line.uptrend.xyaxis",
                                         tint: m.estimatedProfit.isNegative ? .spDanger : .spSuccess,
                                         footnote: "Estimated")
                }
                SettlementMetricTile(title: "Unpaid Settlements", value: "\(m.unpaidCount) · \(m.unpaidAmount.formatted)",
                                     icon: "hourglass", tint: .spWarning,
                                     footnote: m.draftCount > 0 ? "\(m.draftCount) draft\(m.draftCount == 1 ? "" : "s") in progress" : nil)
                SettlementMetricTile(title: "Paid Settlements", value: "\(m.paidCount) · \(m.paidAmount.formatted)",
                                     icon: "dollarsign.circle.fill", tint: .spSuccess)
            }
        }
        .task(id: AppMode.shared.isLocal) {
            if !AppMode.shared.isLocal {
                cloudExpenses = (try? await supabase.fetchAllExpenses()) ?? []
            }
        }
    }
}

/// Compact card for the Home dashboard. Links into the Settlements tab's data
/// without duplicating the full overview.
struct SettlementDashboardSummaryCard: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var repo = SettlementRepository.shared
    @ObservedObject private var loadsSync = LoadsSyncService.shared
    @ObservedObject private var payWeek = PayWeekService.shared

    var body: some View {
        let range = SettlementDateRange.preset(.thisWeek, firstWeekday: payWeek.firstWeekday)
        let m = SettlementInsights.dashboard(ledger: repo.ledger, loads: loadsSync.loads,
                                             expenses: [], range: range)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Settlements", systemImage: "doc.text.fill")
                    .font(.headline)
                    .foregroundStyle(Color.spTextPrimary)
                Spacer()
                Text("This week")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
            HStack(spacing: 10) {
                summaryStat("Driver Pay", m.driverPay.formatted)
                summaryStat("Unpaid", "\(m.unpaidCount)")
                summaryStat("Drafts", "\(m.draftCount)")
                summaryStat("Paid", "\(m.paidCount)")
            }
        }
        .padding(14)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            repo.attach(supabase)
            if !repo.hasLoaded { await repo.reload() }
        }
    }

    private func summaryStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                .foregroundStyle(Color.spGold)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
