import XCTest
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

// =============================================================================
//  History search, YTD, dashboard, reports, CSV — and the rule that an
//  ESTIMATE never mixes with finalized history.
// =============================================================================

@MainActor
final class SettlementInsightsTests: XCTestCase {

    private func history() throws -> (SettlementLedger, paid: UUID, approved: UUID, draft: UUID, estimate: UUID) {
        var ledger = SettlementLedger()
        let paid = try Fx.saveDraft([Fx.opLoad(1, gross: 3_000, broker: "Acme Test Logistics")], into: &ledger)
        _ = try Fx.approve(paid, &ledger)
        _ = try SettlementWorkflowService.transition(settlementId: paid, to: .paid, ledger: &ledger,
                                                     actor: Fx.actor, paymentReference: "TEST-ACH",
                                                     now: Fx.now)
        let approved = try Fx.saveDraft([Fx.opLoad(2, gross: 2_000)], into: &ledger,
                                        driver: Fx.driver(Fx.driver2Id, name: "Test Driver Two"))
        _ = try Fx.approve(approved, &ledger)
        let draft = try Fx.saveDraft([Fx.opLoad(3, gross: 1_000)], into: &ledger)

        var est = SettlementWorkflowService.makeDraft(
            options: Fx.options(isEstimate: true), loads: [Fx.opLoad(4, gross: 9_999)], ledger: ledger)
        est.auditEvents = []
        try SettlementWorkflowService.save(est, into: &ledger, actor: Fx.actor)
        return (ledger, paid, approved, draft, est.settlement.id!)
    }

    // MARK: Estimate separation

    func testEstimatesNeverAppearInHistoryYTDDashboardOrReports() throws {
        let (ledger, paid, approved, draft, estimate) = try history()
        let all = SettlementInsights.filter(ledger, SettlementHistoryFilter())
        XCTAssertEqual(Set(all.compactMap(\.id)), [paid, approved, draft])
        XCTAssertFalse(all.contains { $0.id == estimate })

        let ytd = SettlementInsights.ytd(ledger, driverId: Fx.driverId, year: 2026, calendar: Fx.utc)!
        XCTAssertEqual(ytd.settlementCount, 1, "only PAID counts toward YTD")
        XCTAssertMoney(ytd.netPay, 2_100)

        // Range runs to "now" so the payment made on the 15th is inside it.
        let dash = SettlementInsights.dashboard(
            ledger: ledger, loads: [], expenses: [],
            range: SettlementDateRange(start: Fx.periodStart, end: Fx.now),
            now: Fx.now, calendar: Fx.utc)
        XCTAssertMoney(dash.driverPay, 3_500, 0, "2,100 paid + 1,400 approved; no estimate, no draft")
        XCTAssertEqual(dash.unpaidCount, 1)
        XCTAssertMoney(dash.unpaidAmount, 1_400)
        XCTAssertEqual(dash.paidCount, 1)
        XCTAssertEqual(dash.draftCount, 1)

        let report = SettlementInsights.report(
            .settlementHistory, ledger: ledger,
            range: SettlementDateRange(start: Fx.periodStart, end: Fx.periodEnd),
            driverNames: [:], now: Fx.now, calendar: Fx.utc)
        XCTAssertEqual(report.rows.count, 3)
        XCTAssertFalse(report.rows.contains { $0.contains("$9,999.00") })
    }

    func testYTDIsNilWithoutPaidHistory() {
        XCTAssertNil(SettlementInsights.ytd(.empty, driverId: Fx.driverId, year: 2026))
    }

    // MARK: Search & filters

    func testHistorySearchAndFilters() throws {
        let (ledger, paid, approved, draft, _) = try history()
        let names = [Fx.driverId: "Test Driver", Fx.driver2Id: "Test Driver Two"]

        func ids(_ f: SettlementHistoryFilter) -> Set<UUID> {
            Set(SettlementInsights.filter(ledger, f, driverNames: names, calendar: Fx.utc).compactMap(\.id))
        }
        XCTAssertEqual(ids(.init(driverId: Fx.driver2Id)), [approved])
        XCTAssertEqual(ids(.init(query: "acme")), [paid], "broker search")
        XCTAssertEqual(ids(.init(query: "TEST-3")), [draft], "load number search")
        XCTAssertEqual(ids(.init(query: "SP-2026-0002")), [approved], "settlement number search")
        XCTAssertEqual(ids(.init(query: "driver two")), [approved], "driver name search")
        XCTAssertEqual(ids(.init(truckNumber: "test-unit-1")).count, 3)
        XCTAssertEqual(ids(.init(statuses: [.paid])), [paid])
        XCTAssertEqual(ids(.init(paid: .paid)), [paid])
        XCTAssertEqual(ids(.init(paid: .unpaid)), [approved, draft])
        XCTAssertEqual(ids(.init(dateRange: SettlementDateRange(start: Fx.date(2026, 10, 1),
                                                                end: Fx.date(2026, 10, 31)))), [])
    }

    func testDateRangePresetsFollowPayWeek() {
        // Wednesday 2026-09-16, Monday-start week.
        let now = Fx.date(2026, 9, 16)
        let week = SettlementDateRange.preset(.thisWeek, now: now, firstWeekday: 2, calendar: Fx.utc)
        XCTAssertEqual(Fx.utc.component(.day, from: week.start), 14)
        XCTAssertEqual(Fx.utc.component(.day, from: week.end), 20)
        let last = SettlementDateRange.preset(.lastWeek, now: now, firstWeekday: 2, calendar: Fx.utc)
        XCTAssertEqual(Fx.utc.component(.day, from: last.start), 7)
        XCTAssertEqual(Fx.utc.component(.day, from: last.end), 13)
        let sunday = SettlementDateRange.preset(.thisWeek, now: now, firstWeekday: 1, calendar: Fx.utc)
        XCTAssertEqual(Fx.utc.component(.day, from: sunday.start), 13)
        let lastMonth = SettlementDateRange.preset(.lastMonth, now: now, calendar: Fx.utc)
        XCTAssertEqual(Fx.utc.component(.month, from: lastMonth.start), 8)
        XCTAssertEqual(Fx.utc.component(.day, from: lastMonth.end), 31)
        XCTAssertTrue(week.contains(Fx.date(2026, 9, 20), calendar: Fx.utc), "end day is inclusive")
    }

    // MARK: Dashboard

    func testDashboardLoadAndExpenseTotals() {
        let loads = [
            Fx.opLoad(1, gross: 3_500),
            Fx.opLoad(2, gross: 3_750, deliveryDay: 20, status: .assigned),
            Fx.opLoad(3, gross: 1_000, pickupDay: 20)       // outside range
        ]
        let expenses = [Fx.expense(1, "fuel", 1_180), Fx.expense(2, "toll", 45.5),
                        Fx.expense(3, "fuel", 99, day: 25)]
        let m = SettlementInsights.dashboard(
            ledger: .empty, loads: loads + [loads[0]],      // duplicate row must not double count
            expenses: expenses,
            range: SettlementDateRange(start: Fx.periodStart, end: Fx.periodEnd),
            now: Fx.now, calendar: Fx.utc)
        XCTAssertMoney(m.grossRevenue, 7_250)
        XCTAssertEqual(m.completedLoads, 1)
        XCTAssertEqual(m.pendingLoads, 1)
        XCTAssertMoney(m.fuel, 1_180)
        XCTAssertMoney(m.otherExpenses, 45, 50)
        XCTAssertMoney(m.estimatedProfit, 6_024, 50)
    }

    // MARK: Reports & CSV

    func testDriverEarningsAndAdvanceReports() throws {
        var (ledger, _, _, _, _) = try history()
        ledger.advances = [Fx.advance(1, dollars: 500)]
        ledger.advanceRepayments = [Fx.repayment(1, advanceId: Fx.id(4_001), dollars: 200)]
        let names = [Fx.driverId: "Test Driver", Fx.driver2Id: "Test Driver Two"]
        let range = SettlementDateRange(start: Fx.periodStart, end: Fx.periodEnd)

        let earnings = SettlementInsights.report(.driverEarnings, ledger: ledger, range: range,
                                                 driverNames: names, now: Fx.now, calendar: Fx.utc)
        XCTAssertEqual(earnings.rows.count, 2)
        XCTAssertEqual(earnings.totals?.last, "$3,500.00")

        let advances = SettlementInsights.report(.driverAdvances, ledger: ledger, range: range,
                                                 driverNames: names, now: Fx.now, calendar: Fx.utc)
        XCTAssertEqual(advances.rows.first?[6], "$300.00", "outstanding rebuilt from the ledger")
        XCTAssertEqual(advances.rows.first?[7], "Open")

        let revenue = SettlementInsights.report(.companyRevenue, ledger: ledger, range: range,
                                                driverNames: names, now: Fx.now, calendar: Fx.utc)
        XCTAssertEqual(revenue.rows.count, 2, "approved + paid only")
        XCTAssertEqual(revenue.totals?[3], "$5,000.00")
    }

    func testCSVEscapingAndNumericCells() {
        let report = SettlementReport(
            kind: .expenses, title: "t", subtitle: "s",
            columns: ["Description", "Amount"], numericColumns: [1],
            rows: [["Fuel, \"Pilot\" #12", "$1,180.00"],
                   ["=HYPERLINK(\"http://x\")", "-$5.50"],
                   ["Line\nbreak", "$0.00"]],
            totals: ["Total", "$1,174.50"], generatedAt: Fx.now)
        let csv = SettlementInsights.csv(report)
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Description,Amount")
        XCTAssertEqual(lines[1], "\"Fuel, \"\"Pilot\"\" #12\",1180.00")
        XCTAssertEqual(lines[2], "\"'=HYPERLINK(\"\"http://x\"\")\",-5.50", "formula injection neutralised")
        XCTAssertTrue(csv.contains("\"Line\nbreak\",0.00"))
        XCTAssertTrue(csv.contains("Total,1174.50"))
    }
}
