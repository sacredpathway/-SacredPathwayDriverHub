import XCTest
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

@MainActor
final class SettlementValidationTests: XCTestCase {

    private func issues(
        _ context: SettlementValidationContext
    ) -> [SettlementValidationIssue] {
        SettlementValidator.validate(context)
    }

    private func hasError(_ list: [SettlementValidationIssue], _ code: String) -> Bool {
        list.contains { $0.code == code && $0.severity == .error }
    }

    private func hasWarning(_ list: [SettlementValidationIssue], _ code: String) -> Bool {
        list.contains { $0.code == code && $0.severity == .warning }
    }

    // MARK: - Header

    func testSettlementWithNoDriverIsBlocked() {
        let context = SettlementValidationContext(
            settlement: Fx.settlement(driverId: nil),
            loadLines: [Fx.load(1, gross: 1_000)]
        )
        XCTAssertTrue(hasError(issues(context), "no_driver"))
        XCTAssertFalse(SettlementValidator.canApprove(issues(context)))
    }

    func testReversedPeriodIsBlocked() {
        var settlement = Fx.settlement()
        settlement.settlementPeriodStart = Fx.date(2026, 9, 13)
        settlement.settlementPeriodEnd = Fx.date(2026, 9, 7)
        XCTAssertTrue(hasError(issues(SettlementValidationContext(settlement: settlement)),
                               "period_reversed"))
    }

    /// History must survive an archived driver — this warns, it does not block.
    func testDeletedDriverWarnsButKeepsHistory() {
        let context = SettlementValidationContext(
            settlement: Fx.settlement(),
            loadLines: [Fx.load(1, gross: 1_000)],
            driverExists: false
        )
        let list = issues(context)
        XCTAssertTrue(hasWarning(list, "driver_missing"))
        XCTAssertFalse(hasError(list, "driver_missing"))
    }

    // MARK: - Settlement numbers

    func testDuplicateSettlementNumberIsBlocked() {
        let context = SettlementValidationContext(
            settlement: Fx.settlement(number: "SP-2026-0001"),
            loadLines: [Fx.load(1, gross: 1_000)],
            existingSettlementNumbers: ["SP-2026-0001"]
        )
        XCTAssertTrue(hasError(issues(context), "duplicate_number"))
    }

    func testASettlementIsNotADuplicateOfItself() {
        let settlementId = Fx.id(7_000)
        let context = SettlementValidationContext(
            settlement: Fx.settlement(id: settlementId, number: "SP-2026-0001"),
            loadLines: [Fx.load(1, gross: 1_000)],
            existingSettlementNumbers: ["SP-2026-0001"],
            settlementNumbersById: [settlementId: "SP-2026-0001"]
        )
        XCTAssertFalse(hasError(issues(context), "duplicate_number"))
    }

    // MARK: - Pay rules

    func testMissingPayRuleIsBlocked() {
        let context = SettlementValidationContext(
            settlement: Fx.settlement(payRule: .none),
            loadLines: [Fx.load(1, gross: 1_000)]
        )
        XCTAssertTrue(hasError(issues(context), "no_pay_rule"))
    }

    func testPercentageAboveTheConfiguredCapIsBlocked() {
        let context = SettlementValidationContext(
            settlement: Fx.settlement(payRule: .percentOfGross(120)),
            loadLines: [Fx.load(1, gross: 1_000)],
            maximumDriverPercent: 100
        )
        XCTAssertTrue(hasError(issues(context), "percent_above_cap"))
    }

    func testNegativePercentageIsBlocked() {
        let context = SettlementValidationContext(
            settlement: Fx.settlement(payRule: .percentOfGross(-10)),
            loadLines: [Fx.load(1, gross: 1_000)]
        )
        XCTAssertTrue(hasError(issues(context), "negative_percent"))
    }

    func testHourlyWithoutHoursIsBlocked() {
        let context = SettlementValidationContext(
            settlement: Fx.settlement(payRule: .hourly(Money(cents: 2_800)), hours: nil),
            loadLines: [Fx.load(1, gross: 1_000)]
        )
        XCTAssertTrue(hasError(issues(context), "no_hours"))
    }

    // MARK: - Duplicate load payment

    func testALoadAlreadyPaidOnAnotherSettlementIsBlocked() {
        let priorSettlement = Fx.id(7_900)
        let loadId = Fx.id(1_001)
        let context = SettlementValidationContext(
            settlement: Fx.settlement(),
            loadLines: [Fx.load(1, gross: 3_500, loadId: loadId)],
            alreadySettledLoadIds: [loadId: priorSettlement],
            settlementNumberForSettlementId: [priorSettlement: "SP-2026-0007"]
        )
        let list = issues(context)
        XCTAssertTrue(hasError(list, "load_already_paid"))
        XCTAssertTrue(list.contains { $0.message.contains("SP-2026-0007") })
    }

    func testTheSameLoadTwiceOnOneSettlementIsBlocked() {
        let loadId = Fx.id(1_001)
        let context = SettlementValidationContext(
            settlement: Fx.settlement(),
            loadLines: [
                Fx.load(1, gross: 3_500, loadId: loadId),
                Fx.load(2, gross: 3_500, loadId: loadId)
            ]
        )
        XCTAssertTrue(hasError(issues(context), "duplicate_load_line"))
    }

    /// An approved correction is the escape hatch: allowed, but recorded.
    func testAnAdjustmentLineMayRepayASettledLoad() {
        let priorSettlement = Fx.id(7_900)
        let loadId = Fx.id(1_001)
        let context = SettlementValidationContext(
            settlement: Fx.settlement(),
            loadLines: [
                Fx.load(1, gross: 250, loadId: loadId,
                        isAdjustment: true, correctsSettlementId: priorSettlement)
            ],
            alreadySettledLoadIds: [loadId: priorSettlement],
            settlementNumberForSettlementId: [priorSettlement: "SP-2026-0007"]
        )
        let list = issues(context)
        XCTAssertFalse(hasError(list, "load_already_paid"))
        XCTAssertTrue(hasWarning(list, "load_adjustment"))
    }

    func testAnAdjustmentMustSayWhatItCorrects() {
        let context = SettlementValidationContext(
            settlement: Fx.settlement(),
            loadLines: [Fx.load(1, gross: 250, isAdjustment: true)]
        )
        XCTAssertTrue(hasError(issues(context), "adjustment_no_origin"))
    }

    // MARK: - Negative and zero amounts

    func testNegativeGrossIsBlockedUnlessItIsAnAdjustment() {
        var line = Fx.load(1, gross: 0)
        line.linehaul = Money(cents: -50_000)

        var context = SettlementValidationContext(
            settlement: Fx.settlement(), loadLines: [line]
        )
        XCTAssertTrue(hasError(issues(context), "negative_gross"))

        line.isAdjustment = true
        line.correctsSettlementId = Fx.id(7_900)
        context = SettlementValidationContext(settlement: Fx.settlement(), loadLines: [line])
        XCTAssertFalse(hasError(issues(context), "negative_gross"))
    }

    func testZeroGrossOnlyWarns() {
        let context = SettlementValidationContext(
            settlement: Fx.settlement(), loadLines: [Fx.load(1, gross: 0)]
        )
        let list = issues(context)
        XCTAssertTrue(hasWarning(list, "zero_gross"))
        XCTAssertTrue(SettlementValidator.canApprove(list))
    }

    func testNegativeMilesAreBlocked() {
        var line = Fx.load(1, gross: 1_000)
        line.loadedMiles = -10
        let context = SettlementValidationContext(
            settlement: Fx.settlement(), loadLines: [line]
        )
        XCTAssertTrue(hasError(issues(context), "negative_miles"))
    }

    // MARK: - Deductions

    func testBadSplitPercentageIsBlocked() {
        let context = SettlementValidationContext(
            settlement: Fx.settlement(),
            loadLines: [Fx.load(1, gross: 1_000)],
            deductions: [Fx.deduction(1, .repair, "Repair", 100,
                                      responsibility: .split, driverShare: 0)]
        )
        XCTAssertTrue(hasError(issues(context), "bad_split"))
    }

    func testDeductionWithoutADescriptionIsBlocked() {
        let context = SettlementValidationContext(
            settlement: Fx.settlement(),
            loadLines: [Fx.load(1, gross: 1_000)],
            deductions: [Fx.deduction(1, .fuel, "", 100)]
        )
        XCTAssertTrue(hasError(issues(context), "deduction_no_description"))
    }

    func testTheSameRecurringRuleTwiceIsBlocked() {
        let ruleId = Fx.id(6_001)
        let context = SettlementValidationContext(
            settlement: Fx.settlement(),
            loadLines: [Fx.load(1, gross: 1_000)],
            deductions: [
                Fx.deduction(1, .truckLease, "Truck", 1_300, recurringId: ruleId),
                Fx.deduction(2, .truckLease, "Truck", 1_300, recurringId: ruleId)
            ]
        )
        XCTAssertTrue(hasError(issues(context), "duplicate_recurring"))
    }

    // MARK: - Advances

    func testDeductingMoreThanTheOutstandingAdvanceIsBlocked() {
        let advance = Fx.advance(1, dollars: 300)
        let context = SettlementValidationContext(
            settlement: Fx.settlement(),
            loadLines: [Fx.load(1, gross: 5_000)],
            deductions: [Fx.deduction(1, .cashAdvance, "Advance recovery", 500,
                                      advanceId: advance.id)],
            advances: [advance]
        )
        XCTAssertTrue(hasError(issues(context), "advance_over_recovery"))
    }

    func testTwoLinesAgainstOneAdvanceAreCheckedTogether() {
        let advance = Fx.advance(1, dollars: 300)
        let context = SettlementValidationContext(
            settlement: Fx.settlement(),
            loadLines: [Fx.load(1, gross: 5_000)],
            deductions: [
                Fx.deduction(1, .cashAdvance, "Advance part 1", 200, advanceId: advance.id),
                Fx.deduction(2, .cashAdvance, "Advance part 2", 200, advanceId: advance.id)
            ],
            advances: [advance]
        )
        XCTAssertTrue(hasError(issues(context), "advance_over_recovery"),
                      "$400 total against a $300 balance must be caught")
    }

    func testRecoveringExactlyTheBalanceIsAllowed() {
        let advance = Fx.advance(1, dollars: 300)
        let context = SettlementValidationContext(
            settlement: Fx.settlement(),
            loadLines: [Fx.load(1, gross: 5_000)],
            deductions: [Fx.deduction(1, .cashAdvance, "Advance recovery", 300,
                                      advanceId: advance.id)],
            advances: [advance]
        )
        XCTAssertFalse(hasError(issues(context), "advance_over_recovery"))
    }

    // MARK: - Locked settlements

    func testAPaidSettlementCannotBeEdited() {
        let context = SettlementValidationContext(
            settlement: Fx.settlement(status: .paid),
            loadLines: [Fx.load(1, gross: 1_000)],
            result: SettlementCalculationEngine.calculate(
                Fx.input(loads: [Fx.load(1, gross: 1_000)])
            )
        )
        XCTAssertTrue(hasError(issues(context), "locked"))
    }

    func testAVoidedSettlementCannotBeEdited() {
        let context = SettlementValidationContext(
            settlement: Fx.settlement(status: .voided),
            loadLines: [Fx.load(1, gross: 1_000)],
            result: SettlementCalculationEngine.calculate(
                Fx.input(loads: [Fx.load(1, gross: 1_000)])
            )
        )
        XCTAssertTrue(hasError(issues(context), "locked"))
    }

    func testEstimatesCannotBeApproved() {
        let context = SettlementValidationContext(
            settlement: Fx.settlement(),
            loadLines: [Fx.load(1, gross: 1_000)],
            result: SettlementCalculationEngine.calculate(
                Fx.input(loads: [Fx.load(1, gross: 1_000)], isEstimate: true)
            )
        )
        XCTAssertTrue(hasWarning(issues(context), "is_estimate"))
    }

    // MARK: - Status transitions

    func testLegalTransitions() {
        XCTAssertNil(SettlementValidator.validateTransition(
            from: .draft, to: .readyForReview, issues: []))
        XCTAssertNil(SettlementValidator.validateTransition(
            from: .approved, to: .paid, issues: []))
        XCTAssertNil(SettlementValidator.validateTransition(
            from: .draft, to: .draft, issues: []))
    }

    func testIllegalTransitionIsRejected() {
        let issue = SettlementValidator.validateTransition(
            from: .draft, to: .paid, issues: [])
        XCTAssertEqual(issue?.code, "bad_transition")
    }

    func testReopeningAPaidSettlementNeedsAReason() {
        XCTAssertEqual(
            SettlementValidator.validateTransition(
                from: .paid, to: .approved, issues: [], reopenReason: nil)?.code,
            "reopen_no_reason"
        )
        XCTAssertNil(
            SettlementValidator.validateTransition(
                from: .paid, to: .approved, issues: [],
                reopenReason: "Fuel receipt arrived late")
        )
    }

    func testApprovalIsBlockedByAnyError() {
        let blocking = [SettlementValidationIssue.error("no_driver", "No driver")]
        XCTAssertEqual(
            SettlementValidator.validateTransition(
                from: .draft, to: .approved, issues: blocking)?.code,
            "no_driver"
        )
    }

    func testApprovalIsNotBlockedByWarnings() {
        let warnings = [SettlementValidationIssue.warning("zero_gross", "Zero gross")]
        XCTAssertNil(SettlementValidator.validateTransition(
            from: .draft, to: .approved, issues: warnings))
    }

    // MARK: - Reconciliation guard

    func testAResultThatDoesNotReconcileBlocksApproval() {
        let good = SettlementCalculationEngine.calculate(
            Fx.input(loads: [Fx.load(1, gross: 5_000)])
        )
        let context = SettlementValidationContext(
            settlement: Fx.settlement(),
            loadLines: [Fx.load(1, gross: 5_000)],
            result: good
        )
        XCTAssertFalse(hasError(issues(context), "does_not_reconcile"))
        XCTAssertTrue(SettlementValidator.canApprove(issues(context)))
    }

    // MARK: - A clean settlement

    func testACleanSettlementHasNoErrors() {
        let loads = [Fx.load(1, gross: 3_500), Fx.load(2, gross: 3_750, sortOrder: 1)]
        let deductions = [Fx.deduction(1, .fuel, "Fuel", 1_180)]
        let result = SettlementCalculationEngine.calculate(
            Fx.input(loads: loads, deductions: deductions)
        )
        let context = SettlementValidationContext(
            settlement: Fx.settlement(),
            loadLines: loads,
            deductions: deductions,
            result: result,
            existingSettlementNumbers: ["SP-2026-0002"]
        )
        let list = issues(context)
        XCTAssertTrue(SettlementValidator.errors(list).isEmpty,
                      "unexpected errors: \(SettlementValidator.errors(list).map(\.message))")
    }
}
