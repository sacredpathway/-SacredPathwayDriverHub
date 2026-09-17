import Foundation

// =============================================================================
// MARK: - DORMANT AI SERVICE (launch v1 ships without Smart Insights)
// =============================================================================
// This service is the bridge between iOS and the `generate-insights` Edge
// Function. It is NOT invoked in the launch version of the app — the
// Settings → Smart Insights entry is hidden behind FeatureFlags.aiScanEnabled.
//
// Preserved as-is so that Smart Insights can be reactivated alongside the
// document scan flow. See DocumentExtractionService.swift for the full
// re-enable checklist.
// =============================================================================

/// Talks to the Supabase `generate-insights` Edge Function.
enum InsightsService {

    static func generate(prompt: String, supabase: SupabaseService) async throws -> String {
        let response: GenerateInsightsResponse = try await supabase.invokeFunction(
            name: Config.generateInsightsFunction,
            body: GenerateInsightsRequest(prompt: prompt)
        )
        if response.ok == false {
            throw InsightsError.backend(response.message ?? "Failed to generate insights.")
        }
        guard let text = response.text else {
            throw InsightsError.backend("Empty response from the AI service.")
        }
        return text
    }
}

struct GenerateInsightsRequest: Encodable {
    let prompt: String
}

struct GenerateInsightsResponse: Decodable {
    let ok: Bool?
    let text: String?
    let model: String?
    let code: String?
    let message: String?
}

enum InsightsError: LocalizedError {
    case backend(String)
    var errorDescription: String? {
        switch self {
        case .backend(let msg): return msg
        }
    }
}

// =============================================================================
// MARK: - LaneSuggestionService (Part 3 — 2026-05)
// -----------------------------------------------------------------------------
// On-device, network-free lane intelligence. Builds rankings from the user's
// own Load history. Three primary outputs:
//
//   * `topLanes(limit:)`        — highest-revenue lanes the user has driven.
//   * `highRPMLanes(limit:)`    — most profitable rate-per-mile lanes.
//   * `bestReload(near:)`       — recommended next move from a current state,
//                                 ranked by historical RPM × frequency.
//
// All math is pure. The service takes a `[Load]` array (already fetched from
// Supabase) so it can be unit-tested without any I/O. Lanes are keyed by
// (originStateCode, destinationStateCode) so noise from city/zip variations
// doesn't fragment statistics ("Atlanta, GA" + "ATL, GA" → both → "GA").
//
// Why state-code clustering and not city-pairs:
//   Owner-operators run repeatable corridors. The signal is "GA → TX paid
//   $2.10/mi on average". City-pair granularity creates dozens of singleton
//   buckets and zero usable trends.
// =============================================================================

enum LaneSuggestionService {

    /// One lane bucket — origin state → destination state. Includes the
    /// summary statistics needed to rank and display the lane.
    struct LaneStat: Identifiable, Hashable {
        let id: String          // "GA→TX"
        let originState: String
        let destinationState: String
        let loadCount: Int
        let totalRevenue: Double
        let totalMiles: Double
        let averageRevenue: Double
        let averageMiles: Double
        let averageRPM: Double
        let bestBroker: String?
        let lastRunAt: Date?

        /// Single number we sort by for "top lanes". Combines RPM (signal
        /// of margin) with frequency (signal of repeatability).
        var profitabilityScore: Double {
            // Frequency weighted log-scale so a 20-load lane doesn't dwarf
            // a 5-load lane to the point the 5-loader is invisible.
            let freqFactor = log(Double(max(loadCount, 1)) + 1.0)
            return averageRPM * freqFactor
        }

        var displayName: String { "\(originState) → \(destinationState)" }
    }

    // MARK: Public API

    /// Top lanes by profitability score (RPM × log(frequency)). Lanes with
    /// fewer than `minLoads` (default 2) are excluded — one-off runs don't
    /// generalize. Returns at most `limit` results.
    static func topLanes(loads: [Load], limit: Int = 5, minLoads: Int = 2) -> [LaneStat] {
        let stats = aggregate(loads: loads)
            .filter { $0.loadCount >= minLoads && $0.averageRPM > 0 }
        return Array(stats.sorted(by: { $0.profitabilityScore > $1.profitabilityScore }).prefix(limit))
    }

    /// Lanes ranked by raw average RPM. Used for "high RPM opportunity"
    /// cards on the dashboard.
    static func highRPMLanes(loads: [Load], limit: Int = 5, minLoads: Int = 2) -> [LaneStat] {
        let stats = aggregate(loads: loads)
            .filter { $0.loadCount >= minLoads && $0.averageRPM > 0 }
        return Array(stats.sorted(by: { $0.averageRPM > $1.averageRPM }).prefix(limit))
    }

    /// Best next move from a current state. Looks at lanes whose ORIGIN
    /// matches the current state (i.e. "loads I can grab from where I just
    /// delivered"). Ranked by profitability score. Falls back to empty.
    static func bestReload(loads: [Load],
                           fromCurrentState currentState: String,
                           limit: Int = 3) -> [LaneStat] {
        let target = currentState.uppercased().trimmingCharacters(in: .whitespaces)
        guard target.count == 2 else { return [] }
        return aggregate(loads: loads)
            .filter { $0.originState == target && $0.averageRPM > 0 }
            .sorted(by: { $0.profitabilityScore > $1.profitabilityScore })
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Aggregation

    /// Group every load by (originState, destinationState) and compute the
    /// summary statistics. Returns one `LaneStat` per unique lane.
    static func aggregate(loads: [Load]) -> [LaneStat] {
        // Bucket key → mutable totals.
        struct Bucket {
            var loadCount: Int = 0
            var revenueSum: Double = 0
            var milesSum: Double = 0
            var brokers: [String: Int] = [:]
            var lastRunAt: Date? = nil
        }
        var buckets: [String: Bucket] = [:]
        var laneMeta: [String: (String, String)] = [:]

        for load in loads {
            guard
                let originRaw = load.origin,
                let destRaw   = load.destination,
                let originSt  = stateCode(from: originRaw),
                let destSt    = stateCode(from: destRaw)
            else { continue }
            // Skip non-trip data (intra-yard, missing $/miles).
            let rev = load.totalRevenue ?? 0
            let mi  = load.totalMiles ?? 0
            guard rev > 0 || mi > 0 else { continue }

            let key = "\(originSt)→\(destSt)"
            laneMeta[key] = (originSt, destSt)
            var b = buckets[key] ?? Bucket()
            b.loadCount += 1
            b.revenueSum += rev
            b.milesSum += mi
            if let broker = load.brokerName, !broker.isEmpty {
                b.brokers[broker, default: 0] += 1
            }
            let runDate = load.deliveryDate ?? load.pickupDate ?? load.createdAt
            if let d = runDate, b.lastRunAt == nil || d > b.lastRunAt! {
                b.lastRunAt = d
            }
            buckets[key] = b
        }

        return buckets.compactMap { (key, b) -> LaneStat? in
            guard let (origin, dest) = laneMeta[key] else { return nil }
            let avgRev   = b.loadCount > 0 ? b.revenueSum / Double(b.loadCount) : 0
            let avgMiles = b.loadCount > 0 ? b.milesSum   / Double(b.loadCount) : 0
            let rpm      = b.milesSum > 0  ? b.revenueSum / b.milesSum          : 0
            let bestBroker = b.brokers.max(by: { $0.value < $1.value })?.key
            return LaneStat(
                id: key,
                originState: origin,
                destinationState: dest,
                loadCount: b.loadCount,
                totalRevenue: b.revenueSum,
                totalMiles: b.milesSum,
                averageRevenue: avgRev,
                averageMiles: avgMiles,
                averageRPM: rpm,
                bestBroker: bestBroker,
                lastRunAt: b.lastRunAt
            )
        }
    }

    // MARK: - State extraction

    /// Pulls a 2-letter US state code out of free-form origin/destination
    /// strings. Matches "Atlanta, GA", "ATL GA 30303", "GA", etc. Returns
    /// nil for non-US or ambiguous strings.
    static func stateCode(from text: String) -> String? {
        // Pattern 1: "City, ST" — most common in our data.
        if let m = regexFirstGroup(text, pattern: #",\s*([A-Z]{2})\b"#) { return m }
        // Pattern 2: " ST " with surrounding whitespace or zip code.
        if let m = regexFirstGroup(text, pattern: #"\b([A-Z]{2})\b\s*\d{5}?"#) {
            if validStates.contains(m) { return m }
        }
        // Pattern 3: bare uppercase token at end of string.
        if let m = regexFirstGroup(text, pattern: #"\b([A-Z]{2})$"#) {
            if validStates.contains(m) { return m }
        }
        return nil
    }

    private static func regexFirstGroup(_ text: String, pattern: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = r.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        guard m.numberOfRanges > 1 else { return nil }
        let g = m.range(at: 1)
        if g.location == NSNotFound { return nil }
        return ns.substring(with: g)
    }

    private static let validStates: Set<String> = [
        "AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA",
        "HI","ID","IL","IN","IA","KS","KY","LA","ME","MD",
        "MA","MI","MN","MS","MO","MT","NE","NV","NH","NJ",
        "NM","NY","NC","ND","OH","OK","OR","PA","RI","SC",
        "SD","TN","TX","UT","VT","VA","WA","WV","WI","WY",
        "DC"
    ]
}

// =============================================================================
// MARK: - DispatchAssistantService (Part 4 — 2026-05)
// -----------------------------------------------------------------------------
// AI-style "accept this load?" scoring engine. Lives entirely on-device.
// Takes a prospective load (offered rate, origin, destination, miles) and
// scores it against the user's historical lane performance + a sensible
// default cost model. Returns:
//
//   * `recommendation` — accept / negotiate / avoid
//   * `score`          — 0..100
//   * `reasons`        — bullet strings used directly in the UI
//   * `negotiationTarget` — recommended counter-offer (10% above breakeven)
//   * `netRevenueEstimate` — gross − estimated fuel − percent fees
//
// Cost model defaults (configurable from Profile in the future):
//   * fuel:    miles ÷ 6.5 mpg × $3.85/gal
//   * factoring: 3% of gross
//   * dispatch:  0% (unless user has dispatcher fee set)
//
// Why no LLM:
//   The accept/avoid decision is a numeric threshold problem. Owner-operators
//   trust math they can verify; a model that says "this load is bad" without
//   a number behind it gets ignored.
// =============================================================================

enum DispatchAssistantService {

    enum Recommendation: String {
        case accept     = "Accept"
        case negotiate  = "Negotiate"
        case avoid      = "Avoid"

        var emoji: String {
            switch self {
            case .accept:    return "✅"
            case .negotiate: return "⚖️"
            case .avoid:     return "🛑"
            }
        }
    }

    struct CostModel {
        var milesPerGallon: Double = 6.5
        var fuelPricePerGallon: Double = 3.85
        var factoringPercent: Double = 3.0
        var dispatchPercent: Double = 0.0
        var minAcceptableRPM: Double = 1.85      // anything below = avoid by default
        var negotiateBelow: Double = 2.20        // anything below = negotiate
        var rpmFloorOverride: Double? = nil

        /// Build a CostModel pre-filled from the user's Profile (so factoring
        /// and dispatch percentages match their actual operation).
        static func from(profile: Profile?) -> CostModel {
            var m = CostModel()
            if let p = profile {
                if let f = p.factoringFeePercentage { m.factoringPercent = f }
                if let d = p.dispatcherFeePercentage { m.dispatchPercent = d }
            }
            return m
        }
    }

    struct ScoredOffer {
        let recommendation: Recommendation
        let score: Int                   // 0..100
        let offeredRPM: Double
        let estimatedFuelCost: Double
        let estimatedFactoringFee: Double
        let estimatedDispatchFee: Double
        let netRevenueEstimate: Double
        let breakevenRate: Double
        let negotiationTarget: Double
        let reasons: [String]
        let comparedLane: LaneSuggestionService.LaneStat?
    }

    // MARK: Public API

    /// Score a prospective load offer.
    /// - Parameters:
    ///   - offeredRate: gross $ the broker offered.
    ///   - miles: loaded miles for the leg.
    ///   - origin: origin string (any format containing "City, ST").
    ///   - destination: same.
    ///   - history: user's full load history for lane lookup.
    ///   - costs: cost model (default uses sensible owner-op numbers).
    static func score(offeredRate: Double,
                      miles: Double,
                      origin: String,
                      destination: String,
                      history: [Load],
                      costs: CostModel = CostModel()) -> ScoredOffer {

        let safeMiles = max(miles, 1.0)
        let rpm = offeredRate / safeMiles

        // Cost components.
        let fuel = (safeMiles / max(costs.milesPerGallon, 1.0)) * costs.fuelPricePerGallon
        let factoring = offeredRate * (costs.factoringPercent / 100.0)
        let dispatch  = offeredRate * (costs.dispatchPercent  / 100.0)
        let net = offeredRate - fuel - factoring - dispatch
        let breakevenGross = fuel + factoring + dispatch
        let breakevenRPM = breakevenGross / safeMiles

        // Historical comparison.
        let originSt = LaneSuggestionService.stateCode(from: origin) ?? ""
        let destSt   = LaneSuggestionService.stateCode(from: destination) ?? ""
        let allLanes = LaneSuggestionService.aggregate(loads: history)
        let comparedLane = allLanes.first { $0.originState == originSt && $0.destinationState == destSt }

        // Build reasons.
        var reasons: [String] = []
        reasons.append("Offered RPM: $\(String(format: "%.2f", rpm))/mi on \(Int(safeMiles)) mi")
        reasons.append("Est. fuel cost: $\(String(format: "%.0f", fuel)) (\(String(format: "%.1f", costs.milesPerGallon)) mpg × $\(String(format: "%.2f", costs.fuelPricePerGallon))/gal)")
        if factoring > 0 {
            reasons.append("Factoring fee: $\(String(format: "%.0f", factoring)) (\(String(format: "%.1f", costs.factoringPercent))%)")
        }
        reasons.append("Estimated net: $\(String(format: "%.0f", net))")
        if let lane = comparedLane {
            let delta = rpm - lane.averageRPM
            let pct = lane.averageRPM > 0 ? (delta / lane.averageRPM) * 100 : 0
            let sign = pct >= 0 ? "+" : ""
            reasons.append("Vs. your \(lane.displayName) avg: $\(String(format: "%.2f", lane.averageRPM))/mi (\(sign)\(String(format: "%.0f", pct))%)")
        } else if !originSt.isEmpty && !destSt.isEmpty {
            reasons.append("No prior history on \(originSt) → \(destSt) — using thresholds only.")
        }

        // Decide.
        let floor = costs.rpmFloorOverride ?? costs.minAcceptableRPM
        let recommendation: Recommendation
        var penaltyBonus: Int = 0

        if net <= 0 {
            recommendation = .avoid
            reasons.insert("Net would be NEGATIVE after fuel + fees.", at: 0)
        } else if rpm < floor {
            recommendation = .avoid
            reasons.insert("RPM below your $\(String(format: "%.2f", floor))/mi floor.", at: 0)
        } else if rpm < costs.negotiateBelow {
            recommendation = .negotiate
            reasons.insert("RPM is profitable but below your $\(String(format: "%.2f", costs.negotiateBelow))/mi target.", at: 0)
        } else {
            recommendation = .accept
            reasons.insert("RPM clears your acceptance target.", at: 0)
            penaltyBonus += 10
        }

        if let lane = comparedLane, rpm >= lane.averageRPM {
            penaltyBonus += 10
        }
        if let lane = comparedLane, rpm < lane.averageRPM * 0.85 {
            penaltyBonus -= 10
        }

        // Compose final score.
        // Anchor: 100 at 2× negotiate target; 50 at floor; 0 at breakeven.
        let anchor = costs.negotiateBelow * 2
        let rawScore = ((rpm - breakevenRPM) / (anchor - breakevenRPM)) * 100.0
        let clamped = max(0, min(100, Int(rawScore.rounded()) + penaltyBonus))

        // Negotiation target = 110% of negotiateBelow × miles.
        let negotiationTarget = (costs.negotiateBelow * 1.10) * safeMiles

        return ScoredOffer(
            recommendation: recommendation,
            score: clamped,
            offeredRPM: rpm,
            estimatedFuelCost: fuel,
            estimatedFactoringFee: factoring,
            estimatedDispatchFee: dispatch,
            netRevenueEstimate: net,
            breakevenRate: breakevenGross,
            negotiationTarget: negotiationTarget,
            reasons: reasons,
            comparedLane: comparedLane
        )
    }
}

// =============================================================================
// MARK: - PerformanceAnalytics (Part 5 — 2026-05)
// -----------------------------------------------------------------------------
// Pure aggregation over Load + Expense history. Powers the Driver Performance
// Dashboard. Returns ready-to-render summary structs + time-series points
// suitable for Swift Charts.
// =============================================================================

enum PerformanceAnalytics {

    struct Summary {
        var loads: Int = 0
        var totalRevenue: Double = 0
        var totalMiles: Double = 0
        var totalExpenses: Double = 0
        var grossProfit: Double { totalRevenue - totalExpenses }
        var averageRPM: Double { totalMiles > 0 ? totalRevenue / totalMiles : 0 }
        var averageRatePerLoad: Double { loads > 0 ? totalRevenue / Double(loads) : 0 }
        var expenseRatio: Double { totalRevenue > 0 ? totalExpenses / totalRevenue : 0 }
        var profitMargin: Double { totalRevenue > 0 ? grossProfit / totalRevenue : 0 }
    }

    struct TopBroker: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let loadCount: Int
        let totalRevenue: Double
        let averageRPM: Double
    }

    /// A point in a time-series (week/month bucket). Suitable for Swift Charts.
    struct TimePoint: Identifiable, Hashable {
        var id: Date { bucket }
        let bucket: Date
        let revenue: Double
        let expenses: Double
        let miles: Double
        let netProfit: Double
    }

    enum Window {
        case last7Days
        case last30Days
        case last90Days
        case yearToDate
        case all

        var days: Int? {
            switch self {
            case .last7Days:  return 7
            case .last30Days: return 30
            case .last90Days: return 90
            case .yearToDate, .all: return nil
            }
        }
    }

    // MARK: - Summary aggregation

    /// Build a Summary over the loads + expenses that fall inside `window`.
    /// Expenses with `loadId` matching a load in the window are included;
    /// expenses with no loadId but a `receiptDate` in the window are also
    /// included (consistent with PaystubExpenseMatcher rules).
    static func summary(loads: [Load], expenses: [Expense], window: Window = .last30Days) -> Summary {
        let (start, end) = bounds(for: window)
        var s = Summary()
        // PICKUP DATE is the single source of truth for windowing loads
        // (spec 2026-05-24). Loads without a pickup date are excluded —
        // they don't belong to any time window.
        let inWindowLoads = loads.filter { l in
            guard let d = l.pickupDate else { return false }
            return (start == nil || d >= start!) && (end == nil || d <= end!)
        }
        for load in inWindowLoads {
            s.loads += 1
            s.totalRevenue += load.totalRevenue ?? 0
            s.totalMiles   += load.totalMiles ?? 0
        }
        let loadIds = Set(inWindowLoads.compactMap { $0.id })
        for exp in expenses {
            if let lid = exp.loadId, loadIds.contains(lid) {
                s.totalExpenses += exp.amount
            } else if exp.loadId == nil,
                      let d = exp.receiptDate,
                      (start == nil || d >= start!) && (end == nil || d <= end!) {
                s.totalExpenses += exp.amount
            }
        }
        return s
    }

    // MARK: - Top brokers / lanes / states

    static func topBrokers(loads: [Load], limit: Int = 5) -> [TopBroker] {
        struct B { var count = 0; var revenue: Double = 0; var miles: Double = 0 }
        var buckets: [String: B] = [:]
        for load in loads {
            guard let name = load.brokerName, !name.isEmpty else { continue }
            var b = buckets[name] ?? B()
            b.count += 1
            b.revenue += load.totalRevenue ?? 0
            b.miles   += load.totalMiles ?? 0
            buckets[name] = b
        }
        let ranked = buckets.map { (name, b) -> TopBroker in
            TopBroker(
                name: name,
                loadCount: b.count,
                totalRevenue: b.revenue,
                averageRPM: b.miles > 0 ? b.revenue / b.miles : 0
            )
        }
        return Array(ranked.sorted(by: { $0.totalRevenue > $1.totalRevenue }).prefix(limit))
    }

    /// Top states by revenue. Counts the destination state for each load.
    static func topStates(loads: [Load], limit: Int = 5) -> [(state: String, revenue: Double, count: Int)] {
        var buckets: [String: (Double, Int)] = [:]
        for load in loads {
            guard let dest = load.destination,
                  let st = LaneSuggestionService.stateCode(from: dest) else { continue }
            var cur = buckets[st] ?? (0, 0)
            cur.0 += load.totalRevenue ?? 0
            cur.1 += 1
            buckets[st] = cur
        }
        return buckets
            .map { (state: $0.key, revenue: $0.value.0, count: $0.value.1) }
            .sorted(by: { $0.revenue > $1.revenue })
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Time-series

    /// Group loads + expenses into weekly buckets covering `window`. Used
    /// by the dashboard's Swift Charts line chart.
    static func weeklySeries(loads: [Load], expenses: [Expense], window: Window = .last90Days) -> [TimePoint] {
        let cal = Calendar(identifier: .iso8601)
        var dataByWeek: [Date: TimePoint] = [:]
        var weekDates: [Date] = []

        // Seed empty buckets so a quiet week still shows.
        let (start, end) = bounds(for: window)
        if let start = start, let end = end {
            var cursor = startOfWeek(start, cal: cal)
            while cursor <= end {
                let p = TimePoint(bucket: cursor, revenue: 0, expenses: 0, miles: 0, netProfit: 0)
                dataByWeek[cursor] = p
                weekDates.append(cursor)
                cursor = cal.date(byAdding: .weekOfYear, value: 1, to: cursor) ?? end
            }
        }

        for load in loads {
            // PICKUP DATE is the single source of truth for which week a
            // load belongs to (spec 2026-05-24). Loads without a pickup
            // date are skipped.
            guard let d = load.pickupDate else { continue }
            if let start = start, d < start { continue }
            if let end = end, d > end { continue }
            let wk = startOfWeek(d, cal: cal)
            let cur = dataByWeek[wk] ?? TimePoint(bucket: wk, revenue: 0, expenses: 0, miles: 0, netProfit: 0)
            dataByWeek[wk] = TimePoint(
                bucket: wk,
                revenue: cur.revenue + (load.totalRevenue ?? 0),
                expenses: cur.expenses,
                miles: cur.miles + (load.totalMiles ?? 0),
                netProfit: 0  // computed at the end
            )
        }

        for exp in expenses {
            guard let d = exp.receiptDate ?? exp.createdAt else { continue }
            if let start = start, d < start { continue }
            if let end = end, d > end { continue }
            let wk = startOfWeek(d, cal: cal)
            let cur = dataByWeek[wk] ?? TimePoint(bucket: wk, revenue: 0, expenses: 0, miles: 0, netProfit: 0)
            dataByWeek[wk] = TimePoint(
                bucket: wk,
                revenue: cur.revenue,
                expenses: cur.expenses + exp.amount,
                miles: cur.miles,
                netProfit: 0
            )
        }

        return dataByWeek.values
            .map { TimePoint(bucket: $0.bucket, revenue: $0.revenue, expenses: $0.expenses, miles: $0.miles, netProfit: $0.revenue - $0.expenses) }
            .sorted(by: { $0.bucket < $1.bucket })
    }

    // MARK: - Insight strings ("you earn more when running these lanes")

    /// Natural-language insight bullets generated by inspecting the lane +
    /// broker + state aggregates. Limited to ~4 bullets; designed to drop
    /// straight into the dashboard UI.
    static func plainTextInsights(loads: [Load], expenses: [Expense]) -> [String] {
        var out: [String] = []
        let lanes = LaneSuggestionService.aggregate(loads: loads)

        if let best = lanes.filter({ $0.loadCount >= 2 }).max(by: { $0.averageRPM < $1.averageRPM }) {
            out.append("Your highest RPM lane is \(best.displayName) at $\(String(format: "%.2f", best.averageRPM))/mi across \(best.loadCount) loads.")
        }
        if let worst = lanes.filter({ $0.loadCount >= 2 }).min(by: { $0.averageRPM < $1.averageRPM }) {
            out.append("Watch your \(worst.displayName) lane — averaging only $\(String(format: "%.2f", worst.averageRPM))/mi.")
        }
        let brokers = topBrokers(loads: loads, limit: 3)
        if let top = brokers.first {
            out.append("\(top.name) is your top revenue broker — \(top.loadCount) loads, $\(Int(top.totalRevenue)) total.")
        }
        let s30 = summary(loads: loads, expenses: expenses, window: .last30Days)
        if s30.totalRevenue > 0 {
            out.append("Last 30 days: \(s30.loads) loads · $\(Int(s30.totalRevenue)) gross · \(String(format: "%.0f", s30.profitMargin * 100))% profit margin.")
        }
        return out
    }

    // MARK: - Helpers

    private static func bounds(for window: Window) -> (Date?, Date?) {
        let now = Date()
        let cal = Calendar.current
        switch window {
        case .all:
            return (nil, nil)
        case .yearToDate:
            var c = cal.dateComponents([.year], from: now)
            c.month = 1; c.day = 1
            let start = cal.date(from: c) ?? now
            return (start, now)
        case .last7Days, .last30Days, .last90Days:
            let days = window.days ?? 30
            let start = cal.date(byAdding: .day, value: -days, to: now) ?? now
            return (start, now)
        }
    }

    private static func startOfWeek(_ date: Date, cal: Calendar) -> Date {
        var c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        c.weekday = cal.firstWeekday
        return cal.date(from: c) ?? date
    }
}

// =============================================================================
// MARK: - AutomationService (Part 6 — 2026-05)
// -----------------------------------------------------------------------------
// Smart automations that operate on already-fetched data. Pure functions with
// no I/O so they can be called from views, tests, or background tasks.
//
//   * `categorize(vendor:description:)` — infers an expense category from
//     scan text. e.g. "PILOT TRAVEL CENTER" → "fuel".
//   * `findDuplicateExpenses(in:)` — flags likely duplicates (same vendor,
//     same amount, within 24h) so the user can clean up.
//   * `matchReceipt(to:loads:)` — given a receipt's date + amount, returns
//     the best load to attach it to (date-window + nearby fuel stops on
//     the lane).
//
// These all run on demand from view code — no background daemons.
// =============================================================================

enum AutomationService {

    // MARK: - Category inference

    /// Map a vendor/description string to a canonical expense category.
    /// Order matters — most specific wins.
    static func categorize(vendor: String?, description: String? = nil) -> String {
        let needle = ((vendor ?? "") + " " + (description ?? "")).lowercased()

        // Fuel chains first — most common scanned receipt.
        let fuelChains = [
            "pilot", "flying j", "loves", "love's", "ta travel", "ta petro",
            "petro", "ttc", "speedway", "shell", "exxon", "chevron", "bp ",
            "marathon", "valero", "circle k", "casey's", "wawa", "sheetz",
            "76 ", "phillips 66", "kwik trip", "kwik fill", "kum & go",
            "maverik", "ampm", "rotella" // engine oil at stations still buckets to fuel
        ]
        if fuelChains.contains(where: { needle.contains($0) }) { return "fuel" }
        if needle.contains("def ") || needle.contains("diesel exhaust") { return "def" }

        // Tolls.
        if needle.contains("toll") || needle.contains("e-zpass") ||
           needle.contains("ezpass") || needle.contains("sunpass") ||
           needle.contains("turnpike") || needle.contains("fastrak") {
            return "toll"
        }
        // Lumper.
        if needle.contains("lumper") { return "lumper" }
        // Scale.
        if needle.contains("cat scale") || needle.contains("scale ticket") ||
           needle.contains("weigh") { return "scale" }
        // Parking.
        if needle.contains("parking") || needle.contains("truck stop park") { return "parking" }
        // Insurance.
        if needle.contains("progressive") || needle.contains("geico") ||
           needle.contains("nationwide") || needle.contains("insurance") {
            return "insurance"
        }
        // Maintenance / repairs.
        if needle.contains("oil change") || needle.contains("lube") ||
           needle.contains("tire") || needle.contains("brake") ||
           needle.contains("kenworth") || needle.contains("peterbilt") ||
           needle.contains("freightliner") || needle.contains("ryder") ||
           needle.contains("repair") || needle.contains("tow") {
            return "repair"
        }
        if needle.contains("maintenance") || needle.contains("preventive") {
            return "maintenance"
        }
        // Truck / trailer payments.
        if needle.contains("paccar financial") || needle.contains("daimler truck") ||
           needle.contains("ach truck payment") || needle.contains("truck note") {
            return "truck_payment"
        }
        if needle.contains("trailer payment") || needle.contains("trailer note") {
            return "trailer_payment"
        }
        // Factoring / dispatch.
        if needle.contains("factor") { return "factoring_fee" }
        if needle.contains("dispatch") { return "dispatch_fee" }
        // Permits / scales.
        if needle.contains("permit") || needle.contains("ifta") || needle.contains("dot ") {
            return "permits"
        }
        // Subscriptions.
        if needle.contains("driver hub") || needle.contains("apple.com/bill") ||
           needle.contains("subscription") {
            return "subscription"
        }
        return "other"
    }

    // MARK: - Duplicate detection

    /// Pair of expenses flagged as likely duplicates. The UI uses this to
    /// suggest a one-tap delete on the newer row.
    struct DuplicatePair: Identifiable {
        let id: UUID
        let original: Expense
        let suspectedDuplicate: Expense
        let reason: String
    }

    /// Find probable duplicate pairs. Rules:
    ///   * same vendor (case-insensitive) AND
    ///   * same amount (to the cent) AND
    ///   * receipt dates within 24 hours, OR createdAt within 5 minutes.
    static func findDuplicateExpenses(in expenses: [Expense]) -> [DuplicatePair] {
        var pairs: [DuplicatePair] = []
        let sorted = expenses.sorted {
            ($0.receiptDate ?? $0.createdAt ?? .distantPast) <
            ($1.receiptDate ?? $1.createdAt ?? .distantPast)
        }
        for i in 0..<sorted.count {
            for j in (i+1)..<sorted.count {
                let a = sorted[i]
                let b = sorted[j]
                if (a.vendorName ?? "").lowercased() != (b.vendorName ?? "").lowercased() { continue }
                if abs(a.amount - b.amount) > 0.005 { continue }
                let dateOK: Bool = {
                    if let da = a.receiptDate, let db = b.receiptDate {
                        return abs(da.timeIntervalSince(db)) <= 24 * 3600
                    }
                    if let ca = a.createdAt, let cb = b.createdAt {
                        return abs(ca.timeIntervalSince(cb)) <= 300
                    }
                    return false
                }()
                if !dateOK { continue }
                let reason = "Same vendor + amount within 24h"
                pairs.append(DuplicatePair(
                    id: UUID(),
                    original: a,
                    suspectedDuplicate: b,
                    reason: reason
                ))
            }
        }
        return pairs
    }

    // MARK: - Receipt → Load matching

    /// Return the best `Load.id` to attach a free-floating expense to.
    /// Heuristic priority:
    ///   1. A load whose pickup→delivery window contains the receipt date.
    ///   2. The closest load by `(deliveryDate ?? pickupDate)` within ±2 days.
    ///   3. Nil if nothing plausible.
    static func matchReceipt(to expense: Expense, loads: [Load]) -> UUID? {
        guard let receiptDate = expense.receiptDate ?? expense.createdAt else { return nil }
        let cal = Calendar.current

        // Step 1: explicit window match.
        for load in loads {
            guard let pickup = load.pickupDate,
                  let delivery = load.deliveryDate ?? load.pickupDate,
                  let id = load.id else { continue }
            let endOfDelivery = cal.date(byAdding: DateComponents(day: 1, second: -1), to: delivery) ?? delivery
            if receiptDate >= pickup && receiptDate <= endOfDelivery {
                return id
            }
        }

        // Step 2: nearest delivery within ±2 days.
        let twoDays: TimeInterval = 2 * 24 * 3600
        let candidates: [(UUID, TimeInterval)] = loads.compactMap { load in
            guard let id = load.id else { return nil }
            let anchor = load.deliveryDate ?? load.pickupDate ?? load.createdAt ?? .distantPast
            let delta = abs(receiptDate.timeIntervalSince(anchor))
            return delta <= twoDays ? (id, delta) : nil
        }
        return candidates.min(by: { $0.1 < $1.1 })?.0
    }

    // MARK: - Document expiry reminders

    /// Returns documents whose `expirationDate` is within `withinDays`. Used by
    /// the dashboard to surface "renew your authority", "DOT physical",
    /// etc., reminders without hitting the network.
    static func expiringSoon(documents: [ComplianceDocument], withinDays: Int = 30) -> [ComplianceDocument] {
        let cal = Calendar.current
        let now = Date()
        let limit = cal.date(byAdding: .day, value: withinDays, to: now) ?? now
        return documents.filter {
            guard let exp = $0.expirationDate else { return false }
            return exp >= now && exp <= limit
        }
        .sorted { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) }
    }
}
