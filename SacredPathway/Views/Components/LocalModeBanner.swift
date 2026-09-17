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
    /// Settings → Cloud Sync flow / SIWA + Paywall.
    var onTapUpgrade: () -> Void = {}

    /// Decode-quarantine notices (Phase 2 data-loss guard). When LocalStore
    /// quarantines a corrupt file, this banner is where the user learns
    /// their data was PRESERVED — never silently wiped.
    @ObservedObject private var storeHealth = LocalStoreHealth.shared

    var body: some View {
        VStack(spacing: 0) {
            bannerRow
            if let event = storeHealth.lastQuarantine {
                quarantineNotice(event)
            }
        }
    }

    private var bannerRow: some View {
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

    /// Persistent, dismissible notice that a data file failed to load and
    /// was preserved as a quarantine copy. Plain language: what happened,
    /// that nothing was deleted, where the copy lives.
    private func quarantineNotice(_ event: LocalStoreHealth.QuarantineEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.spWarning)
                .font(.subheadline)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("A data file couldn't be read")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text("\(event.originalFileName) was preserved as \(event.quarantinedFileName) (Files app → On My iPhone → Driver Hub). Nothing was deleted. Restore a backup, or contact support with that file.")
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Button {
                storeHealth.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spTextSecondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss data file notice")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.spWarning.opacity(0.12))
        .overlay(
            Rectangle()
                .fill(Color.spWarning.opacity(0.35))
                .frame(height: 1),
            alignment: .bottom
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: the data file \(event.originalFileName) couldn't be read. A copy was preserved on this device. Nothing was deleted.")
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
