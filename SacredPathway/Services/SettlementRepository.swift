import Foundation
import Combine

// =============================================================================
//  SettlementRepository — the one object the Settlements screens talk to
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). Routes every read and write to the Free Local
//  Mode file store or the Supabase tables based on `AppMode`, runs all rules
//  through `SettlementWorkflowService`, and publishes the resulting ledger.
//
//  Write discipline: every change is applied to a COPY of the ledger, the copy
//  is persisted, and only then is it published. A failed write therefore never
//  shows the user figures that were not saved.
// =============================================================================

extension Notification.Name {
    static let settlementsDidChange = Notification.Name("sph.settlementsDidChange")
}

@MainActor
final class SettlementRepository: ObservableObject {

    static let shared = SettlementRepository()

    @Published private(set) var ledger: SettlementLedger = .empty
    @Published private(set) var cloudDrivers: [Driver] = []
    @Published private(set) var portalContexts: [DriverPortalContext] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published var lastError: String?

    private var localStore: SettlementLocalStore?
    private var cloudStore: SettlementCloudStore?
    private weak var supabase: SupabaseService?
    /// Who the published data belongs to ("local:<install>" / "cloud:<user>").
    /// When it changes (sign-out → sign-in as someone else, or a mode switch)
    /// everything is cleared BEFORE the next fetch, so one account never sees
    /// another account's settlements, even if that fetch fails.
    private var loadedIdentity: String?
    private var loadingIdentity: String?

    /// Carrier setting: may linked drivers see a live estimate?
    @Published var driversMaySeeEstimates: Bool {
        didSet { UserDefaults.standard.set(driversMaySeeEstimates, forKey: Self.estimateKey) }
    }
    /// Company-set maximum for a percentage pay rule (validation cap).
    @Published var maximumDriverPercent: Decimal = 100
    /// Prefix for new settlement numbers.
    @Published var numberPrefix: String {
        didSet { UserDefaults.standard.set(numberPrefix, forKey: Self.prefixKey) }
    }

    private static let estimateKey = "sph.settlements.driversSeeEstimates.v1"
    private static let prefixKey = "sph.settlements.numberPrefix.v1"

    private init() {
        driversMaySeeEstimates = UserDefaults.standard.bool(forKey: Self.estimateKey)
        numberPrefix = UserDefaults.standard.string(forKey: Self.prefixKey)
            ?? SettlementNumberService.defaultPrefix
    }

    // MARK: - Context

    var isLocal: Bool { AppMode.shared.isLocal }

    func attach(_ supabase: SupabaseService) {
        if self.supabase !== supabase {
            self.supabase = supabase
            cloudStore = SettlementCloudStore(client: supabase.client)
        }
        resetIfAccountChanged()
    }

    private var currentIdentity: String {
        if isLocal { return "local:\(AppMode.shared.localInstallId.uuidString)" }
        return "cloud:\(supabase?.client.auth.currentUser?.id.uuidString ?? "signed-out")"
    }

    /// Clears all published data when the signed-in account or mode changed.
    func resetIfAccountChanged() {
        let identity = currentIdentity
        guard identity != loadedIdentity else { return }
        if loadedIdentity != nil {
            ledger = .empty
            cloudDrivers = []
            portalContexts = []
            hasLoaded = false
            lastError = nil
        }
        loadedIdentity = identity
    }

    var profileId: UUID? {
        if isLocal { return AppMode.shared.localInstallId }
        return supabase?.currentProfile?.id ?? supabase?.client.auth.currentUser?.id
    }

    var role: SettlementRole {
        SettlementRole.resolve(
            accountRole: supabase?.currentProfile?.accountRole,
            isLocalMode: isLocal)
    }

    var viewer: SettlementViewer {
        SettlementViewer(
            role: role,
            userId: supabase?.client.auth.currentUser?.id,
            linkedDriverIds: Set(portalContexts.map(\.linkedDriverId)),
            driversMaySeeEstimates: driversMaySeeEstimates)
    }

    var actor: SettlementActor {
        if isLocal {
            return SettlementActor(userId: AppMode.shared.localInstallId, name: "This iPhone")
        }
        let user = supabase?.client.auth.currentUser
        return SettlementActor(userId: user?.id,
                               name: supabase?.currentProfile?.companyName ?? user?.email)
    }

    var company: SettlementCompanyInfo {
        if !isLocal, role == .driver, let ctx = portalContexts.first {
            return SettlementCompanyInfo(name: ctx.companyName ?? "Your Carrier",
                                         mcNumber: ctx.mcNumber, dotNumber: ctx.dotNumber,
                                         phone: ctx.phone)
        }
        let p = supabase?.currentProfile
        return SettlementCompanyInfo(
            name: (p?.companyName?.isEmpty == false ? p?.companyName : nil) ?? "Sacred Pathway LLC",
            mcNumber: p?.mcNumber,
            dotNumber: p?.dotNumber,
            phone: p?.phone,
            email: isLocal ? nil : supabase?.client.auth.currentUser?.email)
    }

    /// Company fee defaults from Settings → Fees (profile row).
    var companyFees: CompanyFeeSettings {
        SettlementWorkflowService.companyFees(from: supabase?.currentProfile)
    }

    // MARK: - Drivers

    var drivers: [Driver] {
        let list = isLocal ? ledger.localDrivers : cloudDrivers
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var activeDrivers: [Driver] { drivers.filter { $0.active != false } }

    var driverNames: [UUID: String] {
        var names: [UUID: String] = [:]
        for d in drivers { if let id = d.id { names[id] = d.name } }
        for c in portalContexts { names[c.linkedDriverId] = c.driverName ?? names[c.linkedDriverId] }
        return names
    }

    func driver(id: UUID?) -> Driver? {
        guard let id else { return nil }
        return drivers.first { $0.id == id }
    }

    func driverName(_ id: UUID?) -> String {
        guard let id else { return "No driver" }
        return driverNames[id] ?? "Former driver"
    }

    func paySettings(for driver: Driver) -> DriverPaySettings {
        // Legacy profiles store "pay on profit" vs "pay on revenue"; honour it
        // for drivers who have never had a settlement pay rule saved.
        let legacyGross = (supabase?.currentProfile?.payBasis ?? "").lowercased() != "profit"
        return driver.paySettings(legacyPayOnGrossRevenue: legacyGross)
    }

    // MARK: - Loading

    func reload() async {
        resetIfAccountChanged()
        let identity = currentIdentity
        guard !isLoading || loadingIdentity != identity else { return }
        isLoading = true
        loadingIdentity = identity
        // Results are published only if the account is still the same when
        // the fetch returns; a slow fetch for a previous account is dropped.
        func stillCurrent() -> Bool { currentIdentity == identity }
        defer {
            if loadingIdentity == identity {
                isLoading = false
                loadingIdentity = nil
                if stillCurrent() { hasLoaded = true }
            }
        }
        do {
            if isLocal {
                if localStore == nil { localStore = try SettlementLocalStore.appDefault() }
                let loaded = try localStore!.load()
                guard stillCurrent() else { return }
                ledger = loaded
                cloudDrivers = []
                portalContexts = []
            } else if let cloudStore {
                if supabase?.currentProfile?.accountRole == .driver {
                    let contexts = (try? await cloudStore.fetchDriverPortalContext()) ?? []
                    let driverLedger = try await cloudStore.fetchDriverLedger(
                        linkedDriverIds: Set(contexts.map(\.linkedDriverId)))
                    guard stillCurrent() else { return }
                    portalContexts = contexts
                    ledger = driverLedger
                    cloudDrivers = []
                } else {
                    async let fetchedLedger = cloudStore.fetchLedger()
                    async let fetchedDrivers = cloudStore.fetchDrivers()
                    let full = try await fetchedLedger
                    let drivers = (try? await fetchedDrivers) ?? []
                    guard stillCurrent() else { return }
                    ledger = full
                    cloudDrivers = drivers
                    portalContexts = []
                }
            }
            lastError = nil
        } catch {
            if stillCurrent() { lastError = error.localizedDescription }
        }
    }

    // MARK: - Operational data

    var loads: [Load] { LoadsSyncService.shared.loads }

    func expenses() async -> [Expense] {
        if isLocal { return LocalExpensesRepository.shared.expenses }
        return (try? await supabase?.fetchAllExpenses()) ?? []
    }

    // MARK: - Drafts

    func newDraft(
        driver: Driver,
        periodStart: Date,
        periodEnd: Date,
        loads: [Load],
        applyRecurring: Bool,
        advancePolicy: AdvanceRecoveryPolicy,
        advanceAmount: Money?,
        hoursWorked: Decimal?,
        paySettingsOverride: DriverPaySettings? = nil
    ) throws -> SettlementBundle {
        guard viewer.can(.createDraft) else {
            throw SettlementWorkflowError.notPermitted("Your role can't create settlements.")
        }
        guard let profileId else { throw SettlementCloudError.notSignedIn }
        let options = SettlementDraftOptions(
            profileId: profileId,
            driver: driver,
            paySettings: paySettingsOverride ?? paySettings(for: driver),
            periodStart: periodStart,
            periodEnd: periodEnd,
            companyFees: companyFees,
            applyRecurringDeductions: applyRecurring,
            advancePolicy: advancePolicy,
            advanceRecoveryAmount: advanceAmount,
            numberPrefix: numberPrefix,
            hoursWorked: hoursWorked,
            actor: actor)
        return SettlementWorkflowService.makeDraft(options: options, loads: loads, ledger: ledger)
    }

    func estimate(for driver: Driver, range: SettlementDateRange) -> SettlementBundle? {
        guard let profileId else { return nil }
        return SettlementInsights.estimate(
            driver: driver, paySettings: paySettings(for: driver),
            profileId: profileId, loads: loads, ledger: ledger, range: range,
            companyFees: companyFees,
            includeUnassigned: isLocal && activeDrivers.count <= 1)
    }

    /// Validates without saving — used live by the review screen.
    func issues(for bundle: SettlementBundle) -> [SettlementValidationIssue] {
        SettlementWorkflowService.validate(
            bundle, ledger: ledger,
            driverExists: driver(id: bundle.settlement.driverId) != nil || role == .driver,
            driverName: driverName(bundle.settlement.driverId),
            maximumDriverPercent: maximumDriverPercent)
    }

    func save(_ bundle: SettlementBundle) async throws {
        guard SettlementPermissions.canEdit(bundle.settlement, viewer: viewer)
                || (ledger.settlement(id: bundle.id) == nil && viewer.can(.createDraft)) else {
            throw SettlementWorkflowError.notPermitted("Your role can't edit this settlement.")
        }
        guard !bundle.settlement.isEstimateRecord else {
            throw SettlementWorkflowError.blocked("Estimates are not saved.")
        }
        if !isLocal, let cloudStore {
            // Validate against the server's latest ledger (numbers, loads
            // already paid elsewhere, advance balances). The edited
            // settlement itself is still saved last-write-wins.
            ledger = try await cloudStore.fetchLedger()
        }
        var copy = ledger
        let previous = ledger.bundle(for: bundle.id)
        let events = try SettlementWorkflowService.save(bundle, into: &copy, actor: actor)
        guard let saved = copy.bundle(for: bundle.id) else { throw SettlementWorkflowError.notFound }
        try await persist(copy) { store in
            try await store.saveBundle(saved, auditEvents: events)
        }
        // Balances moved back if an approved settlement was edited.
        if !isLocal, let cloudStore {
            let before = Set(ledger.advanceRepayments.filter { $0.settlementId == bundle.id }.map(\.id))
            if !before.isEmpty && copy.advanceRepayments.filter({ $0.settlementId == bundle.id }).isEmpty {
                let touched = Set(ledger.advanceRepayments.filter { before.contains($0.id) }.map(\.advanceId))
                try await cloudStore.applyTransition(SettlementTransitionOutcome(
                    settlement: saved.settlement, auditEvents: [],
                    repaymentsAdded: [], repaymentIdsRemoved: Array(before),
                    advancesTouched: copy.advances.filter { touched.contains($0.id) },
                    loadIdsToMarkSettled: [], loadIdsToRelease: []))
            }
        }
        ledger = copy
        // An approved settlement edited back to draft no longer pays its
        // loads until it is approved again: clear their "settled" flag
        // (approval sets it again for the loads still on it).
        if let previous, previous.settlement.settlementStatus == .approved,
           saved.settlement.settlementStatus != .approved {
            await updateLoadStatuses(settled: [], released: previous.loadLines.compactMap(\.loadId))
        }
        NotificationCenter.default.post(name: .settlementsDidChange, object: nil)
    }

    func transition(
        _ settlementId: UUID,
        to target: SettlementStatus,
        reason: String? = nil,
        paymentReference: String? = nil,
        paymentMethod: String? = nil
    ) async throws {
        guard let current = ledger.settlement(id: settlementId) else {
            throw SettlementWorkflowError.notFound
        }
        guard SettlementPermissions.canTransition(viewer, from: current.settlementStatus, to: target) else {
            throw SettlementWorkflowError.notPermitted("Your role can't move a settlement to \(target.displayName).")
        }
        if !isLocal, let cloudStore {
            ledger = try await cloudStore.fetchLedger()
        }
        var copy = ledger
        let outcome = try SettlementWorkflowService.transition(
            settlementId: settlementId, to: target, ledger: &copy, actor: actor,
            reason: reason, paymentReference: paymentReference, paymentMethod: paymentMethod,
            driverExists: driver(id: current.driverId) != nil,
            maximumDriverPercent: maximumDriverPercent,
            numberPrefix: numberPrefix)
        try await persist(copy) { store in
            try await store.applyTransition(outcome)
        }
        ledger = copy
        await updateLoadStatuses(settled: outcome.loadIdsToMarkSettled,
                                 released: outcome.loadIdsToRelease)
        NotificationCenter.default.post(name: .settlementsDidChange, object: nil)
    }

    /// Flags loads `settled` so the legacy Paystub Maker hides them too, and
    /// releases them when a settlement is voided or reopened. Best effort —
    /// the settlement ledger (not this flag) is what blocks double pay.
    private func updateLoadStatuses(settled: [UUID], released: [UUID]) async {
        guard !settled.isEmpty || !released.isEmpty else { return }
        if isLocal {
            let repo = LocalLoadsRepository.shared
            for id in settled {
                if var load = repo.find(id: id) {
                    load.status = LoadStatus.settled.rawValue
                    repo.update(load)
                }
            }
            for id in released {
                if var load = repo.find(id: id), load.loadStatus == .settled {
                    load.status = LoadStatus.readyForSettlement.rawValue
                    repo.update(load)
                }
            }
            NotificationCenter.default.post(name: .loadsDidChange, object: nil)
        } else if let supabase {
            try? await supabase.markLoadsAsSettled(loadIds: settled)
            // Not markLoadsAsUnsettled: that sets "assigned", which hides a
            // load with no delivery date from the next settlement.
            try? await cloudStore?.releaseSettledLoads(released)
            NotificationCenter.default.post(name: .loadsDidChange, object: nil)
        }
    }

    // MARK: - Standing data

    func saveRecurring(_ rule: RecurringDeduction) async throws {
        guard viewer.can(.manageRecurring) else {
            throw SettlementWorkflowError.notPermitted("Your role can't change recurring deductions.")
        }
        let problems = RecurringDeductionService.validate(rule)
        if let first = problems.first { throw SettlementWorkflowError.blocked(first) }
        var r = rule
        r.updatedAt = Date()
        if r.createdAt == nil { r.createdAt = Date() }
        var copy = ledger
        copy.upsert(recurring: r)
        try await persist(copy) { try await $0.saveRecurring(r) }
        ledger = copy
    }

    func saveAdvance(_ advance: DriverAdvance) async throws {
        guard viewer.can(.manageAdvances) else {
            throw SettlementWorkflowError.notPermitted("Your role can't record advances.")
        }
        guard advance.amount.isPositive else {
            throw SettlementWorkflowError.blocked("An advance must be more than $0.00.")
        }
        if advance.descriptionText.trimmingCharacters(in: .whitespaces).isEmpty {
            throw SettlementWorkflowError.blocked("Describe the advance.")
        }
        var a = DriverAdvanceService.reconciled(advance: advance, repayments: ledger.advanceRepayments)
        let recovered = a.recoveredAmount
        if a.amount.rounded < recovered {
            throw SettlementWorkflowError.blocked("\(recovered.formatted) has already been recovered — the advance can't be less than that.")
        }
        a.updatedAt = Date()
        if a.createdAt == nil { a.createdAt = Date() }
        var copy = ledger
        copy.upsert(advance: a)
        try await persist(copy) { try await $0.saveAdvance(a) }
        ledger = copy
    }

    func deleteAdvance(_ advance: DriverAdvance) async throws {
        guard viewer.can(.manageAdvances) else {
            throw SettlementWorkflowError.notPermitted("Your role can't delete advances.")
        }
        let used = ledger.advanceRepayments.contains { $0.advanceId == advance.id }
            || ledger.deductions.contains { $0.advanceId == advance.id }
        guard !used else {
            throw SettlementWorkflowError.blocked("This advance is already on a settlement, so it is kept for history.")
        }
        var copy = ledger
        copy.advances.removeAll { $0.id == advance.id }
        try await persist(copy) { try await $0.deleteAdvance(id: advance.id) }
        ledger = copy
    }

    func savePaySettings(_ settings: DriverPaySettings, for driver: Driver) async throws {
        guard viewer.can(.managePaySettings), let driverId = driver.id else {
            throw SettlementWorkflowError.notPermitted("Your role can't change driver pay.")
        }
        if let problem = SettlementWorkflowService.payRuleProblem(settings.payRule, maximumPercent: maximumDriverPercent) {
            throw SettlementWorkflowError.blocked(problem)
        }
        var updated = driver
        updated.settlementType = settings.settlementType
        updated.payRule = settings.payRule
        updated.payOnGrossRevenue = settings.payOnGrossRevenue
        updated.leaseConfig = settings.leaseConfig
        if let truck = settings.defaultTruckNumber { updated.truckNumber = truck }
        if isLocal {
            var copy = ledger
            copy.upsert(localDriver: updated)
            if localStore == nil { localStore = try SettlementLocalStore.appDefault() }
            try localStore?.save(copy)
            ledger = copy
        } else if let cloudStore {
            try await cloudStore.savePaySettings(driverId: driverId, settings: settings)
            if let idx = cloudDrivers.firstIndex(where: { $0.id == driverId }) {
                cloudDrivers[idx] = updated
            }
        }
    }

    /// Free Local Mode: add a driver (there is no drivers table on device).
    /// Cloud Pro: inserts into `drivers` like the existing Add Driver screen.
    @discardableResult
    func addDriver(name: String, truckNumber: String?, settings: DriverPaySettings?) async throws -> Driver {
        guard viewer.can(.managePaySettings), let profileId else {
            throw SettlementWorkflowError.notPermitted("Your role can't add drivers.")
        }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SettlementWorkflowError.blocked("Enter the driver's name.") }
        // Validate BEFORE creating anything, so a rejected rule can't leave a
        // driver row behind (and a retry can't create a second one).
        if let settings,
           let problem = SettlementWorkflowService.payRuleProblem(settings.payRule, maximumPercent: maximumDriverPercent) {
            throw SettlementWorkflowError.blocked(problem)
        }
        var newDriver = Driver(id: isLocal ? UUID() : nil, profileId: profileId, name: clean,
                               truckNumber: truckNumber?.isEmpty == false ? truckNumber : nil,
                               payType: "percent", active: true, createdAt: Date())
        if isLocal {
            if let settings {
                newDriver.settlementType = settings.settlementType
                newDriver.payRule = settings.payRule
                newDriver.payOnGrossRevenue = settings.payOnGrossRevenue
                newDriver.leaseConfig = settings.leaseConfig
            }
            var copy = ledger
            copy.upsert(localDriver: newDriver)
            if localStore == nil { localStore = try SettlementLocalStore.appDefault() }
            try localStore?.save(copy)
            ledger = copy
            return newDriver
        }
        guard let cloudStore else { throw SettlementCloudError.notSignedIn }
        if let pct = settings?.payRule.components.first(where: { $0.kind == .percentOfGross })?.percent {
            newDriver.payPercentage = NSDecimalNumber(decimal: pct).doubleValue
        }
        let created = try await cloudStore.createDriver(newDriver)
        cloudDrivers.append(created)
        if let settings {
            // The driver now exists; don't throw (a retry would add a
            // duplicate). Surface the problem instead.
            do { try await savePaySettings(settings, for: created) }
            catch { lastError = "Driver added, but pay terms weren't saved: \(error.localizedDescription) Open the driver to set pay." }
        }
        return self.driver(id: created.id) ?? created
    }

    func setDriverActive(_ driver: Driver, active: Bool) async throws {
        guard isLocal, viewer.can(.managePaySettings) else { return }
        var d = driver
        d.active = active
        var copy = ledger
        copy.upsert(localDriver: d)
        try localStore?.save(copy)
        ledger = copy
    }

    func link(documentId: UUID, category: SettlementDocumentCategory,
              target: SettlementDocumentTarget, targetId: UUID,
              settlementId: UUID?, title: String?) async throws {
        guard let profileId else { return }
        let link = SettlementDocumentLink(profileId: profileId, documentId: documentId,
                                          settlementId: settlementId, target: target,
                                          targetId: targetId, category: category,
                                          title: title, createdAt: Date())
        var copy = ledger
        copy.documentLinks.append(link)
        try await persist(copy) { try await $0.linkDocument(link) }
        ledger = copy
    }

    func documents(for bundle: SettlementBundle) async throws -> [TruckDocument] {
        guard !isLocal, let cloudStore, let sid = bundle.settlement.id else { return [] }
        return try await cloudStore.fetchDocuments(
            settlementId: sid,
            loadIds: bundle.loadLines.compactMap(\.loadId))
    }

    // MARK: - YTD

    func ytd(for settlement: Settlement) -> SettlementYTDTotals? {
        guard let driverId = settlement.driverId, let end = settlement.settlementPeriodEnd else { return nil }
        let year = Calendar(identifier: .gregorian).component(.year, from: end)
        return SettlementInsights.ytd(ledger, driverId: driverId, year: year, throughPeriodEnd: end)
    }

    func statement(for bundle: SettlementBundle) -> SettlementStatementDocument {
        let source = role == .driver ? SettlementPermissions.redactedForDriver(bundle) : bundle
        return SettlementStatementDocument.make(
            bundle: source,
            driverName: driverName(bundle.settlement.driverId),
            company: company,
            ytd: bundle.settlement.isEstimateRecord ? nil : ytd(for: bundle.settlement),
            // A driver's copy has no company-paid lines; re-pricing it would
            // move a percent-of-net rule. Show the approved figures instead.
            frozenLoadEarnings: role == .driver ? true : nil)
    }

    // MARK: - Backup (Free Local Mode)

    var ledgerForBackup: SettlementLedger? {
        isLocal ? ledger : nil
    }

    func replaceLocalLedger(_ newLedger: SettlementLedger) throws {
        if localStore == nil { localStore = try SettlementLocalStore.appDefault() }
        try localStore?.replace(with: newLedger)
        ledger = newLedger
        NotificationCenter.default.post(name: .settlementsDidChange, object: nil)
    }

    // MARK: - Persistence

    private func persist(
        _ copy: SettlementLedger,
        cloud: (SettlementCloudStore) async throws -> Void
    ) async throws {
        if isLocal {
            if localStore == nil { localStore = try SettlementLocalStore.appDefault() }
            try localStore!.save(copy)
        } else if let cloudStore {
            try await cloud(cloudStore)
        } else {
            throw SettlementCloudError.notSignedIn
        }
    }
}
