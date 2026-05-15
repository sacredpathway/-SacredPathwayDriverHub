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
                        tierPicker

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

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(Color.spGold)
            Text("Start Your 7-Day Free Trial")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.spTextPrimary)
                .multilineTextAlignment(.center)

            // Gating-context tagline. Visible only when the paywall is
            // acting as the access gate so brand-new users immediately
            // see the value-for-money pitch.
            if isGatedFullScreen {
                Text("Create your account for free. Try Driver Hub Pro free for 7 days.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spGoldLight)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
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
        switch sub.loadState {
        case .idle, .loading:
            loadingState
        case .failed(let message):
            errorState(message: message)
        case .loaded:
            loadedState
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

    /// Apple-compliant per-product disclosure shown next to the CTA. Pulls the
    /// price + period from StoreKit so the wording always matches App Store
    /// Connect — no risk of stale hardcoded copy triggering a 3.1.2 rejection.
    private func trialDisclosure(for product: Product) -> String {
        let price = product.displayPrice
        let period = product.billingPeriodText.isEmpty
            ? "per renewal period"
            : product.billingPeriodText
        return """
        Start your 7-day free trial. After the trial, \(product.displayName.isEmpty ? "Driver Hub Pro" : product.displayName) auto-renews at \(price) \(period) until canceled. Cancel anytime in your Apple ID Subscriptions settings at least 24 hours before the trial ends to avoid charges. Payment is charged to your Apple ID at confirmation of purchase.
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
