import XCTest
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

// MARK: - Settlement numbers

@MainActor
final class SettlementNumberServiceTests: XCTestCase {

    func testFirstNumberOfTheYear() {
        XCTAssertEqual(
            SettlementNumberService.nextNumber(existing: [], year: 2026),
            "SP-2026-0001"
        )
    }

    func testIncrementsPastTheHighestExisting() {
        XCTAssertEqual(
            SettlementNumberService.nextNumber(
                existing: ["SP-2026-0001", "SP-2026-0007", "SP-2026-0003"], year: 2026
            ),
            "SP-2026-0008"
        )
    }

    func testSequenceRestartsEachYear() {
        XCTAssertEqual(
            SettlementNumberService.nextNumber(
                existing: ["SP-2025-0042"], year: 2026
            ),
            "SP-2026-0001"
        )
    }

    func testOtherPrefixesDoNotAffectTheSequence() {
        XCTAssertEqual(
            SettlementNumberService.nextNumber(
                existing: ["HEE-2026-0099"], year: 2026, prefix: "SP"
            ),
            "SP-2026-0001"
        )
    }

    func testGarbageNumbersAreIgnoredNotFatal() {
        XCTAssertEqual(
            SettlementNumberService.nextNumber(
                existing: ["", "not-a-number", "SP-2026", "SP-2026-0004"], year: 2026
            ),
            "SP-2026-0005"
        )
    }

    func testParse() {
        let parsed = SettlementNumberService.parse("SP-2026-0042")
        XCTAssertEqual(parsed?.prefix, "SP")
        XCTAssertEqual(parsed?.year, 2026)
        XCTAssertEqual(parsed?.sequence, 42)
        XCTAssertNil(SettlementNumberService.parse("nonsense"))
    }

    func testDuplicateDetectionIsCaseAndSpaceInsensitive() {
        XCTAssertTrue(SettlementNumberService.isDuplicate(
            " sp-2026-0042 ", existing: ["SP-2026-0042"]))
        XCTAssertFalse(SettlementNumberService.isDuplicate(
            "SP-2026-0043", existing: ["SP-2026-0042"]))
    }

    func testASettlementIsNotADuplicateOfItsOwnNumber() {
        let id = Fx.id(7_000)
        XCTAssertFalse(SettlementNumberService.isDuplicate(
            "SP-2026-0042",
            existing: ["SP-2026-0042"],
            excluding: id,
            existingBySettlement: [id: "SP-2026-0042"]
        ))
    }

    func testPrefixSuggestionFromACompanyName() {
        XCTAssertEqual(SettlementNumberService.suggestedPrefix(companyName: "Sacred Pathway LLC"), "SP")
        XCTAssertEqual(SettlementNumberService.suggestedPrefix(companyName: "Hinton Eagle Express LLC"), "HEE")
        XCTAssertEqual(SettlementNumberService.suggestedPrefix(companyName: nil), "SP")
        XCTAssertEqual(SettlementNumberService.suggestedPrefix(companyName: "  "), "SP")
        XCTAssertEqual(SettlementNumberService.suggestedPrefix(companyName: "The Co"), "SP")
    }

    func testPrefixIsSanitised() {
        XCTAssertEqual(SettlementNumberService.sanitise("s p!"), "SP")
        XCTAssertEqual(SettlementNumberService.sanitise(""), "SP")
        XCTAssertEqual(SettlementNumberService.sanitise("ABCDEFGHIJ"), "ABCDEF")
    }
}

// MARK: - Audit trail

@MainActor
final class SettlementAuditServiceTests: XCTestCase {

    private let actor = SettlementActor(userId: Fx.id(9_001), name: "Test Operator")
    private let settlementId = Fx.id(7_000)

    func testStatusChangeRecordsBothValues() {
        let event = SettlementAuditService.statusChanged(
            settlementId: settlementId, profileId: Fx.profileId, actor: actor,
            from: .approved, to: .paid, netPay: Fx.money(1_595)
        )
        XCTAssertEqual(event.action, .markedPaid)
        XCTAssertEqual(event.previousValue, "approved")
        XCTAssertEqual(event.newValue, "paid")
        XCTAssertTrue(event.summary.contains("$1,595.00"))
        XCTAssertEqual(event.actorUserId, actor.userId)
    }

    func testReopeningAPaidSettlementIsRecordedAsAReopen() {
        let event = SettlementAuditService.statusChanged(
            settlementId: settlementId, profileId: Fx.profileId, actor: actor,
            from: .paid, to: .draft, netPay: nil, reason: "Late fuel receipt"
        )
        XCTAssertEqual(event.action, .reopened)
        XCTAssertTrue(event.summary.contains("Late fuel receipt"))
    }

    func testPayRuleChangeCapturesBeforeAndAfter() {
        let event = SettlementAuditService.payRuleChanged(
            settlementId: settlementId, profileId: Fx.profileId, actor: actor,
            from: .percentOfGross(70), to: .percentOfGross(65)
        )
        XCTAssertEqual(event.previousValue, "70% of gross")
        XCTAssertEqual(event.newValue, "65% of gross")
        XCTAssertEqual(event.fieldName, "pay_rule")
    }

    func testAdvanceRecoveryRecordsTheBalanceMovement() {
        let plan = PlannedAdvanceRecovery(
            advanceId: Fx.id(4_001), advanceType: .cash,
            advanceDescription: "Test Cash Advance 1",
            outstandingBefore: Fx.money(500), amount: Fx.money(300)
        )
        let event = SettlementAuditService.advanceRepaymentApplied(
            settlementId: settlementId, profileId: Fx.profileId, actor: actor, plan: plan
        )
        XCTAssertEqual(event.previousValue, "$500.00")
        XCTAssertEqual(event.newValue, "$200.00")
    }

    func testRecalculationWithNoChangeProducesNoEvent() {
        XCTAssertNil(SettlementAuditService.recalculated(
            settlementId: settlementId, profileId: Fx.profileId, actor: actor,
            previousNet: Fx.money(1_595), newNet: Fx.money(1_595),
            engineVersion: SettlementCalculationEngine.engineVersion
        ))
    }

    func testRecalculationThatMovesNetPayIsRecorded() {
        let event = SettlementAuditService.recalculated(
            settlementId: settlementId, profileId: Fx.profileId, actor: actor,
            previousNet: Fx.money(1_595), newNet: Fx.money(1_345),
            engineVersion: SettlementCalculationEngine.engineVersion
        )
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.previousValue, "$1,595.00")
        XCTAssertEqual(event?.newValue, "$1,345.00")
    }

    func testDiffProducesOneEventPerChangedField() {
        let before = SettlementSnapshot(
            settlementNumber: "SP-2026-0001",
            grossLoadRevenue: Fx.money(7_250),
            driverEarnings: Fx.money(5_075),
            totalAdditions: .zero,
            totalDeductions: Fx.money(3_480),
            netPay: Fx.money(1_595)
        )
        var after = before
        after.totalDeductions = Fx.money(3_230)
        after.netPay = Fx.money(1_845)

        let events = SettlementAuditService.diffEvents(
            settlementId: settlementId, profileId: Fx.profileId, actor: actor,
            before: before, after: after
        )
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.contains { $0.fieldName == "total_deductions" })
        XCTAssertTrue(events.contains { $0.fieldName == "net_pay" })
    }

    func testDiffOfIdenticalSnapshotsIsEmpty() {
        let snapshot = SettlementSnapshot(netPay: Fx.money(1_595))
        XCTAssertTrue(SettlementAuditService.diffEvents(
            settlementId: settlementId, profileId: Fx.profileId, actor: actor,
            before: snapshot, after: snapshot
        ).isEmpty)
    }

    func testEventsSortNewestFirst() {
        let old = SettlementAuditService.event(
            .created, settlementId: settlementId, profileId: Fx.profileId,
            actor: actor, summary: "old", timestamp: Fx.date(2026, 9, 1))
        let new = SettlementAuditService.event(
            .approved, settlementId: settlementId, profileId: Fx.profileId,
            actor: actor, summary: "new", timestamp: Fx.date(2026, 9, 10))
        XCTAssertEqual(SettlementAuditService.sorted([old, new]).map(\.summary),
                       ["new", "old"])
    }
}

// MARK: - Settlement record

@MainActor
final class SettlementRecordTests: XCTestCase {

    func testStatusRoundTrips() {
        var settlement = Fx.settlement(status: .draft)
        XCTAssertEqual(settlement.settlementStatus, .draft)
        settlement.settlementStatus = .approved
        XCTAssertEqual(settlement.status, "approved")
        XCTAssertFalse(settlement.isLocked)
        settlement.settlementStatus = .paid
        XCTAssertTrue(settlement.isLocked)
    }

    func testUnknownStatusStringReadsAsDraftRatherThanLocking() {
        var settlement = Fx.settlement()
        settlement.status = "something_from_the_future"
        XCTAssertEqual(settlement.settlementStatus, .draft)
        XCTAssertFalse(settlement.isLocked)
    }

    func testApplyingAResultFillsBothNewAndLegacyColumns() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                loads: [Fx.load(1, gross: 3_500), Fx.load(2, gross: 3_750, sortOrder: 1)],
                deductions: [Fx.deduction(1, .fuel, "Fuel", 1_180)]
            )
        )
        var settlement = Fx.settlement()
        settlement.apply(result, payRule: .percentOfGross(70),
                         payOnGrossRevenue: true, settlementType: .companyDriver)

        // New decimal columns
        XCTAssertMoney(settlement.grossLoadRevenue ?? .zero, 7_250)
        XCTAssertMoney(settlement.totalDriverEarnings ?? .zero, 5_075)
        XCTAssertMoney(settlement.totalDeductions ?? .zero, 1_180)

        // Legacy Double columns, kept in step
        XCTAssertEqual(settlement.totalRevenue, 7_250)
        XCTAssertEqual(settlement.netPay, 3_895)
        XCTAssertEqual(settlement.driverPayPercentage, 70)
        XCTAssertEqual(settlement.engineVersion, SettlementCalculationEngine.engineVersion)
        XCTAssertNotNil(settlement.updatedAt)
    }

    func testNetPayMoneyFallsBackToTheNewTotals() {
        var settlement = Fx.settlement()
        settlement.netPay = nil
        settlement.totalDriverEarnings = Fx.money(5_075)
        settlement.totalAdditions = Fx.money(400)
        settlement.totalDeductions = Fx.money(3_480)
        XCTAssertMoney(settlement.netPayMoney, 1_995)
    }

    func testEffectivePayRuleFallsBackToTheLegacyPercentageColumn() {
        var settlement = Fx.settlement(payRule: .none)
        settlement.payRule = nil
        settlement.driverPayPercentage = 65
        XCTAssertEqual(settlement.effectivePayRule.summary, "65% of gross")
    }

    /// A row written by an older build has none of the new keys and must still
    /// decode — this is the backward-compatibility guarantee.
    func testDecodesALegacyRowWithoutTheNewColumns() throws {
        let legacy = """
        {
          "id": "\(Fx.id(7_000).uuidString)",
          "profile_id": "\(Fx.profileId.uuidString)",
          "driver_id": "\(Fx.driverId.uuidString)",
          "settlement_period_start": "2026-09-07",
          "settlement_period_end": "2026-09-13",
          "total_revenue": 7250.00,
          "net_pay": 1595.00,
          "status": "draft",
          "created_at": "2026-09-13T12:00:00.000Z"
        }
        """
        let settlement = try JSONDecoder().decode(Settlement.self, from: Data(legacy.utf8))
        XCTAssertEqual(settlement.totalRevenue, 7_250)
        XCTAssertNil(settlement.settlementNumber)
        XCTAssertNil(settlement.payRule)
        XCTAssertEqual(settlement.settlementStatus, .draft)
        XCTAssertMoney(settlement.netPayMoney, 1_595)
        XCTAssertEqual(settlement.effectiveSettlementType, .companyDriver)
    }

    func testRoundTripsThroughJSONWithEveryNewField() throws {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(loads: [Fx.load(1, gross: 5_000)])
        )
        var original = Fx.settlement()
        original.apply(result, payRule: .percentOfGross(70),
                       payOnGrossRevenue: true, settlementType: .leaseOperator)
        original.paymentReference = "ACH-99812"
        original.notes = "Test settlement"

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settlement.self, from: data)

        XCTAssertEqual(decoded.settlementNumber, original.settlementNumber)
        XCTAssertEqual(decoded.settlementType, .leaseOperator)
        XCTAssertEqual(decoded.payRule, original.payRule)
        XCTAssertEqual(decoded.paymentReference, "ACH-99812")
        XCTAssertMoney(decoded.grossLoadRevenue ?? .zero, 5_000)
        XCTAssertMoney(decoded.totalDriverEarnings ?? .zero, 3_500)
        XCTAssertEqual(decoded.engineVersion, SettlementCalculationEngine.engineVersion)
    }

    func testPayRuleRoundTripsThroughJSON() throws {
        let rule = PayRule(components: [
            PayComponent(kind: .percentOfGross, percent: 70),
            PayComponent(kind: .perMile, rate: Money(cents: 5), mileBasis: .total)
        ])
        let decoded = try JSONDecoder().decode(
            PayRule.self, from: try JSONEncoder().encode(rule)
        )
        XCTAssertEqual(decoded, rule)
        XCTAssertEqual(decoded.summary, "70% of gross + $0.05/mi all miles")
    }

    func testStatusTransitionTable() {
        XCTAssertTrue(SettlementStatus.draft.allowedTransitions.contains(.approved))
        XCTAssertFalse(SettlementStatus.draft.allowedTransitions.contains(.paid))
        XCTAssertTrue(SettlementStatus.approved.allowedTransitions.contains(.paid))
        XCTAssertTrue(SettlementStatus.paid.isLocked)
        XCTAssertTrue(SettlementStatus.voided.isLocked)
        XCTAssertFalse(SettlementStatus.approved.isLocked)
        XCTAssertTrue(SettlementStatus.approved.isFinancialRecord)
        XCTAssertFalse(SettlementStatus.draft.isFinancialRecord)
    }
}
