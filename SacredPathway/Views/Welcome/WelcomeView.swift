import SwiftUI

// =============================================================================
//  WelcomeView — Phase A mode picker
// -----------------------------------------------------------------------------
//  Shown on first launch (AppMode.shared.mode == .notSet) before LoginView,
//  before AccessGate, before anything else. Two choices:
//
//    1. "Start Free on this iPhone"  → AppMode = .local  → ContentView
//    2. "Sign in for Cloud Pro"      → AppMode = .cloud  → LoginView path
//
//  Wording per spec:
//    • "Free Local Mode"
//    • "Stored on this device only"
//    • Explicit warning that deleting the app may delete local data unless
//      a backup is exported (the backup feature itself lands in a later
//      phase — for now we tell the user that's how it will work).
//
//  This screen is intentionally simple. It is the gate, not the funnel.
// =============================================================================

struct WelcomeView: View {

    /// Closure invoked AFTER AppMode has been written. The root view
    /// (SacredPathwayApp) re-renders automatically via @ObservedObject
    /// on AppMode, but the closure is here so the caller can hook in a
    /// one-time first-screen animation or analytics ping later.
    var onPick: (AppModeValue) -> Void = { _ in }

    @ObservedObject private var appMode = AppMode.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var showLocalConfirm = false

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 32) {

                    // ─── Header ────────────────────────────────────────
                    VStack(spacing: 14) {
                        Image("SacredPathwayLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .shadow(color: Color.spGold.opacity(0.25),
                                    radius: 12, x: 0, y: 4)
                        Text("Driver Hub")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Color.spTextPrimary)
                        Text("How would you like to use it?")
                            .font(.subheadline)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    .padding(.top, 36)

                    // ─── Free Local Mode card ──────────────────────────
                    modeCard(
                        title: "Free Local Mode",
                        subtitle: "Stored on this device only",
                        bullets: [
                            "No account required",
                            "Works offline",
                            "Manual entry for loads, brokers, contacts, expenses, settlements",
                            "Smart Scan works locally (no AI costs)",
                        ],
                        ctaTitle: "Start Free on this iPhone",
                        accent: Color.spGold
                    ) {
                        showLocalConfirm = true
                    }

                    // ─── Cloud Pro card ────────────────────────────────
                    modeCard(
                        title: "Cloud Pro",
                        subtitle: "Sign in to sync across devices",
                        bullets: [
                            "Multi-device sync (iPhone + iPad + web)",
                            "Cloud backup of every load, contact, and document",
                            "Web portal at app.sacredpathway.org",
                            "Premium AI extraction and exports",
                        ],
                        ctaTitle: "Sign in for Cloud Pro",
                        accent: Color.spGreenAccent
                    ) {
                        appMode.setCloud()
                        onPick(.cloud)
                    }

                    // ─── Footer fine print ─────────────────────────────
                    footerNote
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)
                }
                .padding(.horizontal, 18)
            }
        }
        .preferredColorScheme(colorScheme)
        .confirmationDialog(
            "Start Free Local Mode",
            isPresented: $showLocalConfirm,
            titleVisibility: .visible
        ) {
            Button("Start Free Local Mode") {
                appMode.setLocal()
                onPick(.local)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
"""
Your loads, brokers, contacts, and settlements will be stored on this iPhone only. They will not be backed up to the cloud.

If you delete Driver Hub, your local data may be lost unless you export a backup first. You can export or import a backup any time from Settings → Backup & Restore.

You can upgrade to Cloud Pro later — your local data will be uploaded to your account when you do.
"""
            )
        }
    }

    // MARK: - Card builder

    @ViewBuilder
    private func modeCard(
        title: String,
        subtitle: String,
        bullets: [String],
        ctaTitle: String,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Spacer()
            }
            Text(subtitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(bullets, id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(accent)
                            .font(.subheadline)
                            .accessibilityHidden(true)
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(Color.spTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 4)

            Button(action: action) {
                Text(ctaTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(accent)
                    .foregroundStyle(Color.spBlack)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(18)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(accent.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Footer

    private var footerNote: some View {
        VStack(spacing: 10) {
            Text("You can switch modes later in Settings.")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
            Text("Free Local Mode: deleting the app may delete your local data unless you export a backup first.")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
        }
    }
}

#Preview {
    WelcomeView()
}
