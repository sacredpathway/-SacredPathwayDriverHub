import SwiftUI

struct LoadDetailView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    let load: Load
    @State private var expenses: [Expense] = []

    // Edit / delete state
    @State private var showingEditSheet = false
    @State private var showingDeleteConfirm = false
    @State private var deleteError: String?
    @State private var isDeleting = false

    // Broker contact info loaded lazily so "Share Load Summary" can include
    // phone, extension, email, and last-known MC# without slowing the
    // initial detail render.
    @State private var brokerContact: BrokerContact?
    @State private var weeklyRevenueTotal: Double?

    var totalExpenses: Double { expenses.reduce(0) { $0 + $1.amount } }
    var profit: Double { (load.totalRevenue ?? 0) - totalExpenses }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        if let broker = load.brokerName {
                            Text(broker)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundStyle(Color.spGold)
                        }
                        if let mc = load.brokerMcNumber {
                            Text("MC# \(mc)")
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                    }

                    // Route
                    if let origin = load.origin, let dest = load.destination {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ROUTE")
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                            Text("\(origin) → \(dest)")
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextPrimary)
                            if let miles = load.totalMiles {
                                Text("\(Int(miles)) miles")
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextSecondary)
                            }
                        }
                    }

                    Divider()
                        .background(Color.spCardBgLight)

                    // Revenue
                    VStack(alignment: .leading, spacing: 8) {
                        Text("REVENUE")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                        detailRow("Line haul", value: load.lineHaulRate)
                        detailRow("Fuel surcharge", value: load.fuelSurcharge)
                        detailRow("Accessorials", value: load.accessorialCharges)
                        Divider()
                            .background(Color.spCardBgLight)
                        HStack {
                            Text("Total Revenue")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.spTextPrimary)
                            Spacer()
                            Text((load.totalRevenue ?? 0).asCurrency)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.spDarkGreen)
                        }
                    }

                    Divider()
                        .background(Color.spCardBgLight)

                    // Expenses
                    VStack(alignment: .leading, spacing: 8) {
                        Text("EXPENSES")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                        if expenses.isEmpty {
                            Text("No expenses recorded")
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextSecondary)
                        } else {
                            ForEach(expenses) { expense in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(expense.category.capitalized)
                                            .foregroundStyle(Color.spTextPrimary)
                                        if let vendor = expense.vendorName {
                                            Text(vendor)
                                                .font(.caption)
                                                .foregroundStyle(Color.spTextSecondary)
                                        }
                                    }
                                    Spacer()
                                    Text(expense.amount.asCurrency)
                                        .foregroundStyle(Color.spDanger)
                                }
                            }
                            Divider()
                                .background(Color.spCardBgLight)
                            HStack {
                                Text("Total Expenses")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.spTextPrimary)
                                Spacer()
                                Text(totalExpenses.asCurrency)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.spDanger)
                            }
                        }
                    }

                    Divider()
                        .background(Color.spCardBgLight)

                    // Profit
                    VStack(spacing: 8) {
                        HStack {
                            Text("PROFIT")
                                .font(.headline)
                                .foregroundStyle(Color.spGold)
                            Spacer()
                            Text(profit.asCurrency)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundStyle(profit >= 0 ? Color.spDarkGreen : Color.spDanger)
                        }
                        if let miles = load.totalMiles, miles > 0 {
                            HStack {
                                Text("Rate/mile")
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextSecondary)
                                Spacer()
                                Text(((load.totalRevenue ?? 0) / miles).asCurrency)
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextPrimary)
                            }
                        }
                    }
                    .padding()
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle("Load #\(load.loadNumber ?? "—")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Native iOS share sheet — plain-text load summary. Cleanest
                // placement: dedicated toolbar slot so it works without
                // opening the "..." menu. Long-press still lets the user copy.
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: loadSummaryText()) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(Color.spGold)
                    }
                    .accessibilityLabel("Share Load Summary")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingEditSheet = true
                        } label: {
                            Label("Edit Load", systemImage: "pencil")
                        }
                        ShareLink(item: loadSummaryText()) {
                            Label("Share Load Summary", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label("Delete Load", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Color.spGold)
                    }
                    .disabled(isDeleting)
                }
            }
            .sheet(isPresented: $showingEditSheet) {
                ManualLoadEntryView(existingLoad: load)
                    .environmentObject(supabase)
            }
            .confirmationDialog(
                "Delete this load?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Load", role: .destructive) {
                    performDelete()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will permanently remove Load \(load.loadNumber ?? "—") and any expenses or documents attached to it. This cannot be undone.")
            }
            .alert("Couldn't delete load",
                   isPresented: Binding(
                       get: { deleteError != nil },
                       set: { if !$0 { deleteError = nil } }
                   )) {
                Button("OK") { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
            .task {
                if let loadId = load.id {
                    if AppMode.shared.isLocal {
                        expenses = await LocalExpensesRepository.shared.fetch(forLoad: loadId)
                    } else {
                        do { expenses = try await supabase.fetchExpenses(forLoad: loadId) }
                        catch { print("Error loading expenses: \(error)") }
                    }
                }
                await loadBrokerContactIfAvailable()
                await loadWeeklyRevenueTotal()
            }
        }
    }

    // MARK: - Share Load Summary

    /// Look up the broker's latest contact (phone / email / extension) so
    /// the share text has the info the user actually wants to forward.
    /// Best-effort — failures are silent, summary just omits those lines.
    private func loadBrokerContactIfAvailable() async {
        guard let brokerName = load.brokerName,
              !brokerName.isEmpty else { return }
        do {
            let brokers = try await supabase.fetchBrokers()
            let target = Broker.normalize(brokerName)
            guard let broker = brokers.first(where: {
                ($0.normalizedName ?? Broker.normalize($0.brokerName)) == target
            }), let brokerId = broker.id else { return }
            let contacts = try await supabase.fetchContacts(forBroker: brokerId)
            brokerContact = contacts.first
        } catch {
            // Non-fatal — the summary will fall back to whatever lives on
            // the Load row.
        }
    }

    /// Compute this pay-week's total revenue (across ALL loads, not just
    /// this load). Surfaced at the bottom of the share text as a quick
    /// "for context" footer per the user spec.
    private func loadWeeklyRevenueTotal() async {
        do {
            let all = try await supabase.fetchLoads()
            let week = PayWeekService.shared.weekInterval()
            let total = all.reduce(0.0) { acc, l in
                let d = l.pickupDate ?? l.createdAt ?? .distantPast
                guard d >= week.start && d < week.end else { return acc }
                return acc + (l.totalRevenue ?? 0)
            }
            weeklyRevenueTotal = total
        } catch {
            // Non-fatal.
        }
    }

    /// Build the plain-text load summary the share sheet sends. Kept simple
    /// per the user's spec — copy/paste-friendly into Messages, Mail, Slack,
    /// etc. Every section is skipped if its data is missing so the body
    /// stays clean.
    private func loadSummaryText() -> String {
        var lines: [String] = []

        let header = "Load Summary"
        lines.append(header)
        lines.append(String(repeating: "─", count: header.count))

        if let n = load.loadNumber, !n.isEmpty {
            lines.append("Load #: \(n)")
        }
        if let s = load.status, !s.isEmpty {
            lines.append("Status: \(load.loadStatus.displayName)")
        }
        if let broker = load.brokerName, !broker.isEmpty {
            lines.append("Broker: \(broker)")
        }
        if let mc = load.brokerMcNumber, !mc.isEmpty {
            lines.append("Broker MC#: \(mc)")
        }
        if let phone = brokerContact?.phone, !phone.isEmpty {
            // Phone may already contain " x4421" extension suffix written by
            // SmartScanReviewView. Render verbatim so the extension is
            // preserved without us splitting + re-joining.
            lines.append("Broker phone: \(phone)")
        }
        if let email = brokerContact?.email, !email.isEmpty {
            lines.append("Broker email: \(email)")
        }

        lines.append("")  // blank line before route block

        if let o = load.origin, !o.isEmpty {
            lines.append("Pickup: \(o)" +
                         (load.pickupDate.map { " · \(formattedDate($0))" } ?? ""))
        }
        if let d = load.destination, !d.isEmpty {
            lines.append("Delivery: \(d)" +
                         (load.deliveryDate.map { " · \(formattedDate($0))" } ?? ""))
        }
        if let miles = load.totalMiles, miles > 0 {
            lines.append("Total miles: \(Int(miles))")
        }

        lines.append("")

        if let rate = load.totalRevenue, rate > 0 {
            lines.append("Rate / Load amount: \(rate.asCurrency)")
        } else if let line = load.lineHaulRate, line > 0 {
            lines.append("Line haul: \(line.asCurrency)")
        }
        if let fsc = load.fuelSurcharge, fsc > 0 {
            lines.append("FSC: \(fsc.asCurrency)")
        }
        if let acc = load.accessorialCharges, acc > 0 {
            lines.append("Accessorials: \(acc.asCurrency)")
        }

        if !expenses.isEmpty {
            lines.append("")
            lines.append("Expenses: \(totalExpenses.asCurrency)")
            lines.append("Profit: \(profit.asCurrency)")
        }

        if let weekly = weeklyRevenueTotal, weekly > 0 {
            lines.append("")
            let weekStart = PayWeekService.shared.weekInterval().start
            lines.append("Pay-week revenue (week of \(formattedDate(weekStart))): \(weekly.asCurrency)")
        }

        lines.append("")
        lines.append("— Sent from Sacred Pathway Driver Hub")

        return lines.joined(separator: "\n")
    }

    private func formattedDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df.string(from: date)
    }

    private func performDelete() {
        guard let loadId = load.id else { return }
        isDeleting = true
        Task {
            do {
                try await supabase.deleteLoad(id: loadId)
                dismiss()
            } catch {
                deleteError = "Delete failed: \(error.localizedDescription)"
                isDeleting = false
            }
        }
    }

    private func detailRow(_ label: String, value: Double?) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
            Spacer()
            Text((value ?? 0).asCurrency)
                .font(.subheadline)
                .foregroundStyle(Color.spGoldLight)
        }
    }
}

#Preview {
    NavigationStack {
        LoadDetailView(load: Load(
            id: UUID(), profileId: UUID(), loadNumber: "2841",
            brokerName: "XPO Logistics", origin: "Dallas, TX",
            destination: "Houston, TX", totalMiles: 239,
            lineHaulRate: 1650, fuelSurcharge: 150,
            accessorialCharges: 50, totalRevenue: 1850, status: "delivered"
        ))
        .environmentObject(SupabaseService())
    }
}
