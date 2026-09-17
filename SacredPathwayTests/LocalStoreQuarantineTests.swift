import XCTest
@testable import SacredPathway

/// Phase 2 data-loss guard: a corrupt local JSON file must be QUARANTINED
/// (preserved under `<name>.corrupt-<timestamp>`), never silently wiped.
/// Uses unique per-test filenames inside the real LocalStore root (isolated
/// simulator container) and cleans up everything it creates.
@MainActor
final class LocalStoreQuarantineTests: XCTestCase {

    nonisolated(unsafe) private var fileName: String!

    override func setUp() {
        super.setUp()
        fileName = "qtest-\(UUID().uuidString).json"
    }

    override func tearDownWithError() throws {
        // Remove the test file and any quarantine siblings it produced.
        let root = try MainActor.assumeIsolated { try LocalStore.rootURL }
        let items = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )
        for url in items where url.lastPathComponent.hasPrefix(fileName) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func writeRaw(_ string: String) throws {
        let url = try LocalStore.fileURL(named: fileName)
        try string.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    private func quarantineSiblings() throws -> [URL] {
        let root = try LocalStore.rootURL
        return try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("\(fileName!).corrupt-") }
    }

    // MARK: Corrupt array file → empty result + preserved quarantine copy

    func testCorruptArrayFileIsQuarantinedNotWiped() throws {
        try writeRaw("{ this is not valid json !!!")

        let loaded = LocalStore.loadArray(Expense.self, fileName: fileName)
        XCTAssertTrue(loaded.isEmpty, "corrupt file must not decode")

        // Original moved aside — bytes preserved, original name freed.
        let originalURL = try LocalStore.fileURL(named: fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path),
                       "original must be MOVED to quarantine, not left in place")
        let quarantined = try quarantineSiblings()
        XCTAssertEqual(quarantined.count, 1, "exactly one quarantine copy expected")
        let preserved = try String(contentsOf: quarantined[0], encoding: .utf8)
        XCTAssertTrue(preserved.contains("not valid json"),
                      "quarantined bytes must be identical to the corrupt input")

        // The slot is reusable: a fresh save + load round-trips normally.
        let expense = Fixtures.expense(amount: 42)
        XCTAssertTrue(LocalStore.saveArray([expense], fileName: fileName))
        let reloaded = LocalStore.loadArray(Expense.self, fileName: fileName)
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded[0].amount, 42, accuracy: 0.001)
    }

    // MARK: Wrong-shape (valid JSON, wrong schema) also quarantines

    func testWrongShapeJSONQuarantines() throws {
        try writeRaw(#"[{"totally": "unrelated", "shape": 1}]"#)
        let loaded = LocalStore.loadArray(Expense.self, fileName: fileName)
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertEqual(try quarantineSiblings().count, 1)
    }

    // MARK: Healthy files are untouched by the guard

    func testValidFileRoundTripsWithoutQuarantine() throws {
        let expense = Fixtures.expense(amount: 88)
        XCTAssertTrue(LocalStore.saveArray([expense], fileName: fileName))
        let loaded = LocalStore.loadArray(Expense.self, fileName: fileName)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(try quarantineSiblings().count, 0,
                       "healthy files must never be quarantined")
    }

    // MARK: Missing file is first-launch, not corruption

    func testMissingFileReturnsEmptyWithoutQuarantine() throws {
        let loaded = LocalStore.loadArray(Expense.self, fileName: fileName)
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertEqual(try quarantineSiblings().count, 0)
    }

    // MARK: loadObject path has the same guard

    func testCorruptObjectFileQuarantines() throws {
        try writeRaw("not even json")
        let loaded = LocalStore.loadObject(BackupService.ReceiptImagePayload.self,
                                           fileName: fileName)
        XCTAssertNil(loaded)
        XCTAssertEqual(try quarantineSiblings().count, 1)
    }
}
