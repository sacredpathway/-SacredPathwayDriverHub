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
    /// `wipeAll()` for testing.
    func reload() {
        loads = LocalStore.loadArray(Load.self, fileName: fileName)
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
    @discardableResult
    func create(_ load: Load) -> Load {
        var copy = load
        if copy.id == nil { copy.id = UUID() }
        if copy.createdAt == nil { copy.createdAt = Date() }
        copy.updatedAt = Date()
        loads.append(copy)
        flush()
        return copy
    }

    /// Update an existing load. No-op if the id isn't found.
    func update(_ load: Load) {
        guard let id = load.id, let idx = loads.firstIndex(where: { $0.id == id }) else { return }
        var copy = load
        copy.updatedAt = Date()
        loads[idx] = copy
        flush()
    }

    /// Delete by id. No-op if missing.
    func delete(id: UUID) {
        let before = loads.count
        loads.removeAll { $0.id == id }
        if loads.count != before { flush() }
    }

    /// Replace the entire list (used by the future Import Backup flow).
    func replaceAll(with newLoads: [Load]) {
        loads = newLoads
        flush()
    }

    // MARK: - Persistence

    private func flush() {
        LocalStore.saveArray(loads, fileName: fileName)
    }
}
