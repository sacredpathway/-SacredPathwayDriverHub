import SwiftUI

// =============================================================================
//  Drivers & Pay — driver list, driver settlement profile, pay rule editor,
//  lease operator responsibilities
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). Driver-level pay is a DEFAULT: each settlement
//  copies it, so changing a rate never rewrites a past settlement.
// =============================================================================

struct SettlementDriversView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var repo = SettlementRepository.shared
    @State private var showingAdd = false
    @State private var showInactive = false

    private var list: [Driver] {
        showInactive ? repo.drivers : repo.activeDrivers
    }

    var body: some View {
        List {
            if list.isEmpty {
                SettlementEmptyState(title: "No drivers",
                                     message: "Add the drivers you pay so you can set their pay terms and build settlements.",
                                     systemImage: "person.2")
                    .listRowBackground(Color.clear)
            }
            ForEach(list, id: \.id) { driver in
                if let id = driver.id {
                    NavigationLink(value: SettlementRoute.driver(id)) {
                        DriverPayRow(driver: driver)
                    }
                    .listRowBackground(Color.spCardBg)
                }
            }
            if AppMode.shared.isLocal {
                Toggle("Show inactive drivers", isOn: $showInactive)
                    .listRowBackground(Color.spCardBg)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.spBackground)
        .navigationTitle("Drivers & Pay")
        .toolbar {
            if repo.viewer.can(.managePaySettings) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("Add Driver")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddSettlementDriverView { _ in }
                .environmentObject(supabase)
        }
    }
}

private struct DriverPayRow: View {
    let driver: Driver
    @ObservedObject private var repo = SettlementRepository.shared

    var body: some View {
        let settings = repo.paySettings(for: driver)
        let outstanding = driver.id.map { repo.ledger.outstandingAdvanceBalance(forDriver: $0) } ?? .zero
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(driver.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                if driver.active == false {
                    Text("INACTIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.spTextSecondary)
                }
                Spacer()
                Text(settings.settlementType.displayName)
                    .font(.caption)
                    .foregroundStyle(Color.spGold)
            }
            Text(settings.payRule.summary)
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
            HStack(spacing: 10) {
                if let truck = driver.truckNumber, !truck.isEmpty {
                    Label(truck, systemImage: "truck.box")
                }
                if outstanding.isPositive {
                    Label("\(outstanding.formatted) advanced", systemImage: "banknote")
                        .foregroundStyle(Color.spWarning)
                }
            }
            .font(.caption2)
            .foregroundStyle(Color.spTextSecondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Driver profile

struct DriverPayProfileView: View {
    let driverId: UUID

    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var repo = SettlementRepository.shared
    @ObservedObject private var payWeek = PayWeekService.shared
    @State private var editing: DriverPaySettings?
    @State private var alert: SettlementAlert?
    @State private var isSaving = false

    private var driver: Driver? { repo.driver(id: driverId) }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            if let driver {
                content(driver)
            } else {
                SettlementEmptyState(title: "Driver not found",
                                     message: "This driver may have been removed. Their settlement history is kept.")
            }
        }
        .navigationTitle(driver?.name ?? "Driver")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(
            get: { editing.map { EditingPay(settings: $0) } },
            set: { editing = $0?.settings })
        ) { item in
            payEditorSheet(item.settings)
        }
        .alert(item: $alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }

    private struct EditingPay: Identifiable {
        let settings: DriverPaySettings
        var id: UUID { settings.id }
    }

    private func content(_ driver: Driver) -> some View {
        let settings = repo.paySettings(for: driver)
        let history = SettlementInsights.filter(repo.ledger, SettlementHistoryFilter(driverId: driverId))
        let last = SettlementInsights.lastSettlement(repo.ledger, driverId: driverId)
        let year = Calendar.current.component(.year, from: Date())
        let ytd = SettlementInsights.ytd(repo.ledger, driverId: driverId, year: year)
        let week = SettlementDateRange.preset(.thisWeek, firstWeekday: payWeek.firstWeekday)
        let estimate = repo.estimate(for: driver, range: week)?.calculate()
        let recurring = repo.ledger.recurringDeductions(forDriver: driverId)
        let outstanding = repo.ledger.outstandingAdvanceBalance(forDriver: driverId)

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettlementCard(title: "Pay") {
                    row("Pay type", settings.settlementType.displayName)
                    row("Pay rate", settings.payRule.summary)
                    row("Percent basis", settings.payOnGrossRevenue ? "Gross revenue" : "Net after company costs")
                    row("Assigned truck", driver.truckNumber ?? "—")
                    if settings.settlementType == .leaseOperator || settings.leaseConfig != nil {
                        let rules = settings.leaseConfig?.rules ?? []
                        row("Responsibility rules", rules.isEmpty ? "Type defaults" : "\(rules.count) custom")
                    }
                    if repo.viewer.can(.managePaySettings) {
                        Button {
                            editing = settings
                        } label: {
                            Label("Edit Pay Terms", systemImage: "slider.horizontal.3")
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.top, 4)
                    }
                }

                if let estimate {
                    NavigationLink(value: SettlementRoute.estimate(driverId: driverId)) {
                        SettlementNetPayHero(amount: estimate.netDriverPay, isEstimate: true,
                                             caption: "This week so far · \(estimate.totalLoads) loads · tap for detail")
                    }
                    .buttonStyle(.plain)
                }

                SettlementCard(title: "Recurring Deductions", trailing: "\(recurring.filter(\.isActive).count) active") {
                    if recurring.isEmpty {
                        Text("None").font(.subheadline).foregroundStyle(Color.spTextSecondary)
                    }
                    ForEach(recurring) { rule in
                        SettlementAmountRow(
                            title: rule.descriptionText,
                            subtitle: "\(rule.frequency.displayName)\(rule.isActive ? "" : " · paused")",
                            amount: rule.isPercentBased ? .zero : rule.amount,
                            style: .debit)
                            .opacity(rule.isActive ? 1 : 0.5)
                    }
                    NavigationLink(value: SettlementRoute.recurring(driverId: driverId)) {
                        Label("Manage", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                    }
                }

                SettlementCard(title: "Advances", trailing: "\(outstanding.formatted) outstanding") {
                    ForEach(repo.ledger.advances(forDriver: driverId).prefix(5)) { a in
                        SettlementAmountRow(
                            title: a.descriptionText,
                            subtitle: "\(SettlementFormat.date(a.date)) · \(a.outstandingBalance.formatted) left of \(a.amount.formatted)",
                            amount: a.outstandingBalance)
                    }
                    NavigationLink(value: SettlementRoute.advances(driverId: driverId)) {
                        Label("Manage Advances", systemImage: "banknote")
                            .font(.subheadline.weight(.semibold))
                    }
                }

                SettlementCard(title: "Year to Date \(String(year))") {
                    if let ytd {
                        SettlementAmountRow(title: "Earnings", amount: ytd.driverEarnings)
                        SettlementAmountRow(title: "Additions", amount: ytd.additions, style: .credit)
                        SettlementAmountRow(title: "Deductions", amount: ytd.deductions, style: .debit)
                        SettlementAmountRow(title: "Net Paid", subtitle: "\(ytd.settlementCount) paid settlements", amount: ytd.netPay)
                    } else {
                        Text("No paid settlements this year yet.")
                            .font(.subheadline)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                }

                SettlementCard(title: "Settlement History", trailing: "\(history.count)") {
                    if let last {
                        row("Last settlement", "\(last.displayNumber) · \(last.settlementStatus.displayName)")
                    }
                    ForEach(history.prefix(12), id: \.id) { s in
                        if let id = s.id {
                            NavigationLink(value: SettlementRoute.settlement(id)) {
                                SettlementHistoryRow(settlement: s, driverName: driver.name)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if history.isEmpty {
                        Text("No settlements yet.")
                            .font(.subheadline)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                }

                if AppMode.shared.isLocal && repo.viewer.can(.managePaySettings) {
                    Button(role: driver.active == false ? nil : .destructive) {
                        Task {
                            try? await repo.setDriverActive(driver, active: driver.active == false)
                        }
                    } label: {
                        Label(driver.active == false ? "Reactivate Driver" : "Mark Driver Inactive",
                              systemImage: "person.crop.circle.badge.xmark")
                    }
                    Text("Drivers are never deleted — their settlement history stays intact.")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
            }
            .padding()
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func payEditorSheet(_ initial: DriverPaySettings) -> some View {
        PayTermsSheet(initial: initial, driverName: driver?.name ?? "Driver") { updated in
            guard let driver else { return }
            Task {
                do {
                    try await repo.savePaySettings(updated, for: driver)
                } catch {
                    alert = SettlementAlert(error: error)
                }
            }
        }
    }
}

// MARK: - Pay terms sheet

struct PayTermsSheet: View {
    let initial: DriverPaySettings
    let driverName: String
    let onSave: (DriverPaySettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var repo = SettlementRepository.shared
    @State private var settings: DriverPaySettings

    init(initial: DriverPaySettings, driverName: String, onSave: @escaping (DriverPaySettings) -> Void) {
        self.initial = initial
        self.driverName = driverName
        self.onSave = onSave
        _settings = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                PayRuleEditor(settings: $settings, maximumPercent: repo.maximumDriverPercent,
                              showsResponsibilities: true)
                Section {
                    TextField("Truck / unit number", text: Binding(
                        get: { settings.defaultTruckNumber ?? "" },
                        set: { settings.defaultTruckNumber = $0.isEmpty ? nil : $0 }))
                } header: {
                    Text("Assigned Truck")
                }
            }
            .navigationTitle(driverName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(settings)
                        dismiss()
                    }
                    .bold()
                    .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        SettlementWorkflowService.payRuleProblem(settings.payRule, maximumPercent: repo.maximumDriverPercent) == nil
    }
}

// MARK: - Pay rule editor

/// Edits a `DriverPaySettings` inside a Form. Used for driver defaults, the
/// per-settlement override and the per-load override.
struct PayRuleEditor: View {
    @Binding var settings: DriverPaySettings
    let maximumPercent: Decimal
    var showsResponsibilities: Bool = true
    var perLoadOnly: Bool = false

    private var availableKinds: [PayMethodKind] {
        perLoadOnly ? PayMethodKind.allCases.filter(\.isPerLoad) : PayMethodKind.allCases
    }

    var body: some View {
        if !perLoadOnly {
            Section {
                Picker("Settlement type", selection: $settings.settlementType) {
                    ForEach(SettlementType.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: settings.settlementType) { _, newType in
                    if newType == .leaseOperator && settings.leaseConfig == nil {
                        settings.leaseConfig = LeaseOperatorConfig()
                    }
                }
                Toggle("Percentages pay on gross revenue", isOn: $settings.payOnGrossRevenue)
            } header: {
                Text("Pay Type")
            } footer: {
                Text(settings.payOnGrossRevenue
                     ? "Percent pay is calculated on each load's gross rate."
                     : "Percent pay is calculated on revenue after company-paid costs, then shared across loads.")
            }
        }

        Section {
            ForEach($settings.payRule.components) { $component in
                PayComponentEditor(component: $component, maximumPercent: maximumPercent,
                                   kinds: availableKinds)
            }
            .onDelete { offsets in
                settings.payRule.components.remove(atOffsets: offsets)
            }
            Menu {
                ForEach(availableKinds) { kind in
                    Button(kind.displayName) {
                        settings.payRule.components.append(PayComponent(kind: kind, percent: kind == .percentOfGross ? 70 : nil))
                    }
                }
            } label: {
                Label(settings.payRule.components.isEmpty ? "Add Pay Method" : "Add Another (combination pay)",
                      systemImage: "plus.circle")
            }
            if settings.payRule.components.isEmpty {
                Text("No pay method — earnings will be $0.00 until one is added.")
                    .font(.caption)
                    .foregroundStyle(Color.spWarning)
            }
        } header: {
            Text("Pay Methods")
        } footer: {
            Text("Summary: \(settings.payRule.summary)")
        }

        if showsResponsibilities && !perLoadOnly {
            LeaseResponsibilityEditor(settings: $settings)
        }
    }
}

private struct PayComponentEditor: View {
    @Binding var component: PayComponent
    let maximumPercent: Decimal
    let kinds: [PayMethodKind]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Method", selection: $component.kind) {
                ForEach(kinds) { Text($0.displayName).tag($0) }
            }
            .onChange(of: component.kind) { _, newKind in
                component.label = newKind.displayName
            }
            switch component.kind {
            case .percentOfGross:
                SettlementDecimalField(title: "Driver percent", value: Binding(
                    get: { component.percent ?? 0 },
                    set: { component.percent = $0 }), suffix: "%")
                if let p = component.percent, p > maximumPercent || p < 0 {
                    Text("Must be between 0% and \(maximumPercent.asPercentString).")
                        .font(.caption)
                        .foregroundStyle(Color.spDanger)
                }
            case .flatPerLoad:
                SettlementMoneyField(title: "Per load", amount: rateBinding)
            case .perMile:
                SettlementMoneyField(title: "Rate per mile", amount: rateBinding)
                Picker("Miles", selection: $component.mileBasis) {
                    ForEach(MileBasis.allCases) { Text($0.displayName).tag($0) }
                }
            case .weeklySalary:
                SettlementMoneyField(title: "Weekly salary", amount: rateBinding)
            case .hourly:
                SettlementMoneyField(title: "Hourly rate", amount: rateBinding)
                SettlementDecimalField(title: "Default hours", value: Binding(
                    get: { component.hours ?? 0 },
                    set: { component.hours = $0 == 0 ? nil : $0 }), suffix: "hrs")
                Text("Leave hours at 0 to enter them on each settlement.")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            case .manual:
                SettlementMoneyField(title: "Amount", amount: Binding(
                    get: { component.fixedAmount ?? .zero },
                    set: { component.fixedAmount = $0 }))
            }
        }
        .padding(.vertical, 4)
    }

    private var rateBinding: Binding<Money> {
        Binding(get: { component.rate ?? .zero }, set: { component.rate = $0 })
    }
}

// MARK: - Lease operator responsibilities

struct LeaseResponsibilityEditor: View {
    @Binding var settings: DriverPaySettings

    /// Categories worth configuring per driver.
    private let categories: [SettlementDeductionCategory] = [
        .truckLease, .insurance, .fuel, .maintenance, .repair, .tolls, .permits,
        .escrow, .maintenanceReserve, .trailerCharge, .equipmentCharge,
        .scaleTickets, .damage, .violation, .dispatcherFee, .factoringFee, .authorityFee
    ]

    var body: some View {
        Section {
            if settings.settlementType == .leaseOperator, let config = settings.leaseConfig {
                SettlementDecimalField(title: "Driver share of gross", value: Binding(
                    get: { config.driverGrossPercent },
                    set: { settings.leaseConfig?.driverGrossPercent = $0 }), suffix: "%")
                SettlementDecimalField(title: "Company share of gross", value: Binding(
                    get: { config.companyGrossPercent },
                    set: { settings.leaseConfig?.companyGrossPercent = $0 }), suffix: "%")
                if !config.splitsToWholePercent {
                    Text("Shares don't add up to 100% — check the agreement.")
                        .font(.caption)
                        .foregroundStyle(Color.spWarning)
                }
                Button("Use driver share as pay rate") {
                    settings.payRule.components = [PayComponent(kind: .percentOfGross,
                                                                percent: config.driverGrossPercent)]
                }
            }
            ForEach(categories) { category in
                responsibilityRow(category)
            }
        } header: {
            Text("Who Pays What")
        } footer: {
            Text("Defaults come from the settlement type. Anything you change here is saved as this driver's agreement and applied to every new deduction line.")
        }
    }

    private func responsibilityRow(_ category: SettlementDeductionCategory) -> some View {
        let current = settings.responsibility(for: category)
        return VStack(alignment: .leading, spacing: 4) {
            Picker(category.displayName, selection: Binding(
                get: { current.0 },
                set: { set(category, responsibility: $0, share: current.0 == .split ? current.1 : 50) })
            ) {
                Text("Driver").tag(DeductionResponsibility.driver)
                Text("Company").tag(DeductionResponsibility.company)
                if !category.isCompanyFee && category != .maintenanceReserve {
                    Text("Split").tag(DeductionResponsibility.split)
                }
            }
            if current.0 == .split {
                SettlementDecimalField(title: "Driver pays", value: Binding(
                    get: { current.1 },
                    set: { set(category, responsibility: .split, share: $0) }), suffix: "%")
            }
        }
    }

    private func set(_ category: SettlementDeductionCategory,
                     responsibility: DeductionResponsibility,
                     share: Decimal) {
        var config = settings.leaseConfig ?? LeaseOperatorConfig(
            driverGrossPercent: 0, companyGrossPercent: 0, rules: [])
        config.rules.removeAll { $0.category == category }
        let pct: Decimal
        switch responsibility {
        case .driver:  pct = 100
        case .company: pct = 0
        case .split:   pct = share
        }
        config.rules.append(ResponsibilityRule(category: category, responsibility: responsibility,
                                               driverSharePercent: pct))
        settings.leaseConfig = config
    }
}

// MARK: - Add driver

struct AddSettlementDriverView: View {
    let onCreated: (Driver) -> Void

    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var repo = SettlementRepository.shared
    @ObservedObject private var subscriptions = SubscriptionService.shared
    @State private var name = ""
    @State private var truck = ""
    @State private var settings = DriverPaySettings(profileId: UUID(), driverId: UUID(),
                                                    payRule: .percentOfGross(70))
    @State private var isSaving = false
    @State private var alert: SettlementAlert?
    @State private var showingPaywall = false

    /// Mirrors DriversListView: more than one driver needs the Carrier tier
    /// in Cloud Pro. Free Local Mode keeps its own on-device list.
    private var canAddMore: Bool {
        AppMode.shared.isLocal
            || subscriptions.isEntitled(.multiDriver)
            || repo.drivers.count < 1
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Driver") {
                    TextField("Full name", text: $name)
                        .textContentType(.name)
                    TextField("Truck / unit number", text: $truck)
                }
                PayRuleEditor(settings: $settings, maximumPercent: repo.maximumDriverPercent,
                              showsResponsibilities: settings.settlementType == .leaseOperator)
                if let payProblem {
                    Section {
                        Text(payProblem)
                            .font(.caption)
                            .foregroundStyle(Color.spDanger)
                    }
                }
            }
            .navigationTitle("Add Driver")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if canAddMore {
                            Task { await save() }
                        } else {
                            showingPaywall = true
                        }
                    } label: {
                        if isSaving { ProgressView() } else { Text("Add").bold() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving || payProblem != nil)
                }
            }
            .alert(item: $alert) { a in
                Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
            }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
        }
    }

    private var payProblem: String? {
        SettlementWorkflowService.payRuleProblem(settings.payRule, maximumPercent: repo.maximumDriverPercent)
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            repo.attach(supabase)
            var s = settings
            s.defaultTruckNumber = truck.isEmpty ? nil : truck
            let created = try await repo.addDriver(name: name, truckNumber: truck, settings: s)
            onCreated(created)
            dismiss()
        } catch {
            alert = SettlementAlert(error: error)
        }
    }
}
