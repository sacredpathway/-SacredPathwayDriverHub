import XCTest
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

// =============================================================================
//  End-to-end acceptance tests
// -----------------------------------------------------------------------------
//  These run the full flow a user goes through — draft, apply recurring rules,
//  recover an advance, calculate, validate, assign a number, approve, mark paid
//  — on isolated test data, and assert the exact dollar figures the settlement
//  statement will print.
//
//  Scenario 1 is the acceptance case from the build brief. If it ever fails,
//  the app is not shipping a correct paycheck.
// =============================================================================

final class SettlementAcceptanceTests: XCTestCase {

    private let actor = SettlementActor(userId: Fx.id(9_001), name: "Test Operator")

    // MARK: - Scenario 1 — the brief's acceptance case

    /// Driver: Test Driver · Period: Mon 2026-09-07 – Sun 2026-09-13
    /// Load 1 $3,500 · Load 2 $3,750 · Gross $7,250 · Driver 70% = $5,075
    /// Fuel $1,180 · Insurance $450 · Truck $1,300 · Cash Advance $300 ·
    /// Maintenance $250  →  Expected Net $1,595.00
    func testScenario1_SeventyPercentWithFiveDeductions() {

        let loads = [
            Fx.load(1, gross: 3_500, loadedMiles: 620, deadheadMiles: 40, sortOrder: 0),
            Fx.load(2, gross: 3_750, loadedMiles: 710, deadheadMiles: 30, sortOrder: 1)
        ]

        let deductions = [
            Fx.deduction(1, .fuel,        "Fuel",          1_180),
            Fx.deduction(2, .insurance,   "Insurance",       450),
            Fx.deduction(3, .truckLease,  "Truck Payment", 1_300),
            Fx.deduction(4, .cashAdvance, "Cash Advance",    300),
            Fx.deduction(5, .maintenance, "Maintenance",     250)
        ]

        let result = SettlementCalculationEngine.calculate(
            Fx.input(payRule: .percentOfGross(70), loads: loads, deductions: deductions)
        )

        // ── The numbers on the statement ─────────────────────────────────
        XCTAssertMoney(result.grossLoadRevenue,     7_250, 0, "Weekly Gross")
        XCTAssertMoney(result.driverBaseEarnings,   5_075, 0, "Driver Gross Earnings at 70%")
        XCTAssertMoney(result.totalDriverDeductions, 3_480, 0, "Total deductions")
        XCTAssertMoney(result.netDriverPay,         1_595, 0, "EXPECTED NET")

        // ── The statement adds up line by line ───────────────────────────
        XCTAssertTrue(result.reconciles)
        XCTAssertEqual(result.driverDeductionLines.count, 5)
        XCTAssertMoney(Money.sum(result.driverDeductionLines.map(\.amount)), 3_480)

        // ── Company side ─────────────────────────────────────────────────
        XCTAssertMoney(result.companyExpenses, 0, 0, "all five deductions are the driver's")
        XCTAssertMoney(result.companyRetained, 5_655, 0, "7,250 − 1,595 − 0")

        // ── Operational metrics ──────────────────────────────────────────
        XCTAssertEqual(result.totalLoads, 2)
        XCTAssertEqual(result.loadedMiles, 1_330)
        XCTAssertEqual(result.deadheadMiles, 70)
        XCTAssertEqual(result.totalMiles, 1_400)
        XCTAssertMoney(result.revenuePerMile, 5, 18, "$7,250 / 1,400 mi")
        XCTAssertMoney(result.fuelCostPerMile, 0, 84, "$1,180 / 1,400 mi")

        // ── The record the UI and the PDF both read ──────────────────────
        var settlement = Fx.settlement(number: nil)
        settlement.apply(result, payRule: .percentOfGross(70),
                         payOnGrossRevenue: true, settlementType: .companyDriver)

        XCTAssertMoney(settlement.netPayMoney, 1_595, 0, "stored net pay")
        XCTAssertEqual(settlement.netPay, 1_595.0, "legacy Double column")

        // ── Validation passes, so it can be approved ─────────────────────
        let context = SettlementValidationContext(
            settlement: settlement,
            loadLines: loads,
            deductions: deductions,
            result: result
        )
        let issues = SettlementValidator.validate(context)
        XCTAssertTrue(
            SettlementValidator.canApprove(issues),
            "blocking issues: \(SettlementValidator.errors(issues).map(\.message))"
        )

        // ── Number assignment ────────────────────────────────────────────
        let number = SettlementNumberService.nextNumber(
            existing: ["SP-2026-0001", "SP-2026-0002"], periodEnd: Fx.periodEnd
        )
        XCTAssertEqual(number, "SP-2026-0003")
        settlement.settlementNumber = number

        // ── Approve, then pay ────────────────────────────────────────────
        XCTAssertNil(SettlementValidator.validateTransition(
            from: .draft, to: .approved, issues: issues))
        settlement.settlementStatus = .approved
        settlement.approvedAt = Fx.periodEnd

        XCTAssertNil(SettlementValidator.validateTransition(
            from: .approved, to: .paid, issues: issues))
        settlement.settlementStatus = .paid
        settlement.paidAt = Fx.periodEnd
        settlement.paymentReference = "ACH-TEST-0003"

        XCTAssertTrue(settlement.isLocked, "a paid settlement is locked")
        XCTAssertMoney(settlement.netPayMoney, 1_595)

        // ── Audit trail ──────────────────────────────────────────────────
        let events = [
            SettlementAuditService.created(
                settlementId: settlement.id!, profileId: Fx.profileId, actor: actor,
                driverName: "Test Driver", periodDescription: settlement.periodDescription),
            SettlementAuditService.statusChanged(
                settlementId: settlement.id!, profileId: Fx.profileId, actor: actor,
                from: .draft, to: .approved, netPay: result.netDriverPay),
            SettlementAuditService.statusChanged(
                settlementId: settlement.id!, profileId: Fx.profileId, actor: actor,
                from: .approved, to: .paid, netPay: result.netDriverPay)
        ]
        XCTAssertEqual(events.map(\.action), [.created, .approved, .markedPaid])
        XCTAssertTrue(events[2].summary.contains("$1,595.00"))
    }

    /// The same settlement re-run through the engine produces the same net pay.
    /// The UI, the PDF and the stored record all read this one result, so this
    /// is the "UI, database and PDF agree" guarantee at the source.
    func testScenario1_IsReproducible() {
        func run() -> SettlementCalculationResult {
            SettlementCalculationEngine.calculate(
                Fx.input(
                    payRule: .percentOfGross(70),
                    loads: [Fx.load(1, gross: 3_500), Fx.load(2, gross: 3_750, sortOrder: 1)],
                    deductions: [
                        Fx.deduction(1, .fuel, "Fuel", 1_180),
                        Fx.deduction(2, .insurance, "Insurance", 450),
                        Fx.deduction(3, .truckLease, "Truck Payment", 1_300),
                        Fx.deduction(4, .cashAdvance, "Cash Advance", 300),
                        Fx.deduction(5, .maintenance, "Maintenance", 250)
                    ]
                )
            )
        }
        let a = run(), b = run()
        XCTAssertEqual(a.netDriverPay, b.netDriverPay)
        XCTAssertEqual(a.lineItems, b.lineItems)
        XCTAssertMoney(b.netDriverPay, 1_595)
    }

    /// The figures the "Estimated Settlement" card shows, from the brief.
    func testScenario1_EstimateMatchesTheFinalSettlement() {
        let estimate = SettlementCalculationEngine.calculate(
            Fx.input(
                payRule: .percentOfGross(70),
                loads: [Fx.load(1, gross: 3_500), Fx.load(2, gross: 3_750, sortOrder: 1)],
                deductions: [
                    Fx.deduction(1, .fuel, "Fuel", 1_180),
                    Fx.deduction(2, .insurance, "Insurance", 450),
                    Fx.deduction(3, .truckLease, "Truck Payment", 1_300),
                    Fx.deduction(4, .cashAdvance, "Cash Advance", 300),
                    Fx.deduction(5, .maintenance, "Maintenance", 250)
                ],
                isEstimate: true
            )
        )
        XCTAssertTrue(estimate.isEstimate)
        XCTAssertMoney(estimate.netDriverPay, 1_595)

        // An estimate is never a financial record.
        var settlement = Fx.settlement()
        settlement.apply(estimate, payRule: .percentOfGross(70),
                         payOnGrossRevenue: true, settlementType: .companyDriver)
        XCTAssertTrue(settlement.isEstimateRecord)

        let issues = SettlementValidator.validate(
            SettlementValidationContext(settlement: settlement, result: estimate)
        )
        XCTAssertTrue(issues.contains { $0.code == "is_estimate" })
    }

    // MARK: - Scenario 2 — additions and a partial advance repayment

    /// Gross $6,000 at 65% = $3,900
    /// Additions: detention $200 + safety bonus $150 = $350
    /// Deductions: fuel $900 + insurance $450 + advance recovery $400 = $1,750
    /// Expected Net $2,500 · advance balance drops $1,000 → $600
    func testScenario2_AdditionsAndPartialAdvanceRepayment() {

        // ── Starting state: a $1,000 advance with nothing recovered ──────
        let advance = Fx.advance(1, type: .cash, dollars: 1_000, on: 2)
        XCTAssertMoney(advance.outstandingBalance, 1_000)

        // ── Recover $400 of it on this settlement ───────────────────────
        let plans = DriverAdvanceService.planRecoveries(
            advances: [advance], repayments: [], driverId: Fx.driverId,
            policy: .fixedPerSettlement, requestedAmount: Fx.money(400)
        )
        XCTAssertEqual(plans.count, 1)
        XCTAssertMoney(plans[0].amount, 400)
        XCTAssertMoney(plans[0].outstandingAfter, 600)
        XCTAssertFalse(plans[0].clearsAdvance)

        let settlementId = Fx.id(7_010)
        let advanceDeductions = DriverAdvanceService.deductions(
            for: plans, profileId: Fx.profileId, settlementId: settlementId,
            date: Fx.periodEnd
        )

        // ── Recurring rules for this driver ──────────────────────────────
        let rules = [
            Fx.recurring(1, .fuel, "Fuel", dollars: 900),
            Fx.recurring(2, .insurance, "Insurance", dollars: 450)
        ]
        let recurringDeductions = RecurringDeductionService.materialise(
            rules: rules,
            driverId: Fx.driverId,
            profileId: Fx.profileId,
            settlementId: settlementId,
            periodStart: Fx.periodStart,
            periodEnd: Fx.periodEnd,
            settlementGross: Fx.money(6_000)
        )
        XCTAssertEqual(recurringDeductions.count, 2)

        let loads = [Fx.load(1, gross: 6_000, loadedMiles: 1_100)]
        let additions = [
            Fx.addition(1, .detention, "Detention — 4 hrs at receiver", 200),
            Fx.addition(2, .safetyBonus, "Clean DOT inspection", 150)
        ]
        let deductions = recurringDeductions + advanceDeductions

        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                payRule: .percentOfGross(65),
                loads: loads,
                additions: additions,
                deductions: deductions
            )
        )

        // ── The numbers ─────────────────────────────────────────────────
        XCTAssertMoney(result.grossLoadRevenue,      6_000)
        XCTAssertMoney(result.driverBaseEarnings,    3_900, 0, "65% of $6,000")
        XCTAssertMoney(result.totalAdditions,          350)
        XCTAssertMoney(result.settlementGross,       6_350)
        XCTAssertMoney(result.totalDriverDeductions, 1_750, 0, "900 + 450 + 400")
        XCTAssertMoney(result.netDriverPay,          2_500, 0, "EXPECTED NET")
        XCTAssertTrue(result.reconciles)

        XCTAssertEqual(result.additionLines.count, 2)
        XCTAssertEqual(result.driverDeductionLines.count, 3)

        // ── Validation ──────────────────────────────────────────────────
        var settlement = Fx.settlement(id: settlementId, number: "SP-2026-0004",
                                       payRule: .percentOfGross(65))
        settlement.apply(result, payRule: .percentOfGross(65),
                         payOnGrossRevenue: true, settlementType: .companyDriver)

        let issues = SettlementValidator.validate(
            SettlementValidationContext(
                settlement: settlement,
                loadLines: loads,
                additions: additions,
                deductions: deductions,
                result: result,
                advances: [advance]
            )
        )
        XCTAssertTrue(
            SettlementValidator.canApprove(issues),
            "blocking issues: \(SettlementValidator.errors(issues).map(\.message))"
        )

        // ── Approving writes the advance ledger ─────────────────────────
        let ledger = DriverAdvanceService.repaymentRecords(
            for: plans, deductions: advanceDeductions, profileId: Fx.profileId,
            settlementId: settlementId, date: Fx.periodEnd
        )
        let updatedAdvance = DriverAdvanceService.reconciled(
            advance: advance, repayments: ledger
        )
        XCTAssertMoney(updatedAdvance.recoveredAmount, 400)
        XCTAssertMoney(updatedAdvance.outstandingBalance, 600)
        XCTAssertFalse(updatedAdvance.isClosed)

        // ── The next settlement can only take the remaining $600 ────────
        let nextPlans = DriverAdvanceService.planRecoveries(
            advances: [advance], repayments: ledger, driverId: Fx.driverId,
            policy: .full, requestedAmount: Fx.money(5_000)
        )
        XCTAssertMoney(nextPlans[0].amount, 600, 0, "capped at the outstanding balance")
        XCTAssertTrue(nextPlans[0].clearsAdvance)
    }

    // MARK: - Scenario 3 — lease operator, end to end

    func testScenario3_LeaseOperatorWeek() {
        let config = LeaseOperatorConfig(
            driverGrossPercent: 72,
            companyGrossPercent: 28,
            rules: [
                ResponsibilityRule(category: .truckLease, responsibility: .driver),
                ResponsibilityRule(category: .fuel, responsibility: .driver),
                ResponsibilityRule(category: .insurance, responsibility: .driver),
                ResponsibilityRule(category: .repair, responsibility: .split,
                                   driverSharePercent: 50),
                ResponsibilityRule(category: .factoringFee, responsibility: .company)
            ]
        )
        let settings = DriverPaySettings(
            profileId: Fx.profileId, driverId: Fx.driverId,
            settlementType: .leaseOperator,
            payRule: .percentOfGross(config.driverGrossPercent),
            leaseConfig: config
        )

        func deduction(
            _ n: Int, _ category: SettlementDeductionCategory,
            _ label: String, _ dollars: Int
        ) -> SettlementDeduction {
            let (responsibility, share) = settings.responsibility(for: category)
            return Fx.deduction(n, category, label, dollars,
                                responsibility: responsibility, driverShare: share)
        }

        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                payRule: settings.payRule,
                type: .leaseOperator,
                loads: [Fx.load(1, gross: 5_200, loadedMiles: 980),
                        Fx.load(2, gross: 4_300, loadedMiles: 810, sortOrder: 1)],
                deductions: [
                    deduction(1, .truckLease, "Weekly lease payment", 1_450),
                    deduction(2, .fuel, "Fuel", 2_100),
                    deduction(3, .insurance, "Insurance", 385),
                    deduction(4, .repair, "Shared tire replacement", 640)
                ],
                fees: CompanyFeeSettings(factoringFeePercent: 3)
            )
        )

        XCTAssertMoney(result.grossLoadRevenue, 9_500)
        XCTAssertMoney(result.driverBaseEarnings, 6_840, 0, "72% of $9,500")
        XCTAssertMoney(result.totalDriverDeductions, 4_255, 0, "1,450 + 2,100 + 385 + 320")
        XCTAssertMoney(result.netDriverPay, 2_585)
        XCTAssertMoney(result.companyExpenses, 605, 0, "320 repair share + 285 factoring")
        XCTAssertMoney(result.companyRetained, 6_310, 0, "9,500 − 2,585 − 605")
        XCTAssertTrue(result.reconciles)
    }

    // MARK: - Cross-driver isolation

    /// Nothing belonging to one driver may reach another driver's settlement.
    func testDriverDataDoesNotLeakAcrossDrivers() {
        let driverOneAdvance = Fx.advance(1, dollars: 500)
        var driverTwoAdvance = Fx.advance(2, dollars: 900)
        driverTwoAdvance.driverId = Fx.driver2Id

        let plans = DriverAdvanceService.planRecoveries(
            advances: [driverOneAdvance, driverTwoAdvance], repayments: [],
            driverId: Fx.driverId, policy: .full
        )
        XCTAssertEqual(plans.map(\.advanceId), [driverOneAdvance.id])
        XCTAssertMoney(Money.sum(plans.map(\.amount)), 500)

        let rules = [
            Fx.recurring(1, .truckLease, "Driver one truck", dollars: 1_000),
            Fx.recurring(2, .truckLease, "Driver two truck", dollars: 1_200,
                         driverId: Fx.driver2Id)
        ]
        let materialised = RecurringDeductionService.materialise(
            rules: rules, driverId: Fx.driverId, profileId: Fx.profileId,
            settlementId: Fx.id(7_020), periodStart: Fx.periodStart,
            periodEnd: Fx.periodEnd, settlementGross: Fx.money(5_000)
        )
        XCTAssertEqual(materialised.count, 1)
        XCTAssertEqual(materialised[0].descriptionText, "Driver one truck")

        XCTAssertMoney(
            DriverAdvanceService.totalOutstanding(
                advances: [driverOneAdvance, driverTwoAdvance],
                repayments: [], driverId: Fx.driverId
            ),
            500
        )
    }

    // MARK: - Estimate vs finalised separation

    func testEstimatesAreNotCountedAsPaidHistory() {
        let paid = Fx.settlement(id: Fx.id(7_030), status: .paid, number: "SP-2026-0005")
        var estimate = Fx.settlement(id: Fx.id(7_031), status: .draft, number: nil)
        estimate.isEstimate = true

        let history = [paid, estimate]
        let financialRecords = history.filter {
            $0.settlementStatus.isFinancialRecord && !$0.isEstimateRecord
        }
        XCTAssertEqual(financialRecords.map(\.id), [paid.id])
    }

    // MARK: - Reopen and adjust

    func testReopeningAPaidSettlementIsAuditedAndUnlocks() {
        var settlement = Fx.settlement(status: .paid)
        XCTAssertTrue(settlement.isLocked)

        // No reason -> refused.
        XCTAssertNotNil(SettlementValidator.validateTransition(
            from: .paid, to: .approved, issues: [], reopenReason: ""))

        // With a reason -> allowed and recorded.
        XCTAssertNil(SettlementValidator.validateTransition(
            from: .paid, to: .approved, issues: [],
            reopenReason: "Fuel receipt arrived after payment"))

        let event = SettlementAuditService.reopened(
            settlementId: settlement.id!, profileId: Fx.profileId, actor: actor,
            from: .paid, reason: "Fuel receipt arrived after payment"
        )
        XCTAssertEqual(event.action, .reopened)
        XCTAssertEqual(event.previousValue, "paid")

        settlement.settlementStatus = .approved
        XCTAssertFalse(settlement.isLocked)
    }

    func testPayingALoadTwiceRequiresAnAuditedAdjustment() {
        let loadId = Fx.id(1_001)
        let originalSettlement = Fx.id(7_040)

        // Plain re-add: blocked.
        let blocked = SettlementValidator.validate(
            SettlementValidationContext(
                settlement: Fx.settlement(id: Fx.id(7_041)),
                loadLines: [Fx.load(1, gross: 3_500, loadId: loadId)],
                alreadySettledLoadIds: [loadId: originalSettlement],
                settlementNumberForSettlementId: [originalSettlement: "SP-2026-0006"]
            )
        )
        XCTAssertTrue(blocked.contains { $0.code == "load_already_paid" && $0.severity == .error })

        // Marked as a correction of a named settlement: allowed, warned, tracked.
        let allowed = SettlementValidator.validate(
            SettlementValidationContext(
                settlement: Fx.settlement(id: Fx.id(7_041)),
                loadLines: [Fx.load(1, gross: 250, loadId: loadId,
                                    isAdjustment: true,
                                    correctsSettlementId: originalSettlement)],
                alreadySettledLoadIds: [loadId: originalSettlement],
                settlementNumberForSettlementId: [originalSettlement: "SP-2026-0006"]
            )
        )
        XCTAssertFalse(allowed.contains { $0.code == "load_already_paid" })
        XCTAssertTrue(allowed.contains { $0.code == "load_adjustment" })
    }
}
