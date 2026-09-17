import XCTest
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

// =============================================================================
//  Phase B fixtures — operational records (Load / Expense / Driver) built from
//  obviously-fake test data, plus a fixed UTC calendar so every date
//  comparison is deterministic on any device.
// =============================================================================

extension Fx {

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    /// "Now" for the Phase B tests: Tuesday after the test week.
    static let now = date(2026, 9, 15)

    static let actor = SettlementActor(userId: id(9_001), name: "Test Operator")

    static func driver(
        _ id: UUID = Fx.driverId,
        name: String = "Test Driver",
        rule: PayRule? = .percentOfGross(70),
        type: SettlementType = .companyDriver
    ) -> Driver {
        var d = Driver(id: id, profileId: profileId, name: name, truckNumber: "TEST-UNIT-1",
                       payPercentage: nil, payType: "percent", flatRate: nil,
                       phone: nil, email: nil, active: true, createdAt: nil)
        d.payRule = rule
        d.settlementType = type
        d.payOnGrossRevenue = true
        return d
    }

    static func opLoad(
        _ n: Int,
        gross: Double,
        driverId: UUID? = Fx.driverId,
        pickupDay: Int = 8,
        deliveryDay: Int = 9,
        miles: Double = 500,
        empty: Double = 0,
        status: LoadStatus? = .readyForSettlement,
        broker: String = "Test Broker"
    ) -> Load {
        Load(
            id: id(1_000 + n),
            profileId: profileId,
            driverId: driverId,
            loadNumber: "TEST-\(n)",
            brokerName: broker,
            brokerMcNumber: "000000",
            pickupDate: date(2026, 9, pickupDay),
            deliveryDate: date(2026, 9, deliveryDay),
            origin: "Test Origin, TS",
            destination: "Test Destination, TS",
            totalMiles: miles,
            emptyMiles: empty,
            lineHaulRate: gross,
            totalRevenue: gross,
            status: status?.rawValue
        )
    }

    static func expense(_ n: Int, _ category: String, _ amount: Double, day: Int = 10) -> Expense {
        Expense(id: id(8_000 + n), profileId: profileId, category: category,
                amount: amount, description: "Test \(category) \(n)",
                receiptDate: date(2026, 9, day))
    }

    static func options(
        driver: Driver = Fx.driver(),
        advancePolicy: AdvanceRecoveryPolicy = .manual,
        advanceAmount: Money? = nil,
        fees: CompanyFeeSettings = .none,
        isEstimate: Bool = false,
        applyRecurring: Bool = true
    ) -> SettlementDraftOptions {
        SettlementDraftOptions(
            profileId: profileId,
            driver: driver,
            paySettings: driver.paySettings(),
            periodStart: periodStart,
            periodEnd: periodEnd,
            companyFees: fees,
            applyRecurringDeductions: applyRecurring,
            advancePolicy: advancePolicy,
            advanceRecoveryAmount: advanceAmount,
            isEstimate: isEstimate,
            actor: actor,
            now: now,
            calendar: utc
        )
    }

    /// Drafts + saves a settlement for `loads`, returning its id.
    @discardableResult
    static func saveDraft(
        _ loads: [Load],
        into ledger: inout SettlementLedger,
        driver: Driver = Fx.driver(),
        additions: [SettlementAddition] = [],
        deductions: [SettlementDeduction] = [],
        advancePolicy: AdvanceRecoveryPolicy = .manual,
        advanceAmount: Money? = nil
    ) throws -> UUID {
        var bundle = SettlementWorkflowService.makeDraft(
            options: options(driver: driver, advancePolicy: advancePolicy, advanceAmount: advanceAmount),
            loads: loads, ledger: ledger)
        bundle.additions += additions
        bundle.deductions += deductions
        try SettlementWorkflowService.save(bundle, into: &ledger, actor: actor, now: now)
        return bundle.settlement.id!
    }

    static func approve(_ id: UUID, _ ledger: inout SettlementLedger) throws -> SettlementTransitionOutcome {
        try SettlementWorkflowService.transition(
            settlementId: id, to: .approved, ledger: &ledger, actor: actor, now: now, calendar: utc)
    }
}

// =============================================================================
//  SettlementWorkflowTests — draft, save, approve, pay, void, reopen
// =============================================================================

final class SettlementWorkflowTests: XCTestCase {

    // MARK: - Adapters

    func testLoadAdapterUsesStoredTotalRevenueAsGross() {
        var load = Fx.opLoad(1, gross: 3_000)
        load.fuelSurcharge = 250
        load.totalRevenue = 3_400      // rate con total incl. an unitemised accessorial
        let line = SettlementLoadAdapter.line(from: load, settlementId: nil, profileId: Fx.profileId, sortOrder: 0)
        XCTAssertMoney(line.grossRate, 3_400)
        XCTAssertMoney(line.linehaul, 3_000)
        XCTAssertMoney(line.fuelSurcharge, 250)
        XCTAssertEqual(line.loadId, load.id)
        XCTAssertEqual(line.loadNumber, "TEST-1")
    }

    func testLoadAdapterWithoutOverrideWhenComponentsMatch() {
        let load = Fx.opLoad(1, gross: 3_500, miles: 620, empty: 40)
        let line = SettlementLoadAdapter.line(from: load, settlementId: nil, profileId: Fx.profileId, sortOrder: 0)
        XCTAssertNil(line.grossRateOverride)
        XCTAssertMoney(line.grossRate, 3_500)
        XCTAssertEqual(line.loadedMiles, 620)
        XCTAssertEqual(line.deadheadMiles, 40)
    }

    func testExpenseAdapterHonoursResponsibilityRules() {
        let lease = Fx.driver(type: .leaseOperator)
        let fuel = SettlementLoadAdapter.deduction(
            from: Fx.expense(1, "fuel", 412.37), settlementId: nil, profileId: Fx.profileId,
            paySettings: lease.paySettings(), sortOrder: 0)
        XCTAssertEqual(fuel.category, .fuel)
        XCTAssertEqual(fuel.responsibility, .driver)
        XCTAssertMoney(fuel.driverAmount, 412, 37)

        let company = Fx.driver(type: .companyDriver)
        let fuel2 = SettlementLoadAdapter.deduction(
            from: Fx.expense(2, "fuel", 412.37), settlementId: nil, profileId: Fx.profileId,
            paySettings: company.paySettings(), sortOrder: 0)
        XCTAssertEqual(fuel2.responsibility, .company, "company drivers don't pay for fuel by default")
        XCTAssertMoney(fuel2.driverAmount, 0)
        XCTAssertEqual(fuel2.relatedExpenseId, Fx.id(8_002))
    }

    // MARK: - Eligible loads

    func testEligibleLoadsFiltersDriverPeriodAndCompletion() {
        let loads = [
            Fx.opLoad(1, gross: 1_000),                                   // in
            Fx.opLoad(2, gross: 1_000, driverId: Fx.driver2Id),           // other driver
            Fx.opLoad(3, gross: 1_000, pickupDay: 14),                    // after period
            Fx.opLoad(4, gross: 1_000, deliveryDay: 20, status: .assigned), // not delivered yet
            Fx.opLoad(5, gross: 1_000, driverId: nil),                    // unassigned
            Fx.opLoad(6, gross: 1_000, status: .settled),                 // legacy paystub
            Fx.opLoad(7, gross: 1_000, pickupDay: 7),                     // first day
            Fx.opLoad(8, gross: 1_000, pickupDay: 13)                     // last day
        ]
        let eligible = SettlementWorkflowService.eligibleLoads(
            from: loads, driverId: Fx.driverId, periodStart: Fx.periodStart, periodEnd: Fx.periodEnd,
            ledger: .empty, now: Fx.now, calendar: Fx.utc)
        XCTAssertEqual(Set(eligible.map { $0.load.loadNumber! }), ["TEST-1", "TEST-6", "TEST-7", "TEST-8"])
        XCTAssertFalse(eligible.first { $0.load.loadNumber == "TEST-6" }!.isSelectedByDefault,
                       "legacy-settled loads are offered but not pre-selected")

        let withUnassignedAndOpen = SettlementWorkflowService.eligibleLoads(
            from: loads, driverId: Fx.driverId, periodStart: Fx.periodStart, periodEnd: Fx.periodEnd,
            ledger: .empty, includeUnassigned: true, includeInProgress: true, now: Fx.now, calendar: Fx.utc)
        XCTAssertTrue(withUnassignedAndOpen.contains { $0.load.loadNumber == "TEST-4" })
        XCTAssertTrue(withUnassignedAndOpen.contains { $0.load.loadNumber == "TEST-5" })
    }

    // MARK: - Drafting

    func testDraftAppliesDriverRuleNumberAndRecurringDeductions() throws {
        var ledger = SettlementLedger()
        ledger.recurringDeductions = [
            Fx.recurring(1, .insurance, "Weekly Insurance", dollars: 450),
            Fx.recurring(2, .truckLease, "Truck Payment", dollars: 1_300),
            Fx.recurring(3, .other, "Other driver's rule", dollars: 99, driverId: Fx.driver2Id),
            Fx.recurring(4, .escrow, "Inactive", dollars: 50, active: false)
        ]
        let bundle = SettlementWorkflowService.makeDraft(
            options: Fx.options(),
            loads: [Fx.opLoad(1, gross: 3_500), Fx.opLoad(2, gross: 3_750)],
            ledger: ledger)

        XCTAssertEqual(bundle.settlement.settlementStatus, .draft)
        XCTAssertEqual(bundle.settlement.settlementNumber, "SP-2026-0001")
        XCTAssertEqual(bundle.loadLines.count, 2)
        XCTAssertEqual(Set(bundle.deductions.map(\.descriptionText)), ["Weekly Insurance", "Truck Payment"])
        XCTAssertMoney(bundle.settlement.grossLoadRevenueMoney, 7_250)
        XCTAssertMoney(bundle.settlement.totalDriverEarnings!, 5_075)
        XCTAssertMoney(bundle.settlement.netPayMoney, 3_325, 0, "5,075 − 450 − 1,300")
        XCTAssertMoney(bundle.loadLines[0].driverEarnings, 2_450, 0, "frozen per-load earnings")
        XCTAssertEqual(bundle.settlement.engineVersion, SettlementCalculationEngine.engineVersion)
        XCTAssertTrue(bundle.auditEvents.contains { $0.action == .created })
        XCTAssertTrue(bundle.auditEvents.contains { $0.action == .recurringApplied })
        XCTAssertEqual(bundle.auditEvents.filter { $0.action == .loadAdded }.count, 2)
    }

    func testRecurringDeductionCanBeRemovedBeforeApproval() throws {
        var ledger = SettlementLedger()
        ledger.recurringDeductions = [Fx.recurring(1, .insurance, "Weekly Insurance", dollars: 450)]
        let id = try Fx.saveDraft([Fx.opLoad(1, gross: 1_000)], into: &ledger)
        var bundle = ledger.bundle(for: id)!
        XCTAssertEqual(bundle.deductions.count, 1)
        bundle.deductions.removeAll()
        let events = try SettlementWorkflowService.save(bundle, into: &ledger, actor: Fx.actor, now: Fx.now)
        XCTAssertTrue(events.contains { $0.action == .deductionRemoved })
        XCTAssertEqual(ledger.bundle(for: id)!.deductions.count, 0)
        XCTAssertMoney(ledger.settlement(id: id)!.netPayMoney, 700)
    }

    func testFixedPerLoadPayThroughDraft() throws {
        var ledger = SettlementLedger()
        let driver = Fx.driver(rule: .flatPerLoad(Fx.money(650)))
        let id = try Fx.saveDraft([Fx.opLoad(1, gross: 2_000), Fx.opLoad(2, gross: 3_100)],
                                  into: &ledger, driver: driver)
        let s = ledger.settlement(id: id)!
        XCTAssertMoney(s.totalDriverEarnings!, 1_300)
        XCTAssertMoney(s.netPayMoney, 1_300)
        XCTAssertMoney(s.companyRetained!, 3_800)
    }

    func testPerMilePayThroughDraftUsesLoadedMilesAndKeepsRatePrecision() throws {
        var ledger = SettlementLedger()
        let driver = Fx.driver(rule: .perMile(Money(Decimal(string: "0.585")!)))
        let id = try Fx.saveDraft([Fx.opLoad(1, gross: 2_000, miles: 1_000, empty: 120),
                                   Fx.opLoad(2, gross: 2_000, miles: 333, empty: 0)],
                                  into: &ledger, driver: driver)
        let s = ledger.settlement(id: id)!
        // 1,333 mi × $0.585 = $779.805 → per line 585.00 + 194.805→194.81
        XCTAssertMoney(s.totalDriverEarnings!, 779, 81)

        // Round-trip the pay rule through JSON: the 3rd decimal must survive.
        let data = try JSONEncoder().encode(s.payRule!)
        let back = try JSONDecoder().decode(PayRule.self, from: data)
        XCTAssertEqual(back.components.first?.rate?.amount, Decimal(string: "0.585"))
    }

    func testEstimateDraftHasNoNumberAndIsFlagged() {
        let bundle = SettlementWorkflowService.makeDraft(
            options: Fx.options(isEstimate: true),
            loads: [Fx.opLoad(1, gross: 1_000)], ledger: .empty)
        XCTAssertNil(bundle.settlement.settlementNumber)
        XCTAssertTrue(bundle.settlement.isEstimateRecord)
        XCTAssertTrue(bundle.calculate().isEstimate)
    }

    func testSettlementNumbersIncrementAndStayUnique() throws {
        var ledger = SettlementLedger()
        let a = try Fx.saveDraft([Fx.opLoad(1, gross: 1_000)], into: &ledger)
        let b = try Fx.saveDraft([Fx.opLoad(2, gross: 1_000)], into: &ledger)
        XCTAssertEqual(ledger.settlement(id: a)?.settlementNumber, "SP-2026-0001")
        XCTAssertEqual(ledger.settlement(id: b)?.settlementNumber, "SP-2026-0002")

        // Forcing a duplicate is refused on save (case-insensitive)…
        var bundle = ledger.bundle(for: b)!
        bundle.settlement.settlementNumber = "sp-2026-0001"
        XCTAssertThrowsError(try SettlementWorkflowService.save(bundle, into: &ledger, actor: Fx.actor, now: Fx.now)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already used"))
        }
        XCTAssertEqual(ledger.settlement(id: b)?.settlementNumber, "SP-2026-0002")

        // …and by validation if a duplicate ever arrives from elsewhere.
        let issues = SettlementWorkflowService.validate(bundle, ledger: ledger)
        XCTAssertTrue(issues.contains { $0.code == "duplicate_number" })
    }

    func testPercentOfGrossRecurringIsRepricedWhenLoadsChange() throws {
        var ledger = SettlementLedger()
        ledger.recurringDeductions = [Fx.recurring(1, .maintenanceReserve, "Reserve 2%", percentOfGross: 2)]
        let id = try Fx.saveDraft([Fx.opLoad(1, gross: 5_000), Fx.opLoad(2, gross: 1_000)], into: &ledger)
        XCTAssertMoney(ledger.bundle(for: id)!.deductions[0].amount, 120)

        var bundle = ledger.bundle(for: id)!
        bundle.loadLines.removeAll { $0.loadNumber == "TEST-2" }
        try SettlementWorkflowService.save(bundle, into: &ledger, actor: Fx.actor, now: Fx.now)
        XCTAssertMoney(ledger.bundle(for: id)!.deductions[0].amount, 100, 0, "2% of the new $5,000 gross")
    }

    // MARK: - Duplicate-load prevention

    func testSameLoadCannotBePaidTwice() throws {
        var ledger = SettlementLedger()
        let first = try Fx.saveDraft([Fx.opLoad(1, gross: 2_000)], into: &ledger)
        let outcome = try Fx.approve(first, &ledger)
        XCTAssertEqual(outcome.loadIdsToMarkSettled, [Fx.id(1_001)])

        // The wizard now shows the load as already paid…
        let eligible = SettlementWorkflowService.eligibleLoads(
            from: [Fx.opLoad(1, gross: 2_000)], driverId: Fx.driverId,
            periodStart: Fx.periodStart, periodEnd: Fx.periodEnd,
            ledger: ledger, now: Fx.now, calendar: Fx.utc)
        XCTAssertEqual(eligible.first?.alreadyPaidOn, first)
        XCTAssertFalse(eligible.first!.isSelectable)

        // …and forcing it onto a second settlement blocks approval.
        let second = try Fx.saveDraft([Fx.opLoad(1, gross: 2_000)], into: &ledger)
        let issues = SettlementWorkflowService.validate(ledger.bundle(for: second)!, ledger: ledger)
        XCTAssertTrue(issues.contains { $0.code == "load_already_paid" })
        XCTAssertThrowsError(try Fx.approve(second, &ledger))
    }

    func testRecordedAdjustmentMayRepayALoad() throws {
        var ledger = SettlementLedger()
        let first = try Fx.saveDraft([Fx.opLoad(1, gross: 2_000)], into: &ledger)
        _ = try Fx.approve(first, &ledger)

        var bundle = SettlementWorkflowService.makeDraft(
            options: Fx.options(), loads: [], ledger: ledger)
        bundle.loadLines = [SettlementWorkflowService.adjustmentLine(
            for: Fx.opLoad(1, gross: 2_000), correcting: first, in: bundle,
            grossOverride: Fx.money(150), note: "Detention paid late by broker")]
        try SettlementWorkflowService.save(bundle, into: &ledger, actor: Fx.actor, now: Fx.now)
        let outcome = try Fx.approve(bundle.settlement.id!, &ledger)
        XCTAssertMoney(outcome.settlement.netPayMoney, 105, 0, "70% of the $150 correction")
        XCTAssertTrue(outcome.loadIdsToMarkSettled.isEmpty, "a correction doesn't re-flag the load")
        XCTAssertEqual(ledger.alreadySettledLoadIds()[Fx.id(1_001)], first,
                       "the original settlement remains the one that paid the load")
    }

    func testExpenseCannotBeDeductedOnTwoSettlements() throws {
        var ledger = SettlementLedger()
        let driver = Fx.driver(type: .leaseOperator)
        let a = try Fx.saveDraft([Fx.opLoad(1, gross: 1_000)], into: &ledger, driver: driver)
        var bundleA = ledger.bundle(for: a)!
        try SettlementWorkflowService.addExpense(Fx.expense(1, "fuel", 300), to: &bundleA,
                                                 paySettings: driver.paySettings(), ledger: ledger)
        try SettlementWorkflowService.save(bundleA, into: &ledger, actor: Fx.actor, now: Fx.now)

        let b = try Fx.saveDraft([Fx.opLoad(2, gross: 1_000)], into: &ledger, driver: driver)
        var bundleB = ledger.bundle(for: b)!
        XCTAssertThrowsError(try SettlementWorkflowService.addExpense(
            Fx.expense(1, "fuel", 300), to: &bundleB, paySettings: driver.paySettings(), ledger: ledger))
    }

    // MARK: - Locking, reopening, voiding

    func testPaidSettlementIsLockedAgainstEdits() throws {
        var ledger = SettlementLedger()
        let id = try Fx.saveDraft([Fx.opLoad(1, gross: 2_000)], into: &ledger)
        _ = try Fx.approve(id, &ledger)
        _ = try SettlementWorkflowService.transition(
            settlementId: id, to: .paid, ledger: &ledger, actor: Fx.actor,
            paymentReference: "ACH-TEST-1", now: Fx.now, calendar: Fx.utc)
        XCTAssertEqual(ledger.settlement(id: id)?.settlementStatus, .paid)
        XCTAssertEqual(ledger.settlement(id: id)?.paymentReference, "ACH-TEST-1")

        var bundle = ledger.bundle(for: id)!
        bundle.additions.append(Fx.addition(1, .bonus, "Sneaky bonus", 500))
        XCTAssertThrowsError(try SettlementWorkflowService.save(bundle, into: &ledger, actor: Fx.actor)) { error in
            XCTAssertEqual(error as? SettlementWorkflowError, .locked(.paid))
        }
        XCTAssertMoney(ledger.settlement(id: id)!.netPayMoney, 1_400, 0, "paid figures unchanged")
    }

    func testMarkPaidRequiresApproval() throws {
        var ledger = SettlementLedger()
        let id = try Fx.saveDraft([Fx.opLoad(1, gross: 2_000)], into: &ledger)
        XCTAssertThrowsError(try SettlementWorkflowService.transition(
            settlementId: id, to: .paid, ledger: &ledger, actor: Fx.actor, now: Fx.now))
    }

    func testReopeningPaidSettlementNeedsReasonAndIsAudited() throws {
        var ledger = SettlementLedger()
        let id = try Fx.saveDraft([Fx.opLoad(1, gross: 2_000)], into: &ledger)
        _ = try Fx.approve(id, &ledger)
        _ = try SettlementWorkflowService.transition(
            settlementId: id, to: .paid, ledger: &ledger, actor: Fx.actor, now: Fx.now)

        XCTAssertThrowsError(try SettlementWorkflowService.transition(
            settlementId: id, to: .approved, ledger: &ledger, actor: Fx.actor, now: Fx.now),
            "no reason → refused")

        let outcome = try SettlementWorkflowService.transition(
            settlementId: id, to: .approved, ledger: &ledger, actor: Fx.actor,
            reason: "Payment bounced", now: Fx.now)
        XCTAssertEqual(outcome.settlement.settlementStatus, .approved)
        XCTAssertNil(outcome.settlement.paidAt)
        let actions = ledger.bundle(for: id)!.auditEvents.map(\.action)
        XCTAssertTrue(actions.contains(.reopened))
        XCTAssertTrue(actions.contains(.markedPaid))
        XCTAssertTrue(actions.contains(.approved))
        let reopen = ledger.auditEvents.first { $0.action == .reopened }!
        XCTAssertEqual(reopen.actorName, "Test Operator")
        XCTAssertEqual(reopen.previousValue, "paid")
        XCTAssertTrue(reopen.summary.contains("Payment bounced"))
    }

    func testEditingApprovedSettlementSendsItBackToDraft() throws {
        var ledger = SettlementLedger()
        let id = try Fx.saveDraft([Fx.opLoad(1, gross: 2_000)], into: &ledger)
        _ = try Fx.approve(id, &ledger)
        var bundle = ledger.bundle(for: id)!
        bundle.additions.append(Fx.addition(1, .detention, "Detention", 75))
        let events = try SettlementWorkflowService.save(bundle, into: &ledger, actor: Fx.actor, now: Fx.now)
        XCTAssertEqual(ledger.settlement(id: id)?.settlementStatus, .draft)
        XCTAssertNil(ledger.settlement(id: id)?.approvedAt)
        XCTAssertTrue(events.contains { $0.action == .additionAdded })
        XCTAssertTrue(events.contains { $0.action == .recalculated })
        XCTAssertTrue(events.contains { $0.action == .statusChanged })
    }

    func testEstimateCannotBeApproved() throws {
        var ledger = SettlementLedger()
        var bundle = SettlementWorkflowService.makeDraft(
            options: Fx.options(isEstimate: true), loads: [Fx.opLoad(1, gross: 1_000)], ledger: ledger)
        bundle.auditEvents = []
        try SettlementWorkflowService.save(bundle, into: &ledger, actor: Fx.actor)
        XCTAssertThrowsError(try Fx.approve(bundle.settlement.id!, &ledger)) { error in
            XCTAssertEqual(error as? SettlementWorkflowError, .estimateCannotBeFinalized)
        }
    }

    // MARK: - Advances

    func testAdvancePartialRepaymentAcrossTwoSettlements() throws {
        var ledger = SettlementLedger()
        ledger.advances = [Fx.advance(1, dollars: 1_000)]

        // Week 1: recover $400 of $1,000.
        let w1 = try Fx.saveDraft([Fx.opLoad(1, gross: 3_000)], into: &ledger,
                                  advancePolicy: .fixedPerSettlement, advanceAmount: Fx.money(400))
        XCTAssertMoney(ledger.outstandingAdvanceBalance(forDriver: Fx.driverId), 1_000, 0,
                       "a draft never moves the balance")
        let o1 = try Fx.approve(w1, &ledger)
        XCTAssertEqual(o1.repaymentsAdded.count, 1)
        XCTAssertMoney(o1.repaymentsAdded[0].amount, 400)
        XCTAssertMoney(ledger.outstandingAdvanceBalance(forDriver: Fx.driverId), 600)
        XCTAssertMoney(ledger.advances[0].recoveredAmount, 400)
        XCTAssertFalse(ledger.advances[0].isClosed)

        // Week 2: ask for $1,000 — capped at the $600 left.
        let w2 = try Fx.saveDraft([Fx.opLoad(2, gross: 3_000)], into: &ledger,
                                  advancePolicy: .fixedPerSettlement, advanceAmount: Fx.money(1_000))
        XCTAssertMoney(ledger.bundle(for: w2)!.deductions.first { $0.advanceId != nil }!.amount, 600)
        _ = try Fx.approve(w2, &ledger)
        XCTAssertMoney(ledger.outstandingAdvanceBalance(forDriver: Fx.driverId), 0)
        XCTAssertTrue(ledger.advances[0].isClosed)
    }

    func testAdvanceFullRepaymentAndOverRecoveryBlocked() throws {
        var ledger = SettlementLedger()
        ledger.advances = [Fx.advance(1, dollars: 300)]
        let id = try Fx.saveDraft([Fx.opLoad(1, gross: 3_000)], into: &ledger, advancePolicy: .full)
        let line = ledger.bundle(for: id)!.deductions.first { $0.advanceId != nil }!
        XCTAssertMoney(line.amount, 300)
        XCTAssertEqual(line.category, .cashAdvance)

        // Hand-edit the recovery above the balance → approval refused.
        var bundle = ledger.bundle(for: id)!
        let idx = bundle.deductions.firstIndex { $0.advanceId != nil }!
        bundle.deductions[idx].amount = Fx.money(450)
        try SettlementWorkflowService.save(bundle, into: &ledger, actor: Fx.actor)
        XCTAssertThrowsError(try Fx.approve(id, &ledger)) { error in
            XCTAssertTrue(error.localizedDescription.contains("exceeds the outstanding balance"))
        }
        XCTAssertMoney(ledger.outstandingAdvanceBalance(forDriver: Fx.driverId), 300)

        bundle.deductions[idx].amount = Fx.money(300)
        try SettlementWorkflowService.save(bundle, into: &ledger, actor: Fx.actor)
        _ = try Fx.approve(id, &ledger)
        XCTAssertMoney(ledger.outstandingAdvanceBalance(forDriver: Fx.driverId), 0)
    }

    func testVoidingRestoresAdvanceBalanceAndReleasesLoads() throws {
        var ledger = SettlementLedger()
        ledger.advances = [Fx.advance(1, dollars: 500)]
        let id = try Fx.saveDraft([Fx.opLoad(1, gross: 3_000)], into: &ledger, advancePolicy: .full)
        _ = try Fx.approve(id, &ledger)
        XCTAssertMoney(ledger.outstandingAdvanceBalance(forDriver: Fx.driverId), 0)

        let outcome = try SettlementWorkflowService.transition(
            settlementId: id, to: .voided, ledger: &ledger, actor: Fx.actor,
            reason: "Wrong driver", now: Fx.now)
        XCTAssertEqual(outcome.repaymentIdsRemoved.count, 1)
        XCTAssertEqual(outcome.loadIdsToRelease, [Fx.id(1_001)])
        XCTAssertMoney(ledger.outstandingAdvanceBalance(forDriver: Fx.driverId), 500)
        XCTAssertFalse(ledger.advances[0].isClosed)
        XCTAssertTrue(ledger.alreadySettledLoadIds().isEmpty, "a voided settlement no longer pays the load")
        XCTAssertTrue(ledger.settlement(id: id)!.isLocked)

        // Reopening a voided settlement goes to draft with a reason.
        let reopened = try SettlementWorkflowService.transition(
            settlementId: id, to: .draft, ledger: &ledger, actor: Fx.actor,
            reason: "Voided by mistake", now: Fx.now)
        XCTAssertEqual(reopened.settlement.settlementStatus, .draft)
        XCTAssertNil(reopened.settlement.voidedAt)
    }
}

// MARK: - Pay rule validation (shared by pay-terms screens and repository)

final class SettlementPayRuleValidationTests: XCTestCase {
    func testPayRuleProblem() {
        XCTAssertNil(SettlementWorkflowService.payRuleProblem(.percentOfGross(70), maximumPercent: 100))
        XCTAssertNotNil(SettlementWorkflowService.payRuleProblem(.percentOfGross(150), maximumPercent: 100))
        XCTAssertNotNil(SettlementWorkflowService.payRuleProblem(.percentOfGross(0), maximumPercent: 100))
        XCTAssertNotNil(SettlementWorkflowService.payRuleProblem(.percentOfGross(80), maximumPercent: 75),
                        "company cap applies")
        XCTAssertNotNil(SettlementWorkflowService.payRuleProblem(
            PayRule(components: [PayComponent(kind: .perMile)]), maximumPercent: 100),
            "per-mile needs a rate")
        XCTAssertNil(SettlementWorkflowService.payRuleProblem(
            PayRule(components: [PayComponent(kind: .perMile, rate: Money(Decimal(string: "0.585")!))]),
            maximumPercent: 100))
        XCTAssertNil(SettlementWorkflowService.payRuleProblem(.none, maximumPercent: 100))
    }
}
