import SwiftUI
import StoreKit

// =============================================================================
//  PaywallView — App Store review-safe implementation
// -----------------------------------------------------------------------------
//  Shows LIVE products loaded from StoreKit 2 (no placeholder prices, no
//  "coming soon" copy). Covers every state required by Apple review:
//
//    • Loading spinner while products are fetching
//    • Error message with a Retry button if the fetch fails
//    • Real purchase buttons that trigger the system purchase sheet
//    • Real Restore Purchases that calls AppStore.sync()
//    • Close button that always dismisses
//    • Working Terms of Service and Privacy Policy links
//    • Subscription auto-renewal disclosure text (Apple requirement)
//
//  All state is owned by the shared SubscriptionService — this view only
//  renders and delegates.
// =============================================================================

struct PaywallView: View {
    @StateObject private var sub = SubscriptionService.shared
    @Environment(\.dismiss) private var dismiss

    /// Which tier the user is currently viewing (Pro vs Carrier).
    @State private var selectedTier: SubscriptionTier = .pro

    /// True when this paywall is acting as the full-screen access gate
    /// (no Close button — the user can only exit by purchasing or signing
    /// out). False (default) is the in-app upgrade flow where Close
    /// returns to wherever the user opened the paywall from.
    var isGatedFullScreen: Bool = false

    /// Optional sign-out callback. Only rendered when the paywall is the
    /// gate. Lets the user back out of the gate without being trapped.
    var onSignOut: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        header

                        // Tier picker is only meaningful when the user is
                        // shopping. For already-subscribed users we render
                        // the subscribed state directly with no picker.
                        if !sub.accessLevel.isPaid {
                            tierPicker
                        }

                        content

                        legalFooter
                    }
                    .padding()
                }
            }
            .navigationTitle("Upgrade")
            .navigationBarBackButtonHidden(isGatedFullScreen)
            .interactiveDismissDisabled(isGatedFullScreen)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isGatedFullScreen, let onSignOut {
                        Button("Sign Out") { onSignOut() }
                            .foregroundStyle(Color.spTextSecondary)
                    } else {
                        Button("Close") { dismiss() }
                            .foregroundStyle(Color.spGold)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await sub.restorePurchases() }
                    } label: {
                        if sub.isPurchasing {
                            ProgressView().tint(Color.spGold)
                        } else {
                            Text("Restore")
                        }
                    }
                    .foregroundStyle(Color.spGold)
                    .disabled(sub.isPurchasing)
                }
            }
            .task {
                // Always re-fetch on open so the user sees fresh prices
                // (App Store pricing can change without an app update).
                await sub.loadProducts()
                await sub.refreshEntitlements()

                // Partial-failure resilience: if the user lands on a tier
                // whose products didn't load, but the other tier did, flip
                // the picker so they see real plans instead of an empty
                // tab. Better than punishing them for an App Store Connect
                // status quirk on a single tier.
                let other: SubscriptionTier = (selectedTier == .pro) ? .carrier : .pro
                if sub.products(for: selectedTier).isEmpty,
                   !sub.products(for: other).isEmpty {
                    selectedTier = other
                }
            }
        }
    }

    // MARK: - Header
    //
    // Header copy is now state-aware. Three states:
    //   1. Subscribed (.pro / .carrier) → "You're subscribed to <X>" with no
    //      trial headline at all. Manage Subscription + Close are the only
    //      actions surfaced; the product list is hidden via `subscribedState`.
    //   2. Free Basic and the SELECTED tier has at least one product with a
    //      StoreKit-confirmed free trial → trial headline.
    //   3. Free Basic and the selected tier has no eligible free trial →
    //      neutral "Upgrade" headline. Never lie about a trial that doesn't
    //      exist for the product the user is about to buy.

    @ViewBuilder
    private var header: some View {
        if sub.accessLevel.isPaid {
            subscribedHeader
        } else {
            freeBasicHeader
        }
    }

    /// "You're subscribed to <Tier>" — no trial pitch, no upgrade urgency.
    private var subscribedHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.spSuccess)
            Text("You're subscribed to \(sub.accessLevel.displayName)")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.spTextPrimary)
                .multilineTextAlignment(.center)
            Text(subscribedBlurb)
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    private var subscribedBlurb: String {
        switch sub.accessLevel {
        case .pro:
            return "Pro unlocks unlimited loads, PDF paystub export, broker intelligence, and Smart Insights."
        case .carrier:
            return "Carrier unlocks everything in Pro plus multi-driver, white-label paystubs, driver scorecard, and IFTA auto-tracking."
        case .freeBasic:
            return ""
        }
    }

    /// Free Basic + tier-aware. Only shows the 7-day trial headline if the
    /// SELECTED tier has at least one StoreKit-confirmed free intro offer.
    /// Otherwise we render a neutral upgrade headline so reviewers and
    /// already-subscribed (but mis-detected) users don't see false promises.
    private var freeBasicHeader: some View {
        let selectedTierHasTrial = sub.products(for: selectedTier).contains { $0.hasFreeTrialOffer }

        return VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(Color.spGold)

            if selectedTierHasTrial {
                Text("Start Your Free Trial")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.spTextPrimary)
                    .multilineTextAlignment(.center)

                if isGatedFullScreen {
                    Text("Create your account for free. Try \(selectedTier.displayName) free, then keep going if you love it.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.spGoldLight)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            } else {
                Text("Upgrade to \(selectedTier.displayName)")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.spTextPrimary)
                    .multilineTextAlignment(.center)

                if isGatedFullScreen {
                    Text("Create your account for free. Pick a plan to unlock the full app.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.spGoldLight)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }

            Text("Unlimited loads, PDF paystub exports, broker intelligence, and fleet-level tools — all in one place.")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    // MARK: - Tier picker

    private var tierPicker: some View {
        Picker("Tier", selection: $selectedTier) {
            Text("Pro").tag(SubscriptionTier.pro)
            Text("Carrier").tag(SubscriptionTier.carrier)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Content (switches on load state)

    @ViewBuilder
    private var content: some View {
        if sub.accessLevel.isPaid {
            // Already subscribed — never show purchase CTAs again here.
            // Manage Subscription deep-links to Apple's subscription page,
            // which is the only correct way to upgrade / downgrade /
            // cancel an active subscription on iOS.
            subscribedState
        } else {
            switch sub.loadState {
            case .idle, .loading:
                loadingState
            case .failed(let message):
                errorState(message: message)
            case .loaded:
                loadedState
            }
        }
    }

    /// "You're subscribed" block — replaces the product list for paid users.
    /// Two actions only: Manage Subscription (Apple), Close (or Sign Out if
    /// we somehow got here from the gated full-screen path, which shouldn't
    /// happen for a subscribed user but is handled defensively).
    private var subscribedState: some View {
        VStack(spacing: 14) {
            tierSummaryCard(activeSubscribedTier)

            // Apple's deep-link to system Subscriptions. Same URL the
            // SubscriptionSettingsView screen uses.
            Link(destination: Config.Legal.manageSubscriptionsURL) {
                HStack {
                    Image(systemName: "gearshape.fill")
                    Text("Manage Subscription")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.spGold)
                .foregroundStyle(Color.spBlack)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Button {
                dismiss()
            } label: {
                Text("Close")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.spCardBg)
                    .foregroundStyle(Color.spGold)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spGold.opacity(0.4), lineWidth: 1))
            }
        }
    }

    /// Bridge `AccessLevel` → `SubscriptionTier` for the tier summary card.
    /// (We can't reuse `selectedTier` because the user could have toggled
    /// the picker before becoming subscribed; we always render their actual
    /// active tier in the subscribed state.)
    private var activeSubscribedTier: SubscriptionTier {
        switch sub.accessLevel {
        case .pro:       return .pro
        case .carrier:   return .carrier
        case .freeBasic: return .pro    // unreachable in subscribedState
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(Color.spGold)
            Text("Loading plans…")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(Color.spGold)
            Text("We couldn't load the subscription plans.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await sub.loadProducts() }
            } label: {
                Text("Try again")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spBlack)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.spGold)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var loadedState: some View {
        let tierProducts = sub.products(for: selectedTier)

        if tierProducts.isEmpty {
            // This tier has no products configured in App Store Connect.
            // Don't show any placeholder text — just hide the tier so the
            // user sees a clean, complete UI.
            errorState(message: "Plans for the \(selectedTier.displayName) tier are temporarily unavailable. Try again in a moment.")
        } else {
            VStack(spacing: 16) {
                tierSummaryCard(selectedTier)

                if let error = sub.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.spDanger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(tierProducts, id: \.id) { product in
                    productButton(product)
                }
            }
        }
    }

    // MARK: - Tier summary

    private func tierSummaryCard(_ tier: SubscriptionTier) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tier.displayName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.spGold)
                Spacer()
                if sub.activeTier == tier {
                    Text("CURRENT")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.spSuccess)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.spSuccess.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            ForEach(perks(for: tier), id: \.self) { perk in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.spSuccess)
                        .font(.caption)
                    Text(perk)
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextPrimary)
                    Spacer()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func perks(for tier: SubscriptionTier) -> [String] {
        switch tier {
        case .free:
            return []
        case .pro:
            return [
                "Unlimited loads",
                "PDF paystub export",
                "Broker intelligence (avg rate per mile, top lanes)",
                "Smart Insights — AI summaries of your week"
            ]
        case .carrier:
            return [
                "Everything in Pro",
                "Unlimited drivers",
                "White-label branding on paystub PDFs",
                "Driver scorecard — profit & on-time per driver",
                "IFTA auto-tracking"
            ]
        }
    }

    // MARK: - Purchase button

    private func productButton(_ product: Product) -> some View {
        // CTA text — driven by StoreKit's introductoryOffer when present so
        // Apple's review never sees a hardcoded "free trial" claim that
        // doesn't match the actual product configuration.
        let cta = product.hasFreeTrialOffer ? "Start Free Trial" : "Subscribe"

        return VStack(spacing: 8) {
            Button {
                Task { await sub.purchase(product) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(product.displayName.isEmpty ? product.id : product.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.spBlack)
                        if let trial = product.freeTrialSummary {
                            // StoreKit-sourced trial summary — Apple-compliant.
                            Text(trial)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.spBlack)
                        } else if !product.billingPeriodText.isEmpty {
                            Text("\(product.displayPrice) \(product.billingPeriodText)")
                                .font(.caption)
                                .foregroundStyle(Color.spBlack.opacity(0.7))
                        }
                    }
                    Spacer()
                    if sub.isPurchasing {
                        ProgressView().tint(Color.spBlack)
                    } else {
                        Text(cta)
                            .font(.headline)
                            .foregroundStyle(Color.spBlack)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.spGold)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(sub.isPurchasing)

            // Per-product Apple-required trial + auto-renewal disclosure.
            // Shown immediately below the CTA so the user cannot miss it.
            if product.hasFreeTrialOffer {
                Text(trialDisclosure(for: product))
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Apple-compliant per-product disclosure shown next to the CTA. Pulls
    /// the trial length, price, and period from StoreKit so the wording always
    /// matches App Store Connect — no risk of stale hardcoded copy triggering
    /// a 3.1.2 rejection. Only invoked when `product.hasFreeTrialOffer` is true
    /// (caller-gated), so the trial sentence is guaranteed to be accurate.
    private func trialDisclosure(for product: Product) -> String {
        let price = product.displayPrice
        let period = product.billingPeriodText.isEmpty
            ? "per renewal period"
            : product.billingPeriodText
        // freeTrialSummary already contains the StoreKit-confirmed length,
        // e.g. "7 days free, then $49.99/per month". Falling back to a
        // generic phrasing here is defensive — caller never invokes this
        // function unless hasFreeTrialOffer is true.
        let trial = product.freeTrialSummary ?? "Free trial included."
        let name = product.displayName.isEmpty ? "this plan" : product.displayName
        return """
        \(trial). After the trial, \(name) auto-renews at \(price) \(period) until canceled. Cancel anytime in your Apple ID Subscriptions settings at least 24 hours before the trial ends to avoid charges. Payment is charged to your Apple ID at confirmation of purchase.
        """
    }

    // MARK: - Legal footer (auto-renewal disclosure is an Apple requirement)

    private var legalFooter: some View {
        VStack(spacing: 6) {
            Text("Subscriptions are auto-renewable. Free trials convert to a paid subscription unless canceled at least 24 hours before the trial ends. Payment is charged to your Apple ID at confirmation of purchase. Manage or cancel in Settings → Apple ID → Subscriptions.")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Link("Terms of Use", destination: Config.Legal.termsOfServiceURL)
                Text("•")
                Link("Privacy Policy", destination: Config.Legal.privacyPolicyURL)
            }
            .font(.caption2)
            .foregroundStyle(Color.spGold)
        }
        .padding(.top, 8)
    }
}
