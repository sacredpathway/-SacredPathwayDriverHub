import Foundation

// =============================================================================
// MARK: - SmartDocumentStore — original documents + extraction snapshots
// -----------------------------------------------------------------------------
// Keeps, on this device, for every record created from an imported document:
//   • the ORIGINAL bytes exactly as imported (PDF or image — never re-encoded),
//   • the extraction snapshot (masked text, per-field confidence, line items),
//   • which values were auto-filled and which the user typed.
// Layout: Documents/DriverHub/SmartDocuments/
//           source-<uuid>.<ext>
//           record-<type>-<id>.json
// No schema change, no upload. Writes are best-effort and never block a save.
// =============================================================================

nonisolated struct SmartDocumentRecord: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var version: Int = SmartDocumentRecord.currentVersion
    var recordType: DuplicateProbe.RecordType
    var recordID: String
    var savedAt: Date
    var sourceFilename: String?
    var sourceMimeType: String?
    var fingerprint: String?
    var result: SmartExtractionResult
    /// Values the importer put into the form (key → value).
    var appliedValues: [String: String]
    /// Keys the user changed or typed before saving.
    var userEditedKeys: [String]
    /// A comparable summary used for duplicate warnings on later imports.
    var probe: DuplicateProbe
}

nonisolated final class SmartDocumentStore: @unchecked Sendable {

    enum StoreError: Error, LocalizedError {
        case directoryUnavailable
        case emptyData
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .directoryUnavailable: return "Document storage isn't available on this device."
            case .emptyData: return "The document was empty."
            case .writeFailed(let m): return "The document couldn't be saved: \(m)"
            }
        }
    }

    static let subdirectoryName = "SmartDocuments"

    /// App-wide instance rooted at `Documents/DriverHub` (same root as LocalStore).
    static let shared = SmartDocumentStore(rootDirectory: nil)

    private let overrideRoot: URL?
    private let lock = NSLock()

    init(rootDirectory: URL?) {
        self.overrideRoot = rootDirectory
    }

    // MARK: Paths

    func directory() throws -> URL {
        let base: URL
        if let overrideRoot {
            base = overrideRoot
        } else {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw StoreError.directoryUnavailable
            }
            base = docs.appendingPathComponent("DriverHub", isDirectory: true)
        }
        let dir = base.appendingPathComponent(Self.subdirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { throw StoreError.directoryUnavailable }
        }
        return dir
    }

    static func fileExtension(for mimeType: String?) -> String {
        switch mimeType?.lowercased() {
        case "application/pdf": return "pdf"
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "image/jpeg", "image/jpg": return "jpg"
        default: return "bin"
        }
    }

    static func isSafeFilename(_ name: String?) -> Bool {
        guard let name, !name.isEmpty, name.count < 120 else { return false }
        return !name.contains("/") && !name.contains("..") && !name.hasPrefix(".")
    }

    private func recordFilename(_ type: DuplicateProbe.RecordType, _ id: String) -> String {
        let safeID = id.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "record-\(type.rawValue)-\(safeID).json"
    }

    // MARK: Source documents

    /// Writes the original bytes unchanged and returns the filename.
    @discardableResult
    func saveSource(_ data: Data, mimeType: String?) throws -> String {
        guard !data.isEmpty else { throw StoreError.emptyData }
        let name = "source-\(UUID().uuidString.lowercased()).\(Self.fileExtension(for: mimeType))"
        let url = try directory().appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic) }
        catch { throw StoreError.writeFailed(error.localizedDescription) }
        return name
    }

    func sourceData(filename: String?) -> Data? {
        guard Self.isSafeFilename(filename), let dir = try? directory() else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(filename!))
    }

    func sourceURL(filename: String?) -> URL? {
        guard Self.isSafeFilename(filename), let dir = try? directory() else { return nil }
        let url = dir.appendingPathComponent(filename!)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Records

    func save(_ record: SmartDocumentRecord) throws {
        lock.lock(); defer { lock.unlock() }
        let url = try directory().appendingPathComponent(recordFilename(record.recordType, record.recordID))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { try encoder.encode(record).write(to: url, options: .atomic) }
        catch { throw StoreError.writeFailed(error.localizedDescription) }
    }

    func record(type: DuplicateProbe.RecordType, id: String) -> SmartDocumentRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let dir = try? directory(),
              let data = try? Data(contentsOf: dir.appendingPathComponent(recordFilename(type, id))) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(SmartDocumentRecord.self, from: data)
    }

    func allRecords() -> [SmartDocumentRecord] {
        lock.lock(); defer { lock.unlock() }
        guard let dir = try? directory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        return names.filter { $0.hasPrefix("record-") && $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
            return try? decoder.decode(SmartDocumentRecord.self, from: data)
        }
    }

    /// Probes of everything imported before (for duplicate warnings).
    func probes() -> [DuplicateProbe] {
        allRecords().map(\.probe)
    }

    /// Removes a record and its source file (e.g. when the record is deleted).
    func delete(type: DuplicateProbe.RecordType, id: String) {
        let existing = record(type: type, id: id)
        lock.lock(); defer { lock.unlock() }
        guard let dir = try? directory() else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(recordFilename(type, id)))
        if let name = existing?.sourceFilename, Self.isSafeFilename(name) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Removes source files no record points at (interrupted saves).
    @discardableResult
    func sweepOrphanSources() -> Int {
        let referenced = Set(allRecords().compactMap(\.sourceFilename))
        lock.lock(); defer { lock.unlock() }
        guard let dir = try? directory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix("source-") && !referenced.contains(name) {
            if (try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}
