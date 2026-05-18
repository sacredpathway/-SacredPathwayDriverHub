import Foundation
import Combine

// =============================================================================
//  AppMode — top-level free/cloud mode selector
// -----------------------------------------------------------------------------
//  Phase A of the Local Mode plan. Persists which mode the user picked on
//  first launch:
//
//   .notSet  → user hasn't chosen yet → WelcomeView
//   .local   → Free Local Mode. Data stays on THIS iPhone. No Supabase, no
//              account required. App works offline. Deleting the app may
//              delete the local data unless the user exported a backup.
//   .cloud   → Sign in + Pro flow (existing AccessGate + Paywall path).
//              Multi-device sync, web portal, backup, premium AI features.
//
//  Persistence: UserDefaults (one key). Survives relaunch. Survives app
//  upgrade. Does NOT survive a full reinstall — that's by design and by
//  warning copy in WelcomeView.
//
//  Phase A is intentionally narrow: this enum, plus a WelcomeView that
//  writes it, plus a SacredPathwayApp branch that reads it. No repository
//  migration yet. No backup/restore yet. No on-list banner yet.
// =============================================================================

/// The three top-level modes the app can be in.
enum AppModeValue: String, Codable, CaseIterable {
    case notSet = "not_set"
    case local  = "local"
    case cloud  = "cloud"
}

@MainActor
final class AppMode: ObservableObject {

    // MARK: - Singleton

    static let shared = AppMode()

    // MARK: - Storage keys

    private let modeKey      = "sp.app.mode.v1"
    private let installIdKey = "sp.local.installId.v1"
    private let pickedAtKey  = "sp.app.mode.picked_at.v1"

    // MARK: - Published state

    /// Current mode. UI reads this; never writes directly — use the
    /// `setLocal()` / `setCloud()` / `reset()` helpers.
    @Published private(set) var mode: AppModeValue

    /// True when the user has explicitly picked a mode (i.e. NOT `.notSet`).
    var isModePicked: Bool { mode != .notSet }

    /// True when the active mode is Free Local Mode.
    var isLocal: Bool { mode == .local }

    /// True when the active mode is Cloud Pro.
    var isCloud: Bool { mode == .cloud }

    // MARK: - Init

    init() {
        let raw = UserDefaults.standard.string(forKey: modeKey) ?? AppModeValue.notSet.rawValue
        self.mode = AppModeValue(rawValue: raw) ?? .notSet
    }

    // MARK: - Mutation

    /// User chose "Start Free on this iPhone" from WelcomeView.
    func setLocal() {
        write(.local)
    }

    /// User chose "Sign in for Cloud Pro" — called from WelcomeView so the
    /// LoginView path is entered intentionally.
    func setCloud() {
        write(.cloud)
    }

    /// Clear the mode entirely. Used by Settings → Reset (future phase) and
    /// by tests. Calling this DOES NOT delete the user's local data — that
    /// requires the explicit Delete Local Data action that ships in a
    /// later phase.
    func reset() {
        write(.notSet)
    }

    private func write(_ new: AppModeValue) {
        UserDefaults.standard.set(new.rawValue, forKey: modeKey)
        if new != .notSet {
            UserDefaults.standard.set(Date(), forKey: pickedAtKey)
        }
        mode = new
    }

    // MARK: - Local install id

    /// Stable per-install UUID used as the `profileId` on every local-mode
    /// row. Generated on first read and persisted forever (until app delete).
    /// Local-mode `profileId` is otherwise meaningless — there is no DB
    /// foreign key — but every Codable model declares it as a required
    /// non-optional UUID, so we hand out this stable value to satisfy
    /// the type.
    var localInstallId: UUID {
        if let s = UserDefaults.standard.string(forKey: installIdKey),
           let id = UUID(uuidString: s) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: installIdKey)
        return id
    }

    // MARK: - Bootstrap (upgrade safety)

    /// Existing v2.0.x users on this branch are already signed into Supabase
    /// — they should NOT see WelcomeView on first launch of the build that
    /// introduces AppMode. Call this once at app launch, after auth restore
    /// completes. If the user is signed in AND we haven't picked a mode,
    /// silently set `.cloud` so they land back in the app exactly where
    /// they expect to be.
    ///
    /// Idempotent. Safe to call repeatedly.
    func bootstrapForExistingCloudUser(isAuthenticated: Bool) {
        guard mode == .notSet else { return }
        guard isAuthenticated else { return }
        write(.cloud)
        #if DEBUG
        print("[AppMode] bootstrap: existing authenticated user → .cloud")
        #endif
    }
}
