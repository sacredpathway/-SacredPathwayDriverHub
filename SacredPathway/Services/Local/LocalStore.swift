import Foundation

// =============================================================================
//  LocalStore — JSON-on-disk storage for Free Local Mode (Phase B)
// -----------------------------------------------------------------------------
//  Generic Codable container. Each repository owns one file path under
//  `Documents/DriverHub/`. Reads load the whole array into memory once;
//  writes flush the whole array back atomically. For free-tier carriers
//  (<2,000 records/year) the read/write cost is negligible.
//
//  Date handling note:
//  Every model already implements its own `init(from:)` / `encode(to:)`
//  via SPDate (Postgres DATE vs TIMESTAMPTZ shapes). LocalStore uses a
//  vanilla JSONEncoder/Decoder so those custom encodings still fire —
//  the round-trip stays bit-identical to what we send to Supabase, which
//  is exactly what the future cloud-migration phase will need.
//
//  Threading:
//  Synchronous file I/O on the calling thread. Repositories that read at
//  startup do so on the main actor; that's safe because the files are
//  small and the read happens off the hot path (in the repo's init).
// =============================================================================

enum LocalStoreError: Error, LocalizedError {
    case directoryUnavailable
    case ioFailure(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable:
            return "Local storage directory is not available."
        case .ioFailure(let e):
            return "Local storage IO error: \(e.localizedDescription)"
        }
    }
}

enum LocalStore {

    /// Per-install root for all local files. Created on demand.
    static let directoryName = "DriverHub"

    /// Root URL = `<app>/Documents/DriverHub/`. Created if missing.
    static var rootURL: URL {
        get throws {
            guard let docs = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first else {
                throw LocalStoreError.directoryUnavailable
            }
            let root = docs.appendingPathComponent(directoryName, isDirectory: true)
            if !FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: true
                )
            }
            return root
        }
    }

    /// Absolute URL for a named file inside the local store root.
    static func fileURL(named name: String) throws -> URL {
        try rootURL.appendingPathComponent(name)
    }

    // MARK: - Encoder / Decoder

    /// JSON encoder used for all local files. Pretty-printed so the user
    /// can inspect / hand-merge a backup if they ever need to. Sorted
    /// keys keep diff-friendly output across writes.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// JSON decoder. Vanilla — models that need custom date handling
    /// implement it themselves via init(from:).
    private static let decoder = JSONDecoder()

    // MARK: - Read

    /// Load an array of decodable items from disk. Returns an empty array
    /// when the file is missing — first launch is not an error.
    static func loadArray<T: Decodable>(_ type: T.Type, fileName: String) -> [T] {
        do {
            let url = try fileURL(named: fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return []
            }
            let data = try Data(contentsOf: url)
            return try decoder.decode([T].self, from: data)
        } catch {
            #if DEBUG
            print("[SP_DEBUG_LOCAL] LocalStore.loadArray(\(fileName)) failed: \(error)")
            #endif
            return []
        }
    }

    /// Load a single decodable object (used for profile.json, meta.json).
    static func loadObject<T: Decodable>(_ type: T.Type, fileName: String) -> T? {
        do {
            let url = try fileURL(named: fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            let data = try Data(contentsOf: url)
            return try decoder.decode(T.self, from: data)
        } catch {
            #if DEBUG
            print("[SP_DEBUG_LOCAL] LocalStore.loadObject(\(fileName)) failed: \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Write

    /// Save an array atomically. The write goes to a temp file first and
    /// then renames — a crash mid-write cannot corrupt the live file.
    @discardableResult
    static func saveArray<T: Encodable>(_ items: [T], fileName: String) -> Bool {
        do {
            let url = try fileURL(named: fileName)
            let data = try encoder.encode(items)
            try data.write(to: url, options: [.atomic])
            #if DEBUG
            print("[SP_DEBUG_LOCAL] LocalStore.saveArray(\(fileName)) wrote \(items.count) items, \(data.count) bytes")
            #endif
            return true
        } catch {
            #if DEBUG
            print("[SP_DEBUG_LOCAL] LocalStore.saveArray(\(fileName)) failed: \(error)")
            #endif
            return false
        }
    }

    /// Save a single encodable object atomically.
    @discardableResult
    static func saveObject<T: Encodable>(_ value: T, fileName: String) -> Bool {
        do {
            let url = try fileURL(named: fileName)
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            #if DEBUG
            print("[SP_DEBUG_LOCAL] LocalStore.saveObject(\(fileName)) failed: \(error)")
            #endif
            return false
        }
    }

    // MARK: - Delete

    @discardableResult
    static func deleteFile(named name: String) -> Bool {
        do {
            let url = try fileURL(named: name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return true
        } catch {
            return false
        }
    }

    /// Wipe every local file (NOT exposed to the UI yet — for tests and
    /// future "Delete local data" Setting). Removes the DriverHub
    /// directory entirely; it is re-created on next access.
    @discardableResult
    static func wipeAll() -> Bool {
        do {
            let url = try rootURL
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return true
        } catch {
            return false
        }
    }
}
