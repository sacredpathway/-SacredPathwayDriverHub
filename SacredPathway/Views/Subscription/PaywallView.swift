import SwiftUI
import StoreKit

private enum DriverHubPaywallPlan: String, CaseIterable, Identifiable {
    case driver
    case ownerOperator
    case carrier

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .driver: return "Driver"
        case .ownerOperator: return "Owner Operator"
        case .carrier: return "Carrier"
        }
    }

    var icon: String {
        switch self {
        case .driver: return "steeringwheel"
        case .ownerOperator: return "truck.box.fill"
        case .carrier: return "building.2.fill"
        }
    }

    var selectorSubtitle: String {
        switch self {
        case .driver:
            return "$14.99/mo - company driver tools"
        case .ownerOperator:
            return "$29.99/mo - business reports"
        case .carrier:
            return "$49.99/mo - fleet operations"
        }
    }

    var headerBlurb: String {
        switch self {
        case .driver:
            return "Track loads, rate cons, documents, settlements, expenses, fuel, stats, history, and dispatcher communication."
        case .ownerOperator:
            return "Add CPA-ready exports, tax reports, mileage reports, profit and loss, revenue analytics, and advanced reports."
        case .carrier:
            return "Run company operations with carrier dashboards, driver and dispatcher management, fleet analytics, and team workflows."
        }
    }

    var perks: [String] {
        switch self {
        case .driver:
            return [
                "Load tracking and assigned load management",
                "Rate con uploads and document storage",
                "Settlement, expense, and fuel tracking",
                "Weekly/monthly stats, basic reports, and dispatcher messaging"
            ]
        case .ownerOperator:
            return [
                "Everything in Driver",
                "CPA-ready export and tax reports",
                "Mileage, profit and loss, and financial reporting",
                "Business/revenue analytics and advanced reports"
            ]
        case .carrier:
            return [
                "Everything in Driver and Owner Operator",
                "Carrier and fleet dashboards",
                "Driver, dispatcher, and company management",
                "Fleet analytics, fleet reporting, team operations, and approvals"
            ]
        }
    }

    var productIDs: Set<String> {
        switch self {
        case .driver:
            return [Config.IAP.driverHubProMonthly]
        case .ownerOperator:
            return [Config.IAP.proMonthly, Config.IAP.proAnnual]
        case .carrier:
            return [Config.IAP.carrierMonthly, Config.IAP.carrierAnnual]
        }
    }

    static func plan(for productID: String) -> DriverHubPaywallPlan? {
        allCases.first { $0.productIDs.contains(productID) }
    }

    static func productLabel(for productID: String) -> String {
        switch productID {
        case Config.IAP.driverHubProMonthly:
            return "Driver Monthly"
        case Config.IAP.proMonthly:
            return "Owner Operator Monthly"
        case Config.IAP.proAnnual:
            return "Owner Operator Annual (Legacy)"
        case Config.IAP.carrierMonthly:
            return "Carrier Monthly"
        case Config.IAP.carrierAnnual:
            return "Carrier Annual (Legacy)"
        default:
            return "Driver Hub Plan"
        }
    }
}

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

    /// Which purchasable Driver Hub plan the user is currently viewing.
    @State private var selectedPlan: DriverHubPaywallPlan = .driver

    /// True when this paywall is acting as the full-screen access gate
    /// (no Close button — the user can only exit by purchasing or signing
    /// out). False (default) is the in-app upgrade flow where Close
    /// returns to wherever the user opened the paywall from.
    var isGatedFullScreen: Bool = false

    /// Optional sign-out callback. Only rendered when the paywall is the
    /// gate. Lets the user back out of the gate without being trapped.
    var onSignOut: (() -> Void)? = nil

    /// S11: confirmation for the gated paywall's Free-Local-Mode escape
    /// hatch. The hard wall previously offered exactly two exits — pay or
    /// sign out — which converts a "not yet" into an uninstall. Local Mode
    /// is the app's own sanctioned free path (AppMode.setLocal, same call
    /// WelcomeView makes); this surfaces it at the moment of decision.
    @State private var showLocalModeConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        header

                        // Plan selector is only meaningful when the user is
                        // shopping. For already-subscribed users we render
                        // the subscribed state directly with no selector.
                        if !sub.accessLevel.isPaid {
                            planSelector
                        }

                        content

                        // S11: Free-Local-Mode escape hatch — GATE ONLY, and
                        // never for already-paid users. Mode switching is the
                        // app's existing sanctioned path (WelcomeView →
                        // setLocal; Settings → Switch to Cloud Sync for the
                        // way back). Entitlement logic untouched: AccessGate
                        // stays fail-closed for Cloud Mode.
                        if isGatedFullScreen && !sub.accessLevel.isPaid {
                            localModeEscapeHatch
                        }

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

                // Partial-failure resilience: if the user lands on a plan
                // whose products didn't load, but another plan did, flip
                // the selector so they see real plans instead of an empty
                // panel. Better than punishing them for an App Store Connect
                // status quirk on a single product.
                if products(for: selectedPlan).isEmpty,
                   let firstAvailable = DriverHubPaywallPlan.allCases.first(where: { !products(for: $0).isEmpty }) {
                    selectedPlan = firstAvailable
                }
            }
        }
    }

    // MARK: - Header
    //
    // Header copy is now state-aware. Three states:
    //   1. Subscribed -> "You're subscribed to <X>" with no
    //      trial headline at all. Manage Subscription + Close are the only
    //      actions surfaced; the product list is hidden via `subscribedState`.
    //   2. Free Basic and the selected plan has at least one product with a
    //      StoreKit-confirmed free trial → trial headline.
    //   3. Free Basic and the selected plan has no eligible free trial →
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

    /// "You're subscribed to <Plan>" — no trial pitch, no upgrade urgency.
    private var subscribedHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.spSuccess)
            Text("You're subscribed to \(activeSubscribedPlan?.displayName ?? sub.activePlanRoleName)")
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
        switch activeSubscribedPlan {
        case .driver?:
            return DriverHubPaywallPlan.driver.headerBlurb
        case .ownerOperator?:
            return DriverHubPaywallPlan.ownerOperator.headerBlurb
        case .carrier?:
            return DriverHubPaywallPlan.carrier.headerBlurb
        case nil:
            return "Your Driver Hub subscription is active."
        }
    }

    /// Free Basic + plan-aware. Only shows the 7-day trial headline if the
    /// selected plan has at least one StoreKit-confirmed free intro offer.
    /// Otherwise we render a neutral upgrade headline so reviewers and
    /// already-subscribed (but mis-detected) users don't see false promises.
    private var freeBasicHeader: some View {
        let selectedPlanHasTrial = products(for: selectedPlan).contains { $0.hasFreeTrialOffer }

        return VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(Color.spGold)

            if selectedPlanHasTrial {
                Text("Start Your Free Trial")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.spTextPrimary)
                    .multilineTextAlignment(.center)

                if isGatedFullScreen {
                    Text("Create your account for free. Try \(selectedPlan.displayName) free, then keep going if you love it.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.spGoldLight)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            } else {
                Text("Upgrade to \(selectedPlan.displayName)")
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

            Text(selectedPlan.headerBlurb)
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    // MARK: - Plan selector

    private var planSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose Plan")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.spTextSecondary)

            VStack(spacing: 8) {
                ForEach(DriverHubPaywallPlan.allCases) { plan in
                    planSelectorButton(plan)
                }
            }
        }
    }

    /// Selector subtitle price is StoreKit-sourced when the plan's products
    /// have loaded (App Store pricing can change without an app update —
    /// the hardcoded copy is only the pre-load fallback). Display-only;
    /// purchase flow already used live products.
    private func selectorSubtitle(for plan: DriverHubPaywallPlan) -> String {
        if let monthly = products(for: plan).first {
            let suffix: String = {
                switch plan {
                case .driver:        return "company driver tools"
                case .ownerOperator: return "business reports"
                case .carrier:       return "fleet operations"
                }
            }()
            return "\(monthly.displayPrice)/mo - \(suffix)"
        }
        return plan.selectorSubtitle
    }

    private func planSelectorButton(_ plan: DriverHubPaywallPlan) -> some View {
        let isSelected = selectedPlan == plan
        return Button {
            SPHaptics.selection()
            selectedPlan = plan
        } label: {
            HStack(spacing: 12) {
                Image(systemName: plan.icon)
                    .foregroundStyle(isSelected ? Color.spBlack : Color.spGold)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plan.displayName)
                            .font(.subheadline.weight(.bold))
                        // Honest anchor: Owner Operator is the app's core
                        // persona and flagship tier — a positioning fact,
                        // not a popularity claim.
                        if plan == .ownerOperator {
                            Text("RECOMMENDED")
                                .font(.system(size: 9, weight: .heavy))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background((isSelected ? Color.spBlack : Color.spGold).opacity(0.15))
                                .foregroundStyle(isSelected ? Color.spBlack : Color.spGoldText)
                                .clipShape(Capsule())
                        }
                    }
                    Text(selectorSubtitle(for: plan))
                        .font(.caption)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                }
            }
            .foregroundStyle(isSelected ? Color.spBlack : Color.spTextPrimary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.spGold : Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.spGold : Color.spTextSecondary.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
            if let activeSubscribedPlan {
                planSummaryCard(activeSubscribedPlan)
            }

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

    /// Resolve the paid StoreKit entitlement back to the user-facing plan.
    /// We intentionally use exact product IDs first so Driver and Owner
    /// Operator remain distinct after the old Pro tier was split into
    /// Driver and Owner Operator.
    private var activeSubscribedPlan: DriverHubPaywallPlan? {
        if sub.activeProductIDs.contains(Config.IAP.carrierMonthly) ||
            sub.activeProductIDs.contains(Config.IAP.carrierAnnual) {
            return .carrier
        }
        if sub.activeProductIDs.contains(Config.IAP.driverHubProMonthly) {
            return .driver
        }
        if sub.activeProductIDs.contains(Config.IAP.proMonthly) ||
            sub.activeProductIDs.contains(Config.IAP.proAnnual) {
            return .ownerOperator
        }

        switch sub.entitledAccountRole {
        case .driver?:
            return .driver
        case .ownerOperator?:
            return .ownerOperator
        case .carrier?:
            return .carrier
        case .dispatcher?, nil:
            return nil
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
        let planProducts = products(for: selectedPlan)

        if planProducts.isEmpty {
            // This plan has no products configured in App Store Connect.
            // Don't show placeholders; keep the UI honest and retryable.
            errorState(message: "Plans for \(selectedPlan.displayName) are temporarily unavailable. Try again in a moment.")
        } else {
            VStack(spacing: 16) {
                planSummaryCard(selectedPlan)

                if let error = sub.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.spDanger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(planProducts, id: \.id) { product in
                    productButton(product)
                }
            }
        }
    }

    // MARK: - Plan summary

    private func planSummaryCard(_ plan: DriverHubPaywallPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(plan.displayName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.spGold)
                Spacer()
                if activeSubscribedPlan == plan {
                    Text("CURRENT")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.spSuccess)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.spSuccess.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            ForEach(plan.perks, id: \.self) { perk in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.spSuccess)
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text(perk)
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextPrimary)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
            }

            // S10 conversion copy: trucking-real value framing. Factual
            // capability statements about what the app does — no earnings
            // claims, no invented statistics.
            Text(roiLine(for: plan))
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// One grounded sentence per plan connecting price to the job it does.
    private func roiLine(for plan: DriverHubPaywallPlan) -> String {
        switch plan {
        case .driver:
            return "Every load, receipt, and settlement in one place — know your pay is right before you sign it."
        case .ownerOperator:
            return "Your paystubs, tax package, and profit numbers come from the same books — tax season stops being a shoebox of receipts."
        case .carrier:
            return "Every driver, settlement, and document for the whole operation — run the fleet from your pocket."
        }
    }

    private func products(for plan: DriverHubPaywallPlan) -> [Product] {
        sub.products
            .filter { plan.productIDs.contains($0.id) }
            .sorted { $0.price < $1.price }
    }

    // MARK: - Purchase button

    private func productButton(_ product: Product) -> some View {
        // CTA text — driven by StoreKit's introductoryOffer when present so
        // Apple's review never sees a hardcoded "free trial" claim that
        // doesn't match the actual product configuration.
        let cta = product.hasFreeTrialOffer ? "Start Free Trial" : "Subscribe"

        return VStack(spacing: 8) {
            Button {
                SPHaptics.action()
                Task { await sub.purchase(product) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DriverHubPaywallPlan.productLabel(for: product.id))
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
        let name = DriverHubPaywallPlan.productLabel(for: product.id)
        return """
        \(trial). After the trial, \(name) auto-renews at \(price) \(period) until canceled. Cancel anytime in your Apple ID Subscriptions settings at least 24 hours before the trial ends to avoid charges. Payment is charged to your Apple ID at confirmation of purchase.
        """
    }

    // MARK: - Free Local Mode escape hatch (S11)

    private var localModeEscapeHatch: some View {
        VStack(spacing: 6) {
            Button {
                SPHaptics.selection()
                showLocalModeConfirm = true
            } label: {
                Text("Or continue free on this iPhone")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spGoldText)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            Text("Free Local Mode keeps your books on this device only — no subscription needed. Your cloud account stays intact; switch back anytime in Settings.")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
        }
        .confirmationDialog(
            "Continue in Free Local Mode?",
            isPresented: $showLocalModeConfirm,
            titleVisibility: .visible
        ) {
            Button("Use Free Local Mode") {
                // Same sanctioned call WelcomeView makes. The root view
                // re-routes to local ContentView immediately; the Supabase
                // session is intentionally kept so Settings → Switch to
                // Cloud Sync returns without re-login.
                AppMode.shared.setLocal()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Local Mode stores data on this iPhone only and starts empty — it does not download your cloud data. Your cloud account and any cloud data remain safe, and you can switch back in Settings at any time.")
        }
        .accessibilityElement(children: .combine)
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
