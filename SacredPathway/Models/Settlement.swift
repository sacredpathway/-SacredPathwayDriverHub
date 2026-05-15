import Foundation

struct Settlement: Codable, Identifiable {
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
    }

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
        createdAt: Date? = nil
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
    }

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
        try SPDate.encodeISO(createdAt,                   into: &c, forKey: .createdAt)
    }
}
