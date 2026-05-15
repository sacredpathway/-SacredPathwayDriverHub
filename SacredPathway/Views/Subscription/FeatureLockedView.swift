import SwiftUI

// =============================================================================
//  FeatureLockedView — the "this feature requires Pro/Carrier" overlay
// -----------------------------------------------------------------------------
//  Shown when the user reaches a gated feature on a lower tier. Presents the
//  feature name, the required tier, and a CTA that opens the real paywall.
//
//  Two shapes are exported:
//    • FeatureLockedView(feature:description:requiredTier:icon:) — used
//      directly by any view that wants a big "locked" state.
//    • .featureGate(_:name:description:requiredTier:icon:) — modifier for
//      compact one-line gating: the content renders if entitled, otherwise
//      the locked overlay takes over.
// =============================================================================

struct FeatureLockedView: View {
    let feature: String
    let description: String
    let requiredTier: SubscriptionTier
    let icon: String

    @State private var showingPaywall = false

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.spGold.opacity(0.1))
                        .frame(width: 100, height: 100)
                    Image(systemName: icon)
                        .font(.system(size: 40))
                        .foregroundStyle(Color.spGold)
                }

                Text(feature)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.spTextPrimary)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.caption)
                    Text("Requires \(requiredTier.displayName) plan")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.spGold)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.spGold.opacity(0.12))
                .clipShape(Capsule())

                Button {
                    showingPaywall = true
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        Text("Upgrade to \(requiredTier.displayName)")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.spGold)
                    .foregroundStyle(Color.spBlack)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 32)

                Spacer()
                Spacer()
            }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
    }
}

/// View modifier that conditionally shows a locked overlay.
/// Usage: `.featureGate(.pdfExport, name: "PDF Export", description: ..., requiredTier: .pro)`
///
/// Internally observes `SubscriptionService.shared` so the gated content
/// flips between locked and unlocked the instant a purchase or restore
/// updates `activeTier` — no view rebuild, no app relaunch required.
struct FeatureGateModifier: ViewModifier {
    let feature: SubscriptionService.Feature
    let featureName: String
    let description: String
    let requiredTier: SubscriptionTier
    let icon: String

    @ObservedObject private var subscriptions = SubscriptionService.shared

    func body(content: Content) -> some View {
        if subscriptions.isEntitled(feature) {
            content
        } else {
            FeatureLockedView(
                feature: featureName,
                description: description,
                requiredTier: requiredTier,
                icon: icon
            )
        }
    }
}

extension View {
    /// Gate a view behind a subscription feature check.
    func featureGate(
        _ feature: SubscriptionService.Feature,
        name: String,
        description: String,
        requiredTier: SubscriptionTier,
        icon: String = "lock.fill"
    ) -> some View {
        modifier(FeatureGateModifier(
            feature: feature,
            featureName: name,
            description: description,
            requiredTier: requiredTier,
            icon: icon
        ))
    }
}
