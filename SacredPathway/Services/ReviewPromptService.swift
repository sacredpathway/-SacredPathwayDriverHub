import Foundation
import StoreKit
import SwiftUI

// =============================================================================
// ReviewPromptService — milestone-based App Store rating requests
// -----------------------------------------------------------------------------
// Phase 1 compliance addition (2026-07-04): the app previously NEVER asked for
// a rating (zero SKStoreReviewController / requestReview call sites), so only
// unhappy users self-selected into the App Store listing.
//
// Policy (deliberately conservative — the prompt must land on a moment of
// delivered value, never interrupt work):
//   • A prompt becomes eligible after the 3rd success of any one milestone
//     (e.g. the user's 3rd generated paystub — they've clearly gotten value).
//   • At most one prompt per app version, and at least 30 days apart —
//     on top of Apple's own 3-per-365-days system cap.
//   • Never in ScreenshotMode; never blocks or delays the share sheet — the
//     request fires ~0.6 s AFTER the milestone so the success UI settles first.
//
// Wiring:
//   1. `.reviewPromptHost()` is attached once at the app root
//      (SacredPathwayApp.rootContent's ZStack).
//   2. Call sites register milestones with one line, e.g.
//      `ReviewPromptService.shared.registerMilestone(.paystubGenerated)`.
//
// Adding a new milestone = add an enum case + one call site. Counters persist
// in UserDefaults under `sp.review.milestone.<raw>`.
// =============================================================================

@MainActor
final class ReviewPromptService: ObservableObject {

    static let shared = ReviewPromptService()

    enum Milestone: String {
        case paystubGenerated  = "paystub_generated"
        case cpaExportCompleted = "cpa_export_completed"
        case scanSaved         = "scan_saved"
    }

    /// Flips true when a prompt should be presented. The host modifier
    /// observes this, calls the StoreKit request, and consumes the flag.
    @Published private(set) var promptRequested = false

    // MARK: - Tuning

    private let milestoneThreshold = 3
    private let minDaysBetweenPrompts = 30

    // MARK: - Persistence keys

    private let defaults = UserDefaults.standard
    private let countKeyPrefix    = "sp.review.milestone."
    private let lastPromptDateKey = "sp.review.lastPromptDate"
    private let lastPromptVersionKey = "sp.review.lastPromptVersion"

    private init() {}

    // MARK: - Public API

    /// Record one success of `milestone`; may arm the review prompt.
    /// Safe to call from any success path — all gating lives here.
    func registerMilestone(_ milestone: Milestone) {
        let key = countKeyPrefix + milestone.rawValue
        let newCount = defaults.integer(forKey: key) + 1
        defaults.set(newCount, forKey: key)

        guard newCount >= milestoneThreshold else { return }
        armPromptIfEligible()
    }

    /// Host modifier calls this immediately before requesting the review so
    /// state can't double-fire.
    func consumePrompt() {
        promptRequested = false
    }

    // MARK: - Eligibility

    private func armPromptIfEligible() {
        guard !ScreenshotMode.isActive else { return }

        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

        // One prompt per released version.
        if defaults.string(forKey: lastPromptVersionKey) == version { return }

        // Minimum spacing between prompts.
        if let last = defaults.object(forKey: lastPromptDateKey) as? Date,
           let days = Calendar.current.dateComponents([.day], from: last, to: Date()).day,
           days < minDaysBetweenPrompts {
            return
        }

        defaults.set(Date(), forKey: lastPromptDateKey)
        defaults.set(version, forKey: lastPromptVersionKey)
        promptRequested = true
    }
}

// MARK: - Root host modifier

/// Attach exactly once near the app root. Owns the SwiftUI
/// `requestReview` environment action (iOS 16+) and fires it slightly after
/// the milestone so success UI (share sheet / preview) presents first.
struct ReviewPromptHost: ViewModifier {
    @ObservedObject private var service = ReviewPromptService.shared
    @Environment(\.requestReview) private var requestReview

    func body(content: Content) -> some View {
        content
            .onChange(of: service.promptRequested) { _, requested in
                guard requested else { return }
                service.consumePrompt()
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    requestReview()
                }
            }
    }
}

extension View {
    /// Enables milestone-driven App Store review prompts for the whole app.
    func reviewPromptHost() -> some View {
        modifier(ReviewPromptHost())
    }
}
