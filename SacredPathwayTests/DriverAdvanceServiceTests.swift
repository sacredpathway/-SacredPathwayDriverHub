import XCTest
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

/// An advance is company money in a driver's pocket. The one rule that must
/// never break: you cannot take back more than is owed.
@MainActor
final class DriverAdvanceServiceTests: XCTestCase {

    // MARK: - Balances

    func testOutstandingIsAmountMinusLedger() {
        let advance = Fx.advance(1, dollars: 1_000)
        let repayments = [Fx.repayment(1, advanceId: advance.id, dollars: 300)]
        XCTAssertMoney(
            DriverAdvanceService.outstanding(advance: advance, repayments: repayments),
            700
        )
    }

    func testOutstandingIgnoresOtherAdvancesRepayments() {
        let a = Fx.advance(1, dollars: 1_000)
        let b = Fx.advance(2, dollars: 500)
        let repayments = [Fx.repayment(1, advanceId: b.id, dollars: 500)]
        XCTAssertMoney(DriverAdvanceService.outstanding(advance: a, repayments: repayments), 1_000)
        XCTAssertMoney(DriverAdvanceService.outstanding(advance: b, repayments: repayments), 0)
    }

    func testStaleCachedRecoveredAmountIsRebuiltFromTheLedger() {
        // Row claims $900 recovered, ledger says $300. The ledger wins.
        let advance = Fx.advance(1, dollars: 1_000, recovered: 900)
        let repayments = [Fx.repayment(1, advanceId: advance.id, dollars: 300)]
        let fixed = DriverAdvanceService.reconciled(advance: advance, repayments: repayments)
        XCTAssertMoney(fixed.recoveredAmount, 300)
        XCTAssertMoney(fixed.outstandingBalance, 700)
        XCTAssertFalse(fixed.isClosed)
    }

    func testOverRecoveredLedgerNeverProducesANegativeBalance() {
        let advance = Fx.advance(1, dollars: 500)
        let repayments = [Fx.repayment(1, advanceId: advance.id, dollars: 800)]
        let fixed = DriverAdvanceService.reconciled(advance: advance, repayments: repayments)
        XCTAssertMoney(fixed.outstandingBalance, 0)
        XCTAssertTrue(fixed.isClosed)
    }

    func testTotalOutstandingAcrossAdvances() {
        let a = Fx.advance(1, dollars: 1_000)
        let b = Fx.advance(2, dollars: 500)
        let repayments = [Fx.repayment(1, advanceId: a.id, dollars: 250)]
        XCTAssertMoney(
            DriverAdvanceService.totalOutstanding(
                advances: [a, b], repayments: repayments, driverId: Fx.driverId
            ),
            1_250
        )
    }

    // MARK: - Full repayment

    func testFullRecoveryClearsTheBalance() {
        let advance = Fx.advance(1, dollars: 300)
        let plans = DriverAdvanceService.planRecoveries(
            advances: [advance], repayments: [], driverId: Fx.driverId, policy: .full
        )
        XCTAssertEqual(plans.count, 1)
        XCTAssertMoney(plans[0].amount, 300)
        XCTAssertMoney(plans[0].outstandingAfter, 0)
        XCTAssertTrue(plans[0].clearsAdvance)
    }

    func testFullRecoverySpansMultipleAdvancesOldestFirst() {
        let older = Fx.advance(1, dollars: 400, on: 1)
        let newer = Fx.advance(2, dollars: 600, on: 5)
        let plans = DriverAdvanceService.planRecoveries(
            advances: [newer, older], repayments: [], driverId: Fx.driverId, policy: .full
        )
        XCTAssertEqual(plans.map(\.advanceId), [older.id, newer.id])
        XCTAssertMoney(Money.sum(plans.map(\.amount)), 1_000)
    }

    // MARK: - Partial repayment

    func testPartialRecoveryLeavesABalance() {
        let advance = Fx.advance(1, dollars: 1_000)
        let plans = DriverAdvanceService.planRecoveries(
            advances: [advance], repayments: [], driverId: Fx.driverId,
            policy: .fixedPerSettlement, requestedAmount: Fx.money(250)
        )
        XCTAssertMoney(plans[0].amount, 250)
        XCTAssertMoney(plans[0].outstandingAfter, 750)
        XCTAssertFalse(plans[0].clearsAdvance)
    }

    func testPartialRecoveryOverTwoSettlementsClearsExactly() {
        let advance = Fx.advance(1, dollars: 500)

        let first = DriverAdvanceService.planRecoveries(
            advances: [advance], repayments: [], driverId: Fx.driverId,
            policy: .fixedPerSettlement, requestedAmount: Fx.money(300)
        )
        let ledger = DriverAdvanceService.repaymentRecords(
            for: first,
            deductions: DriverAdvanceService.deductions(
                for: first, profileId: Fx.profileId, settlementId: Fx.id(7_001),
                date: Fx.periodEnd
            ),
            profileId: Fx.profileId, settlementId: Fx.id(7_001), date: Fx.periodEnd
        )

        let second = DriverAdvanceService.planRecoveries(
            advances: [advance], repayments: ledger, driverId: Fx.driverId,
            policy: .fixedPerSettlement, requestedAmount: Fx.money(300)
        )
        // Only $200 is left — the request is capped, not honoured in full.
        XCTAssertMoney(second[0].amount, 200)
        XCTAssertTrue(second[0].clearsAdvance)
    }

    // MARK: - The cap

    func testRequestLargerThanTheBalanceIsCapped() {
        let advance = Fx.advance(1, dollars: 300)
        let plans = DriverAdvanceService.planRecoveries(
            advances: [advance], repayments: [], driverId: Fx.driverId,
            policy: .full, requestedAmount: Fx.money(5_000)
        )
        XCTAssertMoney(plans[0].amount, 300, 0, "never more than the outstanding balance")
    }

    func testClosedAdvancesAreNotRecoveredAgain() {
        let advance = Fx.advance(1, dollars: 300)
        let ledger = [Fx.repayment(1, advanceId: advance.id, dollars: 300)]
        let plans = DriverAdvanceService.planRecoveries(
            advances: [advance], repayments: ledger, driverId: Fx.driverId, policy: .full
        )
        XCTAssertTrue(plans.isEmpty)
    }

    func testManualPolicyPlansNothing() {
        let plans = DriverAdvanceService.planRecoveries(
            advances: [Fx.advance(1, dollars: 300)], repayments: [],
            driverId: Fx.driverId, policy: .manual
        )
        XCTAssertTrue(plans.isEmpty)
    }

    func testAnotherDriversAdvanceIsNeverTouched() {
        var otherDriverAdvance = Fx.advance(1, dollars: 500)
        otherDriverAdvance.driverId = Fx.driver2Id
        let plans = DriverAdvanceService.planRecoveries(
            advances: [otherDriverAdvance], repayments: [],
            driverId: Fx.driverId, policy: .full
        )
        XCTAssertTrue(plans.isEmpty)
    }

    // MARK: - Materialising

    func testDeductionsCarryTheAdvanceLinkAndDriverResponsibility() {
        let advance = Fx.advance(1, type: .fuel, dollars: 400)
        let plans = DriverAdvanceService.planRecoveries(
            advances: [advance], repayments: [], driverId: Fx.driverId, policy: .full
        )
        let deductions = DriverAdvanceService.deductions(
            for: plans, profileId: Fx.profileId, settlementId: Fx.id(7_001), date: Fx.periodEnd
        )
        XCTAssertEqual(deductions.count, 1)
        XCTAssertEqual(deductions[0].advanceId, advance.id)
        XCTAssertEqual(deductions[0].category, .fuelAdvance)
        XCTAssertEqual(deductions[0].responsibility, .driver)
        XCTAssertMoney(deductions[0].driverAmount, 400)
        XCTAssertEqual(deductions[0].notes, "Advance paid in full")
    }

    func testRepaymentRecordsLinkBackToTheDeduction() {
        let advance = Fx.advance(1, dollars: 400)
        let plans = DriverAdvanceService.planRecoveries(
            advances: [advance], repayments: [], driverId: Fx.driverId,
            policy: .fixedPerSettlement, requestedAmount: Fx.money(150)
        )
        let deductions = DriverAdvanceService.deductions(
            for: plans, profileId: Fx.profileId, settlementId: Fx.id(7_001), date: Fx.periodEnd
        )
        let records = DriverAdvanceService.repaymentRecords(
            for: plans, deductions: deductions, profileId: Fx.profileId,
            settlementId: Fx.id(7_001), date: Fx.periodEnd
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].deductionId, deductions[0].id)
        XCTAssertEqual(records[0].settlementId, Fx.id(7_001))
        XCTAssertMoney(records[0].amount, 150)
    }

    // MARK: - Manual entry validation

    func testManualRecoveryAboveTheBalanceIsRejected() {
        let advance = Fx.advance(1, dollars: 300)
        let problem = DriverAdvanceService.validateManualRecovery(
            amount: Fx.money(500), advance: advance, repayments: []
        )
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("exceeds") == true)
    }

    func testManualRecoveryWithinTheBalanceIsAccepted() {
        XCTAssertNil(
            DriverAdvanceService.validateManualRecovery(
                amount: Fx.money(300), advance: Fx.advance(1, dollars: 300), repayments: []
            )
        )
    }

    func testZeroOrNegativeManualRecoveryIsRejected() {
        let advance = Fx.advance(1, dollars: 300)
        XCTAssertNotNil(DriverAdvanceService.validateManualRecovery(
            amount: .zero, advance: advance, repayments: []))
        XCTAssertNotNil(DriverAdvanceService.validateManualRecovery(
            amount: Money(cents: -100), advance: advance, repayments: []))
    }

    /// Editing the settlement that already recorded a recovery must not count
    /// its own repayment against itself.
    func testEditingASettlementExcludesItsOwnRepayment() {
        let advance = Fx.advance(1, dollars: 300)
        let settlementId = Fx.id(7_001)
        let ledger = [Fx.repayment(1, advanceId: advance.id, dollars: 300,
                                   settlementId: settlementId)]

        XCTAssertNotNil(
            DriverAdvanceService.validateManualRecovery(
                amount: Fx.money(300), advance: advance, repayments: ledger
            ),
            "without the exclusion the balance reads $0 and the edit is blocked"
        )
        XCTAssertNil(
            DriverAdvanceService.validateManualRecovery(
                amount: Fx.money(300), advance: advance, repayments: ledger,
                excludingSettlementId: settlementId
            ),
            "with the exclusion the same $300 is still valid"
        )
    }
}
