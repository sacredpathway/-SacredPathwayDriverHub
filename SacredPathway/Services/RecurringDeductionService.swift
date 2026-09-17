import Foundation

// =============================================================================
//  RecurringDeductionService — standing deductions -> draft settlement lines
// -----------------------------------------------------------------------------
//  "Take $1,300 truck payment off Marcus every week" is stored once as a
//  `RecurringDeduction` and materialised into a real, editable
//  `SettlementDeduction` each time a settlement is drafted for that driver.
//
//  Two rules matter and both are enforced here:
//   1. Materialising NEVER approves anything. The user still sees, edits or
//      deletes the line before approving the settlement.
//   2. A rule due every N days is applied once per window. Drafting the same
//      settlement twice does not double-charge the driver — `alreadyApplied`
//      filters out rules that are already on the settlement.
// =============================================================================

enum RecurringDeductionService {

    // MARK: - Due dates

    /// Is this rule in force for a settlement covering `periodStart...periodEnd`?
    static func isInEffect(
        _ rule: RecurringDeduction,
        periodStart: Date,
        periodEnd: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Bool {
        guard rule.isActive else { return false }

        let startOfPeriodEnd = calendar.startOfDay(for: periodEnd)
        let startOfRule = calendar.startOfDay(for: rule.effectiveStartDate)

        // The rule must have started on or before the period ends.
        guard startOfRule <= startOfPeriodEnd else { return false }

        // And must not have ended before the period begins.
        if let end = rule.effectiveEndDate {
            let startOfEnd = calendar.startOfDay(for: end)
            if startOfEnd < calendar.startOfDay(for: periodStart) { return false }
        }
        return true
    }

    /// For frequencies longer than one settlement, decide whether THIS period is
    /// the one that carries the charge.
    ///
    /// `lastAppliedDate` is the period-start of the most recent settlement that
    /// already carried this rule. Nil means it has never been applied.
    static func isDue(
        _ rule: RecurringDeduction,
        periodStart: Date,
        periodEnd: Date,
        lastAppliedDate: Date?,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Bool {
        guard isInEffect(rule, periodStart: periodStart, periodEnd: periodEnd,
                         calendar: calendar) else { return false }

        if rule.frequency == .everySettlement { return true }

        guard let last = lastAppliedDate else { return true }

        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: last),
            to: calendar.startOfDay(for: periodStart)
        ).day ?? 0

        // A little tolerance so a settlement drafted a day early still charges.
        let threshold = rule.frequency.approximateDays - 2
        return days >= threshold
    }

    // MARK: - Materialising

    /// Builds the deduction lines for a new draft settlement.
    ///
    /// - Parameters:
    ///   - rules: every recurring deduction on file for the profile.
    ///   - driverId: the settlement's driver.
    ///   - settlementGross: used for percent-of-gross rules.
    ///   - lastAppliedByRule: rule id -> period start of the last settlement
    ///     that carried it. Drives the frequency check.
    ///   - alreadyOnSettlement: rule ids already present on this settlement, so
    ///     a re-draft cannot duplicate a line.
    static func materialise(
        rules: [RecurringDeduction],
        driverId: UUID,
        profileId: UUID,
        settlementId: UUID?,
        periodStart: Date,
        periodEnd: Date,
        settlementGross: Money,
        lastAppliedByRule: [UUID: Date] = [:],
        alreadyOnSettlement: Set<UUID> = [],
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [SettlementDeduction] {

        let applicable = rules
            .filter { $0.driverId == driverId }
            .filter { !alreadyOnSettlement.contains($0.id) }
            .filter {
                isDue($0,
                      periodStart: periodStart,
                      periodEnd: periodEnd,
                      lastAppliedDate: lastAppliedByRule[$0.id],
                      calendar: calendar)
            }
            .sorted { lhs, rhs in
                if lhs.category.rawValue != rhs.category.rawValue {
                    return lhs.category.rawValue < rhs.category.rawValue
                }
                return lhs.descriptionText < rhs.descriptionText
            }

        return applicable.enumerated().compactMap { index, rule in
            let amount = rule.resolvedAmount(settlementGross: settlementGross)
            guard amount.isPositive else { return nil }
            return SettlementDeduction(
                settlementId: settlementId,
                profileId: profileId,
                category: rule.category,
                descriptionText: rule.descriptionText.isEmpty
                    ? rule.category.displayName
                    : rule.descriptionText,
                amount: amount,
                date: periodEnd,
                notes: rule.isPercentBased
                    ? "Recurring · \((rule.percentOfGross ?? 0).asPercentString) of gross"
                    : "Recurring · \(rule.frequency.displayName.lowercased())",
                responsibility: rule.responsibility,
                driverSharePercent: rule.driverSharePercent,
                recurringDeductionId: rule.id,
                sortOrder: 1_000 + index
            )
        }
    }

    // MARK: - History

    /// Builds the rule id -> last-applied map from settlement history. Only
    /// settlements that actually became a financial record count; a discarded
    /// draft must not push a monthly charge out a month.
    static func lastAppliedDates(
        deductions: [SettlementDeduction],
        settlementPeriodStarts: [UUID: Date],
        settlementStatuses: [UUID: SettlementStatus]
    ) -> [UUID: Date] {
        var out: [UUID: Date] = [:]
        for deduction in deductions {
            guard let ruleId = deduction.recurringDeductionId,
                  let settlementId = deduction.settlementId,
                  let status = settlementStatuses[settlementId], status.isFinancialRecord,
                  let periodStart = settlementPeriodStarts[settlementId]
            else { continue }
            if let existing = out[ruleId] {
                out[ruleId] = max(existing, periodStart)
            } else {
                out[ruleId] = periodStart
            }
        }
        return out
    }

    // MARK: - Validation

    /// Returns problems with a recurring rule the user is about to save.
    static func validate(_ rule: RecurringDeduction) -> [String] {
        var problems: [String] = []

        if rule.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("Give the recurring deduction a description.")
        }

        if let pct = rule.percentOfGross {
            if pct <= 0 { problems.append("Percentage must be greater than 0%.") }
            if pct > 100 { problems.append("Percentage cannot exceed 100%.") }
        } else if !rule.amount.isPositive {
            problems.append("Amount must be greater than $0.00.")
        }

        if let end = rule.effectiveEndDate, end < rule.effectiveStartDate {
            problems.append("End date cannot be before the start date.")
        }

        if rule.responsibility == .split {
            if rule.driverSharePercent <= 0 || rule.driverSharePercent >= 100 {
                problems.append("A split deduction needs a driver share between 1% and 99%.")
            }
        }

        if rule.category.isAdvanceRecovery {
            problems.append("Advances are tracked separately — add a Driver Advance instead of a recurring deduction, so the balance is capped correctly.")
        }

        return problems
    }
}
