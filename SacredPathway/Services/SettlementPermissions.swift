import Foundation

// =============================================================================
//  SettlementPermissions — who may see and do what
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). Built on the app's existing `AccountRole`
//  (profiles.account_role) and the live `carrier_members` table
//  (role = 'driver' | 'admin', linked_driver_id). No new role table.
//
//    Role        Maps from                                  Can
//    ─────────   ─────────────────────────────────────────  ──────────────────
//    owner       carrier, owner_operator, Free Local Mode    everything
//    manager     dispatcher                                  prepare drafts
//    accounting  (reserved for carrier_members 'admin')      review, approve,
//                                                            mark paid, export
//    driver      driver                                      view OWN approved
//                                                            / paid settlements
//
//  Server side, Supabase RLS is the real boundary (profile_id = auth.uid(),
//  plus the driver read policy in migration 20260916120000). These checks
//  make the UI honest and are covered by unit tests; they are not a
//  substitute for RLS.
// =============================================================================

enum SettlementRole: String, CaseIterable, Identifiable {
    case owner
    case manager
    case accounting
    case driver

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .owner:      return "Owner / Admin"
        case .manager:    return "Dispatch / Manager"
        case .accounting: return "Accounting"
        case .driver:     return "Driver"
        }
    }

    /// Maps the existing account model onto a settlement role.
    static func resolve(
        accountRole: AccountRole?,
        isLocalMode: Bool,
        membershipRole: String? = nil
    ) -> SettlementRole {
        if isLocalMode { return .owner }
        if let membershipRole {
            switch membershipRole.lowercased() {
            case "admin":      return .accounting
            case "driver":     return .driver
            default:           break
            }
        }
        switch accountRole {
        case .carrier, .ownerOperator, .none: return .owner
        case .dispatcher:                     return .manager
        case .driver:                         return .driver
        }
    }
}

struct SettlementCapabilities: OptionSet, Hashable {
    let rawValue: Int

    static let viewAllSettlements     = SettlementCapabilities(rawValue: 1 << 0)
    static let viewOwnSettlements     = SettlementCapabilities(rawValue: 1 << 1)
    static let createDraft            = SettlementCapabilities(rawValue: 1 << 2)
    static let editDraft              = SettlementCapabilities(rawValue: 1 << 3)
    static let submitForReview        = SettlementCapabilities(rawValue: 1 << 4)
    static let approve                = SettlementCapabilities(rawValue: 1 << 5)
    static let markPaid               = SettlementCapabilities(rawValue: 1 << 6)
    static let void                   = SettlementCapabilities(rawValue: 1 << 7)
    static let reopen                 = SettlementCapabilities(rawValue: 1 << 8)
    static let export                 = SettlementCapabilities(rawValue: 1 << 9)
    static let managePaySettings      = SettlementCapabilities(rawValue: 1 << 10)
    static let manageRecurring        = SettlementCapabilities(rawValue: 1 << 11)
    static let manageAdvances         = SettlementCapabilities(rawValue: 1 << 12)
    static let viewCompanyFinancials  = SettlementCapabilities(rawValue: 1 << 13)
    static let viewAuditTrail         = SettlementCapabilities(rawValue: 1 << 14)
    static let viewEstimates          = SettlementCapabilities(rawValue: 1 << 15)

    static let all: SettlementCapabilities = [
        .viewAllSettlements, .createDraft, .editDraft, .submitForReview, .approve,
        .markPaid, .void, .reopen, .export, .managePaySettings, .manageRecurring,
        .manageAdvances, .viewCompanyFinancials, .viewAuditTrail, .viewEstimates
    ]
}

/// The person looking at settlement data.
struct SettlementViewer: Hashable {
    var role: SettlementRole
    var userId: UUID?
    /// For a driver: the `drivers.id` rows this user is linked to through
    /// `carrier_members.linked_driver_id`. Empty = sees nothing.
    var linkedDriverIds: Set<UUID>
    /// Carrier setting — may drivers see their live estimate?
    var driversMaySeeEstimates: Bool

    init(
        role: SettlementRole,
        userId: UUID? = nil,
        linkedDriverIds: Set<UUID> = [],
        driversMaySeeEstimates: Bool = false
    ) {
        self.role = role
        self.userId = userId
        self.linkedDriverIds = linkedDriverIds
        self.driversMaySeeEstimates = driversMaySeeEstimates
    }

    var capabilities: SettlementCapabilities {
        SettlementPermissions.capabilities(for: role, driversMaySeeEstimates: driversMaySeeEstimates)
    }

    func can(_ capability: SettlementCapabilities) -> Bool {
        capabilities.contains(capability)
    }
}

enum SettlementPermissions {

    static func capabilities(
        for role: SettlementRole,
        driversMaySeeEstimates: Bool = false
    ) -> SettlementCapabilities {
        switch role {
        case .owner:
            return .all
        case .manager:
            return [.viewAllSettlements, .createDraft, .editDraft, .submitForReview,
                    .manageRecurring, .manageAdvances, .viewEstimates, .viewAuditTrail]
        case .accounting:
            return [.viewAllSettlements, .submitForReview, .approve, .markPaid, .export,
                    .viewCompanyFinancials, .viewAuditTrail, .viewEstimates]
        case .driver:
            var caps: SettlementCapabilities = [.viewOwnSettlements, .export]
            if driversMaySeeEstimates { caps.insert(.viewEstimates) }
            return caps
        }
    }

    /// Capability required to move a settlement into `target`.
    static func requiredCapability(
        from current: SettlementStatus,
        to target: SettlementStatus
    ) -> SettlementCapabilities {
        if current.isLocked && !target.isLocked { return .reopen }
        switch target {
        case .readyForReview: return .submitForReview
        case .approved:       return current == .paid ? .reopen : .approve
        case .paid:           return .markPaid
        case .voided:         return .void
        case .draft:          return current == .approved ? .reopen : .editDraft
        }
    }

    static func canTransition(
        _ viewer: SettlementViewer,
        from current: SettlementStatus,
        to target: SettlementStatus
    ) -> Bool {
        viewer.can(requiredCapability(from: current, to: target))
    }

    /// Can this viewer open this settlement at all?
    static func canView(_ settlement: Settlement, viewer: SettlementViewer) -> Bool {
        if viewer.can(.viewAllSettlements) { return true }
        guard viewer.can(.viewOwnSettlements),
              let driverId = settlement.driverId,
              viewer.linkedDriverIds.contains(driverId) else { return false }
        if settlement.isEstimateRecord { return viewer.can(.viewEstimates) }
        // Drivers see finalized money only — never a draft being prepared.
        return settlement.settlementStatus == .approved || settlement.settlementStatus == .paid
    }

    static func canEdit(_ settlement: Settlement, viewer: SettlementViewer) -> Bool {
        guard viewer.can(.editDraft), !settlement.isLocked else { return false }
        // Approved settlements are editable only by someone who can approve
        // again (editing drops them back to draft).
        if settlement.settlementStatus == .approved { return viewer.can(.approve) }
        return true
    }

    static func visibleSettlements(
        _ settlements: [Settlement],
        viewer: SettlementViewer
    ) -> [Settlement] {
        settlements.filter { canView($0, viewer: viewer) }
    }

    /// The driver-facing copy of a settlement: company-side figures, company
    /// expense lines and the internal audit trail are removed. Driver-paid
    /// deduction amounts are kept (they are on the driver's statement).
    static func redactedForDriver(_ bundle: SettlementBundle) -> SettlementBundle {
        var copy = bundle
        copy.settlement.companyRetained = nil
        copy.settlement.companyExpenses = nil
        copy.settlement.totalExpenses = nil
        copy.settlement.grossProfit = nil
        copy.settlement.createdByUserId = nil
        copy.settlement.approvedByUserId = nil
        copy.settlement.notes = nil
        copy.auditEvents = []
        // A company-paid line never touched the driver's check.
        copy.deductions = bundle.deductions.filter { $0.effectiveDriverPercent > 0 }
        return copy
    }

    /// A ledger containing only what this viewer may see.
    static func scopedLedger(_ ledger: SettlementLedger, viewer: SettlementViewer) -> SettlementLedger {
        if viewer.can(.viewAllSettlements) { return ledger }
        let visible = visibleSettlements(ledger.settlements, viewer: viewer)
        let ids = Set(visible.compactMap(\.id))
        var out = SettlementLedger()
        out.settlements = visible.map {
            var s = $0
            s.companyRetained = nil
            s.companyExpenses = nil
            s.totalExpenses = nil
            s.grossProfit = nil
            s.notes = nil
            return s
        }
        out.loadLines = ledger.loadLines.filter { $0.settlementId.map(ids.contains) ?? false }
        out.additions = ledger.additions.filter { $0.settlementId.map(ids.contains) ?? false }
        out.deductions = ledger.deductions.filter {
            ($0.settlementId.map(ids.contains) ?? false) && $0.effectiveDriverPercent > 0
        }
        out.advances = ledger.advances.filter { viewer.linkedDriverIds.contains($0.driverId) }
        let advanceIds = Set(out.advances.map(\.id))
        out.advanceRepayments = ledger.advanceRepayments.filter { advanceIds.contains($0.advanceId) }
        out.documentLinks = ledger.documentLinks.filter { $0.settlementId.map(ids.contains) ?? false }
        return out
    }
}
