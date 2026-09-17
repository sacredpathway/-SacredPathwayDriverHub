import Foundation

// =============================================================================
//  SettlementAuditService — append-only trail of every financial change
// -----------------------------------------------------------------------------
//  A settlement is a promise about money. When a number changes, the record of
//  who changed it, when, from what, to what has to survive — including through
//  a reopen of a settlement the driver was already paid on.
//
//  Nothing in the app ever updates or deletes an audit event. This service only
//  BUILDS events; persistence is the repository's job.
// =============================================================================

/// Identity of whoever is acting. In Cloud Pro this is the signed-in account;
/// in Free Local Mode there is one operator and the local install id is used.
struct SettlementActor: Hashable {
    let userId: UUID?
    let name: String?

    init(userId: UUID? = nil, name: String? = nil) {
        self.userId = userId
        self.name = name
    }

    static let unknown = SettlementActor()
}

enum SettlementAuditService {

    // MARK: - Event construction

    static func event(
        _ action: SettlementAuditAction,
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        summary: String,
        field: String? = nil,
        previous: String? = nil,
        new: String? = nil,
        timestamp: Date = Date()
    ) -> SettlementAuditEvent {
        SettlementAuditEvent(
            profileId: profileId,
            settlementId: settlementId,
            action: action,
            summary: summary,
            fieldName: field,
            previousValue: previous,
            newValue: new,
            actorUserId: actor.userId,
            actorName: actor.name,
            timestamp: timestamp
        )
    }

    // MARK: - Common events

    static func created(
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        driverName: String,
        periodDescription: String,
        timestamp: Date = Date()
    ) -> SettlementAuditEvent {
        event(.created, settlementId: settlementId, profileId: profileId, actor: actor,
              summary: "Settlement created for \(driverName), \(periodDescription)",
              timestamp: timestamp)
    }

    static func loadAdded(
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        loadNumber: String?,
        gross: Money,
        driverEarnings: Money,
        timestamp: Date = Date()
    ) -> SettlementAuditEvent {
        event(.loadAdded, settlementId: settlementId, profileId: profileId, actor: actor,
              summary: "Load \(loadNumber ?? "—") added · gross \(gross.formatted) · driver \(driverEarnings.formatted)",
              field: "load", new: loadNumber, timestamp: timestamp)
    }

    static func loadRemoved(
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        loadNumber: String?,
        gross: Money,
        timestamp: Date = Date()
    ) -> SettlementAuditEvent {
        event(.loadRemoved, settlementId: settlementId, profileId: profileId, actor: actor,
              summary: "Load \(loadNumber ?? "—") removed · gross \(gross.formatted)",
              field: "load", previous: loadNumber, timestamp: timestamp)
    }

    static func payRuleChanged(
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        from oldRule: PayRule,
        to newRule: PayRule,
        timestamp: Date = Date()
    ) -> SettlementAuditEvent {
        event(.payRateChanged, settlementId: settlementId, profileId: profileId, actor: actor,
              summary: "Pay rule changed from “\(oldRule.summary)” to “\(newRule.summary)”",
              field: "pay_rule", previous: oldRule.summary, new: newRule.summary,
              timestamp: timestamp)
    }

    static func additionAdded(
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        addition: SettlementAddition,
        timestamp: Date = Date()
    ) -> SettlementAuditEvent {
        event(.additionAdded, settlementId: settlementId, profileId: profileId, actor: actor,
              summary: "Addition “\(addition.descriptionText)” \(addition.amount.formatted) added",
              field: "addition", new: addition.amount.formatted, timestamp: timestamp)
    }

    static func additionRemoved(
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        addition: SettlementAddition,
        timestamp: Date = Date()
    ) -> SettlementAuditEvent {
        event(.additionRemoved, settlementId: settlementId, profileId: profileId, actor: actor,
              summary: "Addition “\(addition.descriptionText)” \(addition.amount.formatted) removed",
              field: "addition", previous: addition.amount.formatted, timestamp: timestamp)
    }

    static func deductionAdded(
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        deduction: SettlementDeduction,
        timestamp: Date = Date()
    ) -> SettlementAuditEvent {
        event(.deductionAdded, settlementId: settlementId, profileId: profileId, actor: actor,
              summary: "Deduction “\(deduction.descriptionText)” \(deduction.amount.formatted) added (\(deduction.responsibility.displayName))",
              field: "deduction", new: deduction.amount.formatted, timestamp: timestamp)
    }

    static func deductionRemoved(
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        deduction: SettlementDeduction,
        timestamp: Date = Date()
    ) -> SettlementAuditEvent {
        event(.deductionRemoved, settlementId: settlementId, profileId: profileId, actor: actor,
              summary: "Deduction “\(deduction.descriptionText)” \(deduction.amount.formatted) removed",
              field: "deduction", previous: deduction.amount.formatted, timestamp: timestamp)
    }

    static func recurringApplied(
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        count: Int,
        total: Money,
        timestamp: Date = Date()
    ) -> SettlementAuditEvent {
        event(.recurringApplied, settlementId: settlementId, profileId: profileId, actor: actor,
              summary: "\(count) recurring deduction\(count == 1 ? "" : "s") applied · \(total.formatted)",
              field: "recurring", new: total.formatted, timestamp: timestamp)
    }

    static func advanceRepaymentApplied(
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        plan: PlannedAdvanceRecovery,
        timestamp: Date = Date()
    ) -> SettlementAuditEvent {
        event(.advanceRepaymentApplied, settlementId: settlementId, profileId: profileId,
              actor: actor,
              summary: "Advance recovery \(plan.amount.formatted) applied · balance \(plan.outstandingBefore.formatted) → \(plan.outstandingAfter.formatted)",
              field: "advance_balance",
              previous: plan.outstandingBefore.formatted,
              new: plan.outstandingAfter.formatted,
              timestamp: timestamp)
    }

    static func statusChanged(
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        from oldStatus: SettlementStatus,
        to newStatus: SettlementStatus,
        netPay: Money?,
        reason: String? = nil,
        timestamp: Date = Date()
    ) -> SettlementAuditEvent {
        let action: SettlementAuditAction
        switch newStatus {
        case .approved: action = .approved
        case .paid:     action = .markedPaid
        case .voided:   action = .voided
        case .draft:    action = oldStatus.isLocked ? .reopened : .statusChanged
        case .readyForReview: action = .statusChanged
        }

        var summary = "\(oldStatus.displayName) → \(newStatus.displayName)"
        if let netPay { summary += " · net \(netPay.formatted)" }
        if let reason, !reason.isEmpty { summary += " · \(reason)" }

        return event(action, settlementId: settlementId, profileId: profileId, actor: actor,
                     summary: summary, field: "status",
                     previous: oldStatus.rawValue, new: newStatus.rawValue,
                     timestamp: timestamp)
    }

    static func reopened(
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        from oldStatus: SettlementStatus,
        reason: String,
        timestamp: Date = Date()
    ) -> SettlementAuditEvent {
        event(.reopened, settlementId: settlementId, profileId: profileId, actor: actor,
              summary: "Reopened from \(oldStatus.displayName) · \(reason)",
              field: "status", previous: oldStatus.rawValue, new: SettlementStatus.draft.rawValue,
              timestamp: timestamp)
    }

    static func manualAdjustment(
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        description: String,
        previous: String?,
        new: String?,
        timestamp: Date = Date()
    ) -> SettlementAuditEvent {
        event(.manualAdjustment, settlementId: settlementId, profileId: profileId, actor: actor,
              summary: description, field: "manual", previous: previous, new: new,
              timestamp: timestamp)
    }

    /// Emitted whenever the engine re-runs and the net pay moved. A recalculation
    /// that changes nothing is not worth a row.
    static func recalculated(
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        previousNet: Money?,
        newNet: Money,
        engineVersion: String,
        timestamp: Date = Date()
    ) -> SettlementAuditEvent? {
        if let previousNet, previousNet.rounded == newNet.rounded { return nil }
        return event(.recalculated, settlementId: settlementId, profileId: profileId, actor: actor,
                     summary: "Recalculated · net \(previousNet?.formatted ?? "—") → \(newNet.formatted) (\(engineVersion))",
                     field: "net_pay",
                     previous: previousNet?.formatted, new: newNet.formatted,
                     timestamp: timestamp)
    }

    // MARK: - Reading

    /// Newest first — the order the detail screen shows them in.
    static func sorted(_ events: [SettlementAuditEvent]) -> [SettlementAuditEvent] {
        events.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Diff between two settlement snapshots, used when a screen saves several
    /// changes at once and we want one row per field rather than one per tap.
    static func diffEvents(
        settlementId: UUID,
        profileId: UUID,
        actor: SettlementActor,
        before: SettlementSnapshot,
        after: SettlementSnapshot,
        timestamp: Date = Date()
    ) -> [SettlementAuditEvent] {
        var out: [SettlementAuditEvent] = []

        func compare(_ field: String, _ old: String?, _ new: String?, _ label: String) {
            guard old != new else { return }
            out.append(
                event(.manualAdjustment, settlementId: settlementId, profileId: profileId,
                      actor: actor,
                      summary: "\(label) changed from \(old ?? "—") to \(new ?? "—")",
                      field: field, previous: old, new: new, timestamp: timestamp)
            )
        }

        compare("gross_load_revenue", before.grossLoadRevenue?.formatted,
                after.grossLoadRevenue?.formatted, "Gross revenue")
        compare("total_driver_earnings", before.driverEarnings?.formatted,
                after.driverEarnings?.formatted, "Driver earnings")
        compare("total_additions", before.totalAdditions?.formatted,
                after.totalAdditions?.formatted, "Additions")
        compare("total_deductions", before.totalDeductions?.formatted,
                after.totalDeductions?.formatted, "Deductions")
        compare("net_pay", before.netPay?.formatted, after.netPay?.formatted, "Net pay")
        compare("settlement_number", before.settlementNumber, after.settlementNumber,
                "Settlement number")

        return out
    }
}

/// Minimal shape of a settlement for diffing. Kept separate from the record type
/// so the audit layer does not depend on the whole model graph.
struct SettlementSnapshot: Hashable {
    var settlementNumber: String?
    var grossLoadRevenue: Money?
    var driverEarnings: Money?
    var totalAdditions: Money?
    var totalDeductions: Money?
    var netPay: Money?

    init(
        settlementNumber: String? = nil,
        grossLoadRevenue: Money? = nil,
        driverEarnings: Money? = nil,
        totalAdditions: Money? = nil,
        totalDeductions: Money? = nil,
        netPay: Money? = nil
    ) {
        self.settlementNumber = settlementNumber
        self.grossLoadRevenue = grossLoadRevenue
        self.driverEarnings = driverEarnings
        self.totalAdditions = totalAdditions
        self.totalDeductions = totalDeductions
        self.netPay = netPay
    }
}
