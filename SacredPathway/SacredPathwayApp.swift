import SwiftUI

@main
struct SacredPathwayApp: App {
    @StateObject private var supabase = SupabaseService()
    @StateObject private var subscription = SubscriptionService.shared
    @StateObject private var appearance = AppearanceService.shared
    @StateObject private var forceUpdate = ForceUpdateService.shared

    /// Free Local Mode vs Cloud Pro mode picker — UserDefaults backed.
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
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Brand surface — adapts automatically to light/dark.
                Color.spBackground.ignoresSafeArea()

                rootContent
            }
            .preferredColorScheme(appearance.mode.colorScheme)
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
        } else if ScreenshotMode.isActive {
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
                // Pro features inside the app remain gated by
                // SubscriptionService.activeTier (unchanged).
                ContentView()
                    .environmentObject(supabase)
                    .environmentObject(subscription)
                    .environmentObject(appMode)

            case .cloud:
                // Existing Cloud Pro path — LoginView → loading → Paywall →
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
