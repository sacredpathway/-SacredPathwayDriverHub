import Foundation
import UIKit

// =============================================================================
// ReceiptImageStore — durable on-device storage for expense receipt images
// -----------------------------------------------------------------------------
// Phase 1 · Task 3 (2026-07-04). Before this service, receipt photos were used
// for on-device OCR and then DISCARDED — the Expense row kept only the parsed
// numbers, so there was no image trail for audits or the CPA package.
//
// Design rules (each maps to a Task-3 requirement):
//   • DURABLE PATH   — files live in `Documents/DriverHub/Receipts/`, the same
//     user-visible root LocalStore already uses. Documents/ is included in iOS
//     device backups and survives app relaunch and app updates.
//   • RELATIVE NAMES — the Expense row stores ONLY the filename
//     (`receipt-<uuid>.jpg`), never an absolute path. Absolute container paths
//     change across reinstalls; filenames resolved at read time do not.
//   • THROWING SAVE  — `save` throws on any failure. Callers must persist the
//     filename ONLY after `save` returns, so the app can never claim a receipt
//     exists that isn't on disk ("never pretend it saved").
//   • NORMALIZED JPEG — images are downscaled to ≤1800 px longest edge and
//     re-encoded JPEG(0.7). A typical receipt lands at 150–400 KB, which keeps
//     backups (base64-embedded, see BackupService v2) reasonable.
//   • CLEANUP        — `delete` removes a single file;
//     `sweepOrphans(referencedFilenames:)` removes any file on disk no expense
//     references (defense-in-depth against interrupted delete flows).
//
// Cloud note: images are DEVICE-LOCAL + BACKUP-INCLUDED. In Cloud mode the
// `receipt_image_filename` column syncs (so other devices know a receipt was
// captured) and a best-effort copy is uploaded to the Document Vault, but the
// authoritative image is this store. See RECEIPT_PERSISTENCE.md.
//
// Testability: all file ops go through `rootDirectory`, injectable via
// `init(rootDirectory:)` — tests use a temp dir; the app uses `.shared`.
// =============================================================================

final class ReceiptImageStore: @unchecked Sendable {

    // MARK: - Errors

    enum StoreError: Error, LocalizedError {
        case imageEncodingFailed
        case directoryUnavailable(underlying: Error?)
        case writeFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .imageEncodingFailed:
                return "The receipt photo couldn't be processed. Try a different photo."
            case .directoryUnavailable:
                return "Receipt storage isn't available on this device."
            case .writeFailed(let e):
                return "The receipt couldn't be saved to this device: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Shared instance

    static let shared = ReceiptImageStore()

    /// Subfolder of the LocalStore root that holds every receipt JPEG.
    static let subdirectoryName = "Receipts"

    private let overrideRoot: URL?

    /// App uses `.shared` (nil override → LocalStore root). Tests inject a
    /// temp directory so they never touch real user data.
    init(rootDirectory: URL? = nil) {
        self.overrideRoot = rootDirectory
    }

    // MARK: - Directory

    /// `Documents/DriverHub/Receipts/` (created on demand) — or the injected
    /// test root.
    func receiptsDirectory() throws -> URL {
        let base: URL
        if let overrideRoot {
            base = overrideRoot
        } else {
            do {
                base = try LocalStore.rootURL
            } catch {
                throw StoreError.directoryUnavailable(underlying: error)
            }
        }
        let dir = base.appendingPathComponent(Self.subdirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw StoreError.directoryUnavailable(underlying: error)
            }
        }
        return dir
    }

    // MARK: - Save

    /// Longest-edge cap for stored receipts. Big enough to re-OCR or zoom a
    /// fuel receipt; small enough to keep 500 receipts under ~150 MB.
    private let maxPixelDimension: CGFloat = 1800
    private let jpegQuality: CGFloat = 0.7

    /// Normalize + write a receipt image. Returns the FILENAME (not a path)
    /// to store on the Expense row. Throws on any failure — callers must not
    /// persist a filename unless this returns.
    @discardableResult
    func save(_ image: UIImage) throws -> String {
        let normalized = Self.downscaled(image, maxDimension: maxPixelDimension)
        guard let data = normalized.jpegData(compressionQuality: jpegQuality),
              !data.isEmpty else {
            throw StoreError.imageEncodingFailed
        }
        return try save(jpegData: data)
    }

    /// Write pre-encoded JPEG bytes (used by backup restore, which already
    /// holds the original encoded file). Same throwing contract as `save(_:)`.
    @discardableResult
    func save(jpegData data: Data, preferredFilename: String? = nil) throws -> String {
        guard !data.isEmpty else { throw StoreError.imageEncodingFailed }
        let dir = try receiptsDirectory()
        let filename = Self.isValidFilename(preferredFilename)
            ? preferredFilename!
            : "receipt-\(UUID().uuidString.lowercased()).jpg"
        let url = dir.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw StoreError.writeFailed(underlying: error)
        }
        return filename
    }

    // MARK: - Read

    /// Resolved file URL if (and only if) the receipt exists on disk.
    func imageURL(for filename: String?) -> URL? {
        guard let filename, Self.isValidFilename(filename),
              let dir = try? receiptsDirectory() else { return nil }
        let url = dir.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Load the stored image, or nil when missing/corrupt. Missing is not an
    /// error at read time — the UI shows a "receipt missing" placeholder.
    func loadImage(filename: String?) -> UIImage? {
        guard let url = imageURL(for: filename),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Raw stored bytes — used by backup export and the cloud-vault copy.
    func loadData(filename: String?) -> Data? {
        guard let url = imageURL(for: filename) else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Delete / cleanup

    /// Remove a single receipt file. Missing file is success (idempotent).
    func delete(filename: String?) {
        guard let filename, Self.isValidFilename(filename),
              let dir = try? receiptsDirectory() else { return }
        let url = dir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }

    /// Delete every file in the receipts folder that no expense references.
    /// Returns the number of orphans removed. Call sites: backup restore
    /// (post-replace) and any future maintenance task.
    @discardableResult
    func sweepOrphans(referencedFilenames: Set<String>) -> Int {
        guard let dir = try? receiptsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
              ) else { return 0 }
        var removed = 0
        for url in files where !referencedFilenames.contains(url.lastPathComponent) {
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - Helpers

    /// Filenames are always app-generated (`receipt-<uuid>.jpg`) or restored
    /// from our own backups. Reject anything with a path separator so a
    /// crafted backup can't write outside the receipts folder.
    static func isValidFilename(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return !name.contains("/") && !name.contains("\\") && !name.contains("..")
    }

    static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
