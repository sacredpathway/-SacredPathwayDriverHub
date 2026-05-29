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

    /// In-memory cache. Views observing this list re-render automatically.
    @Published private(set) var loads: [Load] = []

    init() {
        reload()
    }

    // MARK: - Read

    /// Re-read from disk. Safe to call any time; used at init and after
    /// `wipeAll()` for testing. Always runs a dedupe-by-id pass before
    /// publishing so any duplicates that snuck in via iCloud merge or a
    /// historic double-save bug do NOT inflate weekly totals.
    func reload() {
        let raw = LocalStore.loadArray(Load.self, fileName: fileName)
        let deduped = WeeklyStatsService.dedupe(raw)
        let ordered = newestFirst(deduped)
        if deduped.count != raw.count {
            // Persist the cleaned list so the dupes don't reappear next launch.
            LocalStore.saveArray(ordered, fileName: fileName)
            #if DEBUG
            print("[SP_DEBUG_LOCAL] LocalLoadsRepository dropped \(raw.count - deduped.count) duplicate load(s) on reload")
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
        if copy.createdAt == nil { copy.createdAt = Date() }
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
        guard let id = load.id, let idx = loads.firstIndex(where: { $0.id == id }) else { return }
        var copy = load
        copy.updatedAt = Date()
        loads[idx] = copy
        loads = newestFirst(loads)
        flush()
    }

    /// Delete by id. No-op if missing.
    ///
    /// Always records a tombstone in `LoadsSyncService` so any observer
    /// reading the canonical income list (Dashboard, Insights, Settlements)
    /// drops the row immediately, even if a Combine republish hasn't run
    /// yet. Without this, two-device users could see "deleted but still
    /// counted" briefly between the delete and the next dashboard task.
    func delete(id: UUID) {
        let before = loads.count
        loads.removeAll { $0.id == id }
        LoadsSyncService.shared.tombstone(id)
        if loads.count != before { flush() }
    }

    /// Replace the entire list (used by the future Import Backup flow).
    func replaceAll(with newLoads: [Load]) {
        loads = newestFirst(newLoads)
        flush()
    }

    // MARK: - Persistence

    private func flush() {
        LocalStore.saveArray(loads, fileName: fileName)
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
