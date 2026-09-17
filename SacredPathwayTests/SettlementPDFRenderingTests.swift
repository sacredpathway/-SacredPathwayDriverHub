import XCTest
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

// =============================================================================
//  PDF generation — runs only inside the iOS app test host (WebKit + PDFKit).
//  The HTML the PDF is printed from is covered on every platform by
//  SettlementStatementTests; this proves the renderer turns it into a real,
//  readable PDF that still says $1,595.00.
// =============================================================================

#if canImport(UIKit) && canImport(WebKit) && canImport(PDFKit) && !canImport(SettlementKit)
import PDFKit

@MainActor
final class SettlementPDFRenderingTests: XCTestCase {

    func testStatementPDFRendersAndContainsNetPay() async throws {
        var ledger = SettlementLedger()
        ledger.recurringDeductions = [
            Fx.recurring(1, .insurance, "Insurance", dollars: 450),
            Fx.recurring(2, .truckLease, "Truck Payment", dollars: 1_300)
        ]
        ledger.advances = [Fx.advance(1, dollars: 300)]
        var draft = SettlementWorkflowService.makeDraft(
            options: Fx.options(advancePolicy: .full),
            loads: [Fx.opLoad(1, gross: 3_500), Fx.opLoad(2, gross: 3_750)],
            ledger: ledger)
        draft.deductions.append(Fx.deduction(1, .fuel, "Fuel", 1_180))
        draft.deductions.append(Fx.deduction(5, .maintenance, "Maintenance", 250))

        let doc = SettlementStatementDocument.make(
            bundle: draft, driverName: "Test Driver",
            company: .sacredPathwayDefault, ytd: nil, generatedAt: Fx.now)
        XCTAssertMoney(doc.netPay, 1_595)

        let data = try await SettlementPDFExporter.statementPDF(doc)
        XCTAssertGreaterThan(data.count, 1_000)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "%PDF")

        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 1)
        let text = pdf.string ?? ""
        XCTAssertTrue(text.contains("1,595.00"), "net pay printed in the PDF")
        XCTAssertTrue(text.contains("Test Driver"))
    }

    func testReportPDFRenders() async throws {
        let report = SettlementReport(
            kind: .driverEarnings, title: "Driver Earnings", subtitle: "Test range",
            columns: ["Driver", "Net Pay"], numericColumns: [1],
            rows: [["Test Driver", "$1,595.00"]], totals: ["Total", "$1,595.00"],
            generatedAt: Fx.now)
        let data = try await SettlementPDFExporter.reportPDF(report, company: .sacredPathwayDefault)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 1)
    }
}
#endif
