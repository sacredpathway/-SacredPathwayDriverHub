import SwiftUI

// =============================================================================
// PaystubExpenseReviewView
// -----------------------------------------------------------------------------
// Shown after the user taps "Calculate" on the paystub flow. Lists every
// expense the matcher pulled in, lets the user uncheck or edit any line,
// add manual lines, and then re-runs the calculation when they hit "Apply".
//
// Production-safety:
//   • Manual lines exist ONLY for the duration of this sheet — they never
//     touch Supabase.
//   • Unchecking and editing also do not write to Supabase. The user's
//     real expense rows stay intact; this screen only shapes what feeds
//     into the calculation + PDF.
// =============================================================================

struct PaystubExpenseReviewView: View {
    @Environment(\.dismiss) private var dismiss

    /// Caller-provided initial set. The view edits a local copy and returns
    /// the curated result via `onApply`.
    let initialResult: PaystubExpenseMatcher.MatchResult

    /// Optional async hook the parent uses to re-fetch from Supabase and
    /// recompute the match. When invoked from the toolbar "Refresh" button
    /// the parent updates `initialResult`'s underlying state, which we
    /// then mirror locally. Defaults to a no-op for unit tests / previews.
    var onRefresh: (() async -> Void)? = nil

    /// Optional bundle that lets us compute a live net-pay preview
    /// (gross → expenses → driver pay → fees → NET) as the user toggles
    /// include/exclude. Pure, no I/O, no state mutation.
    struct LiveContext {
        var loads: [Load]
        var profile: Profile
        var driver: Driver
    }
    var liveContext: LiveContext? = nil

    /// Called when the user taps "Apply" — passes the curated result back
    /// to the parent so it can re-run SettlementEngine and refresh the
    /// preview / PDF.
    let onApply: (PaystubExpenseMatcher.MatchResult) -> Void

    // Local editable copy.
    @State private var lineItems: [PaystubExpenseMatcher.LineItem] = []

    // Manual-line entry sheet
    @State private var showManualEntry = false

    // Per-row inline-edit amount text
    @State private var editAmountText: [UUID: String] = [:]

    // Refresh state for the toolbar button
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        summaryCard
                        livePreviewCard
                        bulkActions
                        groupedList
                        addManualButton
                    }
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("Review Expenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.spBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.spGoldLight)
                }
                ToolbarItem(placement: .principal) {
                    if let onRefresh {
                        Button {
                            guard !isRefreshing else { return }
                            isRefreshing = true
                            Task {
                                await onRefresh()
                                // Mirror any new lines the parent surfaced.
                                lineItems = initialResult.lineItems
                                isRefreshing = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if isRefreshing {
                                    ProgressView().controlSize(.small)
                                        .tint(Color.spGold)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text("Refresh")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(Color.spGold)
                        }
                        .disabled(isRefreshing)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(makeResult())
                        dismiss()
                    }
                    .foregroundStyle(Color.spGold)
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                lineItems = initialResult.lineItems
            }
            .onChange(of: initialResult.lineItems.map(\.id)) { _, _ in
                // Parent pushed a refreshed match — adopt it.
                lineItems = initialResult.lineItems
            }
            .sheet(isPresented: $showManualEntry) {
                ManualLineEntryView { newLine in
                    lineItems.insert(newLine, at: 0)
                }
            }
        }
    }

    // MARK: - Summary
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .foregroundStyle(Color.spGold)
                Text("Pay period")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                Spacer()
                Text(periodLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
            }
            Divider().background(Color.spCardBgLight)
            HStack {
                Text("Included")
                    .foregroundStyle(Color.spTextSecondary)
                    .font(.subheadline)
                Spacer()
                Text("\(includedCount) of \(lineItems.count) items")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
            }
            HStack {
                Text("Total")
                    .foregroundStyle(Color.spTextSecondary)
                    .font(.subheadline)
                Spacer()
                Text(includedTotal.asCurrency)
                    .font(.headline)
                    .foregroundStyle(Color.spGold)
            }
            if initialResult.unattributedDropped > 0 {
                Text("\(initialResult.unattributedDropped) older expense(s) had no date and were skipped.")
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
            }
        }
        .padding(14)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    // MARK: - Live net-pay preview
    //
    // Recomputes the SettlementCalculation on every toggle so the user
    // sees the exact $ impact of including/excluding any line before
    // hitting Apply. Pure local compute — no Supabase round-trip.
    @ViewBuilder
    private var livePreviewCard: some View {
        if let ctx = liveContext {
            let includedExpenses: [Expense] = lineItems
                .filter { $0.included }
                .map { item in
                    var copy = item.expense
                    if let override = item.overrideAmount { copy.amount = override }
                    return copy
                }
            let calc = SettlementEngine.calculate(
                loads: ctx.loads,
                expenses: includedExpenses,
                profile: ctx.profile,
                driver: ctx.driver
            )
            VStack(spacing: 6) {
                HStack {
                    Image(systemName: "function")
                        .foregroundStyle(Color.spGold)
                    Text("LIVE SETTLEMENT PREVIEW")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Color.spGold)
                    Spacer()
                }
                .padding(.bottom, 4)
                previewRow("Gross Revenue",  calc.totalRevenue.asCurrency)
                previewRow("Expenses",       "-\(calc.totalExpenses.asCurrency)", color: .spDanger)
                previewRow("Gross Profit",   calc.grossProfit.asCurrency)
                Divider().background(Color.spTextSecondary.opacity(0.3))
                previewRow("Driver Pay",     calc.driverPayAmount.asCurrency)
                previewRow("Dispatch Fee",   "-\(calc.dispatcherFeeAmount.asCurrency)", color: .spDanger)
                previewRow("Factoring Fee",  "-\(calc.factoringFeeAmount.asCurrency)", color: .spDanger)
                previewRow("Authority Fee",  "-\(calc.authorityFee.asCurrency)",       color: .spDanger)
                previewRow("Maint. Reserve", "-\(calc.maintenanceReserve.asCurrency)", color: .spDanger)
                Divider().background(Color.spGold)
                previewRow(
                    "NET PAY",
                    calc.carrierNetPay.asCurrency,
                    bold: true,
                    color: calc.carrierNetPay >= 0 ? .spSuccess : .spDanger
                )
            }
            .padding(14)
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }

    private func previewRow(_ label: String, _ value: String, bold: Bool = false, color: Color = .spTextPrimary) -> some View {
        HStack {
            Text(label)
                .font(bold ? .subheadline.weight(.bold) : .caption)
                .foregroundStyle(Color.spTextSecondary)
            Spacer()
            Text(value)
                .font(bold ? .subheadline.weight(.bold) : .caption.weight(.medium))
                .foregroundStyle(color)
        }
    }

    // MARK: - Bulk include / exclude
    private var bulkActions: some View {
        HStack(spacing: 10) {
            bulkButton(label: "Include All", systemImage: "checkmark.square.fill") {
                for i in lineItems.indices { lineItems[i].included = true }
            }
            bulkButton(label: "Exclude All", systemImage: "square") {
                for i in lineItems.indices { lineItems[i].included = false }
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    private func bulkButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(label)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.spGold.opacity(0.15))
            .foregroundStyle(Color.spGoldLight)
            .clipShape(Capsule())
        }
    }

    // MARK: - Grouped list
    private var groupedList: some View {
        VStack(spacing: 14) {
            ForEach(currentResult.includedByCategory, id: \.0) { (category, _) in
                let items = lineItems.filter { $0.category == category }
                if !items.isEmpty {
                    categorySection(category: category, items: items)
                }
            }
            // Categories where nothing is currently included still need to
            // render so the user can re-enable them.
            ForEach(uncheckedCategories, id: \.self) { category in
                let items = lineItems.filter { $0.category == category }
                if !items.isEmpty {
                    categorySection(category: category, items: items)
                }
            }
        }
        .padding(.horizontal)
    }

    private func categorySection(category: PaystubExpenseMatcher.Category,
                                 items: [PaystubExpenseMatcher.LineItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(category.displayName.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.spGold)
                Spacer()
                let subtotal = items.filter { $0.included }.reduce(0) { $0 + $1.displayAmount }
                Text(subtotal.asCurrency)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
            }
            .padding(.bottom, 6)

            VStack(spacing: 6) {
                ForEach(items) { item in
                    row(for: item)
                }
            }
        }
        .padding(12)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func row(for item: PaystubExpenseMatcher.LineItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            // Checkbox
            Button {
                toggleInclude(item.id)
            } label: {
                Image(systemName: item.included ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.included ? Color.spGold : Color.spTextSecondary)
                    .font(.title3)
            }
            // Description + date
            VStack(alignment: .leading, spacing: 2) {
                Text(item.expense.description ?? item.expense.vendorName ?? item.category.displayName)
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextPrimary)
                    .lineLimit(1)
                if let d = item.date {
                    Text(d, format: Date.FormatStyle(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary)
                }
                if item.isManualLine {
                    Text("Added manually — not saved to your records")
                        .font(.caption2)
                        .foregroundStyle(Color.spWarning)
                }
            }
            Spacer(minLength: 8)
            // Editable amount
            TextField("0.00", text: amountBinding(for: item))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
                .frame(width: 90)
                .padding(.vertical, 6).padding(.horizontal, 8)
                .background(Color.spCardBgLight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(item.included ? 1.0 : 0.5)
                .disabled(!item.included)
        }
    }

    // MARK: - Manual add
    private var addManualButton: some View {
        Button {
            showManualEntry = true
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                Text("Add expense line")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(Color.spGold)
            .padding(14)
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }

    // MARK: - Derived state

    private var includedCount: Int { lineItems.filter { $0.included }.count }
    private var includedTotal: Double {
        lineItems.filter { $0.included }.reduce(0) { $0 + $1.displayAmount }
    }

    private var currentResult: PaystubExpenseMatcher.MatchResult {
        var r = initialResult
        r.lineItems = lineItems
        return r
    }

    private var uncheckedCategories: [PaystubExpenseMatcher.Category] {
        let activeCategories = Set(lineItems.filter { $0.included }.map(\.category))
        return PaystubExpenseMatcher.Category.allCases.filter { category in
            !activeCategories.contains(category)
                && lineItems.contains(where: { $0.category == category })
        }
    }

    private var periodLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "\(f.string(from: initialResult.periodStart)) – \(f.string(from: initialResult.periodEnd))"
    }

    // MARK: - Mutations

    private func toggleInclude(_ id: UUID) {
        guard let idx = lineItems.firstIndex(where: { $0.id == id }) else { return }
        lineItems[idx].included.toggle()
    }

    private func amountBinding(for item: PaystubExpenseMatcher.LineItem) -> Binding<String> {
        Binding(
            get: {
                if let txt = editAmountText[item.id] { return txt }
                return String(format: "%.2f", item.displayAmount)
            },
            set: { newValue in
                editAmountText[item.id] = newValue
                if let parsed = Double(newValue),
                   let idx = lineItems.firstIndex(where: { $0.id == item.id }) {
                    lineItems[idx].overrideAmount = parsed
                }
            }
        )
    }

    private func makeResult() -> PaystubExpenseMatcher.MatchResult {
        var r = initialResult
        r.lineItems = lineItems
        return r
    }
}

// =============================================================================
// MARK: - ManualLineEntryView
// =============================================================================
private struct ManualLineEntryView: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (PaystubExpenseMatcher.LineItem) -> Void

    @State private var category: PaystubExpenseMatcher.Category = .other
    @State private var amountText: String = ""
    @State private var description: String = ""

    private let categories = PaystubExpenseMatcher.Category.allCases

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                Form {
                    Section("Category") {
                        Picker("", selection: $category) {
                            ForEach(categories, id: \.self) { c in
                                Text(c.displayName).tag(c)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Section("Amount") {
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                    }
                    Section("Description") {
                        TextField("Optional — e.g. Out-of-pocket toll", text: $description)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add Manual Line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addLine()
                    }
                    .disabled(Double(amountText) == nil || (Double(amountText) ?? 0) <= 0)
                }
            }
        }
    }

    private func addLine() {
        guard let amount = Double(amountText), amount > 0 else { return }
        // Build a synthetic Expense — never persisted. profileId placeholder is
        // safe because this expense is only consumed by the in-memory PDF path.
        let synthetic = Expense(
            id: UUID(),
            loadId: nil,
            profileId: UUID(),
            category: category.rawValue,
            amount: amount,
            vendorName: nil,
            description: description.isEmpty ? nil : description,
            receiptDate: Date(),
            createdAt: Date()
        )
        let item = PaystubExpenseMatcher.LineItem(
            id: synthetic.id ?? UUID(),
            expense: synthetic,
            category: category,
            date: Date(),
            included: true,
            overrideAmount: nil,
            isManualLine: true
        )
        onAdd(item)
        dismiss()
    }
}
