import Foundation
import SwiftUI
import UIKit

// =============================================================================
// ForceUpdateService
// -----------------------------------------------------------------------------
// Decides whether to show the full-screen blocking ForceUpdateView at launch.
//
// FAIL-OPEN GUARANTEE
// -------------------
// If the remote config URL fails for ANY reason (network down, 5xx, malformed
// JSON, timeout, DNS), `shouldForceUpdate` stays `false`. This is intentional:
// a server outage must never lock paying carriers out of their loads.
//
// Versioning rules
// ----------------
// 1. If installed < `minimumSupportedVersion`           → block.
// 2. Else if `forceUpdateRequired` && installed < `latestVersion` → block.
// 3. Otherwise → allow.
//
// Comparisons use `.numeric` so "1.10.0" > "1.9.0".
//
// Public surface
// --------------
//   • `await checkForUpdate()` — call once on app launch (kicked off from
//     `SacredPathwayApp.task`). Idempotent; safe to call again.
//   • `@Published shouldForceUpdate: Bool`  — drives the root view switch.
//   • `@Published config: RemoteAppConfig?` — latest decoded config.
//   • `openAppStore()`                      — opens the App Store URL.
//
// Manual QA hooks (DEBUG only — see #if DEBUG block at bottom):
//   • `forceShowForTesting()` / `forceHideForTesting()`
// =============================================================================

@MainActor
final class ForceUpdateService: ObservableObject {

    // MARK: - Singleton
    static let shared = ForceUpdateService()

    // MARK: - Published state
    @Published private(set) var shouldForceUpdate: Bool = false
    @Published private(set) var config: RemoteAppConfig?
    @Published private(set) var isChecking: Bool = false
    @Published private(set) var hasCompletedFirstCheck: Bool = false

    // MARK: - Init
    private init() {}

    /// A dedicated URLSession that does NOT share storage with `URLSession.shared`.
    /// Ephemeral configuration → no on-disk cache, no in-memory cache, no cookies.
    /// Combined with the URL-level cache-buster (`?t=<epoch>`) and an explicit
    /// `Cache-Control: no-cache` header, this guarantees every kill-switch fetch
    /// goes all the way to origin and is never served from URLCache, the
    /// HTTP cache, or a CDN that keys on the bare URL.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpAdditionalHeaders = [
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "Pragma": "no-cache"
        ]
        return URLSession(configuration: config)
    }()

    // MARK: - Installed version (read once at startup)
    /// `CFBundleShortVersionString` — e.g. "1.0.3".
    var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// `CFBundleVersion` — e.g. "21".
    var installedBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Numeric form of `installedBuild` for direct comparison against the
    /// remote `minimum_supported_build` / `latest_build` floors. Non-numeric
    /// strings (rare) collapse to 0, which is the safest "below everything".
    var installedBuildNumber: Int {
        Int(installedBuild) ?? 0
    }

    // MARK: - Public API

    /// Fetch remote config and update `shouldForceUpdate`. Fail-open on any
    /// error. Safe to call multiple times.
    func checkForUpdate() async {
        // ─── DEBUG simulate-blocked override ──────────────────────────
        // Lets QA verify the blocker UX without changing the live remote
        // config. Compiled out of Release builds.
        //
        //   Test on: xcrun simctl launch booted <bundle> -ForceUpdateSimulateBlocked YES
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ForceUpdateSimulateBlocked") {
            self.config = RemoteAppConfig(
                minimumSupportedVersion: "999.0.0",
                minimumSupportedBuild: 99999,
                latestVersion: "999.0.0",
                latestBuild: 99999,
                forceUpdateRequired: true,
                updateMessage: nil,
                appStoreURL: Config.ForceUpdate.fallbackAppStoreURL.absoluteString
            )
            self.shouldForceUpdate = true
            self.hasCompletedFirstCheck = true
            print("[ForceUpdate] 🧪 SIMULATED BLOCK via -ForceUpdateSimulateBlocked launch arg.")
            return
        }
        #endif

        // ─── DEBUG bypass ──────────────────────────────────────────────
        // Developer builds must NEVER be blocked by the force-update
        // screen. Local development almost always uses pre-release
        // versions that are by definition below `latest_version`, so
        // without this bypass every Cmd+R would land on the blocker.
        //
        // Compiled out of Release builds via `#if DEBUG` so production
        // users always go through the real check.
        #if DEBUG
        if !ProcessInfo.processInfo.arguments.contains("-ForceUpdateRespectInDEBUG") {
            self.shouldForceUpdate = false
            self.hasCompletedFirstCheck = true
            print("[ForceUpdate] DEBUG build — skipping check. " +
                  "Pass `-ForceUpdateRespectInDEBUG YES` for real check, " +
                  "or `-ForceUpdateSimulateBlocked YES` to preview the blocker.")
            return
        }
        #endif

        // Avoid concurrent checks.
        if isChecking { return }
        isChecking = true
        defer {
            isChecking = false
            hasCompletedFirstCheck = true
        }

        do {
            let fetched = try await fetchConfig()
            self.config = fetched
            self.shouldForceUpdate = Self.evaluate(
                installedVersion: installedVersion,
                installedBuild:   installedBuildNumber,
                config: fetched
            )

            // Plain-print (not DEBUG-only) so production crash logs/Console
            // include the check outcome for support diagnosis.
            print("""
            [ForceUpdate] ✅ check complete.
              installed=\(installedVersion) (build \(installedBuild))
              minVersion=\(fetched.minimumSupportedVersion ?? "nil")
              minBuild=\(fetched.minimumSupportedBuild.map(String.init) ?? "nil")
              latestVersion=\(fetched.latestVersion ?? "nil")
              latestBuild=\(fetched.latestBuild.map(String.init) ?? "nil")
              forceFlag=\(fetched.forceUpdateRequired ?? false)
              shouldForceUpdate=\(shouldForceUpdate)
            """)
        } catch {
            // FAIL-OPEN. Never lock the user out due to remote-config errors.
            print("[ForceUpdate] ⚠️ check FAILED, failing open. error=\(error.localizedDescription)")
            self.shouldForceUpdate = false
        }
    }

    /// Opens the App Store product page. Uses remote `appStoreURL` if
    /// present, otherwise falls back to `Config.ForceUpdate.fallbackAppStoreURL`.
    func openAppStore() {
        let urlString = config?.appStoreURL
        let url = urlString.flatMap(URL.init(string:)) ?? Config.ForceUpdate.fallbackAppStoreURL
        Task { @MainActor in
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            }
        }
    }

    /// User-facing copy. Falls back to a sensible default if the remote
    /// config omits `updateMessage`.
    var updateMessage: String {
        config?.updateMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "An updated version of Sacred Pathway Driver Hub is required to continue. Please update from the App Store to keep using the app."
    }

    /// User-facing version line, e.g. "Version 1.0.3 → 1.1.0".
    var versionLine: String? {
        guard let latest = config?.latestVersion, !latest.isEmpty else { return nil }
        return "Version \(installedVersion) → \(latest)"
    }

    // MARK: - Private

    private func fetchConfig() async throws -> RemoteAppConfig {
        // Cache-bust at the URL level so neither URLCache nor any upstream
        // CDN (Supabase Storage CDN, in particular) can serve a stale
        // "do not force" entry — that would defeat the kill-switch. Every
        // request is a unique cache key.
        var components = URLComponents(url: Config.ForceUpdate.configURL,
                                       resolvingAgainstBaseURL: false)!
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "t", value: "\(Int(Date().timeIntervalSince1970))"))
        components.queryItems = query
        let bustedURL = components.url ?? Config.ForceUpdate.configURL

        var request = URLRequest(url: bustedURL)
        request.timeoutInterval = Config.ForceUpdate.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store, must-revalidate", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        // Belt-and-braces: even though the ephemeral session has no cache,
        // explicitly evict any prior response that the shared cache may
        // have kept for the bare URL.
        URLCache.shared.removeCachedResponse(for: URLRequest(url: Config.ForceUpdate.configURL))

        let (data, response) = try await Self.session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(RemoteAppConfig.self, from: data)
    }

    /// Pure decision function. Exposed `internal` so a unit test can drive it.
    ///
    /// Decision rules (in order — first match wins):
    ///   1. installed VERSION < `minimum_supported_version`          → block
    ///   2. installed BUILD   < `minimum_supported_build`            → block
    ///   3. `force_update` is true AND (installed VERSION < latest
    ///      OR installed BUILD < latest_build)                       → block
    ///   4. otherwise                                                → allow
    static func evaluate(
        installedVersion: String,
        installedBuild: Int,
        config: RemoteAppConfig
    ) -> Bool {
        // Rule 1 — hard version floor.
        if let minRequired = config.minimumSupportedVersion?.nilIfEmpty,
           compare(installedVersion, minRequired) == .orderedAscending {
            return true
        }

        // Rule 2 — hard build floor (handles same-version hot-fixes).
        if let minBuild = config.minimumSupportedBuild, installedBuild < minBuild {
            return true
        }

        // Rule 3 — soft kill-switch.
        if config.forceUpdateRequired ?? false {
            if let latest = config.latestVersion?.nilIfEmpty,
               compare(installedVersion, latest) == .orderedAscending {
                return true
            }
            if let latestBuild = config.latestBuild, installedBuild < latestBuild {
                return true
            }
        }

        return false
    }

    /// Numeric semver-friendly comparison. "1.10.0" > "1.9.0".
    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}

// MARK: - Tiny helper

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - DEBUG hooks

#if DEBUG
extension ForceUpdateService {
    /// Manually force the blocking screen to appear — wire to a debug menu
    /// or shake gesture for QA. No-op in Release builds.
    func forceShowForTesting() {
        self.shouldForceUpdate = true
        self.hasCompletedFirstCheck = true
    }

    /// Manually clear the blocking state — for QA only.
    func forceHideForTesting() {
        self.shouldForceUpdate = false
        self.hasCompletedFirstCheck = true
    }
}
#endif
