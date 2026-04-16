import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var loads: [Load] = []
    @State private var allExpenses: [Expense] = []
    @State private var isLoading = true
    @State private var selectedPeriod: TimePeriod = .allTime

    enum TimePeriod: String, CaseIterable {
        case week = "This Week"
        case month = "This Month"
        case allTime = "All Time"
    }

    // MARK: - Computed Metrics
    var filteredLoads: [Load] {
        filterByPeriod(loads, keyPath: \.createdAt)
    }
    var filteredExpenses: [Expense] {
        filterByPeriod(allExpenses, keyPath: \.createdAt)
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
                        headerSection
                        periodPicker
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
                        Image(systemName: "truck.box.fill")
                            .foregroundStyle(Color.spGold)
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
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome back")
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
            Text(supabase.currentProfile?.companyName ?? "Dashboard")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.spGold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                SummaryCard(title: "Expenses", value: totalExpenses.asCurrency, color: .spDanger, icon: "arrow.down.left")
            }
            SummaryCard(
                title: "Net Profit",
                value: netProfit.asCurrency,
                color: netProfit >= 0 ? .spDarkGreen : .spDanger,
                icon: netProfit >= 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
        }
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
                Text("No expenses recorded")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
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
            } else if loads.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "truck.box")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.spTextSecondary)
                    Text("No loads yet")
                        .font(.headline)
                        .foregroundStyle(Color.spTextSecondary)
                    Text("Scan or upload a rate confirmation to get started")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ForEach(loads.prefix(5)) { load in
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

            if allExpenses.isEmpty {
                Text("No expenses recorded yet")
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(allExpenses.prefix(5)) { expense in
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
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Data Loading
    private func loadData() async {
        isLoading = true
        do {
            loads = try await supabase.fetchLoads()
            allExpenses = try await supabase.fetchAllExpenses()
        } catch {
            print("Error loading dashboard: \(error)")
        }
        isLoading = false
    }

    // MARK: - Filtering
    private func filterByPeriod<T>(_ items: [T], keyPath: KeyPath<T, Date?>) -> [T] {
        guard selectedPeriod != .allTime else { return items }
        let cal = Calendar.current
        let now = Date()
        let start: Date
        switch selectedPeriod {
        case .week: start = cal.date(byAdding: .day, value: -7, to: now)!
        case .month: start = cal.date(byAdding: .month, value: -1, to: now)!
        case .allTime: return items
        }
        return items.filter { ($0[keyPath: keyPath] ?? .distantPast) >= start }
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
