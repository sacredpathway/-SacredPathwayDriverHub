import Foundation

// =============================================================================
//  Settlement — settlement header record
// -----------------------------------------------------------------------------
//  EXTENDED (2026-09-12) for Driver Pay & Settlements. Every field that existed
//  before is still here, still the same type, still the same coding key, so
//  rows written by earlier builds decode unchanged and the existing
//  `SettlementGeneratorView` / `SupabaseService.createSettlement` paths keep
//  working untouched.
//
//  New fields are all OPTIONAL and all additive:
//   - identity:      settlementNumber, settlementType, truckId, truckNumber
//   - pay rules:     payRule, payOnGrossRevenue, hoursWorked
//   - money totals:  grossLoadRevenue, totalDriverEarnings, totalAdditions,
//                    totalDeductions, companyRetained, companyExpenses
//   - metrics:       totalMilesValue, loadedMilesValue, deadheadMilesValue
//   - lifecycle:     updatedAt, approvedAt, paidAt, voidedAt, createdByUserId,
//                    approvedByUserId, paymentReference, paymentMethod
//   - provenance:    engineVersion, isEstimate, notes
//
//  Legacy `netPay: Double?` remains THE net-pay column. `netPayMoney` is the
//  decimal-safe accessor every new screen uses.
// =============================================================================

struct Settlement: Codable, Identifiable {

    // ── Existing fields (unchanged) ──────────────────────────────────────
    var id: UUID?
    let profileId: UUID
    var driverId: UUID?
    var settlementPeriodStart: Date?  // Postgres DATE
    var settlementPeriodEnd: Date?    // Postgres DATE
    var totalRevenue: Double?
    var totalExpenses: Double?
    var grossProfit: Double?
    var driverPayPercentage: Double?
    var driverPayAmount: Double?
    var dispatcherFeePercentage: Double?
    var dispatcherFeeAmount: Double?
    var factoringFeePercentage: Double?
    var factoringFeeAmount: Double?
    var authorityFee: Double?
    var maintenanceReserve: Double?
    var netPay: Double?
    var pdfStoragePath: String?
    var status: String?
    var createdAt: Date?              // Postgres TIMESTAMPTZ

    // ── New: identity ────────────────────────────────────────────────────
    var settlementNumber: String?
    var settlementType: SettlementType?
    var truckId: UUID?
    var truckNumber: String?

    // ── New: pay rules ───────────────────────────────────────────────────
    var payRule: PayRule?
    var payOnGrossRevenue: Bool?
    var hoursWorked: Decimal?

    // ── New: money totals ────────────────────────────────────────────────
    var grossLoadRevenue: Money?
    var totalDriverEarnings: Money?
    var totalAdditions: Money?
    var totalDeductions: Money?
    var companyRetained: Money?
    var companyExpenses: Money?

    // ── New: metrics ─────────────────────────────────────────────────────
    var loadedMilesValue: Decimal?
    var deadheadMilesValue: Decimal?
    var totalMilesValue: Decimal?

    // ── New: lifecycle ───────────────────────────────────────────────────
    var notes: String?
    var updatedAt: Date?
    var approvedAt: Date?
    var paidAt: Date?
    var voidedAt: Date?
    var createdByUserId: UUID?
    var approvedByUserId: UUID?
    var paymentReference: String?
    var paymentMethod: String?

    // ── New: provenance ──────────────────────────────────────────────────
    var engineVersion: String?
    /// True for a live "what will this week look like" projection. Estimates are
    /// never a financial record and are excluded from paid/approved history.
    var isEstimate: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case driverId = "driver_id"
        case settlementPeriodStart = "settlement_period_start"
        case settlementPeriodEnd = "settlement_period_end"
        case totalRevenue = "total_revenue"
        case totalExpenses = "total_expenses"
        case grossProfit = "gross_profit"
        case driverPayPercentage = "driver_pay_percentage"
        case driverPayAmount = "driver_pay_amount"
        case dispatcherFeePercentage = "dispatcher_fee_percentage"
        case dispatcherFeeAmount = "dispatcher_fee_amount"
        case factoringFeePercentage = "factoring_fee_percentage"
        case factoringFeeAmount = "factoring_fee_amount"
        case authorityFee = "authority_fee"
        case maintenanceReserve = "maintenance_reserve"
        case netPay = "net_pay"
        case pdfStoragePath = "pdf_storage_path"
        case status
        case createdAt = "created_at"

        case settlementNumber = "settlement_number"
        case settlementType = "settlement_type"
        case truckId = "truck_id"
        case truckNumber = "truck_number"

        case payRule = "pay_rule"
        case payOnGrossRevenue = "pay_on_gross_revenue"
        case hoursWorked = "hours_worked"

        case grossLoadRevenue = "gross_load_revenue"
        case totalDriverEarnings = "total_driver_earnings"
        case totalAdditions = "total_additions"
        case totalDeductions = "total_deductions"
        case companyRetained = "company_retained"
        case companyExpenses = "company_expenses"

        case loadedMilesValue = "loaded_miles"
        case deadheadMilesValue = "deadhead_miles"
        case totalMilesValue = "total_miles"

        case notes
        case updatedAt = "updated_at"
        case approvedAt = "approved_at"
        case paidAt = "paid_at"
        case voidedAt = "voided_at"
        case createdByUserId = "created_by"
        case approvedByUserId = "approved_by"
        case paymentReference = "payment_reference"
        case paymentMethod = "payment_method"

        case engineVersion = "engine_version"
        case isEstimate = "is_estimate"
    }

    // MARK: - Init

    init(
        id: UUID? = nil,
        profileId: UUID,
        driverId: UUID? = nil,
        settlementPeriodStart: Date? = nil,
        settlementPeriodEnd: Date? = nil,
        totalRevenue: Double? = nil,
        totalExpenses: Double? = nil,
        grossProfit: Double? = nil,
        driverPayPercentage: Double? = nil,
        driverPayAmount: Double? = nil,
        dispatcherFeePercentage: Double? = nil,
        dispatcherFeeAmount: Double? = nil,
        factoringFeePercentage: Double? = nil,
        factoringFeeAmount: Double? = nil,
        authorityFee: Double? = nil,
        maintenanceReserve: Double? = nil,
        netPay: Double? = nil,
        pdfStoragePath: String? = nil,
        status: String? = nil,
        createdAt: Date? = nil,
        settlementNumber: String? = nil,
        settlementType: SettlementType? = nil,
        truckId: UUID? = nil,
        truckNumber: String? = nil,
        payRule: PayRule? = nil,
        payOnGrossRevenue: Bool? = nil,
        hoursWorked: Decimal? = nil,
        grossLoadRevenue: Money? = nil,
        totalDriverEarnings: Money? = nil,
        totalAdditions: Money? = nil,
        totalDeductions: Money? = nil,
        companyRetained: Money? = nil,
        companyExpenses: Money? = nil,
        loadedMilesValue: Decimal? = nil,
        deadheadMilesValue: Decimal? = nil,
        totalMilesValue: Decimal? = nil,
        notes: String? = nil,
        updatedAt: Date? = nil,
        approvedAt: Date? = nil,
        paidAt: Date? = nil,
        voidedAt: Date? = nil,
        createdByUserId: UUID? = nil,
        approvedByUserId: UUID? = nil,
        paymentReference: String? = nil,
        paymentMethod: String? = nil,
        engineVersion: String? = nil,
        isEstimate: Bool? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.driverId = driverId
        self.settlementPeriodStart = settlementPeriodStart
        self.settlementPeriodEnd = settlementPeriodEnd
        self.totalRevenue = totalRevenue
        self.totalExpenses = totalExpenses
        self.grossProfit = grossProfit
        self.driverPayPercentage = driverPayPercentage
        self.driverPayAmount = driverPayAmount
        self.dispatcherFeePercentage = dispatcherFeePercentage
        self.dispatcherFeeAmount = dispatcherFeeAmount
        self.factoringFeePercentage = factoringFeePercentage
        self.factoringFeeAmount = factoringFeeAmount
        self.authorityFee = authorityFee
        self.maintenanceReserve = maintenanceReserve
        self.netPay = netPay
        self.pdfStoragePath = pdfStoragePath
        self.status = status
        self.createdAt = createdAt
        self.settlementNumber = settlementNumber
        self.settlementType = settlementType
        self.truckId = truckId
        self.truckNumber = truckNumber
        self.payRule = payRule
        self.payOnGrossRevenue = payOnGrossRevenue
        self.hoursWorked = hoursWorked
        self.grossLoadRevenue = grossLoadRevenue
        self.totalDriverEarnings = totalDriverEarnings
        self.totalAdditions = totalAdditions
        self.totalDeductions = totalDeductions
        self.companyRetained = companyRetained
        self.companyExpenses = companyExpenses
        self.loadedMilesValue = loadedMilesValue
        self.deadheadMilesValue = deadheadMilesValue
        self.totalMilesValue = totalMilesValue
        self.notes = notes
        self.updatedAt = updatedAt
        self.approvedAt = approvedAt
        self.paidAt = paidAt
        self.voidedAt = voidedAt
        self.createdByUserId = createdByUserId
        self.approvedByUserId = approvedByUserId
        self.paymentReference = paymentReference
        self.paymentMethod = paymentMethod
        self.engineVersion = engineVersion
        self.isEstimate = isEstimate
    }

    // MARK: - Codable
    //
    // Dates go through SPDate for the same reason every other model does:
    // Postgres DATE and TIMESTAMPTZ come back in shapes Swift's built-in
    // .iso8601 strategy rejects.

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                       = try c.decodeIfPresent(UUID.self,   forKey: .id)
        profileId                = try c.decode(UUID.self,            forKey: .profileId)
        driverId                 = try c.decodeIfPresent(UUID.self,   forKey: .driverId)
        totalRevenue             = try c.decodeIfPresent(Double.self, forKey: .totalRevenue)
        totalExpenses            = try c.decodeIfPresent(Double.self, forKey: .totalExpenses)
        grossProfit              = try c.decodeIfPresent(Double.self, forKey: .grossProfit)
        driverPayPercentage      = try c.decodeIfPresent(Double.self, forKey: .driverPayPercentage)
        driverPayAmount          = try c.decodeIfPresent(Double.self, forKey: .driverPayAmount)
        dispatcherFeePercentage  = try c.decodeIfPresent(Double.self, forKey: .dispatcherFeePercentage)
        dispatcherFeeAmount      = try c.decodeIfPresent(Double.self, forKey: .dispatcherFeeAmount)
        factoringFeePercentage   = try c.decodeIfPresent(Double.self, forKey: .factoringFeePercentage)
        factoringFeeAmount       = try c.decodeIfPresent(Double.self, forKey: .factoringFeeAmount)
        authorityFee             = try c.decodeIfPresent(Double.self, forKey: .authorityFee)
        maintenanceReserve       = try c.decodeIfPresent(Double.self, forKey: .maintenanceReserve)
        netPay                   = try c.decodeIfPresent(Double.self, forKey: .netPay)
        pdfStoragePath           = try c.decodeIfPresent(String.self, forKey: .pdfStoragePath)
        status                   = try c.decodeIfPresent(String.self, forKey: .status)
        settlementPeriodStart    = try SPDate.decode(c, forKey: .settlementPeriodStart)
        settlementPeriodEnd      = try SPDate.decode(c, forKey: .settlementPeriodEnd)
        createdAt                = try SPDate.decode(c, forKey: .createdAt)

        settlementNumber         = try c.decodeIfPresent(String.self, forKey: .settlementNumber)
        settlementType           = try c.decodeIfPresent(SettlementType.self, forKey: .settlementType)
        truckId                  = try c.decodeIfPresent(UUID.self,   forKey: .truckId)
        truckNumber              = try c.decodeIfPresent(String.self, forKey: .truckNumber)

        payRule                  = try c.decodeIfPresent(PayRule.self, forKey: .payRule)
        payOnGrossRevenue        = try c.decodeIfPresent(Bool.self,   forKey: .payOnGrossRevenue)
        hoursWorked              = try c.decodeIfPresent(Decimal.self, forKey: .hoursWorked)

        grossLoadRevenue         = try c.decodeIfPresent(Money.self,  forKey: .grossLoadRevenue)
        totalDriverEarnings      = try c.decodeIfPresent(Money.self,  forKey: .totalDriverEarnings)
        totalAdditions           = try c.decodeIfPresent(Money.self,  forKey: .totalAdditions)
        totalDeductions          = try c.decodeIfPresent(Money.self,  forKey: .totalDeductions)
        companyRetained          = try c.decodeIfPresent(Money.self,  forKey: .companyRetained)
        companyExpenses          = try c.decodeIfPresent(Money.self,  forKey: .companyExpenses)

        loadedMilesValue         = try c.decodeIfPresent(Decimal.self, forKey: .loadedMilesValue)
        deadheadMilesValue       = try c.decodeIfPresent(Decimal.self, forKey: .deadheadMilesValue)
        totalMilesValue          = try c.decodeIfPresent(Decimal.self, forKey: .totalMilesValue)

        notes                    = try c.decodeIfPresent(String.self, forKey: .notes)
        updatedAt                = try SPDate.decode(c, forKey: .updatedAt)
        approvedAt               = try SPDate.decode(c, forKey: .approvedAt)
        paidAt                   = try SPDate.decode(c, forKey: .paidAt)
        voidedAt                 = try SPDate.decode(c, forKey: .voidedAt)
        createdByUserId          = try c.decodeIfPresent(UUID.self,   forKey: .createdByUserId)
        approvedByUserId         = try c.decodeIfPresent(UUID.self,   forKey: .approvedByUserId)
        paymentReference         = try c.decodeIfPresent(String.self, forKey: .paymentReference)
        paymentMethod            = try c.decodeIfPresent(String.self, forKey: .paymentMethod)

        engineVersion            = try c.decodeIfPresent(String.self, forKey: .engineVersion)
        isEstimate               = try c.decodeIfPresent(Bool.self,   forKey: .isEstimate)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id,                      forKey: .id)
        try c.encode(profileId,                        forKey: .profileId)
        try c.encodeIfPresent(driverId,                forKey: .driverId)
        try c.encodeIfPresent(totalRevenue,            forKey: .totalRevenue)
        try c.encodeIfPresent(totalExpenses,           forKey: .totalExpenses)
        try c.encodeIfPresent(grossProfit,             forKey: .grossProfit)
        try c.encodeIfPresent(driverPayPercentage,     forKey: .driverPayPercentage)
        try c.encodeIfPresent(driverPayAmount,         forKey: .driverPayAmount)
        try c.encodeIfPresent(dispatcherFeePercentage, forKey: .dispatcherFeePercentage)
        try c.encodeIfPresent(dispatcherFeeAmount,     forKey: .dispatcherFeeAmount)
        try c.encodeIfPresent(factoringFeePercentage,  forKey: .factoringFeePercentage)
        try c.encodeIfPresent(factoringFeeAmount,      forKey: .factoringFeeAmount)
        try c.encodeIfPresent(authorityFee,            forKey: .authorityFee)
        try c.encodeIfPresent(maintenanceReserve,      forKey: .maintenanceReserve)
        try c.encodeIfPresent(netPay,                  forKey: .netPay)
        try c.encodeIfPresent(pdfStoragePath,          forKey: .pdfStoragePath)
        try c.encodeIfPresent(status,                  forKey: .status)
        try SPDate.encodeDateOnly(settlementPeriodStart, into: &c, forKey: .settlementPeriodStart)
        try SPDate.encodeDateOnly(settlementPeriodEnd,   into: &c, forKey: .settlementPeriodEnd)
        try SPDate.encodeISO(createdAt,                  into: &c, forKey: .createdAt)

        try c.encodeIfPresent(settlementNumber,        forKey: .settlementNumber)
        try c.encodeIfPresent(settlementType,          forKey: .settlementType)
        try c.encodeIfPresent(truckId,                 forKey: .truckId)
        try c.encodeIfPresent(truckNumber,             forKey: .truckNumber)

        try c.encodeIfPresent(payRule,                 forKey: .payRule)
        try c.encodeIfPresent(payOnGrossRevenue,       forKey: .payOnGrossRevenue)
        try c.encodeIfPresent(hoursWorked,             forKey: .hoursWorked)

        try c.encodeIfPresent(grossLoadRevenue,        forKey: .grossLoadRevenue)
        try c.encodeIfPresent(totalDriverEarnings,     forKey: .totalDriverEarnings)
        try c.encodeIfPresent(totalAdditions,          forKey: .totalAdditions)
        try c.encodeIfPresent(totalDeductions,         forKey: .totalDeductions)
        try c.encodeIfPresent(companyRetained,         forKey: .companyRetained)
        try c.encodeIfPresent(companyExpenses,         forKey: .companyExpenses)

        try c.encodeIfPresent(loadedMilesValue,        forKey: .loadedMilesValue)
        try c.encodeIfPresent(deadheadMilesValue,      forKey: .deadheadMilesValue)
        try c.encodeIfPresent(totalMilesValue,         forKey: .totalMilesValue)

        try c.encodeIfPresent(notes,                   forKey: .notes)
        try SPDate.encodeISO(updatedAt,  into: &c, forKey: .updatedAt)
        try SPDate.encodeISO(approvedAt, into: &c, forKey: .approvedAt)
        try SPDate.encodeISO(paidAt,     into: &c, forKey: .paidAt)
        try SPDate.encodeISO(voidedAt,   into: &c, forKey: .voidedAt)
        try c.encodeIfPresent(createdByUserId,         forKey: .createdByUserId)
        try c.encodeIfPresent(approvedByUserId,        forKey: .approvedByUserId)
        try c.encodeIfPresent(paymentReference,        forKey: .paymentReference)
        try c.encodeIfPresent(paymentMethod,           forKey: .paymentMethod)

        try c.encodeIfPresent(engineVersion,           forKey: .engineVersion)
        try c.encodeIfPresent(isEstimate,              forKey: .isEstimate)
    }

    // MARK: - Derived

    /// Typed status. Unknown or missing strings read as `.draft` so a row from
    /// an older build is editable rather than mysteriously locked.
    var settlementStatus: SettlementStatus {
        get {
            guard let status, let parsed = SettlementStatus(rawValue: status) else {
                return .draft
            }
            return parsed
        }
        set { status = newValue.rawValue }
    }

    var isLocked: Bool { settlementStatus.isLocked }

    var isEstimateRecord: Bool { isEstimate == true }

    /// Decimal-safe net pay. Prefers the stored legacy column and falls back to
    /// recomputing from the new totals when the column is missing.
    var netPayMoney: Money {
        if let netPay { return Money(double: netPay) }
        let earnings = totalDriverEarnings ?? .zero
        let adds = totalAdditions ?? .zero
        let deducts = totalDeductions ?? .zero
        return (earnings + adds - deducts).rounded
    }

    var grossLoadRevenueMoney: Money {
        grossLoadRevenue ?? Money(double: totalRevenue ?? 0)
    }

    var effectiveSettlementType: SettlementType { settlementType ?? .companyDriver }

    var effectivePayRule: PayRule {
        if let payRule, !payRule.isEmpty { return payRule }
        if let pct = driverPayPercentage, pct > 0 {
            return .percentOfGross(Decimal(pct))
        }
        return .none
    }

    /// "Sep 7 – Sep 13, 2026"
    var periodDescription: String {
        guard let start = settlementPeriodStart, let end = settlementPeriodEnd else {
            return "—"
        }
        let startF = DateFormatter()
        startF.dateFormat = "MMM d"
        let endF = DateFormatter()
        endF.dateFormat = "MMM d, yyyy"
        return "\(startF.string(from: start)) – \(endF.string(from: end))"
    }

    var displayNumber: String {
        settlementNumber ?? id.map { "#" + String($0.uuidString.prefix(8)) } ?? "—"
    }

    // MARK: - Applying engine output

    /// Writes a calculation result onto the record. Both the legacy Double
    /// columns and the new decimal columns are populated so old screens, old
    /// exports and the Supabase rows all stay consistent.
    mutating func apply(
        _ result: SettlementCalculationResult,
        payRule: PayRule,
        payOnGrossRevenue: Bool,
        settlementType: SettlementType
    ) {
        self.payRule = payRule
        self.payOnGrossRevenue = payOnGrossRevenue
        self.settlementType = settlementType
        self.engineVersion = result.engineVersion
        self.isEstimate = result.isEstimate

        grossLoadRevenue    = result.grossLoadRevenue.rounded
        totalDriverEarnings = result.driverBaseEarnings.rounded
        totalAdditions      = result.totalAdditions.rounded
        totalDeductions     = result.totalDriverDeductions.rounded
        companyRetained     = result.companyRetained.rounded
        companyExpenses     = result.companyExpenses.rounded

        loadedMilesValue    = result.loadedMiles
        deadheadMilesValue  = result.deadheadMiles
        totalMilesValue     = result.totalMiles

        // Legacy columns — kept in step so nothing that reads them breaks.
        totalRevenue        = result.grossLoadRevenue.doubleValue
        totalExpenses       = result.companyExpenses.doubleValue
        grossProfit         = (result.grossLoadRevenue - result.companyExpenses).doubleValue
        driverPayAmount     = result.driverBaseEarnings.doubleValue
        netPay              = result.netDriverPay.doubleValue

        if let percentComponent = payRule.components.first(where: { $0.kind == .percentOfGross }),
           let percent = percentComponent.percent {
            driverPayPercentage = NSDecimalNumber(decimal: percent).doubleValue
        }

        updatedAt = Date()
    }

    /// Snapshot used by the audit diff.
    var auditSnapshot: SettlementSnapshot {
        SettlementSnapshot(
            settlementNumber: settlementNumber,
            grossLoadRevenue: grossLoadRevenue,
            driverEarnings: totalDriverEarnings,
            totalAdditions: totalAdditions,
            totalDeductions: totalDeductions,
            netPay: netPay.map { Money(double: $0) }
        )
    }
}
