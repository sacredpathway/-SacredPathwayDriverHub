import Foundation
import SwiftUI

/// Centralized source of truth for the user's pay-week start day.
///
/// Every screen that filters by "this week" — Dashboard, Loads list,
/// Smart Insights, and any settlement defaults — uses
/// `PayWeekService.shared.weekInterval(for:)` so that changing the start
/// day in Settings → Pay Week immediately reshapes every weekly total.
///
/// Default: Monday (Calendar.Component.weekday == 2). This matches the
/// ISO-8601 week and is what the app shipped with prior to the user
/// preference. Persisted in UserDefaults so the choice survives launches.
@MainActor
final class PayWeekService: ObservableObject {
    static let shared = PayWeekService()

    private let key = "sp.payweek.firstWeekday.v1"

    /// 1 = Sunday, 2 = Monday, ..., 7 = Saturday. Matches
    /// `Calendar.firstWeekday` semantics.
    @Published var firstWeekday: Int {
        didSet {
            UserDefaults.standard.set(firstWeekday, forKey: key)
            // Notify the dashboard / loads list / insights to refresh.
            NotificationCenter.default.post(
                name: PayWeekService.didChangeNotification, object: nil)
        }
    }

    /// Broadcast whenever the user picks a new start day. Listeners that
    /// can't `@ObservedObject` (e.g. computed properties on a struct view)
    /// can pick this up to invalidate their cached week.
    static let didChangeNotification = Notification.Name("PayWeekService.didChange")

    private init() {
        let stored = UserDefaults.standard.integer(forKey: key)
        // UserDefaults returns 0 when no value is set — fall back to Monday.
        self.firstWeekday = (1...7).contains(stored) ? stored : 2
    }

    // MARK: - Week math

    /// The configured weekday's display name (e.g. "Monday").
    var displayName: String { PayWeekService.dayName(for: firstWeekday) }

    /// Day name for any weekday 1...7.
    static func dayName(for weekday: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        // weekdaySymbols is 0-indexed Sunday=0; weekday is 1-indexed Sunday=1.
        let idx = max(0, min(6, weekday - 1))
        return formatter.weekdaySymbols[idx]
    }

    /// The (start, end) interval [start, end) for the pay-week containing
    /// `date`. `start` lands at 00:00 on the user's configured start day;
    /// `end` lands at 00:00 seven days later.
    func weekInterval(for date: Date = Date()) -> DateInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = firstWeekday
        cal.timeZone = .current

        // dateInterval(of:.weekOfYear) honors `firstWeekday`, so changing the
        // configured start day instantly re-aligns the bucket boundaries.
        if let interval = cal.dateInterval(of: .weekOfYear, for: date) {
            return interval
        }
        // Defensive fallback — should never fire.
        let start = cal.startOfDay(for: date)
        return DateInterval(start: start, duration: 7 * 24 * 60 * 60)
    }

    /// Convenience predicate: is `date` inside the pay-week containing `now`?
    func isInCurrentPayWeek(_ date: Date, now: Date = Date()) -> Bool {
        let interval = weekInterval(for: now)
        return date >= interval.start && date < interval.end
    }

    /// End-of-week display (e.g. "Sunday" when start = Monday).
    var endDayDisplayName: String {
        let endIdx = ((firstWeekday - 1 + 6) % 7) + 1
        return PayWeekService.dayName(for: endIdx)
    }
}
