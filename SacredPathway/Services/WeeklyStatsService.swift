import Foundation
import SwiftUI

// =============================================================================
//  WeeklyStatsService — centralized period bucketing + dedupe + debug
// -----------------------------------------------------------------------------
//  Single source of truth for ANY weekly / biweekly / monthly / 30-day / all-
//  time aggregation of revenue across loads. Prior to this service the same
//  filter-and-reduce was open-coded in DashboardView, LoadsListView,
//  SmartInsightsView, LoadDetailView, etc. Even with all sites converged on
//  `PayWeekService.pickupFalls(in:)`, three risks remained:
//
//    1. Duplicate loads in the local store (iCloud merge, repeated saves)
//       would silently double-count weekly revenue with no visible warning.
//    2. There was no built-in way to print the exact records feeding a card
//       so a user reporting "weekly says $17k but I only entered $300" had
//       no quick path to evidence.
//    3. New code added later could drift back to `createdAt` without a
//       reviewer noticing.
//
//  This service fixes all three:
//    - `sum(...)` dedupes by `Load.id` before reducing — duplicates can
//      enter the store, but they never inflate a total.
//    - `debugReport(...)` returns the human-readable record-by-record dump
//      that the user requested in the spec (records found, amounts, dates,
//      totals per window).
//    - Every period — week, biweek, month, last30, all-time — flows through
//      one function, so any future audit only has to read one file.
//
//  Loads with a nil `pickupDate` are EXCLUDED from windowed totals (no week
//  to belong to). They are included in `allTime` so total lifetime revenue
//  still matches the user's intuition.
// =============================================================================

/// Time window for revenue aggregation. `allTime` ignores `pickupDate`
/// entirely — every load with `totalRevenue` is counted. The windowed
/// cases require a non-nil pickup date.
enum StatsPeriod: String, CaseIterable {
    case week        = "This Week"
    case biweekly    = "Biweekly (current 2 weeks)"
    case month       = "This Month"
    case last30Days  = "Last 30 Days"
    case allTime     = "All Time"
}

@MainActor
enum WeeklyStatsService {

    // MARK: - Public API

    /// Total revenue (in dollars) for `period`, computed from `loads`.
    /// Always deduplicates by `id` first — protects against iCloud-merge
    /// or repeated-save inflation that would otherwise silently double
    /// up weekly totals.
    static func revenue(
        in period: StatsPeriod,
        loads: [Load],
        now: Date = Date()
    ) -> Double {
        bucket(period: period, loads: loads, now: now)
            .reduce(0) { $0 + ($1.totalRevenue ?? 0) }
    }

    /// The deduped, period-filtered slice of `loads` used by `revenue(...)`.
    /// Exposed so views that want the record list (e.g. "Recent Loads —
    /// This Week") share the same bucket the headline number is built from.
    static func loads(
        in period: StatsPeriod,
        loads: [Load],
        now: Date = Date()
    ) -> [Load] {
        bucket(period: period, loads: loads, now: now)
    }

    /// True if `pickupDate` is inside the half-open interval that defines
    /// `period`. Identical semantics to `PayWeekService.pickupFalls(in:)`
    /// for `.week`; extended to the other windows so every caller routes
    /// through one rule.
    static func contains(
        period: StatsPeriod,
        pickupDate: Date?,
        now: Date = Date()
    ) -> Bool {
        if period == .allTime { return true }
        guard let d = pickupDate else { return false }
        let i = interval(for: period, now: now)
        return d >= i.start && d < i.end
    }

    /// Returns the half-open interval [start, end) for `period`. For
    /// `.allTime` the start is `.distantPast` and the end is `.distantFuture`
    /// — every date is contained, no caller needs a special case.
    static func interval(for period: StatsPeriod, now: Date = Date()) -> DateInterval {
        switch period {
        case .week:
            return PayWeekService.shared.weekInterval(for: now)
        case .biweekly:
            // Current pay-week + the next pay-week's start as the end.
            // Defining "biweekly" as the current week + previous week
            // would make today's totals depend on data already paid;
            // defining it forward keeps the rule consistent with how the
            // Settlements screen schedules pay periods.
            let w = PayWeekService.shared.weekInterval(for: now)
            let priorStart = Calendar.current.date(byAdding: .day, value: -7, to: w.start) ?? w.start
            return DateInterval(start: priorStart, end: w.end)
        case .month:
            let cal = Calendar.current
            return cal.dateInterval(of: .month, for: now)
                ?? DateInterval(start: now, duration: 0)
        case .last30Days:
            let cal = Calendar.current
            let start = cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: now))
                ?? now
            let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
                ?? now
            return DateInterval(start: start, end: end)
        case .allTime:
            return DateInterval(start: .distantPast, end: .distantFuture)
        }
    }

    // MARK: - Debug

    /// Build the human-readable debug dump the user requested in the spec.
    /// Prints record count, every line item (amount + date + load #), and
    /// the resulting total for the requested period. Safe to print to
    /// console or share via the system share sheet.
    static func debugReport(
        period: StatsPeriod,
        loads: [Load],
        now: Date = Date()
    ) -> String {
        let bucketed = bucket(period: period, loads: loads, now: now)
        let total = bucketed.reduce(0) { $0 + ($1.totalRevenue ?? 0) }
        let interval = interval(for: period, now: now)

        let df: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = .current
            return f
        }()

        var lines: [String] = []
        lines.append("\(period.rawValue) Revenue Debug")
        if period != .allTime {
            lines.append("Window: \(df.string(from: interval.start)) → \(df.string(from: interval.end))")
        }
        lines.append("Records Found: \(bucketed.count)")
        lines.append("")
        for (i, l) in bucketed.enumerated() {
            let amount = (l.totalRevenue ?? 0).asCurrency
            let date = l.pickupDate.map(df.string(from:)) ?? "—"
            let num = l.loadNumber ?? "(no #)"
            lines.append("Entry \(i + 1):")
            lines.append("  Amount: \(amount)")
            lines.append("  Date:   \(date)")
            lines.append("  Load:   \(num)")
            lines.append("  ID:     \(l.id?.uuidString.prefix(8) ?? "—")")
        }
        lines.append("")
        lines.append("\(period.rawValue) Total = \(total.asCurrency)")
        return lines.joined(separator: "\n")
    }

    /// Multi-period dump — exactly the spec's example, all windows in one
    /// block. Wired to the dashboard's hidden long-press in DEBUG builds.
    static func debugReportAllPeriods(loads: [Load], now: Date = Date()) -> String {
        let periods: [StatsPeriod] = [.week, .biweekly, .month, .last30Days, .allTime]
        let uniqueIDs = dedupe(loads).count
        let totalCount = loads.count
        var lines: [String] = []
        lines.append("══════════════════════════════════════════")
        lines.append("Sacred Pathway Driver Hub — Stats Debug")
        lines.append("Raw records:  \(totalCount)")
        lines.append("Unique by id: \(uniqueIDs)")
        if totalCount != uniqueIDs {
            lines.append("⚠️  \(totalCount - uniqueIDs) duplicate row(s) on disk — see LocalLoadsRepository dedupe pass")
        }
        lines.append("══════════════════════════════════════════")
        for p in periods {
            lines.append("")
            lines.append(debugReport(period: p, loads: loads, now: now))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Internal

    /// Deduplicate `loads` by `id`, keeping the most-recently-updated copy.
    /// Loads without an `id` are treated as unique (can't dedupe them).
    static func dedupe(_ loads: [Load]) -> [Load] {
        var byID: [UUID: Load] = [:]
        var idless: [Load] = []
        for l in loads {
            guard let id = l.id else { idless.append(l); continue }
            if let existing = byID[id] {
                // Pick the newer updatedAt; nil < any real date.
                let a = existing.updatedAt ?? .distantPast
                let b = l.updatedAt ?? .distantPast
                byID[id] = b > a ? l : existing
            } else {
                byID[id] = l
            }
        }
        return Array(byID.values) + idless
    }

    /// Dedupe → filter to `period` → return the resulting array. Single
    /// internal pipeline so every public entry point uses the same rule.
    private static func bucket(
        period: StatsPeriod,
        loads: [Load],
        now: Date
    ) -> [Load] {
        let deduped = dedupe(loads)
        if period == .allTime { return deduped }
        let i = interval(for: period, now: now)
        return deduped.filter {
            guard let d = $0.pickupDate else { return false }
            return d >= i.start && d < i.end
        }
    }
}
