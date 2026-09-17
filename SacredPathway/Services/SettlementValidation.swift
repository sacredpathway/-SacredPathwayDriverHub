import Foundation

// =============================================================================
//  SettlementValidation — the guardrails around real money
// -----------------------------------------------------------------------------
//  Everything here answers one question: "is it safe to approve this?"
//
//  Errors block approval. Warnings do not — they are things a carrier might
//  legitimately mean (a negative line entered deliberately as a correction, a
//  driver with no miles on a detention-only settlement) and the user is told
//  rather than stopped.
//
//  Pure functions. The caller supplies the surrounding state; nothing here
//  reads storage.
// =============================================================================

enum SettlementIssueSeverity: String {
    case error
    case warning
}

struct SettlementValidationIssue: Hashable, Identifiable {
    var id: String { code + (field ?? "") + message }
    let severity: SettlementIssueSeverity
    let code: String
    let message: String
    let field: String?

    static func error(_ code: String, _ message: String, field: String? = nil) -> Self {
        .init(severity: .error, code: code, message: message, field: field)
    }

    static func warning(_ code: String, _ message: String, field: String? = nil) -> Self {
        .init(severity: .warning, code: code, message: message, field: field)
    }
}

/// Everything the validator needs to see, gathered by the caller.
struct SettlementValidationContext {
    var settlement: Settlement
    var loadLines: [SettlementLoadLine]
    var additions: [SettlementAddition]
    var deductions: [SettlementDeduction]
    var result: SettlementCalculationResult?

    /// Settlement numbers already issued on this account.
    var existingSettlementNumbers: [String]
    var settlementNumbersById: [UUID: String]

    /// load id -> the settlement it was already paid on, for every settlement
    /// that is a financial record. Powers duplicate-pay detection.
    var alreadySettledLoadIds: [UUID: UUID]
    var settlementNumberForSettlementId: [UUID: String]

    /// Advances for this driver plus the full repayment ledger.
    var advances: [DriverAdvance]
    var advanceRepayments: [DriverAdvanceRepayment]

    /// Does the driver row still exist?
    var driverExists: Bool
    var driverName: String?

    /// Maximum driver percentage the account allows. Nil = no cap.
    var maximumDriverPercent: Decimal?

    init(
        settlement: Settlement,
        loadLines: [SettlementLoadLine] = [],
        additions: [SettlementAddition] = [],
        deductions: [SettlementDeduction] = [],
        result: SettlementCalculationResult? = nil,
        existingSettlementNumbers: [String] = [],
        settlementNumbersById: [UUID: String] = [:],
        alreadySettledLoadIds: [UUID: UUID] = [:],
        settlementNumberForSettlementId: [UUID: String] = [:],
        advances: [DriverAdvance] = [],
        advanceRepayments: [DriverAdvanceRepayment] = [],
        driverExists: Bool = true,
        driverName: String? = nil,
        maximumDriverPercent: Decimal? = 100
    ) {
        self.settlement = settlement
        self.loadLines = loadLines
        self.additions = additions
        self.deductions = deductions
        self.result = result
        self.existingSettlementNumbers = existingSettlementNumbers
        self.settlementNumbersById = settlementNumbersById
        self.alreadySettledLoadIds = alreadySettledLoadIds
        self.settlementNumberForSettlementId = settlementNumberForSettlementId
        self.advances = advances
        self.advanceRepayments = advanceRepayments
        self.driverExists = driverExists
        self.driverName = driverName
        self.maximumDriverPercent = maximumDriverPercent
    }
}

enum SettlementValidator {

    // MARK: - Entry point

    static func validate(_ context: SettlementValidationContext) -> [SettlementValidationIssue] {
        var issues: [SettlementValidationIssue] = []
        issues += validateHeader(context)
        issues += validateNumber(context)
        issues += validatePayRule(context)
        issues += validateLoads(context)
        issues += validateAdditions(context)
        issues += validateDeductions(context)
        issues += validateAdvances(context)
        issues += validateTotals(context)
        return issues
    }

    static func errors(_ issues: [SettlementValidationIssue]) -> [SettlementValidationIssue] {
        issues.filter { $0.severity == .error }
    }

    static func warnings(_ issues: [SettlementValidationIssue]) -> [SettlementValidationIssue] {
        issues.filter { $0.severity == .warning }
    }

    /// A settlement may only be approved when nothing is an error.
    static func canApprove(_ issues: [SettlementValidationIssue]) -> Bool {
        errors(issues).isEmpty
    }

    // MARK: - Header

    private static func validateHeader(
        _ c: SettlementValidationContext
    ) -> [SettlementValidationIssue] {
        var issues: [SettlementValidationIssue] = []

        if c.settlement.driverId == nil {
            issues.append(.error("no_driver",
                                 "Select a driver before approving this settlement.",
                                 field: "driver_id"))
        } else if !c.driverExists {
            // History must survive an archived driver, so this is a warning,
            // not a block: the name is already snapshotted on the statement.
            issues.append(.warning("driver_missing",
                                   "The driver record for this settlement no longer exists. The settlement is kept intact for history.",
                                   field: "driver_id"))
        }

        guard let start = c.settlement.settlementPeriodStart,
              let end = c.settlement.settlementPeriodEnd else {
            issues.append(.error("no_period",
                                 "Set a settlement period start and end date.",
                                 field: "settlement_period"))
            return issues
        }

        if end < start {
            issues.append(.error("period_reversed",
                                 "The settlement period ends before it starts.",
                                 field: "settlement_period"))
        }

        let span = Calendar(identifier: .gregorian)
            .dateComponents([.day], from: start, to: end).day ?? 0
        if span > 45 {
            issues.append(.warning("period_long",
                                   "This settlement covers \(span) days. Check the period is right.",
                                   field: "settlement_period"))
        }

        return issues
    }

    // MARK: - Settlement number

    private static func validateNumber(
        _ c: SettlementValidationContext
    ) -> [SettlementValidationIssue] {
        guard let number = c.settlement.settlementNumber,
              !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [.warning("no_number",
                             "No settlement number yet — one is assigned on approval.",
                             field: "settlement_number")]
        }

        if SettlementNumberService.isDuplicate(
            number,
            existing: c.existingSettlementNumbers,
            excluding: c.settlement.id,
            existingBySettlement: c.settlementNumbersById
        ) {
            return [.error("duplicate_number",
                           "Settlement number \(number) is already used on another settlement.",
                           field: "settlement_number")]
        }
        return []
    }

    // MARK: - Pay rule

    private static func validatePayRule(
        _ c: SettlementValidationContext
    ) -> [SettlementValidationIssue] {
        var issues: [SettlementValidationIssue] = []
        let rule = c.settlement.effectivePayRule

        if rule.isEmpty && c.loadLines.contains(where: { $0.payRuleOverride == nil }) {
            issues.append(.error("no_pay_rule",
                                 "This driver has no pay method set. Choose a pay method before approving.",
                                 field: "pay_rule"))
        }

        let cap = c.maximumDriverPercent
        for component in rule.components {
            switch component.kind {
            case .percentOfGross:
                let pct = component.percent ?? 0
                if pct < 0 {
                    issues.append(.error("negative_percent",
                                         "Driver percentage cannot be negative.",
                                         field: "pay_rule"))
                }
                if let cap, pct > cap {
                    issues.append(.error("percent_above_cap",
                                         "Driver percentage of \(pct.asPercentString) exceeds the allowed maximum of \(cap.asPercentString).",
                                         field: "pay_rule"))
                }
            case .perMile, .flatPerLoad, .weeklySalary, .hourly:
                if let rate = component.rate, rate.isNegative {
                    issues.append(.error("negative_rate",
                                         "\(component.label) rate cannot be negative.",
                                         field: "pay_rule"))
                }
            case .manual:
                break
            }

            if component.kind == .hourly {
                let hours = component.hours ?? c.settlement.hoursWorked ?? 0
                if hours <= 0 {
                    issues.append(.error("no_hours",
                                         "Hourly pay needs the hours worked for this period.",
                                         field: "hours_worked"))
                }
            }
        }

        return issues
    }

    // MARK: - Loads

    private static func validateLoads(
        _ c: SettlementValidationContext
    ) -> [SettlementValidationIssue] {
        var issues: [SettlementValidationIssue] = []

        if c.loadLines.isEmpty {
            let hasNonLoadPay = c.settlement.effectivePayRule.components
                .contains { !$0.kind.isPerLoad }
            if !hasNonLoadPay && c.additions.isEmpty {
                issues.append(.warning("no_loads",
                                       "This settlement has no loads on it.",
                                       field: "loads"))
            }
        }

        // Duplicate line within this settlement.
        var seenLoadIds: Set<UUID> = []
        for line in c.loadLines {
            guard let loadId = line.loadId else {
                issues.append(.warning("line_no_load",
                                       "Load \(line.loadNumber ?? "—") is not linked to a load record. It is kept for history.",
                                       field: "loads"))
                continue
            }

            if seenLoadIds.contains(loadId) && !line.isAdjustment {
                issues.append(.error("duplicate_load_line",
                                     "Load \(line.loadNumber ?? "—") appears twice on this settlement.",
                                     field: "loads"))
            }
            seenLoadIds.insert(loadId)

            // Already paid on another settlement.
            if let priorSettlementId = c.alreadySettledLoadIds[loadId],
               priorSettlementId != c.settlement.id {
                let priorNumber = c.settlementNumberForSettlementId[priorSettlementId] ?? "another settlement"
                if line.isAdjustment && line.correctsSettlementId != nil {
                    issues.append(.warning("load_adjustment",
                                           "Load \(line.loadNumber ?? "—") was already paid on \(priorNumber). It is included here as a recorded correction.",
                                           field: "loads"))
                } else {
                    issues.append(.error("load_already_paid",
                                         "Load \(line.loadNumber ?? "—") was already paid on \(priorNumber). Mark it as an adjustment if you intend to pay it again.",
                                         field: "loads"))
                }
            }

            if line.isAdjustment && line.correctsSettlementId == nil {
                issues.append(.error("adjustment_no_origin",
                                     "Load \(line.loadNumber ?? "—") is marked as an adjustment but does not say which settlement it corrects.",
                                     field: "loads"))
            }

            // Negative gross.
            if line.grossRate.isNegative && !line.isAdjustment {
                issues.append(.error("negative_gross",
                                     "Load \(line.loadNumber ?? "—") has a negative gross rate of \(line.grossRate.formatted). Mark it as an adjustment if this is a chargeback.",
                                     field: "loads"))
            }

            if line.grossRate.isZero {
                issues.append(.warning("zero_gross",
                                       "Load \(line.loadNumber ?? "—") has a gross rate of $0.00.",
                                       field: "loads"))
            }

            if line.loadedMiles < 0 || line.deadheadMiles < 0 {
                issues.append(.error("negative_miles",
                                     "Load \(line.loadNumber ?? "—") has negative mileage.",
                                     field: "loads"))
            }

            if let pickup = line.pickupDate,
               let delivery = line.deliveryDate,
               delivery < pickup {
                issues.append(.warning("load_dates_reversed",
                                       "Load \(line.loadNumber ?? "—") delivers before it picks up.",
                                       field: "loads"))
            }
        }

        return issues
    }

    // MARK: - Additions

    private static func validateAdditions(
        _ c: SettlementValidationContext
    ) -> [SettlementValidationIssue] {
        var issues: [SettlementValidationIssue] = []
        for addition in c.additions {
            if addition.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.error("addition_no_description",
                                     "Every addition needs a description.",
                                     field: "additions"))
            }
            if addition.amount.isZero {
                issues.append(.warning("addition_zero",
                                       "Addition “\(addition.descriptionText)” is $0.00.",
                                       field: "additions"))
            }
            if addition.amount.isNegative {
                issues.append(.warning("addition_negative",
                                       "Addition “\(addition.descriptionText)” is negative and will reduce the driver's pay.",
                                       field: "additions"))
            }
        }
        return issues
    }

    // MARK: - Deductions

    private static func validateDeductions(
        _ c: SettlementValidationContext
    ) -> [SettlementValidationIssue] {
        var issues: [SettlementValidationIssue] = []

        for deduction in c.deductions {
            if deduction.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.error("deduction_no_description",
                                     "Every deduction needs a description.",
                                     field: "deductions"))
            }
            if deduction.amount.isNegative {
                issues.append(.warning("deduction_negative",
                                       "Deduction “\(deduction.descriptionText)” is negative and will increase the driver's pay.",
                                       field: "deductions"))
            }
            if deduction.responsibility == .split {
                let share = deduction.driverSharePercent
                if share <= 0 || share >= 100 {
                    issues.append(.error("bad_split",
                                         "Deduction “\(deduction.descriptionText)” is split but the driver share is \(share.asPercentString). Use a share between 1% and 99%.",
                                         field: "deductions"))
                }
            }
        }

        // Two identical recurring rules landing on one settlement.
        var seenRecurring: Set<UUID> = []
        for deduction in c.deductions {
            guard let ruleId = deduction.recurringDeductionId else { continue }
            if seenRecurring.contains(ruleId) {
                issues.append(.error("duplicate_recurring",
                                     "Recurring deduction “\(deduction.descriptionText)” has been applied twice to this settlement.",
                                     field: "deductions"))
            }
            seenRecurring.insert(ruleId)
        }

        return issues
    }

    // MARK: - Advances

    private static func validateAdvances(
        _ c: SettlementValidationContext
    ) -> [SettlementValidationIssue] {
        var issues: [SettlementValidationIssue] = []

        // Group this settlement's recoveries by advance so two lines against
        // one advance are checked against the balance together.
        var byAdvance: [UUID: Money] = [:]
        for deduction in c.deductions {
            guard let advanceId = deduction.advanceId else { continue }
            byAdvance[advanceId] = (byAdvance[advanceId] ?? .zero) + deduction.amount.rounded
        }

        for (advanceId, requested) in byAdvance {
            guard let advance = c.advances.first(where: { $0.id == advanceId }) else {
                issues.append(.warning("advance_missing",
                                       "A deduction references an advance that no longer exists.",
                                       field: "deductions"))
                continue
            }
            if let problem = DriverAdvanceService.validateManualRecovery(
                amount: requested,
                advance: advance,
                repayments: c.advanceRepayments,
                excludingSettlementId: c.settlement.id
            ) {
                issues.append(.error("advance_over_recovery", problem, field: "deductions"))
            }
        }

        return issues
    }

    // MARK: - Totals

    private static func validateTotals(
        _ c: SettlementValidationContext
    ) -> [SettlementValidationIssue] {
        guard let result = c.result else { return [] }
        var issues: [SettlementValidationIssue] = []

        if !result.reconciles {
            issues.append(.error("does_not_reconcile",
                                 "The settlement lines do not add up to the net pay. Recalculate before approving.",
                                 field: "net_pay"))
        }

        if result.netDriverPay.isNegative {
            issues.append(.warning("negative_net",
                                   "Net pay is \(result.netDriverPay.formatted). The driver owes the company for this period.",
                                   field: "net_pay"))
        }

        if result.isEstimate {
            issues.append(.warning("is_estimate",
                                   "This is an estimate. Estimates cannot be approved or paid.",
                                   field: "status"))
        }

        if c.settlement.isLocked {
            issues.append(.error("locked",
                                 "This settlement is \(c.settlement.settlementStatus.displayName.lowercased()) and cannot be edited. Reopen it first.",
                                 field: "status"))
        }

        return issues
    }

    // MARK: - Transitions

    /// Guards a status change. Returns nil when the move is allowed.
    static func validateTransition(
        from current: SettlementStatus,
        to target: SettlementStatus,
        issues: [SettlementValidationIssue],
        reopenReason: String? = nil
    ) -> SettlementValidationIssue? {

        guard current != target else { return nil }

        guard current.allowedTransitions.contains(target) else {
            return .error("bad_transition",
                          "A \(current.displayName.lowercased()) settlement cannot move straight to \(target.displayName.lowercased()).",
                          field: "status")
        }

        // Reopening financial history needs a stated reason for the audit trail.
        if current.isLocked && !target.isLocked {
            let reason = reopenReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if reason.isEmpty {
                return .error("reopen_no_reason",
                              "Give a reason for reopening this \(current.displayName.lowercased()) settlement — it is recorded in the audit trail.",
                              field: "status")
            }
        }

        // Approving or paying requires a clean settlement.
        if target == .approved || target == .paid {
            if let blocker = errors(issues).first {
                return blocker
            }
        }

        return nil
    }
}
