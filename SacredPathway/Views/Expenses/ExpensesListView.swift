import SwiftUI

struct ExpensesListView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var expenses: [Expense] = []
    @State private var isLoading = true
    @State private var showingAddExpense = false
    @State private var editingExpense: Expense?
    @State private var filterCategory: String? = nil

    private let categories = ["fuel", "lumper", "toll", "repair", "insurance", "maintenance", "other"]

    var filteredExpenses: [Expense] {
        if let cat = filterCategory {
            return expenses.filter { $0.category.lowercased() == cat }
        }
        return expenses
    }

    var totalExpenses: Double {
        filteredExpenses.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            NavigationStack {
                VStack(spacing: 0) {
                    // Summary header
                    VStack(spacing: 8) {
                        Text("Total Expenses")
                            .font(.subheadline)
                            .foregroundStyle(Color.spTextSecondary)
                        Text(totalExpenses.asCurrency)
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.spDanger)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.spCardBg)

                    // Category filter chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterChip("All", category: nil)
                            ForEach(categories, id: \.self) { cat in
                                filterChip(cat.capitalized, category: cat)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                    }

                    if isLoading {
                        Spacer()
                        ProgressView()
                            .tint(Color.spGold)
                        Spacer()
                    } else if filteredExpenses.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "receipt")
                                .font(.system(size: 48))
                                .foregroundStyle(Color.spTextSecondary)
                            Text("No expenses yet — tap + to add your first one.")
                                .font(.headline)
                                .foregroundStyle(Color.spTextSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        Spacer()
                    } else {
                        List {
                            ForEach(filteredExpenses) { expense in
                                expenseRow(expense)
                                    .listRowBackground(Color.spCardBg)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        editingExpense = expense
                                    }
                            }
                            .onDelete(perform: deleteExpenses)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
                .navigationTitle("Expenses")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingAddExpense = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.spGold)
                                .font(.title3)
                        }
                    }
                }
                .sheet(isPresented: $showingAddExpense) {
                    AddEditExpenseView(mode: .add) { newExpense in
                        expenses.insert(newExpense, at: 0)
                    }
                    .environmentObject(supabase)
                }
                .sheet(item: $editingExpense) { expense in
                    AddEditExpenseView(mode: .edit(expense)) { updated in
                        if let index = expenses.firstIndex(where: { $0.id == updated.id }) {
                            expenses[index] = updated
                        }
                    }
                    .environmentObject(supabase)
                }
                .task { await loadExpenses() }
            }
        }
    }

    // MARK: - Subviews

    private func expenseRow(_ expense: Expense) -> some View {
        HStack(spacing: 12) {
            // Category icon
            ZStack {
                Circle()
                    .fill(categoryColor(expense.category).opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: categoryIcon(expense.category))
                    .foregroundStyle(categoryColor(expense.category))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(expense.category.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                if let vendor = expense.vendorName, !vendor.isEmpty {
                    Text(vendor)
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                if let date = expense.receiptDate {
                    Text(date, style: .date)
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary)
                }
            }

            Spacer()

            Text(expense.amount.asCurrency)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.spDanger)
        }
        .padding(.vertical, 4)
    }

    private func filterChip(_ title: String, category: String?) -> some View {
        Button {
            withAnimation { filterCategory = category }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(filterCategory == category ? Color.spGold : Color.spCardBg)
                .foregroundStyle(filterCategory == category ? Color.spBlack : Color.spTextPrimary)
                .clipShape(Capsule())
        }
    }

    // MARK: - Actions

    private func loadExpenses() async {
        do {
            expenses = try await supabase.fetchAllExpenses()
        } catch {
            print("Error loading expenses: \(error)")
        }
        isLoading = false
    }

    private func deleteExpenses(at offsets: IndexSet) {
        let toDelete = offsets.map { filteredExpenses[$0] }
        for expense in toDelete {
            guard let id = expense.id else { continue }
            Task {
                try? await supabase.deleteExpense(id)
            }
            expenses.removeAll { $0.id == id }
        }
    }

    // MARK: - Helpers

    private func categoryIcon(_ category: String) -> String {
        switch category.lowercased() {
        case "fuel": return "fuelpump.fill"
        case "lumper": return "person.2.fill"
        case "toll": return "road.lanes"
        case "repair": return "wrench.and.screwdriver.fill"
        case "insurance": return "shield.checkered"
        case "maintenance": return "gearshape.2.fill"
        default: return "dollarsign.circle.fill"
        }
    }

    private func categoryColor(_ category: String) -> Color {
        switch category.lowercased() {
        case "fuel": return Color(red: 0.2, green: 0.6, blue: 0.9)
        case "lumper": return Color(red: 0.8, green: 0.5, blue: 0.2)
        case "toll": return Color(red: 0.6, green: 0.4, blue: 0.8)
        case "repair": return Color.spDanger
        case "insurance": return Color.spSuccess
        case "maintenance": return Color.spWarning
        default: return Color.spTextSecondary
        }
    }
}
