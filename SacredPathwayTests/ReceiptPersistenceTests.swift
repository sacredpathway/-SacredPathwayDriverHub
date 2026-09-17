import XCTest
import UIKit
@testable import SacredPathway

/// Task 3 guarantees: receipt files are durable, cleaned up, backup-safe,
/// and the app never records a filename whose file doesn't exist.
@MainActor
final class ReceiptPersistenceTests: XCTestCase {

    nonisolated(unsafe) private var tempRoot: URL!
    nonisolated(unsafe) private var store: ReceiptImageStore!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let root = tempRoot!
        store = MainActor.assumeIsolated {
            ReceiptImageStore(rootDirectory: root)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func sampleImage(side: CGFloat = 100) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    // MARK: Save → exists → load round-trip

    func testSaveWritesFileAndFilenameResolves() throws {
        let filename = try store.save(sampleImage())
        XCTAssertTrue(filename.hasPrefix("receipt-"))
        XCTAssertTrue(filename.hasSuffix(".jpg"))
        XCTAssertNotNil(store.imageURL(for: filename), "saved file must resolve")
        XCTAssertNotNil(store.loadImage(filename: filename), "saved file must decode as an image")
        XCTAssertNotNil(store.loadData(filename: filename))
    }

    func testFilenameResolutionIsRelative_survivesNewStoreInstance() throws {
        // Simulates relaunch: a NEW store over the same root resolves the
        // same filename (nothing depends on in-memory state or absolute
        // paths captured at save time).
        let filename = try store.save(sampleImage())
        let relaunched = ReceiptImageStore(rootDirectory: tempRoot)
        XCTAssertNotNil(relaunched.imageURL(for: filename))
    }

    func testLargeImageIsDownscaled() throws {
        let big = sampleImage(side: 4000)
        let filename = try store.save(big)
        let stored = try XCTUnwrap(store.loadImage(filename: filename))
        XCTAssertLessThanOrEqual(max(stored.size.width, stored.size.height), 1801,
                                 "stored receipts are capped at 1800 px longest edge")
    }

    // MARK: Failure honesty

    func testEmptyDataThrows_neverPretendSaved() {
        XCTAssertThrowsError(try store.save(jpegData: Data())) { error in
            XCTAssertTrue(error is ReceiptImageStore.StoreError)
        }
    }

    func testMissingFileReturnsNilNotGarbage() {
        XCTAssertNil(store.imageURL(for: "receipt-nonexistent.jpg"))
        XCTAssertNil(store.loadImage(filename: "receipt-nonexistent.jpg"))
        XCTAssertNil(store.loadImage(filename: nil))
    }

    // MARK: Deletion + orphan sweep

    func testDeleteRemovesFileAndIsIdempotent() throws {
        let filename = try store.save(sampleImage())
        store.delete(filename: filename)
        XCTAssertNil(store.imageURL(for: filename))
        store.delete(filename: filename) // second delete: no crash, no effect
        store.delete(filename: nil)
    }

    func testOrphanSweepRemovesOnlyUnreferencedFiles() throws {
        let keep = try store.save(sampleImage())
        let orphan1 = try store.save(sampleImage())
        let orphan2 = try store.save(sampleImage())

        let removed = store.sweepOrphans(referencedFilenames: [keep])

        XCTAssertEqual(removed, 2)
        XCTAssertNotNil(store.imageURL(for: keep))
        XCTAssertNil(store.imageURL(for: orphan1))
        XCTAssertNil(store.imageURL(for: orphan2))
    }

    // MARK: Path-traversal guard (backup files are user-provided input)

    func testTraversalFilenamesAreRejected() {
        XCTAssertFalse(ReceiptImageStore.isValidFilename("../../evil.jpg"))
        XCTAssertFalse(ReceiptImageStore.isValidFilename("a/b.jpg"))
        XCTAssertFalse(ReceiptImageStore.isValidFilename(""))
        XCTAssertFalse(ReceiptImageStore.isValidFilename(nil))
        XCTAssertTrue(ReceiptImageStore.isValidFilename("receipt-abc.jpg"))
        XCTAssertNil(store.imageURL(for: "../escape.jpg"))
    }

    // MARK: Expense model round-trip (local JSON + cloud body shape)

    func testExpenseCodableRoundTripWithReceiptFilename() throws {
        let expense = Fixtures.expense(amount: 88.5)
        var withReceipt = expense
        withReceipt.receiptImageFilename = "receipt-test.jpg"

        let data = try JSONEncoder().encode(withReceipt)
        let decoded = try JSONDecoder().decode(Expense.self, from: data)
        XCTAssertEqual(decoded.receiptImageFilename, "receipt-test.jpg")

        // nil filename → key ABSENT from the payload (cloud-safe before the
        // receipt_image_filename migration is applied).
        let bare = try JSONEncoder().encode(expense)
        let json = String(data: bare, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("receipt_image_filename"),
                       "nil receipts must not emit the column key")

        // Old rows (no key at all) still decode.
        let legacy = try JSONDecoder().decode(Expense.self, from: bare)
        XCTAssertNil(legacy.receiptImageFilename)
    }

    // MARK: Backup payload v2 + v1 compatibility

    @MainActor
    func testBackupPayloadRoundTripAndV1Decode() throws {
        let payload = BackupService.ReceiptImagePayload(
            filename: "receipt-abc.jpg",
            jpegBase64: Data([0xFF, 0xD8, 0xFF]).base64EncodedString()
        )
        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(BackupService.ReceiptImagePayload.self, from: encoded)
        XCTAssertEqual(decoded, payload)

        // A v1-shaped manifest (no receipt fields) must still decode —
        // optional fields land as nil.
        let v1ManifestJSON = """
        {"schemaVersion":1,"backupTimestamp":0,"deviceName":"iPhone",
         "installId":"00000000-0000-0000-0000-0000000000AA",
         "counts":{"loads":0,"brokers":0,"brokerContacts":0,"expenses":0}}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let manifest = try decoder.decode(BackupService.Manifest.self, from: v1ManifestJSON)
        XCTAssertNil(manifest.receiptImageCount)
        XCTAssertNil(manifest.receiptImagesSkipped)
        XCTAssertEqual(manifest.schemaVersion, 1)
    }

    // MARK: Restore semantics building block

    func testRestoreStylePreferredFilenameWrite() throws {
        // Backup restore writes the ORIGINAL filename so expense rows keep
        // resolving. Verify preferredFilename is honored byte-for-byte.
        let original = try XCTUnwrap(sampleImage().jpegData(compressionQuality: 0.7))
        let name = try store.save(jpegData: original, preferredFilename: "receipt-restored.jpg")
        XCTAssertEqual(name, "receipt-restored.jpg")
        XCTAssertEqual(store.loadData(filename: name), original)
    }
}
