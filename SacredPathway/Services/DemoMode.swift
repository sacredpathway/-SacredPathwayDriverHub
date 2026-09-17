import Foundation

/// DEBUG-only entitlement override for QA and local development.
///
/// The whole `unlockAllFeatures` storage is stripped from Release builds via
/// the `#if DEBUG` gate below, so production runs always go through the real
/// StoreKit + Supabase entitlement flow. Flipping this in a Release build is
/// physically impossible — the symbol doesn't exist there.
enum DemoMode {
    #if DEBUG
    private static let manualOverrideKey = "sp.debug.unlockAllFeatures"

    /// When `true`, every paywall check resolves as if the user is on the
    /// Carrier tier. This is DEBUG-only and intentionally opt-in:
    ///   - launch with `-DriverHubQAEntitlementBypass YES`, or
    ///   - toggle Settings → Developer → QA Entitlement Override.
    ///
    /// Release builds compile out this storage and always return `false`.
    static var unlockAllFeatures: Bool {
        get {
            DriverHubQAMode.entitlementBypass ||
            UserDefaults.standard.bool(forKey: manualOverrideKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: manualOverrideKey)
        }
    }
    #else
    static let unlockAllFeatures: Bool = false
    #endif
}

#if DEBUG
enum DriverHubQAMode {
    private static let entitlementBypassKey = "DriverHubQAEntitlementBypass"

    /// DEBUG-only launch flag used for role-routing QA when a reviewer/tester
    /// needs to reach the app after auth without a live StoreKit entitlement.
    /// Example:
    /// `-DriverHubQAEntitlementBypass YES`
    static let entitlementBypass: Bool = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-DriverHubQAEntitlementBypass") ||
            args.contains("--DriverHubQAEntitlementBypass") {
            return true
        }
        return UserDefaults.standard.bool(forKey: entitlementBypassKey)
    }()
}
#endif
