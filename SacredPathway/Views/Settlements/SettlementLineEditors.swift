import SwiftUI

// =============================================================================
//  SettlementLineEditors — additions, deductions, load lines, expenses,
//  documents
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). Editors return values; the review screen owns
//  the draft and recalculates through the engine.
// =============================================================================

// MARK: - Addition

struct SettlementAdditionEditor: View {
    let existing: SettlementAddition?
    let profileId: UUID
    let settlementId: UUID
    let loads: [SettlementLoadLine]
    let onSave: (SettlementAddition) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Stable id for a new line: a repeated tap updates it instead of adding a copy.
    @State private var newLineId = UUID()
    @State private var category: SettlementAdditionCategory = .bonus
    @State private var descriptionText = ""
    @State private var amount: Money = .zero
    @State private var date = Date()
    @State private var relatedLoadId: UUID?
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Category", selection: $category) {
                        ForEach(SettlementAdditionCategory.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("Description", text: $descriptionText)
                    SettlementMoneyField(title: "Amount", amount: $amount)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }
                if !loads.isEmpty {
                    Section("Related Load") {
                        Picker("Load", selection: $relatedLoadId) {
                            Text("None").tag(UUID?.none)
                            ForEach(loads) { line in
                                Text(line.loadNumber ?? "Load").tag(line.loadId)
                            }
                        }
                    }
                }
                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                }
                if amount.isNegative {
                    Text("A negative addition reduces the driver's pay. Use a deduction instead if that's what you mean.")
                        .font(.caption)
                        .foregroundStyle(Color.spWarning)
                }
            }
            .navigationTitle(existing == nil ? "Add Addition" : "Edit Addition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .bold()
                        .disabled(amount.isZero)
                }
            }
            .onAppear(perform: load)
            .onChange(of: category) { old, new in
                if descriptionText.isEmpty || descriptionText == old.displayName {
                    descriptionText = new.displayName
                }
            }
        }
    }

    private func load() {
        guard let e = existing else {
            descriptionText = category.displayName
            return
        }
        category = e.category
        descriptionText = e.descriptionText
        amount = e.amount
        date = e.date ?? Date()
        relatedLoadId = e.relatedLoadId
        notes = e.notes ?? ""
    }

    private func save() {
        let clean = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let addition = SettlementAddition(
            id: existing?.id ?? newLineId,
            settlementId: settlementId,
            profileId: profileId,
            category: category,
            descriptionText: clean.isEmpty ? category.displayName : clean,
            amount: amount.rounded,
            date: date,
            relatedLoadId: relatedLoadId,
            documentId: existing?.documentId,
            notes: notes.isEmpty ? nil : notes,
            sortOrder: existing?.sortOrder ?? 0,
            createdAt: existing?.createdAt ?? Date())
        onSave(addition)
        dismiss()
    }
}

// MARK: - Deduction

struct SettlementDeductionEditor: View {
    let existing: SettlementDeduction?
    let profileId: UUID
    let settlementId: UUID
    let loads: [SettlementLoadLine]
    let paySettings: DriverPaySettings
    let advances: [DriverAdvance]
    let repayments: [DriverAdvanceRepayment]
    let onSave: (SettlementDeduction) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Stable id for a new line: a repeated tap updates it instead of adding a copy.
    @State private var newLineId = UUID()
    @State private var category: SettlementDeductionCategory = .fuel
    @State private var descriptionText = ""
    @State private var amount: Money = .zero
    @State private var date = Date()
    @State private var relatedLoadId: UUID?
    @State private var responsibility: DeductionResponsibility = .driver
    @State private var driverShare: Decimal = 50
    @State private var advanceId: UUID?
    @State private var notes = ""

    private var openAdvances: [DriverAdvance] {
        advances.filter {
            !DriverAdvanceService.outstanding(advance: $0, repayments: relevantRepayments).isZero
                || $0.id == existing?.advanceId
        }
    }

    /// The ledger minus this settlement's own recoveries, so editing an
    /// existing recovery is checked against the balance before it.
    private var relevantRepayments: [DriverAdvanceRepayment] {
        repayments.filter { $0.settlementId != settlementId }
    }

    private var advanceProblem: String? {
        guard let advanceId, let advance = advances.first(where: { $0.id == advanceId }) else { return nil }
        return DriverAdvanceService.validateManualRecovery(
            amount: amount, advance: advance, repayments: relevantRepayments,
            excludingSettlementId: settlementId)
    }

    private var preview: SettlementDeduction { build() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Category", selection: $category) {
                        ForEach(SettlementDeductionCategory.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("Description", text: $descriptionText)
                    SettlementMoneyField(title: "Amount", amount: $amount)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                if category.isAdvanceRecovery {
                    Section {
                        Picker("Advance", selection: $advanceId) {
                            Text("Not linked").tag(UUID?.none)
                            ForEach(openAdvances) { a in
                                Text("\(a.descriptionText) · \(DriverAdvanceService.outstanding(advance: a, repayments: relevantRepayments).formatted) left")
                                    .tag(UUID?.some(a.id))
                            }
                        }
                        if let advanceProblem {
                            Text(advanceProblem)
                                .font(.caption)
                                .foregroundStyle(Color.spDanger)
                        }
                    } header: {
                        Text("Advance Recovery")
                    } footer: {
                        Text("Link the advance so its balance goes down when this settlement is approved. A recovery can never exceed what is still owed.")
                    }
                }

                Section {
                    Picker("Who pays", selection: $responsibility) {
                        ForEach(DeductionResponsibility.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if responsibility == .split {
                        SettlementDecimalField(title: "Driver share", value: $driverShare, suffix: "%")
                    }
                    LabeledContent("Off driver's check", value: preview.driverAmount.formatted)
                    LabeledContent("Company pays", value: preview.companyAmount.formatted)
                } header: {
                    Text("Responsibility")
                } footer: {
                    Text("Default for \(paySettings.settlementType.displayName.lowercased())s: \(paySettings.responsibility(for: category).0.displayName.lowercased()).")
                }

                if !loads.isEmpty {
                    Section("Related Load") {
                        Picker("Load", selection: $relatedLoadId) {
                            Text("None").tag(UUID?.none)
                            ForEach(loads) { line in
                                Text(line.loadNumber ?? "Load").tag(line.loadId)
                            }
                        }
                    }
                }
                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                }
            }
            .navigationTitle(existing == nil ? "Add Deduction" : "Edit Deduction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(build())
                        dismiss()
                    }
                    .bold()
                    .disabled(amount.isZero || advanceProblem != nil
                              || (responsibility == .split && (driverShare <= 0 || driverShare >= 100)))
                }
            }
            .onAppear(perform: load)
            .onChange(of: category) { old, new in
                if existing == nil {
                    let rule = paySettings.responsibility(for: new)
                    responsibility = rule.0
                    if rule.0 == .split { driverShare = rule.1 }
                }
                if descriptionText.isEmpty || descriptionText == old.displayName {
                    descriptionText = new.displayName
                }
                if !new.isAdvanceRecovery { advanceId = nil }
            }
        }
    }

    private func load() {
        guard let e = existing else {
            let rule = paySettings.responsibility(for: category)
            responsibility = rule.0
            if rule.0 == .split { driverShare = rule.1 }
            descriptionText = category.displayName
            return
        }
        category = e.category
        descriptionText = e.descriptionText
        amount = e.amount
        date = e.date ?? Date()
        relatedLoadId = e.relatedLoadId
        responsibility = e.responsibility
        driverShare = e.responsibility == .split ? e.driverSharePercent : 50
        advanceId = e.advanceId
        notes = e.notes ?? ""
    }

    private func build() -> SettlementDeduction {
        let clean = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let share: Decimal
        switch responsibility {
        case .driver:  share = 100
        case .company: share = 0
        case .split:   share = driverShare
        }
        return SettlementDeduction(
            id: existing?.id ?? newLineId,
            settlementId: settlementId,
            profileId: profileId,
            category: category,
            descriptionText: clean.isEmpty ? category.displayName : clean,
            amount: amount.rounded,
            date: date,
            relatedLoadId: relatedLoadId,
            relatedExpenseId: existing?.relatedExpenseId,
            documentId: existing?.documentId,
            notes: notes.isEmpty ? nil : notes,
            responsibility: responsibility,
            driverSharePercent: share,
            recurringDeductionId: existing?.recurringDeductionId,
            advanceId: category.isAdvanceRecovery ? advanceId : nil,
            sortOrder: existing?.sortOrder ?? 0,
            createdAt: existing?.createdAt ?? Date())
    }
}

// MARK: - Expenses → deductions

struct SettlementExpensePicker: View {
    let alreadyOnSettlement: Set<UUID>
    let linkedElsewhere: [UUID: UUID]
    let period: SettlementDateRange?
    let onAdd: ([Expense]) -> Void

    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var repo = SettlementRepository.shared
    @State private var expenses: [Expense] = []
    @State private var selected: Set<UUID> = []
    @State private var onlyInPeriod = true
    @State private var isLoading = true

    private var visible: [Expense] {
        expenses.filter { e in
            guard let id = e.id, !alreadyOnSettlement.contains(id) else { return false }
            if onlyInPeriod, let period {
                return period.contains(e.receiptDate ?? e.createdAt)
            }
            return true
        }
        .sorted { ($0.receiptDate ?? .distantPast) > ($1.receiptDate ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                if period != nil {
                    Toggle("Only this settlement's period", isOn: $onlyInPeriod)
                }
                if isLoading {
                    ProgressView()
                } else if visible.isEmpty {
                    Text("No expenses to add.")
                        .foregroundStyle(Color.spTextSecondary)
                }
                ForEach(visible, id: \.id) { expense in
                    let id = expense.id ?? UUID()
                    let otherSettlement = linkedElsewhere[id]
                    Button {
                        guard otherSettlement == nil else { return }
                        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
                    } label: {
                        HStack {
                            Image(systemName: otherSettlement != nil ? "nosign"
                                  : (selected.contains(id) ? "checkmark.circle.fill" : "circle"))
                                .foregroundStyle(Color.spGold)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(expense.description ?? expense.vendorName ?? expense.category.capitalized)
                                    .foregroundStyle(Color.spTextPrimary)
                                Text(caption(expense, otherSettlement: otherSettlement))
                                    .font(.caption)
                                    .foregroundStyle(otherSettlement != nil ? Color.spDanger : Color.spTextSecondary)
                            }
                            Spacer()
                            SettlementMoneyText(amount: Money(double: expense.amount))
                        }
                    }
                    .disabled(otherSettlement != nil)
                }
            }
            .navigationTitle("Add From Expenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selected.count)") {
                        onAdd(expenses.filter { $0.id.map(selected.contains) ?? false })
                        dismiss()
                    }
                    .bold()
                    .disabled(selected.isEmpty)
                }
            }
            .task {
                repo.attach(supabase)
                expenses = await repo.expenses()
                isLoading = false
            }
        }
    }

    private func caption(_ e: Expense, otherSettlement: UUID?) -> String {
        if let otherSettlement {
            return "Already on \(repo.ledger.settlement(id: otherSettlement)?.displayNumber ?? "another settlement")"
        }
        var bits = [e.category.capitalized]
        bits.append(SettlementFormat.date(e.receiptDate ?? e.createdAt))
        let mapped = SettlementLoadAdapter.deductionCategory(forExpenseCategory: e.category)
        bits.append("→ \(mapped.displayName)")
        return bits.joined(separator: " · ")
    }
}

// MARK: - Add loads / corrections

struct SettlementAddLoadsView: View {
    let settlementId: UUID
    let bundle: SettlementBundle?
    let onAdd: ([SettlementLoadLine]) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var repo = SettlementRepository.shared
    @ObservedObject private var loadsSync = LoadsSyncService.shared
    @State private var selected: Set<UUID> = []
    @State private var includeUnassigned = false
    @State private var includeOtherWeeks = false
    @State private var correctionLoad: EligibleSettlementLoad?
    @State private var correctionAmount: Money = .zero
    @State private var correctionNote = ""

    private var candidates: [EligibleSettlementLoad] {
        guard let bundle, let driverId = bundle.settlement.driverId else { return [] }
        let onSettlement = Set(bundle.loadLines.filter { !$0.isAdjustment }.compactMap(\.loadId))
        let start = includeOtherWeeks
            ? Calendar.current.date(byAdding: .day, value: -120, to: Date()) ?? Date()
            : bundle.settlement.settlementPeriodStart ?? Date()
        let end = includeOtherWeeks ? Date() : bundle.settlement.settlementPeriodEnd ?? Date()
        return SettlementWorkflowService.eligibleLoads(
            from: loadsSync.loads, driverId: driverId,
            periodStart: start, periodEnd: end,
            ledger: repo.ledger, includeUnassigned: includeUnassigned,
            excludingSettlementId: settlementId)
        .filter { !onSettlement.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Include unassigned loads", isOn: $includeUnassigned)
                    Toggle("Show loads from other weeks", isOn: $includeOtherWeeks)
                }
                Section {
                    if candidates.isEmpty {
                        Text("No other completed loads found.")
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    ForEach(candidates) { item in
                        row(item)
                    }
                } footer: {
                    Text("A load that was already paid can only be added as a correction that names the settlement it corrects.")
                }
            }
            .navigationTitle("Add Loads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selected.count)") {
                        let profileId = bundle?.settlement.profileId ?? UUID()
                        let lines = candidates
                            .filter { selected.contains($0.id) && $0.isSelectable }
                            .map { SettlementLoadAdapter.line(from: $0.load, settlementId: settlementId,
                                                              profileId: profileId, sortOrder: 0) }
                        onAdd(lines)
                        dismiss()
                    }
                    .bold()
                    .disabled(selected.isEmpty)
                }
            }
            .sheet(item: $correctionLoad) { item in
                correctionSheet(item)
            }
        }
    }

    private func row(_ item: EligibleSettlementLoad) -> some View {
        Button {
            if item.isSelectable {
                if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
            } else {
                correctionAmount = .zero
                correctionNote = ""
                correctionLoad = item
            }
        } label: {
            HStack {
                Image(systemName: item.isSelectable
                      ? (selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                      : "arrow.uturn.backward.circle")
                    .foregroundStyle(Color.spGold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.load.loadNumber ?? "No load #")
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                    Text(item.isSelectable
                         ? "PU \(SettlementFormat.date(item.load.pickupDate))"
                         : "Paid on \(item.alreadyPaidOn.flatMap { repo.ledger.settlement(id: $0)?.displayNumber } ?? "another settlement") — tap to add a correction")
                        .font(.caption)
                        .foregroundStyle(item.isSelectable ? Color.spTextSecondary : Color.spWarning)
                }
                Spacer()
                SettlementMoneyText(amount: Money(double: item.load.totalRevenue ?? 0))
            }
        }
    }

    private func correctionSheet(_ item: EligibleSettlementLoad) -> some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Load", value: item.load.loadNumber ?? "—")
                    LabeledContent("Originally paid on",
                                   value: item.alreadyPaidOn.flatMap { repo.ledger.settlement(id: $0)?.displayNumber } ?? "—")
                    SettlementMoneyField(title: "Correction gross", amount: $correctionAmount, allowsNegative: true)
                    TextField("Reason (required)", text: $correctionNote, axis: .vertical)
                } footer: {
                    Text("Enter only the ADDITIONAL gross being paid (e.g. late detention). Use a negative amount for a chargeback. The driver's pay rule is applied to it.")
                }
            }
            .navigationTitle("Load Correction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { correctionLoad = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let bundle, let original = item.alreadyPaidOn {
                            let line = SettlementWorkflowService.adjustmentLine(
                                for: item.load, correcting: original, in: bundle,
                                grossOverride: correctionAmount,
                                note: correctionNote.trimmingCharacters(in: .whitespacesAndNewlines))
                            onAdd([line])
                        }
                        correctionLoad = nil
                        dismiss()
                    }
                    .bold()
                    .disabled(correctionAmount.isZero
                              || correctionNote.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Load line editor

struct SettlementLoadLineEditor: View {
    let line: SettlementLoadLine
    let maximumPercent: Decimal
    let onSave: (SettlementLoadLine) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var working: SettlementLoadLine
    @State private var useOverride: Bool
    @State private var overrideGross: Money
    @State private var useLoadPay: Bool
    @State private var loadPay: DriverPaySettings

    init(line: SettlementLoadLine, maximumPercent: Decimal, onSave: @escaping (SettlementLoadLine) -> Void) {
        self.line = line
        self.maximumPercent = maximumPercent
        self.onSave = onSave
        _working = State(initialValue: line)
        _useOverride = State(initialValue: line.grossRateOverride != nil)
        _overrideGross = State(initialValue: line.grossRateOverride ?? line.grossRate)
        _useLoadPay = State(initialValue: line.payRuleOverride != nil)
        _loadPay = State(initialValue: DriverPaySettings(
            profileId: line.profileId, driverId: line.profileId,
            payRule: line.payRuleOverride ?? .percentOfGross(0)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Load") {
                    LabeledContent("Load #", value: working.loadNumber ?? "—")
                    LabeledContent("Route", value: working.routeDescription)
                    SettlementDecimalField(title: "Loaded miles", value: $working.loadedMiles, suffix: "mi")
                    SettlementDecimalField(title: "Deadhead miles", value: $working.deadheadMiles, suffix: "mi")
                }
                Section {
                    SettlementMoneyField(title: "Linehaul", amount: $working.linehaul)
                    SettlementMoneyField(title: "Fuel surcharge", amount: $working.fuelSurcharge)
                    SettlementMoneyField(title: "Accessorials", amount: $working.accessorials)
                    SettlementMoneyField(title: "Detention", amount: $working.detention)
                    SettlementMoneyField(title: "Layover", amount: $working.layover)
                    SettlementMoneyField(title: "TONU", amount: $working.tonu)
                    SettlementMoneyField(title: "Lumper reimbursement", amount: $working.lumperReimbursement)
                    Toggle("Use a single gross rate", isOn: $useOverride)
                    if useOverride {
                        SettlementMoneyField(title: "Gross rate", amount: $overrideGross)
                    }
                    LabeledContent("Gross for this load", value: preview.grossRate.rounded.formatted)
                } header: {
                    Text("Revenue")
                } footer: {
                    Text("Changes here affect this settlement only. The load in the Loads tab is not changed.")
                }
                Section {
                    Toggle("Different pay for this load", isOn: $useLoadPay)
                } header: {
                    Text("Driver Pay")
                } footer: {
                    Text("A load override always pays on this load's own gross.")
                }
                if useLoadPay {
                    PayRuleEditor(settings: $loadPay, maximumPercent: maximumPercent,
                                  showsResponsibilities: false, perLoadOnly: true)
                    if let loadPayProblem {
                        Section {
                            Text(loadPayProblem)
                                .font(.caption)
                                .foregroundStyle(Color.spDanger)
                        }
                    }
                }
                Section("Notes") {
                    TextField("Optional", text: Binding(
                        get: { working.notes ?? "" },
                        set: { working.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
                }
            }
            .navigationTitle("Edit Load Line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(preview)
                        dismiss()
                    }
                    .bold()
                    .disabled(working.loadedMiles < 0 || working.deadheadMiles < 0 || loadPayProblem != nil)
                }
            }
        }
    }

    /// A load override must actually pay something — a 0% / empty override
    /// would silently pay $0.00 for this load.
    private var loadPayProblem: String? {
        guard useLoadPay else { return nil }
        if loadPay.payRule.components.isEmpty { return "Add a pay method for this load, or turn the override off." }
        return SettlementWorkflowService.payRuleProblem(loadPay.payRule, maximumPercent: maximumPercent)
    }

    private var preview: SettlementLoadLine {
        var l = working
        l.grossRateOverride = useOverride ? overrideGross.rounded : nil
        l.payRuleOverride = useLoadPay ? loadPay.payRule : nil
        return l
    }
}

// MARK: - Documents

struct SettlementDocumentsSheet: View {
    let settlementId: UUID
    let bundle: SettlementBundle?

    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var repo = SettlementRepository.shared
    @State private var documents: [TruckDocument] = []
    @State private var settlementDocuments: [TruckDocument] = []
    @State private var isLoading = true
    @State private var alert: SettlementAlert?
    @State private var previewURL: URL?

    private var loadIds: Set<UUID> {
        Set((bundle?.loadLines ?? []).compactMap(\.loadId))
    }

    private var linkedIds: Set<UUID> {
        Set(repo.ledger.documentLinks.filter { $0.settlementId == settlementId }.map(\.documentId))
    }

    /// Documents already tied to one of this settlement's loads (rate cons,
    /// BOLs, PODs, receipts scanned against the load) plus explicit links.
    private var related: [TruckDocument] {
        var seen: Set<UUID> = []
        return (settlementDocuments + documents).filter { doc in
            guard let id = doc.id, !seen.contains(id) else { return false }
            guard linkedIds.contains(id)
                    || (doc.loadId.map(loadIds.contains) ?? false)
                    || settlementDocuments.contains(where: { $0.id == id }) else { return false }
            seen.insert(id)
            return true
        }
    }

    private var attachable: [TruckDocument] {
        let relatedIds = Set(related.compactMap(\.id))
        return documents.filter { doc in
            guard let id = doc.id else { return false }
            return !relatedIds.contains(id)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("On This Settlement") {
                    if isLoading { ProgressView() }
                    if !isLoading && related.isEmpty {
                        Text("No documents yet. Scan rate confirmations, BOLs and receipts from the Loads tab and they appear here automatically.")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    ForEach(related, id: \.id) { doc in
                        Button {
                            Task { await open(doc) }
                        } label: {
                            documentRow(doc)
                        }
                    }
                }
                if repo.viewer.can(.editDraft) && !attachable.isEmpty {
                    Section("Attach From Documents") {
                        ForEach(attachable.prefix(40), id: \.id) { doc in
                            Button {
                                Task { await attach(doc) }
                            } label: {
                                HStack {
                                    documentRow(doc)
                                    Spacer()
                                    Image(systemName: "plus.circle").foregroundStyle(Color.spGold)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                repo.attach(supabase)
                if let bundle {
                    settlementDocuments = (try? await repo.documents(for: bundle)) ?? []
                }
                // The full vault is only needed by people who can attach.
                if repo.viewer.can(.editDraft) {
                    documents = (try? await supabase.fetchDocuments()) ?? []
                }
                isLoading = false
            }
            .alert(item: $alert) { a in
                Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
            }
            .sheet(item: Binding(
                get: { previewURL.map { IdentifiedURL(url: $0) } },
                set: { previewURL = $0?.url })
            ) { item in
                DocumentPreviewSheet(url: item.url, title: "Document")
            }
        }
    }

    private func documentRow(_ doc: TruckDocument) -> some View {
        let category = SettlementDocumentCategory(documentType: doc.documentType)
        return VStack(alignment: .leading, spacing: 2) {
            Text(doc.extractedData?.notes ?? category.displayName)
                .foregroundStyle(Color.spTextPrimary)
                .lineLimit(1)
            Text("\(category.displayName) · \(SettlementFormat.date(doc.createdAt))")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
        }
    }

    private func attach(_ doc: TruckDocument) async {
        guard let id = doc.id else { return }
        do {
            try await repo.link(documentId: id,
                                category: SettlementDocumentCategory(documentType: doc.documentType),
                                target: .settlement, targetId: settlementId,
                                settlementId: settlementId,
                                title: doc.extractedData?.notes)
        } catch {
            alert = SettlementAlert(error: error)
        }
    }

    private func open(_ doc: TruckDocument) async {
        do {
            previewURL = try await supabase.signedURL(forPath: doc.storagePath, expiresIn: 300)
        } catch {
            alert = SettlementAlert(error: error)
        }
    }
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
