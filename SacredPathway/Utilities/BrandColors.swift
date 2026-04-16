import SwiftUI

// Sacred Pathway Brand Colors — Black, Gold & Dark Green
extension Color {
    // Primary brand colors
    static let spBlack = Color(red: 0.07, green: 0.07, blue: 0.07)         // #121212 – deep black
    static let spGold = Color(red: 0.80, green: 0.68, blue: 0.26)          // #CCAD42 – rich gold
    static let spGoldLight = Color(red: 0.90, green: 0.80, blue: 0.45)     // #E6CC73 – light gold
    static let spDarkGreen = Color(red: 0.10, green: 0.30, blue: 0.15)     // #1A4D26 – dark green
    static let spGreenAccent = Color(red: 0.18, green: 0.45, blue: 0.25)   // #2E7340 – green accent

    // Background layers
    static let spBackground = Color(red: 0.05, green: 0.05, blue: 0.05)    // #0D0D0D – true dark bg
    static let spCardBg = Color(red: 0.11, green: 0.11, blue: 0.11)        // #1C1C1C – card surface
    static let spCardBgLight = Color(red: 0.16, green: 0.16, blue: 0.16)   // #292929 – lighter card

    // Text
    static let spTextPrimary = Color(red: 0.95, green: 0.92, blue: 0.82)   // #F2EBD1 – warm white
    static let spTextSecondary = Color(red: 0.65, green: 0.62, blue: 0.55) // #A69E8C – muted

    // Status colors
    static let spSuccess = Color(red: 0.18, green: 0.65, blue: 0.35)       // Green success
    static let spWarning = Color(red: 0.85, green: 0.65, blue: 0.13)       // Amber warning
    static let spDanger = Color(red: 0.80, green: 0.20, blue: 0.20)        // Red danger
}

// Brand gradient
extension LinearGradient {
    static let goldShimmer = LinearGradient(
        colors: [Color.spGold, Color.spGoldLight, Color.spGold],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let darkGreen = LinearGradient(
        colors: [Color.spDarkGreen, Color.spGreenAccent],
        startPoint: .top,
        endPoint: .bottom
    )
}
