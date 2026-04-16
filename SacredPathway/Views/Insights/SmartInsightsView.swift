import SwiftUI

struct SmartInsightsView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var loads: [Load] = []
    @State private var expenses: [Expense] = []
    @State private var isLoading = true
    @State private var aiSummary: String?
    @State private var isGeneratingAI = false

    // MARK: - Computed Insights
    var totalRevenue: Double { loads.reduce(0) { $0 + ($1.totalRevenue ?? 0) } }
    var totalExpenses: Double { expenses.reduce(0) { $0 + $1.amount } }
    var totalMiles: Double { loads.reduce(0) { $0 + ($1.totalMiles ?? 0) } }
    var avgRPM: Double { totalMiles > 0 ? totalRevenue / totalMiles : 0 }
    var fuelCost: Double { expenses.filter { $0.category.lowercased() == "fuel" }.reduce(0) { $0 + $1.amount } }
    var fuelCostPerMile: Double { totalMiles > 0 ? fuelCost / totalMiles : 0 }

    var underpricedLoads: [Load] {
        loads.filter { load in
            guard let rev = load.totalRevenue, let miles = load.totalMiles, miles > 0 else { return false }
            return (rev / miles) < 2.00
        }
    }

    var suggestedMinRPM: Double {
        guard totalMiles > 0 else { return 2.50 }
        let costPM = totalExpenses / totalMiles
        return max(costPM * 1.3, 2.00) // 30% margin over cost
    }

    var weeklyProfit: Double {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date())!
        let weekLoads = loads.filter { ($0.createdAt ?? .distantPast) >= weekAgo }
        let weekExpenses = expenses.filter { ($0.createdAt ?? .distantPast) >= weekAgo }
        return weekLoads.reduce(0) { $0 + ($1.totalRevenue ?? 0) } - weekExpenses.reduce(0) { $0 + $1.amount }
    }

    var projectedMonthlyProfit: Double { weeklyProfit * 4.33 }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        // AI Summary
                        aiSummarySection

                        // Alerts
                        alertsSection

                        // Rate Intelligence
                        rateSection

                        // Fuel Analysis
                        fuelSection

                        // Projections
                        projectionSection
                    }
                    .padding()
                }
                .navigationTitle("Smart Insights")
                .toolbarColorScheme(.dark, for: .navigationBar)
                .task { await loadData() }
            }
        }
    }

    // MARK: - AI Summary
    private var aiSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Color.spGold)
                Text("AI Weekly Summary").font(.headline).foregroundStyle(Color.spGold)
                Spacer()
                if !isGeneratingAI {
                    Button { Task { await generateAISummary() } } label: {
                        Image(systemName: "arrow.clockwise").foregroundStyle(Color.spGold)
                    }
                }
            }

            if isGeneratingAI {
                HStack { ProgressView().tint(Color.spGold); Text("Analyzing your data...").font(.caption).foregroundStyle(Color.spTextSecondary) }
                    .frame(maxWidth: .infinity).padding()
            } else if let summary = aiSummary {
                Text(summary).font(.subheadline).foregroundStyle(Color.spTextPrimary).lineSpacing(4)
            } else if !isLoading {
                Text("Tap refresh to generate an AI-powered summary of your week.")
                    .font(.caption).foregroundStyle(Color.spTextSecondary)
            }
        }
        .padding().background(Color.spCardBg).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Alerts
    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.spWarning)
                Text("Alerts").font(.headline).foregroundStyle(Color.spGold)
            }

            if underpricedLoads.isEmpty && fuelCostPerMile < 0.70 {
                alertCard("All Clear", message: "No issues detected. Your loads and expenses look healthy.", icon: "checkmark.circle.fill", color: .spSuccess)
            } else {
                if !underpricedLoads.isEmpty {
                    alertCard("Underpriced Loads", message: "\(underpricedLoads.count) load(s) below $2.00/mile. Consider negotiating higher rates.", icon: "dollarsign.arrow.circlepath", color: .spDanger)
                }
                if fuelCostPerMile >= 0.70 {
                    alertCard("High Fuel Costs", message: "Fuel cost is $\(String(format: "%.2f", fuelCostPerMile))/mile — above the $0.70 average. Shop for better fuel stops.", icon: "fuelpump.exclamationmark.fill", color: .spWarning)
                }
            }
        }
    }

    private func alertCard(_ title: String, message: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.spTextPrimary)
                Text(message).font(.caption).foregroundStyle(Color.spTextSecondary)
            }
        }
        .padding().background(Color.spCardBg).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Rate Intelligence
    private var rateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "chart.bar.fill").foregroundStyle(Color.spGold)
                Text("Rate Intelligence").font(.headline).foregroundStyle(Color.spGold)
            }
            HStack(spacing: 12) {
                metricCard("Avg Rate/Mile", String(format: "$%.2f", avgRPM), color: avgRPM >= 2.50 ? .spSuccess : .spWarning)
                metricCard("Min Suggested", String(format: "$%.2f", suggestedMinRPM), color: .spGold)
            }
            Text("Minimum rate accounts for your expenses plus a 30% margin.")
                .font(.caption2).foregroundStyle(Color.spTextSecondary)
        }
        .padding().background(Color.spCardBg).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Fuel Analysis
    private var fuelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "fuelpump.fill").foregroundStyle(Color(red: 0.2, green: 0.6, blue: 0.9))
                Text("Fuel Analysis").font(.headline).foregroundStyle(Color.spGold)
            }
            HStack(spacing: 12) {
                metricCard("Total Fuel", fuelCost.asCurrency, color: .spDanger)
                metricCard("Fuel/Mile", String(format: "$%.2f", fuelCostPerMile), color: fuelCostPerMile < 0.70 ? .spSuccess : .spWarning)
            }

            let fuelExpenses = expenses.filter { $0.category.lowercased() == "fuel" }
            let avgPPG = fuelExpenses.compactMap { $0.pricePerGallon }.reduce(0, +) / max(Double(fuelExpenses.compactMap { $0.pricePerGallon }.count), 1)
            if avgPPG > 0 {
                Text("Average price per gallon: $\(String(format: "%.3f", avgPPG))")
                    .font(.caption).foregroundStyle(Color.spTextSecondary)
            }
        }
        .padding().background(Color.spCardBg).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Projections
    private var projectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(Color.spGreenAccent)
                Text("Profit Projections").font(.headline).foregroundStyle(Color.spGold)
            }
            HStack(spacing: 12) {
                metricCard("This Week", weeklyProfit.asCurrency, color: weeklyProfit >= 0 ? .spSuccess : .spDanger)
                metricCard("Monthly (est.)", projectedMonthlyProfit.asCurrency, color: projectedMonthlyProfit >= 0 ? .spSuccess : .spDanger)
            }
            Text("Monthly projection based on current week's performance.")
                .font(.caption2).foregroundStyle(Color.spTextSecondary)
        }
        .padding().background(Color.spCardBg).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func metricCard(_ title: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.bold)).foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.spCardBgLight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Data
    private func loadData() async {
        do {
            loads = try await supabase.fetchLoads()
            expenses = try await supabase.fetchAllExpenses()
        } catch { print("Error: \(error)") }
        isLoading = false
    }

    private func generateAISummary() async {
        isGeneratingAI = true
        let netProfit = totalRevenue - totalExpenses
        let prompt = """
        You are a trucking financial advisor. Give a brief 3-4 sentence weekly summary for this carrier:
        - \(loads.count) loads, \(String(format: "%.0f", totalMiles)) total miles
        - Revenue: $\(String(format: "%.2f", totalRevenue))
        - Expenses: $\(String(format: "%.2f", totalExpenses)) (Fuel: $\(String(format: "%.2f", fuelCost)))
        - Net Profit: $\(String(format: "%.2f", netProfit))
        - Avg rate/mile: $\(String(format: "%.2f", avgRPM))
        - \(underpricedLoads.count) loads under $2/mile
        Be direct, actionable, and encouraging. Use plain language.
        """

        do {
            let summary = try await ClaudeAIService.generateText(prompt: prompt)
            await MainActor.run { aiSummary = summary }
        } catch {
            await MainActor.run { aiSummary = "Unable to generate summary. Check your API key." }
        }
        isGeneratingAI = false
    }
}
