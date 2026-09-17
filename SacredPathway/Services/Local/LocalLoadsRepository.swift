import Foundation
import Combine

// =============================================================================
//  LocalLoadsRepository — Free Local Mode loads store (Phase B)
// -----------------------------------------------------------------------------
//  ObservableObject so SwiftUI views can bind to `loads`. Single instance per
//  app via `.shared`. Disk file lives at `Documents/DriverHub/loads.json`.
//
//  Phase B intentionally keeps the API surface minimal — fetchAll / create /
//  update / delete / findByLoadNumber. Views that need to switch from
//  Supabase to local will do so in Phase C through the upcoming Repositories
//  factory; for now this class exists, compiles, and the smoke test exercises
//  every CRUD path.
// =============================================================================

@MainActor
final class LocalLoadsRepository: ObservableObject {

    static let shared = LocalLoadsRepository()

    /// On-disk filename within `Documents/DriverHub/`.
    private let fileName = "loads.json"

    /// Durable local deletion ledger. A successful delete must remain deleted
    /// even if a stale view or delayed writer later tries to flush an older
    /// in-memory snapshot back to `loads.json`.
    private let deletedIDsFileName = "deleted-load-ids.json"
    private var deletedIDs: Set<UUID> = []

    /// In-memory cache. Views observing this list re-render automatically.
    @Published private(set) var loads: [Load] = []

    init() {
        deletedIDs = Set(LocalStore.loadArray(UUID.self, fileName: deletedIDsFileName))
        reload()
    }

    // MARK: - Read

    /// Re-read from disk. Safe to call any time; used at init and after
    /// `wipeAll()` for testing. Always runs a dedupe-by-id pass before
    /// publishing so any duplicates that snuck in via iCloud merge or a
    /// historic double-save bug do NOT inflate weekly totals.
    func reload() {
        let raw = LocalStore.loadArray(Load.self, fileName: fileName)
        let live = raw.filter { load in
            guard let id = load.id else { return true }
            return !deletedIDs.contains(id)
        }
        let deduped = WeeklyStatsService.dedupe(live)
        // One-time, safe normalization: loads created by the old manual-entry
        // default were saved with status "pending" and never counted as Active.
        // Rewrite any "pending" → "active" so existing test/demo loads stop
        // showing the stale Pending badge. Only the status string changes; no
        // dates, revenue, or ids are touched.
        var normalizedCount = 0
        let normalized: [Load] = deduped.map { load in
            guard (load.status ?? "").lowercased() == "pending" else { return load }
            var copy = load
            copy.status = "active"
            normalizedCount += 1
            return copy
        }
        let ordered = newestFirst(normalized)
        if ordered.count != raw.count || normalizedCount > 0 {
            // Persist the cleaned/normalized list so it doesn't recur next launch.
            LocalStore.saveArray(ordered, fileName: fileName)
            #if DEBUG
            if deduped.count != raw.count {
                print("[SP_DEBUG_LOCAL] LocalLoadsRepository dropped \(raw.count - deduped.count) duplicate load(s) on reload")
            }
            if normalizedCount > 0 {
                print("[SP_DEBUG_LOCAL] LocalLoadsRepository normalized \(normalizedCount) pending→active load(s) on reload")
            }
            #endif
        }
        loads = ordered
        #if DEBUG
        print("[SP_DEBUG_LOCAL] LocalLoadsRepository loaded \(loads.count) loads from disk")
        #endif
    }

    /// Fully async fetch (matches the eventual cloud-repo signature).
    func fetchAll() async -> [Load] {
        loads
    }

    /// Fetch one by ID.
    func find(id: UUID) -> Load? {
        loads.first { $0.id == id }
    }

    /// Find by load number (best-effort — load numbers aren't unique across
    /// brokers, but useful for dedupe + recent-scan lookup).
    func findByLoadNumber(_ number: String) -> Load? {
        let trimmed = number.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return loads.first { ($0.loadNumber ?? "").caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    // MARK: - Write

    /// Insert a new load. If the caller didn't supply an id, generate one.
    /// Returns the stored load so callers can read the assigned id.
    ///
    /// If a row with the same id is already in the store this method
    /// routes to `update(...)` instead of appending. Without this guard a
    /// SwiftUI view that calls `create(...)` twice — e.g. .task fires
    /// after a re-render — would silently duplicate the load and double
    /// the weekly revenue total.
    @discardableResult
    func create(_ load: Load) -> Load {
        var copy = load
        if copy.id == nil { copy.id = UUID() }
        // A stale screen may still hold a value after another screen deletes
        // it. Never let that old UUID recreate a persisted ghost record.
        if let id = copy.id, deletedIDs.contains(id) {
            #if DEBUG
            print("[SP_DEBUG_LOCAL] LocalLoadsRepository rejected create for deleted id \(id)")
            #endif
            return copy
        }
        if copy.createdAt == nil { copy.createdAt = Date() }
        // Weekly buckets group by pickupDate and EXCLUDE nil, so a scanned or
        // rate-con load with no detected pickup would vanish from "This Week".
        // Default a missing pickup to today (date-only) — never overwrite a
        // real one — so every newly created load lands in the current week.
        if copy.pickupDate == nil {
            copy.pickupDate = Calendar.current.startOfDay(for: Date())
        }
        copy.updatedAt = Date()
        if let id = copy.id, let idx = loads.firstIndex(where: { $0.id == id }) {
            // Already exists — treat as an update, not a duplicate insert.
            loads[idx] = copy
            #if DEBUG
            print("[SP_DEBUG_LOCAL] LocalLoadsRepository.create() received an existing id \(id); routed to update")
            #endif
        } else {
            loads.insert(copy, at: 0)
        }
        loads = newestFirst(loads)
        flush()
        return copy
    }

    /// Update an existing load. No-op if the id isn't found.
    func update(_ load: Load) {
        guard let id = load.id,
              !deletedIDs.contains(id),
              let idx = loads.firstIndex(where: { $0.id == id }) else { return }
        var copy = load
        copy.updatedAt = Date()
        loads[idx] = copy
        loads = newestFirst(loads)
        flush()
    }

    /// Delete by id, committing the new array to disk before publishing it.
    ///
    /// Always records a tombstone in `LoadsSyncService` so any observer
    /// reading the canonical income list (Dashboard, Insights, Settlements)
    /// drops the row immediately, even if a Combine republish hasn't run
    /// yet. Without this, two-device users could see "deleted but still
    /// counted" briefly between the delete and the next dashboard task.
    @discardableResult
    func delete(id: UUID) -> Bool {
        guard loads.contains(where: { $0.id == id }) else { return false }

        let remaining = loads.filter { $0.id != id }
        var nextDeletedIDs = deletedIDs
        nextDeletedIDs.insert(id)

        // Commit the deletion intent first. If the process is interrupted
        // between these writes, reload still filters the deleted UUID.
        guard LocalStore.saveArray(
            nextDeletedIDs.sorted { $0.uuidString < $1.uuidString },
            fileName: deletedIDsFileName
        ) else {
            return false
        }
        guard LocalStore.saveArray(remaining, fileName: fileName) else {
            // The load file was unchanged, so roll the ledger back as well.
            _ = LocalStore.saveArray(
                deletedIDs.sorted { $0.uuidString < $1.uuidString },
                fileName: deletedIDsFileName
            )
            return false
        }

        deletedIDs = nextDeletedIDs
        loads = remaining
        LoadsSyncService.shared.tombstone(id)
        return true
    }

    /// Replace the entire list (used by the future Import Backup flow).
    func replaceAll(with newLoads: [Load]) {
        // Backup restore is an explicit request to restore its complete data
        // set, including records that may have been deleted since that backup.
        let restoredIDs = Set(newLoads.compactMap(\.id))
        deletedIDs.subtract(restoredIDs)
        _ = LocalStore.saveArray(
            deletedIDs.sorted { $0.uuidString < $1.uuidString },
            fileName: deletedIDsFileName
        )
        loads = newestFirst(newLoads)
        flush()
    }

    // MARK: - Persistence

    private func flush() {
        let live = loads.filter { load in
            guard let id = load.id else { return true }
            return !deletedIDs.contains(id)
        }
        LocalStore.saveArray(live, fileName: fileName)
    }

    private func newestFirst(_ values: [Load]) -> [Load] {
        values.sorted { lhs, rhs in
            let leftDate = lhs.createdAt ?? lhs.updatedAt ?? lhs.pickupDate ?? .distantPast
            let rightDate = rhs.createdAt ?? rhs.updatedAt ?? rhs.pickupDate ?? .distantPast
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            return (lhs.loadNumber ?? "") < (rhs.loadNumber ?? "")
        }
    }
}
