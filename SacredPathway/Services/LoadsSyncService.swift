import Foundation
import SwiftUI
import UIKit
import Combine

// =============================================================================
//  LoadsSyncService — canonical income source-of-truth, cross-device aware
// -----------------------------------------------------------------------------
//  PRIOR STATE: Dashboard and every weekly/monthly aggregator each chose
//  between `LocalLoadsRepository.shared.loads` and the cloud `@State loads`
//  array via `AppMode.shared.isLocal ? … : …`. Three flaws followed from
//  that:
//
//    1. No single function in the codebase could answer "what is the user's
//       canonical list of income records right now?" — every screen made
//       its own choice and could disagree with another screen.
//    2. Deletes had no tombstone. If iPhone deleted a load, iPad's cached
//       `[Load]` still summed it into Weekly Income until the next
//       `fetchLoads()` round-tripped.
//    3. Repeated saves, iCloud-style merges, and offline reconnections
//       could leave duplicate rows with the same `id` in the working array.
//
//  THIS SERVICE: one ObservableObject that the Dashboard observes. It
//  routes to the correct backing store based on `AppMode`, dedupes by
//  `id` with updatedAt-wins, applies in-memory tombstones for pending
//  deletes, and exposes the audit data the cross-device debug view needs.
//
//  Source-of-truth rule:
//    • AppMode.cloud  → Supabase (multi-device shared). LoadsSyncService
//      caches the most recent `fetchLoads()` result and republishes when
//      `.loadsDidChange` fires.
//    • AppMode.local  → LocalLoadsRepository (single-device JSON). Cross-
//      device parity is NOT possible in this mode — that's documented in
//      AppMode.swift and the audit dump surfaces it explicitly.
//
//  Conflict rules:
//    • Same id + newer `updatedAt` wins (delegated to WeeklyStatsService.dedupe).
//    • Deleted ids are tombstoned in-memory + on-disk until a fresh fetch
//      confirms the row is gone server-side.
//    • A `create()` call that arrives with an already-stored id routes to
//      `update()` (enforced in LocalLoadsRepository).
// =============================================================================

@MainActor
final class LoadsSyncService: ObservableObject {

    // MARK: - Singleton

    static let shared = LoadsSyncService()

    // MARK: - Published state

    /// Canonical, deduped, tombstone-filtered list of loads.
    /// Every income surface in the app reads this — never the underlying
    /// repository or `fetchLoads()` array directly.
    @Published private(set) var loads: [Load] = []

    /// Wall-clock time of the most recent successful refresh. Nil before
    /// the first fetch in Cloud Mode; Local Mode sets it on every reload.
    @Published private(set) var lastSyncAt: Date? = nil

    /// Most recent sync error. Nil after a successful refresh. Surfaced
    /// only in the DEBUG audit view (the dashboard's existing loadError
    /// banner handles user-facing surfacing).
    @Published private(set) var lastSyncError: String? = nil

    // MARK: - Storage keys + caches

    private let tombstonesKey = "sp.loads.tombstones.v1"

    /// IDs that the user has deleted but a fresh server fetch has not
    /// yet confirmed. Survives relaunch so an offline-then-online flow
    /// still excludes them.
    private var tombstones: Set<UUID> = []

    /// Last server response (Cloud Mode). Held here instead of in each
    /// view's `@State` so every observer sees the same array.
    private var cloudCache: [Load] = []

    /// Combine bag for the AppMode/LocalLoadsRepository republish links.
    private var cancellables: Set<AnyCancellable> = []

    /// Block-based observer token for `.loadsDidChange`. Block API is
    /// used (not `@objc selector`) because LoadsSyncService is a pure
    /// Swift ObservableObject — it does not inherit from NSObject and
    /// therefore cannot expose `@objc` selectors.
    private var loadsDidChangeObserver: NSObjectProtocol?

    // MARK: - Init

    private init() {
        tombstones = Self.loadTombstones(key: tombstonesKey)

        // Every observer below uses the same shape so MainActor isolation
        // is guaranteed by Swift's concurrency model, not by hoping that
        // RunLoop.main equals MainActor (it doesn't under strict checking):
        //
        //   .sink { [weak self] _ in
        //       Task { [weak self] in
        //           await self?.handleLoadsChangedFromNotification()
        //       }
        //   }
        //
        // `handleLoadsChangedFromNotification` is a member of this
        // @MainActor class, so `await` on it performs the actor hop. No
        // `Task { @MainActor [weak self] in … }` capture sugar — that
        // form can confuse the type-checker and is the kind of code I
        // want to avoid before a clean-room build.

        LocalLoadsRepository.shared.$loads
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.handleLoadsChangedFromNotification()
                }
            }
            .store(in: &cancellables)

        AppMode.shared.$mode
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.handleLoadsChangedFromNotification()
                }
            }
            .store(in: &cancellables)

        loadsDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .loadsDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handleLoadsChangedFromNotification()
            }
        }

        recompute()
    }

    deinit {
        // `loadsDidChangeObserver` is a stored property on a @MainActor
        // class. Swift permits stored-property access from a nonisolated
        // deinit when the object is being deallocated (no concurrent
        // observers can race us). `NotificationCenter.removeObserver`
        // is thread-safe, so this is correct without any actor hop.
        if let token = loadsDidChangeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// MainActor-isolated entry point used by every observer above.
    /// Splitting it out (rather than calling `recompute()` directly
    /// inside the closures) keeps each observer body to the safest
    /// shape — a `Task { await self?.method() }` — and lets the
    /// compiler verify the actor hop without any `@MainActor` closure
    /// attributes or `MainActor.run { … }` wrappers.
    private func handleLoadsChangedFromNotification() {
        recompute()
    }

    // MARK: - Public API

    /// One-call refresh used by the Dashboard's `.task` / `.refreshable`.
    /// Cloud Mode: round-trips to Supabase, replaces the cache, drops
    /// tombstones for ids the server confirms are gone, recomputes.
    /// Local Mode: just recomputes — there's no upstream to fetch.
    func refresh(supabase: SupabaseService) async {
        guard AppMode.shared.isCloud else {
            recompute()
            lastSyncAt = Date()
            return
        }
        do {
            let server = try await supabase.fetchLoads()
            cloudCache = server
            // After a successful server round-trip the server response IS
            // the truth. Any tombstone left over from a pending delete is
            // now redundant: if the id is missing from `server` the row is
            // truly gone (tombstone no longer needed); if it's still in
            // `server` the delete failed (tombstone must be cleared so the
            // row is not silently hidden). Both cases collapse to "wipe
            // every tombstone after a confirmed refresh."
            tombstones.removeAll()
            persistTombstones()
            lastSyncError = nil
            lastSyncAt = Date()
            recompute()
        } catch {
            lastSyncError = error.localizedDescription
            // Don't clear the cache on failure — the user keeps seeing
            // the last known good totals.
        }
    }

    /// Soft-delete an id. The dashboard immediately excludes it from
    /// totals; the next successful `refresh()` removes the tombstone if
    /// the server confirms deletion.
    func tombstone(_ id: UUID) {
        tombstones.insert(id)
        persistTombstones()
        recompute()
    }

    /// Forget every tombstone. Exposed for the DEBUG audit view's
    /// "Reset tombstones" action and for tests.
    func clearAllTombstones() {
        tombstones.removeAll()
        persistTombstones()
        recompute()
    }

    /// Snapshot of the current tombstone set — for the audit dump.
    var tombstonedIDs: [UUID] { Array(tombstones) }

    /// Raw (pre-dedupe, pre-tombstone) backing array for the audit dump.
    /// In Cloud Mode this is the last server response; in Local Mode it
    /// is whatever LocalLoadsRepository has on disk right now.
    var rawBackingLoads: [Load] {
        AppMode.shared.isLocal
            ? LocalLoadsRepository.shared.loads
            : cloudCache
    }

    /// The store the active mode considers authoritative — a one-word
    /// descriptor for the audit dump.
    var activeStorageName: String {
        AppMode.shared.isLocal ? "LocalJSON" : "Supabase"
    }

    // MARK: - Internal

    /// Apply dedupe + tombstone filter to the active backing array and
    /// publish to subscribers. Called any time inputs change.
    private func recompute() {
        let raw = rawBackingLoads
        let deduped = WeeklyStatsService.dedupe(raw)
        loads = deduped.filter { l in
            guard let id = l.id else { return true }
            return !tombstones.contains(id)
        }
    }

    // MARK: - Tombstone persistence

    private struct TombstoneFile: Codable { let ids: [UUID] }

    private func persistTombstones() {
        let payload = TombstoneFile(ids: Array(tombstones))
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: tombstonesKey)
        }
    }

    private static func loadTombstones(key: String) -> Set<UUID> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let payload = try? JSONDecoder().decode(TombstoneFile.self, from: data)
        else { return [] }
        return Set(payload.ids)
    }

    // MARK: - Cross-device audit dump

    /// Full dump the DEBUG audit view shares. Includes everything the
    /// support team needs to diagnose a "iPhone shows $X, iPad shows $Y"
    /// report without screen-sharing.
    func crossDeviceAuditReport(now: Date = Date()) -> String {
        let raw = rawBackingLoads
        let deduped = WeeklyStatsService.dedupe(raw)
        let visible = loads
        let dupeIDs = duplicateIDs(in: raw)
        let df: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
            f.timeZone = .current
            return f
        }()
        let dateOnly: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = .current
            return f
        }()

        var lines: [String] = []
        lines.append("══════════════════════════════════════════")
        lines.append("Sacred Pathway Driver Hub — Cross-Device Audit")
        lines.append("══════════════════════════════════════════")
        lines.append("Device:         \(UIDevice.current.name) (\(UIDevice.current.model))")
        lines.append("System:         \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        lines.append("Locale / TZ:    \(Locale.current.identifier) / \(TimeZone.current.identifier)")
        lines.append("App Mode:       \(AppMode.shared.mode.rawValue)")
        lines.append("Storage:        \(activeStorageName)")
        lines.append("Install ID:     \(AppMode.shared.localInstallId.uuidString.prefix(8))…")
        lines.append("Last sync at:   \(lastSyncAt.map(df.string(from:)) ?? "—")")
        lines.append("Last error:     \(lastSyncError ?? "—")")
        lines.append("")
        lines.append("Raw records:    \(raw.count)")
        lines.append("Unique by id:   \(deduped.count)")
        lines.append("Visible (post-tombstone): \(visible.count)")
        lines.append("Duplicate ids:  \(dupeIDs.count)\(dupeIDs.isEmpty ? "" : "  ⚠️ " + dupeIDs.prefix(5).map { String($0.uuidString.prefix(8)) }.joined(separator: ", "))")
        lines.append("Tombstoned ids: \(tombstones.count)")
        if !tombstones.isEmpty {
            for id in tombstones.prefix(20) {
                lines.append("    ✕ \(id.uuidString.prefix(8))")
            }
        }
        lines.append("")
        lines.append("── Revenue by period (uses LoadsSyncService.loads) ──")
        for p in StatsPeriod.allCases {
            let total = WeeklyStatsService.revenue(in: p, loads: visible, now: now)
            lines.append("\(p.rawValue):  \(total.asCurrency)")
        }
        lines.append("")
        lines.append("── Every visible record ──")
        for (i, l) in visible.enumerated() {
            let id = l.id?.uuidString.prefix(8) ?? "(no id)"
            let amount = (l.totalRevenue ?? 0).asCurrency
            let pickup = l.pickupDate.map(dateOnly.string(from:)) ?? "—"
            let created = l.createdAt.map(df.string(from:)) ?? "—"
            let updated = l.updatedAt.map(df.string(from:)) ?? "—"
            let num = l.loadNumber ?? "(no #)"
            lines.append("\(i + 1). \(id)  \(amount)  pickup=\(pickup)  load=\(num)")
            lines.append("    createdAt=\(created)")
            lines.append("    updatedAt=\(updated)")
        }
        if AppMode.shared.isLocal {
            lines.append("")
            lines.append("ℹ️  Local Mode is single-device by design. Cross-device parity")
            lines.append("    requires signing in to Cloud Mode (Settings → Sign In).")
        }
        return lines.joined(separator: "\n")
    }

    /// Returns the set of ids that appear more than once in `raw`.
    private func duplicateIDs(in raw: [Load]) -> [UUID] {
        var counts: [UUID: Int] = [:]
        for l in raw {
            guard let id = l.id else { continue }
            counts[id, default: 0] += 1
        }
        return counts.filter { $0.value > 1 }.map { $0.key }
    }
}
