import XCTest
#if canImport(SmartCore)
@testable import SmartCore
#else
@testable import SacredPathway
#endif

final class SmartDocumentStoreTests: XCTestCase {

    private var root: URL!
    private var store: SmartDocumentStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("smartdocs-\(UUID().uuidString)")
        store = SmartDocumentStore(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRecord(id: String, source: String?) -> SmartDocumentRecord {
        let result = SmartExtractionPipeline.run(DocumentText(text: SmartFixtures.lovesFuel), fingerprint: "fp-\(id)")
        return SmartDocumentRecord(recordType: .expense, recordID: id, savedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                   sourceFilename: source, sourceMimeType: "application/pdf", fingerprint: result.fingerprint,
                                   result: result, appliedValues: ["amount": "501.15"], userEditedKeys: ["description"],
                                   probe: result.duplicateProbe(recordID: id))
    }

    func testOriginalBytesAreStoredUnchanged() throws {
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let name = try store.saveSource(bytes, mimeType: "application/pdf")
        XCTAssertTrue(name.hasSuffix(".pdf"))
        XCTAssertEqual(store.sourceData(filename: name), bytes)
        XCTAssertEqual(DocumentFingerprint.sha256Hex(store.sourceData(filename: name)!), DocumentFingerprint.sha256Hex(bytes))
        XCTAssertNotNil(store.sourceURL(filename: name))
        XCTAssertThrowsError(try store.saveSource(Data(), mimeType: nil))
    }

    func testRecordRoundTripAndProbes() throws {
        let name = try store.saveSource(Data("pdf".utf8), mimeType: "application/pdf")
        let record = makeRecord(id: "8F2C1D9A-0000-4000-8000-000000000001", source: name)
        try store.save(record)
        let loaded = try XCTUnwrap(store.record(type: .expense, id: record.recordID))
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(store.probes().map(\.recordID), [record.recordID])
        XCTAssertEqual(store.probes().first?.fingerprint, "fp-8F2C1D9A-0000-4000-8000-000000000001")
    }

    func testDeleteRemovesRecordAndSource() throws {
        let name = try store.saveSource(Data("img".utf8), mimeType: "image/jpeg")
        try store.save(makeRecord(id: "r1", source: name))
        store.delete(type: .expense, id: "r1")
        XCTAssertNil(store.record(type: .expense, id: "r1"))
        XCTAssertNil(store.sourceData(filename: name))
    }

    func testOrphanSweepKeepsReferencedFiles() throws {
        let kept = try store.saveSource(Data("a".utf8), mimeType: "image/png")
        let orphan = try store.saveSource(Data("b".utf8), mimeType: "image/png")
        try store.save(makeRecord(id: "r2", source: kept))
        XCTAssertEqual(store.sweepOrphanSources(), 1)
        XCTAssertNotNil(store.sourceData(filename: kept))
        XCTAssertNil(store.sourceData(filename: orphan))
    }

    func testUnsafeFilenamesAreRejected() {
        XCTAssertNil(store.sourceData(filename: "../secrets.txt"))
        XCTAssertNil(store.sourceData(filename: "/etc/passwd"))
        XCTAssertNil(store.sourceURL(filename: nil))
    }

    func testStoredRecordNeverContainsFullCardNumber() throws {
        let result = SmartExtractionPipeline.run(DocumentText(text: "Pilot #1\nDiesel 10.000 gal @ 4.000 40.00\nTotal 40.00\nVISA 4111111111111234"))
        let record = SmartDocumentRecord(recordType: .expense, recordID: "r3", savedAt: Date(), sourceFilename: nil,
                                         sourceMimeType: nil, fingerprint: nil, result: result, appliedValues: [:],
                                         userEditedKeys: [], probe: result.duplicateProbe(recordID: "r3"))
        try store.save(record)
        let raw = try String(contentsOf: try store.directory().appendingPathComponent("record-expense-r3.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("4111111111111234"))
        XCTAssertTrue(raw.contains("1234"))
    }
}
