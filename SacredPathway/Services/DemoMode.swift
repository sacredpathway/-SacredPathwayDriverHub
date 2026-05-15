import Foundation

/// DEBUG-only entitlement override for screenshot capture and local development.
///
/// The whole `unlockAllFeatures` storage is stripped from Release builds via
/// the `#if DEBUG` gate below, so production runs always go through the real
/// StoreKit + Supabase entitlement flow. Flipping this in a Release build is
/// physically impossible — the symbol doesn't exist there.
enum DemoMode {
    #if DEBUG
    /// When `true`, every paywall check resolves as if the user is on the
    /// Carrier tier. Default ON in DEBUG so `cmd+R` from Xcode lands in a
    /// fully-unlocked app for App Store screenshot capture. Toggle from
    /// Settings → Developer → Demo Mode (Unlock All) at runtime.
    static var unlockAllFeatures: Bool = true
    #else
    static let unlockAllFeatures: Bool = false
    #endif
}
