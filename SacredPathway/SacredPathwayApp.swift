import SwiftUI
import UIKit
@preconcurrency import UserNotifications
import Supabase

@main
struct SacredPathwayApp: App {
    // Dispatcher push registration (staging-safe). Inert unless the remote kill switch
    // (RemoteAppConfig.dispatcherMessagesEnabled) is true — default OFF means no
    // permission prompt, no token collection, and zero behavior change in production.
    @UIApplicationDelegateAdaptor(DriverPushRegistrar.self) private var pushRegistrar

    @StateObject private var supabase = SupabaseService()
    @StateObject private var subscription = SubscriptionService.shared
    @StateObject private var appearance = AppearanceService.shared
    @StateObject private var forceUpdate = ForceUpdateService.shared

    /// Free Local Mode vs Cloud Sync mode picker — UserDefaults backed.
    /// `.notSet` on first launch routes the root view to WelcomeView; once
    /// the user picks, `.local` skips AccessGate entirely and `.cloud`
    /// flows through the existing LoginView → AccessGate → Paywall path.
    @StateObject private var appMode = AppMode.shared

    /// Combines auth + entitlement state into a single 4-state machine so
    /// the root view body can route deterministically. Apple Sign In and
    /// email/password both flow through the same gate. Only consulted when
    /// AppMode.mode == .cloud.
    @StateObject private var accessGate: AccessGate

    init() {
        // SwiftUI quirk: @StateObject can't reference other @StateObjects in
        // its default initializer because property wrappers are constructed
        // before `self` is available. So we hand-build AccessGate here using
        // the same singletons the @StateObjects above wrap.
        let supabaseInstance = SupabaseService()
        let gate = AccessGate(
            supabase: supabaseInstance,
            subscription: SubscriptionService.shared
        )
        _supabase = StateObject(wrappedValue: supabaseInstance)
        _accessGate = StateObject(wrappedValue: gate)
        #if DEBUG
        DriverHubUITestMode.prepare(appMode: AppMode.shared)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Brand surface — adapts automatically to light/dark.
                Color.spBackground.ignoresSafeArea()

                rootContent
            }
            .preferredColorScheme(appearance.mode.colorScheme)
            // Milestone-driven App Store review prompts (ReviewPromptService).
            // One host at the root; call sites just register milestones.
            .reviewPromptHost()
            .task {
                // Kick off product fetch + entitlement refresh as soon as
                // the app is on screen. AccessGate.performInitialEntitlementCheck
                // sets isCheckingEntitlement→true while this runs so the
                // root view stays on the loading splash and never flickers
                // through Dashboard before settling on Paywall.
                await accessGate.performInitialEntitlementCheck()
            }
            .task {
                // Force-update check runs in parallel with the auth restore.
                // Fail-open inside the service guarantees we never lock the
                // user out due to network/CDN issues.
                await forceUpdate.checkForUpdate()
            }
            .task {
                // Phase B smoke test — DEBUG only, gated by either
                // `-RunLocalSmokeTest` launch arg or the
                // `sp.debug.local.smoke_test` UserDefaults bool. No-op on
                // Release builds; this whole task compiles out.
                #if DEBUG
                await LocalSmokeTest.runIfRequested()
                #endif
            }
            .onChange(of: supabase.isAuthenticated) { _, newValue in
                // Re-check entitlements on every sign-in transition (false →
                // true). Sign-out is handled by AccessGate's auth subscriber.
                if newValue {
                    Task { await accessGate.performInitialEntitlementCheck() }
                }
                // Bootstrap upgrade safety: existing v2.0.x users who land on
                // this build already authed must NOT see WelcomeView. If
                // AppMode is still .notSet when auth flips to true, lock in
                // .cloud silently.
                AppMode.shared.bootstrapForExistingCloudUser(isAuthenticated: newValue)
            }
            .onAppear {
                // Bootstrap on cold launch — Supabase may already be signed
                // in from a previous build before AppMode existed.
                AppMode.shared.bootstrapForExistingCloudUser(
                    isAuthenticated: supabase.isAuthenticated
                )
                // Safety timeout — if loading hangs for more than 4 seconds, force show login
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if supabase.isLoading {
                        supabase.isLoading = false
                    }
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Root view selector
    //
    // Order of precedence (top wins):
    //   1. Force-update screen — blocks everything when remote config flags
    //      this build as out of date. ScreenshotMode is exempt so App Store
    //      screenshots can still be captured locally.
    //   2. Splash / loading state (Supabase auth restoring).
    //   3. AppMode pick:
    //        .notSet → WelcomeView (first-launch chooser)
    //        .local  → ContentView (Free Local Mode, AccessGate bypassed)
    //        .cloud  → AccessGate state machine (existing path)
    // ─────────────────────────────────────────────────────────────────────
    @ViewBuilder
    private var rootContent: some View {
        if forceUpdate.shouldForceUpdate && !ScreenshotMode.isActive {
            ForceUpdateView()
                .transition(.opacity)
        } else if ScreenshotMode.isActive || DriverHubUITestMode.isActive {
            // Hard fast-path: skip splash + login + paywall entirely.
            ContentView()
                .environmentObject(supabase)
                .environmentObject(subscription)
        } else if supabase.isLoading {
            loadingSplash(message: "Loading...")
        } else {
            switch appMode.mode {
            case .notSet:
                // First-launch chooser. Writing AppMode flips this branch
                // automatically via @StateObject observation.
                WelcomeView()
                    .environmentObject(supabase)
                    .environmentObject(subscription)
                    .environmentObject(appMode)

            case .local:
                // Free Local Mode — AccessGate intentionally bypassed.
                // ContentView is reached without an account or paywall.
                // Subscription-only features inside the app remain gated by
                // SubscriptionService.activeTier (unchanged).
                ContentView()
                    .environmentObject(supabase)
                    .environmentObject(subscription)
                    .environmentObject(appMode)

            case .cloud:
                // Existing Cloud Sync path — LoginView → loading → Paywall →
                // ContentView. No behaviour change for current users.
                accessGateView
            }
        }
    }

    @ViewBuilder
    private var accessGateView: some View {
        switch accessGate.state {
        case .unauthenticated:
            LoginView()
                .environmentObject(supabase)

        case .authenticatedCheckingSubscription:
            loadingSplash(message: "Checking your subscription…")

        case .needsSubscription:
            // Full-screen paywall acting as the access gate. The "Sign Out"
            // toolbar button (only rendered when isGatedFullScreen=true)
            // lets a user back out without being trapped.
            PaywallView(
                isGatedFullScreen: true,
                onSignOut: {
                    Task {
                        try? await supabase.signOut()
                    }
                }
            )
            .environmentObject(supabase)
            .environmentObject(subscription)

        case .subscribed:
            ContentView()
                .environmentObject(supabase)
                .environmentObject(subscription)
        }
    }

    // Reusable splash view used in both auth-loading and entitlement-checking
    // phases. Centered logo + spinner + caption.
    @ViewBuilder
    private func loadingSplash(message: String) -> some View {
        VStack(spacing: 16) {
            Image("SacredPathwayLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            ProgressView()
                .tint(Color.spGold)
            Text(message)
                .foregroundStyle(Color.spTextPrimary)
                .font(.subheadline)
        }
    }
}

// MARK: - Dispatcher push registration (staging-safe; gated by the remote kill switch)
//
// Registers for APNs and upserts a device token (app = "driver_hub") into
// `dispatch_device_tokens` — but ONLY when the remote flag
// `RemoteAppConfig.dispatcherMessagesEnabled` is true. Default is OFF, so in production
// there is NO permission prompt, NO token collection, and NO behavior change. This
// mirrors the Dispatcher Hub token flow.
//
// NOTE (owner): the Driver Hub target must ALSO have Push Notifications + Background
// Modes (remote-notification) added in Xcode for tokens to actually arrive. Adding this
// code does not, by itself, prompt users while the flag is OFF.
final class DriverPushRegistrar: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let client = SupabaseClient(supabaseURL: Config.supabaseURL, supabaseKey: Config.supabaseAnonKey)
    private var didRequest = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Register the Maps background-refresh task. Must run before launch
        // completes; identifier is declared in Info.plist. Inert when the Maps
        // feature is off or Background App Refresh is disabled by the user.
        if MapFeatureFlags.enabled {
            BackgroundRefreshManager.register()
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Queue an opportunistic snapshot refresh so the maps are fresh on next open.
        if MapFeatureFlags.enabled {
            BackgroundRefreshManager.schedule()
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Final runtime gate: register only when the remote kill switch enables messaging.
        guard ForceUpdateService.shared.config?.dispatcherMessagesEnabled == true, !didRequest else { return }
        didRequest = true
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { await MainActor.run { UIApplication.shared.registerForRemoteNotifications() } }
        }
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard let uid = client.auth.currentUser?.id else { return }
        struct TokenUpsert: Encodable, Sendable { let profile_id: UUID; let token: String; let platform: String; let app: String }
        let row = TokenUpsert(profile_id: uid, token: token, platform: "ios", app: "driver_hub")
        Task { [client, row] in
            _ = try? await client.from("dispatch_device_tokens")
                .upsert(row, onConflict: "token,app")
                .execute()
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) { /* non-fatal */ }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}
