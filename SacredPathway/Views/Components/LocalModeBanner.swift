import SwiftUI

// =============================================================================
//  LocalModeBanner — Phase A placeholder
// -----------------------------------------------------------------------------
//  Slim badge intended to sit under the navigation bar on list views (Loads,
//  Brokers, Settlements, etc.) when the app is in Free Local Mode.
//
//  Phase A status: built but NOT yet wired into any list views. The plan is
//  to insert it once Repository pattern lands so the banner reflects real
//  local-vs-cloud state. For now this file exists so:
//   1. The visual treatment can be reviewed early
//   2. The "Stored on this device only" wording is locked in
//   3. Future phases plug it in without rebuilding the component
//
//  Tap behaviors are wired to callbacks supplied by the caller — defaults
//  are no-ops so the banner is safe to drop into any screen.
// =============================================================================

struct LocalModeBanner: View {

    /// Fired when the user taps "Back up" in the banner. Wire this to your
    /// Settings → Backup & Restore flow (lands in a later phase).
    var onTapBackup: () -> Void = {}

    /// Fired when the user taps "Upgrade" in the banner. Wire this to your
    /// Settings → Switch to Cloud Pro flow / SIWA + Paywall.
    var onTapUpgrade: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .foregroundStyle(Color.spGold)
                .font(.subheadline)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Free Local Mode")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text("Data saved on this device")
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
            }

            Spacer(minLength: 6)

            Button(action: onTapBackup) {
                Text("Back up")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.spCardBgLight)
                    .foregroundStyle(Color.spGold)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onTapUpgrade) {
                Text("Upgrade")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.spGold)
                    .foregroundStyle(Color.spBlack)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.spCardBg)
        .overlay(
            Rectangle()
                .fill(Color.spGold.opacity(0.25))
                .frame(height: 1),
            alignment: .bottom
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Free Local Mode. Stored on this device only. Buttons to back up or upgrade to cloud.")
    }
}

#Preview {
    VStack(spacing: 0) {
        LocalModeBanner()
        Color.spBackground
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.spBackground)
}
