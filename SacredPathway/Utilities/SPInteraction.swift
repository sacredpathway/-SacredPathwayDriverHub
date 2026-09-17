import SwiftUI
import OSLog
import UIKit

// =============================================================================
// SPInteraction — the app's physical-feedback foundation (Phase 2 · Session 6)
// -----------------------------------------------------------------------------
// One file, four building blocks (single file = one project-file registration,
// same pragmatic pattern as SPDate-in-Expense.swift):
//
//   1. SPHaptics      — semantic haptic vocabulary. Before this file the app
//                       had ZERO haptic feedback (measured, 2026-07-04 audit).
//   2. Animation.sp*  — exactly two motion curves for the whole app, both
//                       Reduce-Motion aware at the call-site helpers.
//   3. SPPressStyle   — 0.97 press-scale for primary buttons/tiles.
//   4. SPSkeletonRow  — first-load placeholder rows replacing bare spinners.
//   5. SPSuccessCheck — draw-in ✓ success moment (component; first wirings
//                       land with the dashboard attention strip).
//   6. ShakeEffect    — error-banner shake for form validation failures.
//
// RULES (enforced by review, documented here):
//   • Haptics accompany STATE CHANGES the user caused — never scrolling,
//     never passive updates. One haptic per user action, max.
//   • All motion routes through .spSpring/.spQuick — no ad-hoc curves.
//   • Reduce Motion: scale/offset effects collapse to opacity or nothing;
//     haptics are unaffected (they're an accessibility POSITIVE for
//     low-vision users — do not gate them on Reduce Motion).
// =============================================================================

// MARK: - 1. Haptics

@MainActor
enum SPHaptics {

    /// Light tick — chip/segment selection, field-landed moments.
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Medium impact — a primary action was accepted (button press that
    /// starts work, e.g. generate, settle).
    static func action() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Success notification — money moments: saved, generated, backed up.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Warning — destructive confirms (delete swipe, remove receipt).
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// Error — validation/save failures, paired with the ShakeEffect.
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - Centralized diagnostic policy

/// Existing call sites historically used `print` for verbose diagnostics,
/// including model payloads. Shadowing Swift's global function here keeps
/// those diagnostics available to developers while compiling all output out
/// of production builds. New operational logging should use `SPLogger` and
/// must never include user, financial, document, or location values.
func print(
    _ items: Any...,
    separator: String = " ",
    terminator: String = "\n"
) {
#if DEBUG
    Swift.print(items.map(String.init(describing:)).joined(separator: separator),
                terminator: terminator)
#endif
}

enum SPLogger {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SacredPathway",
        category: "App"
    )

    static func operationalError(_ message: StaticString) {
        logger.error("\(message, privacy: .public)")
    }
}

// MARK: - 2. Motion tokens

extension Animation {
    /// The app's standard spring — screen-level and card-level motion.
    static let spSpring = Animation.spring(response: 0.35, dampingFraction: 0.8)
    /// Snappier spring — presses, chips, small state flips.
    static let spQuick  = Animation.spring(response: 0.25, dampingFraction: 0.85)
}

// MARK: - 3. Press style

/// 0.97 press-scale + slight dim for primary buttons and tappable tiles.
/// Under Reduce Motion the scale is dropped and only the dim remains.
struct SPPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spQuick, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SPPressStyle {
    /// `.buttonStyle(.spPress)`
    static var spPress: SPPressStyle { SPPressStyle() }
}

// MARK: - 4. Skeleton rows

/// First-load placeholder row: icon circle + two text bars, shimmering.
/// Use N of these (default 5) in place of a centered ProgressView so the
/// screen keeps its final shape while loading. Shimmer freezes under
/// Reduce Motion. Sizes are relative (scaledMetric) so Dynamic Type users
/// get proportional skeletons.
struct SPSkeletonRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var barHeight: CGFloat = 12
    @ScaledMetric(relativeTo: .subheadline) private var iconSide: CGFloat = 42
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.spCardBgLight)
                .frame(width: iconSide, height: iconSide)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.spCardBgLight)
                    .frame(width: 140, height: barHeight)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.spCardBgLight)
                    .frame(width: 90, height: barHeight * 0.8)
            }
            Spacer()
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.spCardBgLight)
                .frame(width: 64, height: barHeight)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .opacity(pulse ? 0.55 : 1.0)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityHidden(true)   // VoiceOver: the list announces loading once
    }
}

/// Convenience column of skeleton rows with a single VoiceOver announcement.
struct SPSkeletonList: View {
    var rows: Int = 5

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { _ in
                SPSkeletonRow()
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

// MARK: - 5. Success check

/// Draw-in checkmark used for silent-success moments (no sheet/navigation
/// already providing feedback). Presents ~0.9 s, fires the success haptic,
/// then calls `onFinished`. Under Reduce Motion the check appears without
/// the draw animation.
struct SPSuccessCheck: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var message: String = "Done"
    var onFinished: () -> Void = {}

    @State private var drawn = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.spCardBg)
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.spSuccess)
                    .scaleEffect(drawn || reduceMotion ? 1 : 0.3)
                    .opacity(drawn || reduceMotion ? 1 : 0)
            }
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .onAppear {
            SPHaptics.success()
            withAnimation(.spSpring) { drawn = true }
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                onFinished()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

// MARK: - 6. Error shake

/// Horizontal shake for error banners/fields. Attach with
/// `.modifier(ShakeEffect(trigger: someCounter))` and increment the trigger
/// when the error fires. No-op under Reduce Motion.
struct ShakeEffect: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var trigger: Int

    func body(content: Content) -> some View {
        content
            .offset(x: 0)
            .modifier(ShakeGeometry(animatableData: reduceMotion ? 0 : CGFloat(trigger)))
            .animation(reduceMotion ? nil : .spQuick, value: trigger)
    }

    private struct ShakeGeometry: GeometryEffect {
        var amplitude: CGFloat = 6
        var shakes: CGFloat = 3
        var animatableData: CGFloat

        func effectValue(size: CGSize) -> ProjectionTransform {
            ProjectionTransform(CGAffineTransform(
                translationX: amplitude * sin(animatableData * .pi * shakes * 2),
                y: 0
            ))
        }
    }
}
