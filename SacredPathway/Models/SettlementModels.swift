import Foundation

// =============================================================================
//  SettlementModels — Driver Pay & Settlements record types
// -----------------------------------------------------------------------------
//  Every type here is a plain Codable value type with snake_case coding keys
//  that match the Supabase columns created in
//  `supabase/migrations/20260912_*_settlements.sql`. The same encoding is what
//  LocalStore writes to `Documents/DriverHub/*.json`, so Free Local Mode and
//  Cloud Pro store byte-identical rows and a future local -> cloud migration is
//  a straight upload.
//
//  Money fields use `Money` (Decimal). Mileage, hours and percentages use
//  `Decimal`. There is no `Double` in this file on purpose.
// =============================================================================

// MARK: - Defensive decoding

/// A `String` field that tolerates NULL or a missing key and reads as "".
/// Used where a Supabase column is nullable but the app only ever writes a
/// string: without this, one NULL row makes the whole array decode throw and
/// the settlement ledger fails to load (defect D1). Encoding is unchanged —
/// the value is always written as a plain string, never null.
@propertyWrapper
struct DefaultEmptyString: Codable, Hashable {
    var wrappedValue: String

    init(wrappedValue: String) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = (try? container.decode(String.self)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// Missing key or JSON null both decode to "" instead of throwing.
    func decode(
        _ type: DefaultEmptyString.Type,
        forKey key: Key
    ) throws -> DefaultEmptyString {
        try decodeIfPresent(type, forKey: key)
            ?? DefaultEmptyString(wrappedValue: "")
    }
}

// MARK: - Status

/// Lifecycle of a settlement. A settlement only ever moves forward except
/// through an explicit, audited reopen.
enum SettlementStatus: String, Codable, CaseIterable, Identifiable {
    case draft
    case readyForReview = "ready_for_review"
    case approved
    case paid
    case voided

    var id: String { rawValue }

    // nonisolated: read by `SettlementWorkflowError.errorDescription`
    // (LocalizedError requirements are nonisolated under the 2.3.3 Swift 6 /
    // default-MainActor build settings).
    nonisolated var displayName: String {
        switch self {
        case .draft:          return "Draft"
        case .readyForReview: return "Ready for Review"
        case .approved:       return "Approved"
        case .paid:           return "Paid"
        case .voided:         return "Voided"
        }
    }

    /// Paid and Voided settlements are financial history. They cannot be
    /// edited in place — the user must reopen (audited) or record a separate
    /// adjustment settlement.
    var isLocked: Bool { self == .paid || self == .voided }

    /// Only these states count toward "money actually owed / paid out".
    var isFinancialRecord: Bool { self == .approved || self == .paid }

    /// Statuses reachable directly from this one.
    var allowedTransitions: [SettlementStatus] {
        switch self {
        case .draft:          return [.readyForReview, .approved, .voided]
        case .readyForReview: return [.draft, .approved, .voided]
        case .approved:       return [.paid, .draft, .voided]
        case .paid:           return [.approved, .voided]   // via explicit reopen
        case .voided:         return [.draft]               // via explicit reopen
        }
    }

    var systemImage: String {
        switch self {
        case .draft:          return "pencil.circle"
        case .readyForReview: return "eye.circle"
        case .approved:       return "checkmark.seal"
        case .paid:           return "dollarsign.circle.fill"
        case .voided:         return "xmark.circle"
        }
    }
}

// MARK: - Settlement type

enum SettlementType: String, Codable, CaseIterable, Identifiable {
    case companyDriver  = "company_driver"
    case leaseOperator  = "lease_operator"
    case ownerOperator  = "owner_operator"
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .companyDriver: return "Company Driver"
        case .leaseOperator: return "Lease Operator"
        case .ownerOperator: return "Owner Operator"
        case .custom:        return "Custom"
        }
    }

    /// Lease and owner operators normally carry their own truck, fuel and
    /// maintenance costs. This is only the STARTING point for a new driver —
    /// every responsibility is individually configurable per driver.
    var defaultDriverResponsibilities: [SettlementDeductionCategory] {
        switch self {
        case .companyDriver:
            return [.cashAdvance, .fuelAdvance, .violation, .damage]
        case .leaseOperator:
            return [.truckLease, .insurance, .fuel, .fuelAdvance, .cashAdvance,
                    .maintenance, .repair, .escrow, .tolls, .permits,
                    .violation, .damage, .trailerCharge]
        case .ownerOperator:
            return [.fuel, .fuelAdvance, .cashAdvance, .maintenance, .repair,
                    .tolls, .scaleTickets, .permits, .violation, .damage]
        case .custom:
            return []
        }
    }
}

// MARK: - Pay methods

enum PayMethodKind: String, Codable, CaseIterable, Identifiable {
    case percentOfGross = "percent_of_gross"
    case flatPerLoad    = "flat_per_load"
    case perMile        = "per_mile"
    case weeklySalary   = "weekly_salary"
    case hourly
    case manual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .percentOfGross: return "Percentage of Gross"
        case .flatPerLoad:    return "Flat Amount per Load"
        case .perMile:        return "Per Mile"
        case .weeklySalary:   return "Weekly Salary"
        case .hourly:         return "Hourly"
        case .manual:         return "Custom Manual Pay"
        }
    }

    /// True when the component earns money once per LOAD; false when it earns
    /// once per SETTLEMENT regardless of how many loads are on it.
    var isPerLoad: Bool {
        switch self {
        case .percentOfGross, .flatPerLoad, .perMile: return true
        case .weeklySalary, .hourly, .manual:         return false
        }
    }
}

/// Which mileage number a per-mile component is paid on.
enum MileBasis: String, Codable, CaseIterable, Identifiable {
    case loaded
    case total          // loaded + deadhead
    case deadhead       // deadhead-only accessorial pay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .loaded:   return "Loaded Miles"
        case .total:    return "All Miles"
        case .deadhead: return "Deadhead Miles"
        }
    }
}

/// One earning rule. A driver paid "70% of gross plus $0.05/mi safety" has two
/// components; most drivers have exactly one.
struct PayComponent: Codable, Hashable, Identifiable {
    var id: UUID
    var kind: PayMethodKind
    var label: String
    /// percentOfGross: 70 means 70%.
    var percent: Decimal?
    /// perMile: rate per mile. flatPerLoad / weeklySalary / hourly: the rate.
    var rate: Money?
    var mileBasis: MileBasis
    /// manual: an explicit dollar amount the user typed.
    var fixedAmount: Money?
    /// hourly: hours for this settlement period. Nil falls back to the
    /// settlement-level `hoursWorked`.
    var hours: Decimal?

    init(
        id: UUID = UUID(),
        kind: PayMethodKind,
        label: String? = nil,
        percent: Decimal? = nil,
        rate: Money? = nil,
        mileBasis: MileBasis = .loaded,
        fixedAmount: Money? = nil,
        hours: Decimal? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label ?? kind.displayName
        self.percent = percent
        self.rate = rate
        self.mileBasis = mileBasis
        self.fixedAmount = fixedAmount
        self.hours = hours
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, label, percent, rate, hours
        case mileBasis = "mile_basis"
        case fixedAmount = "fixed_amount"
    }

    // Explicit coding (2026-09-16): `Money` encodes rounded to cents, which
    // would silently turn a $0.585/mi rate into $0.59/mi on save. A RATE is
    // not a printed dollar total, so it is stored at full precision.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind        = try c.decode(PayMethodKind.self, forKey: .kind)
        label       = try c.decodeIfPresent(String.self, forKey: .label) ?? kind.displayName
        percent     = try c.decodeIfPresent(Decimal.self, forKey: .percent)
        rate        = try c.decodeIfPresent(Money.self, forKey: .rate)
        mileBasis   = try c.decodeIfPresent(MileBasis.self, forKey: .mileBasis) ?? .loaded
        fixedAmount = try c.decodeIfPresent(Money.self, forKey: .fixedAmount)
        hours       = try c.decodeIfPresent(Decimal.self, forKey: .hours)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(percent, forKey: .percent)
        try c.encodeIfPresent(rate.map { Money.round($0.amount, scale: 6) }, forKey: .rate)
        try c.encode(mileBasis, forKey: .mileBasis)
        try c.encodeIfPresent(fixedAmount, forKey: .fixedAmount)
        try c.encodeIfPresent(hours, forKey: .hours)
    }

    /// Human-readable basis that prints on the statement next to the amount.
    var basisDescription: String {
        switch kind {
        case .percentOfGross:
            return "\((percent ?? 0).asPercentString) of gross"
        case .flatPerLoad:
            return "\((rate ?? .zero).formatted) per load"
        case .perMile:
            return "\((rate ?? .zero).rounded(scale: 3).formatted)/mi \(mileBasis.displayName.lowercased())"
        case .weeklySalary:
            return "\((rate ?? .zero).formatted) salary"
        case .hourly:
            return "\((rate ?? .zero).formatted)/hr"
        case .manual:
            return "Manual entry"
        }
    }
}

/// The full pay arrangement. Empty components means "no automatic pay" — the
/// user must enter a manual amount, and validation will say so.
struct PayRule: Codable, Hashable {
    var components: [PayComponent]
    /// Company fee terms (dispatcher %, factoring %, authority, maintenance
    /// reserve and who pays each) frozen with the settlement so a later change
    /// to the company defaults can never re-price a settled week. Nil on rules
    /// saved before 2026-09-16 and on per-load overrides.
    var feeTerms: CompanyFeeSettings?

    init(components: [PayComponent] = [], feeTerms: CompanyFeeSettings? = nil) {
        self.components = components
        self.feeTerms = feeTerms
    }

    enum CodingKeys: String, CodingKey {
        case components
        case feeTerms = "fee_terms"
    }

    var isEmpty: Bool { components.isEmpty }
    var isCombination: Bool { components.count > 1 }
    var primaryKind: PayMethodKind? { components.first?.kind }

    /// "70% of gross", "$0.58/mi loaded miles", "70% of gross + $0.05/mi ..."
    var summary: String {
        guard !components.isEmpty else { return "No pay rule set" }
        return components.map(\.basisDescription).joined(separator: " + ")
    }

    // Convenience constructors — these are what the UI and the driver defaults use.

    static func percentOfGross(_ percent: Decimal) -> PayRule {
        PayRule(components: [PayComponent(kind: .percentOfGross, percent: percent)])
    }

    static func flatPerLoad(_ amount: Money) -> PayRule {
        PayRule(components: [PayComponent(kind: .flatPerLoad, rate: amount)])
    }

    static func perMile(_ rate: Money, basis: MileBasis = .loaded) -> PayRule {
        PayRule(components: [PayComponent(kind: .perMile, rate: rate, mileBasis: basis)])
    }

    static func weeklySalary(_ amount: Money) -> PayRule {
        PayRule(components: [PayComponent(kind: .weeklySalary, rate: amount)])
    }

    static func hourly(_ rate: Money, hours: Decimal? = nil) -> PayRule {
        PayRule(components: [PayComponent(kind: .hourly, rate: rate, hours: hours)])
    }

    static func manual(_ amount: Money) -> PayRule {
        PayRule(components: [PayComponent(kind: .manual, fixedAmount: amount)])
    }

    static let none = PayRule()

    /// True when both rules pay the same way. Component ids and labels are
    /// ignored — they are identity, not terms — so a rule rebuilt from the
    /// same numbers is not reported as a pay change.
    func hasSameTerms(as other: PayRule) -> Bool {
        func terms(_ r: PayRule) -> [String] {
            r.components.map { c in
                [c.kind.rawValue,
                 c.percent.map { "\($0)" } ?? "-",
                 c.rate.map { "\($0.amount)" } ?? "-",
                 c.mileBasis.rawValue,
                 c.fixedAmount.map { "\($0.rounded.amount)" } ?? "-",
                 c.hours.map { "\($0)" } ?? "-"].joined(separator: "|")
            }
        }
        return terms(self) == terms(other) && feeTerms == other.feeTerms
    }
}

// MARK: - Additions

enum SettlementAdditionCategory: String, Codable, CaseIterable, Identifiable {
    case bonus
    case detention
    case layover
    case tonu
    case lumperReimbursement = "lumper_reimbursement"
    case reimbursement
    case fuelCredit       = "fuel_credit"
    case maintenanceCredit = "maintenance_credit"
    case safetyBonus      = "safety_bonus"
    case referralBonus    = "referral_bonus"
    case manualCredit     = "manual_credit"
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bonus:              return "Bonus"
        case .detention:          return "Detention"
        case .layover:            return "Layover"
        case .tonu:               return "TONU"
        case .lumperReimbursement:return "Lumper Reimbursement"
        case .reimbursement:      return "Reimbursement"
        case .fuelCredit:         return "Fuel Credit"
        case .maintenanceCredit:  return "Maintenance Credit"
        case .safetyBonus:        return "Safety Bonus"
        case .referralBonus:      return "Referral Bonus"
        case .manualCredit:       return "Manual Credit"
        case .other:              return "Other"
        }
    }
}

/// A credit that increases what the driver is paid.
struct SettlementAddition: Codable, Hashable, Identifiable {
    var id: UUID
    var settlementId: UUID?
    var profileId: UUID
    var category: SettlementAdditionCategory
    var descriptionText: String
    var amount: Money
    var date: Date?
    var relatedLoadId: UUID?
    var documentId: UUID?
    var notes: String?
    var sortOrder: Int
    var createdAt: Date?

    init(
        id: UUID = UUID(),
        settlementId: UUID? = nil,
        profileId: UUID,
        category: SettlementAdditionCategory,
        descriptionText: String,
        amount: Money,
        date: Date? = nil,
        relatedLoadId: UUID? = nil,
        documentId: UUID? = nil,
        notes: String? = nil,
        sortOrder: Int = 0,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.settlementId = settlementId
        self.profileId = profileId
        self.category = category
        self.descriptionText = descriptionText
        self.amount = amount
        self.date = date
        self.relatedLoadId = relatedLoadId
        self.documentId = documentId
        self.notes = notes
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, category, amount, date, notes
        case settlementId = "settlement_id"
        case profileId = "profile_id"
        case descriptionText = "description"
        case relatedLoadId = "related_load_id"
        case documentId = "document_id"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }
}

// MARK: - Deductions

enum SettlementDeductionCategory: String, Codable, CaseIterable, Identifiable {
    case truckLease        = "truck_lease"
    case insurance
    case fuel
    case fuelAdvance       = "fuel_advance"
    case cashAdvance       = "cash_advance"
    case maintenance
    case repair
    case escrow
    case maintenanceReserve = "maintenance_reserve"
    case tolls
    case scaleTickets      = "scale_tickets"
    case permits
    case violation
    case damage
    case trailerCharge     = "trailer_charge"
    case equipmentCharge   = "equipment_charge"
    case dispatcherFee     = "dispatcher_fee"
    case factoringFee      = "factoring_fee"
    case authorityFee      = "authority_fee"
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .truckLease:         return "Truck Lease / Payment"
        case .insurance:          return "Insurance"
        case .fuel:               return "Fuel"
        case .fuelAdvance:        return "Fuel Advance"
        case .cashAdvance:        return "Cash Advance"
        case .maintenance:        return "Maintenance"
        case .repair:             return "Repair"
        case .escrow:             return "Escrow"
        case .maintenanceReserve: return "Maintenance Reserve"
        case .tolls:              return "Tolls"
        case .scaleTickets:       return "Scale Tickets"
        case .permits:            return "Permits"
        case .violation:          return "Violation / Fine"
        case .damage:             return "Damage Charge"
        case .trailerCharge:      return "Trailer Charge"
        case .equipmentCharge:    return "Equipment Charge"
        case .dispatcherFee:      return "Dispatcher Fee"
        case .factoringFee:       return "Factoring Fee"
        case .authorityFee:       return "Authority Fee"
        case .other:              return "Other"
        }
    }

    /// Categories that recover money the company already fronted. These are the
    /// only ones that may be linked to a `DriverAdvance`.
    var isAdvanceRecovery: Bool { self == .cashAdvance || self == .fuelAdvance }

    /// Counted into fuel-cost-per-mile on the settlement metrics.
    var isFuelCost: Bool { self == .fuel }

    /// Company fees that exist regardless of who is driving.
    var isCompanyFee: Bool {
        self == .dispatcherFee || self == .factoringFee || self == .authorityFee
    }
}

/// Who actually bears the cost. Only the driver's share reduces net driver pay;
/// the company's share is a company expense and never touches the driver's check.
enum DeductionResponsibility: String, Codable, CaseIterable, Identifiable {
    case driver
    case company
    case split

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .driver:  return "Driver Pays"
        case .company: return "Company Pays"
        case .split:   return "Split"
        }
    }
}

/// A debit against the driver's earnings, a company cost, or a split of both.
struct SettlementDeduction: Codable, Hashable, Identifiable {
    var id: UUID
    var settlementId: UUID?
    var profileId: UUID
    var category: SettlementDeductionCategory
    var descriptionText: String
    /// Total cost of the line, before the responsibility split is applied.
    var amount: Money
    var date: Date?
    var relatedLoadId: UUID?
    var relatedExpenseId: UUID?
    var documentId: UUID?
    var notes: String?
    var responsibility: DeductionResponsibility
    /// Only read when `responsibility == .split`. 60 means the driver pays 60%.
    var driverSharePercent: Decimal
    /// Set when this line was materialised from a `RecurringDeduction`.
    var recurringDeductionId: UUID?
    /// Set when this line recovers part of a `DriverAdvance`.
    var advanceId: UUID?
    var sortOrder: Int
    var createdAt: Date?

    init(
        id: UUID = UUID(),
        settlementId: UUID? = nil,
        profileId: UUID,
        category: SettlementDeductionCategory,
        descriptionText: String,
        amount: Money,
        date: Date? = nil,
        relatedLoadId: UUID? = nil,
        relatedExpenseId: UUID? = nil,
        documentId: UUID? = nil,
        notes: String? = nil,
        responsibility: DeductionResponsibility = .driver,
        driverSharePercent: Decimal = 100,
        recurringDeductionId: UUID? = nil,
        advanceId: UUID? = nil,
        sortOrder: Int = 0,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.settlementId = settlementId
        self.profileId = profileId
        self.category = category
        self.descriptionText = descriptionText
        self.amount = amount
        self.date = date
        self.relatedLoadId = relatedLoadId
        self.relatedExpenseId = relatedExpenseId
        self.documentId = documentId
        self.notes = notes
        self.responsibility = responsibility
        self.driverSharePercent = driverSharePercent
        self.recurringDeductionId = recurringDeductionId
        self.advanceId = advanceId
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, category, amount, date, notes, responsibility
        case settlementId = "settlement_id"
        case profileId = "profile_id"
        case descriptionText = "description"
        case relatedLoadId = "related_load_id"
        case relatedExpenseId = "related_expense_id"
        case documentId = "document_id"
        case driverSharePercent = "driver_share_percent"
        case recurringDeductionId = "recurring_deduction_id"
        case advanceId = "advance_id"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }

    /// Effective driver share as a percentage, normalised for the responsibility.
    var effectiveDriverPercent: Decimal {
        switch responsibility {
        case .driver:  return 100
        case .company: return 0
        case .split:
            if driverSharePercent < 0 { return 0 }
            if driverSharePercent > 100 { return 100 }
            return driverSharePercent
        }
    }

    /// The portion taken off the driver's check. Rounded to cents so the
    /// printed line and the total always agree.
    var driverAmount: Money {
        amount.percentage(effectiveDriverPercent).rounded
    }

    /// The portion the company absorbs.
    var companyAmount: Money {
        (amount - amount.percentage(effectiveDriverPercent)).rounded
    }
}

// MARK: - Recurring deductions

enum RecurrenceFrequency: String, Codable, CaseIterable, Identifiable {
    case everySettlement = "every_settlement"
    case weekly
    case biweekly
    case monthly
    case quarterly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .everySettlement: return "Every Settlement"
        case .weekly:          return "Weekly"
        case .biweekly:        return "Every Other Week"
        case .monthly:         return "Monthly"
        case .quarterly:       return "Quarterly"
        }
    }

    /// Nominal days between occurrences — used to decide whether a recurring
    /// deduction is due for a given settlement period.
    var approximateDays: Int {
        switch self {
        case .everySettlement: return 0
        case .weekly:          return 7
        case .biweekly:        return 14
        case .monthly:         return 30
        case .quarterly:       return 91
        }
    }
}

/// A standing instruction: "take $1,300 truck payment off Marcus every week".
/// Materialised into a real `SettlementDeduction` when a settlement is drafted;
/// the user can still edit or delete the line before approving.
struct RecurringDeduction: Codable, Hashable, Identifiable {
    var id: UUID
    var profileId: UUID
    var driverId: UUID
    var category: SettlementDeductionCategory
    var descriptionText: String
    /// Fixed dollar amount. Ignored when `percentOfGross` is set.
    var amount: Money
    /// Percentage of settlement gross revenue instead of a fixed amount.
    var percentOfGross: Decimal?
    var frequency: RecurrenceFrequency
    var effectiveStartDate: Date
    var effectiveEndDate: Date?
    var isActive: Bool
    var responsibility: DeductionResponsibility
    var driverSharePercent: Decimal
    var notes: String?
    var createdAt: Date?
    var updatedAt: Date?

    init(
        id: UUID = UUID(),
        profileId: UUID,
        driverId: UUID,
        category: SettlementDeductionCategory,
        descriptionText: String,
        amount: Money = .zero,
        percentOfGross: Decimal? = nil,
        frequency: RecurrenceFrequency = .everySettlement,
        effectiveStartDate: Date,
        effectiveEndDate: Date? = nil,
        isActive: Bool = true,
        responsibility: DeductionResponsibility = .driver,
        driverSharePercent: Decimal = 100,
        notes: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.driverId = driverId
        self.category = category
        self.descriptionText = descriptionText
        self.amount = amount
        self.percentOfGross = percentOfGross
        self.frequency = frequency
        self.effectiveStartDate = effectiveStartDate
        self.effectiveEndDate = effectiveEndDate
        self.isActive = isActive
        self.responsibility = responsibility
        self.driverSharePercent = driverSharePercent
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, category, amount, frequency, notes, responsibility
        case profileId = "profile_id"
        case driverId = "driver_id"
        case descriptionText = "description"
        case percentOfGross = "percent_of_gross"
        case effectiveStartDate = "effective_start_date"
        case effectiveEndDate = "effective_end_date"
        case isActive = "is_active"
        case driverSharePercent = "driver_share_percent"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var isPercentBased: Bool { percentOfGross != nil }

    /// The dollar amount this rule produces for a settlement of `gross`.
    func resolvedAmount(settlementGross: Money) -> Money {
        if let pct = percentOfGross {
            return settlementGross.percentage(pct).rounded
        }
        return amount.rounded
    }
}

// MARK: - Advances

enum AdvanceType: String, Codable, CaseIterable, Identifiable {
    case cash
    case fuel
    case emergency
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cash:      return "Cash Advance"
        case .fuel:      return "Fuel Advance"
        case .emergency: return "Emergency Advance"
        case .other:     return "Other Advance"
        }
    }

    /// The deduction category used when this advance is recovered.
    var deductionCategory: SettlementDeductionCategory {
        switch self {
        case .fuel:                    return .fuelAdvance
        case .cash, .emergency, .other:return .cashAdvance
        }
    }
}

/// Money fronted to a driver ahead of a settlement, recovered over one or more
/// future settlements. `outstandingBalance` is derived, never trusted from the
/// wire — see `DriverAdvanceService`.
struct DriverAdvance: Codable, Hashable, Identifiable {
    var id: UUID
    var profileId: UUID
    var driverId: UUID
    var type: AdvanceType
    var date: Date
    var amount: Money
    var descriptionText: String
    var documentId: UUID?
    var notes: String?
    /// Cached recovered-to-date. Recomputed from the repayment ledger on load.
    var recoveredAmount: Money
    var isClosed: Bool
    var createdAt: Date?
    var updatedAt: Date?

    init(
        id: UUID = UUID(),
        profileId: UUID,
        driverId: UUID,
        type: AdvanceType,
        date: Date,
        amount: Money,
        descriptionText: String,
        documentId: UUID? = nil,
        notes: String? = nil,
        recoveredAmount: Money = .zero,
        isClosed: Bool = false,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.driverId = driverId
        self.type = type
        self.date = date
        self.amount = amount
        self.descriptionText = descriptionText
        self.documentId = documentId
        self.notes = notes
        self.recoveredAmount = recoveredAmount
        self.isClosed = isClosed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, type, date, amount, notes
        case profileId = "profile_id"
        case driverId = "driver_id"
        case descriptionText = "description"
        case documentId = "document_id"
        case recoveredAmount = "recovered_amount"
        case isClosed = "is_closed"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Never negative — over-recovery is impossible by construction elsewhere,
    /// but a corrupted row must not produce a negative balance in the UI.
    var outstandingBalance: Money {
        (amount - recoveredAmount).clampedToZero.rounded
    }

    var isFullyRecovered: Bool { outstandingBalance.isZero }
}

/// One recovery event: "$300 of advance X came off settlement Y".
struct DriverAdvanceRepayment: Codable, Hashable, Identifiable {
    var id: UUID
    var profileId: UUID
    var advanceId: UUID
    var settlementId: UUID?
    var deductionId: UUID?
    var amount: Money
    var date: Date
    var createdAt: Date?

    init(
        id: UUID = UUID(),
        profileId: UUID,
        advanceId: UUID,
        settlementId: UUID? = nil,
        deductionId: UUID? = nil,
        amount: Money,
        date: Date,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.advanceId = advanceId
        self.settlementId = settlementId
        self.deductionId = deductionId
        self.amount = amount
        self.date = date
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, amount, date
        case profileId = "profile_id"
        case advanceId = "advance_id"
        case settlementId = "settlement_id"
        case deductionId = "deduction_id"
        case createdAt = "created_at"
    }
}

// MARK: - Load lines

/// A load as it appears ON a settlement. This is a SNAPSHOT, not a pointer:
/// the rate, miles and driver earnings are frozen here so that archiving,
/// editing or deleting the operational `Load` row later can never rewrite a
/// settlement the driver has already been paid on.
struct SettlementLoadLine: Codable, Hashable, Identifiable {
    var id: UUID
    var settlementId: UUID?
    var profileId: UUID
    /// Pointer back to the operational load. Nullable on purpose — a deleted
    /// load must not destroy settlement history.
    var loadId: UUID?
    var loadNumber: String?
    var brokerName: String?
    var brokerMcNumber: String?
    var pickupDate: Date?
    var deliveryDate: Date?
    var origin: String?
    var destination: String?
    var loadedMiles: Decimal
    var deadheadMiles: Decimal
    var linehaul: Money
    var fuelSurcharge: Money
    var accessorials: Money
    var detention: Money
    var layover: Money
    var tonu: Money
    var lumperReimbursement: Money
    /// When set, this is the authoritative gross rate and the components above
    /// are informational only. Used when a rate con states one number.
    var grossRateOverride: Money?
    /// Per-load override of the driver's pay rule. Nil = use the settlement rule.
    var payRuleOverride: PayRule?
    var hoursWorked: Decimal?
    /// Frozen result of the calculation engine for this line.
    var driverEarnings: Money
    @DefaultEmptyString var payBasisDescription: String
    var rateConfirmationDocumentId: UUID?
    var proofOfDeliveryDocumentId: UUID?
    var notes: String?
    /// True when this line re-pays a load that was already settled, as an
    /// approved correction. Duplicate-pay validation allows it only with this
    /// flag plus `correctsSettlementId`.
    var isAdjustment: Bool
    var correctsSettlementId: UUID?
    var sortOrder: Int
    var createdAt: Date?

    init(
        id: UUID = UUID(),
        settlementId: UUID? = nil,
        profileId: UUID,
        loadId: UUID? = nil,
        loadNumber: String? = nil,
        brokerName: String? = nil,
        brokerMcNumber: String? = nil,
        pickupDate: Date? = nil,
        deliveryDate: Date? = nil,
        origin: String? = nil,
        destination: String? = nil,
        loadedMiles: Decimal = 0,
        deadheadMiles: Decimal = 0,
        linehaul: Money = .zero,
        fuelSurcharge: Money = .zero,
        accessorials: Money = .zero,
        detention: Money = .zero,
        layover: Money = .zero,
        tonu: Money = .zero,
        lumperReimbursement: Money = .zero,
        grossRateOverride: Money? = nil,
        payRuleOverride: PayRule? = nil,
        hoursWorked: Decimal? = nil,
        driverEarnings: Money = .zero,
        payBasisDescription: String = "",
        rateConfirmationDocumentId: UUID? = nil,
        proofOfDeliveryDocumentId: UUID? = nil,
        notes: String? = nil,
        isAdjustment: Bool = false,
        correctsSettlementId: UUID? = nil,
        sortOrder: Int = 0,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.settlementId = settlementId
        self.profileId = profileId
        self.loadId = loadId
        self.loadNumber = loadNumber
        self.brokerName = brokerName
        self.brokerMcNumber = brokerMcNumber
        self.pickupDate = pickupDate
        self.deliveryDate = deliveryDate
        self.origin = origin
        self.destination = destination
        self.loadedMiles = loadedMiles
        self.deadheadMiles = deadheadMiles
        self.linehaul = linehaul
        self.fuelSurcharge = fuelSurcharge
        self.accessorials = accessorials
        self.detention = detention
        self.layover = layover
        self.tonu = tonu
        self.lumperReimbursement = lumperReimbursement
        self.grossRateOverride = grossRateOverride
        self.payRuleOverride = payRuleOverride
        self.hoursWorked = hoursWorked
        self.driverEarnings = driverEarnings
        self.payBasisDescription = payBasisDescription
        self.rateConfirmationDocumentId = rateConfirmationDocumentId
        self.proofOfDeliveryDocumentId = proofOfDeliveryDocumentId
        self.notes = notes
        self.isAdjustment = isAdjustment
        self.correctsSettlementId = correctsSettlementId
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, origin, destination, linehaul, detention, layover, tonu, notes
        case settlementId = "settlement_id"
        case profileId = "profile_id"
        case loadId = "load_id"
        case loadNumber = "load_number"
        case brokerName = "broker_name"
        case brokerMcNumber = "broker_mc_number"
        case pickupDate = "pickup_date"
        case deliveryDate = "delivery_date"
        case loadedMiles = "loaded_miles"
        case deadheadMiles = "deadhead_miles"
        case fuelSurcharge = "fuel_surcharge"
        case accessorials = "accessorials"
        case lumperReimbursement = "lumper_reimbursement"
        case grossRateOverride = "gross_rate_override"
        case payRuleOverride = "pay_rule_override"
        case hoursWorked = "hours_worked"
        case driverEarnings = "driver_earnings"
        case payBasisDescription = "pay_basis_description"
        case rateConfirmationDocumentId = "rate_confirmation_document_id"
        case proofOfDeliveryDocumentId = "proof_of_delivery_document_id"
        case isAdjustment = "is_adjustment"
        case correctsSettlementId = "corrects_settlement_id"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }

    /// Gross rate for the load. The override wins; otherwise the components sum.
    var grossRate: Money {
        if let override = grossRateOverride { return override }
        return Money.sum([linehaul, fuelSurcharge, accessorials,
                          detention, layover, tonu, lumperReimbursement])
    }

    var totalMiles: Decimal { loadedMiles + deadheadMiles }

    func miles(for basis: MileBasis) -> Decimal {
        switch basis {
        case .loaded:   return loadedMiles
        case .total:    return totalMiles
        case .deadhead: return deadheadMiles
        }
    }

    var routeDescription: String {
        switch (origin, destination) {
        case let (o?, d?): return "\(o) → \(d)"
        case let (o?, nil): return o
        case let (nil, d?): return d
        default: return "—"
        }
    }
}

// MARK: - Audit

enum SettlementAuditAction: String, Codable, CaseIterable, Identifiable {
    case created
    case loadAdded            = "load_added"
    case loadRemoved          = "load_removed"
    case payRateChanged       = "pay_rate_changed"
    case additionAdded        = "addition_added"
    case additionRemoved      = "addition_removed"
    case deductionAdded       = "deduction_added"
    case deductionRemoved     = "deduction_removed"
    case recurringApplied     = "recurring_applied"
    case advanceRepaymentApplied = "advance_repayment_applied"
    case statusChanged        = "status_changed"
    case approved
    case markedPaid           = "marked_paid"
    case reopened
    case voided
    case manualAdjustment     = "manual_adjustment"
    case recalculated

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .created:                 return "Settlement created"
        case .loadAdded:               return "Load added"
        case .loadRemoved:             return "Load removed"
        case .payRateChanged:          return "Pay rate changed"
        case .additionAdded:           return "Addition added"
        case .additionRemoved:         return "Addition removed"
        case .deductionAdded:          return "Deduction added"
        case .deductionRemoved:        return "Deduction removed"
        case .recurringApplied:        return "Recurring deductions applied"
        case .advanceRepaymentApplied: return "Advance repayment applied"
        case .statusChanged:           return "Status changed"
        case .approved:                return "Settlement approved"
        case .markedPaid:              return "Marked paid"
        case .reopened:                return "Settlement reopened"
        case .voided:                  return "Settlement voided"
        case .manualAdjustment:        return "Manual adjustment"
        case .recalculated:            return "Recalculated"
        }
    }
}

/// Append-only. Nothing in the app updates or deletes an audit row.
struct SettlementAuditEvent: Codable, Hashable, Identifiable {
    var id: UUID
    var profileId: UUID
    var settlementId: UUID
    var action: SettlementAuditAction
    var summary: String
    var fieldName: String?
    var previousValue: String?
    var newValue: String?
    /// Who did it. The account user id in cloud mode; the local install id in
    /// Free Local Mode where there is only ever one operator.
    var actorUserId: UUID?
    var actorName: String?
    var timestamp: Date

    init(
        id: UUID = UUID(),
        profileId: UUID,
        settlementId: UUID,
        action: SettlementAuditAction,
        summary: String,
        fieldName: String? = nil,
        previousValue: String? = nil,
        newValue: String? = nil,
        actorUserId: UUID? = nil,
        actorName: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.profileId = profileId
        self.settlementId = settlementId
        self.action = action
        self.summary = summary
        self.fieldName = fieldName
        self.previousValue = previousValue
        self.newValue = newValue
        self.actorUserId = actorUserId
        self.actorName = actorName
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case id, action, summary, timestamp
        case profileId = "profile_id"
        case settlementId = "settlement_id"
        case fieldName = "field_name"
        case previousValue = "previous_value"
        case newValue = "new_value"
        case actorUserId = "actor_user_id"
        case actorName = "actor_name"
    }
}

// MARK: - Lease operator configuration

/// One "who pays for X" rule. A lease operator agreement is a list of these.
struct ResponsibilityRule: Codable, Hashable, Identifiable {
    var id: UUID
    var category: SettlementDeductionCategory
    var responsibility: DeductionResponsibility
    var driverSharePercent: Decimal

    init(
        id: UUID = UUID(),
        category: SettlementDeductionCategory,
        responsibility: DeductionResponsibility,
        driverSharePercent: Decimal = 100
    ) {
        self.id = id
        self.category = category
        self.responsibility = responsibility
        self.driverSharePercent = driverSharePercent
    }

    enum CodingKeys: String, CodingKey {
        case id, category, responsibility
        case driverSharePercent = "driver_share_percent"
    }
}

/// Lease operator arrangements differ per driver. Nothing here is assumed —
/// every rule is explicit, and an unlisted category falls back to the
/// settlement type's default.
struct LeaseOperatorConfig: Codable, Hashable {
    var driverGrossPercent: Decimal
    var companyGrossPercent: Decimal
    var rules: [ResponsibilityRule]

    init(
        driverGrossPercent: Decimal = 70,
        companyGrossPercent: Decimal = 30,
        rules: [ResponsibilityRule] = []
    ) {
        self.driverGrossPercent = driverGrossPercent
        self.companyGrossPercent = companyGrossPercent
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey {
        case rules
        case driverGrossPercent = "driver_gross_percent"
        case companyGrossPercent = "company_gross_percent"
    }

    func responsibility(for category: SettlementDeductionCategory)
        -> (DeductionResponsibility, Decimal)? {
        guard let rule = rules.first(where: { $0.category == category }) else { return nil }
        return (rule.responsibility, rule.driverSharePercent)
    }

    /// Sanity flag for the UI — the two shares do not have to total 100
    /// (a third party can take a cut), but it is worth warning about.
    var splitsToWholePercent: Bool {
        driverGrossPercent + companyGrossPercent == 100
    }
}

// MARK: - Driver pay settings

/// Driver-level defaults. Every settlement copies these in and may override
/// them, so changing a driver's rate never rewrites a past settlement.
struct DriverPaySettings: Codable, Hashable, Identifiable {
    var id: UUID
    var profileId: UUID
    var driverId: UUID
    var settlementType: SettlementType
    var payRule: PayRule
    /// Percentage basis. true = percent of GROSS revenue (industry norm);
    /// false = percent of net after company expenses (the legacy behaviour of
    /// `SettlementEngine` when `payOnRevenue` was false).
    var payOnGrossRevenue: Bool
    var leaseConfig: LeaseOperatorConfig?
    var defaultTruckNumber: String?
    var updatedAt: Date?

    init(
        id: UUID = UUID(),
        profileId: UUID,
        driverId: UUID,
        settlementType: SettlementType = .companyDriver,
        payRule: PayRule = .none,
        payOnGrossRevenue: Bool = true,
        leaseConfig: LeaseOperatorConfig? = nil,
        defaultTruckNumber: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.driverId = driverId
        self.settlementType = settlementType
        self.payRule = payRule
        self.payOnGrossRevenue = payOnGrossRevenue
        self.leaseConfig = leaseConfig
        self.defaultTruckNumber = defaultTruckNumber
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case driverId = "driver_id"
        case settlementType = "settlement_type"
        case payRule = "pay_rule"
        case payOnGrossRevenue = "pay_on_gross_revenue"
        case leaseConfig = "lease_config"
        case defaultTruckNumber = "default_truck_number"
        case updatedAt = "updated_at"
    }

    /// Responsibility for a deduction category under this driver's agreement.
    func responsibility(for category: SettlementDeductionCategory)
        -> (DeductionResponsibility, Decimal) {
        if let explicit = leaseConfig?.responsibility(for: category) {
            return explicit
        }
        if settlementType.defaultDriverResponsibilities.contains(category) {
            return (.driver, 100)
        }
        return (.company, 0)
    }
}
