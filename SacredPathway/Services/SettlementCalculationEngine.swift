import Foundation

// =============================================================================
//  SettlementCalculationEngine — the single source of settlement math
// -----------------------------------------------------------------------------
//  NOTHING that produces a dollar figure on a settlement lives in a view. Every
//  screen, the PDF, the estimate card and the reports all call this engine and
//  render what comes back.
//
//  Determinism contract:
//   - Pure function. Same input -> same output, no clock, no locale, no I/O.
//   - Decimal throughout; rounding happens only where the engine emits a line
//     or a total (see Money's precision policy).
//   - Every emitted total is the sum of the ROUNDED lines above it, so a driver
//     adding up the printed statement by hand always lands on the same net pay.
//   - `engineVersion` is stamped onto each result and persisted with the
//     settlement, so a future rule change is identifiable in history.
//
//  Order of operations (the business rule, stated once):
//
//    Gross Load Revenue   = Σ load gross rate
//    + Additions          = Σ credits to the driver
//    = Settlement Gross
//
//    Driver Base Earnings = Σ per-load earnings + Σ per-settlement earnings
//    + Additions
//    − Driver Deductions  = Σ (deduction × driver share)
//    = Net Driver Pay
//
//    Company Expenses     = Σ (deduction × company share) incl. company fees
//    Company Retained     = Gross Load Revenue − Net Driver Pay − Company Expenses
// =============================================================================

// MARK: - Company fee settings

/// Carrier-level fees. These are expanded into real deduction lines so there is
/// exactly one deduction pipeline and one place that decides who pays.
struct CompanyFeeSettings: Codable, Hashable {
    var dispatcherFeePercent: Decimal
    var factoringFeePercent: Decimal
    var authorityFee: Money
    var maintenanceReserve: Money

    /// Who bears each fee. Company by default; lease operators often carry
    /// factoring and authority themselves.
    var dispatcherFeeResponsibility: DeductionResponsibility
    var factoringFeeResponsibility: DeductionResponsibility
    var authorityFeeResponsibility: DeductionResponsibility
    var maintenanceReserveResponsibility: DeductionResponsibility

    init(
        dispatcherFeePercent: Decimal = 0,
        factoringFeePercent: Decimal = 0,
        authorityFee: Money = .zero,
        maintenanceReserve: Money = .zero,
        dispatcherFeeResponsibility: DeductionResponsibility = .company,
        factoringFeeResponsibility: DeductionResponsibility = .company,
        authorityFeeResponsibility: DeductionResponsibility = .company,
        maintenanceReserveResponsibility: DeductionResponsibility = .company
    ) {
        self.dispatcherFeePercent = dispatcherFeePercent
        self.factoringFeePercent = factoringFeePercent
        self.authorityFee = authorityFee
        self.maintenanceReserve = maintenanceReserve
        self.dispatcherFeeResponsibility = dispatcherFeeResponsibility
        self.factoringFeeResponsibility = factoringFeeResponsibility
        self.authorityFeeResponsibility = authorityFeeResponsibility
        self.maintenanceReserveResponsibility = maintenanceReserveResponsibility
    }

    enum CodingKeys: String, CodingKey {
        case dispatcherFeePercent = "dispatcher_fee_percent"
        case factoringFeePercent = "factoring_fee_percent"
        case authorityFee = "authority_fee"
        case maintenanceReserve = "maintenance_reserve"
        case dispatcherFeeResponsibility = "dispatcher_fee_responsibility"
        case factoringFeeResponsibility = "factoring_fee_responsibility"
        case authorityFeeResponsibility = "authority_fee_responsibility"
        case maintenanceReserveResponsibility = "maintenance_reserve_responsibility"
    }

    static let none = CompanyFeeSettings()

    var hasAnyFee: Bool {
        dispatcherFeePercent != 0 || factoringFeePercent != 0
            || !authorityFee.isZero || !maintenanceReserve.isZero
    }
}

// MARK: - Line items

/// One printable row. The review screen and the PDF both render these, so what
/// the user approves on screen is exactly what the driver receives.
struct SettlementLineItem: Hashable, Identifiable {
    enum Kind: String, Hashable {
        case loadEarning
        case settlementEarning
        case addition
        case driverDeduction
        case companyExpense
    }

    var id: UUID
    var kind: Kind
    var label: String
    var basis: String
    var amount: Money
    var relatedLoadId: UUID?
    var category: String?

    /// Does this row increase (true) or decrease (false) the driver's check?
    var isCredit: Bool {
        switch kind {
        case .loadEarning, .settlementEarning, .addition: return true
        case .driverDeduction, .companyExpense:           return false
        }
    }
}

// MARK: - Input

struct SettlementCalculationInput {
    var settlementType: SettlementType
    var payRule: PayRule
    /// true = percentage pays on GROSS revenue. false = percentage pays on net
    /// after company-borne expenses (the legacy `payOnRevenue: false` rule).
    var payOnGrossRevenue: Bool
    var loadLines: [SettlementLoadLine]
    var additions: [SettlementAddition]
    var deductions: [SettlementDeduction]
    /// Hours for an hourly component that does not carry its own hours.
    var hoursWorked: Decimal?
    var companyFees: CompanyFeeSettings
    /// Estimates may include booked / in-progress loads and are never a
    /// financial record. Carried through to the result so the UI can label it.
    var isEstimate: Bool

    init(
        settlementType: SettlementType = .companyDriver,
        payRule: PayRule = .none,
        payOnGrossRevenue: Bool = true,
        loadLines: [SettlementLoadLine] = [],
        additions: [SettlementAddition] = [],
        deductions: [SettlementDeduction] = [],
        hoursWorked: Decimal? = nil,
        companyFees: CompanyFeeSettings = .none,
        isEstimate: Bool = false
    ) {
        self.settlementType = settlementType
        self.payRule = payRule
        self.payOnGrossRevenue = payOnGrossRevenue
        self.loadLines = loadLines
        self.additions = additions
        self.deductions = deductions
        self.hoursWorked = hoursWorked
        self.companyFees = companyFees
        self.isEstimate = isEstimate
    }
}

// MARK: - Result

struct SettlementCalculationResult {

    // Revenue
    let grossLoadRevenue: Money
    let totalAdditions: Money
    let settlementGross: Money

    // Driver side
    let driverBaseEarnings: Money
    let totalDriverDeductions: Money
    let netDriverPay: Money

    // Company side
    let companyExpenses: Money
    let companyRetained: Money
    let companyMargin: Money

    // Per-line results
    let loadEarnings: [UUID: Money]
    let loadPayBasis: [UUID: String]
    let lineItems: [SettlementLineItem]

    // Operational metrics
    let totalLoads: Int
    let loadedMiles: Decimal
    let deadheadMiles: Decimal
    let totalMiles: Decimal
    let revenuePerMile: Money
    let driverEarningsPerMile: Money
    let fuelCostPerMile: Money
    /// (net driver pay + company expenses) / gross load revenue. 0.82 = 82%.
    let expenseRatio: Decimal

    let isEstimate: Bool
    let engineVersion: String
    let warnings: [String]

    /// Driver-facing deduction rows only (company-absorbed lines excluded).
    var driverDeductionLines: [SettlementLineItem] {
        lineItems.filter { $0.kind == .driverDeduction }
    }

    var earningLines: [SettlementLineItem] {
        lineItems.filter { $0.kind == .loadEarning || $0.kind == .settlementEarning }
    }

    var additionLines: [SettlementLineItem] {
        lineItems.filter { $0.kind == .addition }
    }

    var companyExpenseLines: [SettlementLineItem] {
        lineItems.filter { $0.kind == .companyExpense }
    }

    /// Proof the statement adds up. Used by tests and by a debug assertion in
    /// the review screen.
    var reconciles: Bool {
        let earnings = Money.sum(earningLines.map(\.amount))
        let adds = Money.sum(additionLines.map(\.amount))
        let deducts = Money.sum(driverDeductionLines.map(\.amount))
        return (earnings + adds - deducts).rounded == netDriverPay.rounded
    }
}

// MARK: - Engine

enum SettlementCalculationEngine {

    /// Bump when a rule changes. Persisted on every settlement so history can
    /// be explained after a rule change.
    static let engineVersion = "settlement-engine/1.0"

    static func calculate(_ input: SettlementCalculationInput) -> SettlementCalculationResult {

        var warnings: [String] = []
        var lineItems: [SettlementLineItem] = []

        // ── 1. Gross load revenue ────────────────────────────────────────
        // Each load's gross is rounded to cents first so the printed load
        // table sums exactly to the printed gross.
        let orderedLines = input.loadLines.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            let l = lhs.pickupDate ?? Date.distantPast
            let r = rhs.pickupDate ?? Date.distantPast
            if l != r { return l < r }
            return (lhs.loadNumber ?? "") < (rhs.loadNumber ?? "")
        }

        let loadGrosses: [UUID: Money] = orderedLines.reduce(into: [:]) { acc, line in
            acc[line.id] = line.grossRate.rounded
        }
        let grossLoadRevenue = Money.sum(orderedLines.map { loadGrosses[$0.id] ?? .zero })

        // ── 2. Mileage ───────────────────────────────────────────────────
        let loadedMiles = orderedLines.reduce(Decimal(0)) { $0 + max(0, $1.loadedMiles) }
        let deadheadMiles = orderedLines.reduce(Decimal(0)) { $0 + max(0, $1.deadheadMiles) }
        let totalMiles = loadedMiles + deadheadMiles

        // ── 3. Company fee lines ─────────────────────────────────────────
        // Expanded into real deductions so there is one deduction pipeline.
        let feeDeductions = expandCompanyFees(
            input.companyFees,
            grossLoadRevenue: grossLoadRevenue,
            profileId: orderedLines.first?.profileId
                ?? input.deductions.first?.profileId
                ?? UUID()
        )
        let allDeductions = input.deductions + feeDeductions

        // ── 4. Driver earnings ───────────────────────────────────────────
        // Percent-of-NET needs the company-borne cost base first, so compute
        // that before the per-load allocation.
        let companyBorneForNetBasis = Money.sum(allDeductions.map(\.companyAmount))
        let netBasis = (grossLoadRevenue - companyBorneForNetBasis).clampedToZero

        let earningsOutcome = calculateDriverEarnings(
            lines: orderedLines,
            loadGrosses: loadGrosses,
            defaultRule: input.payRule,
            payOnGrossRevenue: input.payOnGrossRevenue,
            grossLoadRevenue: grossLoadRevenue,
            netBasis: netBasis,
            settlementHours: input.hoursWorked,
            warnings: &warnings
        )

        for line in orderedLines {
            let amount = earningsOutcome.perLoad[line.id] ?? .zero
            let basis = earningsOutcome.perLoadBasis[line.id] ?? ""
            lineItems.append(
                SettlementLineItem(
                    id: line.id,
                    kind: .loadEarning,
                    label: line.loadNumber.map { "Load \($0)" } ?? "Load",
                    basis: basis,
                    amount: amount,
                    relatedLoadId: line.loadId,
                    category: nil
                )
            )
        }
        lineItems.append(contentsOf: earningsOutcome.settlementLevelLines)

        let driverBaseEarnings = Money.sum(
            orderedLines.map { earningsOutcome.perLoad[$0.id] ?? .zero }
        ) + Money.sum(earningsOutcome.settlementLevelLines.map(\.amount))

        // ── 5. Additions ─────────────────────────────────────────────────
        let sortedAdditions = input.additions.sorted { $0.sortOrder < $1.sortOrder }
        for addition in sortedAdditions {
            lineItems.append(
                SettlementLineItem(
                    id: addition.id,
                    kind: .addition,
                    label: addition.descriptionText.isEmpty
                        ? addition.category.displayName
                        : addition.descriptionText,
                    basis: addition.category.displayName,
                    amount: addition.amount.rounded,
                    relatedLoadId: addition.relatedLoadId,
                    category: addition.category.rawValue
                )
            )
            if addition.amount.isNegative {
                warnings.append("Addition “\(addition.descriptionText)” is negative — it will reduce the driver's pay.")
            }
        }
        let totalAdditions = Money.sum(sortedAdditions.map { $0.amount.rounded })
        let settlementGross = grossLoadRevenue + totalAdditions

        // ── 6. Deductions ────────────────────────────────────────────────
        let sortedDeductions = allDeductions.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.descriptionText < rhs.descriptionText
        }

        var totalDriverDeductions = Money.zero
        var companyExpenses = Money.zero

        for deduction in sortedDeductions {
            let driverPart = deduction.driverAmount
            let companyPart = deduction.companyAmount

            if !driverPart.isZero {
                totalDriverDeductions += driverPart
                lineItems.append(
                    SettlementLineItem(
                        id: deduction.id,
                        kind: .driverDeduction,
                        label: deduction.descriptionText.isEmpty
                            ? deduction.category.displayName
                            : deduction.descriptionText,
                        basis: deduction.responsibility == .split
                            ? "\(deduction.category.displayName) · driver \(deduction.effectiveDriverPercent.asPercentString)"
                            : deduction.category.displayName,
                        amount: driverPart,
                        relatedLoadId: deduction.relatedLoadId,
                        category: deduction.category.rawValue
                    )
                )
            }

            if !companyPart.isZero {
                companyExpenses += companyPart
                lineItems.append(
                    SettlementLineItem(
                        id: UUID(uuidString: deduction.id.uuidString) ?? deduction.id,
                        kind: .companyExpense,
                        label: deduction.descriptionText.isEmpty
                            ? deduction.category.displayName
                            : deduction.descriptionText,
                        basis: deduction.category.displayName,
                        amount: companyPart,
                        relatedLoadId: deduction.relatedLoadId,
                        category: deduction.category.rawValue
                    )
                )
            }

            if deduction.amount.isNegative {
                warnings.append("Deduction “\(deduction.descriptionText)” is negative — it will increase the driver's pay.")
            }
        }

        // ── 7. Net driver pay ────────────────────────────────────────────
        let netDriverPay = (driverBaseEarnings + totalAdditions - totalDriverDeductions).rounded

        if netDriverPay.isNegative {
            warnings.append("Net pay is negative — deductions exceed earnings for this period.")
        }

        // ── 8. Company side ──────────────────────────────────────────────
        let companyRetained = (grossLoadRevenue - netDriverPay - companyExpenses).rounded
        let companyMargin = companyRetained

        // ── 9. Metrics ───────────────────────────────────────────────────
        let revenuePerMile = totalMiles > 0
            ? (grossLoadRevenue / totalMiles).rounded(scale: 3) : .zero
        let driverEarningsPerMile = totalMiles > 0
            ? (driverBaseEarnings / totalMiles).rounded(scale: 3) : .zero

        let fuelTotal = Money.sum(
            sortedDeductions.filter { $0.category.isFuelCost }.map { $0.amount.rounded }
        )
        let fuelCostPerMile = totalMiles > 0
            ? (fuelTotal / totalMiles).rounded(scale: 3) : .zero

        let expenseRatio: Decimal = grossLoadRevenue.amount > 0
            ? Money.round(
                (netDriverPay.amount + companyExpenses.amount) / grossLoadRevenue.amount,
                scale: 4)
            : 0

        if grossLoadRevenue.isZero && !orderedLines.isEmpty {
            warnings.append("Every load on this settlement has a gross rate of $0.00.")
        }
        if totalMiles == 0 && !orderedLines.isEmpty {
            warnings.append("No mileage recorded — per-mile metrics are unavailable.")
        }

        return SettlementCalculationResult(
            grossLoadRevenue: grossLoadRevenue,
            totalAdditions: totalAdditions,
            settlementGross: settlementGross,
            driverBaseEarnings: driverBaseEarnings,
            totalDriverDeductions: totalDriverDeductions,
            netDriverPay: netDriverPay,
            companyExpenses: companyExpenses,
            companyRetained: companyRetained,
            companyMargin: companyMargin,
            loadEarnings: earningsOutcome.perLoad,
            loadPayBasis: earningsOutcome.perLoadBasis,
            lineItems: lineItems,
            totalLoads: orderedLines.count,
            loadedMiles: loadedMiles,
            deadheadMiles: deadheadMiles,
            totalMiles: totalMiles,
            revenuePerMile: revenuePerMile,
            driverEarningsPerMile: driverEarningsPerMile,
            fuelCostPerMile: fuelCostPerMile,
            expenseRatio: expenseRatio,
            isEstimate: input.isEstimate,
            engineVersion: engineVersion,
            warnings: warnings
        )
    }

    // MARK: - Driver earnings

    private struct EarningsOutcome {
        var perLoad: [UUID: Money]
        var perLoadBasis: [UUID: String]
        var settlementLevelLines: [SettlementLineItem]
    }

    private static func calculateDriverEarnings(
        lines: [SettlementLoadLine],
        loadGrosses: [UUID: Money],
        defaultRule: PayRule,
        payOnGrossRevenue: Bool,
        grossLoadRevenue: Money,
        netBasis: Money,
        settlementHours: Decimal?,
        warnings: inout [String]
    ) -> EarningsOutcome {

        var perLoad: [UUID: Money] = [:]
        var perLoadBasis: [UUID: String] = [:]
        var settlementLines: [SettlementLineItem] = []

        // --- Per-load components -------------------------------------------------
        //
        // Percent-of-NET cannot be evaluated load by load (the cost base is a
        // settlement-level number), so it is computed once and then allocated
        // across the loads in proportion to gross, with the rounding residual
        // pushed onto the last line. Every other component is load-local.

        var netPercentPerLoadTotals: [UUID: Money] = [:]
        if !payOnGrossRevenue {
            let netPercent = defaultRule.components
                .filter { $0.kind == .percentOfGross }
                .reduce(Decimal(0)) { $0 + ($1.percent ?? 0) }
            if netPercent != 0 {
                let total = netBasis.percentage(netPercent)
                netPercentPerLoadTotals = allocate(
                    total: total,
                    across: lines.map { ($0.id, loadGrosses[$0.id] ?? .zero) }
                )
            }
        }

        for line in lines {
            let rule = line.payRuleOverride ?? defaultRule
            let gross = loadGrosses[line.id] ?? .zero
            var lineTotal = Money.zero
            var basisParts: [String] = []

            for component in rule.components where component.kind.isPerLoad {
                switch component.kind {
                case .percentOfGross:
                    if payOnGrossRevenue || line.payRuleOverride != nil {
                        // Per-load override always pays on that load's gross —
                        // a one-off rate on one load has no settlement-level base.
                        let pct = component.percent ?? 0
                        lineTotal += gross.percentage(pct)
                        basisParts.append("\(pct.asPercentString) of \(gross.formatted)")
                    } else {
                        let allocated = netPercentPerLoadTotals[line.id] ?? .zero
                        lineTotal += allocated
                        basisParts.append("\((component.percent ?? 0).asPercentString) of net")
                    }

                case .flatPerLoad:
                    let rate = component.rate ?? .zero
                    lineTotal += rate
                    basisParts.append("\(rate.formatted) flat")

                case .perMile:
                    let rate = component.rate ?? .zero
                    let miles = max(0, line.miles(for: component.mileBasis))
                    lineTotal += rate * miles
                    basisParts.append("\(formatMiles(miles)) mi × \(rate.rounded(scale: 3).formatted)")

                case .weeklySalary, .hourly, .manual:
                    break   // handled at settlement level
                }
            }

            perLoad[line.id] = lineTotal.rounded
            perLoadBasis[line.id] = basisParts.isEmpty
                ? (rule.isEmpty ? "No pay rule" : rule.summary)
                : basisParts.joined(separator: " + ")
        }

        // Percent-of-net allocation already rounds per line; make sure the
        // per-load sum still equals the intended settlement-level total.
        if !payOnGrossRevenue && !netPercentPerLoadTotals.isEmpty {
            // allocate() guarantees this; the assert documents the invariant.
            let allocatedSum = Money.sum(lines.map { netPercentPerLoadTotals[$0.id] ?? .zero })
            let netPercent = defaultRule.components
                .filter { $0.kind == .percentOfGross }
                .reduce(Decimal(0)) { $0 + ($1.percent ?? 0) }
            let intended = netBasis.percentage(netPercent).rounded
            if allocatedSum != intended {
                warnings.append("Percentage allocation residual of \((intended - allocatedSum).formatted) detected.")
            }
        }

        // --- Per-settlement components -------------------------------------------

        for component in defaultRule.components where !component.kind.isPerLoad {
            switch component.kind {
            case .weeklySalary:
                let amount = (component.rate ?? .zero).rounded
                settlementLines.append(
                    SettlementLineItem(
                        id: component.id,
                        kind: .settlementEarning,
                        label: component.label,
                        basis: component.basisDescription,
                        amount: amount,
                        relatedLoadId: nil,
                        category: component.kind.rawValue
                    )
                )

            case .hourly:
                let rate = component.rate ?? .zero
                let hours = component.hours ?? settlementHours ?? 0
                if hours <= 0 {
                    warnings.append("Hourly pay is configured but no hours were entered for this period.")
                }
                let amount = (rate * max(0, hours)).rounded
                settlementLines.append(
                    SettlementLineItem(
                        id: component.id,
                        kind: .settlementEarning,
                        label: component.label,
                        basis: "\(formatHours(max(0, hours))) hrs × \(rate.formatted)",
                        amount: amount,
                        relatedLoadId: nil,
                        category: component.kind.rawValue
                    )
                )

            case .manual:
                let amount = (component.fixedAmount ?? .zero).rounded
                settlementLines.append(
                    SettlementLineItem(
                        id: component.id,
                        kind: .settlementEarning,
                        label: component.label,
                        basis: component.basisDescription,
                        amount: amount,
                        relatedLoadId: nil,
                        category: component.kind.rawValue
                    )
                )

            case .percentOfGross, .flatPerLoad, .perMile:
                break
            }
        }

        if defaultRule.isEmpty && lines.contains(where: { $0.payRuleOverride == nil }) {
            warnings.append("No pay rule is set for this driver — load earnings calculated as $0.00.")
        }

        return EarningsOutcome(
            perLoad: perLoad,
            perLoadBasis: perLoadBasis,
            settlementLevelLines: settlementLines
        )
    }

    // MARK: - Company fee expansion

    private static func expandCompanyFees(
        _ fees: CompanyFeeSettings,
        grossLoadRevenue: Money,
        profileId: UUID
    ) -> [SettlementDeduction] {
        guard fees.hasAnyFee else { return [] }
        var out: [SettlementDeduction] = []

        func add(
            _ category: SettlementDeductionCategory,
            _ label: String,
            _ amount: Money,
            _ responsibility: DeductionResponsibility
        ) {
            guard !amount.rounded.isZero else { return }
            out.append(
                SettlementDeduction(
                    // Deterministic id so recalculating an unchanged settlement
                    // does not churn line identities in the UI.
                    id: deterministicFeeId(category: category, profileId: profileId),
                    profileId: profileId,
                    category: category,
                    descriptionText: label,
                    amount: amount.rounded,
                    responsibility: responsibility,
                    driverSharePercent: responsibility == .driver ? 100 : 0,
                    sortOrder: 9_000
                )
            )
        }

        add(.dispatcherFee,
            "Dispatcher Fee (\(fees.dispatcherFeePercent.asPercentString))",
            grossLoadRevenue.percentage(fees.dispatcherFeePercent),
            fees.dispatcherFeeResponsibility)

        add(.factoringFee,
            "Factoring Fee (\(fees.factoringFeePercent.asPercentString))",
            grossLoadRevenue.percentage(fees.factoringFeePercent),
            fees.factoringFeeResponsibility)

        add(.authorityFee, "Authority Fee", fees.authorityFee,
            fees.authorityFeeResponsibility)

        add(.maintenanceReserve, "Maintenance Reserve", fees.maintenanceReserve,
            fees.maintenanceReserveResponsibility)

        return out
    }

    /// Stable UUID per (profile, fee category) so repeated recalculation of the
    /// same settlement produces the same line ids.
    private static func deterministicFeeId(
        category: SettlementDeductionCategory,
        profileId: UUID
    ) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let profileBytes = withUnsafeBytes(of: profileId.uuid) { Array($0) }
        let categoryBytes = Array(category.rawValue.utf8)
        for i in 0..<16 {
            let c = categoryBytes.isEmpty ? 0 : categoryBytes[i % categoryBytes.count]
            bytes[i] = profileBytes[i] ^ c ^ 0x5A
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Allocation

    /// Splits `total` across weighted buckets, rounding each to cents and
    /// pushing the residual onto the largest bucket so the parts always sum
    /// back to the rounded whole. Zero total weight splits evenly.
    static func allocate(total: Money, across buckets: [(UUID, Money)]) -> [UUID: Money] {
        guard !buckets.isEmpty else { return [:] }
        let target = total.rounded
        let totalWeight = Money.sum(buckets.map(\.1))

        var out: [UUID: Money] = [:]
        if totalWeight.isZero {
            let even = (target / Decimal(buckets.count)).rounded
            for (id, _) in buckets { out[id] = even }
        } else {
            for (id, weight) in buckets {
                out[id] = Money(target.amount * weight.amount / totalWeight.amount).rounded
            }
        }

        let allocated = Money.sum(buckets.map { out[$0.0] ?? .zero })
        let residual = target - allocated
        if !residual.isZero {
            // Largest bucket absorbs the fraction of a cent.
            let anchor = buckets.max(by: { $0.1 < $1.1 })?.0 ?? buckets[buckets.count - 1].0
            out[anchor] = (out[anchor] ?? .zero) + residual
        }
        return out
    }

    // MARK: - Formatting helpers

    private static func formatMiles(_ miles: Decimal) -> String {
        let n = NSDecimalNumber(decimal: Money.round(miles, scale: 1))
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        f.locale = Locale(identifier: "en_US")
        return f.string(from: n) ?? "0"
    }

    private static func formatHours(_ hours: Decimal) -> String {
        let n = NSDecimalNumber(decimal: Money.round(hours, scale: 2))
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.locale = Locale(identifier: "en_US")
        return f.string(from: n) ?? "0"
    }
}
