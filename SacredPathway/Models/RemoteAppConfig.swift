import Foundation

// =============================================================================
// RemoteAppConfig
// -----------------------------------------------------------------------------
// Decoded from the hosted JSON file at `Config.ForceUpdate.configURL`.
//
// Example JSON (host this at https://www.sacredpathway.org/force-update.json
// or any public, cacheable URL):
//
// {
//   "minimumSupportedVersion": "1.0.0",
//   "latestVersion":           "1.1.0",
//   "forceUpdateRequired":     false,
//   "updateMessage":           "A new version is available with bug fixes and improvements.",
//   "appStoreURL":             "https://apps.apple.com/us/app/sacred-pathway-driver-hub/id6762578372"
// }
//
// Versioning rules
// ----------------
// • Versions are compared with `String.compare(_:options:.numeric)` so
//   "1.10.0" correctly sorts above "1.9.0".
// • If the installed CFBundleShortVersionString is < minimumSupportedVersion
//   OR forceUpdateRequired is true while installed < latestVersion, the
//   force-update screen is shown.
// • All fields are optional in the JSON to keep older builds forward-
//   compatible — missing fields fall back to "do not block".
// =============================================================================

struct RemoteAppConfig: Codable, Equatable {
    /// Hard floor — anything below this MUST update.
    var minimumSupportedVersion: String?

    /// Hard floor on build number (CFBundleVersion). Anyone below this is blocked
    /// even if `minimumSupportedVersion` would let them through. Use this when
    /// you ship a same-version hot-fix and need to invalidate the prior build.
    var minimumSupportedBuild: Int?

    /// Newest released version. Used together with `forceUpdateRequired`.
    var latestVersion: String?

    /// Newest released build (CFBundleVersion). Optional companion to
    /// `latestVersion`. Shown in logs and used by the soft kill-switch.
    var latestBuild: Int?

    /// Master kill-switch. When true, anyone below `latestVersion`/`latestBuild`
    /// is blocked. Accepts both `force_update_required` and the shorter
    /// `force_update` keys in the wire JSON.
    var forceUpdateRequired: Bool?

    /// User-facing copy shown on the blocking screen.
    var updateMessage: String?

    /// Direct App Store / TestFlight URL the "Update Now" button opens.
    /// Accepts both `app_store_url` and `update_url` in the wire JSON.
    var appStoreURL: String?

    // Both naming conventions are accepted on decode so the JSON file in
    // Supabase can be edited in either style without breaking older clients
    // already in the field.
    //
    //   camelCase:  minimumSupportedVersion / minimumSupportedBuild
    //               latestVersion / latestBuild / forceUpdateRequired
    //               updateMessage / appStoreURL
    //   snake_case: minimum_supported_version / minimum_supported_build
    //               latest_version / latest_build / force_update[_required|_enabled]
    //               update_message / message / app_store_url / update_url
    //
    // Encoding always uses camelCase (matches the historical format).
    private enum CodingKeys: String, CodingKey {
        case minimumSupportedVersion
        case minimumSupportedBuild
        case latestVersion
        case latestBuild
        case forceUpdateRequired
        case updateMessage
        case appStoreURL
    }
    private enum SnakeKeys: String, CodingKey {
        case minimum_supported_version
        case minimum_supported_build
        case latest_version
        case latest_build
        case force_update_enabled
        case force_update_required
        case force_update
        case update_message
        case message
        case app_store_url
        case update_url
    }

    init(
        minimumSupportedVersion: String? = nil,
        minimumSupportedBuild: Int? = nil,
        latestVersion: String? = nil,
        latestBuild: Int? = nil,
        forceUpdateRequired: Bool? = nil,
        updateMessage: String? = nil,
        appStoreURL: String? = nil
    ) {
        self.minimumSupportedVersion = minimumSupportedVersion
        self.minimumSupportedBuild   = minimumSupportedBuild
        self.latestVersion           = latestVersion
        self.latestBuild             = latestBuild
        self.forceUpdateRequired     = forceUpdateRequired
        self.updateMessage           = updateMessage
        self.appStoreURL             = appStoreURL
    }

    init(from decoder: Decoder) throws {
        let camel = try? decoder.container(keyedBy: CodingKeys.self)
        let snake = try? decoder.container(keyedBy: SnakeKeys.self)

        // Prefer camelCase when present, then fall back to snake_case.
        self.minimumSupportedVersion =
            try? camel?.decodeIfPresent(String.self, forKey: .minimumSupportedVersion)
            ?? snake?.decodeIfPresent(String.self, forKey: .minimum_supported_version)

        // Build numbers are usually Int, but some hosted JSON tools write them
        // as quoted strings — accept either.
        self.minimumSupportedBuild =
            (try? camel?.decodeIfPresent(Int.self, forKey: .minimumSupportedBuild))
            ?? (try? snake?.decodeIfPresent(Int.self, forKey: .minimum_supported_build))
            ?? Self.intFromString(
                (try? camel?.decodeIfPresent(String.self, forKey: .minimumSupportedBuild))
                ?? (try? snake?.decodeIfPresent(String.self, forKey: .minimum_supported_build))
            )

        self.latestVersion =
            try? camel?.decodeIfPresent(String.self, forKey: .latestVersion)
            ?? snake?.decodeIfPresent(String.self, forKey: .latest_version)

        self.latestBuild =
            (try? camel?.decodeIfPresent(Int.self, forKey: .latestBuild))
            ?? (try? snake?.decodeIfPresent(Int.self, forKey: .latest_build))
            ?? Self.intFromString(
                (try? camel?.decodeIfPresent(String.self, forKey: .latestBuild))
                ?? (try? snake?.decodeIfPresent(String.self, forKey: .latest_build))
            )

        // Accept `force_update_required`, `force_update_enabled`, and `force_update`
        // — all three signal the same kill-switch.
        self.forceUpdateRequired =
            (try? camel?.decodeIfPresent(Bool.self, forKey: .forceUpdateRequired))
            ?? (try? snake?.decodeIfPresent(Bool.self, forKey: .force_update_required))
            ?? (try? snake?.decodeIfPresent(Bool.self, forKey: .force_update_enabled))
            ?? (try? snake?.decodeIfPresent(Bool.self, forKey: .force_update))

        self.updateMessage =
            try? camel?.decodeIfPresent(String.self, forKey: .updateMessage)
            ?? snake?.decodeIfPresent(String.self, forKey: .update_message)
            ?? snake?.decodeIfPresent(String.self, forKey: .message)

        self.appStoreURL =
            try? camel?.decodeIfPresent(String.self, forKey: .appStoreURL)
            ?? snake?.decodeIfPresent(String.self, forKey: .app_store_url)
            ?? snake?.decodeIfPresent(String.self, forKey: .update_url)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(minimumSupportedVersion, forKey: .minimumSupportedVersion)
        try c.encodeIfPresent(minimumSupportedBuild,   forKey: .minimumSupportedBuild)
        try c.encodeIfPresent(latestVersion,           forKey: .latestVersion)
        try c.encodeIfPresent(latestBuild,             forKey: .latestBuild)
        try c.encodeIfPresent(forceUpdateRequired,     forKey: .forceUpdateRequired)
        try c.encodeIfPresent(updateMessage,           forKey: .updateMessage)
        try c.encodeIfPresent(appStoreURL,             forKey: .appStoreURL)
    }

    private static func intFromString(_ s: String?) -> Int? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return Int(s)
    }
}
