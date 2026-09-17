import Foundation

// =============================================================================
//  SettlementLedger — every settlement-related record for one account
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). A plain value type that holds the settlement
//  headers plus every child row. Both stores produce one of these:
//
//   - Free Local Mode: `SettlementLocalStore` reads/writes it as a single JSON
//     file in `Documents/DriverHub/settlements_v1.json` (atomic write).
//   - Cloud Pro:       `SettlementCloudStore` assembles it from the Supabase
//     tables created by migration 20260912120000.
//
//  All business rules (`SettlementWorkflowService`, `SettlementInsights`) run
//  against this type, so the rules are identical in both modes and are unit
//  tested without a database.
// =============================================================================

struct SettlementLedger: Codable {

    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var settlements: [Settlement]
    var loadLines: [SettlementLoadLine]
    var additions: [SettlementAddition]
    var deductions: [SettlementDeduction]
    var recurringDeductions: [RecurringDeduction]
    var advances: [DriverAdvance]
    var advanceRepayments: [DriverAdvanceRepayment]
    var auditEvents: [SettlementAuditEvent]
    /// Free Local Mode only. There is no `drivers` table on the device, so the
    /// drivers a local user pays are kept with the ledger. Always empty in
    /// Cloud Pro, where drivers come from Supabase.
    var localDrivers: [Driver]
    /// Document attachments to settlement objects (local mode keeps them
    /// here; cloud mode mirrors the `documents.settlement_id/...` columns).
    var documentLinks: [SettlementDocumentLink]

    init(
        schemaVersion: Int = SettlementLedger.currentSchemaVersion,
        settlements: [Settlement] = [],
        loadLines: [SettlementLoadLine] = [],
        additions: [SettlementAddition] = [],
        deductions: [SettlementDeduction] = [],
        recurringDeductions: [RecurringDeduction] = [],
        advances: [DriverAdvance] = [],
        advanceRepayments: [DriverAdvanceRepayment] = [],
        auditEvents: [SettlementAuditEvent] = [],
        localDrivers: [Driver] = [],
        documentLinks: [SettlementDocumentLink] = []
    ) {
        self.schemaVersion = schemaVersion
        self.settlements = settlements
        self.loadLines = loadLines
        self.additions = additions
        self.deductions = deductions
        self.recurringDeductions = recurringDeductions
        self.advances = advances
        self.advanceRepayments = advanceRepayments
        self.auditEvents = auditEvents
        self.localDrivers = localDrivers
        self.documentLinks = documentLinks
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case settlements
        case loadLines = "load_lines"
        case additions, deductions
        case recurringDeductions = "recurring_deductions"
        case advances
        case advanceRepayments = "advance_repayments"
        case auditEvents = "audit_events"
        case localDrivers = "local_drivers"
        case documentLinks = "document_links"
    }

    /// Tolerant decode: a key missing from an older file reads as empty rather
    /// than failing the whole ledger (which would look like data loss).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion       = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        settlements         = try c.decodeIfPresent([Settlement].self, forKey: .settlements) ?? []
        loadLines           = try c.decodeIfPresent([SettlementLoadLine].self, forKey: .loadLines) ?? []
        additions           = try c.decodeIfPresent([SettlementAddition].self, forKey: .additions) ?? []
        deductions          = try c.decodeIfPresent([SettlementDeduction].self, forKey: .deductions) ?? []
        recurringDeductions = try c.decodeIfPresent([RecurringDeduction].self, forKey: .recurringDeductions) ?? []
        advances            = try c.decodeIfPresent([DriverAdvance].self, forKey: .advances) ?? []
        advanceRepayments   = try c.decodeIfPresent([DriverAdvanceRepayment].self, forKey: .advanceRepayments) ?? []
        auditEvents         = try c.decodeIfPresent([SettlementAuditEvent].self, forKey: .auditEvents) ?? []
        localDrivers        = try c.decodeIfPresent([Driver].self, forKey: .localDrivers) ?? []
        documentLinks       = try c.decodeIfPresent([SettlementDocumentLink].self, forKey: .documentLinks) ?? []
    }

    static let empty = SettlementLedger()

    // MARK: - Lookups

    func settlement(id: UUID) -> Settlement? {
        settlements.first { $0.id == id }
    }

    func bundle(for settlementId: UUID) -> SettlementBundle? {
        guard let header = settlement(id: settlementId) else { return nil }
        return SettlementBundle(
            settlement: header,
            loadLines: loadLines.filter { $0.settlementId == settlementId }
                .sorted { $0.sortOrder < $1.sortOrder },
            additions: additions.filter { $0.settlementId == settlementId }
                .sorted { $0.sortOrder < $1.sortOrder },
            deductions: deductions.filter { $0.settlementId == settlementId }
                .sorted { $0.sortOrder < $1.sortOrder },
            auditEvents: SettlementAuditService.sorted(
                auditEvents.filter { $0.settlementId == settlementId }
            ),
            documentLinks: documentLinks.filter { $0.settlementId == settlementId }
        )
    }

    /// Settlements that are real financial history (approved or paid, never
    /// an estimate).
    var financialSettlements: [Settlement] {
        settlements.filter { $0.settlementStatus.isFinancialRecord && !$0.isEstimateRecord }
    }

    /// load id → the settlement that already paid it. Only approved/paid,
    /// non-estimate settlements count, and correction lines are ignored so an
    /// approved adjustment does not look like the original payment.
    func alreadySettledLoadIds(excluding settlementId: UUID? = nil) -> [UUID: UUID] {
        let paying = Set(financialSettlements.compactMap(\.id))
        var out: [UUID: UUID] = [:]
        for line in loadLines {
            guard let loadId = line.loadId,
                  let sid = line.settlementId,
                  sid != settlementId,
                  paying.contains(sid),
                  !line.isAdjustment else { continue }
            out[loadId] = sid
        }
        return out
    }

    /// expense id → settlement that already carried it as a deduction.
    func alreadyLinkedExpenseIds(excluding settlementId: UUID? = nil) -> [UUID: UUID] {
        let live = Set(settlements
            .filter { $0.settlementStatus != .voided && !$0.isEstimateRecord }
            .compactMap(\.id))
        var out: [UUID: UUID] = [:]
        for d in deductions {
            guard let expenseId = d.relatedExpenseId,
                  let sid = d.settlementId,
                  sid != settlementId,
                  live.contains(sid) else { continue }
            out[expenseId] = sid
        }
        return out
    }

    var settlementNumbers: [String] {
        settlements.compactMap(\.settlementNumber)
    }

    var settlementNumbersById: [UUID: String] {
        settlements.reduce(into: [:]) { acc, s in
            if let id = s.id, let n = s.settlementNumber { acc[id] = n }
        }
    }

    /// Recurring rule id → period start of the last financial settlement that
    /// carried it (drives monthly / biweekly frequency checks).
    func lastAppliedRecurringDates() -> [UUID: Date] {
        var statuses: [UUID: SettlementStatus] = [:]
        var starts: [UUID: Date] = [:]
        for s in settlements where !s.isEstimateRecord {
            guard let id = s.id else { continue }
            statuses[id] = s.settlementStatus
            if let start = s.settlementPeriodStart { starts[id] = start }
        }
        return RecurringDeductionService.lastAppliedDates(
            deductions: deductions,
            settlementPeriodStarts: starts,
            settlementStatuses: statuses
        )
    }

    func advances(forDriver driverId: UUID) -> [DriverAdvance] {
        advances
            .filter { $0.driverId == driverId }
            .map { DriverAdvanceService.reconciled(advance: $0, repayments: advanceRepayments) }
            .sorted { $0.date > $1.date }
    }

    func outstandingAdvanceBalance(forDriver driverId: UUID) -> Money {
        DriverAdvanceService.totalOutstanding(
            advances: advances, repayments: advanceRepayments, driverId: driverId
        )
    }

    func recurringDeductions(forDriver driverId: UUID) -> [RecurringDeduction] {
        recurringDeductions
            .filter { $0.driverId == driverId }
            .sorted { $0.descriptionText < $1.descriptionText }
    }

    // MARK: - Mutation helpers

    /// Replaces a settlement and all of its child rows. Audit rows are never
    /// replaced — use `appendAudit`.
    mutating func replace(bundle: SettlementBundle) {
        guard let sid = bundle.settlement.id else { return }
        if let idx = settlements.firstIndex(where: { $0.id == sid }) {
            settlements[idx] = bundle.settlement
        } else {
            settlements.append(bundle.settlement)
        }
        loadLines.removeAll { $0.settlementId == sid }
        loadLines.append(contentsOf: bundle.loadLines)
        additions.removeAll { $0.settlementId == sid }
        additions.append(contentsOf: bundle.additions)
        deductions.removeAll { $0.settlementId == sid }
        deductions.append(contentsOf: bundle.deductions)
        documentLinks.removeAll { $0.settlementId == sid }
        documentLinks.append(contentsOf: bundle.documentLinks)
    }

    mutating func updateHeader(_ settlement: Settlement) {
        guard let sid = settlement.id,
              let idx = settlements.firstIndex(where: { $0.id == sid }) else { return }
        settlements[idx] = settlement
    }

    mutating func appendAudit(_ events: [SettlementAuditEvent]) {
        auditEvents.append(contentsOf: events)
    }

    mutating func upsert(recurring rule: RecurringDeduction) {
        if let idx = recurringDeductions.firstIndex(where: { $0.id == rule.id }) {
            recurringDeductions[idx] = rule
        } else {
            recurringDeductions.append(rule)
        }
    }

    mutating func upsert(advance: DriverAdvance) {
        if let idx = advances.firstIndex(where: { $0.id == advance.id }) {
            advances[idx] = advance
        } else {
            advances.append(advance)
        }
    }

    mutating func upsert(localDriver: Driver) {
        guard let id = localDriver.id else { return }
        if let idx = localDrivers.firstIndex(where: { $0.id == id }) {
            localDrivers[idx] = localDriver
        } else {
            localDrivers.append(localDriver)
        }
    }

    /// Rebuilds every advance's cached `recoveredAmount` / `isClosed` from the
    /// repayment ledger. Called after any repayment change.
    mutating func reconcileAdvances() {
        advances = advances.map {
            DriverAdvanceService.reconciled(advance: $0, repayments: advanceRepayments)
        }
    }
}

// MARK: - Bundle

/// One settlement with its child rows — the unit the review screen edits and
/// the stores save.
struct SettlementBundle: Identifiable {
    var settlement: Settlement
    var loadLines: [SettlementLoadLine]
    var additions: [SettlementAddition]
    var deductions: [SettlementDeduction]
    var auditEvents: [SettlementAuditEvent]
    var documentLinks: [SettlementDocumentLink]

    init(
        settlement: Settlement,
        loadLines: [SettlementLoadLine] = [],
        additions: [SettlementAddition] = [],
        deductions: [SettlementDeduction] = [],
        auditEvents: [SettlementAuditEvent] = [],
        documentLinks: [SettlementDocumentLink] = []
    ) {
        self.settlement = settlement
        self.loadLines = loadLines
        self.additions = additions
        self.deductions = deductions
        self.auditEvents = auditEvents
        self.documentLinks = documentLinks
    }

    var id: UUID { settlement.id ?? UUID() }

    /// Engine input rebuilt purely from what is stored on the settlement —
    /// no driver or company defaults are consulted, so a stored settlement
    /// always recalculates to the same figures.
    var calculationInput: SettlementCalculationInput {
        let rule = settlement.effectivePayRule
        return SettlementCalculationInput(
            settlementType: settlement.effectiveSettlementType,
            payRule: rule,
            payOnGrossRevenue: settlement.payOnGrossRevenue ?? true,
            loadLines: loadLines,
            additions: additions,
            deductions: deductions,
            hoursWorked: settlement.hoursWorked,
            companyFees: rule.feeTerms ?? .none,
            isEstimate: settlement.isEstimateRecord
        )
    }

    func calculate() -> SettlementCalculationResult {
        SettlementCalculationEngine.calculate(calculationInput)
    }

    /// Calculation for DISPLAY (screens, statements). Paid/voided history, and
    /// any copy redacted for a driver, shows the load earnings frozen at the
    /// last recalculation. Editing and validation always use `calculate()`.
    func calculate(frozenLoadEarnings: Bool) -> SettlementCalculationResult {
        var input = calculationInput
        input.frozenLoadEarnings = frozenLoadEarnings && !settlement.isEstimateRecord
        return SettlementCalculationEngine.calculate(input)
    }

    var displayCalculation: SettlementCalculationResult {
        calculate(frozenLoadEarnings: settlement.isLocked)
    }
}

// MARK: - Documents

enum SettlementDocumentCategory: String, Codable, CaseIterable, Identifiable {
    case rateConfirmation = "rate_confirmation"
    case bol
    case pod
    case fuelReceipt = "fuel_receipt"
    case lumperReceipt = "lumper_receipt"
    case scaleTicket = "scale_ticket"
    case tollReceipt = "toll_receipt"
    case repairInvoice = "repair_invoice"
    case maintenanceInvoice = "maintenance_invoice"
    case insurance
    case leaseAgreement = "lease_agreement"
    case settlementPDF = "settlement"
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rateConfirmation:   return "Rate Confirmation"
        case .bol:                return "BOL"
        case .pod:                return "POD"
        case .fuelReceipt:        return "Fuel Receipt"
        case .lumperReceipt:      return "Lumper Receipt"
        case .scaleTicket:        return "Scale Ticket"
        case .tollReceipt:        return "Toll Receipt"
        case .repairInvoice:      return "Repair Invoice"
        case .maintenanceInvoice: return "Maintenance Invoice"
        case .insurance:          return "Insurance"
        case .leaseAgreement:     return "Lease Agreement"
        case .settlementPDF:      return "Settlement PDF"
        case .other:              return "Other"
        }
    }

    /// Maps the free-text `documents.document_type` values the scanner and
    /// vault already write onto a category. Unknown values read as `.other`.
    init(documentType raw: String?) {
        let v = (raw ?? "").lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch v {
        case "rate_confirmation", "rate_con", "ratecon", "rate_confirmation_pdf": self = .rateConfirmation
        case "bol", "bill_of_lading":                   self = .bol
        case "pod", "proof_of_delivery":                self = .pod
        case "fuel_receipt", "fuel":                    self = .fuelReceipt
        case "lumper_receipt", "lumper", "lumper_fee":  self = .lumperReceipt
        case "scale_ticket", "scale":                   self = .scaleTicket
        case "toll_receipt", "toll", "tolls":           self = .tollReceipt
        case "repair_invoice", "repair":                self = .repairInvoice
        case "maintenance_invoice", "maintenance":      self = .maintenanceInvoice
        case "insurance":                               self = .insurance
        case "lease_agreement", "lease":                self = .leaseAgreement
        case "settlement", "paystub", "settlement_pdf": self = .settlementPDF
        default:                                        self = .other
        }
    }
}

/// What a document is attached to.
enum SettlementDocumentTarget: String, Codable, CaseIterable {
    case load
    case settlement
    case addition
    case deduction
    case advance
    case expense
}

/// Link between an existing document row (the vault / scanner owns the file)
/// and a settlement object. No file bytes are duplicated.
struct SettlementDocumentLink: Codable, Hashable, Identifiable {
    var id: UUID
    var profileId: UUID
    var documentId: UUID
    var settlementId: UUID?
    var target: SettlementDocumentTarget
    /// The id of the load / addition / deduction / advance / expense.
    var targetId: UUID
    var category: SettlementDocumentCategory
    var title: String?
    var createdAt: Date?

    init(
        id: UUID = UUID(),
        profileId: UUID,
        documentId: UUID,
        settlementId: UUID? = nil,
        target: SettlementDocumentTarget,
        targetId: UUID,
        category: SettlementDocumentCategory,
        title: String? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.documentId = documentId
        self.settlementId = settlementId
        self.target = target
        self.targetId = targetId
        self.category = category
        self.title = title
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, target, category, title
        case profileId = "profile_id"
        case documentId = "document_id"
        case settlementId = "settlement_id"
        case targetId = "target_id"
        case createdAt = "created_at"
    }
}
