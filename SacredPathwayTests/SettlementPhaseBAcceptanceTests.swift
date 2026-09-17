import XCTest
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

// =============================================================================
//  Phase B acceptance — the brief's final acceptance test, end to end
// -----------------------------------------------------------------------------
//  Real `Load` records → settlement wizard draft → save → local database file
//  → reload → approve → paid → statement document → statement HTML (the PDF
//  source). Every layer must print exactly $1,595.00.
//
//  All data is isolated test data ("Test Driver", TEST-n loads) written to a
//  throw-away temp folder that is deleted afterwards.
// =============================================================================

final class SettlementPhaseBAcceptanceTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sph-settlement-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testAcceptance1_EngineDatabaseStatementAndHTMLAgreeOn1595() throws {
        let store = SettlementLocalStore(directory: tempDir)
        var ledger = try store.load()
        XCTAssertTrue(ledger.settlements.isEmpty)

        // Test Driver, Monday–Sunday, two completed loads.
        let loads = [
            Fx.opLoad(1, gross: 3_500, pickupDay: 7, deliveryDay: 8, miles: 620, empty: 40),
            Fx.opLoad(2, gross: 3_750, pickupDay: 10, deliveryDay: 12, miles: 710, empty: 30)
        ]
        // Standing deductions come from recurring rules, the one-offs are added
        // on the review screen — exactly as a user would.
        ledger.recurringDeductions = [
            Fx.recurring(1, .insurance, "Insurance", dollars: 450),
            Fx.recurring(2, .truckLease, "Truck Payment", dollars: 1_300)
        ]
        ledger.advances = [Fx.advance(1, dollars: 300)]

        let eligible = SettlementWorkflowService.eligibleLoads(
            from: loads, driverId: Fx.driverId,
            periodStart: Fx.periodStart, periodEnd: Fx.periodEnd,
            ledger: ledger, now: Fx.now, calendar: Fx.utc)
        XCTAssertEqual(eligible.filter(\.isSelectedByDefault).count, 2)

        var draft = SettlementWorkflowService.makeDraft(
            options: Fx.options(advancePolicy: .full),
            loads: eligible.filter(\.isSelectedByDefault).map(\.load),
            ledger: ledger)
        draft.deductions.append(Fx.deduction(1, .fuel, "Fuel", 1_180))
        draft.deductions.append(Fx.deduction(5, .maintenance, "Maintenance", 250))

        // ── Engine ───────────────────────────────────────────────────────
        let result = draft.calculate()
        XCTAssertMoney(result.grossLoadRevenue, 7_250)
        XCTAssertMoney(result.driverBaseEarnings, 5_075)
        XCTAssertMoney(result.totalDriverDeductions, 3_480)
        XCTAssertMoney(result.netDriverPay, 1_595)
        XCTAssertEqual(Set(draft.deductions.map { $0.category }),
                       [.fuel, .insurance, .truckLease, .cashAdvance, .maintenance])

        // ── Database (local file) ────────────────────────────────────────
        try SettlementWorkflowService.save(draft, into: &ledger, actor: Fx.actor, now: Fx.now)
        try store.save(ledger)
        var reloaded = try SettlementLocalStore(directory: tempDir).load()
        let sid = draft.settlement.id!
        let stored = reloaded.settlement(id: sid)!
        XCTAssertMoney(stored.netPayMoney, 1_595, 0, "stored net pay")
        XCTAssertEqual(stored.netPay, 1_595.0)
        XCTAssertMoney(stored.grossLoadRevenue!, 7_250)
        XCTAssertMoney(stored.totalDriverEarnings!, 5_075)
        XCTAssertMoney(stored.totalDeductions!, 3_480)
        XCTAssertMoney(reloaded.bundle(for: sid)!.calculate().netDriverPay, 1_595, 0,
                       "recalculating the stored rows reproduces the figure")

        // ── Approve → paid ───────────────────────────────────────────────
        let approved = try Fx.approve(sid, &reloaded)
        XCTAssertEqual(approved.settlement.settlementNumber, "SP-2026-0001")
        XCTAssertMoney(reloaded.outstandingAdvanceBalance(forDriver: Fx.driverId), 0,
                       0, "the $300 cash advance is recovered")
        _ = try SettlementWorkflowService.transition(
            settlementId: sid, to: .paid, ledger: &reloaded, actor: Fx.actor,
            paymentReference: "TEST-ACH-0001", now: Fx.now, calendar: Fx.utc)
        try store.save(reloaded)
        let final = try SettlementLocalStore(directory: tempDir).load()
        XCTAssertEqual(final.settlement(id: sid)?.settlementStatus, .paid)
        XCTAssertMoney(final.settlement(id: sid)!.netPayMoney, 1_595)

        // ── Statement (what the review screen renders) ───────────────────
        let ytd = SettlementInsights.ytd(final, driverId: Fx.driverId, year: 2026, calendar: Fx.utc)
        let doc = SettlementStatementDocument.make(
            bundle: final.bundle(for: sid)!, driverName: "Test Driver",
            company: SettlementCompanyInfo(name: "Sacred Pathway LLC", mcNumber: "TEST-MC", dotNumber: "TEST-DOT"),
            ytd: ytd, generatedAt: Fx.now, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertNil(doc.reconciliationWarning)
        XCTAssertMoney(doc.grossRevenue, 7_250)
        XCTAssertMoney(doc.driverEarnings, 5_075)
        XCTAssertMoney(doc.totalDeductions, 3_480)
        XCTAssertMoney(doc.netPay, 1_595)
        XCTAssertEqual(doc.loads.count, 2)
        XCTAssertEqual(doc.deductions.count, 5)
        XCTAssertEqual(doc.statusLabel, "PAID")
        XCTAssertMoney(ytd!.netPay, 1_595)

        // ── HTML (what the PDF renderer prints) ──────────────────────────
        let html = SettlementStatementHTML.render(doc)
        XCTAssertTrue(html.contains("$1,595.00"))
        XCTAssertTrue(html.contains("$7,250.00"))
        XCTAssertTrue(html.contains("$5,075.00"))
        XCTAssertTrue(html.contains("-$3,480.00"))
        XCTAssertTrue(html.contains("SP-2026-0001"))
        XCTAssertTrue(html.contains("Test Driver"))
        XCTAssertTrue(html.contains("TEST-1") && html.contains("TEST-2"))
        XCTAssertTrue(html.contains("Sacred Pathway LLC"))
        XCTAssertTrue(html.contains("not a tax document"))
        XCTAssertFalse(html.contains("ESTIMATED"))
    }

    /// Second configuration: additions + partial advance repayment.
    /// Gross $6,000 · 65% = $3,900 · +$200 detention +$150 safety bonus ·
    /// −$900 fuel −$450 insurance −$400 partial advance = $2,500.00.
    func testAcceptance2_AdditionsAndPartialAdvance() throws {
        let store = SettlementLocalStore(directory: tempDir)
        var ledger = SettlementLedger()
        ledger.advances = [Fx.advance(1, dollars: 1_000)]
        ledger.recurringDeductions = [Fx.recurring(1, .insurance, "Insurance", dollars: 450)]
        let driver = Fx.driver(type: .leaseOperator)
        var d = driver
        d.payRule = .percentOfGross(65)

        var draft = SettlementWorkflowService.makeDraft(
            options: Fx.options(driver: d, advancePolicy: .fixedPerSettlement, advanceAmount: Fx.money(400)),
            loads: [Fx.opLoad(1, gross: 2_500), Fx.opLoad(2, gross: 3_500)],
            ledger: ledger)
        draft.additions = [
            Fx.addition(1, .detention, "Detention", 200),
            Fx.addition(2, .safetyBonus, "Safety Bonus", 150)
        ]
        var fuel = Fx.deduction(1, .fuel, "Fuel", 900)
        fuel.responsibility = d.paySettings().responsibility(for: .fuel).0
        draft.deductions.append(fuel)

        try SettlementWorkflowService.save(draft, into: &ledger, actor: Fx.actor, now: Fx.now)
        let sid = draft.settlement.id!
        XCTAssertMoney(ledger.settlement(id: sid)!.netPayMoney, 2_500)
        XCTAssertMoney(ledger.settlement(id: sid)!.totalAdditions!, 350)

        _ = try Fx.approve(sid, &ledger)
        XCTAssertMoney(ledger.outstandingAdvanceBalance(forDriver: Fx.driverId), 600)
        try store.save(ledger)

        let reloaded = try store.load()
        XCTAssertMoney(reloaded.outstandingAdvanceBalance(forDriver: Fx.driverId), 600)
        XCTAssertEqual(reloaded.advanceRepayments.count, 1)

        let doc = SettlementStatementDocument.make(
            bundle: reloaded.bundle(for: sid)!, driverName: "Test Driver",
            company: .sacredPathwayDefault, ytd: nil, generatedAt: Fx.now)
        XCTAssertMoney(doc.netPay, 2_500)
        XCTAssertEqual(doc.additions.count, 2)
        XCTAssertEqual(doc.settlementType, .leaseOperator)
        let html = SettlementStatementHTML.render(doc)
        XCTAssertTrue(html.contains("$2,500.00"))
        XCTAssertTrue(html.contains("+$200.00"))
        XCTAssertTrue(html.contains("-$400.00"))
        XCTAssertFalse(html.contains("Year to Date"), "no paid history → no YTD block")

        // Next week: the plan is capped at the $600 left.
        let plans = DriverAdvanceService.planRecoveries(
            advances: reloaded.advances, repayments: reloaded.advanceRepayments,
            driverId: Fx.driverId, policy: .fixedPerSettlement, requestedAmount: Fx.money(1_000))
        XCTAssertMoney(Money.sum(plans.map(\.amount)), 600)
    }

    /// The UI's "Weekly estimate" example from the brief.
    func testEstimateCardMatchesBriefExample() {
        var ledger = SettlementLedger()
        ledger.recurringDeductions = [
            Fx.recurring(1, .fuel, "Fuel", dollars: 1_180),
            Fx.recurring(2, .insurance, "Insurance", dollars: 450),
            Fx.recurring(3, .truckLease, "Truck Payment", dollars: 1_300),
            Fx.recurring(4, .maintenance, "Maintenance", dollars: 250)
        ]
        ledger.advances = [Fx.advance(1, dollars: 300)]
        // Estimates don't auto-recover advances; show the planned one explicitly.
        let loads = [
            Fx.opLoad(1, gross: 3_500, status: .readyForSettlement),
            Fx.opLoad(2, gross: 3_750, deliveryDay: 20, status: .assigned)   // still in transit
        ]
        var estimate = SettlementInsights.estimate(
            driver: Fx.driver(), paySettings: Fx.driver().paySettings(),
            profileId: Fx.profileId, loads: loads, ledger: ledger,
            range: SettlementDateRange(start: Fx.periodStart, end: Fx.periodEnd),
            companyFees: .none, now: Fx.now, calendar: Fx.utc)!
        estimate.deductions += DriverAdvanceService.deductions(
            for: DriverAdvanceService.planRecoveries(
                advances: ledger.advances, repayments: [], driverId: Fx.driverId, policy: .full),
            profileId: Fx.profileId, settlementId: estimate.settlement.id, date: Fx.periodEnd)
        let r = estimate.calculate()
        XCTAssertTrue(r.isEstimate)
        XCTAssertMoney(r.grossLoadRevenue, 7_250, 0, "Weekly Gross")
        XCTAssertMoney(r.driverBaseEarnings, 5_075, 0, "Driver Gross Earnings")
        XCTAssertMoney(r.netDriverPay, 1_595, 0, "Estimated Net")
        XCTAssertNil(estimate.settlement.settlementNumber)
        XCTAssertTrue(estimate.auditEvents.isEmpty, "estimates are never audited or saved")
    }
}
