import SwiftUI

// =============================================================================
//  DriverSettlementsPortalView — what a DRIVER account sees
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). Read-only. Shows the approved and paid
//  settlements of the driver record(s) this account is linked to through the
//  carrier's `carrier_members` invite, plus a live estimate when the carrier
//  allows it. No company figures, no editing.
//
//  Server-side enforcement: migration 20260916120000 (SELECT-only RLS).
// =============================================================================

struct DriverSettlementsPortalView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var repo = SettlementRepository.shared

    private var settlements: [Settlement] {
        SettlementPermissions.visibleSettlements(repo.ledger.settlements, viewer: repo.viewer)
            .sorted { ($0.settlementPeriodEnd ?? .distantPast) > ($1.settlementPeriodEnd ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if repo.portalContexts.isEmpty && repo.hasLoaded {
                    SettlementEmptyState(
                        title: "Not linked to a carrier yet",
                        message: "When your carrier links your account to your driver profile, your approved and paid settlements will appear here.",
                        systemImage: "link")
                }
                if let error = repo.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.spWarning)
                }
                if let latest = settlements.first {
                    NavigationLink(value: SettlementRoute.settlement(latest.id ?? UUID())) {
                        SettlementNetPayHero(
                            amount: latest.netPayMoney,
                            caption: "\(latest.settlementStatus == .paid ? "Paid" : "Approved") · \(latest.periodDescription)")
                    }
                    .buttonStyle(.plain)
                }
                if let first = settlements.first, let driverId = first.driverId,
                   let ytd = SettlementInsights.ytd(repo.ledger, driverId: driverId,
                                                    year: Calendar.current.component(.year, from: Date())) {
                    SettlementCard(title: "Year to Date") {
                        SettlementAmountRow(title: "Earnings", amount: ytd.driverEarnings)
                        SettlementAmountRow(title: "Additions", amount: ytd.additions, style: .credit)
                        SettlementAmountRow(title: "Deductions", amount: ytd.deductions, style: .debit)
                        SettlementAmountRow(title: "Net Paid", amount: ytd.netPay)
                    }
                }
                advancesCard
                SettlementCard(title: "My Settlements", trailing: "\(settlements.count)") {
                    if settlements.isEmpty {
                        Text("No approved or paid settlements yet.")
                            .font(.subheadline)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    ForEach(settlements, id: \.id) { s in
                        if let id = s.id {
                            NavigationLink(value: SettlementRoute.settlement(id)) {
                                SettlementHistoryRow(settlement: s, driverName: repo.driverName(s.driverId))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("Settlement statements summarize pay for each period. They are not tax documents.")
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
            }
            .padding()
        }
        .task {
            repo.attach(supabase)
            await repo.reload()
        }
    }

    @ViewBuilder
    private var advancesCard: some View {
        // Only this driver's own advances, even if stale data were present.
        let linked = repo.viewer.linkedDriverIds
        let advances = repo.ledger.advances.filter { !$0.isFullyRecovered && linked.contains($0.driverId) }
        if !advances.isEmpty {
            SettlementCard(title: "Open Advances",
                           trailing: Money.sum(advances.map(\.outstandingBalance)).formatted) {
                ForEach(advances) { a in
                    SettlementAmountRow(title: a.descriptionText,
                                        subtitle: "\(SettlementFormat.date(a.date)) · of \(a.amount.formatted)",
                                        amount: a.outstandingBalance)
                }
            }
        }
    }
}

/// Entry point used from the Driver role's Paycheck tab.
struct DriverSettlementsLinkRow: View {
    var body: some View {
        NavigationLink {
            DriverSettlementsScreen()
        } label: {
            Label("My Settlements", systemImage: "doc.text.fill")
                .foregroundStyle(Color.spTextPrimary)
        }
    }
}

/// Standalone navigation host for the driver portal (the Paycheck tab has its
/// own NavigationStack, so routes are registered here).
struct DriverSettlementsScreen: View {
    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            DriverSettlementsPortalView()
        }
        .navigationTitle("My Settlements")
        .settlementDestinations()
    }
}
