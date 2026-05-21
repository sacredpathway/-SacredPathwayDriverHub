import Foundation
import StoreKit
import os.log

// =============================================================================
//  SubscriptionService — production StoreKit 2 implementation
// -----------------------------------------------------------------------------
//  Single source of truth for:
//   • available products (loaded live from App Store Connect)
//   • purchase + restore flow
//   • current entitlement (active tier) — derived from Transaction.currentEntitlements
//   • background listener for renewals / refunds / family sharing changes
//
//  Entitlement rules:
//    • Carrier > Pro > Free
//    • Carrier unlocks every Pro feature AND every Carrier-only feature.
//
//  All mutable state is @Published on the main actor. Views observe this
//  service; they never read entitlements from any other source.
// =============================================================================

/// Plan tier. Ordered deliberately so `.carrier` is the highest.
enum SubscriptionTier: String, CaseIterable, Identifiable, Comparable {
    case free
    case pro
    case carrier

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .free:    return "Free"
        case .pro:     return "Pro"
        case .carrier: return "Carrier"
        }
    }

    private var rank: Int {
        switch self { case .free: 0; case .pro: 1; case .carrier: 2 }
    }

    static func < (lhs: SubscriptionTier, rhs: SubscriptionTier) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Public access level the UI reads to choose between "Free Basic" copy,
/// "You're subscribed" copy, and feature gating. Centralizes the rule
/// "no active paid entitlement = Free Basic" so individual views never
/// need to interpret StoreKit transactions themselves.
///
/// Mapping (from `SubscriptionService.activeTier`):
///   .free    → .freeBasic   (no paid entitlement OR unrecognized product)
///   .pro     → .pro         (Pro Monthly, Pro Annual, or Driver Hub Pro Monthly)
///   .carrier → .carrier     (Carrier Monthly or Carrier Annual)
///
/// Important: Free Basic is an in-app concept. There is NO $0 product in
/// App Store Connect — the user just doesn't have an active paid receipt.
/// Apple's $0-subscription policies don't apply because nothing is being
/// purchased.
enum AccessLevel: String, CaseIterable, Identifiable, Comparable {
    case freeBasic
    case pro
    case carrier

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .freeBasic: return "Free Basic"
        case .pro:       return "Pro"
        case .carrier:   return "Carrier"
        }
    }

    /// True only for paid tiers. The paywall uses this to flip the header
    /// from "upgrade" copy to "you're subscribed" copy.
    var isPaid: Bool { self != .freeBasic }

    private var rank: Int {
        switch self { case .freeBasic: 0; case .pro: 1; case .carrier: 2 }
    }

    static func < (lhs: AccessLevel, rhs: AccessLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Loading state for the product list. Drives the paywall UI.
enum ProductLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
final class SubscriptionService: ObservableObject {
    static let shared = SubscriptionService()

    // MARK: - Published state

    @Published private(set) var products: [Product] = []
    @Published private(set) var activeTier: SubscriptionTier = .free
    @Published private(set) var loadState: ProductLoadState = .idle
    @Published private(set) var isPurchasing: Bool = false
    @Published var lastError: String?

    /// Product IDs that StoreKit could not resolve on the most recent fetch.
    /// Surfaced for diagnostics — when Apple review reports
    /// "products are unavailable" this set tells you exactly which IDs the
    /// device couldn't load (almost always an App Store Connect status
    /// problem: Missing Metadata, not attached to the build's version, or
    /// Paid Apps Agreement not yet active).
    @Published private(set) var missingProductIDs: Set<String> = []

    // MARK: - Internal

    private static let log = Logger(
        subsystem: "com.sacredpathway.driverhub",
        category: "SubscriptionService"
    )

    private var updatesTask: Task<Void, Never>?

    private init() {
        // Attach the transaction-updates listener immediately so renewals,
        // refunds, and family-sharing changes land in `activeTier` without
        // waiting for an app relaunch.
        updatesTask = Task { [weak self] in
            await self?.listenForTransactions()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Lifecycle hooks

    /// Call from `SacredPathwayApp` on launch (and after sign-in) so products
    /// are available the first time a user taps "Upgrade" and so entitlements
    /// reflect current reality.
    func refreshOnAppLaunch() async {
        await loadProducts()
        await refreshEntitlements()
    }

    // MARK: - Product loading

    func loadProducts() async {
        loadState = .loading
        lastError = nil
        do {
            let requestedIDs = Config.IAP.all
            let loaded = try await Product.products(for: requestedIDs)

            // Track which IDs StoreKit couldn't resolve so we can degrade
            // gracefully (show what loaded) instead of failing the whole
            // paywall. `Product.products(for:)` silently drops invalid /
            // missing-metadata IDs, so subtraction is the only way to know.
            let loadedIDs = Set(loaded.map(\.id))
            let missing = requestedIDs.subtracting(loadedIDs)
            self.missingProductIDs = missing

            if !missing.isEmpty {
                Self.log.warning("StoreKit returned a partial product list. Missing IDs: \(missing.sorted().joined(separator: ", "), privacy: .public)")
            }

            // Sort deterministically so the picker order is stable across
            // launches: by tier first, then price ascending.
            self.products = loaded.sorted { lhs, rhs in
                let lt = tier(for: lhs.id)
                let rt = tier(for: rhs.id)
                if lt != rt { return lt < rt }
                return lhs.price < rhs.price
            }

            if loaded.isEmpty {
                // Don't tell the user "the app is broken" — point them at
                // the real cause. Apple reviewers reading this string also
                // see an actionable retry path instead of a dead-end.
                self.loadState = .failed(
                    "Subscription plans aren't available from the App Store right now. Check your connection and tap Try again in a moment."
                )
                Self.log.error("StoreKit returned zero products for IDs: \(requestedIDs.sorted().joined(separator: ", "), privacy: .public). Verify products are attached to this app version in App Store Connect and the Paid Apps Agreement is active.")
            } else {
                self.loadState = .loaded
            }
        } catch {
            self.products = []
            self.missingProductIDs = Config.IAP.all
            self.loadState = .failed(error.localizedDescription)
            Self.log.error("Product.products(for:) threw: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Purchase

    /// Kick off a real StoreKit 2 purchase. Updates `activeTier` on success.
    /// - Returns: `true` on a verified successful purchase, `false` for user
    ///   cancel / pending / unverified.
    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        isPurchasing = true
        lastError = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshEntitlements()
                    return true
                case .unverified(_, let error):
                    lastError = "Purchase could not be verified: \(error.localizedDescription)"
                    return false
                }
            case .userCancelled:
                return false
            case .pending:
                lastError = "Purchase is pending approval (e.g. Ask to Buy). You'll see the update once it's approved."
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Sync with the App Store — used by the "Restore Purchases" button.
    /// After sync, re-walk current entitlements.
    func restorePurchases() async {
        lastError = nil
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            lastError = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Entitlement evaluation

    /// Walk `Transaction.currentEntitlements` and take the highest active tier.
    /// Expired or revoked entitlements are skipped.
    func refreshEntitlements() async {
        #if DEBUG
        if DemoMode.unlockAllFeatures {
            self.activeTier = .carrier
            return
        }
        #endif

        var best: SubscriptionTier = .free

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }

            if let revocation = transaction.revocationDate, revocation <= Date() { continue }
            if let expiry = transaction.expirationDate, expiry <= Date() { continue }

            let t = tier(for: transaction.productID)
            if t > best { best = t }
        }

        self.activeTier = best
    }

    /// Listen forever for Transaction.updates — renewals, refunds, family
    /// sharing, cross-device restores.
    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if case .verified(let transaction) = result {
                await transaction.finish()
                await refreshEntitlements()
            }
        }
    }

    // MARK: - Helpers

    /// Resolve a product ID to its tier. Unknown IDs map to `.free`.
    func tier(for productID: String) -> SubscriptionTier {
        switch productID {
        case Config.IAP.proMonthly,
             Config.IAP.proAnnual,
             Config.IAP.driverHubProMonthly:
            return .pro
        case Config.IAP.carrierMonthly, Config.IAP.carrierAnnual:
            return .carrier
        default:
            return .free
        }
    }

    /// Products that belong to a given tier — used by the paywall to split
    /// the product list into Pro vs Carrier columns.
    func products(for tier: SubscriptionTier) -> [Product] {
        products.filter { self.tier(for: $0.id) == tier }
    }

    // MARK: - Entitlement API (single source of truth)

    /// Public access level for the UI to read. Maps `activeTier` to the
    /// `AccessLevel` vocabulary (`.freeBasic` instead of `.free`) so paywall
    /// + Free Basic logic has one canonical thing to switch on.
    ///
    /// Free-only launch override: if the master subscription flag is off,
    /// every user is reported as Carrier so all features unlock (the dev /
    /// pre-launch state).
    var accessLevel: AccessLevel {
        #if DEBUG
        if DemoMode.unlockAllFeatures { return .carrier }
        #endif
        if !FeatureFlags.subscriptionsEnabled { return .carrier }
        switch activeTier {
        case .free:    return .freeBasic
        case .pro:     return .pro
        case .carrier: return .carrier
        }
    }

    /// Does the user have access to Pro features? (true if active tier is Pro OR Carrier)
    var hasProAccess: Bool {
        #if DEBUG
        if DemoMode.unlockAllFeatures { return true }
        #endif
        // Free-only launch: no paywalls, every feature unlocked.
        if !FeatureFlags.subscriptionsEnabled { return true }
        return activeTier >= .pro
    }

    /// Does the user have access to Carrier features?
    var hasCarrierAccess: Bool {
        #if DEBUG
        if DemoMode.unlockAllFeatures { return true }
        #endif
        // Free-only launch: no paywalls, every feature unlocked.
        if !FeatureFlags.subscriptionsEnabled { return true }
        return activeTier >= .carrier
    }

    /// Granular entitlement check used by every feature gate in the UI.
    /// Carrier inherits everything Pro unlocks.
    func isEntitled(_ feature: Feature) -> Bool {
        #if DEBUG
        if DemoMode.unlockAllFeatures { return true }
        #endif

        // Free-only launch: every feature unlocked, no paywall ever shows.
        // Flip FeatureFlags.subscriptionsEnabled to true in v1.1 once the
        // four ASC IAPs (Pro/Carrier x Monthly/Annual) are Ready to Submit.
        if !FeatureFlags.subscriptionsEnabled { return true }

        switch feature {
        case .aiScan, .pdfExport, .brokerIntelligence, .smartInsights, .cpaTaxPackage:
            return hasProAccess
        case .multiDriver, .whiteLabelBranding, .driverScorecard, .iftaAutoTracking:
            return hasCarrierAccess
        case .manualPaystub, .basicDashboard:
            return true
        }
    }

    /// The minimum tier that unlocks a given feature.
    func requiredTier(for feature: Feature) -> SubscriptionTier {
        switch feature {
        case .aiScan, .pdfExport, .brokerIntelligence, .smartInsights, .cpaTaxPackage:
            return .pro
        case .multiDriver, .whiteLabelBranding, .driverScorecard, .iftaAutoTracking:
            return .carrier
        case .manualPaystub, .basicDashboard:
            return .free
        }
    }

    enum Feature {
        case aiScan
        case pdfExport
        case brokerIntelligence
        case smartInsights
        case multiDriver
        case whiteLabelBranding
        case driverScorecard
        case iftaAutoTracking
        case manualPaystub
        case basicDashboard
        /// CPA Ready Tax Package — Pro-tier accountant-grade export feature.
        /// Free-tier users see the row with a lock and a "Upgrade to Pro" CTA
        /// that opens the paywall instead of the export screen.
        case cpaTaxPackage
    }
}

// MARK: - Product display helpers

extension Product {
    /// Human-readable billing period, e.g. "per month", "per year". Falls
    /// back to an empty string for non-subscription products.
    var billingPeriodText: String {
        guard let period = subscription?.subscriptionPeriod else { return "" }
        switch period.unit {
        case .day:   return period.value == 1 ? "per day"   : "every \(period.value) days"
        case .week:  return period.value == 1 ? "per week"  : "every \(period.value) weeks"
        case .month: return period.value == 1 ? "per month" : "every \(period.value) months"
        case .year:  return period.value == 1 ? "per year"  : "every \(period.value) years"
        @unknown default: return ""
        }
    }

    /// Free-trial summary string driven by StoreKit's introductoryOffer.
    /// Returns e.g. "7 days free, then $29.99/month" when the App Store Connect
    /// product has a free intro offer attached; `nil` otherwise. Apple updates
    /// this server-side, so the paywall reflects the true offer without an
    /// app release.
    var freeTrialSummary: String? {
        guard let offer = subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        let period = offer.period
        let unitText: String
        switch period.unit {
        case .day:   unitText = period.value == 1 ? "day"   : "days"
        case .week:  unitText = period.value == 1 ? "week"  : "weeks"
        case .month: unitText = period.value == 1 ? "month" : "months"
        case .year:  unitText = period.value == 1 ? "year"  : "years"
        @unknown default: unitText = "days"
        }
        // Translate weeks into days for trucker-friendly phrasing ("7 days free"
        // reads cleaner than "1 week free" in Apple-required disclosures).
        let lengthText: String
        if period.unit == .week {
            let days = period.value * 7
            lengthText = "\(days) days"
        } else {
            lengthText = "\(period.value) \(unitText)"
        }
        let priceText = "\(displayPrice)\(billingPeriodText.isEmpty ? "" : "/\(billingPeriodText.replacingOccurrences(of: "per ", with: ""))")"
        return "\(lengthText) free, then \(priceText)"
    }

    /// True iff the product has an active free-trial intro offer in
    /// App Store Connect. Drives the "Start Free Trial" CTA wording.
    var hasFreeTrialOffer: Bool {
        subscription?.introductoryOffer?.paymentMode == .freeTrial
    }
}
