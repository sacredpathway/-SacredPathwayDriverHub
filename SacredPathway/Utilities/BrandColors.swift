import SwiftUI
import UIKit

// =============================================================================
// Sacred Pathway Brand Colors — Black, Gold & Dark Green
// -----------------------------------------------------------------------------
// All colors are now DYNAMIC: they adapt automatically based on the active
// userInterfaceStyle (light vs. dark). Brand colors (gold, dark green, status)
// are intentionally fixed because they are the brand. Surface colors and text
// flip between light-mode and dark-mode equivalents so the whole app supports
// both modes without per-view changes.
//
// The user's appearance preference is applied via .preferredColorScheme(...) at
// the root in SacredPathwayApp; everything below adapts off that.
// =============================================================================
extension Color {

    // ---- Helpers ----
    private static func dynamic(
        light: UIColor,
        dark: UIColor
    ) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : light
        })
    }

    private static func ui(_ r: Double, _ g: Double, _ b: Double) -> UIColor {
        UIColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    // ---- Brand colors (fixed in both modes) ----
    static let spBlack       = Color(red: 0.07, green: 0.07, blue: 0.07)   // #121212 – deep black
    static let spGold        = Color(red: 0.80, green: 0.68, blue: 0.26)   // #CCAD42 – rich gold
    static let spGoldLight   = Color(red: 0.90, green: 0.80, blue: 0.45)   // #E6CC73 – light gold
    static let spDarkGreen   = Color(red: 0.10, green: 0.30, blue: 0.15)   // #1A4D26 – dark green
    static let spGreenAccent = Color(red: 0.18, green: 0.45, blue: 0.25)   // #2E7340 – green accent

    /// Gold for TEXT and informative icons (WCAG fix, Phase 1 · Task 6).
    /// `spGold` (#CCAD42) measures ~2.2:1 against white — below the 3:1
    /// large-text and 4.5:1 body-text minimums — so gold TEXT was unreadable
    /// for low-vision users in Light Mode. This token darkens to an antique
    /// gold (#8A6D1F ≈ 4.9:1 on white) in Light Mode only; Dark Mode keeps
    /// the exact brand gold (8.7:1 there — already excellent).
    /// RULE: gold as a BACKGROUND (buttons with spBlack text) stays `spGold`
    /// — that pairing passes in both modes. Gold as TEXT should migrate to
    /// this token (Dashboard done; remaining views tracked in the log).
    static let spGoldText = dynamic(
        light: ui(0.541, 0.427, 0.122),    // #8A6D1F – antique gold, AA on white
        dark:  ui(0.80, 0.68, 0.26)        // #CCAD42 – unchanged brand gold
    )

    // ---- Background layers (dynamic) ----
    /// Top-level background. Dark = near-black; Light = white.
    static let spBackground = dynamic(
        light: ui(1.00, 1.00, 1.00),       // #FFFFFF
        dark:  ui(0.05, 0.05, 0.05)        // #0D0D0D
    )

    /// Card surface. Dark = #1C1C1C; Light = #F5F5F5.
    static let spCardBg = dynamic(
        light: ui(0.96, 0.96, 0.96),       // #F5F5F5
        dark:  ui(0.11, 0.11, 0.11)        // #1C1C1C
    )

    /// Lighter card / inset. Dark = #292929; Light = #EAEAEA.
    static let spCardBgLight = dynamic(
        light: ui(0.92, 0.92, 0.92),       // #EAEAEA
        dark:  ui(0.16, 0.16, 0.16)        // #292929
    )

    // ---- Text (dynamic) ----
    /// Primary body text. Dark = warm white; Light = near-black.
    static let spTextPrimary = dynamic(
        light: ui(0.10, 0.10, 0.10),       // #1A1A1A
        dark:  ui(0.95, 0.92, 0.82)        // #F2EBD1
    )

    /// Secondary/muted text. Dark = warm gray; Light = mid-gray.
    static let spTextSecondary = dynamic(
        light: ui(0.42, 0.42, 0.42),       // #6B6B6B
        dark:  ui(0.65, 0.62, 0.55)        // #A69E8C
    )

    // ---- Status colors ----
    // Phase 1 · Task 6 (2026-07-04): success + warning are now DYNAMIC.
    // Measured against Light-Mode surfaces the old fixed values failed WCAG:
    //   • old spSuccess #2EA659 ≈ 2.9:1 on white (needs 4.5:1 body / 3:1 large)
    //   • old spWarning #D9A621 ≈ 2.1:1 on white
    // Dark-Mode values are UNCHANGED (both passed there). spDanger #CC3333
    // already measures ≈ 4.7:1 on white and stays fixed. Tinted backgrounds
    // (e.g. `.opacity(0.12)` banners) shift imperceptibly in Light Mode.
    static let spSuccess = dynamic(
        light: ui(0.122, 0.478, 0.251),    // #1F7A40 ≈ 4.9:1 on white
        dark:  ui(0.18, 0.65, 0.35)        // unchanged
    )
    static let spWarning = dynamic(
        light: ui(0.541, 0.384, 0.0),      // #8A6200 ≈ 5.0:1 on white
        dark:  ui(0.85, 0.65, 0.13)        // unchanged
    )
    static let spDanger  = Color(red: 0.80, green: 0.20, blue: 0.20)
}

// Brand gradient
@MainActor
extension LinearGradient {
    static var goldShimmer: LinearGradient {
        LinearGradient(
            colors: [Color.spGold, Color.spGoldLight, Color.spGold],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var darkGreen: LinearGradient {
        LinearGradient(
            colors: [Color.spDarkGreen, Color.spGreenAccent],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
