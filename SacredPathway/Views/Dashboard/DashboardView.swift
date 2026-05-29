import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var supabase: SupabaseService
    // Observed so changing Pay Week Start Day in Settings re-shapes the
    // "This Week" totals instantly without needing to re-launch the app.
    @ObservedObject private var payWeek = PayWeekService.shared
    @ObservedObject private var appMode = AppMode.shared
    @ObservedObject private var localLoads = LocalLoadsRepository.shared
    @ObservedObject private var localExpenses = LocalExpensesRepository.shared
    // Canonical income source-of-truth. Routes between LocalLoadsRepository
    // and the Supabase cache based on AppMode, dedupes by id, and excludes
    // tombstoned (pending-delete) rows. Every income total on the dashboard
    // — Revenue, Net Profit, Key Metrics, Recent Loads — reads from this
    // and only this. Two devices in Cloud Mode see the same `loads.count`
    // here because they read the same Supabase rows through the same
    // dedupe + tombstone pipeline.
    @ObservedObject private var loadsSync = LoadsSyncService.shared
    @State private var allExpenses: [Expense] = []
    @State private var isLoading = true
    @State private var selectedPeriod: TimePeriod = .allTime
    /// Human-readable error surfaced when fetchLoads / fetchAllExpenses
    /// throws. Without this, a network blip or expired token would silently
    /// produce a zero-dollar dashboard that looks identical to "no data".
    @State private var loadError: String? = nil
    /// DEBUG-only: holds the multi-period dump produced by a long-press on
    /// the Revenue card. Renders in a sheet so the user can screenshot or
    /// AirDrop it to the engineering team when a weekly total looks off.
    @State private var debugDumpText: String? = nil

    /// Source of truth for dashboard totals — always the
    /// `LoadsSyncService.loads` snapshot. The service has already deduped,
    /// applied tombstones, and reconciled with the active backing store
    /// (LocalLoadsRepository or the Supabase cache). NEVER read
    /// `localLoads.loads` or a per-view `@State loads` array directly for
    /// totals — that's what produced device-to-device drift.
    private var sourceLoads: [Load] {
        loadsSync.loads
    }

    /// Source of truth for expense totals — local repo when offline.
    private var sourceExpenses: [Expense] {
        appMode.isLocal ? localExpenses.expenses : allExpenses
    }

    enum TimePeriod: String, CaseIterable {
        case week = "This Week"
        case month = "This Month"
        case allTime = "All Time"
    }

    // MARK: - Computed Metrics
    // Loads route through WeeklyStatsService — the centralized rule for
    // every period bucket. It dedupes by id before reducing, so duplicate
    // rows on disk (iCloud merge, historic double-save) can never inflate
    // a total. Pickup-date is the only date used; nil-pickup loads are
    // excluded from windowed totals per the 2026-05-24 spec.
    private var statsPeriod: StatsPeriod {
        switch selectedPeriod {
        case .week:    return .week
        case .month:   return .month
        case .allTime: return .allTime
        }
    }
    var filteredLoads: [Load] {
        WeeklyStatsService.loads(in: statsPeriod, loads: sourceLoads)
    }
    // Expenses keep `createdAt` — they have no pickup-date concept and
    // are not part of the "weekly load grouping" spec.
    var filteredExpenses: [Expense] {
        filterByPeriod(sourceExpenses, keyPath: \.createdAt)
    }
    var totalRevenue: Double { filteredLoads.reduce(0) { $0 + ($1.totalRevenue ?? 0) } }
    var totalExpenses: Double { filteredExpenses.reduce(0) { $0 + $1.amount } }
    var netProfit: Double { totalRevenue - totalExpenses }
    var totalMiles: Double { filteredLoads.reduce(0) { $0 + ($1.totalMiles ?? 0) } }
    var profitPerMile: Double { totalMiles > 0 ? netProfit / totalMiles : 0 }
    var costPerMile: Double { totalMiles > 0 ? totalExpenses / totalMiles : 0 }
    var revenuePerMile: Double { totalMiles > 0 ? totalRevenue / totalMiles : 0 }
    var loadCount: Int { filteredLoads.count }
    var avgRevenuePerLoad: Double { loadCount > 0 ? totalRevenue / Double(loadCount) : 0 }

    var fuelExpenses: Double {
        filteredExpenses.filter { $0.category.lowercased() == "fuel" }.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        if appMode.isLocal {
                            LocalModeBanner()
                                .padding(.horizontal, -16)
                        }
                        headerSection
                        periodPicker
                        if let loadError {
                            loadErrorBanner(message: loadError)
                        }
                        financialCards
                        metricsRow
                        expenseBreakdown
                        recentLoadsSection
                        recentExpensesSection
                    }
                    .padding()
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.spBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image("SacredPathwayLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(supabase.currentProfile?.companyName ?? "Dashboard")
                            .font(.headline)
                            .foregroundStyle(Color.spGold)
                    }
                }
            }
            .refreshable { await loadData() }
            .task { await loadData() }
        }
    }

    // MARK: - Header
    // The toolbar already shows the company logo + name in the navigation
    // bar, so the in-content header doesn't repeat the company name. Instead
    // it's a quick at-a-glance: greeting + today's date. Saves ~30 vertical
    // points and removes a redundancy.
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.spTextPrimary)
            Text(todayString)
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Welcome back"
        }
    }

    private var todayString: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: Date())
    }

    // MARK: - Period Picker
    private var periodPicker: some View {
        HStack(spacing: 8) {
            ForEach(TimePeriod.allCases, id: \.self) { period in
                Button {
                    withAnimation { selectedPeriod = period }
                } label: {
                    Text(period.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(selectedPeriod == period ? Color.spGold : Color.spCardBg)
                        .foregroundStyle(selectedPeriod == period ? Color.spBlack : Color.spTextSecondary)
                        .clipShape(Capsule())
                }
            }
            Spacer()
        }
    }

    // MARK: - Financial Cards
    private var financialCards: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                SummaryCard(title: "Revenue", value: totalRevenue.asCurrency, color: .spGreenAccent, icon: "arrow.up.right")
                    // DEBUG-only: long-press the Revenue card to dump the
                    // exact records feeding the headline number — Weekly,
                    // Biweekly, Monthly, Last-30-Days, and All Time. Lets
                    // the user prove on the spot when a total looks wrong.
                    #if DEBUG
                    .onLongPressGesture(minimumDuration: 0.6) {
                        // Long-press now dumps the full cross-device audit
                        // (device, mode, sync timestamp, dupes, tombstones,
                        // every record) on top of the per-period totals.
                        // Replaces the older per-period-only dump because
                        // this is a strict superset and matches the
                        // 2026-05-25 cross-device data-consistency spec.
                        debugDumpText = LoadsSyncService.shared.crossDeviceAuditReport()
                        print(debugDumpText ?? "")
                    }
                    #endif
                SummaryCard(title: "Expenses", value: totalExpenses.asCurrency, color: .spDanger, icon: "arrow.down.left")
            }
            SummaryCard(
                title: "Net Profit",
                value: netProfit.asCurrency,
                color: netProfit >= 0 ? .spDarkGreen : .spDanger,
                icon: netProfit >= 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
        }
        #if DEBUG
        .sheet(item: Binding(
            get: { debugDumpText.map { DebugDump(text: $0) } },
            set: { debugDumpText = $0?.text }
        )) { dump in
            NavigationStack {
                ScrollView {
                    Text(dump.text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Cross-Device Audit")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        // ShareLink so the dump can be AirDropped / mailed
                        // to engineering directly from a tester's device —
                        // no screenshots, no copy/paste truncation.
                        ShareLink(item: dump.text)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { debugDumpText = nil }
                    }
                }
            }
        }
        #endif
    }

    // MARK: - Key Metrics Row
    private var metricsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Key Metrics")
                .font(.headline)
                .foregroundStyle(Color.spGold)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    metricPill("Profit/Mile", value: String(format: "$%.2f", profitPerMile), color: profitPerMile >= 0.50 ? .spSuccess : .spDanger)
                    metricPill("Rev/Mile", value: String(format: "$%.2f", revenuePerMile), color: .spGold)
                    metricPill("Cost/Mile", value: String(format: "$%.2f", costPerMile), color: .spWarning)
                    metricPill("Loads", value: "\(loadCount)", color: .spGold)
                    metricPill("Total Miles", value: String(format: "%.0f", totalMiles), color: .spGreenAccent)
                    metricPill("Avg/Load", value: avgRevenuePerLoad.asCurrency, color: .spGold)
                }
            }
        }
    }

    private func metricPill(_ title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Expense Breakdown
    private var expenseBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Expense Breakdown")
                .font(.headline)
                .foregroundStyle(Color.spGold)

            let grouped = Dictionary(grouping: filteredExpenses) { $0.category.lowercased() }
            let sorted = grouped.sorted { $0.value.reduce(0) { $0 + $1.amount } > $1.value.reduce(0) { $0 + $1.amount } }

            if sorted.isEmpty {
                Text("Start tracking your finances to see your overview.")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                // Baseline (v2.1.1_upload/iPhone/01) shows the four category
                // rows inside a SINGLE rounded card. Applying `.background`
                // to a `ForEach` clips each row individually instead, so
                // wrap the ForEach in a VStack and clip once at the parent.
                VStack(spacing: 0) {
                    ForEach(sorted, id: \.key) { category, expenses in
                        let total = expenses.reduce(0) { $0 + $1.amount }
                        let pct = totalExpenses > 0 ? total / totalExpenses * 100 : 0
                        HStack {
                            Image(systemName: categoryIcon(category))
                                .foregroundStyle(categoryColor(category))
                                .frame(width: 24)
                            Text(category.capitalized)
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextPrimary)
                            Spacer()
                            Text(total.asCurrency)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.spTextPrimary)
                            Text(String(format: "%.0f%%", pct))
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Recent Loads
    private var recentLoadsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Loads")
                .font(.headline)
                .foregroundStyle(Color.spGold)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80).tint(Color.spGold)
            } else if sourceLoads.isEmpty {
                // Empty state had been gated on the cloud-only `loads` array,
                // so Local Mode would show "No loads yet" forever even when
                // there were rows in LocalLoadsRepository. Baseline screenshot
                // (v2.1.1_upload/iPhone/01) has Recent Loads populated.
                VStack(spacing: 12) {
                    Image(systemName: "truck.box")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.spTextSecondary)
                    Text("No loads yet")
                        .font(.headline)
                        .foregroundStyle(Color.spTextSecondary)
                    Text("Tap the + tab to add your first load")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ForEach(sourceLoads.prefix(5)) { load in
                    NavigationLink(destination: LoadDetailView(load: load)) {
                        LoadRowView(load: load)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Recent Expenses
    private var recentExpensesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Expenses")
                .font(.headline)
                .foregroundStyle(Color.spGold)

            if sourceExpenses.isEmpty {
                // Same Local-Mode gating bug as Recent Loads — empty state
                // had been keyed off the cloud-only `allExpenses`. Switched
                // to `sourceExpenses` so Local Mode renders real rows.
                Text("Start tracking your finances to see your overview.")
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                // Wrap the ForEach in a VStack so the unified card style
                // (one rounded background containing every row) matches the
                // Expense Breakdown pattern in the v2.1.1 baseline. The old
                // ForEach-only modifier clipped each row individually.
                VStack(spacing: 0) {
                    ForEach(sourceExpenses.prefix(5)) { expense in
                        HStack(spacing: 10) {
                            Image(systemName: categoryIcon(expense.category))
                                .foregroundStyle(categoryColor(expense.category))
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(expense.category.capitalized)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.spTextPrimary)
                                if let vendor = expense.vendorName, !vendor.isEmpty {
                                    Text(vendor).font(.caption).foregroundStyle(Color.spTextSecondary)
                                }
                            }
                            Spacer()
                            Text(expense.amount.asCurrency)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.spDanger)
                        }
                        .padding(10)
                    }
                }
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Error banner

    /// Inline red-tinted card shown above the tiles when the most recent
    /// fetch threw. Replaces the previous silent failure (catch { print }).
    /// Tappable in the future if we want a retry shortcut; today the
    /// existing pull-to-refresh / .task path is the recovery mechanism.
    @ViewBuilder
    private func loadErrorBanner(message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.spDanger)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't refresh dashboard")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.spDanger.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.spDanger.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Data Loading
    private func loadData() async {
        isLoading = true
        loadError = nil
        // Loads route through LoadsSyncService.refresh — that one call
        // populates the canonical store (Supabase in Cloud Mode, local
        // JSON snapshot in Local Mode), applies dedupe + tombstones, and
        // republishes to every observer. Expenses still load directly
        // for now; the cross-device hardening shipped in this pass is
        // scoped to income/load totals per the user request.
        await loadsSync.refresh(supabase: supabase)
        if loadsSync.lastSyncError != nil, !appMode.isLocal {
            loadError = "Couldn't load your latest data: \(loadsSync.lastSyncError ?? ""). Pull down to retry."
        }

        if appMode.isLocal {
            isLoading = false
            return
        }
        do {
            allExpenses = try await supabase.fetchAllExpenses()
        } catch {
            print("Error loading dashboard expenses: \(error)")
            if loadError == nil {
                loadError = "Couldn't load your latest data: \(error.localizedDescription). Pull down to retry."
            }
        }
        isLoading = false
    }

    // MARK: - Filtering
    private func filterByPeriod<T>(_ items: [T], keyPath: KeyPath<T, Date?>) -> [T] {
        guard selectedPeriod != .allTime else { return items }
        let now = Date()
        switch selectedPeriod {
        case .week:
            // Pay-week buckets are user-configurable in Settings → Pay Week.
            // Default is Monday → Sunday (ISO). Centralized so changing the
            // setting re-shapes every weekly total in the app immediately.
            let week = PayWeekService.shared.weekInterval(for: now)
            return items.filter {
                let d = $0[keyPath: keyPath] ?? .distantPast
                return d >= week.start && d < week.end
            }
        case .month:
            let cal = Calendar.current
            guard let month = cal.dateInterval(of: .month, for: now) else { return items }
            return items.filter {
                let d = $0[keyPath: keyPath] ?? .distantPast
                return d >= month.start && d < month.end
            }
        case .allTime:
            return items
        }
    }

    // MARK: - Category Helpers
    private func categoryIcon(_ cat: String) -> String {
        switch cat.lowercased() {
        case "fuel": return "fuelpump.fill"
        case "lumper": return "person.2.fill"
        case "toll": return "road.lanes"
        case "repair": return "wrench.and.screwdriver.fill"
        case "insurance": return "shield.checkered"
        case "maintenance": return "gearshape.2.fill"
        default: return "dollarsign.circle.fill"
        }
    }

    private func categoryColor(_ cat: String) -> Color {
        switch cat.lowercased() {
        case "fuel": return Color(red: 0.2, green: 0.6, blue: 0.9)
        case "lumper": return Color(red: 0.8, green: 0.5, blue: 0.2)
        case "toll": return Color(red: 0.6, green: 0.4, blue: 0.8)
        case "repair": return .spDanger
        case "insurance": return .spSuccess
        case "maintenance": return .spWarning
        default: return .spTextSecondary
        }
    }
}

// MARK: - Summary Card
struct SummaryCard: View {
    let title: String
    let value: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
                Text(title).font(.caption).foregroundStyle(Color.spTextSecondary).fontWeight(.medium)
                Spacer()
            }
            Text(value).font(.title2).fontWeight(.bold).foregroundStyle(Color.spGold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Load Row
struct LoadRowView: View {
    let load: Load

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(load.loadNumber.map { "#\($0)" } ?? "No Load #")
                        .font(.headline).foregroundStyle(Color.spGold)
                    if let broker = load.brokerName {
                        Text(broker).font(.caption).foregroundStyle(Color.spTextSecondary)
                    }
                }
                Spacer()
                Text(load.status?.capitalized ?? "Pending")
                    .font(.caption).fontWeight(.medium)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(statusColor.opacity(0.2))
                    .foregroundStyle(statusColor).clipShape(Capsule())
            }
            if let origin = load.origin, let dest = load.destination {
                HStack {
                    Image(systemName: "location.fill").font(.caption).foregroundStyle(Color.spGoldLight)
                    Text("\(origin) → \(dest)").font(.caption).foregroundStyle(Color.spTextSecondary)
                    Spacer()
                }
            }
            if let weight = load.weightDisplay {
                HStack {
                    Image(systemName: "shippingbox.fill").font(.caption).foregroundStyle(Color.spGoldLight)
                    Text("Weight: \(weight)").font(.caption).foregroundStyle(Color.spTextSecondary)
                    Spacer()
                }
            }
            Divider().background(Color.spTextSecondary.opacity(0.2))
            HStack {
                if let rev = load.totalRevenue {
                    Text(rev.asCurrency).font(.subheadline.weight(.semibold)).foregroundStyle(Color.spDarkGreen)
                }
                Spacer()
                if let miles = load.totalMiles, miles > 0, let rev = load.totalRevenue {
                    let rpm = rev / miles
                    Text(String(format: "$%.2f/mi", rpm))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(rpm >= 2.50 ? Color.spSuccess : Color.spWarning)
                }
            }
        }
        .padding(12).background(Color.spCardBg).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spGoldLight.opacity(0.1), lineWidth: 1))
    }

    private var statusColor: Color {
        switch load.status {
        case "delivered": return Color.spDarkGreen
        case "in_transit": return Color.spGoldLight
        case "settled": return Color.spGreenAccent
        default: return Color.spGoldLight
        }
    }
}

#Preview { DashboardView().environmentObject(SupabaseService()) }

#if DEBUG
/// Bridge so SwiftUI's `.sheet(item:)` can present a plain `String?` —
/// `Identifiable` requirement is fulfilled by the wrapped text itself.
private struct DebugDump: Identifiable {
    let text: String
    var id: String { String(text.prefix(64)) }
}
#endif
