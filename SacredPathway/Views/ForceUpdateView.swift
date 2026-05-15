import SwiftUI

// =============================================================================
// ForceUpdateView
// -----------------------------------------------------------------------------
// Full-screen, non-dismissible blocking screen shown when
// `ForceUpdateService.shouldForceUpdate == true`.
//
// Layout requirements (per spec):
//   • App icon centered perfectly with equal vertical breathing room.
//   • Title + update message immediately under the icon.
//   • "Update App" CTA pinned to the bottom safe area.
//   • Responsive across iPhone + iPad.
//   • No back gesture, no swipe-down dismissal.
//
// Branding: black/gold/dark-green Sacred Pathway palette via BrandColors.
// =============================================================================

struct ForceUpdateView: View {
    @ObservedObject private var service = ForceUpdateService.shared

    // Detect Dynamic Type so the icon stays "visually centered" — the icon
    // size scales modestly with text size, never leaving the safe area.
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 132

    var body: some View {
        GeometryReader { geo in
            let isPad = geo.size.width >= 600

            ZStack {
                // Brand-aware backdrop. Adapts to dark/light mode.
                Color.spBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // ─── Top spacer takes equal share with the bottom spacer
                    //     (1 fr each) so the icon block lands in the optical
                    //     center even when text wraps to multiple lines. ───
                    Spacer(minLength: 0)

                    iconAndCopy(isPad: isPad)
                        .padding(.horizontal, isPad ? 80 : 28)
                        .frame(maxWidth: isPad ? 560 : .infinity)

                    Spacer(minLength: 0)

                    VStack(spacing: 10) {
                        updateButton(isPad: isPad)

                        // Lightweight retry path. After tapping "Update App"
                        // and updating from the App Store, iOS terminates
                        // the app and a relaunch will re-fetch — so this
                        // button is mainly for users who hit a transient
                        // network error and want to try again, OR who
                        // updated a different app and bounced back.
                        Button {
                            Task { await service.checkForUpdate() }
                        } label: {
                            HStack(spacing: 6) {
                                if service.isChecking {
                                    ProgressView().tint(Color.spGold).scaleEffect(0.7)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(service.isChecking ? "Rechecking…" : "Recheck")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(Color.spGoldLight)
                            .padding(.vertical, 8)
                        }
                        .disabled(service.isChecking)
                    }
                    .padding(.horizontal, isPad ? 80 : 24)
                    .padding(.bottom, isPad ? 36 : 20)
                    .frame(maxWidth: isPad ? 560 : .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Hard-block any chance of dismissal.
        .interactiveDismissDisabled(true)
        .navigationBarBackButtonHidden(true)
        .statusBarHidden(false)
    }

    // MARK: - Icon + copy block

    @ViewBuilder
    private func iconAndCopy(isPad: Bool) -> some View {
        VStack(spacing: isPad ? 28 : 22) {
            // App icon — perfectly centered, fixed-aspect rounded square.
            appIcon
                .frame(
                    width: isPad ? max(iconSize, 168) : iconSize,
                    height: isPad ? max(iconSize, 168) : iconSize
                )
                .accessibilityHidden(true)

            // Title.
            Text("Update Required")
                .font(.system(
                    size: isPad ? 34 : 28,
                    weight: .bold,
                    design: .rounded
                ))
                .foregroundStyle(Color.spTextPrimary)
                .multilineTextAlignment(.center)

            // Optional version line, e.g. "Version 1.0.3 → 1.1.0".
            if let line = service.versionLine {
                Text(line)
                    .font(.system(size: isPad ? 17 : 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.spGold)
                    .multilineTextAlignment(.center)
            }

            // Update message body.
            Text(service.updateMessage)
                .font(.system(size: isPad ? 18 : 16, weight: .regular))
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Icon view

    private var appIcon: some View {
        // Prefer the in-bundle marketing icon. Fall back to the existing
        // SacredPathwayLogo asset (already shipped) if missing.
        Group {
            if UIImage(named: "AppIconMarketing") != nil {
                Image("AppIconMarketing")
                    .resizable()
                    .scaledToFit()
            } else {
                Image("SacredPathwayLogo")
                    .resizable()
                    .scaledToFit()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.spGold.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 18, x: 0, y: 10)
    }

    // MARK: - CTA

    @ViewBuilder
    private func updateButton(isPad: Bool) -> some View {
        Button {
            service.openAppStore()
        } label: {
            Text("Update Now")
                .font(.system(size: isPad ? 19 : 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.spBlack)
                .frame(maxWidth: .infinity)
                .frame(height: isPad ? 58 : 54)
                .background(
                    LinearGradient.goldShimmer
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.spGold.opacity(0.6), lineWidth: 1)
                )
                .shadow(color: Color.spGold.opacity(0.25), radius: 14, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Update Now")
        .accessibilityHint("Opens the App Store to install the latest Sacred Pathway Driver Hub.")
    }
}

#if DEBUG
#Preview("iPhone — Forced") {
    ForceUpdateView()
        .preferredColorScheme(.dark)
        .onAppear { ForceUpdateService.shared.forceShowForTesting() }
}

#Preview("iPad — Forced", traits: .landscapeLeft) {
    ForceUpdateView()
        .preferredColorScheme(.light)
        .onAppear { ForceUpdateService.shared.forceShowForTesting() }
}
#endif
