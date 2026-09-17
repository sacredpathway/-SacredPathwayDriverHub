import SwiftUI

// =============================================================================
//  SubscriptionSettingsView — plan & billing screen in Settings
// -----------------------------------------------------------------------------
//  Shows the current plan and exposes the three required surfaces:
//    • View Plans → opens PaywallView
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
                                Text("View Plans")
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
            Text(sub.activePlanRoleName)
                .font(.largeTitle.weight(.heavy))
                .foregroundStyle(Color.spTextPrimary)
            if let price = sub.activeTier.monthlyPriceText {
                Text(price)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spGold)
            }
            Text("Feature access is locked by active subscription")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.spGold)
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
        switch sub.entitledAccountRole {
        case .driver?:
            return "Driver unlocks load tracking, rate con uploads, documents, settlements, expenses, fuel, weekly/monthly statistics, basic reports, and dispatcher communication."
        case .ownerOperator?:
            return "Owner Operator includes Driver and adds CPA-ready export, tax reports, mileage reports, profit and loss, business analytics, revenue analytics, financial reporting, and advanced reports."
        case .carrier?:
            return "Carrier includes Driver and Owner Operator and adds carrier dashboards, driver and dispatcher management, fleet dashboards, fleet analytics, team messaging, company management, fleet reporting, and approvals."
        case .dispatcher?, nil:
            return "No paid entitlement is active. Choose Driver, Owner Operator, or Carrier to unlock the app."
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
