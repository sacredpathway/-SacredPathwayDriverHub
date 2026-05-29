import SwiftUI
import Combine

/// Primary Paystubs tab entry point.
///
/// Flow: pick a driver → pick a period → review the saved loads that
/// match → calculate → optionally export a PDF. Selecting a load
/// auto-fills its broker, route, miles, and revenue from what was already
/// logged in the Loads tab — drivers don't re-type anything.
///
/// On successful PDF export, every picked load is marked `settled` so it
/// won't show up in the next paystub by default. The user can flip the
/// "Show settled loads" toggle to intentionally re-include one.
struct SettlementGeneratorView: View {
    @EnvironmentObject var supabase: SupabaseService
    // Observed so the Export button switches between PDF and locked state
    // immediately after a Pro/Carrier purchase or restore — no relaunch.
    @ObservedObject private var subscriptions = SubscriptionService.shared

    // Drivers
    @State private var drivers: [Driver] = []
    @State private var selectedDriver: Driver?

    // Period
    @State private var periodStart = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var periodEnd = Date()

    // Loads
    @State private var allLoads: [Load] = []
    @State private var selectedLoadIds: Set<UUID> = []
    @State private var showSettledLoads: Bool = false
    @State private var isLoadingLoads = false

    // Calculation + export
    @State private var expenses: [Expense] = []
    @State private var calculation: SettlementCalculation?
    @State private var isCalculating = false
    @State private var pdfData: Data?
    @State private var showingShareSheet = false
    @State private var showingPreview = false
    @State private var errorMessage: String?
    @State private var showExportPaywall = false
    @State private var showDriverPrompt = false

    // Expense review (auto-pull from period + selected loads, with manual edits).
    @State private var matchResult: PaystubExpenseMatcher.MatchResult?
    @State private var showExpenseReview = false
    // Tracks the last expense set used for `calculation`. Lets us detect
    // newly-added/edited rows since the last Calculate tap and surface a
    // "REFRESHED" badge to the user.
    @State private var lastCalcExpenseFingerprint: String = ""
    @State private var hasFreshExpensesPending = false
    // True after the user has explicitly stepped through (or skipped) the
    // expense review for the current calculation. Resets when the calc
    // changes. Used to gate the export buttons.
    @State private var userConfirmedExpenseReview = false

    // Equipment fields (stamp on the PDF carrier meta line).
    @AppStorage("sph.lastTruckNumber")   private var truckNumber: String = ""
    @AppStorage("sph.lastTrailerNumber") private var trailerNumber: String = ""

    // MARK: - Derived

    /// Loads that match the current driver + period filter, filtered by
    /// settled state. Drives the picker rows.
    private var filteredLoads: [Load] {
        allLoads.filter { load in
            // Settled filter
            if !showSettledLoads, load.isSettled, !selectedLoadIds.contains(load.id ?? UUID()) {
                return false
            }
            // Driver filter — if a driver is picked, only show loads
            // already assigned to that driver OR unassigned (so the
            // user can attach an unassigned load to this paystub).
            if let driverId = selectedDriver?.id {
                if let loadDriver = load.driverId {
                    if loadDriver != driverId { return false }
                }
            }
            // Period filter — PICKUP DATE is the single source of truth
            // for which settlement period a load belongs to (spec
            // 2026-05-24). No delivery or createdAt fallback. Loads
            // without a pickup date are excluded from the period.
            guard let d = load.pickupDate else { return false }
            return d >= startOfDay(periodStart) && d <= endOfDay(periodEnd)
        }
    }

    private var selectedLoads: [Load] {
        allLoads.filter { load in
            guard let id = load.id else { return false }
            return selectedLoadIds.contains(id)
        }
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    periodSection
                    driverSection
                    equipmentSection
                    loadsPickerSection
                    calculateButton

                    if let calc = calculation {
                        if hasFreshExpensesPending {
                            freshExpensesBanner
                        }
                        if let result = matchResult {
                            expenseReviewBanner(result: result)
                        }
                        settlementPreview(calc)
                        exportButton
                    }

                    NavigationLink {
                        ManualPaystubView()
                            .environmentObject(supabase)
                    } label: {
                        HStack {
                            Image(systemName: "square.and.pencil")
                            Text("Or build a paystub manually")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .padding()
                        .background(Color.spCardBg)
                        .foregroundStyle(Color.spGold)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color.spDanger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Generate Paystub")
        .task {
            await loadDrivers()
            await loadLoads()
        }
        // Pull-to-refresh: re-pulls loads + recalculates if there's an
        // in-progress calculation, so brand-new fuel/lumper rows added in
        // the Expenses tab show up without leaving this screen.
        .refreshable {
            await refreshAll()
        }
        // Auto-react to Expense create/update/delete from anywhere in the
        // app. The matcher + calc re-run live; the user does not need to
        // tap Calculate again.
        .onReceive(NotificationCenter.default.publisher(for: .expensesDidChange)) { _ in
            Task { await refreshAfterExpenseChange() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .loadsDidChange)) { _ in
            Task { await loadLoads() }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let data = pdfData {
                ShareSheet(items: [data])
            }
        }
        .sheet(isPresented: $showingPreview) {
            if let data = pdfData {
                PDFPreviewView(data: data, title: "Settlement Preview")
            }
        }
        .alert("Pick a Driver", isPresented: $showDriverPrompt) {
            Button("OK") { }
        } message: {
            Text("These loads aren't assigned to anyone yet. Select a driver above so the paystub knows who's getting paid.")
        }
        .sheet(isPresented: $showExpenseReview) {
            if let result = matchResult {
                PaystubExpenseReviewView(
                    initialResult: result,
                    onRefresh: { await refreshAfterExpenseChange() },
                    liveContext: makeLiveContext()
                ) { updated in
                    matchResult = updated
                    expenses = updated.includedExpenses
                    userConfirmedExpenseReview = true
                    hasFreshExpensesPending = false
                    lastCalcExpenseFingerprint = expensesFingerprint(expenses)
                    // Re-run the engine with the curated list so the
                    // settlement preview + PDF reflect user edits.
                    if let profile = supabase.currentProfile {
                        let driver = selectedDriver
                            ?? Driver(profileId: profile.id, name: "Owner-Operator")
                        calculation = SettlementEngine.calculate(
                            loads: selectedLoads,
                            expenses: expenses,
                            profile: profile,
                            driver: driver,
                            customDeductions: customDeductions(for: selectedLoads)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Expense review entry point

    /// One-tap link to the dedicated PaystubExpenseReviewView so the user
    /// can uncheck/edit/manually-add expense lines before exporting the PDF.
    @ViewBuilder
    private func expenseReviewBanner(result: PaystubExpenseMatcher.MatchResult) -> some View {
        Button {
            showExpenseReview = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: userConfirmedExpenseReview
                      ? "checkmark.seal.fill"
                      : "list.bullet.rectangle.portrait")
                    .foregroundStyle(Color.spGold)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(userConfirmedExpenseReview
                         ? "Expenses reviewed"
                         : "Review expenses (required)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                    let included = result.lineItems.filter { $0.included }.count
                    Text("\(included) of \(result.lineItems.count) included · \(result.includedTotal.asCurrency)")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spGold)
            }
            .padding(14)
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(userConfirmedExpenseReview ? Color.spSuccess.opacity(0.6)
                                                       : Color.spGold.opacity(0.4),
                            lineWidth: 1)
            )
        }
    }

    /// Yellow banner shown when an Expense create/update/delete happens
    /// while a calculation is on-screen. Tells the user the preview was
    /// auto-refreshed and prompts them to re-confirm before exporting.
    private var freshExpensesBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.spWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Expenses updated — preview refreshed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text("Tap Review Expenses to confirm what's included before exporting.")
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.spWarning.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.spWarning.opacity(0.6), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Equipment (Truck / Trailer)

    private var equipmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Equipment", icon: "truck.box.fill")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Truck #").font(.caption).foregroundStyle(Color.spTextSecondary)
                    TextField("e.g. 2580", text: $truckNumber)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color.spBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trailer #").font(.caption).foregroundStyle(Color.spTextSecondary)
                    TextField("e.g. T-2418", text: $trailerNumber)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color.spBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
            }
            .padding()
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Period

    private var periodSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Settlement Period", icon: "calendar")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("From").font(.caption).foregroundStyle(Color.spTextSecondary)
                    DatePicker("", selection: $periodStart, displayedComponents: .date)
                        .labelsHidden().tint(Color.spGold)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("To").font(.caption).foregroundStyle(Color.spTextSecondary)
                    DatePicker("", selection: $periodEnd, displayedComponents: .date)
                        .labelsHidden().tint(Color.spGold)
                }
            }
            .padding().background(Color.spCardBg).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Driver

    private var driverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Driver", icon: "person.fill")
            if drivers.isEmpty {
                Text("No drivers added yet. Add drivers under More → Drivers.")
                    .font(.caption).foregroundStyle(Color.spTextSecondary)
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.spCardBg).clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(drivers) { driver in
                            Button {
                                selectedDriver = driver
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "person.circle.fill").font(.title2)
                                    Text(driver.name).font(.caption.weight(.semibold))
                                    if let pct = driver.payPercentage {
                                        Text("\(Int(pct))%").font(.caption2).foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                                .frame(width: 90, height: 80)
                                .background(selectedDriver?.id == driver.id ? Color.spGold.opacity(0.2) : Color.spCardBg)
                                .foregroundStyle(selectedDriver?.id == driver.id ? Color.spGold : Color.spTextPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(selectedDriver?.id == driver.id ? Color.spGold : .clear, lineWidth: 1.5)
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Loads picker

    private var loadsPickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Loads", icon: "shippingbox.fill")
                Spacer()
                Toggle(isOn: $showSettledLoads) {
                    Text("Show settled")
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary)
                }
                .toggleStyle(.switch)
                .tint(Color.spGold)
                .scaleEffect(0.85)
            }

            if isLoadingLoads {
                ProgressView().tint(Color.spGold)
                    .frame(maxWidth: .infinity).padding()
                    .background(Color.spCardBg).clipShape(RoundedRectangle(cornerRadius: 12))
            } else if filteredLoads.isEmpty {
                emptyLoadsCard
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            selectAllVisible()
                        } label: {
                            Text("Select all visible").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(Color.spGold)

                        Spacer()

                        if !selectedLoadIds.isEmpty {
                            Button {
                                selectedLoadIds.removeAll()
                            } label: {
                                Text("Clear (\(selectedLoadIds.count))")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(Color.spDanger.opacity(0.85))
                        }
                    }
                    .padding(.horizontal, 4)

                    ForEach(filteredLoads) { load in
                        loadRow(load)
                    }
                }
            }
        }
    }

    private var emptyLoadsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No loads match this period or driver.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
            Text("Adjust the date range, pick a different driver, or toggle 'Show settled' to include loads already paid out.")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func loadRow(_ load: Load) -> some View {
        let id = load.id ?? UUID()
        let isSelected = selectedLoadIds.contains(id)
        return Button {
            toggleLoad(id: id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.spGold : Color.spTextSecondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(load.loadNumber.map { "Load #\($0)" } ?? "Load")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.spTextPrimary)
                        if load.isSettled {
                            Text("SETTLED")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.spTextSecondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.spTextSecondary.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    if let broker = load.brokerName {
                        Text(broker).font(.caption).foregroundStyle(Color.spTextSecondary)
                    }
                    HStack(spacing: 4) {
                        if let origin = load.origin, let dest = load.destination {
                            Text("\(origin) → \(dest)")
                                .font(.caption2)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                        if let miles = load.totalMiles {
                            Text("· \(Int(miles)) mi")
                                .font(.caption2)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                    }
                }
                Spacer()
                if let revenue = load.totalRevenue {
                    Text(revenue.asCurrency)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.spGold)
                }
            }
            .padding(12)
            .background(isSelected ? Color.spGold.opacity(0.1) : Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.spGold : .clear, lineWidth: 1.5)
            )
        }
    }

    // MARK: - Calculate

    private var calculateButton: some View {
        Button {
            Task { await calculateSettlement() }
        } label: {
            HStack {
                if isCalculating { ProgressView().tint(Color.spBlack) }
                else { Image(systemName: "function") }
                Text(selectedLoadIds.isEmpty ? "Pick loads to calculate" : "Calculate Settlement (\(selectedLoadIds.count))")
            }
            .font(.headline)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(selectedLoadIds.isEmpty ? Color.spGold.opacity(0.4) : Color.spGold)
            .foregroundStyle(Color.spBlack)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isCalculating || selectedLoadIds.isEmpty)
    }

    private func settlementPreview(_ calc: SettlementCalculation) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("PAYSTUB PREVIEW").font(.caption.weight(.heavy)).foregroundStyle(Color.spGold)
                Spacer()
            }
            .padding(12).background(Color.spCardBg)

            VStack(spacing: 6) {
                calcRow("Gross Revenue", calc.totalRevenue.asCurrency, bold: true)
                calcRow("Expenses", "-\(calc.totalExpenses.asCurrency)", color: .spDanger)
                calcRow("Gross Profit", calc.grossProfit.asCurrency)
                Divider().background(Color.spTextSecondary.opacity(0.3))
                calcRow("Driver Pay (\(Int(calc.driverPayPercentage))%)", calc.driverPayAmount.asCurrency)
                calcRow("Dispatcher Fee", "-\(calc.dispatcherFeeAmount.asCurrency)", color: .spDanger)
                calcRow("Factoring Fee", "-\(calc.factoringFeeAmount.asCurrency)", color: .spDanger)
                calcRow("Authority Fee", "-\(calc.authorityFee.asCurrency)", color: .spDanger)
                calcRow("Maint. Reserve", "-\(calc.maintenanceReserve.asCurrency)", color: .spDanger)
                ForEach(calc.customDeductions) { deduction in
                    calcRow(deduction.name, "-\(deduction.amount.asCurrency)", color: .spDanger)
                }
                calcRow("Total Deductions", "-\(calc.totalDeductions.asCurrency)", bold: true, color: .spDanger)
                Divider().background(Color.spGold)
                calcRow("NET PAY", calc.carrierNetPay.asCurrency, bold: true, color: calc.carrierNetPay >= 0 ? .spSuccess : .spDanger)
            }
            .padding(12)
        }
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var exportButton: some View {
        Group {
            if subscriptions.isEntitled(.pdfExport) {
                // Mandatory review gate. The Export and Preview buttons
                // ALWAYS route through PaystubExpenseReviewView the first
                // time, and again any time expenses change underneath us.
                // After "Apply" they generate the PDF directly with the
                // confirmed, freshly-refetched expense set.
                let reviewRequired = !userConfirmedExpenseReview || hasFreshExpensesPending

                Button {
                    if reviewRequired {
                        showExpenseReview = true
                    } else {
                        Task { await generatePDF(showPreview: true) }
                    }
                } label: {
                    Label(reviewRequired ? "Review then Preview PDF" : "Preview PDF",
                          systemImage: reviewRequired ? "list.bullet.rectangle.portrait" : "eye.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.spGreenAccent).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    if reviewRequired {
                        showExpenseReview = true
                    } else {
                        Task { await generatePDF(showPreview: false) }
                    }
                } label: {
                    Label(reviewRequired ? "Review then Export PDF" : "Export Paystub PDF",
                          systemImage: reviewRequired ? "list.bullet.rectangle.portrait" : "square.and.arrow.up.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.spGreenAccent).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else {
                Button { showExportPaywall = true } label: {
                    HStack {
                        Image(systemName: "lock.fill")
                        Text("Export PDF")
                        Spacer()
                        Text("PRO")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.spGold.opacity(0.2))
                            .clipShape(Capsule())
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.spCardBgLight).foregroundStyle(Color.spGold)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .sheet(isPresented: $showExportPaywall) { PaywallView() }
            }
        }
    }

    private func calcRow(_ label: String, _ value: String, bold: Bool = false, color: Color = .spTextPrimary) -> some View {
        HStack {
            Text(label).font(bold ? .subheadline.weight(.bold) : .caption).foregroundStyle(Color.spTextSecondary)
            Spacer()
            Text(value).font(bold ? .subheadline.weight(.bold) : .caption.weight(.medium)).foregroundStyle(color)
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(Color.spGold)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.spTextPrimary)
        }
    }

    // MARK: - Date helpers

    private func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private func endOfDay(_ date: Date) -> Date {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        return cal.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }

    // MARK: - Actions

    private func loadDrivers() async {
        do { drivers = try await supabase.fetchDrivers() } catch { print("Error: \(error)") }
    }

    private func loadLoads() async {
        isLoadingLoads = true
        defer { isLoadingLoads = false }
        do {
            allLoads = try await supabase.fetchLoads()
        } catch {
            errorMessage = "Couldn't load saved loads: \(error.localizedDescription)"
        }
    }

    private func selectAllVisible() {
        for load in filteredLoads {
            if let id = load.id {
                selectedLoadIds.insert(id)
            }
        }
    }

    private func toggleLoad(id: UUID) {
        if selectedLoadIds.contains(id) {
            selectedLoadIds.remove(id)
        } else {
            selectedLoadIds.insert(id)
        }
    }

    private func calculateSettlement() async {
        isCalculating = true
        errorMessage = nil
        defer { isCalculating = false }

        do {
            let chosenLoads = selectedLoads
            guard !chosenLoads.isEmpty else {
                errorMessage = "Pick at least one load."
                return
            }

            // If none of the picked loads have a driver and the user
            // hasn't selected one, prompt rather than silently labeling
            // the paystub "Owner-Operator".
            let allUnassigned = chosenLoads.allSatisfy { $0.driverId == nil }
            if selectedDriver == nil && allUnassigned {
                showDriverPrompt = true
                return
            }

            // Auto-select driver from the loads if they all share one
            // and the user hasn't picked manually.
            if selectedDriver == nil {
                let driverIds = Set(chosenLoads.compactMap { $0.driverId })
                if driverIds.count == 1, let onlyId = driverIds.first {
                    selectedDriver = drivers.first { $0.id == onlyId }
                }
            }

            try await runMatchAndCalc(chosenLoads: chosenLoads)
            // A fresh Calculate resets the review-confirmation gate so
            // the user is explicitly walked through the expense list
            // before they can export.
            userConfirmedExpenseReview = false
            hasFreshExpensesPending = false
            lastCalcExpenseFingerprint = expensesFingerprint(expenses)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Single source of truth: fetch → match → calc

    /// Re-fetches expenses from Supabase, re-runs the matcher (preserving
    /// any prior user include/exclude/override + manual lines), and
    /// recomputes the SettlementCalculation. ALL paystub money math
    /// goes through this function — including the PDF path — so newly
    /// added or edited expenses can never get left behind.
    private func runMatchAndCalc(chosenLoads: [Load]) async throws {
        let allExpenses = try await supabase.fetchAllExpenses()
        let chosenLoadIds = Set(chosenLoads.compactMap { $0.id })

        // Preserve manual lines the user added in the review sheet.
        let priorManualLines = matchResult?.lineItems
            .filter { $0.isManualLine }
            .map { $0.expense } ?? []

        var newMatch = PaystubExpenseMatcher.match(
            allExpenses: allExpenses,
            selectedLoadIds: chosenLoadIds,
            periodStart: periodStart,
            periodEnd: periodEnd,
            manualLines: priorManualLines
        )

        // Re-apply previous user toggles + overrides if any.
        if let prior = matchResult {
            newMatch.lineItems = newMatch.lineItems.map { item in
                if let priorItem = prior.lineItems.first(where: { $0.id == item.id }) {
                    var copy = item
                    copy.included = priorItem.included
                    copy.overrideAmount = priorItem.overrideAmount
                    return copy
                }
                return item
            }
        }

        matchResult = newMatch
        expenses = newMatch.includedExpenses

        guard let profile = supabase.currentProfile else {
            errorMessage = "No profile loaded yet."
            return
        }
        let driver = selectedDriver ?? Driver(profileId: profile.id, name: "Owner-Operator")
        calculation = SettlementEngine.calculate(
            loads: chosenLoads,
            expenses: expenses,
            profile: profile,
            driver: driver,
            customDeductions: customDeductions(for: chosenLoads)
        )
    }

    /// Reload drivers + loads + (if a calc is in-flight) recompute. Used
    /// by pull-to-refresh.
    private func refreshAll() async {
        await loadDrivers()
        await loadLoads()
        if calculation != nil, !selectedLoads.isEmpty {
            try? await runMatchAndCalc(chosenLoads: selectedLoads)
        }
    }

    /// Called whenever a `Notification.Name.expensesDidChange` fires.
    /// Silently re-pulls expenses and re-runs the matcher so the in-progress
    /// paystub stays current, then sets `hasFreshExpensesPending` if the
    /// included-expense fingerprint changed since the last user-confirmed
    /// calculation — surfaced as a "REFRESHED" banner the user can see.
    private func refreshAfterExpenseChange() async {
        guard calculation != nil, !selectedLoads.isEmpty else { return }
        let before = lastCalcExpenseFingerprint
        try? await runMatchAndCalc(chosenLoads: selectedLoads)
        let after = expensesFingerprint(expenses)
        if before != after {
            hasFreshExpensesPending = true
            userConfirmedExpenseReview = false
        }
    }

    /// Builds the bundle the review sheet uses to compute a live net-pay
    /// preview as the user toggles include/exclude. Returns nil if we
    /// don't have enough state yet (no profile / no loads).
    private func makeLiveContext() -> PaystubExpenseReviewView.LiveContext? {
        guard let profile = supabase.currentProfile else { return nil }
        let chosen = selectedLoads
        guard !chosen.isEmpty else { return nil }
        let driver = selectedDriver ?? Driver(profileId: profile.id, name: "Owner-Operator")
        return PaystubExpenseReviewView.LiveContext(
            loads: chosen,
            profile: profile,
            driver: driver,
            customDeductions: customDeductions(for: chosen)
        )
    }

    private func customDeductions(for loads: [Load]) -> [SettlementCustomDeduction] {
        let grossPay = loads.reduce(0.0) { $0 + ($1.totalRevenue ?? 0) }
        return CustomFeeService.shared.activeCustomDeductions(grossPay: grossPay)
    }

    /// Deterministic fingerprint of the included expense set. Catches
    /// adds, deletes, amount edits, and category edits. Used by the
    /// "fresh expenses pending" banner.
    private func expensesFingerprint(_ list: [Expense]) -> String {
        list
            .map { e in
                let idStr = e.id?.uuidString ?? "manual"
                return "\(idStr):\(e.category):\(e.amount):\(e.loadId?.uuidString ?? "")"
            }
            .sorted()
            .joined(separator: "|")
    }

    private func generatePDF(showPreview: Bool = true) async {
        guard let profile = supabase.currentProfile else { return }

        // ALWAYS refetch right before rendering so the PDF reflects the
        // newest expenses — even if the user added a fuel receipt seconds
        // ago in another tab. This is the production-safe guarantee that
        // closes the "missing expense on paystub" bug class entirely.
        do {
            try await runMatchAndCalc(chosenLoads: selectedLoads)
            lastCalcExpenseFingerprint = expensesFingerprint(expenses)
            hasFreshExpensesPending = false
        } catch {
            errorMessage = "Couldn't refresh expenses before export: \(error.localizedDescription)"
            return
        }

        guard let calc = calculation else { return }
        let branding = BrandingService.shared
        do {
            let data = try await SettlementHTMLPDFService.generate(
                calculation: calc,
                loads: selectedLoads,
                expenses: expenses,
                companyName: profile.companyName ?? "Company",
                driverName: selectedDriver?.name ?? "Owner-Operator",
                periodStart: periodStart,
                periodEnd: periodEnd,
                logo: branding.logoImage,
                primaryColor: UIColor(branding.primaryColor),
                truckNumber: truckNumber.isEmpty ? nil : truckNumber,
                trailerNumber: trailerNumber.isEmpty ? nil : trailerNumber,
                mcNumber: profile.mcNumber,
                dotNumber: profile.dotNumber
            )
            pdfData = data
            if showPreview { showingPreview = true } else { showingShareSheet = true }

            // Mark every picked load as settled. This is the duplicate-
            // prevention mechanism — settled loads are filtered out of
            // future paystubs unless the user flips the "Show settled"
            // toggle and reselects intentionally.
            let ids = selectedLoads.compactMap { $0.id }
            try? await supabase.markLoadsAsSettled(loadIds: ids)
            await loadLoads() // refresh local copy so badges update

            // Save a copy of the paystub PDF to the Document Vault so
            // the user can re-download it later. Fire and forget — a
            // failure here shouldn't block the share sheet.
            let driverLabel = selectedDriver?.name ?? "Owner-Operator"
            let periodLabel = "\(formatDate(periodStart))–\(formatDate(periodEnd))"
            let title = "Paystub — \(driverLabel) — \(periodLabel)"
            Task {
                _ = try? await supabase.saveDocumentRecord(
                    pdfData: data,
                    documentType: "paystub",
                    title: title,
                    loadId: nil
                )
            }
        } catch {
            errorMessage = "PDF error: \(error.localizedDescription)"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yyyy"
        return f.string(from: date)
    }
}

// MARK: - Share Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
