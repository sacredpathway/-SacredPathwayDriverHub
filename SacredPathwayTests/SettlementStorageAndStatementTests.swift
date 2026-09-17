import XCTest
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

// =============================================================================
//  Local store safety, Supabase row shape, legacy driver defaults, and the
//  statement document / HTML the PDF is printed from.
// =============================================================================

final class SettlementStorageTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sph-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingFileIsAnEmptyLedger() throws {
        let ledger = try SettlementLocalStore(directory: dir).load()
        XCTAssertTrue(ledger.settlements.isEmpty)
    }

    func testRoundTripKeepsEveryRecordAndPreviousCopy() throws {
        let store = SettlementLocalStore(directory: dir)
        var ledger = SettlementLedger()
        ledger.localDrivers = [Fx.driver()]
        ledger.recurringDeductions = [Fx.recurring(1, .insurance, "Insurance", dollars: 450)]
        ledger.advances = [Fx.advance(1, dollars: 300)]
        let id = try Fx.saveDraft([Fx.opLoad(1, gross: 1_234.56)], into: &ledger,
                                  additions: [Fx.addition(1, .bonus, "Bonus", 25)])
        try store.save(ledger)
        try store.save(ledger)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.previousURL.path))

        let back = try SettlementLocalStore(directory: dir).load()
        XCTAssertEqual(back.settlements.count, 1)
        XCTAssertEqual(back.loadLines.count, 1)
        XCTAssertEqual(back.additions.count, 1)
        XCTAssertEqual(back.deductions.count, 1)
        XCTAssertEqual(back.recurringDeductions.count, 1)
        XCTAssertEqual(back.advances.count, 1)
        XCTAssertEqual(back.localDrivers.first?.name, "Test Driver")
        XCTAssertTrue(back.localDrivers.first?.payRule?.hasSameTerms(as: .percentOfGross(70)) == true)
        XCTAssertEqual(back.auditEvents.count, ledger.auditEvents.count)
        XCTAssertMoney(back.settlement(id: id)!.netPayMoney, ledger.settlement(id: id)!.netPayMoney)
        XCTAssertMoney(back.bundle(for: id)!.loadLines[0].grossRate, 1_234, 56)
    }

    func testUnreadableFileIsPreservedAndNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SettlementLocalStore(directory: dir)
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: store.fileURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard case SettlementLocalStoreError.unreadable(let preserved, _) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertNotNil(preserved)
        }
        XCTAssertTrue(store.isQuarantined)
        XCTAssertThrowsError(try store.save(SettlementLedger()), "must not clobber unreadable data")
        XCTAssertEqual(try Data(contentsOf: store.fileURL), garbage)
        let asides = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains("unreadable") }
        XCTAssertEqual(asides.count, 1)
    }

    func testOlderFileWithMissingKeysStillLoads() throws {
        let json = #"{"schema_version":1,"settlements":[]}"#
        let ledger = try JSONDecoder().decode(SettlementLedger.self, from: Data(json.utf8))
        XCTAssertTrue(ledger.advances.isEmpty)
        XCTAssertTrue(ledger.localDrivers.isEmpty)
    }

    // MARK: Supabase row shape

    func testRowCodecWritesDateOnlyAndTimestampColumnsCorrectly() throws {
        var line = Fx.load(1, gross: 100)
        line.createdAt = Fx.date(2026, 9, 8)
        let row = try SettlementRowCodec.jsonObject(line)
        XCTAssertEqual(row["pickup_date"] as? String, "2026-09-07")
        XCTAssertEqual(row["delivery_date"] as? String, "2026-09-13")
        XCTAssertEqual(row["created_at"] as? String, "2026-09-08T12:00:00.000Z")
        XCTAssertEqual(row["load_number"] as? String, "TEST-1")

        let rule = try SettlementRowCodec.jsonObject(Fx.recurring(1, .insurance, "Ins", dollars: 450))
        XCTAssertEqual(rule["effective_start_date"] as? String, "2026-01-01")
        XCTAssertEqual(rule["frequency"] as? String, "every_settlement")

        let event = try SettlementRowCodec.jsonObject(SettlementAuditEvent(
            profileId: Fx.profileId, settlementId: Fx.id(1), action: .approved,
            summary: "x", timestamp: Fx.date(2026, 9, 14)))
        XCTAssertEqual(event["timestamp"] as? String, "2026-09-14T12:00:00.000Z")
        XCTAssertEqual(event["action"] as? String, "approved")
    }

    func testRowCodecReadsPostgresShapes() throws {
        let json = """
        [{"id":"22222222-0000-4000-8000-000000003001","settlement_id":"22222222-0000-4000-8000-000000007000",
          "profile_id":"11111111-0000-4000-8000-000000000001","category":"fuel","description":"Fuel",
          "amount":1180.00,"date":"2026-09-13","related_load_id":null,"related_expense_id":null,
          "document_id":null,"notes":null,"responsibility":"split","driver_share_percent":60.000,
          "recurring_deduction_id":null,"advance_id":null,"sort_order":3,
          "created_at":"2026-09-14T17:03:22.123456+00:00"}]
        """
        let rows = try SettlementRowCodec.decodeRows(SettlementDeduction.self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertMoney(rows[0].amount, 1_180)
        XCTAssertMoney(rows[0].driverAmount, 708)
        XCTAssertEqual(rows[0].responsibility, .split)
        XCTAssertNotNil(rows[0].date)
        XCTAssertNotNil(rows[0].createdAt)
    }

    func testSettlementStatusValuesMatchDatabaseCheckConstraint() {
        XCTAssertEqual(Set(SettlementStatus.allCases.map(\.rawValue)),
                       ["draft", "ready_for_review", "approved", "paid", "voided"])
        XCTAssertEqual(Set(SettlementType.allCases.map(\.rawValue)),
                       ["company_driver", "lease_operator", "owner_operator", "custom"])
    }

    // MARK: Driver defaults

    func testLegacyDriverFieldsBecomePayRules() {
        var pct = Driver(profileId: Fx.profileId, name: "Test Driver", payPercentage: 72.5, payType: "percent")
        pct.id = Fx.driverId
        XCTAssertTrue(pct.paySettings().payRule.hasSameTerms(as: .percentOfGross(Decimal(string: "72.5")!)))
        XCTAssertEqual(pct.paySettings().settlementType, .companyDriver)
        XCTAssertFalse(pct.paySettings(legacyPayOnGrossRevenue: false).payOnGrossRevenue)

        let flat = Driver(id: Fx.driverId, profileId: Fx.profileId, name: "Test Driver",
                          payType: "flat", flatRate: 1_200)
        XCTAssertEqual(flat.paySettings().payRule.components.first?.kind, .manual)
        XCTAssertMoney(flat.paySettings().payRule.components.first!.fixedAmount!, 1_200)

        let none = Driver(id: Fx.driverId, profileId: Fx.profileId, name: "Test Driver")
        XCTAssertTrue(none.paySettings().payRule.isEmpty)

        var saved = pct
        saved.payRule = .perMile(Fx.money(0, 62))
        XCTAssertEqual(saved.paySettings().payRule.primaryKind, .perMile, "a saved rule wins over legacy fields")
    }

    func testDriverDecodesRowsWrittenBeforeTheMigration() throws {
        let json = #"""
        [{"id":"11111111-0000-4000-8000-000000000002","profile_id":"11111111-0000-4000-8000-000000000001",
          "name":"Test Driver","truck_number":"T1","pay_percentage":70,"pay_type":"percent",
          "flat_rate":null,"phone":null,"email":null,"active":true,
          "created_at":"2026-05-01T10:00:00+00:00"}]
        """#
        let drivers = try SettlementRowCodec.decodeRows(Driver.self, from: Data(json.utf8))
        XCTAssertNil(drivers[0].payRule)
        XCTAssertTrue(drivers[0].paySettings().payRule.hasSameTerms(as: .percentOfGross(70)))
    }

    func testFeeTermsFrozenOnSettlementAreUsedOnRecalculation() throws {
        var ledger = SettlementLedger()
        var draft = SettlementWorkflowService.makeDraft(
            options: Fx.options(fees: CompanyFeeSettings(dispatcherFeePercent: 10, factoringFeePercent: 3)),
            loads: [Fx.opLoad(1, gross: 5_000)], ledger: ledger)
        draft.auditEvents = []
        try SettlementWorkflowService.save(draft, into: &ledger, actor: Fx.actor)
        let stored = ledger.bundle(for: draft.settlement.id!)!
        XCTAssertEqual(stored.settlement.payRule?.feeTerms?.dispatcherFeePercent, 10)
        let r = stored.calculate()
        XCTAssertMoney(r.companyExpenses, 650, 0, "10% + 3% of $5,000, company-borne for a company driver")
        XCTAssertMoney(r.netDriverPay, 3_500)
        XCTAssertEqual(stored.settlement.dispatcherFeePercentage, 10)
        XCTAssertEqual(stored.settlement.factoringFeeAmount, 150)

        // A lease operator whose agreement says they carry factoring.
        var lease = Fx.driver(type: .leaseOperator)
        lease.leaseConfig = LeaseOperatorConfig(rules: [
            ResponsibilityRule(category: .factoringFee, responsibility: .driver)
        ])
        let leaseDraft = SettlementWorkflowService.makeDraft(
            options: Fx.options(driver: lease, fees: CompanyFeeSettings(dispatcherFeePercent: 10, factoringFeePercent: 3)),
            loads: [Fx.opLoad(1, gross: 5_000)], ledger: .empty)
        XCTAssertMoney(leaseDraft.calculate().netDriverPay, 3_350, 0, "3,500 − 150 factoring")
    }

    func testCompanySideLineIdIsDistinctForSplitDeductions() {
        let r = SettlementCalculationEngine.calculate(Fx.input(
            loads: [Fx.load(1, gross: 1_000)],
            deductions: [Fx.deduction(1, .repair, "Split", 100, responsibility: .split, driverShare: 40)]))
        let driverLine = r.driverDeductionLines.first!
        let companyLine = r.companyExpenseLines.first!
        XCTAssertNotEqual(driverLine.id, companyLine.id)
        XCTAssertEqual(Set(r.lineItems.map(\.id)).count, r.lineItems.count, "all line ids unique")
        XCTAssertMoney(driverLine.amount, 40)
        XCTAssertMoney(companyLine.amount, 60)
    }
}

final class SettlementStatementTests: XCTestCase {

    private func bundle(status: SettlementStatus = .draft, estimate: Bool = false) throws -> SettlementBundle {
        var ledger = SettlementLedger()
        var draft = SettlementWorkflowService.makeDraft(
            options: Fx.options(isEstimate: estimate),
            loads: [Fx.opLoad(1, gross: 3_500, broker: "Acme <Test> & Sons")], ledger: ledger)
        draft.additions = [Fx.addition(1, .detention, "Detention", 100)]
        draft.deductions = [Fx.deduction(1, .fuel, "Fuel", 500),
                            Fx.deduction(2, .factoringFee, "Company factoring", 70,
                                         responsibility: .company, driverShare: 0)]
        draft.auditEvents = []
        try SettlementWorkflowService.save(draft, into: &ledger, actor: Fx.actor)
        return ledger.bundle(for: draft.settlement.id!)!
    }

    func testStatementListsEveryDriverLineAndHidesCompanyLines() throws {
        let doc = SettlementStatementDocument.make(
            bundle: try bundle(), driverName: "Test Driver",
            company: .sacredPathwayDefault, ytd: nil, generatedAt: Fx.now)
        XCTAssertEqual(doc.loads.count, 1)
        XCTAssertEqual(doc.additions.map(\.label), ["Detention"])
        XCTAssertEqual(doc.deductions.map(\.label), ["Fuel"], "company-paid factoring is not on the driver's statement")
        XCTAssertMoney(doc.netPay, 2_050, 0, "2,450 + 100 − 500")
        XCTAssertEqual(doc.statusLabel, "DRAFT")
        XCTAssertEqual(doc.settlementNumber, "SP-2026-0001")
        XCTAssertTrue(doc.fileName.hasPrefix("Settlement-SP-2026-0001-Test-Driver"))
        XCTAssertEqual(doc.driverReference, "DRV-11111111")
    }

    func testHTMLEscapesUserTextAndCarriesDisclaimer() throws {
        let doc = SettlementStatementDocument.make(
            bundle: try bundle(), driverName: "Test <script>alert(1)</script>",
            company: SettlementCompanyInfo(name: "Sacred Pathway LLC", phone: "(000) 000-0000",
                                           email: "test@example.invalid"),
            ytd: SettlementYTDTotals(year: 2026, settlementCount: 3, driverEarnings: Fx.money(9_000),
                                     additions: Fx.money(100), deductions: Fx.money(2_000),
                                     netPay: Fx.money(7_100)),
            generatedAt: Fx.now)
        let html = SettlementStatementHTML.render(doc)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("Acme &lt;Test&gt; &amp; Sons"))
        XCTAssertTrue(html.contains(SettlementStatementHTML.escape(SettlementStatementDocument.disclaimer)))
        XCTAssertTrue(html.contains("Year to Date 2026"))
        XCTAssertTrue(html.contains("$7,100.00"))
        XCTAssertTrue(html.contains("test@example.invalid"))
        XCTAssertTrue(html.contains("Generated"))
        XCTAssertFalse(html.contains("<script"), "no script tags at all in the statement")
    }

    func testEstimateStatementIsClearlyLabelled() throws {
        let doc = SettlementStatementDocument.make(
            bundle: try bundle(estimate: true), driverName: "Test Driver",
            company: .sacredPathwayDefault, ytd: nil, generatedAt: Fx.now)
        XCTAssertTrue(doc.isEstimate)
        XCTAssertEqual(doc.statusLabel, "ESTIMATED")
        XCTAssertEqual(doc.settlementNumber, "ESTIMATE")
        let html = SettlementStatementHTML.render(doc)
        XCTAssertTrue(html.contains("ESTIMATED — not a final settlement"))
        XCTAssertTrue(html.contains("Estimated Net Pay"))
    }

    func testStatementFlagsStoredFiguresThatDisagreeWithTheEngine() throws {
        var tampered = try bundle()
        tampered.settlement.netPay = 9_999
        let doc = SettlementStatementDocument.make(
            bundle: tampered, driverName: "Test Driver",
            company: .sacredPathwayDefault, ytd: nil, generatedAt: Fx.now)
        XCTAssertNotNil(doc.reconciliationWarning)
        XCTAssertMoney(doc.netPay, 2_050, 0, "the statement prints the engine's figure, never the tampered one")
        XCTAssertTrue(SettlementStatementHTML.render(doc).contains("differs from the recalculated"))
    }
}
