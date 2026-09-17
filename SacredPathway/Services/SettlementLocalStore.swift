import Foundation

// =============================================================================
//  SettlementLocalStore — Free Local Mode persistence for settlements
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). One JSON file next to the other Local Mode
//  files: `Documents/DriverHub/settlements_v1.json`.
//
//  Safety rules (financial history lives here):
//   * Writes are atomic (temp file + rename).
//   * The previous good file is kept as `settlements_v1.previous.json`.
//   * A file that fails to decode is NEVER overwritten. It is copied aside to
//     `settlements_v1.unreadable-<timestamp>.json` and the load throws, so the
//     UI can tell the user instead of silently starting an empty ledger.
// =============================================================================

enum SettlementLocalStoreError: Error, LocalizedError {
    case unreadable(preservedAt: URL?, underlying: Error)
    case writeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url, let e):
            let kept = url.map { " A copy was kept as \($0.lastPathComponent)." } ?? ""
            return "Settlement data on this device could not be read (\(e.localizedDescription)). Nothing was overwritten.\(kept)"
        case .writeFailed(let e):
            return "Settlements could not be saved on this device: \(e.localizedDescription)"
        }
    }
}

final class SettlementLocalStore {

    static let fileName = "settlements_v1.json"
    static let previousFileName = "settlements_v1.previous.json"

    let directory: URL
    private let fileManager: FileManager
    /// Set after an unreadable file was found; saves are refused until the
    /// user resolves it, so the unreadable file cannot be clobbered.
    private(set) var isQuarantined = false

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// The store used by the app — same folder as every other Local Mode file.
    static func appDefault() throws -> SettlementLocalStore {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw SettlementLocalStoreError.writeFailed(
                NSError(domain: "SettlementLocalStore", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Documents folder unavailable"]))
        }
        let dir = docs.appendingPathComponent("DriverHub", isDirectory: true)
        return SettlementLocalStore(directory: dir)
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    var previousURL: URL { directory.appendingPathComponent(Self.previousFileName) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    func load() throws -> SettlementLedger {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
        do {
            let data = try Data(contentsOf: fileURL)
            let ledger = try JSONDecoder().decode(SettlementLedger.self, from: data)
            isQuarantined = false
            return ledger
        } catch {
            isQuarantined = true
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = directory.appendingPathComponent("settlements_v1.unreadable-\(stamp).json")
            let preserved: URL? = (try? fileManager.copyItem(at: fileURL, to: aside)) != nil ? aside : nil
            throw SettlementLocalStoreError.unreadable(preservedAt: preserved, underlying: error)
        }
    }

    func save(_ ledger: SettlementLedger) throws {
        guard !isQuarantined else {
            throw SettlementLocalStoreError.writeFailed(
                NSError(domain: "SettlementLocalStore", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "the existing settlement file could not be read, so it was not overwritten"]))
        }
        do {
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let data = try Self.encoder.encode(ledger)
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: previousURL)
                try? fileManager.copyItem(at: fileURL, to: previousURL)
            }
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw SettlementLocalStoreError.writeFailed(error)
        }
    }

    /// Used by Backup & Restore to replace the ledger wholesale.
    func replace(with ledger: SettlementLedger) throws {
        isQuarantined = false
        try save(ledger)
    }
}
