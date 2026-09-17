import XCTest
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

@MainActor
final class RecurringDeductionServiceTests: XCTestCase {

    private func materialise(
        _ rules: [RecurringDeduction],
        gross: Money = Fx.money(7_250),
        lastApplied: [UUID: Date] = [:],
        already: Set<UUID> = []
    ) -> [SettlementDeduction] {
        RecurringDeductionService.materialise(
            rules: rules,
            driverId: Fx.driverId,
            profileId: Fx.profileId,
            settlementId: Fx.id(7_001),
            periodStart: Fx.periodStart,
            periodEnd: Fx.periodEnd,
            settlementGross: gross,
            lastAppliedByRule: lastApplied,
            alreadyOnSettlement: already
        )
    }

    // MARK: - Basic materialising

    func testActiveRulesBecomeDeductionLines() {
        let rules = [
            Fx.recurring(1, .truckLease, "Weekly truck payment", dollars: 1_300),
            Fx.recurring(2, .insurance, "Insurance", dollars: 450)
        ]
        let out = materialise(rules)
        XCTAssertEqual(out.count, 2)
        XCTAssertMoney(Money.sum(out.map(\.amount)), 1_750)
        XCTAssertTrue(out.allSatisfy { $0.recurringDeductionId != nil })
        XCTAssertTrue(out.allSatisfy { $0.settlementId == Fx.id(7_001) })
    }

    func testInactiveRulesAreSkipped() {
        let out = materialise([Fx.recurring(1, .truckLease, "Truck", dollars: 1_300, active: false)])
        XCTAssertTrue(out.isEmpty)
    }

    func testAnotherDriversRulesAreSkipped() {
        let out = materialise([
            Fx.recurring(1, .truckLease, "Truck", dollars: 1_300, driverId: Fx.driver2Id)
        ])
        XCTAssertTrue(out.isEmpty)
    }

    func testZeroAmountRulesProduceNoLine() {
        let out = materialise([Fx.recurring(1, .other, "Placeholder", dollars: 0)])
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - Effective dates

    func testRuleStartingAfterThePeriodIsNotApplied() {
        let out = materialise([
            Fx.recurring(1, .truckLease, "Truck", dollars: 1_300,
                         start: Fx.date(2026, 10, 1))
        ])
        XCTAssertTrue(out.isEmpty)
    }

    func testRuleEndedBeforeThePeriodIsNotApplied() {
        let out = materialise([
            Fx.recurring(1, .truckLease, "Truck", dollars: 1_300,
                         start: Fx.date(2026, 1, 1), end: Fx.date(2026, 8, 1))
        ])
        XCTAssertTrue(out.isEmpty)
    }

    func testRuleEndingInsideThePeriodStillApplies() {
        let out = materialise([
            Fx.recurring(1, .truckLease, "Truck", dollars: 1_300,
                         start: Fx.date(2026, 1, 1), end: Fx.date(2026, 9, 10))
        ])
        XCTAssertEqual(out.count, 1)
    }

    // MARK: - Frequency

    func testEverySettlementRuleAlwaysApplies() {
        let rule = Fx.recurring(1, .truckLease, "Truck", dollars: 1_300,
                                frequency: .everySettlement)
        let out = materialise([rule], lastApplied: [rule.id: Fx.date(2026, 9, 6)])
        XCTAssertEqual(out.count, 1)
    }

    func testMonthlyRuleIsNotAppliedTwiceInOneMonth() {
        let rule = Fx.recurring(1, .permits, "Permits", dollars: 90, frequency: .monthly)
        let out = materialise([rule], lastApplied: [rule.id: Fx.date(2026, 9, 1)])
        XCTAssertTrue(out.isEmpty, "only 6 days since the last charge")
    }

    func testMonthlyRuleAppliesOnceAMonthHasPassed() {
        let rule = Fx.recurring(1, .permits, "Permits", dollars: 90, frequency: .monthly)
        let out = materialise([rule], lastApplied: [rule.id: Fx.date(2026, 8, 5)])
        XCTAssertEqual(out.count, 1)
    }

    func testRuleNeverAppliedBeforeIsDue() {
        let rule = Fx.recurring(1, .permits, "Permits", dollars: 90, frequency: .quarterly)
        XCTAssertEqual(materialise([rule]).count, 1)
    }

    func testBiweeklyRuleRespectsItsWindow() {
        let rule = Fx.recurring(1, .equipmentCharge, "ELD", dollars: 40, frequency: .biweekly)
        XCTAssertTrue(materialise([rule], lastApplied: [rule.id: Fx.date(2026, 9, 1)]).isEmpty)
        XCTAssertEqual(materialise([rule], lastApplied: [rule.id: Fx.date(2026, 8, 24)]).count, 1)
    }

    // MARK: - Percent-based rules

    func testPercentOfGrossRuleResolvesAgainstTheSettlementGross() {
        let out = materialise([
            Fx.recurring(1, .maintenanceReserve, "Maintenance reserve",
                         percentOfGross: 2)
        ], gross: Fx.money(7_250))
        XCTAssertEqual(out.count, 1)
        XCTAssertMoney(out[0].amount, 145, 0, "2% of $7,250")
        XCTAssertEqual(out[0].notes, "Recurring · 2% of gross")
    }

    // MARK: - Double-charge protection

    func testARuleAlreadyOnTheSettlementIsNotAddedAgain() {
        let rule = Fx.recurring(1, .truckLease, "Truck", dollars: 1_300)
        let out = materialise([rule], already: [rule.id])
        XCTAssertTrue(out.isEmpty, "re-drafting must not double-charge the driver")
    }

    func testMaterialisingTwiceWithoutTheGuardWouldDuplicate() {
        // Documents exactly why `alreadyOnSettlement` exists.
        let rule = Fx.recurring(1, .truckLease, "Truck", dollars: 1_300)
        let first = materialise([rule])
        let second = materialise([rule], already: Set(first.compactMap(\.recurringDeductionId)))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 0)
    }

    // MARK: - Responsibility carries through

    func testResponsibilityAndSplitCarryFromTheRule() {
        let out = materialise([
            Fx.recurring(1, .repair, "Shared tire program", dollars: 200,
                         responsibility: .split, driverShare: 50)
        ])
        XCTAssertEqual(out[0].responsibility, .split)
        XCTAssertMoney(out[0].driverAmount, 100)
        XCTAssertMoney(out[0].companyAmount, 100)
    }

    // MARK: - History

    func testLastAppliedOnlyCountsFinancialRecords() {
        let ruleId = Fx.id(6_001)
        let draftSettlement = Fx.id(7_001)
        let paidSettlement = Fx.id(7_002)

        var draftDeduction = Fx.deduction(1, .permits, "Permits", 90, recurringId: ruleId)
        draftDeduction.settlementId = draftSettlement
        var paidDeduction = Fx.deduction(2, .permits, "Permits", 90, recurringId: ruleId)
        paidDeduction.settlementId = paidSettlement

        let map = RecurringDeductionService.lastAppliedDates(
            deductions: [draftDeduction, paidDeduction],
            settlementPeriodStarts: [
                draftSettlement: Fx.date(2026, 9, 7),
                paidSettlement: Fx.date(2026, 8, 3)
            ],
            settlementStatuses: [draftSettlement: .draft, paidSettlement: .paid]
        )
        XCTAssertEqual(map[ruleId], Fx.date(2026, 8, 3),
                       "an abandoned draft must not push the next charge out")
    }

    func testLastAppliedTakesTheMostRecentRecord() {
        let ruleId = Fx.id(6_001)
        let s1 = Fx.id(7_001), s2 = Fx.id(7_002)
        var d1 = Fx.deduction(1, .permits, "Permits", 90, recurringId: ruleId); d1.settlementId = s1
        var d2 = Fx.deduction(2, .permits, "Permits", 90, recurringId: ruleId); d2.settlementId = s2

        let map = RecurringDeductionService.lastAppliedDates(
            deductions: [d1, d2],
            settlementPeriodStarts: [s1: Fx.date(2026, 7, 6), s2: Fx.date(2026, 8, 3)],
            settlementStatuses: [s1: .paid, s2: .approved]
        )
        XCTAssertEqual(map[ruleId], Fx.date(2026, 8, 3))
    }

    // MARK: - Validation

    func testValidationCatchesBadRules() {
        var rule = Fx.recurring(1, .truckLease, "", dollars: 0)
        XCTAssertTrue(RecurringDeductionService.validate(rule)
            .contains { $0.contains("description") })

        rule = Fx.recurring(1, .truckLease, "Truck", dollars: 0)
        XCTAssertTrue(RecurringDeductionService.validate(rule)
            .contains { $0.contains("greater than $0.00") })

        rule = Fx.recurring(1, .truckLease, "Truck", percentOfGross: 150)
        XCTAssertTrue(RecurringDeductionService.validate(rule)
            .contains { $0.contains("cannot exceed 100%") })

        rule = Fx.recurring(1, .truckLease, "Truck", dollars: 100,
                            start: Fx.date(2026, 9, 1), end: Fx.date(2026, 8, 1))
        XCTAssertTrue(RecurringDeductionService.validate(rule)
            .contains { $0.contains("End date") })

        rule = Fx.recurring(1, .repair, "Repair", dollars: 100,
                            responsibility: .split, driverShare: 0)
        XCTAssertTrue(RecurringDeductionService.validate(rule)
            .contains { $0.contains("driver share") })
    }

    /// Advances have a balance cap; a recurring rule does not. Routing an
    /// advance through recurring would let it over-recover.
    func testAdvanceCategoriesAreRejectedAsRecurringRules() {
        let rule = Fx.recurring(1, .cashAdvance, "Weekly advance", dollars: 200)
        XCTAssertTrue(RecurringDeductionService.validate(rule)
            .contains { $0.contains("Advances are tracked separately") })
    }

    func testAGoodRuleHasNoProblems() {
        let rule = Fx.recurring(1, .truckLease, "Weekly truck payment", dollars: 1_300)
        XCTAssertTrue(RecurringDeductionService.validate(rule).isEmpty)
    }
}
