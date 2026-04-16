import SwiftUI

struct LoadDetailView: View {
    @EnvironmentObject var supabase: SupabaseService
    let load: Load
    @State private var expenses: [Expense] = []

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
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task {
                if let loadId = load.id {
                    do { expenses = try await supabase.fetchExpenses(forLoad: loadId) }
                    catch { print("Error loading expenses: \(error)") }
                }
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
