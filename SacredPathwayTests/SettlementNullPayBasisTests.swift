import XCTest
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

// =============================================================================
//  D1 — `settlement_loads.pay_basis_description` is nullable in Postgres while
//  the Swift field is a non-optional String. Before the defensive decoder a
//  single NULL row made the whole array decode throw, so the Settlements
//  screen and the Driver Portal loaded nothing at all.
//  These tests pin the tolerant behaviour and prove encoding is unchanged.
// =============================================================================

@MainActor
final class SettlementNullPayBasisTests: XCTestCase {

    private nonisolated(unsafe) var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sph-d1-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    /// A real load line as a JSON object, so the row shape always matches the
    /// model rather than a hand-written fixture that can drift.
    private func rowObject(_ line: SettlementLoadLine) throws -> [String: Any] {
        try SettlementRowCodec.jsonObject(line)
    }

    private func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    // MARK: 1–3 decoding

    func testNullPayBasisDecodesAsEmptyString() throws {
        var row = try rowObject(Fx.load(1, gross: 1_000))
        row["pay_basis_description"] = NSNull()
        let lines = try SettlementRowCodec.decodeRows(SettlementLoadLine.self, from: data([row]))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].payBasisDescription, "")
        XCTAssertEqual(lines[0].loadNumber, "TEST-1")
    }

    func testMissingPayBasisKeyDecodesAsEmptyString() throws {
        var row = try rowObject(Fx.load(2, gross: 1_000))
        row.removeValue(forKey: "pay_basis_description")
        let lines = try SettlementRowCodec.decodeRows(SettlementLoadLine.self, from: data([row]))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].payBasisDescription, "")
    }

    func testOneNullRowDoesNotFailTheWholeArray() throws {
        var good1 = try rowObject(Fx.load(3, gross: 1_000, sortOrder: 0))
        good1["pay_basis_description"] = "70% of gross"
        var bad = try rowObject(Fx.load(4, gross: 2_000, sortOrder: 1))
        bad["pay_basis_description"] = NSNull()
        var good2 = try rowObject(Fx.load(5, gross: 3_000, sortOrder: 2))
        good2["pay_basis_description"] = "$0.585/mi loaded"

        let lines = try SettlementRowCodec.decodeRows(
            SettlementLoadLine.self, from: data([good1, bad, good2]))

        XCTAssertEqual(lines.count, 3, "one NULL row must not drop the other rows")
        XCTAssertEqual(lines.map(\.payBasisDescription), ["70% of gross", "", "$0.585/mi loaded"])
    }

    // MARK: 4 encoding is unchanged

    func testEmptyPayBasisEncodesAsEmptyStringNotNull() throws {
        var line = Fx.load(6, gross: 1_000)
        line.payBasisDescription = ""
        let object = try rowObject(line)
        XCTAssertEqual(object["pay_basis_description"] as? String, "")
        XCTAssertFalse(object["pay_basis_description"] is NSNull)

        line.payBasisDescription = "70% of gross"
        let json = String(decoding: try SettlementRowCodec.encodeRows([line]), as: UTF8.self)
        XCTAssertTrue(json.contains("\"pay_basis_description\":\"70% of gross\""))
    }

    // MARK: 5 ledger level

    func testLedgerWithNullPayBasisLineStillLoads() throws {
        var ledger = SettlementLedger()
        ledger.settlements = [Fx.settlement()]
        ledger.loadLines = [Fx.load(7, gross: 1_500), Fx.load(8, gross: 900, sortOrder: 1)]

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try SettlementRowCodec.encoder.encode(ledger))
                as? [String: Any])
        var lines = try XCTUnwrap(object["load_lines"] as? [[String: Any]])
        lines[0]["pay_basis_description"] = NSNull()
        object["load_lines"] = lines

        let back = try SettlementRowCodec.decoder.decode(
            SettlementLedger.self, from: try data(object))

        XCTAssertEqual(back.settlements.count, 1, "the whole ledger must still load")
        XCTAssertEqual(back.loadLines.count, 2)
        XCTAssertEqual(back.loadLines[0].payBasisDescription, "")
    }

    // MARK: 6 local store / backup restore of an older representation

    func testLocalStoreLoadsLedgerWhenPayBasisKeyIsAbsent() throws {
        let store = SettlementLocalStore(directory: dir)
        var ledger = SettlementLedger()
        ledger.settlements = [Fx.settlement()]
        ledger.loadLines = [Fx.load(9, gross: 2_100)]
        try store.save(ledger)

        // Rewrite the saved file the way an older build would have: the key is
        // simply not there.
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: store.fileURL))
                as? [String: Any])
        var lines = try XCTUnwrap(object["load_lines"] as? [[String: Any]])
        lines[0].removeValue(forKey: "pay_basis_description")
        object["load_lines"] = lines
        try data(object).write(to: store.fileURL, options: .atomic)

        let back = try SettlementLocalStore(directory: dir).load()
        XCTAssertEqual(back.settlements.count, 1)
        XCTAssertEqual(back.loadLines.count, 1)
        XCTAssertEqual(back.loadLines[0].payBasisDescription, "")
    }
}
