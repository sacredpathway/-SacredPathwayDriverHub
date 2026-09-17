import XCTest
import UIKit
@testable import SacredPathway

// =============================================================================
//  SettlementBackupRoundTripTests — 2.3.3 integration (2026-09-17)
// -----------------------------------------------------------------------------
//  Validates the BackupService merge: 2.3.3 receipt photos (schema v2) and the
//  Driver Pay & Settlements ledger travel in the same backup, restore together,
//  and a restore REPLACES (never duplicates) either dataset.
//
//  These tests use the app's real Free Local Mode stores (the same ones
//  BackupService uses). The device state found at the start is exported first
//  and imported back at the end, and the previous app mode is restored, so the
//  test host is left as it was. All data is obviously fake ("TEST-…").
// =============================================================================

@MainActor
final class SettlementBackupRoundTripTests: XCTestCase {

    private func sampleJPEG() -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { ctx in
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return image.jpegData(compressionQuality: 0.7)!
    }

    private func seededLedger() throws -> (SettlementLedger, UUID) {
        var ledger = SettlementLedger()
        ledger.localDrivers = [Fx.driver()]
        let id = try Fx.saveDraft([Fx.opLoad(1, gross: 1_234.56)], into: &ledger,
                                  additions: [Fx.addition(1, .bonus, "Bonus", 25)])
        return (ledger, id)
    }

    private func diskLedger() throws -> SettlementLedger {
        try SettlementLocalStore.appDefault().load()
    }

    private func decodeBundle(_ url: URL) throws -> BackupService.Bundle {
        try JSONDecoder().decode(BackupService.Bundle.self, from: Data(contentsOf: url))
    }

    /// Runs `body` in Free Local Mode and puts the device back afterwards.
    private func withIsolatedLocalMode(_ body: () throws -> Void) throws {
        let previousMode = AppMode.shared.mode
        AppMode.shared.setLocal()
        let saved = try BackupService.exportToTempFile()
        defer {
            _ = try? BackupService.importBackup(from: saved)
            try? FileManager.default.removeItem(at: saved)
            switch previousMode {
            case .local:  AppMode.shared.setLocal()
            case .cloud:  AppMode.shared.setCloud()
            case .notSet: AppMode.shared.reset()
            }
        }
        try body()
    }

    func testReceiptPhotosAndSettlementsSurviveRestoreWithoutDuplication() throws {
        try withIsolatedLocalMode {
            // 1–2. Seed one receipt photo and one settlement.
            let jpeg = sampleJPEG()
            let filename = try ReceiptImageStore.shared.save(jpegData: jpeg)
            let expense = Expense(id: UUID(), profileId: Fx.profileId, category: "fuel",
                                  amount: 12.34, vendorName: "TEST VENDOR",
                                  receiptImageFilename: filename)
            LocalLoadsRepository.shared.replaceAll(with: [])
            LocalExpensesRepository.shared.replaceAll(with: [expense])
            let (ledger, settlementId) = try seededLedger()
            try SettlementRepository.shared.replaceLocalLedger(ledger)

            let url = try BackupService.exportToTempFile()
            defer { try? FileManager.default.removeItem(at: url) }
            let exported = try decodeBundle(url)
            XCTAssertEqual(exported.receiptImages?.count, 1)
            XCTAssertEqual(exported.receiptImages?.first?.filename, filename)
            XCTAssertEqual(exported.settlements?.settlements.count, 1)
            XCTAssertEqual(exported.settlements?.settlements.first?.id, settlementId)

            // Change the device so a restore has to put both datasets back.
            ReceiptImageStore.shared.delete(filename: filename)
            LocalExpensesRepository.shared.replaceAll(with: [])
            var other = SettlementLedger()
            _ = try Fx.saveDraft([Fx.opLoad(2, gross: 99)], into: &other)
            other.settlements[0].id = Fx.id(7_777)
            try SettlementRepository.shared.replaceLocalLedger(other)
            XCTAssertNil(ReceiptImageStore.shared.loadData(filename: filename))

            // 3. Restore — twice, to prove it replaces rather than appends.
            for _ in 0..<2 {
                try BackupService.importBackup(from: url)

                // 4. Receipt photo survives, byte for byte, exactly once.
                let expenses = LocalExpensesRepository.shared.expenses
                XCTAssertEqual(expenses.count, 1)
                XCTAssertEqual(expenses.first?.receiptImageFilename, filename)
                XCTAssertEqual(ReceiptImageStore.shared.loadData(filename: filename), jpeg)

                // 5–6. Settlements survive, exactly once, in memory and on disk.
                let inMemory = SettlementRepository.shared.ledger
                let onDisk = try diskLedger()
                for restored in [inMemory, onDisk] {
                    XCTAssertEqual(restored.settlements.map(\.id), [settlementId])
                    XCTAssertEqual(restored.loadLines.count, ledger.loadLines.count)
                    XCTAssertEqual(restored.additions.count, ledger.additions.count)
                    XCTAssertEqual(restored.deductions.count, ledger.deductions.count)
                    XCTAssertEqual(restored.localDrivers.count, 1)
                    XCTAssertEqual(Set(restored.loadLines.map(\.id)).count, restored.loadLines.count)
                }
            }
        }
    }

    func testBackupWithoutSettlementsKeepsExistingSettlementHistory() throws {
        try withIsolatedLocalMode {
            let (ledger, settlementId) = try seededLedger()
            try SettlementRepository.shared.replaceLocalLedger(ledger)

            var bundle = BackupService.currentBundle()
            bundle.settlements = nil            // e.g. a backup made by 2.3.3
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("TEST-no-settlements-\(UUID().uuidString).driverhub-backup")
            try JSONEncoder().encode(bundle).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            try BackupService.importBackup(from: url)
            XCTAssertEqual(try diskLedger().settlements.map(\.id), [settlementId])
            XCTAssertEqual(SettlementRepository.shared.ledger.settlements.map(\.id), [settlementId])
        }
    }

    func testExportReadsSettlementsFromDiskNotAStaleInMemoryCopy() throws {
        try withIsolatedLocalMode {
            // In-memory ledger empty (as before Settlements has loaded) …
            try SettlementRepository.shared.replaceLocalLedger(.empty)
            // … while the file on disk already holds a settlement.
            let (ledger, settlementId) = try seededLedger()
            try SettlementLocalStore.appDefault().save(ledger)
            XCTAssertTrue(SettlementRepository.shared.ledger.settlements.isEmpty)

            let bundle = BackupService.currentBundle()
            XCTAssertEqual(bundle.settlements?.settlements.map(\.id), [settlementId])
        }
    }
}
