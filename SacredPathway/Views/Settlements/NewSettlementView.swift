import SwiftUI

// =============================================================================
//  NewSettlementView — fast settlement creation
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). One screen, top to bottom:
//   1. Driver   2. Week   3. Loads (auto-selected)   4. Pay terms
//   5. Recurring deductions + advance recovery   6. Live preview → Create Draft
//  Additions, extra deductions, PDF preview and approval happen on the review
//  screen the wizard opens next.
// =============================================================================

struct NewSettlementView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var repo = SettlementRepository.shared
    @ObservedObject private var loadsSync = LoadsSyncService.shared
    @ObservedObject private var payWeek = PayWeekService.shared

    let onCreated: (UUID) -> Void

    private enum WeekChoice: String, CaseIterable, Identifiable {
        case thisWeek = "This Week"
        case lastWeek = "Last Week"
        case custom = "Custom"
        var id: String { rawValue }
    }

    @State private var driverId: UUID?
    @State private var week: WeekChoice = .lastWeek
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var selectedLoadIds: Set<UUID> = []
    @State private var includeUnassigned = false
    @State private var applyRecurring = true
    @State private var advancePolicy: AdvanceRecoveryPolicy = .manual
    @State private var advanceAmount: Money = .zero
    @State private var hoursWorked: Decimal = 0
    @State private var overridePay = false
    @State private var payOverride: DriverPaySettings?
    @State private var isSaving = false
    @State private var alert: SettlementAlert?
    @State private var showingAddDriver = false

    // MARK: - Derived

    private var driver: Driver? { repo.driver(id: driverId) }

    private var period: SettlementDateRange {
        switch week {
        case .thisWeek:
            return SettlementDateRange.preset(.thisWeek, firstWeekday: payWeek.firstWeekday)
        case .lastWeek:
            return SettlementDateRange.preset(.lastWeek, firstWeekday: payWeek.firstWeekday)
        case .custom:
            return SettlementDateRange(start: min(customStart, customEnd), end: max(customStart, customEnd))
        }
    }

    private var eligible: [EligibleSettlementLoad] {
        guard let driverId else { return [] }
        return SettlementWorkflowService.eligibleLoads(
            from: loadsSync.loads, driverId: driverId,
            periodStart: period.start, periodEnd: period.end,
            ledger: repo.ledger, includeUnassigned: includeUnassigned)
    }

    private var selectedLoads: [Load] {
        eligible.filter { selectedLoadIds.contains($0.id) && $0.isSelectable }.map(\.load)
    }

    private var effectiveSettings: DriverPaySettings? {
        guard let driver else { return nil }
        if overridePay, let payOverride { return payOverride }
        return repo.paySettings(for: driver)
    }

    private var needsHours: Bool {
        effectiveSettings?.payRule.components.contains { $0.kind == .hourly && $0.hours == nil } ?? false
    }

    private var preview: SettlementBundle? {
        guard let driver else { return nil }
        return try? repo.newDraft(
            driver: driver, periodStart: period.start, periodEnd: period.end,
            loads: selectedLoads, applyRecurring: applyRecurring,
            advancePolicy: advancePolicy,
            advanceAmount: advancePolicy == .fixedPerSettlement ? advanceAmount : nil,
            hoursWorked: needsHours ? hoursWorked : nil,
            paySettingsOverride: overridePay ? payOverride : nil)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                driverSection
                if driver != nil {
                    periodSection
                    loadsSection
                    paySection
                    deductionsSection
                    previewSection
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.spBackground)
            .navigationTitle("New Settlement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await create() }
                    } label: {
                        if isSaving { ProgressView() } else { Text("Create Draft").bold() }
                    }
                    .disabled(driver == nil || isSaving)
                    .accessibilityIdentifier("settlements.createDraft")
                }
            }
            .alert(item: $alert) { a in
                Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
            }
            .sheet(isPresented: $showingAddDriver) {
                AddSettlementDriverView { created in
                    driverId = created.id
                }
                .environmentObject(supabase)
            }
            .onAppear {
                if driverId == nil { driverId = repo.activeDrivers.first?.id }
                includeUnassigned = AppMode.shared.isLocal && repo.activeDrivers.count <= 1
                selectDefaults()
            }
            .onChange(of: driverId) { _, _ in
                payOverride = nil
                overridePay = false
                selectDefaults()
            }
            .onChange(of: week) { _, _ in selectDefaults() }
            .onChange(of: customStart) { _, _ in selectDefaults() }
            .onChange(of: customEnd) { _, _ in selectDefaults() }
            .onChange(of: includeUnassigned) { _, _ in selectDefaults() }
        }
    }

    // MARK: - Sections

    private var driverSection: some View {
        Section {
            if repo.activeDrivers.isEmpty {
                Text("No drivers yet.")
                    .foregroundStyle(Color.spTextSecondary)
            } else {
                Picker("Driver", selection: $driverId) {
                    Text("Select a driver").tag(UUID?.none)
                    ForEach(repo.activeDrivers, id: \.id) { d in
                        Text(d.name).tag(d.id)
                    }
                }
            }
            if repo.viewer.can(.managePaySettings) {
                Button {
                    showingAddDriver = true
                } label: {
                    Label("Add Driver", systemImage: "person.badge.plus")
                }
            }
        } header: {
            Text("1 · Driver")
        }
    }

    private var periodSection: some View {
        Section {
            Picker("Week", selection: $week) {
                ForEach(WeekChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if week == .custom {
                DatePicker("Start", selection: $customStart, displayedComponents: .date)
                DatePicker("End", selection: $customEnd, displayedComponents: .date)
            }
            LabeledContent("Period", value: period.description)
        } header: {
            Text("2 · Settlement Period")
        } footer: {
            Text("Loads are included by pickup date. Your pay week starts on \(payWeek.displayName).")
        }
    }

    private var loadsSection: some View {
        Section {
            Toggle("Include unassigned loads", isOn: $includeUnassigned)
            if eligible.isEmpty {
                Text("No completed loads for this driver in this period.")
                    .foregroundStyle(Color.spTextSecondary)
            }
            ForEach(eligible) { item in
                LoadSelectionRow(
                    item: item,
                    isSelected: selectedLoadIds.contains(item.id),
                    paidOn: item.alreadyPaidOn.flatMap { repo.ledger.settlement(id: $0)?.displayNumber }
                ) {
                    guard item.isSelectable else { return }
                    if selectedLoadIds.contains(item.id) {
                        selectedLoadIds.remove(item.id)
                    } else {
                        selectedLoadIds.insert(item.id)
                    }
                }
            }
        } header: {
            Text("3 · Loads (\(selectedLoads.count) selected)")
        } footer: {
            Text("Loads already paid on another settlement can't be selected. Loads marked settled by the older Paystub Maker are shown but not pre-selected.")
        }
    }

    @ViewBuilder
    private var paySection: some View {
        Section {
            if let settings = effectiveSettings {
                LabeledContent("Type", value: settings.settlementType.displayName)
                LabeledContent("Pay", value: settings.payRule.summary)
                LabeledContent("Percent basis", value: settings.payOnGrossRevenue ? "Gross revenue" : "Net after company costs")
            }
            Toggle("Different pay for this settlement", isOn: $overridePay)
                .onChange(of: overridePay) { _, on in
                    if on, payOverride == nil, let driver { payOverride = repo.paySettings(for: driver) }
                }
            if needsHours {
                SettlementDecimalField(title: "Hours worked", value: $hoursWorked, suffix: "hrs")
            }
        } header: {
            Text("4 · Pay Terms")
        } footer: {
            Text("An override applies to this settlement only. The driver's saved pay stays the same.")
        }
        if overridePay, payOverride != nil {
            PayRuleEditor(settings: Binding(
                get: { payOverride ?? DriverPaySettings(profileId: UUID(), driverId: UUID()) },
                set: { payOverride = $0 }),
                maximumPercent: repo.maximumDriverPercent,
                showsResponsibilities: false)
        }
    }

    private var deductionsSection: some View {
        Section {
            Toggle("Apply recurring deductions", isOn: $applyRecurring)
            if let driverId {
                let rules = repo.ledger.recurringDeductions(forDriver: driverId).filter(\.isActive)
                if rules.isEmpty {
                    Text("No recurring deductions set up for this driver.")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                let outstanding = repo.ledger.outstandingAdvanceBalance(forDriver: driverId)
                if outstanding.isPositive {
                    Picker("Advance recovery", selection: $advancePolicy) {
                        Text("Don't recover now").tag(AdvanceRecoveryPolicy.manual)
                        Text("Recover in full").tag(AdvanceRecoveryPolicy.full)
                        Text("Recover an amount").tag(AdvanceRecoveryPolicy.fixedPerSettlement)
                    }
                    if advancePolicy == .fixedPerSettlement {
                        SettlementMoneyField(title: "Amount", amount: $advanceAmount)
                    }
                    LabeledContent("Outstanding advances", value: outstanding.formatted)
                }
            }
        } header: {
            Text("5 · Deductions & Advances")
        } footer: {
            Text("Everything added here can still be edited or removed on the review screen before approval. Advance balances only change when the settlement is approved.")
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if let preview {
            let r = preview.calculate()
            Section {
                SettlementAmountRow(title: "Gross Revenue", subtitle: "\(r.totalLoads) loads · \(SettlementFormat.miles(r.totalMiles))", amount: r.grossLoadRevenue)
                SettlementAmountRow(title: "Driver Earnings", subtitle: preview.settlement.effectivePayRule.summary, amount: r.driverBaseEarnings)
                ForEach(r.driverDeductionLines) { line in
                    SettlementAmountRow(title: line.label, subtitle: line.basis, amount: line.amount, style: .debit)
                }
                SettlementAmountRow(title: "Net Pay (before additions)", amount: r.netDriverPay)
                    .font(.headline)
            } header: {
                Text("6 · Preview")
            } footer: {
                if let number = preview.settlement.settlementNumber {
                    Text("Will be created as draft \(number).")
                }
            }
        }
    }

    // MARK: - Actions

    private func selectDefaults() {
        selectedLoadIds = Set(eligible.filter(\.isSelectedByDefault).map(\.id))
    }

    private func create() async {
        guard let bundle = preview else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await repo.save(bundle)
            let id = bundle.settlement.id ?? UUID()
            dismiss()
            onCreated(id)
        } catch {
            alert = SettlementAlert(error: error)
        }
    }
}

// MARK: - Load row

private struct LoadSelectionRow: View {
    let item: EligibleSettlementLoad
    let isSelected: Bool
    let paidOn: String?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(item.isSelectable ? Color.spGold : Color.spTextSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.load.loadNumber ?? "No load #")
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        if !item.isCompleted {
                            Text("IN PROGRESS")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.spWarning)
                        }
                    }
                    Text("\(item.load.origin ?? "—") → \(item.load.destination ?? "—")")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                        .lineLimit(1)
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(item.isSelectable ? Color.spTextSecondary : Color.spDanger)
                }
                Spacer()
                SettlementMoneyText(amount: Money(double: item.load.totalRevenue ?? 0))
            }
        }
        .buttonStyle(.plain)
        .disabled(!item.isSelectable)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var icon: String {
        if !item.isSelectable { return "nosign" }
        return isSelected ? "checkmark.circle.fill" : "circle"
    }

    private var note: String {
        if let paidOn { return "Already paid on \(paidOn)" }
        var bits: [String] = []
        if let p = item.load.pickupDate { bits.append("PU \(SettlementFormat.shortDate.string(from: p))") }
        if let b = item.load.brokerName, !b.isEmpty { bits.append(b) }
        if item.legacySettled { bits.append("marked settled in Paystub Maker") }
        return bits.joined(separator: " · ")
    }
}
