import SwiftUI

// =============================================================================
//  Driver advances and recurring deductions
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B).
//   • Advances: amount, outstanding balance (rebuilt from the repayment
//     ledger), recovery history. Recovered through settlements only — never
//     more than the outstanding balance.
//   • Recurring deductions: weekly truck payment, insurance, reserve… Applied
//     automatically to new drafts, still editable before approval.
// =============================================================================

struct DriverAdvancesView: View {
    let driverId: UUID?

    @ObservedObject private var repo = SettlementRepository.shared
    @State private var editing: DriverAdvance?
    @State private var creating = false
    @State private var showClosed = false
    @State private var alert: SettlementAlert?

    private var advances: [DriverAdvance] {
        let all = repo.ledger.advances
            .filter { driverId == nil || $0.driverId == driverId }
            .map { DriverAdvanceService.reconciled(advance: $0, repayments: repo.ledger.advanceRepayments) }
            .sorted { $0.date > $1.date }
        return showClosed ? all : all.filter { !$0.isFullyRecovered }
    }

    var body: some View {
        List {
            Section {
                let total = driverId.map { repo.ledger.outstandingAdvanceBalance(forDriver: $0) }
                    ?? Money.sum(repo.ledger.advances.map {
                        DriverAdvanceService.outstanding(advance: $0, repayments: repo.ledger.advanceRepayments)
                    })
                LabeledContent("Outstanding", value: total.formatted)
                Toggle("Show recovered advances", isOn: $showClosed)
            }
            .listRowBackground(Color.spCardBg)

            if advances.isEmpty {
                SettlementEmptyState(title: "No open advances",
                                     message: "Record cash, fuel or emergency advances here. They're recovered on future settlements.",
                                     systemImage: "banknote")
                    .listRowBackground(Color.clear)
            }

            ForEach(advances) { advance in
                Section {
                    AdvanceSummaryRow(advance: advance,
                                      driverName: repo.driverName(advance.driverId),
                                      showsDriver: driverId == nil)
                    ForEach(history(for: advance)) { r in
                        HStack {
                            Text(SettlementFormat.date(r.date))
                                .font(.caption)
                            Text(r.settlementId.flatMap { repo.ledger.settlement(id: $0)?.displayNumber } ?? "Manual")
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            SettlementMoneyText(amount: r.amount, style: .debit,
                                                font: .system(.caption, design: .monospaced))
                        }
                        .foregroundStyle(Color.spTextSecondary)
                    }
                    if repo.viewer.can(.manageAdvances) {
                        Button("Edit") { editing = advance }
                            .font(.subheadline)
                    }
                }
                .listRowBackground(Color.spCardBg)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.spBackground)
        .navigationTitle("Advances")
        .toolbar {
            if repo.viewer.can(.manageAdvances) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus.circle.fill") }
                        .accessibilityLabel("Record Advance")
                }
            }
        }
        .sheet(isPresented: $creating) {
            AdvanceEditor(existing: nil, fixedDriverId: driverId)
        }
        .sheet(item: $editing) { advance in
            AdvanceEditor(existing: advance, fixedDriverId: advance.driverId)
        }
        .alert(item: $alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }

    private func history(for advance: DriverAdvance) -> [DriverAdvanceRepayment] {
        repo.ledger.advanceRepayments
            .filter { $0.advanceId == advance.id }
            .sorted { $0.date < $1.date }
    }
}

private struct AdvanceSummaryRow: View {
    let advance: DriverAdvance
    let driverName: String
    let showsDriver: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(advance.descriptionText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                    Text([showsDriver ? driverName : nil, advance.type.displayName,
                          SettlementFormat.date(advance.date)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                Spacer()
                Text(advance.isFullyRecovered ? "RECOVERED" : "OPEN")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(advance.isFullyRecovered ? Color.spSuccess : Color.spWarning)
            }
            ProgressView(value: progress)
                .tint(Color.spGold)
            HStack {
                Text("Advanced \(advance.amount.formatted)")
                Spacer()
                Text("Recovered \(advance.recoveredAmount.formatted)")
                Spacer()
                Text("Left \(advance.outstandingBalance.formatted)")
                    .fontWeight(.bold)
            }
            .font(.caption2)
            .foregroundStyle(Color.spTextSecondary)
        }
    }

    private var progress: Double {
        guard advance.amount.isPositive else { return 0 }
        return min(1, max(0, advance.recoveredAmount.rawDoubleValue / advance.amount.rawDoubleValue))
    }
}

struct AdvanceEditor: View {
    let existing: DriverAdvance?
    let fixedDriverId: UUID?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var repo = SettlementRepository.shared
    @State private var driverId: UUID?
    @State private var type: AdvanceType = .cash
    @State private var date = Date()
    @State private var amount: Money = .zero
    @State private var descriptionText = ""
    @State private var notes = ""
    @State private var isSaving = false
    @State private var alert: SettlementAlert?
    @State private var confirmDelete = false

    private var isUsed: Bool {
        guard let existing else { return false }
        return repo.ledger.advanceRepayments.contains { $0.advanceId == existing.id }
            || repo.ledger.deductions.contains { $0.advanceId == existing.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if fixedDriverId == nil {
                        Picker("Driver", selection: $driverId) {
                            Text("Select").tag(UUID?.none)
                            ForEach(repo.activeDrivers, id: \.id) { Text($0.name).tag($0.id) }
                        }
                    } else {
                        LabeledContent("Driver", value: repo.driverName(fixedDriverId))
                    }
                    Picker("Type", selection: $type) {
                        ForEach(AdvanceType.allCases) { Text($0.displayName).tag($0) }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    SettlementMoneyField(title: "Amount", amount: $amount)
                    TextField("Description", text: $descriptionText)
                    TextField("Notes", text: $notes, axis: .vertical)
                } footer: {
                    if let existing, existing.recoveredAmount.isPositive {
                        Text("\(existing.recoveredAmount.formatted) already recovered. The amount can't go below that.")
                    } else {
                        Text("Recovered on future settlements — in full or a set amount each time, never more than what's owed.")
                    }
                }
                if existing != nil && repo.viewer.can(.manageAdvances) {
                    Section {
                        Button("Delete Advance", role: .destructive) { confirmDelete = true }
                            .disabled(isUsed)
                    } footer: {
                        if isUsed { Text("This advance is on a settlement, so it's kept for history.") }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Record Advance" : "Edit Advance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .bold()
                        .disabled((fixedDriverId ?? driverId) == nil || !amount.isPositive || isSaving)
                }
            }
            .alert(item: $alert) { a in
                Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
            }
            .confirmationDialog("Delete this advance?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        driverId = fixedDriverId
        guard let e = existing else {
            descriptionText = type.displayName
            return
        }
        type = e.type
        date = e.date
        amount = e.amount
        descriptionText = e.descriptionText
        notes = e.notes ?? ""
    }

    private func save() async {
        guard let driver = fixedDriverId ?? driverId, let profileId = repo.profileId else { return }
        isSaving = true
        defer { isSaving = false }
        var advance = existing ?? DriverAdvance(profileId: profileId, driverId: driver, type: type,
                                                date: date, amount: amount, descriptionText: descriptionText)
        advance.type = type
        advance.date = date
        advance.amount = amount.rounded
        advance.descriptionText = descriptionText.trimmingCharacters(in: .whitespaces).isEmpty
            ? type.displayName : descriptionText
        advance.notes = notes.isEmpty ? nil : notes
        do {
            try await repo.saveAdvance(advance)
            dismiss()
        } catch {
            alert = SettlementAlert(error: error)
        }
    }

    private func delete() async {
        guard let existing else { return }
        do {
            try await repo.deleteAdvance(existing)
            dismiss()
        } catch {
            alert = SettlementAlert(error: error)
        }
    }
}

// MARK: - Recurring deductions

struct RecurringDeductionsView: View {
    let driverId: UUID?

    @ObservedObject private var repo = SettlementRepository.shared
    @State private var editing: RecurringDeduction?
    @State private var creating = false
    @State private var alert: SettlementAlert?

    private var rules: [RecurringDeduction] {
        repo.ledger.recurringDeductions
            .filter { driverId == nil || $0.driverId == driverId }
            .sorted {
                (repo.driverName($0.driverId), $0.descriptionText) < (repo.driverName($1.driverId), $1.descriptionText)
            }
    }

    var body: some View {
        List {
            if rules.isEmpty {
                SettlementEmptyState(title: "No recurring deductions",
                                     message: "Weekly truck payments, insurance, escrow and reserves added here are applied to every new settlement automatically.",
                                     systemImage: "arrow.triangle.2.circlepath")
                    .listRowBackground(Color.clear)
            }
            ForEach(rules) { rule in
                Button {
                    if repo.viewer.can(.manageRecurring) { editing = rule }
                } label: {
                    RecurringRuleRow(rule: rule, driverName: repo.driverName(rule.driverId),
                                     showsDriver: driverId == nil)
                }
                .listRowBackground(Color.spCardBg)
                .swipeActions {
                    if repo.viewer.can(.manageRecurring) {
                        Button(rule.isActive ? "Pause" : "Resume") {
                            Task { await toggle(rule) }
                        }
                        .tint(rule.isActive ? Color.spWarning : Color.spSuccess)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.spBackground)
        .navigationTitle("Recurring Deductions")
        .toolbar {
            if repo.viewer.can(.manageRecurring) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus.circle.fill") }
                        .accessibilityLabel("Add Recurring Deduction")
                }
            }
        }
        .sheet(isPresented: $creating) {
            RecurringDeductionEditor(existing: nil, fixedDriverId: driverId)
        }
        .sheet(item: $editing) { rule in
            RecurringDeductionEditor(existing: rule, fixedDriverId: rule.driverId)
        }
        .alert(item: $alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }

    private func toggle(_ rule: RecurringDeduction) async {
        var r = rule
        r.isActive.toggle()
        do { try await repo.saveRecurring(r) } catch { alert = SettlementAlert(error: error) }
    }
}

private struct RecurringRuleRow: View {
    let rule: RecurringDeduction
    let driverName: String
    let showsDriver: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.descriptionText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
            Spacer()
            if let pct = rule.percentOfGross {
                Text("\(pct.asPercentString) of gross")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Color.spDanger)
            } else {
                SettlementMoneyText(amount: rule.amount, style: .debit)
            }
        }
        .opacity(rule.isActive ? 1 : 0.5)
    }

    private var subtitle: String {
        var bits: [String] = []
        if showsDriver { bits.append(driverName) }
        bits.append(rule.category.displayName)
        bits.append(rule.frequency.displayName)
        if rule.responsibility != .driver { bits.append(rule.responsibility.displayName) }
        if !rule.isActive { bits.append("Paused") }
        if let end = rule.effectiveEndDate { bits.append("ends \(SettlementFormat.date(end))") }
        return bits.joined(separator: " · ")
    }
}

struct RecurringDeductionEditor: View {
    let existing: RecurringDeduction?
    let fixedDriverId: UUID?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var repo = SettlementRepository.shared
    @State private var driverId: UUID?
    @State private var category: SettlementDeductionCategory = .truckLease
    @State private var descriptionText = ""
    @State private var usePercent = false
    @State private var amount: Money = .zero
    @State private var percent: Decimal = 0
    @State private var frequency: RecurrenceFrequency = .everySettlement
    @State private var start = Date()
    @State private var hasEnd = false
    @State private var end = Date()
    @State private var isActive = true
    @State private var responsibility: DeductionResponsibility = .driver
    @State private var driverShare: Decimal = 50
    @State private var notes = ""
    @State private var alert: SettlementAlert?
    @State private var isSaving = false
    /// Fixed id for a NEW rule, so a repeated Save upserts the same row
    /// instead of creating a duplicate deduction.
    @State private var newRuleId = UUID()

    /// Advances have their own balance-capped tracking.
    private let categories = SettlementDeductionCategory.allCases.filter { !$0.isAdvanceRecovery }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if fixedDriverId == nil {
                        Picker("Driver", selection: $driverId) {
                            Text("Select").tag(UUID?.none)
                            ForEach(repo.activeDrivers, id: \.id) { Text($0.name).tag($0.id) }
                        }
                    } else {
                        LabeledContent("Driver", value: repo.driverName(fixedDriverId))
                    }
                    Picker("Category", selection: $category) {
                        ForEach(categories) { Text($0.displayName).tag($0) }
                    }
                    TextField("Description", text: $descriptionText)
                    Toggle("Percentage of gross", isOn: $usePercent)
                    if usePercent {
                        SettlementDecimalField(title: "Percent", value: $percent, suffix: "%")
                    } else {
                        SettlementMoneyField(title: "Amount", amount: $amount)
                    }
                    Picker("Frequency", selection: $frequency) {
                        ForEach(RecurrenceFrequency.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Schedule") {
                    DatePicker("Starts", selection: $start, displayedComponents: .date)
                    Toggle("Has an end date", isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("Ends", selection: $end, in: start..., displayedComponents: .date)
                    }
                    Toggle("Active", isOn: $isActive)
                }
                Section("Who Pays") {
                    Picker("Responsibility", selection: $responsibility) {
                        ForEach(DeductionResponsibility.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if responsibility == .split {
                        SettlementDecimalField(title: "Driver share", value: $driverShare, suffix: "%")
                    }
                }
                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                }
            }
            .navigationTitle(existing == nil ? "New Recurring Deduction" : "Edit Recurring Deduction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .bold()
                        .disabled((fixedDriverId ?? driverId) == nil || isSaving)
                }
            }
            .alert(item: $alert) { a in
                Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
            }
            .onAppear(perform: load)
            .onChange(of: category) { old, new in
                if descriptionText.isEmpty || descriptionText == old.displayName {
                    descriptionText = new.displayName
                }
                if existing == nil { applyDriverDefaults(for: new) }
            }
        }
    }

    /// New rules start with the driver's configured "who pays" for the category.
    private func applyDriverDefaults(for category: SettlementDeductionCategory) {
        guard let d = repo.driver(id: fixedDriverId ?? driverId) else { return }
        let rule = repo.paySettings(for: d).responsibility(for: category)
        responsibility = rule.0
        if rule.0 == .split { driverShare = rule.1 }
    }

    private func load() {
        driverId = fixedDriverId
        guard let e = existing else {
            descriptionText = category.displayName
            applyDriverDefaults(for: category)
            return
        }
        category = e.category
        descriptionText = e.descriptionText
        usePercent = e.percentOfGross != nil
        amount = e.amount
        percent = e.percentOfGross ?? 0
        frequency = e.frequency
        start = e.effectiveStartDate
        hasEnd = e.effectiveEndDate != nil
        end = e.effectiveEndDate ?? Date()
        isActive = e.isActive
        responsibility = e.responsibility
        driverShare = e.responsibility == .split ? e.driverSharePercent : 50
        notes = e.notes ?? ""
    }

    private func save() async {
        guard !isSaving, let driver = fixedDriverId ?? driverId, let profileId = repo.profileId else { return }
        isSaving = true
        defer { isSaving = false }
        let share: Decimal
        switch responsibility {
        case .driver:  share = 100
        case .company: share = 0
        case .split:   share = driverShare
        }
        let rule = RecurringDeduction(
            id: existing?.id ?? newRuleId,
            profileId: profileId,
            driverId: driver,
            category: category,
            descriptionText: descriptionText.trimmingCharacters(in: .whitespaces),
            amount: usePercent ? .zero : amount.rounded,
            percentOfGross: usePercent ? percent : nil,
            frequency: frequency,
            effectiveStartDate: start,
            effectiveEndDate: hasEnd ? end : nil,
            isActive: isActive,
            responsibility: responsibility,
            driverSharePercent: share,
            notes: notes.isEmpty ? nil : notes,
            createdAt: existing?.createdAt,
            updatedAt: Date())
        do {
            try await repo.saveRecurring(rule)
            dismiss()
        } catch {
            alert = SettlementAlert(error: error)
        }
    }
}
