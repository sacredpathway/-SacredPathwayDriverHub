import Foundation
import SwiftUI
import Combine

// =============================================================================
// AccessGate
// -----------------------------------------------------------------------------
// Single source of truth for what the app's root view should render.
// Combines `SupabaseService.isAuthenticated` (auth) with
// `SubscriptionService.activeTier` (entitlement) plus a "checking" flag, then
// derives a 4-state machine:
//
//   .unauthenticated                  → LoginView
//   .authenticatedCheckingSubscription → loading splash
//   .needsSubscription                → PaywallView (gate)
//   .subscribed                       → ContentView (full app)
//
// SAFETY
// ------
// Fail-CLOSED: if the entitlement check fails for any reason — StoreKit
// outage, no network, missing receipt — we return `.needsSubscription`,
// NOT `.subscribed`. That matches the spec ("If subscription status cannot
// be verified, show paywall instead of dashboard").
//
// Apple Sign In and email/password go through the EXACT same gate because
// the only inputs are `isAuthenticated` (any provider) and `activeTier`
// (StoreKit, identical for all providers).
// =============================================================================

enum AccessGateState: Equatable {
    case unauthenticated
    case authenticatedCheckingSubscription
    case needsSubscription
    case subscribed
}

@MainActor
final class AccessGate: ObservableObject {

    // MARK: - Published

    @Published private(set) var state: AccessGateState = .unauthenticated

    /// True while the very first entitlement check after sign-in is still
    /// running. Drives the loading splash so the user never flickers
    /// between Login → Dashboard → Paywall on cold launch.
    @Published private(set) var isCheckingEntitlement: Bool = false

    // MARK: - Dependencies (weak references via `unowned` is unsafe across
    // app lifetime, so keep strong — both are app-scoped singletons anyway).

    private let supabase: SupabaseService
    private let subscription: SubscriptionService

    private var cancellables: Set<AnyCancellable> = []

    /// Tracks whether we've completed at least one entitlement refresh after
    /// the most recent sign-in transition. Reset to false on sign-out.
    private var hasCompletedFirstCheck: Bool = false

    // MARK: - Init

    init(supabase: SupabaseService, subscription: SubscriptionService) {
        self.supabase = supabase
        self.subscription = subscription

        // React to auth changes.
        supabase.$isAuthenticated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeState() }
            .store(in: &cancellables)

        // React to entitlement changes (purchase, restore, refund, family
        // sharing, etc.).
        subscription.$activeTier
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeState() }
            .store(in: &cancellables)

        // Initial compute so the first frame after launch has a real state.
        recomputeState()
    }

    // MARK: - Public lifecycle hook

    /// Called after sign-in completes (root view's `.task`) so the very
    /// first cold-launch entitlement check sets `isCheckingEntitlement`
    /// properly and produces a stable terminal state without a UI flicker.
    func performInitialEntitlementCheck() async {
        // No point checking entitlements if we aren't signed in yet — the
        // `recomputeState()` in init already settled the right state.
        guard supabase.isAuthenticated else {
            hasCompletedFirstCheck = false
            recomputeState()
            return
        }

        isCheckingEntitlement = true
        recomputeState()

        // SubscriptionService.refreshOnAppLaunch loads products and
        // currentEntitlements in one shot. On any error it keeps the prior
        // `activeTier`; we treat that as "could not verify" and stay in
        // .needsSubscription via the recompute.
        await subscription.refreshOnAppLaunch()

        isCheckingEntitlement = false
        hasCompletedFirstCheck = true
        recomputeState()
    }

    // MARK: - Recompute

    private func recomputeState() {
        // ScreenshotMode bypass — App Store screenshot capture must never
        // be blocked by the paywall.
        if ScreenshotMode.isActive {
            state = .subscribed
            return
        }

        // Not signed in → login.
        if !supabase.isAuthenticated {
            state = .unauthenticated
            hasCompletedFirstCheck = false
            return
        }

        // Signed in but the very first entitlement check hasn't completed
        // yet → show the loading splash.
        if !hasCompletedFirstCheck || isCheckingEntitlement {
            state = .authenticatedCheckingSubscription
            return
        }

        // ─── DEBUG-only override ───────────────────────────────────────
        // When the app is launched with the `-AccessGateDebugForceUnsubscribed YES`
        // launch argument, treat this user as if their entitlement were
        // `.free` and route to the gated paywall. Used only to verify the
        // paywall flow without altering production data.
        //
        // The flag is a UserDefaults key populated by NSUserDefaults's
        // argumentDomain — it lives only for the lifetime of the launched
        // process. Relaunching without the arg returns to normal behavior.
        //
        // Wrapped in `#if DEBUG` so Release builds compile this branch out
        // entirely; production users can never trigger this path.
        #if DEBUG
        if Self.isDebugForceUnsubscribed {
            state = .needsSubscription
            return
        }
        #endif

        // Settled state. Free → paywall, anything paid → full app.
        if subscription.activeTier == .free {
            state = .needsSubscription
        } else {
            state = .subscribed
        }
    }

    #if DEBUG
    /// Set when the host process was launched with
    /// `-AccessGateDebugForceUnsubscribed YES` (or `1`). Read once per
    /// recompute so toggling it off mid-session via SwiftUI debug previews
    /// doesn't get sticky.
    private static var isDebugForceUnsubscribed: Bool {
        UserDefaults.standard.bool(forKey: "AccessGateDebugForceUnsubscribed")
    }
    #endif
}
