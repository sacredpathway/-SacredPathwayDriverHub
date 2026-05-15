import Foundation

// =============================================================================
// PaystubExpenseMatcher
// -----------------------------------------------------------------------------
// Pure, side-effect-free helper that decides which expenses belong on a given
// paystub. Lives outside SettlementEngine so the rules can be unit-tested and
// reused by both the review screen and the PDF generator.
//
// Rules
// -----
// 1. An expense is "matched" to the paystub if EITHER:
//      a) `loadId` is set AND the load is in the selected load set, OR
//      b) `loadId` is nil AND `receiptDate` falls inside `[periodStart,
//         periodEnd]` (inclusive on both ends, day-precision).
//
// 2. Expenses missing both `loadId` AND `receiptDate` are excluded — there's
//    no way to attribute them to a specific period without a date.
//
// 3. Categories are normalized to lowercase and grouped under one of the
//    canonical labels in `Category` so analytics + the PDF show predictable
//    totals (e.g. "FUEL" / "Fuel" / "fuel " all roll up the same way).
//
// 4. The result is deterministic — sorted by (date desc, category, vendor).
//
// Production safety: this file does NO network or DB calls. It can be called
// from any thread.
// =============================================================================

enum PaystubExpenseMatcher {

    // MARK: - Categories

    /// Canonical, paystub-friendly category buckets. All raw category strings
    /// from `expenses.category` map into one of these.
    enum Category: String, CaseIterable, Hashable {
        case fuel
        case def
        case lumper
        case toll
        case parking
        case scale
        case repair
        case maintenance
        case insurance
        case truckPayment      = "truck_payment"
        case trailerPayment    = "trailer_payment"
        case permits
        case factoring         = "factoring_fee"
        case dispatch          = "dispatch_fee"
        case subscription
        case other

        /// User-facing label.
        var displayName: String {
            switch self {
            case .fuel: return "Fuel"
            case .def: return "DEF"
            case .lumper: return "Lumper"
            case .toll: return "Tolls"
            case .parking: return "Parking"
            case .scale: return "Scale Tickets"
            case .repair: return "Repairs"
            case .maintenance: return "Maintenance"
            case .insurance: return "Insurance"
            case .truckPayment: return "Truck Payment"
            case .trailerPayment: return "Trailer Payment"
            case .permits: return "Permits"
            case .factoring: return "Factoring Fees"
            case .dispatch: return "Dispatch Fees"
            case .subscription: return "Subscriptions"
            case .other: return "Other"
            }
        }

        /// Map any raw expense.category string to a canonical bucket.
        /// Defaults to `.other` for unknown values so we never lose money.
        static func resolve(rawCategory: String?) -> Category {
            let lc = (rawCategory ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            // Try exact rawValue first.
            if let exact = Category(rawValue: lc) { return exact }
            // Common synonyms.
            switch lc {
            case "tolls":                     return .toll
            case "scale tickets", "scale_ticket", "scale-ticket": return .scale
            case "maintenance fees", "maint": return .maintenance
            case "repairs":                   return .repair
            case "truck note", "truck-payment", "truckpayment": return .truckPayment
            case "trailer note", "trailer-payment", "trailerpayment": return .trailerPayment
            case "factoring", "factor":       return .factoring
            case "dispatch", "dispatcher":    return .dispatch
            case "subscriptions", "subs":     return .subscription
            case "permit":                    return .permits
            case "ifta", "fuel_tax":          return .fuel  // road taxes roll into Fuel for simplicity
            default:                          return .other
            }
        }
    }

    // MARK: - Result

    /// One curated expense as it appears on the paystub. Wraps the underlying
    /// `Expense` plus a UI-controlled `included` flag and a possible
    /// override amount the user typed.
    struct LineItem: Identifiable {
        let id: UUID
        let expense: Expense
        let category: Category
        let date: Date?
        var included: Bool
        var overrideAmount: Double?
        let isManualLine: Bool

        var displayAmount: Double {
            overrideAmount ?? expense.amount
        }
    }

    /// Bundle returned by `match`. The view uses this directly.
    struct MatchResult {
        var lineItems: [LineItem]
        let unattributedDropped: Int
        let periodStart: Date
        let periodEnd: Date

        /// Sum of every included line item.
        var includedTotal: Double {
            lineItems.filter { $0.included }.reduce(0) { $0 + $1.displayAmount }
        }

        /// Map of canonical category → sum of included items in that category.
        /// Empty categories are omitted.
        var includedByCategory: [(Category, Double)] {
            var bucket: [Category: Double] = [:]
            for item in lineItems where item.included {
                bucket[item.category, default: 0] += item.displayAmount
            }
            return Category.allCases.compactMap { c in
                bucket[c].map { (c, $0) }
            }
        }

        /// Just the included expenses re-projected back to `Expense` — used
        /// by `SettlementEngine` and `PaystubPDFService` which both still
        /// take `[Expense]`.
        var includedExpenses: [Expense] {
            lineItems
                .filter { $0.included }
                .map { item in
                    var copy = item.expense
                    if let override = item.overrideAmount {
                        copy.amount = override
                    }
                    return copy
                }
        }
    }

    // MARK: - Public API

    /// Build the curated list. Caller passes everything they have; matcher
    /// decides what belongs on this paystub.
    ///
    /// - Parameters:
    ///   - allExpenses: every expense the user has access to (already
    ///     fetched from Supabase).
    ///   - selectedLoadIds: the loads the user picked for this paystub.
    ///   - periodStart / periodEnd: the inclusive date range. Time-of-day
    ///     is normalized to start-of-day / end-of-day internally.
    ///   - manualLines: extra `Expense` rows the user typed by hand on the
    ///     review screen. They are NEVER persisted; they exist only for the
    ///     duration of the paystub flow.
    static func match(
        allExpenses: [Expense],
        selectedLoadIds: Set<UUID>,
        periodStart: Date,
        periodEnd: Date,
        manualLines: [Expense] = []
    ) -> MatchResult {
        let cal = Calendar.current
        let start = cal.startOfDay(for: periodStart)
        let end: Date = {
            var c = cal.dateComponents([.year, .month, .day], from: periodEnd)
            c.hour = 23; c.minute = 59; c.second = 59
            return cal.date(from: c) ?? periodEnd
        }()

        var lineItems: [LineItem] = []
        var dropped = 0

        for expense in allExpenses {
            let attached = expense.loadId.map { selectedLoadIds.contains($0) } ?? false
            let inWindow: Bool = {
                guard let d = expense.receiptDate else { return false }
                return d >= start && d <= end
            }()

            if attached {
                // Always include — it's tied to a load on this paystub.
                lineItems.append(makeLineItem(expense: expense, isManual: false))
            } else if expense.loadId == nil && inWindow {
                // Free-floating expense in the window.
                lineItems.append(makeLineItem(expense: expense, isManual: false))
            } else if expense.loadId == nil && expense.receiptDate == nil {
                // No way to attribute — drop and surface count to UI.
                dropped += 1
            }
            // else: tied to a load NOT on this paystub → silently skipped.
        }

        // Append manual lines verbatim — already user-curated.
        for m in manualLines {
            lineItems.append(makeLineItem(expense: m, isManual: true))
        }

        // Stable, predictable order: newest receipts first, then category, then vendor.
        lineItems.sort { lhs, rhs in
            let ld = lhs.date ?? .distantPast
            let rd = rhs.date ?? .distantPast
            if ld != rd { return ld > rd }
            if lhs.category != rhs.category {
                return lhs.category.displayName < rhs.category.displayName
            }
            return (lhs.expense.vendorName ?? "") < (rhs.expense.vendorName ?? "")
        }

        return MatchResult(
            lineItems: lineItems,
            unattributedDropped: dropped,
            periodStart: start,
            periodEnd: end
        )
    }

    // MARK: - Helpers

    private static func makeLineItem(expense: Expense, isManual: Bool) -> LineItem {
        LineItem(
            id: expense.id ?? UUID(),
            expense: expense,
            category: Category.resolve(rawCategory: expense.category),
            date: expense.receiptDate ?? expense.createdAt,
            included: true,
            overrideAmount: nil,
            isManualLine: isManual
        )
    }
}
