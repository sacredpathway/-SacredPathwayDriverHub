import Foundation
import Combine

// =============================================================================
//  LocalExpensesRepository — Free Local Mode expenses store (Phase D)
// -----------------------------------------------------------------------------
//  Mirrors SupabaseService's expense surface (fetchAllExpenses,
//  fetchExpenses(forLoad:), createExpense, updateExpense, deleteExpense).
//  Disk file: `Documents/DriverHub/expenses.json`.
// =============================================================================

@MainActor
final class LocalExpensesRepository: ObservableObject {

    static let shared = LocalExpensesRepository()

    private let fileName = "expenses.json"

    @Published private(set) var expenses: [Expense] = []

    init() {
        reload()
    }

    // MARK: - Read

    func reload() {
        expenses = LocalStore.loadArray(Expense.self, fileName: fileName)
        #if DEBUG
        print("[SP_DEBUG_LOCAL] LocalExpensesRepository loaded \(expenses.count) expenses from disk")
        #endif
    }

    func fetchAll() async -> [Expense] {
        expenses
    }

    func fetch(forLoad loadId: UUID) async -> [Expense] {
        expenses
            .filter { $0.loadId == loadId }
            .sorted { ($0.receiptDate ?? .distantPast) > ($1.receiptDate ?? .distantPast) }
    }

    func find(id: UUID) -> Expense? {
        expenses.first { $0.id == id }
    }

    // MARK: - Write

    @discardableResult
    func create(_ expense: Expense) -> Expense {
        var copy = expense
        if copy.id == nil { copy.id = UUID() }
        if copy.createdAt == nil { copy.createdAt = Date() }
        expenses.append(copy)
        flush()
        return copy
    }

    func update(_ expense: Expense) {
        guard let id = expense.id, let idx = expenses.firstIndex(where: { $0.id == id }) else { return }
        expenses[idx] = expense
        flush()
    }

    func delete(id: UUID) {
        let before = expenses.count
        expenses.removeAll { $0.id == id }
        if expenses.count != before { flush() }
    }

    /// Delete all expenses linked to a given load — used when a load is
    /// removed so we don't leave orphan rows.
    func deleteAll(forLoad loadId: UUID) {
        let before = expenses.count
        expenses.removeAll { $0.loadId == loadId }
        if expenses.count != before { flush() }
    }

    func replaceAll(with newExpenses: [Expense]) {
        expenses = newExpenses
        flush()
    }

    // MARK: - Persistence

    private func flush() {
        LocalStore.saveArray(expenses, fileName: fileName)
    }
}
