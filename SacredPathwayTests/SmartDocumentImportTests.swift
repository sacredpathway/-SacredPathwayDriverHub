import XCTest
import UIKit
import PDFKit
@testable import SacredPathway

// =============================================================================
//  Smart document import — iOS paths: embedded PDF text vs Vision OCR,
//  multi-page PDFs, rotated and low-quality images, form prefill, legacy
//  parser merge, and on-device persistence of the original document.
// =============================================================================

@MainActor
final class SmartDocumentReaderTests: XCTestCase {

    static let receiptLines = ["PILOT TRAVEL CENTER #88", "DIESEL 100.000 GAL @ $3.500", "TOTAL $350.00"]

    // MARK: Fixture builders

    static func textPDF(pages: [[String]]) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            for lines in pages {
                ctx.beginPage()
                var y: CGFloat = 36
                for line in lines {
                    (line as NSString).draw(at: CGPoint(x: 36, y: y),
                                            withAttributes: [.font: UIFont.systemFont(ofSize: 10)])
                    y += 14
                }
            }
        }
    }

    static func textImage(_ lines: [String], foreground: UIColor = .black, background: UIColor = .white,
                          fontSize: CGFloat = 34) -> UIImage {
        let size = CGSize(width: 900, height: CGFloat(lines.count) * (fontSize * 1.6) + 80)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            background.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            var y: CGFloat = 40
            for line in lines {
                (line as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: foreground
                ])
                y += fontSize * 1.6
            }
        }
    }

    /// Pixels rotated 90° (orientation stays .up, like a sideways photo).
    static func rotated(_ image: UIImage) -> UIImage {
        let size = CGSize(width: image.size.height, height: image.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: size.width, y: 0)
            ctx.cgContext.rotate(by: .pi / 2)
            image.draw(at: .zero)
        }
    }

    static func imagePDF(_ image: UIImage) -> Data {
        let bounds = CGRect(origin: .zero, size: image.size)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            ctx.beginPage()
            image.draw(in: bounds)
        }
    }

    // MARK: Tests

    func testDigitalPDFUsesEmbeddedText() async throws {
        let lines = DocumentText(text: SmartFixtures.textRateCon).pages[0].lines
        let data = Self.textPDF(pages: [lines])
        let reading = await DocumentTextReader.read(ImportedDocument(images: [], originalData: data, mimeType: "application/pdf"))
        XCTAssertEqual(reading.document.pages.first?.source, .pdfText)
        let result = SmartExtractionPipeline.run(reading.document)
        XCTAssertEqual(result.kind, .rateConfirmation)
        XCTAssertEqual(result.rateConfirmation?.loadNumber.value, "SFB-448812")
        XCTAssertEqual(result.rateConfirmation?.totalRate.value, 2_850)
        XCTAssertFalse(reading.legacyOCRLines.isEmpty, "the legacy parser still receives OCR lines")
    }

    func testMultiPagePDFKeepsPages() async throws {
        let data = Self.textPDF(pages: [
            ["BROKER CARRIER TERMS AND CONDITIONS", "Carrier shall comply with all laws and regulations of the DOT."],
            ["Great Plains Logistics Inc", "Rate Confirmation", "Load Number: GPL-20931", "Total: $1,735.50"]
        ])
        let reading = await DocumentTextReader.read(ImportedDocument(images: [], originalData: data, mimeType: "application/pdf"))
        XCTAssertEqual(reading.document.pageCount, 2)
        XCTAssertTrue(reading.document.pages[1].lines.contains { $0.contains("GPL-20931") })
        let r = SmartExtractionPipeline.run(reading.document).rateConfirmation
        XCTAssertEqual(r?.loadNumber.value, "GPL-20931")
        XCTAssertEqual(r?.loadNumber.page, 2)
    }

    func testScannedPDFFallsBackToOCR() async throws {
        let data = Self.imagePDF(Self.textImage(Self.receiptLines))
        let reading = await DocumentTextReader.read(ImportedDocument(images: [], originalData: data, mimeType: "application/pdf"))
        XCTAssertNotEqual(reading.document.pages.first?.source, .pdfText, "an image-only PDF has no usable text layer")
        let text = reading.document.joined.uppercased()
        XCTAssertTrue(text.contains("350"), "OCR read: \(text)")
        let receipt = SmartExtractionPipeline.run(reading.document, forcedKind: .fuelReceipt).receipt
        XCTAssertEqual(receipt?.total.value, 350)
    }

    func testRotatedImageIsRead() async throws {
        let image = Self.rotated(Self.textImage(Self.receiptLines))
        let reading = await DocumentTextReader.read(ImportedDocument(images: [image], originalData: nil, mimeType: nil))
        let text = reading.document.joined.uppercased()
        XCTAssertTrue(text.contains("TOTAL") && text.contains("350"), "OCR read: \(text)")
        let receipt = SmartExtractionPipeline.run(reading.document, forcedKind: .fuelReceipt).receipt
        XCTAssertEqual(receipt?.total.value, 350)
    }

    func testLowQualityScanIsEnhancedOrFlagged() async throws {
        let faint = Self.textImage(Self.receiptLines, foreground: UIColor(white: 0.62, alpha: 1),
                                   background: UIColor(white: 0.78, alpha: 1), fontSize: 22)
        let enhanced = try XCTUnwrap(DocumentTextReader.enhanced(faint))
        XCTAssertEqual(enhanced.size, faint.size, "enhancement keeps the page size")
        let reading = await DocumentTextReader.read(ImportedDocument(images: [faint], originalData: nil, mimeType: nil))
        let result = SmartExtractionPipeline.run(reading.document, forcedKind: .fuelReceipt)
        if let total = result.receipt?.total.value {
            XCTAssertEqual(total, 350, accuracy: 0.001)
        } else {
            // Not readable: the review card must say so instead of inventing a value.
            XCTAssertTrue(result.issues.contains { $0.field == "total" })
        }
    }

    func testEmbeddedTextReliabilityRules() {
        XCTAssertFalse(DocumentTextReader.isReliableEmbeddedText(["1", "2"]))
        XCTAssertFalse(DocumentTextReader.isReliableEmbeddedText([String(repeating: "\u{FFFD}", count: 80)]))
        XCTAssertTrue(DocumentTextReader.isReliableEmbeddedText([
            "Rate Confirmation", "Load Number: GPL-20931", "Shipper Prairie Grain Co-op",
            "Consignee Front Range Foods", "Total carrier pay $1,735.50"
        ]))
    }

    func testImportedDocumentFingerprintUsesOriginalBytes() {
        let data = Self.textPDF(pages: [["Hello fingerprint test document"]])
        let doc = ImportedDocument(images: [], originalData: data, mimeType: "application/pdf")
        XCTAssertTrue(doc.isPDF)
        XCTAssertEqual(doc.fileFingerprint, DocumentFingerprint.sha256Hex(data))
        XCTAssertNil(ImportedDocument(images: [], originalData: nil, mimeType: nil).fileFingerprint)
    }
}

@MainActor
final class SmartImportCoordinatorTests: XCTestCase {

    private func makeImport(_ text: String, family: SmartImportCoordinator.Family = .expense,
                            kind: SmartDocumentKind? = nil) -> SmartImport {
        let doc = DocumentText(text: text)
        var result = SmartExtractionPipeline.run(doc, forcedKind: kind)
        if family == .expense, result.kind == .rateConfirmation {
            result.rateConfirmation = nil
            result.kind = .unknown
        }
        return SmartImport(result: result, document: doc, legacyOCRLines: doc.pages.flatMap(\.lines),
                           source: ImportedDocument(images: [], originalData: nil, mimeType: nil), family: family)
    }

    func testFuelReceiptPrefill() {
        let prefill = SmartImportCoordinator.expensePrefill(makeImport(SmartFixtures.lovesFuel))
        XCTAssertEqual(prefill.category, "fuel")
        XCTAssertEqual(prefill.amount, "501.15")
        XCTAssertEqual(prefill.gallons, "125.482")
        XCTAssertEqual(prefill.pricePerGallon, "3.899")
        XCTAssertEqual(prefill.defGallons, "4.250")
        XCTAssertEqual(prefill.vendorName, "Love's #356")
        XCTAssertEqual(SimpleDate(date: prefill.receiptDate).iso, "2026-06-10")
        XCTAssertNotNil(prefill.smartImport)
        XCTAssertEqual(prefill.smartSuggestions["amount"]?.confidence, .high)
    }

    func testMaintenancePrefill() {
        let prefill = SmartImportCoordinator.expensePrefill(makeImport(SmartFixtures.maintenanceInvoice))
        XCTAssertEqual(prefill.category, "maintenance")
        XCTAssertEqual(prefill.amount, "941.35")
        XCTAssertEqual(prefill.vendorName, "Rush Truck Centers - Oklahoma City")
        XCTAssertTrue(prefill.gallons.isEmpty)
        XCTAssertTrue(prefill.description.contains("PM Service"))
    }

    func testUnknownDocumentPrefillsNothing() {
        let prefill = SmartImportCoordinator.expensePrefill(makeImport(SmartFixtures.ambiguousReceipt))
        XCTAssertTrue(prefill.amount.isEmpty)
        XCTAssertTrue(prefill.vendorName.isEmpty)
        XCTAssertEqual(prefill.category, "other")
        XCTAssertTrue(prefill.smartImport?.result.needsKindChoice ?? false)
    }

    func testRateConScannedFromExpensesIsNotAnExpense() {
        let imp = makeImport(SmartFixtures.textRateCon, family: .expense)
        XCTAssertEqual(imp.result.kind, .unknown)
        XCTAssertNotNil(imp.familyMismatchMessage)
        XCTAssertFalse(imp.selectableKinds.contains(.rateConfirmation))
        XCTAssertTrue(SmartImportCoordinator.expensePrefill(imp).amount.isEmpty)
    }

    func testChoosingKindReExtracts() {
        let imp = makeImport(SmartFixtures.ambiguousReceipt)
        let chosen = SmartImportCoordinator.choose(.generalReceipt, for: imp, existing: [])
        XCTAssertEqual(chosen.result.kind, .generalReceipt)
        XCTAssertNotNil(chosen.result.receipt)
    }

    func testLegacyFuelParserFillsOnlyMissingValues() {
        let suggestions = SmartImportCoordinator.expenseSuggestions(makeImport(SmartFixtures.messyPilotFuel))
        XCTAssertEqual(suggestions["amount"]?.value, "371.01")
        XCTAssertEqual(suggestions["amount"]?.confidence, .high, "shared extractor value is kept")
        XCTAssertNotNil(suggestions["gallons"])
    }

    func testEnhanceFillsLegacyGapsWithoutOverwriting() {
        var parsed = LocalDocumentParser.parseText(SmartFixtures.textRateCon)
        let before = parsed
        let result = SmartExtractionPipeline.run(DocumentText(text: SmartFixtures.textRateCon))
        SmartImportCoordinator.enhance(&parsed, with: result)
        // A field the legacy parser does not read is filled.
        XCTAssertEqual(parsed.truckNumber, "2580")
        // Confident legacy readings are never replaced.
        let pairs: [(String, String?, String?)] = [
            ("loadNumber", before.loadNumber, parsed.loadNumber),
            ("brokerName", before.brokerName, parsed.brokerName),
            ("commodity", before.commodity, parsed.commodity),
            ("pickupCityState", before.pickupCityState, parsed.pickupCityState),
            ("deliveryCityState", before.deliveryCityState, parsed.deliveryCityState)
        ]
        for (key, old, new) in pairs {
            guard let old, !old.isEmpty, (before.confidence[key] ?? 1) >= 0.5 else { continue }
            XCTAssertEqual(new, old, "\(key) was replaced")
        }
        // Empty legacy fields are filled from the document.
        XCTAssertNotNil(parsed.rate)
        XCTAssertNotNil(parsed.pickupDate)
        XCTAssertNotNil(parsed.deliveryDate)
        XCTAssertNotNil(parsed.pickupCityState)
        XCTAssertNotNil(parsed.deliveryCityState)
    }

    func testEnhanceIgnoresNonRateConfirmations() {
        var parsed = ParsedLoadFields()
        let notes = SmartImportCoordinator.enhance(&parsed, with: SmartExtractionPipeline.run(DocumentText(text: SmartFixtures.lovesFuel)))
        XCTAssertTrue(notes.isEmpty)
        XCTAssertNil(parsed.rate)
    }

    func testExpenseAndLoadProbes() throws {
        let expense = Expense(id: UUID(), profileId: UUID(), category: "fuel", amount: 501.15, vendorName: "Love's",
                              description: "Diesel · Receipt 88213", receiptDate: SimpleDate(year: 2026, month: 6, day: 10)!.date())
        let p = try XCTUnwrap(SmartImportCoordinator.probe(for: expense))
        XCTAssertEqual(p.kind, .fuelReceipt)
        XCTAssertEqual(p.number, "88213")
        XCTAssertEqual(p.date?.iso, "2026-06-10")
        let fresh = SmartExtractionPipeline.run(DocumentText(text: SmartFixtures.lovesFuel), existingRecords: [p])
        XCTAssertEqual(fresh.duplicates.first?.recordID, expense.id?.uuidString)

        let load = Load(profileId: UUID(), loadNumber: "SFB-448812", brokerName: "Summit Freight Brokerage",
                        pickupDate: SimpleDate(year: 2026, month: 9, day: 17)!.date(), totalRevenue: 2850)
        var withID = load
        withID.id = UUID()
        let lp = try XCTUnwrap(SmartImportCoordinator.probe(for: withID))
        XCTAssertEqual(lp.recordType, .load)
        XCTAssertNil(SmartImportCoordinator.probe(for: load), "unsaved records have no id")
    }

    func testPersistKeepsOriginalAndSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smartimport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SmartDocumentStore(rootDirectory: root)
        let original = SmartDocumentReaderTests.textPDF(pages: [["Receipt test document with enough text to read"]])
        var imp = makeImport(SmartFixtures.lovesFuel)
        imp.source = ImportedDocument(images: [], originalData: original, mimeType: "application/pdf")
        let id = UUID()
        SmartImportCoordinator.persist(recordType: .expense, recordID: id, imp: imp,
                                       appliedValues: ["amount": "501.15"], userEditedKeys: ["description"],
                                       title: "Fuel · Love's", store: store)
        let record = try XCTUnwrap(store.record(type: .expense, id: id.uuidString))
        XCTAssertEqual(store.sourceData(filename: record.sourceFilename), original, "original bytes unchanged")
        XCTAssertEqual(record.userEditedKeys, ["description"])
        XCTAssertEqual(record.probe.title, "Fuel · Love's")
        XCTAssertEqual(record.result.kind, .fuelReceipt)

        // Camera scans (no file) keep every page as a PDF.
        var scanned = makeImport(SmartFixtures.lovesFuel)
        scanned.source = ImportedDocument(images: [SmartDocumentReaderTests.textImage(["PAGE ONE"]),
                                                   SmartDocumentReaderTests.textImage(["PAGE TWO"])],
                                          originalData: nil, mimeType: nil)
        let scanID = UUID()
        SmartImportCoordinator.persist(recordType: .expense, recordID: scanID, imp: scanned, appliedValues: [:],
                                       userEditedKeys: [], title: nil, store: store)
        let scanRecord = try XCTUnwrap(store.record(type: .expense, id: scanID.uuidString))
        XCTAssertEqual(scanRecord.sourceMimeType, "application/pdf")
        let pdfData = try XCTUnwrap(store.sourceData(filename: scanRecord.sourceFilename))
        XCTAssertEqual(PDFDocument(data: pdfData)?.pageCount, 2)

        // No record id → nothing is written.
        SmartImportCoordinator.persist(recordType: .expense, recordID: nil, imp: imp, appliedValues: [:],
                                       userEditedKeys: [], title: nil, store: store)
        XCTAssertEqual(store.allRecords().count, 2)
    }
}
