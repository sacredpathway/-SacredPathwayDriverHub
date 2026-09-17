import SwiftUI

// =============================================================================
//  SettlementDetailView — review, edit, approve, pay, PDF
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). Everything on this screen is rendered from
//  `SettlementStatementDocument` / the calculation engine — the same source as
//  the PDF — so what is approved here is exactly what the driver receives.
//
//  Paid and voided settlements are read-only. Reopening asks for a reason
//  and is written to the audit trail.
// =============================================================================

struct SettlementDetailView: View {
    let settlementId: UUID

    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var repo = SettlementRepository.shared

    @State private var working: SettlementBundle?
    @State private var isDirty = false
    @State private var isBusy = false
    @State private var alert: SettlementAlert?
    @State private var sheet: DetailSheet?
    @State private var reasonPrompt: ReasonPrompt?
    @State private var reasonText = ""
    @State private var pdfData: Data?
    @State private var showingPDF = false
    @State private var showDiscard = false

    enum DetailSheet: Identifiable {
        case addition(SettlementAddition?)
        case deduction(SettlementDeduction?)
        case expenses
        case addLoads
        case markPaid
        case loadLine(SettlementLoadLine)
        case documents

        var id: String {
            switch self {
            case .addition(let a):  return "add-\(a?.id.uuidString ?? "new")"
            case .deduction(let d): return "ded-\(d?.id.uuidString ?? "new")"
            case .expenses:         return "expenses"
            case .addLoads:         return "loads"
            case .markPaid:         return "paid"
            case .loadLine(let l):  return "line-\(l.id.uuidString)"
            case .documents:        return "documents"
            }
        }
    }

    enum ReasonPrompt: String, Identifiable {
        case void, reopenToApproved, reopenToDraft
        var id: String { rawValue }
        var title: String {
            switch self {
            case .void:             return "Void Settlement"
            case .reopenToApproved: return "Reopen Paid Settlement"
            case .reopenToDraft:    return "Reopen for Editing"
            }
        }
        var target: SettlementStatus {
            switch self {
            case .void:             return .voided
            case .reopenToApproved: return .approved
            case .reopenToDraft:    return .draft
            }
        }
    }

    // MARK: - Derived

    private var stored: SettlementBundle? { repo.ledger.bundle(for: settlementId) }

    private var bundle: SettlementBundle? { working ?? stored }

    private var canEdit: Bool {
        guard let s = stored?.settlement else { return false }
        return SettlementPermissions.canEdit(s, viewer: repo.viewer)
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            if let bundle {
                SettlementReviewContent(
                    bundle: bundle,
                    editable: canEdit,
                    onEditLine: { line in sheet = .loadLine(line) },
                    onRemoveLine: { line in mutate { $0.loadLines.removeAll { $0.id == line.id } } },
                    onAddLoads: { sheet = .addLoads },
                    onAddAddition: { sheet = .addition(nil) },
                    onEditAddition: { a in sheet = .addition(a) },
                    onRemoveAddition: { a in mutate { $0.additions.removeAll { $0.id == a.id } } },
                    onAddDeduction: { sheet = .deduction(nil) },
                    onAddFromExpenses: { sheet = .expenses },
                    onEditDeduction: { d in sheet = .deduction(d) },
                    onRemoveDeduction: { d in mutate { $0.deductions.removeAll { $0.id == d.id } } },
                    onNotesChanged: { text in mutate { $0.settlement.notes = text.isEmpty ? nil : text } },
                    onDocuments: { sheet = .documents },
                    actions: AnyView(actionBar(for: bundle))
                )
            } else if repo.isLoading {
                ProgressView().tint(Color.spGold)
            } else {
                SettlementEmptyState(title: "Settlement not found",
                                     message: "It may have been removed on another device, or you don't have access to it.")
            }
            if isBusy {
                Color.black.opacity(0.25).ignoresSafeArea()
                ProgressView().tint(Color.spGold).scaleEffect(1.4)
            }
        }
        .navigationTitle(bundle?.settlement.displayNumber ?? "Settlement")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isDirty)
        .toolbar { toolbar }
        .sheet(item: $sheet) { which in sheetView(which) }
        .sheet(isPresented: $showingPDF) {
            if let pdfData, let bundle {
                SettlementPDFSheet(data: pdfData, document: repo.statement(for: bundle))
            }
        }
        .alert(item: $alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
        .alert(reasonPrompt?.title ?? "", isPresented: Binding(
            get: { reasonPrompt != nil },
            set: { if !$0 { reasonPrompt = nil } })
        ) {
            TextField("Reason (required)", text: $reasonText)
            Button("Cancel", role: .cancel) { reasonText = "" }
            Button(reasonPrompt == .void ? "Void" : "Reopen", role: reasonPrompt == .void ? .destructive : nil) {
                if let prompt = reasonPrompt {
                    let reason = reasonText
                    reasonText = ""
                    Task { await move(to: prompt.target, reason: reason) }
                }
            }
        } message: {
            Text("This is recorded in the settlement's audit trail.")
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) {
                working = nil
                isDirty = false
            }
        }
        .task {
            repo.attach(supabase)
            if !repo.hasLoaded { await repo.reload() }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isDirty {
            ToolbarItem(placement: .cancellationAction) {
                Button("Discard") { showDiscard = true }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await saveChanges() } }
                    .bold()
                    .disabled(isBusy)
                    .accessibilityIdentifier("settlement.save")
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await makePDF() } } label: {
                        Label("Preview PDF", systemImage: "doc.richtext")
                    }
                    if repo.viewer.can(.editDraft) && repo.viewer.can(.export) {
                        Button { Task { await makePDF(saveToVault: true) } } label: {
                            Label("Save PDF to Documents", systemImage: "tray.and.arrow.down")
                        }
                        .disabled(AppMode.shared.isLocal)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Statement PDF")
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionBar(for bundle: SettlementBundle) -> some View {
        let status = bundle.settlement.settlementStatus
        let viewer = repo.viewer
        VStack(spacing: 10) {
            if isDirty {
                primaryButton("Save Changes", icon: "tray.and.arrow.down.fill") {
                    Task { await saveChanges() }
                }
            } else {
                switch status {
                case .draft:
                    if viewer.can(.approve) {
                        primaryButton("Approve Settlement", icon: "checkmark.seal.fill") {
                            Task { await move(to: .approved) }
                        }
                    }
                    if viewer.can(.submitForReview) {
                        secondaryButton("Mark Ready for Review", icon: "eye") {
                            Task { await move(to: .readyForReview) }
                        }
                    }
                case .readyForReview:
                    if viewer.can(.approve) {
                        primaryButton("Approve Settlement", icon: "checkmark.seal.fill") {
                            Task { await move(to: .approved) }
                        }
                    }
                    if viewer.can(.editDraft) {
                        secondaryButton("Back to Draft", icon: "arrow.uturn.backward") {
                            Task { await move(to: .draft) }
                        }
                    }
                case .approved:
                    if viewer.can(.markPaid) {
                        primaryButton("Mark Paid", icon: "dollarsign.circle.fill") {
                            sheet = .markPaid
                        }
                    }
                    if viewer.can(.reopen) {
                        secondaryButton("Reopen for Editing", icon: "lock.open") {
                            reasonPrompt = .reopenToDraft
                        }
                    }
                case .paid:
                    Label(paidCaption(bundle.settlement), systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                    if viewer.can(.reopen) {
                        secondaryButton("Reopen Paid Settlement", icon: "lock.open") {
                            reasonPrompt = .reopenToApproved
                        }
                    }
                case .voided:
                    Label("Voided \(SettlementFormat.date(bundle.settlement.voidedAt)) — kept for history", systemImage: "xmark.octagon")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                    if viewer.can(.reopen) {
                        secondaryButton("Restore as Draft", icon: "arrow.uturn.backward") {
                            reasonPrompt = .reopenToDraft
                        }
                    }
                }
                secondaryButton("Preview Statement PDF", icon: "doc.richtext") {
                    Task { await makePDF() }
                }
                if status != .voided && status != .paid && viewer.can(.void) {
                    Button(role: .destructive) {
                        reasonPrompt = .void
                    } label: {
                        Label("Void Settlement", systemImage: "xmark.circle")
                            .font(.subheadline)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func paidCaption(_ s: Settlement) -> String {
        var text = "Paid \(SettlementFormat.date(s.paidAt))"
        if let ref = s.paymentReference, !ref.isEmpty { text += " · Ref \(ref)" }
        if let method = s.paymentMethod, !method.isEmpty { text += " · \(method)" }
        return text
    }

    private func primaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.spGold)
                .foregroundStyle(Color.spBlack)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isBusy)
    }

    private func secondaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.spCardBg)
                .foregroundStyle(Color.spGold)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isBusy)
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetView(_ which: DetailSheet) -> some View {
        switch which {
        case .addition(let existing):
            SettlementAdditionEditor(
                existing: existing,
                profileId: bundle?.settlement.profileId ?? UUID(),
                settlementId: settlementId,
                loads: bundle?.loadLines ?? []
            ) { addition in
                mutate { b in
                    if let idx = b.additions.firstIndex(where: { $0.id == addition.id }) {
                        b.additions[idx] = addition
                    } else {
                        var a = addition
                        a.sortOrder = (b.additions.map(\.sortOrder).max() ?? 0) + 1
                        b.additions.append(a)
                    }
                }
            }
        case .deduction(let existing):
            SettlementDeductionEditor(
                existing: existing,
                profileId: bundle?.settlement.profileId ?? UUID(),
                settlementId: settlementId,
                loads: bundle?.loadLines ?? [],
                paySettings: paySettings,
                advances: advancesForDriver,
                repayments: repo.ledger.advanceRepayments
            ) { deduction in
                mutate { b in
                    if let idx = b.deductions.firstIndex(where: { $0.id == deduction.id }) {
                        b.deductions[idx] = deduction
                    } else {
                        var d = deduction
                        d.sortOrder = (b.deductions.map(\.sortOrder).filter { $0 < 8_000 }.max() ?? 1_999) + 1
                        b.deductions.append(d)
                    }
                }
            }
        case .expenses:
            SettlementExpensePicker(
                alreadyOnSettlement: Set((bundle?.deductions ?? []).compactMap(\.relatedExpenseId)),
                linkedElsewhere: repo.ledger.alreadyLinkedExpenseIds(excluding: settlementId),
                period: bundle.flatMap { b -> SettlementDateRange? in
                    guard let s = b.settlement.settlementPeriodStart,
                          let e = b.settlement.settlementPeriodEnd else { return nil }
                    return SettlementDateRange(start: s, end: e)
                }
            ) { expenses in
                addExpenses(expenses)
            }
            .environmentObject(supabase)
        case .addLoads:
            SettlementAddLoadsView(settlementId: settlementId, bundle: bundle) { lines in
                mutate { b in
                    var order = (b.loadLines.map(\.sortOrder).max() ?? -1) + 1
                    for var line in lines {
                        line.sortOrder = order
                        order += 1
                        b.loadLines.append(line)
                    }
                }
            }
        case .markPaid:
            MarkPaidSheet(netPay: bundle?.settlement.netPayMoney ?? .zero) { reference, method in
                Task {
                    await move(to: .paid, paymentReference: reference, paymentMethod: method)
                }
            }
        case .loadLine(let line):
            SettlementLoadLineEditor(line: line, maximumPercent: repo.maximumDriverPercent) { updated in
                mutate { b in
                    if let idx = b.loadLines.firstIndex(where: { $0.id == updated.id }) {
                        b.loadLines[idx] = updated
                    }
                }
            }
        case .documents:
            SettlementDocumentsSheet(settlementId: settlementId, bundle: bundle)
                .environmentObject(supabase)
        }
    }

    private var paySettings: DriverPaySettings {
        if let driver = repo.driver(id: bundle?.settlement.driverId) {
            return repo.paySettings(for: driver)
        }
        return DriverPaySettings(profileId: bundle?.settlement.profileId ?? UUID(),
                                 driverId: bundle?.settlement.driverId ?? UUID(),
                                 settlementType: bundle?.settlement.effectiveSettlementType ?? .companyDriver)
    }

    private var advancesForDriver: [DriverAdvance] {
        guard let driverId = bundle?.settlement.driverId else { return [] }
        return repo.ledger.advances(forDriver: driverId)
    }

    // MARK: - Mutation

    private func mutate(_ change: (inout SettlementBundle) -> Void) {
        guard canEdit, var copy = working ?? stored else { return }
        change(&copy)
        SettlementWorkflowService.recalculate(&copy, rules: repo.ledger.recurringDeductions)
        working = copy
        isDirty = true
    }

    private func addExpenses(_ expenses: [Expense]) {
        guard canEdit, var copy = working ?? stored else { return }
        var failures: [String] = []
        for expense in expenses {
            do {
                try SettlementWorkflowService.addExpense(expense, to: &copy,
                                                         paySettings: paySettings,
                                                         ledger: repo.ledger)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        SettlementWorkflowService.recalculate(&copy, rules: repo.ledger.recurringDeductions)
        working = copy
        isDirty = true
        if let first = failures.first {
            alert = SettlementAlert("Some expenses were skipped", first)
        }
    }

    private func saveChanges() async {
        guard !isBusy, let working else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await repo.save(working)
            self.working = nil
            isDirty = false
        } catch {
            alert = SettlementAlert(error: error)
        }
    }

    private func move(
        to target: SettlementStatus,
        reason: String? = nil,
        paymentReference: String? = nil,
        paymentMethod: String? = nil
    ) async {
        if isDirty {
            alert = SettlementAlert("Save first", "Save or discard your changes before changing the status.")
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await repo.transition(settlementId, to: target, reason: reason,
                                      paymentReference: paymentReference,
                                      paymentMethod: paymentMethod)
        } catch {
            alert = SettlementAlert(error: error)
        }
    }

    private func makePDF(saveToVault: Bool = false) async {
        guard !isBusy, let bundle = stored ?? working else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let document = repo.statement(for: bundle)
            let data = try await SettlementPDFExporter.statementPDF(document)
            if saveToVault, !AppMode.shared.isLocal {
                let title = "Settlement \(document.settlementNumber) — \(document.driverName) — \(document.periodDescription)"
                let record = try await supabase.saveDocumentRecord(
                    pdfData: data, documentType: "settlement", title: title)
                if let docId = record.id {
                    try? await repo.link(documentId: docId, category: .settlementPDF,
                                         target: .settlement, targetId: settlementId,
                                         settlementId: settlementId, title: title)
                }
                alert = SettlementAlert("Saved", "The statement was saved to Documents.")
            } else {
                pdfData = data
                showingPDF = true
            }
        } catch {
            alert = SettlementAlert(error: error)
        }
    }
}

// MARK: - Estimate detail

struct SettlementEstimateDetailView: View {
    let driverId: UUID
    let range: SettlementDateRange

    @ObservedObject private var repo = SettlementRepository.shared
    @State private var pdfData: Data?
    @State private var showingPDF = false
    @State private var alert: SettlementAlert?

    private var bundle: SettlementBundle? {
        guard let driver = repo.driver(id: driverId) else { return nil }
        return repo.estimate(for: driver, range: range)
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            if let bundle {
                SettlementReviewContent(
                    bundle: bundle,
                    editable: false,
                    actions: AnyView(
                        VStack(spacing: 8) {
                            Text("Estimates include booked and in-progress loads and are never saved, approved or paid. Create a settlement once loads are delivered.")
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                            Button {
                                Task { await preview(bundle) }
                            } label: {
                                Label("Preview Estimate PDF", systemImage: "doc.richtext")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.spCardBg)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    )
                )
            } else {
                SettlementEmptyState(title: "No estimate", message: "This driver is no longer available.")
            }
        }
        .navigationTitle("Estimated Settlement")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPDF) {
            if let pdfData, let bundle {
                SettlementPDFSheet(data: pdfData, document: repo.statement(for: bundle))
            }
        }
        .alert(item: $alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }

    private func preview(_ bundle: SettlementBundle) async {
        do {
            pdfData = try await SettlementPDFExporter.statementPDF(repo.statement(for: bundle))
            showingPDF = true
        } catch {
            alert = SettlementAlert(error: error)
        }
    }
}

// MARK: - Shared review content

struct SettlementReviewContent: View {
    let bundle: SettlementBundle
    let editable: Bool
    var onEditLine: (SettlementLoadLine) -> Void = { _ in }
    var onRemoveLine: (SettlementLoadLine) -> Void = { _ in }
    var onAddLoads: () -> Void = {}
    var onAddAddition: () -> Void = {}
    var onEditAddition: (SettlementAddition) -> Void = { _ in }
    var onRemoveAddition: (SettlementAddition) -> Void = { _ in }
    var onAddDeduction: () -> Void = {}
    var onAddFromExpenses: () -> Void = {}
    var onEditDeduction: (SettlementDeduction) -> Void = { _ in }
    var onRemoveDeduction: (SettlementDeduction) -> Void = { _ in }
    var onNotesChanged: (String) -> Void = { _ in }
    var onDocuments: () -> Void = {}
    var actions: AnyView = AnyView(EmptyView())

    @ObservedObject private var repo = SettlementRepository.shared

    var body: some View {
        // Drivers and locked history see the stored load earnings; an editable
        // working copy is always re-priced live.
        let result = bundle.calculate(frozenLoadEarnings: !editable && (repo.role == .driver || bundle.settlement.isLocked))
        let issues = (editable || bundle.settlement.settlementStatus == .readyForReview)
            ? repo.issues(for: bundle) : []
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettlementHeaderCard(bundle: bundle, driverName: repo.driverName(bundle.settlement.driverId))
                SettlementNetPayHero(
                    amount: result.netDriverPay,
                    isEstimate: result.isEstimate,
                    caption: "\(result.totalLoads) load\(result.totalLoads == 1 ? "" : "s") · \(SettlementFormat.miles(result.totalMiles))")
                SettlementSummaryCard(result: result,
                                      showCompany: repo.viewer.can(.viewCompanyFinancials))
                SettlementIssuesView(issues: issues)
                loadsCard(result)
                if !result.lineItems.filter({ $0.kind == .settlementEarning }).isEmpty {
                    SettlementCard(title: "Other Earnings") {
                        ForEach(result.lineItems.filter { $0.kind == .settlementEarning }) { line in
                            SettlementAmountRow(title: line.label, subtitle: line.basis,
                                                amount: line.amount, style: .credit)
                        }
                    }
                }
                additionsCard(result)
                deductionsCard(result)
                if repo.viewer.can(.viewCompanyFinancials) && !result.companyExpenseLines.isEmpty {
                    SettlementCard(title: "Company-Paid (not on driver's check)",
                                   trailing: result.companyExpenses.formatted) {
                        ForEach(result.companyExpenseLines) { line in
                            SettlementAmountRow(title: line.label, subtitle: line.basis, amount: line.amount)
                        }
                    }
                }
                notesCard
                if !bundle.settlement.isEstimateRecord && !AppMode.shared.isLocal {
                    Button(action: onDocuments) {
                        Label("Documents (\(bundle.documentLinks.count))", systemImage: "paperclip")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                actions
                if repo.viewer.can(.viewAuditTrail) && !bundle.auditEvents.isEmpty {
                    SettlementAuditTrailView(events: bundle.auditEvents)
                }
            }
            .padding()
        }
    }

    private func loadsCard(_ result: SettlementCalculationResult) -> some View {
        SettlementCard(title: "Loads", trailing: result.grossLoadRevenue.formatted) {
            if bundle.loadLines.isEmpty {
                Text("No loads on this settlement.")
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextSecondary)
            }
            ForEach(bundle.loadLines) { line in
                SettlementLoadLineRow(line: line,
                                      earnings: result.loadEarnings[line.id] ?? .zero,
                                      basis: result.loadPayBasis[line.id] ?? "",
                                      editable: editable,
                                      onEdit: { onEditLine(line) },
                                      onRemove: { onRemoveLine(line) })
                if line.id != bundle.loadLines.last?.id { Divider() }
            }
            if editable {
                Button(action: onAddLoads) {
                    Label("Add Load or Correction", systemImage: "plus.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.top, 4)
            }
        }
    }

    private func additionsCard(_ result: SettlementCalculationResult) -> some View {
        SettlementCard(title: "Additions", trailing: result.totalAdditions.formattedSigned(asCredit: true)) {
            if bundle.additions.isEmpty {
                Text("None")
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextSecondary)
            }
            ForEach(bundle.additions) { addition in
                EditableAmountRow(
                    title: addition.descriptionText,
                    subtitle: [addition.category.displayName, addition.notes].compactMap { $0 }.joined(separator: " · "),
                    amount: addition.amount.rounded,
                    style: .credit,
                    editable: editable,
                    onEdit: { onEditAddition(addition) },
                    onRemove: { onRemoveAddition(addition) })
            }
            if editable {
                Button(action: onAddAddition) {
                    Label("Add Bonus, Detention, Reimbursement…", systemImage: "plus.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.top, 4)
            }
        }
    }

    private func deductionsCard(_ result: SettlementCalculationResult) -> some View {
        SettlementCard(title: "Deductions", trailing: result.totalDriverDeductions.formattedSigned(asCredit: false)) {
            let driverLines = bundle.deductions.filter { $0.effectiveDriverPercent > 0 }
            if driverLines.isEmpty && result.driverDeductionLines.isEmpty {
                Text("None")
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextSecondary)
            }
            ForEach(driverLines) { deduction in
                EditableAmountRow(
                    title: deduction.descriptionText,
                    subtitle: deductionSubtitle(deduction),
                    amount: deduction.driverAmount,
                    style: .debit,
                    editable: editable,
                    onEdit: { onEditDeduction(deduction) },
                    onRemove: { onRemoveDeduction(deduction) })
            }
            // Company fee lines the engine adds from the frozen fee terms.
            ForEach(result.driverDeductionLines.filter { line in
                !bundle.deductions.contains { $0.id == line.id }
            }) { line in
                SettlementAmountRow(title: line.label, subtitle: line.basis, amount: line.amount, style: .debit)
            }
            if editable {
                let companyOnly = bundle.deductions.filter { $0.effectiveDriverPercent == 0 }
                ForEach(companyOnly) { deduction in
                    EditableAmountRow(
                        title: deduction.descriptionText,
                        subtitle: "\(deduction.category.displayName) · company pays",
                        amount: deduction.amount.rounded,
                        style: .plain,
                        editable: true,
                        onEdit: { onEditDeduction(deduction) },
                        onRemove: { onRemoveDeduction(deduction) })
                        .opacity(0.6)
                }
                HStack(spacing: 16) {
                    Button(action: onAddDeduction) {
                        Label("Add Deduction", systemImage: "minus.circle")
                    }
                    Button(action: onAddFromExpenses) {
                        Label("From Expenses", systemImage: "creditcard")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            }
        }
    }

    private func deductionSubtitle(_ d: SettlementDeduction) -> String {
        var bits = [d.category.displayName]
        if d.responsibility == .split {
            bits.append("driver \(d.effectiveDriverPercent.asPercentString) of \(d.amount.rounded.formatted)")
        }
        if d.recurringDeductionId != nil { bits.append("recurring") }
        if d.advanceId != nil { bits.append("advance recovery") }
        if d.relatedExpenseId != nil { bits.append("from Expenses") }
        if let notes = d.notes, !notes.isEmpty, d.recurringDeductionId == nil { bits.append(notes) }
        return bits.joined(separator: " · ")
    }

    @ViewBuilder
    private var notesCard: some View {
        if editable {
            SettlementNotesEditor(initial: bundle.settlement.notes ?? "", onCommit: onNotesChanged)
        } else if let notes = bundle.settlement.notes, !notes.isEmpty, repo.role != .driver {
            SettlementCard(title: "Notes") {
                Text(notes)
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextPrimary)
            }
        }
    }
}

// MARK: - Pieces

struct SettlementHeaderCard: View {
    let bundle: SettlementBundle
    let driverName: String

    var body: some View {
        let s = bundle.settlement
        SettlementCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(driverName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.spTextPrimary)
                    Text(s.periodDescription)
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                }
                Spacer()
                SettlementStatusBadge(status: s.settlementStatus, isEstimate: s.isEstimateRecord)
            }
            Divider()
            detail("Settlement #", s.settlementNumber ?? (s.isEstimateRecord ? "Estimate" : "Assigned on approval"))
            detail("Truck / Unit", s.truckNumber ?? "—")
            detail("Type", s.effectiveSettlementType.displayName)
            detail("Pay", s.effectivePayRule.summary)
            if s.payOnGrossRevenue == false {
                detail("Percent basis", "Net after company costs")
            }
            if let approved = s.approvedAt {
                detail("Approved", SettlementFormat.dateTime.string(from: approved))
            }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct SettlementSummaryCard: View {
    let result: SettlementCalculationResult
    let showCompany: Bool

    var body: some View {
        SettlementCard(title: "Summary") {
            SettlementAmountRow(title: "Gross Revenue", amount: result.grossLoadRevenue)
            SettlementAmountRow(title: "Driver Earnings", amount: result.driverBaseEarnings)
            SettlementAmountRow(title: "Additions", amount: result.totalAdditions, style: .credit)
            SettlementAmountRow(title: "Deductions", amount: result.totalDriverDeductions, style: .debit)
            Divider()
            HStack {
                Text(result.isEstimate ? "Estimated Net Pay" : "Net Pay")
                    .font(.headline)
                    .foregroundStyle(Color.spTextPrimary)
                Spacer()
                SettlementMoneyText(amount: result.netDriverPay,
                                    font: .system(.title3, design: .monospaced).weight(.heavy))
            }
            Divider()
            HStack(spacing: 8) {
                SettlementMetricTile(title: "Rev / mi", value: SettlementFormat.perMile(result.revenuePerMile), icon: "road.lanes")
                SettlementMetricTile(title: "Driver / mi", value: SettlementFormat.perMile(result.driverEarningsPerMile), icon: "person.fill")
                SettlementMetricTile(title: "Fuel / mi", value: SettlementFormat.perMile(result.fuelCostPerMile), icon: "fuelpump.fill")
            }
            if showCompany {
                Divider()
                SettlementAmountRow(title: "Company Expenses", amount: result.companyExpenses)
                SettlementAmountRow(title: "Company Retained",
                                    subtitle: "gross − net pay − company expenses",
                                    amount: result.companyRetained)
                HStack {
                    Text("Expense Ratio")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextPrimary)
                    Spacer()
                    Text(SettlementFormat.percent(result.expenseRatio))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                }
            }
            if !result.warnings.isEmpty {
                ForEach(result.warnings, id: \.self) { w in
                    Label(w, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
            }
        }
    }
}

struct SettlementLoadLineRow: View {
    let line: SettlementLoadLine
    let earnings: Money
    let basis: String
    let editable: Bool
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(line.loadNumber ?? "Load")
                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                        .foregroundStyle(Color.spTextPrimary)
                    if line.isAdjustment {
                        Text("CORRECTION")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Color.spGold)
                    }
                }
                Text(line.routeDescription)
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .lineLimit(1)
                Text(meta)
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
                    .lineLimit(2)
                if !basis.isEmpty {
                    Text(basis)
                        .font(.caption2)
                        .foregroundStyle(Color.spGold)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                SettlementMoneyText(amount: line.grossRate.rounded,
                                    font: .system(.caption, design: .monospaced))
                SettlementMoneyText(amount: earnings)
                if editable {
                    Menu {
                        Button { onEdit() } label: { Label("Edit Load Line", systemImage: "pencil") }
                        Button(role: .destructive) { onRemove() } label: {
                            Label("Remove from Settlement", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Color.spGold)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var meta: String {
        var bits: [String] = []
        if let b = line.brokerName, !b.isEmpty { bits.append(b) }
        if let p = line.pickupDate { bits.append("PU \(SettlementFormat.shortDate.string(from: p))") }
        if let d = line.deliveryDate { bits.append("DL \(SettlementFormat.shortDate.string(from: d))") }
        bits.append(SettlementFormat.miles(line.totalMiles))
        if line.deadheadMiles > 0 { bits.append("\(SettlementFormat.miles(line.deadheadMiles)) deadhead") }
        return bits.joined(separator: " · ")
    }
}

struct EditableAmountRow: View {
    let title: String
    let subtitle: String
    let amount: Money
    let style: SettlementMoneyText.Style
    let editable: Bool
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SettlementAmountRow(title: title, subtitle: subtitle, amount: amount, style: style)
            if editable {
                Menu {
                    Button { onEdit() } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { onRemove() } label: { Label("Remove", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Color.spGold)
                }
            }
        }
    }
}

struct SettlementNotesEditor: View {
    let initial: String
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        SettlementCard(title: "Notes") {
            TextField("Notes for this settlement (internal)", text: $text, axis: .vertical)
                .lineLimit(2...5)
                .focused($focused)
                .onChange(of: text) { _, newText in
                    // Commit as the user types so a Save tapped while the
                    // field still has focus includes the latest text.
                    if focused, newText != initial { onCommit(newText) }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused, text != initial { onCommit(text) }
                }
        }
        .onAppear { text = initial }
        .onChange(of: initial) { _, newInitial in
            // Discard / reload: show the stored text again.
            if !focused { text = newInitial }
        }
    }
}

struct SettlementAuditTrailView: View {
    let events: [SettlementAuditEvent]
    @State private var expanded = false

    var body: some View {
        SettlementCard(title: "Audit Trail", trailing: "\(events.count) events") {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.summary)
                            .font(.caption)
                            .foregroundStyle(Color.spTextPrimary)
                        Text("\(SettlementFormat.dateTime.string(from: event.timestamp)) · \(event.actorName ?? "Unknown user")")
                            .font(.caption2)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    .padding(.vertical, 3)
                }
            } label: {
                Text(expanded ? "Hide history" : "Show who changed what, and when")
                    .font(.subheadline)
            }
        }
    }
}

// MARK: - Mark paid

struct MarkPaidSheet: View {
    let netPay: Money
    let onConfirm: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reference = ""
    @State private var method = "Direct Deposit"

    private let methods = ["Direct Deposit", "ACH", "Check", "Zelle", "Cash App", "Wire", "Cash", "Other"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Net Pay", value: netPay.formatted)
                    Picker("Payment Method", selection: $method) {
                        ForEach(methods, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Reference / check # (optional)", text: $reference)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Only mark a settlement paid once the money has actually been sent. Paid settlements are locked.")
                }
            }
            .navigationTitle("Mark Paid")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Mark Paid") {
                        onConfirm(reference.trimmingCharacters(in: .whitespaces), method)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - PDF sheet

struct SettlementPDFSheet: View {
    let data: Data
    let document: SettlementStatementDocument
    @State private var fileURL: URL?

    var body: some View {
        PDFPreviewView(data: data, title: "Statement \(document.settlementNumber)")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if let fileURL {
                        ShareLink(item: fileURL) {
                            Label("Share / Save", systemImage: "square.and.arrow.up")
                        }
                    }
                    Spacer()
                    Button {
                        SettlementPDFExporter.print(data, jobName: document.fileName)
                    } label: {
                        Label("Print", systemImage: "printer")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .onAppear {
                fileURL = try? SettlementPDFExporter.temporaryFile(data, named: document.fileName)
            }
            .onDisappear {
                SettlementPDFExporter.cleanupTemporaryFiles()
            }
    }
}
