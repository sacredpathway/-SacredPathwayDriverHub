import Foundation

// =============================================================================
//  DriverAdvanceService — advance balances and recovery planning
// -----------------------------------------------------------------------------
//  Pure, testable math. No storage, no UI. The repositories call in here to
//  decide how much of an advance may be recovered on a settlement, and the
//  answer is always bounded by the outstanding balance:
//
//      recovered ≤ outstanding      (never more, never negative)
//
//  Recovery order is oldest advance first — the same way a carrier works a
//  driver's balance down — and each recovery produces BOTH a deduction line the
//  driver can see and a ledger row that closes out the advance.
// =============================================================================

enum AdvanceRecoveryPolicy: String, Codable, CaseIterable, Identifiable {
    /// Take the whole outstanding balance on this settlement.
    case full
    /// Take a fixed amount per settlement until the balance clears.
    case fixedPerSettlement = "fixed_per_settlement"
    /// Take nothing automatically — the user adds it by hand.
    case manual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full:               return "Recover in Full"
        case .fixedPerSettlement: return "Recover Over Time"
        case .manual:             return "Manual"
        }
    }
}

/// One planned recovery against one advance.
struct PlannedAdvanceRecovery: Hashable, Identifiable {
    var id: UUID { advanceId }
    let advanceId: UUID
    let advanceType: AdvanceType
    let advanceDescription: String
    let outstandingBefore: Money
    let amount: Money
    var outstandingAfter: Money { (outstandingBefore - amount).clampedToZero }
    var clearsAdvance: Bool { outstandingAfter.isZero }
}

enum DriverAdvanceService {

    // MARK: - Balances

    /// Authoritative outstanding balance, recomputed from the repayment ledger
    /// rather than trusting the cached `recoveredAmount` column.
    static func outstanding(
        advance: DriverAdvance,
        repayments: [DriverAdvanceRepayment]
    ) -> Money {
        let recovered = Money.sum(
            repayments.filter { $0.advanceId == advance.id }.map { $0.amount.rounded }
        )
        return (advance.amount.rounded - recovered).clampedToZero
    }

    /// Returns the advance with `recoveredAmount` and `isClosed` rebuilt from
    /// the ledger. Use this on load so a stale cache can never over- or
    /// under-deduct.
    static func reconciled(
        advance: DriverAdvance,
        repayments: [DriverAdvanceRepayment]
    ) -> DriverAdvance {
        var copy = advance
        let recovered = Money.sum(
            repayments.filter { $0.advanceId == advance.id }.map { $0.amount.rounded }
        )
        copy.recoveredAmount = recovered.capped(at: advance.amount.rounded)
        copy.isClosed = copy.outstandingBalance.isZero
        return copy
    }

    /// Total a driver still owes across every open advance.
    static func totalOutstanding(
        advances: [DriverAdvance],
        repayments: [DriverAdvanceRepayment],
        driverId: UUID
    ) -> Money {
        Money.sum(
            advances
                .filter { $0.driverId == driverId }
                .map { outstanding(advance: $0, repayments: repayments) }
        )
    }

    // MARK: - Planning

    /// Works out how much comes off this settlement, oldest advance first.
    ///
    /// - `requestedAmount` nil with `.full` means "clear everything".
    /// - Any requested amount is capped at the total outstanding, and each
    ///   individual recovery is capped at that advance's own balance.
    static func planRecoveries(
        advances: [DriverAdvance],
        repayments: [DriverAdvanceRepayment],
        driverId: UUID,
        policy: AdvanceRecoveryPolicy,
        requestedAmount: Money? = nil
    ) -> [PlannedAdvanceRecovery] {

        guard policy != .manual else { return [] }

        let open = advances
            .filter { $0.driverId == driverId }
            .map { reconciled(advance: $0, repayments: repayments) }
            .filter { !$0.outstandingBalance.isZero }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        guard !open.isEmpty else { return [] }

        let totalOutstanding = Money.sum(open.map(\.outstandingBalance))

        var budget: Money
        switch policy {
        case .full:
            budget = requestedAmount?.capped(at: totalOutstanding) ?? totalOutstanding
        case .fixedPerSettlement:
            // A fixed plan with no amount recovers nothing — the caller must
            // say how much. Silently clearing the whole balance would be worse.
            budget = (requestedAmount ?? .zero).capped(at: totalOutstanding)
        case .manual:
            budget = .zero
        }

        guard budget.isPositive else { return [] }

        var plans: [PlannedAdvanceRecovery] = []
        var remaining = budget

        for advance in open {
            guard remaining.isPositive else { break }
            let take = remaining.capped(at: advance.outstandingBalance).rounded
            guard take.isPositive else { continue }
            plans.append(
                PlannedAdvanceRecovery(
                    advanceId: advance.id,
                    advanceType: advance.type,
                    advanceDescription: advance.descriptionText,
                    outstandingBefore: advance.outstandingBalance,
                    amount: take
                )
            )
            remaining -= take
        }

        return plans
    }

    // MARK: - Materialising

    /// Turns planned recoveries into the deduction lines the driver sees.
    static func deductions(
        for plans: [PlannedAdvanceRecovery],
        profileId: UUID,
        settlementId: UUID?,
        date: Date
    ) -> [SettlementDeduction] {
        plans.enumerated().map { index, plan in
            SettlementDeduction(
                settlementId: settlementId,
                profileId: profileId,
                category: plan.advanceType.deductionCategory,
                descriptionText: plan.advanceDescription.isEmpty
                    ? plan.advanceType.displayName
                    : plan.advanceDescription,
                amount: plan.amount,
                date: date,
                notes: plan.clearsAdvance
                    ? "Advance paid in full"
                    : "Balance after this settlement: \(plan.outstandingAfter.formatted)",
                responsibility: .driver,
                driverSharePercent: 100,
                advanceId: plan.advanceId,
                sortOrder: 8_000 + index
            )
        }
    }

    /// Ledger rows recording the recovery. Written only when the settlement is
    /// approved — a draft must not move a driver's balance.
    static func repaymentRecords(
        for plans: [PlannedAdvanceRecovery],
        deductions: [SettlementDeduction],
        profileId: UUID,
        settlementId: UUID,
        date: Date
    ) -> [DriverAdvanceRepayment] {
        plans.map { plan in
            let matchingDeduction = deductions.first { $0.advanceId == plan.advanceId }
            return DriverAdvanceRepayment(
                profileId: profileId,
                advanceId: plan.advanceId,
                settlementId: settlementId,
                deductionId: matchingDeduction?.id,
                amount: plan.amount,
                date: date
            )
        }
    }

    // MARK: - Validation

    /// Guards a hand-entered advance deduction. Returns nil when the amount is
    /// acceptable, otherwise the reason it is not.
    static func validateManualRecovery(
        amount: Money,
        advance: DriverAdvance,
        repayments: [DriverAdvanceRepayment],
        excludingSettlementId: UUID? = nil
    ) -> String? {
        guard amount.isPositive else {
            return "Advance recovery must be greater than $0.00."
        }
        let relevant = repayments.filter {
            $0.advanceId == advance.id
                && (excludingSettlementId == nil || $0.settlementId != excludingSettlementId)
        }
        let balance = outstanding(advance: advance, repayments: relevant)
        if amount.rounded > balance {
            return "Recovery of \(amount.formatted) exceeds the outstanding balance of \(balance.formatted)."
        }
        return nil
    }
}
