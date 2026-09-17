import Foundation
import UIKit

// =============================================================================
//  BackupService — Free Local Mode export/import
// -----------------------------------------------------------------------------
//  Produces and consumes a single `.driverhub-backup` file. The file is a
//  JSON bundle with a versioned manifest and every on-device repository's
//  data inline. Single file = atomic AirDrop / Files share / iCloud Drive
//  drop, and a trivially auditable round-trip (open it in any text editor
//  and you can see exactly what's in your backup).
//
//  Why JSON (and not a real .zip)
//  ------------------------------
//  iOS does not ship a public-API zip reader. NSFileCoordinator can WRITE a
//  zip but cannot READ one without a third-party dependency. To keep
//  Phase D's "no new SPM deps" rule and still ship a one-tap backup file,
//  we put everything in a single JSON. The internal structure mirrors the
//  layout described in LOCAL_MODE_PLAN.md §5 (named top-level keys per
//  domain), so a future migration to a true zip-of-folders is a
//  serialization-format swap, not a data-model migration.
//
//  Schema version is bumped any time the bundle format changes in a way
//  that older versions of the app can't read.
// =============================================================================

@MainActor
enum BackupService {

    // MARK: - Constants

    /// Increment when the on-disk bundle layout changes incompatibly.
    ///
    /// v2 (2026-07-04, Phase 1 · Task 3): adds `receiptImages` — base64 JPEG
    /// payloads for every expense receipt photo — plus optional manifest
    /// counts. v1 files still import fine (images simply absent); v2 files
    /// are refused by v1 apps via the existing schema check, which is the
    /// correct forward-compatibility behavior.
    static let currentSchemaVersion = 2

    /// Cumulative raw-bytes cap for embedded receipt images. Receipts are
    /// stored ≤1800 px JPEG(0.7) ≈ 150–400 KB each, so this covers ~800+
    /// receipts. Beyond the cap the remaining images are skipped and the
    /// count is surfaced in `manifest.receiptImagesSkipped` — the JSON
    /// encoder holds the whole bundle in memory, so an unbounded embed
    /// could OOM on older devices.
    static let maxEmbeddedReceiptBytes = 250 * 1024 * 1024

    /// File extension used when exporting. iOS treats unknown extensions
    /// gracefully on import; the actual format check happens against the
    /// manifest, not the extension.
    static let fileExtension = "driverhub-backup"

    // MARK: - Errors

    enum BackupError: Error, LocalizedError {
        case writeFailed(underlying: Error)
        case readFailed(underlying: Error)
        case decodingFailed(underlying: Error)
        case unsupportedSchema(found: Int, max: Int)
        case fileNotFound
        case fileAccessDenied

        var errorDescription: String? {
            switch self {
            case .writeFailed(let e):     return "Couldn't write the backup file: \(e.localizedDescription)"
            case .readFailed(let e):      return "Couldn't read the backup file: \(e.localizedDescription)"
            case .decodingFailed(let e):  return "This file doesn't look like a Driver Hub backup. (\(e.localizedDescription))"
            case .unsupportedSchema(let f, let m):
                return "This backup was made with a newer version of Driver Hub (schema \(f)). Update the app to import it. (max supported: \(m))"
            case .fileNotFound:           return "Couldn't find the backup file on disk."
            case .fileAccessDenied:       return "Driver Hub doesn't have permission to read that file."
            }
        }
    }

    // MARK: - Manifest + bundle shape

    /// Top-level identifying / counting metadata. Decoded first so the UI
    /// can preview the backup before the user confirms an overwrite.
    struct Manifest: Codable, Equatable {
        var schemaVersion: Int
        var appBuild: String?           // CFBundleVersion
        var appVersion: String?         // CFBundleShortVersionString
        var backupTimestamp: Date
        var deviceName: String
        var deviceModel: String?
        var installId: UUID
        var counts: Counts
        /// v2: number of receipt images embedded in this backup. nil on v1
        /// files (optional → decodes forwards/backwards compatibly).
        var receiptImageCount: Int?
        /// v2: how many receipt images were SKIPPED because the backup hit
        /// `maxEmbeddedReceiptBytes`. nil/0 in the normal case.
        var receiptImagesSkipped: Int?

        struct Counts: Codable, Equatable {
            var loads: Int
            var brokers: Int
            var brokerContacts: Int
            var expenses: Int
        }
    }

    /// v2: one embedded receipt photo. `jpegBase64` is the exact bytes from
    /// ReceiptImageStore, so restore reproduces the identical file.
    struct ReceiptImagePayload: Codable, Equatable {
        var filename: String
        var jpegBase64: String
    }

    /// Captured app preferences that aren't living in a repository.
    struct Preferences: Codable, Equatable {
        /// Pay-week first weekday — 1 (Sunday) to 7 (Saturday).
        var payWeekFirstWeekday: Int?
        /// Optional appearance mode — light / dark / system. Saved as a
        /// plain string so future enum additions decode forwards-compatibly.
        var appearanceMode: String?
    }

    /// Full bundle written to disk. Manifest comes first so a partial /
    /// truncated read can still surface metadata to the user before the
    /// rest of the JSON is parsed.
    struct Bundle: Codable {
        var manifest: Manifest
        var loads: [Load]
        var brokers: [Broker]
        var brokerContacts: [BrokerContact]
        var expenses: [Expense]
        var preferences: Preferences
        /// v2: embedded receipt photos. Optional so v1 backups decode.
        var receiptImages: [ReceiptImagePayload]?
    }

    // MARK: - Export

    /// Build the in-memory `Bundle` from the current state of every local
    /// repository plus user preferences.
    static func currentBundle() -> Bundle {
        let loads    = LocalLoadsRepository.shared.loads
        let brokers  = LocalBrokersRepository.shared.brokers
        let contacts = LocalBrokerContactsRepository.shared.contacts
        let expenses = LocalExpensesRepository.shared.expenses

        // v2: embed receipt photos (Task 3 — backups must carry the images,
        // not just the rows). Missing files are counted as skipped rather
        // than failing the whole export — a backup with 199 of 200 images
        // beats no backup.
        var receiptImages: [ReceiptImagePayload] = []
        var embeddedBytes = 0
        var skipped = 0
        for expense in expenses {
            guard let filename = expense.receiptImageFilename else { continue }
            guard let data = ReceiptImageStore.shared.loadData(filename: filename) else {
                skipped += 1   // row references a file that's gone
                continue
            }
            if embeddedBytes + data.count > maxEmbeddedReceiptBytes {
                skipped += 1
                continue
            }
            embeddedBytes += data.count
            receiptImages.append(
                ReceiptImagePayload(filename: filename,
                                    jpegBase64: data.base64EncodedString())
            )
        }

        let infoDict = Foundation.Bundle.main.infoDictionary
        let manifest = Manifest(
            schemaVersion: currentSchemaVersion,
            appBuild: infoDict?["CFBundleVersion"] as? String,
            appVersion: infoDict?["CFBundleShortVersionString"] as? String,
            backupTimestamp: Date(),
            deviceName: UIDevice.current.name,
            deviceModel: UIDevice.current.model,
            installId: AppMode.shared.localInstallId,
            counts: Manifest.Counts(
                loads: loads.count,
                brokers: brokers.count,
                brokerContacts: contacts.count,
                expenses: expenses.count
            ),
            receiptImageCount: receiptImages.count,
            receiptImagesSkipped: skipped > 0 ? skipped : nil
        )

        let prefs = Preferences(
            payWeekFirstWeekday: PayWeekService.shared.firstWeekday,
            appearanceMode: AppearanceService.shared.mode.rawValue
        )

        return Bundle(
            manifest: manifest,
            loads: loads,
            brokers: brokers,
            brokerContacts: contacts,
            expenses: expenses,
            preferences: prefs,
            receiptImages: receiptImages.isEmpty ? nil : receiptImages
        )
    }

    /// Serialize the current bundle to a temp file and return its URL.
    /// Caller hands this URL to a `ShareLink` so the user can AirDrop /
    /// Save to Files / email / iCloud Drive it.
    static func exportToTempFile() throws -> URL {
        let bundle = currentBundle()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(bundle)
        } catch {
            throw BackupError.writeFailed(underlying: error)
        }

        let filename = exportFilename(for: bundle.manifest.backupTimestamp)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: .atomic)
            #if DEBUG
            print("[SP_DEBUG_LOCAL] BackupService.exportToTempFile → \(url.path) (\(data.count) bytes)")
            #endif
            return url
        } catch {
            throw BackupError.writeFailed(underlying: error)
        }
    }

    /// `DriverHubBackup-YYYY-MM-DD-HHmm.driverhub-backup`.
    private static func exportFilename(for date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale   = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "DriverHubBackup-\(f.string(from: date)).\(fileExtension)"
    }

    // MARK: - Import — validate (decode manifest only)

    /// Decode just the manifest portion of a backup so the UI can show
    /// the user what they're about to import BEFORE the overwrite. Throws
    /// if the file isn't a Driver Hub backup at all, or the schema is too
    /// new for this app to handle.
    static func validate(at url: URL) throws -> Manifest {
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BackupError.fileNotFound
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BackupError.readFailed(underlying: error)
        }

        // Decode just the manifest first — fail fast on corrupt / wrong-format
        // files without paying the cost of decoding thousands of loads.
        struct ManifestOnly: Codable {
            var manifest: Manifest
        }
        let manifestOnly: ManifestOnly
        do {
            manifestOnly = try JSONDecoder().decode(ManifestOnly.self, from: data)
        } catch {
            throw BackupError.decodingFailed(underlying: error)
        }

        if manifestOnly.manifest.schemaVersion > currentSchemaVersion {
            throw BackupError.unsupportedSchema(
                found: manifestOnly.manifest.schemaVersion,
                max: currentSchemaVersion
            )
        }

        return manifestOnly.manifest
    }

    // MARK: - Import — apply (replace local data)

    /// Decode the full bundle and atomically replace every repository.
    ///
    /// "Atomic" here = per-file atomic write via LocalStore.saveArray; the
    /// in-memory caches are replaced sequentially. In the unlikely event
    /// of an OS-level write failure mid-import, the user is left with a
    /// mix of old + new data — same exposure level as iOS's own iCloud
    /// restore. Schema-version + JSON-shape checks at the top fail the
    /// import fully before we touch any repo, which is where the real
    /// safety lives.
    @discardableResult
    static func importBackup(from url: URL) throws -> Manifest {
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BackupError.fileNotFound
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BackupError.readFailed(underlying: error)
        }

        let bundle: Bundle
        do {
            bundle = try JSONDecoder().decode(Bundle.self, from: data)
        } catch {
            throw BackupError.decodingFailed(underlying: error)
        }
        if bundle.manifest.schemaVersion > currentSchemaVersion {
            throw BackupError.unsupportedSchema(
                found: bundle.manifest.schemaVersion,
                max: currentSchemaVersion
            )
        }

        // ── v2: restore receipt image files BEFORE replacing the expense
        //    rows, so the moment the UI reloads, every restored expense's
        //    thumbnail resolves. Individual file failures don't abort the
        //    import (row data is more important than one photo).
        var restoredImages = 0
        if let images = bundle.receiptImages {
            for payload in images {
                guard ReceiptImageStore.isValidFilename(payload.filename),
                      let data = Data(base64Encoded: payload.jpegBase64),
                      !data.isEmpty else { continue }
                if (try? ReceiptImageStore.shared.save(
                    jpegData: data, preferredFilename: payload.filename)) != nil {
                    restoredImages += 1
                }
            }
        }

        // ── Replace every local repo. Order doesn't matter for correctness
        //    because the references inside the data (broker_id, load_id)
        //    are UUID-based and don't run through any DB FK validation.
        LocalBrokersRepository.shared.replaceAll(with: bundle.brokers)
        LocalBrokerContactsRepository.shared.replaceAll(with: bundle.brokerContacts)
        LocalLoadsRepository.shared.replaceAll(with: bundle.loads)
        LocalExpensesRepository.shared.replaceAll(with: bundle.expenses)

        // ── Replace-mode restore: receipts belonging to the PREVIOUS data
        //    set are now orphans — sweep anything the restored expenses
        //    don't reference (matches the destructive replace semantics of
        //    the rows themselves).
        let referenced = Set(bundle.expenses.compactMap { $0.receiptImageFilename })
        let sweptOrphans = ReceiptImageStore.shared.sweepOrphans(referencedFilenames: referenced)
        #if DEBUG
        print("[SP_DEBUG_LOCAL] BackupService.import → restored \(restoredImages) receipt image(s), swept \(sweptOrphans) orphan(s)")
        #endif

        // ── Apply preferences. Each setter no-ops on nil so a partial
        //    preferences payload is safe. Both services persist on
        //    didSet, so a plain assignment flushes to UserDefaults.
        if let wd = bundle.preferences.payWeekFirstWeekday, (1...7).contains(wd) {
            PayWeekService.shared.firstWeekday = wd
        }
        if let modeRaw = bundle.preferences.appearanceMode,
           let mode = AppearanceMode(rawValue: modeRaw) {
            AppearanceService.shared.mode = mode
        }

        #if DEBUG
        print("[SP_DEBUG_LOCAL] BackupService.import → loads=\(bundle.loads.count) brokers=\(bundle.brokers.count) contacts=\(bundle.brokerContacts.count) expenses=\(bundle.expenses.count)")
        #endif
        return bundle.manifest
    }

    // MARK: - Cleanup

    /// Delete temp export files so we don't leak large JSON blobs into
    /// the system /tmp directory across launches.
    static func cleanupTempExports() {
        let tmp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(at: tmp,
                                                                       includingPropertiesForKeys: nil) else { return }
        for item in items where item.pathExtension == fileExtension {
            try? FileManager.default.removeItem(at: item)
        }
    }
}
