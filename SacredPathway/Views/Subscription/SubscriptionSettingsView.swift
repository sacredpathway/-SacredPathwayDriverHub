import SwiftUI

// =============================================================================
//  SubscriptionSettingsView — plan & billing screen in Settings
// -----------------------------------------------------------------------------
//  Shows the current plan and exposes the three required surfaces:
//    • Upgrade  → opens PaywallView
//    • Restore  → calls StoreKit AppStore.sync()
//    • Manage   → deep-links to Apple's subscription management page
// =============================================================================

struct SubscriptionSettingsView: View {
    @StateObject private var sub = SubscriptionService.shared
    @State private var showingPaywall = false

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    planCard

                    if sub.activeTier != .carrier {
                        Button {
                            showingPaywall = true
                        } label: {
                            HStack {
                                Image(systemName: "sparkles")
                                Text(sub.activeTier == .pro ? "Upgrade to Carrier" : "View Plans")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.spGold)
                            .foregroundStyle(Color.spBlack)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    Button {
                        Task { await sub.restorePurchases() }
                    } label: {
                        HStack {
                            if sub.isPurchasing {
                                ProgressView().tint(Color.spGold)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("Restore Purchases")
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.spCardBg)
                        .foregroundStyle(Color.spGold)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spGold.opacity(0.4), lineWidth: 1))
                    }
                    .disabled(sub.isPurchasing)

                    manageLink

                    if let error = sub.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color.spDanger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Subscription")
        .sheet(isPresented: $showingPaywall) { PaywallView() }
        .task { await sub.refreshEntitlements() }
    }

    // MARK: - Subviews

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CURRENT PLAN")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.spGold)
                Spacer()
            }
            Text(sub.activeTier.displayName)
                .font(.largeTitle.weight(.heavy))
                .foregroundStyle(Color.spTextPrimary)
            Text(planBlurb)
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var planBlurb: String {
        switch sub.activeTier {
        case .free:
            return "You're on the free plan. Upgrade to unlock unlimited loads, PDF paystubs, and broker intelligence."
        case .pro:
            return "Pro unlocks unlimited loads, PDF paystub exports, broker intelligence, and Smart Insights."
        case .carrier:
            return "Carrier unlocks everything — multi-driver, white-label branding, driver scorecard, and IFTA auto-tracking."
        }
    }

    private var manageLink: some View {
        Link(destination: Config.Legal.manageSubscriptionsURL) {
            HStack {
                Image(systemName: "link")
                Text("Manage subscription in App Store")
                Spacer()
                Image(systemName: "arrow.up.right")
            }
            .font(.caption)
            .foregroundStyle(Color.spTextSecondary)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
