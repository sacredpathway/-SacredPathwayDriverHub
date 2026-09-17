import Foundation

// =============================================================================
//  SettlementWorkflowService — draft → review → approve → paid
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). Pure Foundation, no UI, no storage. Every
//  settlement screen and both stores go through here, so the lifecycle rules
//  exist exactly once:
//
//   * A draft is built from the driver's pay defaults, the loads in the
//     period, active recurring deductions and planned advance recoveries.
//   * The calculation engine is the only thing that produces a dollar figure.
//     `recalculate` freezes its output onto the stored lines and header.
//   * Paid and voided settlements are locked. They only move through an
//     explicit, reasoned, audited transition.
//   * Advance balances move ONLY when a settlement is approved, and move back
//     if that settlement is reopened to draft or voided.
//   * A load is paid at most once. Paying it again requires an adjustment
//     line that names the settlement it corrects.
// =============================================================================

enum SettlementWorkflowError: Error, LocalizedError, Equatable {
    case notFound
    case locked(SettlementStatus)
    case estimateCannotBeFinalized
    case blocked(String)
    case notPermitted(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "That settlement could not be found."
        case .locked(let status):
            return "This settlement is \(status.displayName.lowercased()). Reopen it before making changes."
        case .estimateCannotBeFinalized:
            return "An estimate cannot be approved or paid. Create a settlement from the completed loads instead."
        case .blocked(let message):
            return message
        case .notPermitted(let message):
            return message
        }
    }
}

// MARK: - Draft options

struct SettlementDraftOptions {
    var profileId: UUID
    var driver: Driver
    var paySettings: DriverPaySettings
    var periodStart: Date
    var periodEnd: Date
    /// Company defaults (from the profile). Responsibilities are overlaid from
    /// the driver's agreement when the draft is built.
    var companyFees: CompanyFeeSettings
    var applyRecurringDeductions: Bool
    var advancePolicy: AdvanceRecoveryPolicy
    var advanceRecoveryAmount: Money?
    var isEstimate: Bool
    var numberPrefix: String
    var hoursWorked: Decimal?
    var actor: SettlementActor
    var now: Date
    var calendar: Calendar

    init(
        profileId: UUID,
        driver: Driver,
        paySettings: DriverPaySettings,
        periodStart: Date,
        periodEnd: Date,
        companyFees: CompanyFeeSettings = .none,
        applyRecurringDeductions: Bool = true,
        advancePolicy: AdvanceRecoveryPolicy = .manual,
        advanceRecoveryAmount: Money? = nil,
        isEstimate: Bool = false,
        numberPrefix: String = SettlementNumberService.defaultPrefix,
        hoursWorked: Decimal? = nil,
        actor: SettlementActor = .unknown,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        self.profileId = profileId
        self.driver = driver
        self.paySettings = paySettings
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.companyFees = companyFees
        self.applyRecurringDeductions = applyRecurringDeductions
        self.advancePolicy = advancePolicy
        self.advanceRecoveryAmount = advanceRecoveryAmount
        self.isEstimate = isEstimate
        self.numberPrefix = numberPrefix
        self.hoursWorked = hoursWorked
        self.actor = actor
        self.now = now
        self.calendar = calendar
    }
}

/// A load offered to the settlement wizard, with the reason it is or is not
/// pre-selected.
struct EligibleSettlementLoad: Identifiable {
    let load: Load
    /// Settlement that already paid this load, if any. Such a load cannot be
    /// selected except as an adjustment.
    let alreadyPaidOn: UUID?
    /// Marked `settled` by the legacy paystub maker. Offered, not pre-selected.
    let legacySettled: Bool
    /// Delivered / ready-for-settlement. Only completed loads go on a real
    /// settlement; in-progress loads may appear on an estimate.
    let isCompleted: Bool

    var id: UUID { load.id ?? UUID() }

    var isSelectable: Bool { alreadyPaidOn == nil }
    var isSelectedByDefault: Bool { isSelectable && !legacySettled && isCompleted }
}

/// Everything that happened when a settlement changed status. The cloud store
/// uses it to write exactly the rows that changed.
struct SettlementTransitionOutcome {
    var settlement: Settlement
    var auditEvents: [SettlementAuditEvent]
    var repaymentsAdded: [DriverAdvanceRepayment]
    var repaymentIdsRemoved: [UUID]
    var advancesTouched: [DriverAdvance]
    /// Operational loads to flag `settled` (approved) or release (reopen/void).
    var loadIdsToMarkSettled: [UUID]
    var loadIdsToRelease: [UUID]
}

enum SettlementWorkflowService {

    // MARK: - Pay settings helpers

    /// Company fee terms for this driver: company amounts, driver agreement
    /// decides who pays. Split is not meaningful for a fee, so it reads as
    /// company-borne.
    static func feeTerms(
        company: CompanyFeeSettings,
        paySettings: DriverPaySettings
    ) -> CompanyFeeSettings {
        func who(_ category: SettlementDeductionCategory) -> DeductionResponsibility {
            let r = paySettings.responsibility(for: category).0
            return r == .driver ? .driver : .company
        }
        var terms = company
        terms.dispatcherFeeResponsibility = who(.dispatcherFee)
        terms.factoringFeeResponsibility = who(.factoringFee)
        terms.authorityFeeResponsibility = who(.authorityFee)
        terms.maintenanceReserveResponsibility = who(.maintenanceReserve)
        return terms
    }

    /// Company fee defaults from the account profile.
    static func companyFees(from profile: Profile?) -> CompanyFeeSettings {
        guard let profile else { return .none }
        return CompanyFeeSettings(
            dispatcherFeePercent: decimal(profile.dispatcherFeePercentage),
            factoringFeePercent: decimal(profile.factoringFeePercentage),
            authorityFee: Money(double: profile.authorityFee ?? 0),
            maintenanceReserve: Money(double: profile.maintenanceReserve ?? 0)
        )
    }

    static func decimal(_ value: Double?) -> Decimal {
        guard let value, value.isFinite else { return 0 }
        return Money(double: value).amount
    }

    // MARK: - Period helpers

    /// Inclusive end-of-day for a period end date.
    static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }

    /// Does this pickup date fall in the settlement period (both ends
    /// inclusive)? Loads belong to the week of their PICKUP date — the same
    /// rule PayWeekService applies everywhere else in the app.
    static func pickup(_ pickup: Date?, isIn start: Date, _ end: Date, calendar: Calendar) -> Bool {
        guard let pickup else { return false }
        return pickup >= calendar.startOfDay(for: start) && pickup <= endOfDay(end, calendar: calendar)
    }

    /// A load is "completed" when it is ready for settlement / settled, or it
    /// is assigned and its delivery date has passed.
    static func isCompleted(_ load: Load, now: Date, calendar: Calendar) -> Bool {
        switch load.loadStatus {
        case .readyForSettlement, .settled:
            return true
        case .assigned, .unassigned:
            guard let delivery = load.deliveryDate else { return false }
            return calendar.startOfDay(for: delivery) <= calendar.startOfDay(for: now)
        }
    }

    // MARK: - Eligible loads

    static func eligibleLoads(
        from loads: [Load],
        driverId: UUID,
        periodStart: Date,
        periodEnd: Date,
        ledger: SettlementLedger,
        includeUnassigned: Bool = false,
        includeInProgress: Bool = false,
        excludingSettlementId: UUID? = nil,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [EligibleSettlementLoad] {
        let paid = ledger.alreadySettledLoadIds(excluding: excludingSettlementId)
        var seen: Set<UUID> = []
        var out: [EligibleSettlementLoad] = []
        for load in loads {
            guard let id = load.id, !seen.contains(id) else { continue }
            seen.insert(id)
            let driverMatches: Bool = load.driverId == driverId
                || (includeUnassigned && load.driverId == nil)
            guard driverMatches,
                  pickup(load.pickupDate, isIn: periodStart, periodEnd, calendar: calendar)
            else { continue }
            let candidate = EligibleSettlementLoad(
                load: load,
                alreadyPaidOn: paid[id],
                legacySettled: load.loadStatus == .settled,
                isCompleted: isCompleted(load, now: now, calendar: calendar)
            )
            guard includeInProgress || candidate.isCompleted || candidate.legacySettled else { continue }
            out.append(candidate)
        }
        out.sort { (lhs: EligibleSettlementLoad, rhs: EligibleSettlementLoad) -> Bool in
            (lhs.load.pickupDate ?? Date.distantPast) < (rhs.load.pickupDate ?? Date.distantPast)
        }
        return out
    }

    // MARK: - Drafting

    /// Builds a new draft (or estimate) settlement. Nothing is saved.
    /// Returned bundle carries the pending "created" audit events.
    static func makeDraft(
        options o: SettlementDraftOptions,
        loads: [Load],
        ledger: SettlementLedger
    ) -> SettlementBundle {
        let settlementId = UUID()
        let terms = feeTerms(company: o.companyFees, paySettings: o.paySettings)
        var rule = o.paySettings.payRule
        rule.feeTerms = terms.hasAnyFee ? terms : nil

        var header = Settlement(
            id: settlementId,
            profileId: o.profileId,
            driverId: o.driver.id,
            settlementPeriodStart: o.calendar.startOfDay(for: o.periodStart),
            settlementPeriodEnd: o.calendar.startOfDay(for: o.periodEnd),
            status: SettlementStatus.draft.rawValue,
            createdAt: o.now,
            settlementType: o.paySettings.settlementType,
            truckNumber: o.paySettings.defaultTruckNumber ?? o.driver.truckNumber,
            payRule: rule,
            payOnGrossRevenue: o.paySettings.payOnGrossRevenue,
            hoursWorked: o.hoursWorked,
            updatedAt: o.now,
            createdByUserId: o.actor.userId,
            isEstimate: o.isEstimate
        )
        if !o.isEstimate {
            header.settlementNumber = SettlementNumberService.nextNumber(
                existing: ledger.settlementNumbers,
                periodEnd: o.periodEnd,
                prefix: o.numberPrefix,
                calendar: o.calendar
            )
        }

        let lines = loads.enumerated().map { index, load in
            SettlementLoadAdapter.line(
                from: load, settlementId: settlementId,
                profileId: o.profileId, sortOrder: index
            )
        }
        let gross = Money.sum(lines.map { $0.grossRate.rounded })

        var deductions: [SettlementDeduction] = []
        if o.applyRecurringDeductions, let driverId = o.driver.id {
            deductions += RecurringDeductionService.materialise(
                rules: ledger.recurringDeductions,
                driverId: driverId,
                profileId: o.profileId,
                settlementId: settlementId,
                periodStart: o.periodStart,
                periodEnd: o.periodEnd,
                settlementGross: gross,
                lastAppliedByRule: ledger.lastAppliedRecurringDates(),
                calendar: o.calendar
            )
        }

        var plans: [PlannedAdvanceRecovery] = []
        if let driverId = o.driver.id, o.advancePolicy != .manual {
            plans = DriverAdvanceService.planRecoveries(
                advances: ledger.advances,
                repayments: ledger.advanceRepayments,
                driverId: driverId,
                policy: o.advancePolicy,
                requestedAmount: o.advanceRecoveryAmount
            )
            deductions += DriverAdvanceService.deductions(
                for: plans, profileId: o.profileId,
                settlementId: settlementId, date: o.periodEnd
            )
        }

        var bundle = SettlementBundle(
            settlement: header,
            loadLines: lines,
            additions: [],
            deductions: deductions
        )
        _ = recalculate(&bundle, rules: ledger.recurringDeductions, now: o.now)

        // Pending audit trail for the new settlement.
        var events: [SettlementAuditEvent] = [
            SettlementAuditService.created(
                settlementId: settlementId, profileId: o.profileId, actor: o.actor,
                driverName: o.driver.name,
                periodDescription: (o.isEstimate ? "estimate " : "")
                    + bundle.settlement.periodDescription
                    + (bundle.settlement.settlementNumber.map { " · \($0)" } ?? ""),
                timestamp: o.now
            )
        ]
        for line in bundle.loadLines {
            events.append(SettlementAuditService.loadAdded(
                settlementId: settlementId, profileId: o.profileId, actor: o.actor,
                loadNumber: line.loadNumber, gross: line.grossRate.rounded,
                driverEarnings: line.driverEarnings, timestamp: o.now))
        }
        let recurringLines = bundle.deductions.filter { $0.recurringDeductionId != nil }
        if !recurringLines.isEmpty {
            events.append(SettlementAuditService.recurringApplied(
                settlementId: settlementId, profileId: o.profileId, actor: o.actor,
                count: recurringLines.count,
                total: Money.sum(recurringLines.map { $0.amount.rounded }),
                timestamp: o.now))
        }
        for plan in plans {
            events.append(SettlementAuditService.advanceRepaymentApplied(
                settlementId: settlementId, profileId: o.profileId, actor: o.actor,
                plan: plan, timestamp: o.now))
        }
        bundle.auditEvents = events
        return bundle
    }

    // MARK: - Recalculation

    /// Runs the engine and freezes its output onto the lines and header.
    /// Percent-of-gross recurring lines are re-priced from their rule so a
    /// changed load list cannot leave a stale amount behind.
    @discardableResult
    static func recalculate(
        _ bundle: inout SettlementBundle,
        rules: [RecurringDeduction] = [],
        now: Date = Date()
    ) -> SettlementCalculationResult {
        // Re-price percent-based recurring lines against the current gross.
        let gross = Money.sum(bundle.loadLines.map { $0.grossRate.rounded })
        for i in bundle.deductions.indices {
            guard let ruleId = bundle.deductions[i].recurringDeductionId,
                  let rule = rules.first(where: { $0.id == ruleId }),
                  rule.isPercentBased else { continue }
            bundle.deductions[i].amount = rule.resolvedAmount(settlementGross: gross)
        }

        let result = bundle.calculate()
        for i in bundle.loadLines.indices {
            let id = bundle.loadLines[i].id
            bundle.loadLines[i].driverEarnings = result.loadEarnings[id] ?? .zero
            bundle.loadLines[i].payBasisDescription = result.loadPayBasis[id] ?? ""
        }
        let rule = bundle.settlement.effectivePayRule
        bundle.settlement.apply(
            result,
            payRule: rule,
            payOnGrossRevenue: bundle.settlement.payOnGrossRevenue ?? true,
            settlementType: bundle.settlement.effectiveSettlementType
        )
        bundle.settlement.updatedAt = now
        // Legacy fee columns stay in step with the frozen fee terms.
        if let terms = rule.feeTerms {
            bundle.settlement.dispatcherFeePercentage = NSDecimalNumber(decimal: terms.dispatcherFeePercent).doubleValue
            bundle.settlement.factoringFeePercentage = NSDecimalNumber(decimal: terms.factoringFeePercent).doubleValue
            bundle.settlement.dispatcherFeeAmount = result.grossLoadRevenue.percentage(terms.dispatcherFeePercent).doubleValue
            bundle.settlement.factoringFeeAmount = result.grossLoadRevenue.percentage(terms.factoringFeePercent).doubleValue
            bundle.settlement.authorityFee = terms.authorityFee.doubleValue
            bundle.settlement.maintenanceReserve = terms.maintenanceReserve.doubleValue
        }
        return result
    }

    // MARK: - Validation

    /// First problem with a driver's pay rule, or nil when it can be saved.
    /// Shared by the pay-terms screens and the repository so a bad rule is
    /// refused before anything (including a new driver row) is written.
    static func payRuleProblem(_ rule: PayRule, maximumPercent: Decimal) -> String? {
        for c in rule.components {
            switch c.kind {
            case .percentOfGross:
                guard let p = c.percent, p > 0, p <= maximumPercent else {
                    return "Percentage must be above 0% and at most \(maximumPercent.asPercentString)."
                }
            case .flatPerLoad, .perMile, .weeklySalary, .hourly:
                guard let r = c.rate, r.isPositive else {
                    return "Enter a rate above $0.00 for \(c.kind.displayName)."
                }
            case .manual:
                if let amount = c.fixedAmount, amount.isNegative {
                    return "A fixed pay amount can't be negative."
                }
            }
        }
        return nil
    }

    static func validate(
        _ bundle: SettlementBundle,
        ledger: SettlementLedger,
        driverExists: Bool = true,
        driverName: String? = nil,
        maximumDriverPercent: Decimal? = 100,
        result: SettlementCalculationResult? = nil
    ) -> [SettlementValidationIssue] {
        let sid = bundle.settlement.id
        let context = SettlementValidationContext(
            settlement: bundle.settlement,
            loadLines: bundle.loadLines,
            additions: bundle.additions,
            deductions: bundle.deductions,
            result: result ?? bundle.calculate(),
            existingSettlementNumbers: ledger.settlements
                .filter { $0.id != sid }
                .compactMap(\.settlementNumber),
            settlementNumbersById: ledger.settlementNumbersById.filter { $0.key != sid },
            alreadySettledLoadIds: ledger.alreadySettledLoadIds(excluding: sid),
            settlementNumberForSettlementId: ledger.settlementNumbersById,
            advances: ledger.advances,
            advanceRepayments: ledger.advanceRepayments,
            driverExists: driverExists,
            driverName: driverName,
            maximumDriverPercent: maximumDriverPercent
        )
        var issues = SettlementValidator.validate(context)

        // Same expense carried on two live settlements = double accounting.
        let linked = ledger.alreadyLinkedExpenseIds(excluding: sid)
        for d in bundle.deductions {
            guard let expenseId = d.relatedExpenseId, let other = linked[expenseId] else { continue }
            let number = ledger.settlementNumbersById[other] ?? "another settlement"
            issues.append(.error(
                "expense_already_linked",
                "Expense “\(d.descriptionText)” is already deducted on \(number).",
                field: "deductions"))
        }
        return issues
    }

    // MARK: - Saving edits

    /// Saves a draft / ready-for-review / approved settlement's edits into the
    /// ledger and returns the audit events it appended. Locked settlements are
    /// refused. `pendingEvents` are events the caller already built (e.g. the
    /// "created" trail from `makeDraft`).
    @discardableResult
    static func save(
        _ bundle: SettlementBundle,
        into ledger: inout SettlementLedger,
        actor: SettlementActor,
        now: Date = Date()
    ) throws -> [SettlementAuditEvent] {
        guard let sid = bundle.settlement.id else { throw SettlementWorkflowError.notFound }

        var toSave = bundle
        let previous = ledger.bundle(for: sid)
        if let number = bundle.settlement.settlementNumber,
           SettlementNumberService.isDuplicate(
               number,
               existing: ledger.settlements.filter { $0.id != sid }.compactMap(\.settlementNumber)) {
            throw SettlementWorkflowError.blocked("Settlement number \(number) is already used on another settlement.")
        }
        if let previous, previous.settlement.isLocked {
            throw SettlementWorkflowError.locked(previous.settlement.settlementStatus)
        }
        // A save never changes status — that is what `transition` is for.
        if let previous {
            toSave.settlement.status = previous.settlement.status
            toSave.settlement.approvedAt = previous.settlement.approvedAt
            toSave.settlement.paidAt = previous.settlement.paidAt
            toSave.settlement.voidedAt = previous.settlement.voidedAt
            toSave.settlement.createdAt = previous.settlement.createdAt
            toSave.settlement.createdByUserId = previous.settlement.createdByUserId
        }
        // Every child row belongs to this settlement and this account.
        let profileId = toSave.settlement.profileId
        for i in toSave.loadLines.indices {
            toSave.loadLines[i].settlementId = sid
            toSave.loadLines[i].profileId = profileId
        }
        for i in toSave.additions.indices {
            toSave.additions[i].settlementId = sid
            toSave.additions[i].profileId = profileId
        }
        for i in toSave.deductions.indices {
            toSave.deductions[i].settlementId = sid
            toSave.deductions[i].profileId = profileId
        }

        let result = recalculate(&toSave, rules: ledger.recurringDeductions, now: now)

        var events = bundle.auditEvents.filter { event in
            !ledger.auditEvents.contains { $0.id == event.id }
        }
        if let previous {
            events += diffEvents(previous: previous, current: toSave, actor: actor, now: now)
            if let recalc = SettlementAuditService.recalculated(
                settlementId: sid, profileId: profileId, actor: actor,
                previousNet: previous.settlement.netPayMoney,
                newNet: result.netDriverPay,
                engineVersion: result.engineVersion, timestamp: now) {
                events.append(recalc)
            }
            // An approved settlement that is edited drops back to draft so it
            // must be approved again — its figures changed.
            if previous.settlement.settlementStatus == .approved, !events.isEmpty,
               previous.settlement.netPayMoney.rounded != result.netDriverPay.rounded {
                toSave.settlement.settlementStatus = .draft
                toSave.settlement.approvedAt = nil
                toSave.settlement.approvedByUserId = nil
                events.append(SettlementAuditService.statusChanged(
                    settlementId: sid, profileId: profileId, actor: actor,
                    from: .approved, to: .draft, netPay: result.netDriverPay,
                    reason: "Edited after approval — needs approval again", timestamp: now))
                // Balances moved on approval move back.
                let removed = ledger.advanceRepayments.filter { $0.settlementId == sid }
                ledger.advanceRepayments.removeAll { $0.settlementId == sid }
                if !removed.isEmpty { ledger.reconcileAdvances() }
            }
        }

        toSave.auditEvents = []
        ledger.replace(bundle: toSave)
        ledger.appendAudit(events)
        return events
    }

    /// One audit row per line added / removed and per pay-rule change.
    static func diffEvents(
        previous: SettlementBundle,
        current: SettlementBundle,
        actor: SettlementActor,
        now: Date
    ) -> [SettlementAuditEvent] {
        guard let sid = current.settlement.id else { return [] }
        let pid = current.settlement.profileId
        var out: [SettlementAuditEvent] = []

        let oldLines = Set(previous.loadLines.map(\.id))
        let newLines = Set(current.loadLines.map(\.id))
        for line in current.loadLines where !oldLines.contains(line.id) {
            out.append(SettlementAuditService.loadAdded(
                settlementId: sid, profileId: pid, actor: actor,
                loadNumber: line.loadNumber, gross: line.grossRate.rounded,
                driverEarnings: line.driverEarnings, timestamp: now))
        }
        for line in previous.loadLines where !newLines.contains(line.id) {
            out.append(SettlementAuditService.loadRemoved(
                settlementId: sid, profileId: pid, actor: actor,
                loadNumber: line.loadNumber, gross: line.grossRate.rounded, timestamp: now))
        }

        let oldAdds = Dictionary(previous.additions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newAdds = Set(current.additions.map(\.id))
        for a in current.additions {
            if let before = oldAdds[a.id] {
                if before.amount.rounded != a.amount.rounded || before.descriptionText != a.descriptionText {
                    out.append(SettlementAuditService.manualAdjustment(
                        settlementId: sid, profileId: pid, actor: actor,
                        description: "Addition “\(a.descriptionText)” changed",
                        previous: before.amount.formatted, new: a.amount.formatted, timestamp: now))
                }
            } else {
                out.append(SettlementAuditService.additionAdded(
                    settlementId: sid, profileId: pid, actor: actor, addition: a, timestamp: now))
            }
        }
        for a in previous.additions where !newAdds.contains(a.id) {
            out.append(SettlementAuditService.additionRemoved(
                settlementId: sid, profileId: pid, actor: actor, addition: a, timestamp: now))
        }

        let oldDeds = Dictionary(previous.deductions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newDeds = Set(current.deductions.map(\.id))
        for d in current.deductions {
            if let before = oldDeds[d.id] {
                if before.amount.rounded != d.amount.rounded
                    || before.responsibility != d.responsibility
                    || before.driverSharePercent != d.driverSharePercent {
                    out.append(SettlementAuditService.manualAdjustment(
                        settlementId: sid, profileId: pid, actor: actor,
                        description: "Deduction “\(d.descriptionText)” changed",
                        previous: "\(before.amount.formatted) · \(before.responsibility.displayName)",
                        new: "\(d.amount.formatted) · \(d.responsibility.displayName)",
                        timestamp: now))
                }
            } else {
                out.append(SettlementAuditService.deductionAdded(
                    settlementId: sid, profileId: pid, actor: actor, deduction: d, timestamp: now))
            }
        }
        for d in previous.deductions where !newDeds.contains(d.id) {
            out.append(SettlementAuditService.deductionRemoved(
                settlementId: sid, profileId: pid, actor: actor, deduction: d, timestamp: now))
        }

        let oldRule = previous.settlement.effectivePayRule
        let newRule = current.settlement.effectivePayRule
        if !oldRule.hasSameTerms(as: newRule)
            || previous.settlement.payOnGrossRevenue != current.settlement.payOnGrossRevenue {
            out.append(SettlementAuditService.payRuleChanged(
                settlementId: sid, profileId: pid, actor: actor,
                from: oldRule, to: newRule, timestamp: now))
        }

        for line in current.loadLines {
            guard let before = previous.loadLines.first(where: { $0.id == line.id }) else { continue }
            if before.grossRate.rounded != line.grossRate.rounded
                || !(before.payRuleOverride ?? .none).hasSameTerms(as: line.payRuleOverride ?? .none) {
                out.append(SettlementAuditService.manualAdjustment(
                    settlementId: sid, profileId: pid, actor: actor,
                    description: "Load \(line.loadNumber ?? "—") changed",
                    previous: before.grossRate.formatted, new: line.grossRate.formatted,
                    timestamp: now))
            }
        }

        if previous.settlement.settlementNumber != current.settlement.settlementNumber {
            out.append(SettlementAuditService.manualAdjustment(
                settlementId: sid, profileId: pid, actor: actor,
                description: "Settlement number changed",
                previous: previous.settlement.settlementNumber,
                new: current.settlement.settlementNumber, timestamp: now))
        }
        return out
    }

    // MARK: - Status transitions

    static func transition(
        settlementId: UUID,
        to target: SettlementStatus,
        ledger: inout SettlementLedger,
        actor: SettlementActor,
        reason: String? = nil,
        paymentReference: String? = nil,
        paymentMethod: String? = nil,
        driverExists: Bool = true,
        maximumDriverPercent: Decimal? = 100,
        numberPrefix: String = SettlementNumberService.defaultPrefix,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> SettlementTransitionOutcome {
        guard var bundle = ledger.bundle(for: settlementId) else {
            throw SettlementWorkflowError.notFound
        }
        let current = bundle.settlement.settlementStatus
        if bundle.settlement.isEstimateRecord && (target == .approved || target == .paid || target == .readyForReview) {
            throw SettlementWorkflowError.estimateCannotBeFinalized
        }

        // Validate the settlement as it would be AFTER the move, so a paid
        // settlement being reopened is not blocked by its own lock.
        var probe = bundle
        probe.settlement.settlementStatus = (target == .approved || target == .paid) ? .approved : .draft
        if probe.settlement.settlementNumber == nil, target == .approved || target == .paid {
            probe.settlement.settlementNumber = SettlementNumberService.nextNumber(
                existing: ledger.settlementNumbers,
                periodEnd: bundle.settlement.settlementPeriodEnd ?? now,
                prefix: numberPrefix, calendar: calendar)
        }
        let issues = validate(probe, ledger: ledger, driverExists: driverExists,
                              maximumDriverPercent: maximumDriverPercent)
        if let blocker = SettlementValidator.validateTransition(
            from: current, to: target, issues: issues, reopenReason: reason) {
            throw SettlementWorkflowError.blocked(blocker.message)
        }
        if target == .paid && current != .approved {
            throw SettlementWorkflowError.blocked("Approve the settlement before marking it paid.")
        }

        let pid = bundle.settlement.profileId
        var outcome = SettlementTransitionOutcome(
            settlement: bundle.settlement, auditEvents: [], repaymentsAdded: [],
            repaymentIdsRemoved: [], advancesTouched: [],
            loadIdsToMarkSettled: [], loadIdsToRelease: [])

        let lineLoadIds = bundle.loadLines.filter { !$0.isAdjustment }.compactMap(\.loadId)

        func removeRepayments() {
            let removed = ledger.advanceRepayments.filter { $0.settlementId == settlementId }
            guard !removed.isEmpty else { return }
            ledger.advanceRepayments.removeAll { $0.settlementId == settlementId }
            outcome.repaymentIdsRemoved = removed.map(\.id)
            let touched = Set(removed.map(\.advanceId))
            ledger.reconcileAdvances()
            outcome.advancesTouched = ledger.advances.filter { touched.contains($0.id) }
        }

        func releasableLoads() -> [UUID] {
            let stillPaid = ledger.alreadySettledLoadIds(excluding: settlementId)
            return lineLoadIds.filter { stillPaid[$0] == nil }
        }

        switch target {
        case .approved:
            if bundle.settlement.settlementNumber == nil {
                bundle.settlement.settlementNumber = probe.settlement.settlementNumber
            }
            if current == .paid {
                // Reopen paid → approved: money already left; balances stay.
                bundle.settlement.paidAt = nil
                bundle.settlement.paymentReference = nil
            } else {
                bundle.settlement.approvedAt = now
                bundle.settlement.approvedByUserId = actor.userId
                // Move advance balances now — and only now.
                removeRepayments()
                let recoveries = bundle.deductions.filter { $0.advanceId != nil }
                let date = bundle.settlement.settlementPeriodEnd ?? now
                let records = recoveries.compactMap { d -> DriverAdvanceRepayment? in
                    guard let advanceId = d.advanceId, d.driverAmount.isPositive else { return nil }
                    return DriverAdvanceRepayment(
                        profileId: pid, advanceId: advanceId, settlementId: settlementId,
                        deductionId: d.id, amount: d.driverAmount, date: date, createdAt: now)
                }
                ledger.advanceRepayments.append(contentsOf: records)
                ledger.reconcileAdvances()
                outcome.repaymentsAdded = records
                let touched = Set(records.map(\.advanceId)).union(outcome.advancesTouched.map(\.id))
                outcome.advancesTouched = ledger.advances.filter { touched.contains($0.id) }
                outcome.loadIdsToMarkSettled = lineLoadIds
            }

        case .paid:
            bundle.settlement.paidAt = now
            if let paymentReference, !paymentReference.isEmpty {
                bundle.settlement.paymentReference = paymentReference
            }
            if let paymentMethod, !paymentMethod.isEmpty {
                bundle.settlement.paymentMethod = paymentMethod
            }

        case .voided:
            bundle.settlement.voidedAt = now
            removeRepayments()
            outcome.loadIdsToRelease = releasableLoads()

        case .draft, .readyForReview:
            if current == .approved || current == .voided || current == .paid {
                bundle.settlement.approvedAt = nil
                bundle.settlement.approvedByUserId = nil
                bundle.settlement.voidedAt = nil
                bundle.settlement.paidAt = nil
                removeRepayments()
                if current == .approved || current == .paid {
                    outcome.loadIdsToRelease = releasableLoads()
                }
            }
        }

        bundle.settlement.settlementStatus = target
        bundle.settlement.updatedAt = now
        ledger.updateHeader(bundle.settlement)

        var events: [SettlementAuditEvent] = []
        if current.isLocked, !target.isLocked, let reason {
            events.append(SettlementAuditService.reopened(
                settlementId: settlementId, profileId: pid, actor: actor,
                from: current, reason: reason, timestamp: now))
        }
        events.append(SettlementAuditService.statusChanged(
            settlementId: settlementId, profileId: pid, actor: actor,
            from: current, to: target, netPay: bundle.settlement.netPayMoney,
            reason: target == .paid ? paymentReference : reason, timestamp: now))
        ledger.appendAudit(events)

        outcome.settlement = bundle.settlement
        outcome.auditEvents = events
        return outcome
    }

    // MARK: - Line editing helpers (used by the review screen)

    /// Adds an existing company expense as a deduction, honouring the driver's
    /// responsibility rules. Refuses an expense already carried elsewhere.
    static func addExpense(
        _ expense: Expense,
        to bundle: inout SettlementBundle,
        paySettings: DriverPaySettings,
        ledger: SettlementLedger
    ) throws {
        guard let expenseId = expense.id else { return }
        if bundle.deductions.contains(where: { $0.relatedExpenseId == expenseId }) { return }
        if let other = ledger.alreadyLinkedExpenseIds(excluding: bundle.settlement.id)[expenseId] {
            let number = ledger.settlementNumbersById[other] ?? "another settlement"
            throw SettlementWorkflowError.blocked("That expense is already deducted on \(number).")
        }
        let nextOrder = (bundle.deductions.map(\.sortOrder).filter { $0 < 8_000 }.max() ?? 1_999) + 1
        bundle.deductions.append(SettlementLoadAdapter.deduction(
            from: expense, settlementId: bundle.settlement.id,
            profileId: bundle.settlement.profileId,
            paySettings: paySettings, sortOrder: nextOrder))
    }

    /// Adds a correction line for a load already paid on `correcting`.
    static func adjustmentLine(
        for load: Load,
        correcting settlementId: UUID,
        in bundle: SettlementBundle,
        grossOverride: Money?,
        note: String
    ) -> SettlementLoadLine {
        var line = SettlementLoadAdapter.line(
            from: load, settlementId: bundle.settlement.id,
            profileId: bundle.settlement.profileId,
            sortOrder: (bundle.loadLines.map(\.sortOrder).max() ?? -1) + 1)
        line.isAdjustment = true
        line.correctsSettlementId = settlementId
        if let grossOverride { line.grossRateOverride = grossOverride }
        line.notes = note
        return line
    }
}

// MARK: - Load / expense adapters

enum SettlementLoadAdapter {

    /// Snapshot of an operational load for a settlement. The load's stored
    /// total revenue is authoritative (it is what every other screen shows);
    /// the component columns are kept for the statement breakdown.
    static func line(
        from load: Load,
        settlementId: UUID?,
        profileId: UUID,
        sortOrder: Int
    ) -> SettlementLoadLine {
        let linehaul = Money(double: load.lineHaulRate ?? 0)
        let fsc = Money(double: load.fuelSurcharge ?? 0)
        let acc = Money(double: load.accessorialCharges ?? 0)
        let componentSum = (linehaul + fsc + acc).rounded
        var override: Money? = nil
        if let total = load.totalRevenue {
            let t = Money(double: total).rounded
            if t != componentSum { override = t }
        }
        return SettlementLoadLine(
            settlementId: settlementId,
            profileId: profileId,
            loadId: load.id,
            loadNumber: load.loadNumber,
            brokerName: load.brokerName,
            brokerMcNumber: load.brokerMcNumber,
            pickupDate: load.pickupDate,
            deliveryDate: load.deliveryDate,
            origin: load.origin,
            destination: load.destination,
            loadedMiles: WorkflowNumbers.decimal(load.totalMiles),
            deadheadMiles: WorkflowNumbers.decimal(load.emptyMiles),
            linehaul: linehaul,
            fuelSurcharge: fsc,
            accessorials: acc,
            grossRateOverride: override,
            sortOrder: sortOrder
        )
    }

    /// Maps the Expenses tab categories onto settlement deduction categories.
    static func deductionCategory(forExpenseCategory raw: String) -> SettlementDeductionCategory {
        switch raw.lowercased() {
        case "fuel", "def":                 return .fuel
        case "toll", "tolls":               return .tolls
        case "repair", "repairs":           return .repair
        case "maintenance":                 return .maintenance
        case "insurance":                   return .insurance
        case "scale", "scale_ticket":       return .scaleTickets
        case "permit", "permits":           return .permits
        case "lease", "truck_payment":      return .truckLease
        case "advance", "advances":         return .cashAdvance
        default:                            return .other
        }
    }

    static func deduction(
        from expense: Expense,
        settlementId: UUID?,
        profileId: UUID,
        paySettings: DriverPaySettings,
        sortOrder: Int
    ) -> SettlementDeduction {
        let category = deductionCategory(forExpenseCategory: expense.category)
        let (who, share) = paySettings.responsibility(for: category)
        let label: String = {
            if let d = expense.description, !d.trimmingCharacters(in: .whitespaces).isEmpty { return d }
            if let v = expense.vendorName, !v.isEmpty { return "\(expense.category.capitalized) · \(v)" }
            return expense.category.capitalized
        }()
        return SettlementDeduction(
            settlementId: settlementId,
            profileId: profileId,
            category: category,
            descriptionText: label,
            amount: Money(double: expense.amount).rounded,
            date: expense.receiptDate ?? expense.createdAt,
            relatedLoadId: expense.loadId,
            relatedExpenseId: expense.id,
            notes: "From Expenses",
            responsibility: who,
            driverSharePercent: who == .split ? share : (who == .driver ? 100 : 0),
            sortOrder: sortOrder
        )
    }
}

enum WorkflowNumbers {
    static func decimal(_ value: Double?) -> Decimal {
        guard let value, value.isFinite else { return 0 }
        return Money(double: value).amount
    }
}
