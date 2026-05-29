import Foundation

enum DispatchParticipantRole: String, Codable, CaseIterable, Identifiable {
    case driver
    case dispatcher
    case carrier
    case admin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .driver: return "Driver"
        case .dispatcher: return "Dispatcher"
        case .carrier: return "Carrier"
        case .admin: return "Admin"
        }
    }
}

enum DispatchOfferStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case accepted
    case declined
    case cancelled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .accepted: return "Accepted"
        case .declined: return "Declined"
        case .cancelled: return "Cancelled"
        }
    }
}

enum DispatchFeeType: String, Codable, CaseIterable, Identifiable {
    case flat
    case percentage
    case percentageGross = "percentage_gross"
    case flatPerLoad = "flat_per_load"
    case weeklyFixed = "weekly_fixed"
    case monthlyFixed = "monthly_fixed"

    var id: String { rawValue }

    static let productionCases: [DispatchFeeType] = [
        .percentageGross,
        .flatPerLoad,
        .weeklyFixed,
        .monthlyFixed
    ]

    static let loadOfferCases: [DispatchFeeType] = productionCases
    static let agreementCases: [DispatchFeeType] = productionCases

    var usesPercentage: Bool {
        self == .percentage || self == .percentageGross
    }

    var requiresAmount: Bool {
        !usesPercentage
    }

    var displayName: String {
        switch self {
        case .flat: return "Flat"
        case .percentage: return "Percent"
        case .percentageGross: return "Percentage of Gross"
        case .flatPerLoad: return "Flat Fee Per Load"
        case .weeklyFixed: return "Weekly Fixed Fee"
        case .monthlyFixed: return "Monthly Fixed Fee"
        }
    }
}

enum DispatchAgreementStatus: String, Codable, CaseIterable, Identifiable {
    case draft
    case pending
    case active
    case paused
    case terminated

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .draft: return "Draft"
        case .pending: return "Pending"
        case .active: return "Active"
        case .paused: return "Paused"
        case .terminated: return "Terminated"
        }
    }
}

enum DispatchServiceRequestStatus: String, Codable, CaseIterable, Identifiable {
    case open
    case pending
    case accepted
    case declined
    case cancelled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .open: return "Open"
        case .pending: return "Pending"
        case .accepted: return "Accepted"
        case .declined: return "Declined"
        case .cancelled: return "Cancelled"
        }
    }
}

enum DispatchEquipmentType: String, Codable, CaseIterable, Identifiable {
    case dryVan = "dry_van"
    case reefer
    case flatbed
    case powerOnly = "power_only"
    case hotshot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dryVan: return "Dry Van"
        case .reefer: return "Reefer"
        case .flatbed: return "Flatbed"
        case .powerOnly: return "Power Only"
        case .hotshot: return "Hotshot"
        }
    }
}

enum DispatchInvoiceCadence: String, Codable, CaseIterable, Identifiable {
    case weekly
    case monthly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}

enum DispatchPaymentStatus: String, Codable, CaseIterable, Identifiable {
    case unpaid
    case pending
    case paid
    case overdue

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unpaid: return "Unpaid"
        case .pending: return "Pending"
        case .paid: return "Paid"
        case .overdue: return "Overdue"
        }
    }
}

enum DispatchMessageKind: String, Codable, CaseIterable, Identifiable {
    case text
    case loadOffer = "load_offer"
    case status

    var id: String { rawValue }
}

struct DispatcherProfile: Codable, Identifiable {
    var id: UUID?
    var companyId: UUID?
    var userId: UUID?
    var displayName: String?
    var companyName: String?
    var yearsExperience: Int?
    var equipmentTypes: [String]?
    var serviceRegions: [String]?
    var languagesSpoken: [String]?
    var servicesOffered: [String]?
    var phone: String?
    var email: String?
    var contactInfo: String?
    var isActive: Bool?
    var isTrusted: Bool?
    var platformFeePercentage: Double?
    var ratingAverage: Double?
    var ratingCount: Int?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case companyId = "company_id"
        case userId = "user_id"
        case displayName = "display_name"
        case companyName = "company_name"
        case yearsExperience = "years_experience"
        case equipmentTypes = "equipment_types"
        case serviceRegions = "service_regions"
        case languagesSpoken = "languages_spoken"
        case servicesOffered = "services_offered"
        case phone, email
        case contactInfo = "contact_info"
        case isActive = "is_active"
        case isTrusted = "is_trusted"
        case platformFeePercentage = "platform_fee_percentage"
        case ratingAverage = "rating_average"
        case ratingCount = "rating_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct DispatchParticipant: Codable, Identifiable {
    var id: UUID?
    var companyId: UUID
    var threadId: UUID?
    var profileId: UUID
    var role: DispatchParticipantRole
    var displayName: String?
    var isActive: Bool = true
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case companyId = "company_id"
        case threadId = "thread_id"
        case profileId = "profile_id"
        case role
        case displayName = "display_name"
        case isActive = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct DispatchThread: Codable, Identifiable {
    var id: UUID?
    var companyId: UUID
    var loadOfferId: UUID?
    var acceptedLoadId: UUID?
    var agreementId: UUID?
    var loadNumber: String?
    var driverProfileId: UUID?
    var dispatcherUserId: UUID?
    var dispatcherName: String?
    var dispatcherCompany: String?
    var subject: String?
    var lastMessagePreview: String?
    var driverUnreadCount: Int = 0
    var dispatcherUnreadCount: Int = 0
    var carrierUnreadCount: Int = 0
    var lastMessageAt: Date?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case companyId = "company_id"
        case loadOfferId = "load_offer_id"
        case acceptedLoadId = "accepted_load_id"
        case agreementId = "agreement_id"
        case loadNumber = "load_number"
        case driverProfileId = "driver_profile_id"
        case dispatcherUserId = "dispatcher_user_id"
        case dispatcherName = "dispatcher_name"
        case dispatcherCompany = "dispatcher_company"
        case subject
        case lastMessagePreview = "last_message_preview"
        case driverUnreadCount = "driver_unread_count"
        case dispatcherUnreadCount = "dispatcher_unread_count"
        case carrierUnreadCount = "carrier_unread_count"
        case lastMessageAt = "last_message_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    func unreadCount(for role: DispatchParticipantRole) -> Int {
        switch role {
        case .driver: return driverUnreadCount
        case .dispatcher: return dispatcherUnreadCount
        case .carrier, .admin: return carrierUnreadCount
        }
    }
}

struct DispatchMessage: Codable, Identifiable {
    var id: UUID?
    var companyId: UUID
    var threadId: UUID
    var loadOfferId: UUID?
    var senderProfileId: UUID
    var senderRole: DispatchParticipantRole
    var senderName: String?
    var body: String
    var kind: DispatchMessageKind = .text
    var readAt: Date?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case companyId = "company_id"
        case threadId = "thread_id"
        case loadOfferId = "load_offer_id"
        case senderProfileId = "sender_profile_id"
        case senderRole = "sender_role"
        case senderName = "sender_name"
        case body, kind
        case readAt = "read_at"
        case createdAt = "created_at"
    }
}

struct DispatchLoadOffer: Codable, Identifiable {
    var id: UUID?
    var companyId: UUID
    var threadId: UUID?
    var dispatcherProfileId: UUID?
    var dispatcherUserId: UUID?
    var driverProfileId: UUID?
    var driverId: UUID?
    var agreementId: UUID?
    var dispatcherName: String?
    var dispatcherCompany: String?
    var loadNumber: String?
    var brokerName: String?
    var brokerMcNumber: String?
    var brokerPhone: String?
    var brokerEmail: String?
    var pickupDate: Date?
    var deliveryDate: Date?
    var origin: String?
    var destination: String?
    var totalMiles: Double?
    var lineHaulRate: Double?
    var fuelSurcharge: Double?
    var accessorialCharges: Double?
    var loadGrossAmount: Double?
    var feeType: DispatchFeeType = .flat
    var feeAmount: Double?
    var feePercentage: Double?
    var invoiceCadence: DispatchInvoiceCadence = .weekly
    var dueDate: Date?
    var notes: String?
    var status: DispatchOfferStatus = .pending
    var acceptedLoadId: UUID?
    var acceptedAt: Date?
    var declinedAt: Date?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case companyId = "company_id"
        case threadId = "thread_id"
        case dispatcherProfileId = "dispatcher_profile_id"
        case dispatcherUserId = "dispatcher_user_id"
        case driverProfileId = "driver_profile_id"
        case driverId = "driver_id"
        case agreementId = "agreement_id"
        case dispatcherName = "dispatcher_name"
        case dispatcherCompany = "dispatcher_company"
        case loadNumber = "load_number"
        case brokerName = "broker_name"
        case brokerMcNumber = "broker_mc_number"
        case brokerPhone = "broker_phone"
        case brokerEmail = "broker_email"
        case pickupDate = "pickup_date"
        case deliveryDate = "delivery_date"
        case origin, destination
        case totalMiles = "total_miles"
        case lineHaulRate = "line_haul_rate"
        case fuelSurcharge = "fuel_surcharge"
        case accessorialCharges = "accessorial_charges"
        case loadGrossAmount = "load_gross_amount"
        case feeType = "fee_type"
        case feeAmount = "fee_amount"
        case feePercentage = "fee_percentage"
        case invoiceCadence = "invoice_cadence"
        case dueDate = "due_date"
        case notes, status
        case acceptedLoadId = "accepted_load_id"
        case acceptedAt = "accepted_at"
        case declinedAt = "declined_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var grossAmountForCalculations: Double {
        if let gross = loadGrossAmount, gross > 0 { return gross }
        return (lineHaulRate ?? 0) + (fuelSurcharge ?? 0) + (accessorialCharges ?? 0)
    }

    var calculatedDispatchFee: Double {
        switch feeType {
        case .flat, .flatPerLoad, .weeklyFixed, .monthlyFixed:
            return max(0, feeAmount ?? 0)
        case .percentage, .percentageGross:
            return max(0, grossAmountForCalculations * ((feePercentage ?? 0) / 100))
        }
    }

    var feeDisplay: String {
        switch feeType {
        case .flat, .flatPerLoad, .weeklyFixed, .monthlyFixed:
            return (feeAmount ?? 0).asCurrency
        case .percentage, .percentageGross:
            return String(format: "%.2f%%", feePercentage ?? 0)
        }
    }
}

struct DispatcherPaymentRecord: Codable, Identifiable {
    var id: UUID?
    var companyId: UUID
    var dispatcherProfileId: UUID?
    var dispatcherUserId: UUID?
    var driverProfileId: UUID?
    var loadId: UUID?
    var loadOfferId: UUID?
    var threadId: UUID?
    var dispatcherName: String?
    var dispatcherCompany: String?
    var loadNumber: String?
    var loadGrossAmount: Double
    var feeType: DispatchFeeType
    var feeAmount: Double?
    var feePercentage: Double?
    var calculatedDispatchFee: Double
    var invoiceCadence: DispatchInvoiceCadence
    var paymentStatus: DispatchPaymentStatus = .unpaid
    var dueDate: Date?
    var notes: String?
    var createdAt: Date?
    var updatedAt: Date?
    var paidAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case companyId = "company_id"
        case dispatcherProfileId = "dispatcher_profile_id"
        case dispatcherUserId = "dispatcher_user_id"
        case driverProfileId = "driver_profile_id"
        case loadId = "load_id"
        case loadOfferId = "load_offer_id"
        case threadId = "thread_id"
        case dispatcherName = "dispatcher_name"
        case dispatcherCompany = "dispatcher_company"
        case loadNumber = "load_number"
        case loadGrossAmount = "load_gross_amount"
        case feeType = "fee_type"
        case feeAmount = "fee_amount"
        case feePercentage = "fee_percentage"
        case calculatedDispatchFee = "calculated_dispatch_fee"
        case invoiceCadence = "invoice_cadence"
        case paymentStatus = "payment_status"
        case dueDate = "due_date"
        case notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case paidAt = "paid_at"
    }
}

struct DispatchServiceRequest: Codable, Identifiable {
    var id: UUID?
    var companyId: UUID
    var requestedByProfileId: UUID
    var dispatcherProfileId: UUID?
    var dispatcherUserId: UUID?
    var carrierName: String?
    var serviceNotes: String?
    var status: DispatchServiceRequestStatus = .open
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case companyId = "company_id"
        case requestedByProfileId = "requested_by_profile_id"
        case dispatcherProfileId = "dispatcher_profile_id"
        case dispatcherUserId = "dispatcher_user_id"
        case carrierName = "carrier_name"
        case serviceNotes = "service_notes"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct DispatcherReview: Codable, Identifiable {
    var id: UUID?
    var companyId: UUID
    var dispatcherProfileId: UUID
    var carrierProfileId: UUID?
    var rating: Int
    var comment: String?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case companyId = "company_id"
        case dispatcherProfileId = "dispatcher_profile_id"
        case carrierProfileId = "carrier_profile_id"
        case rating, comment
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct DispatchAgreement: Codable, Identifiable {
    var id: UUID?
    var companyId: UUID
    var carrierProfileId: UUID
    var dispatcherProfileId: UUID
    var dispatcherUserId: UUID?
    var carrierName: String?
    var dispatcherName: String?
    var dispatcherCompany: String?
    var effectiveDate: Date?
    var feeType: DispatchFeeType
    var feePercentage: Double?
    var feeAmount: Double?
    var status: DispatchAgreementStatus = .pending
    var notes: String?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case companyId = "company_id"
        case carrierProfileId = "carrier_profile_id"
        case dispatcherProfileId = "dispatcher_profile_id"
        case dispatcherUserId = "dispatcher_user_id"
        case carrierName = "carrier_name"
        case dispatcherName = "dispatcher_name"
        case dispatcherCompany = "dispatcher_company"
        case effectiveDate = "effective_date"
        case feeType = "fee_type"
        case feePercentage = "fee_percentage"
        case feeAmount = "fee_amount"
        case status, notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    func fee(for grossRevenue: Double, loadCount: Int = 1) -> Double {
        switch feeType {
        case .percentage, .percentageGross:
            return max(0, grossRevenue * ((feePercentage ?? 0) / 100))
        case .flat, .flatPerLoad:
            return max(0, (feeAmount ?? 0) * Double(max(loadCount, 1)))
        case .weeklyFixed, .monthlyFixed:
            return max(0, feeAmount ?? 0)
        }
    }

    var feeDisplay: String {
        switch feeType {
        case .percentage, .percentageGross:
            return String(format: "%.2f%% of gross", feePercentage ?? 0)
        case .flat, .flatPerLoad:
            return "\((feeAmount ?? 0).asCurrency) per load"
        case .weeklyFixed:
            return "\((feeAmount ?? 0).asCurrency) weekly"
        case .monthlyFixed:
            return "\((feeAmount ?? 0).asCurrency) monthly"
        }
    }
}

struct DispatcherFeeRecord: Codable, Identifiable {
    var id: UUID?
    var companyId: UUID
    var agreementId: UUID?
    var dispatcherProfileId: UUID?
    var dispatcherUserId: UUID?
    var carrierProfileId: UUID?
    var loadId: UUID?
    var settlementDocumentId: UUID?
    var invoiceId: UUID?
    var loadNumber: String?
    var brokerName: String?
    var grossRevenue: Double
    var paymentAmount: Double?
    var feeType: DispatchFeeType
    var feePercentage: Double?
    var feeAmount: Double?
    var calculatedDispatchFee: Double
    var paymentStatus: DispatchPaymentStatus = .unpaid
    var dueDate: Date?
    var paymentDate: Date?
    var notes: String?
    var sourceType: String?
    var ocrConfidence: Double?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case companyId = "company_id"
        case agreementId = "agreement_id"
        case dispatcherProfileId = "dispatcher_profile_id"
        case dispatcherUserId = "dispatcher_user_id"
        case carrierProfileId = "carrier_profile_id"
        case loadId = "load_id"
        case settlementDocumentId = "settlement_document_id"
        case invoiceId = "invoice_id"
        case loadNumber = "load_number"
        case brokerName = "broker_name"
        case grossRevenue = "gross_revenue"
        case paymentAmount = "payment_amount"
        case feeType = "fee_type"
        case feePercentage = "fee_percentage"
        case feeAmount = "fee_amount"
        case calculatedDispatchFee = "calculated_dispatch_fee"
        case paymentStatus = "payment_status"
        case dueDate = "due_date"
        case paymentDate = "payment_date"
        case notes
        case sourceType = "source_type"
        case ocrConfidence = "ocr_confidence"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct DispatcherInvoice: Codable, Identifiable {
    var id: UUID?
    var companyId: UUID
    var agreementId: UUID?
    var dispatcherProfileId: UUID?
    var dispatcherUserId: UUID?
    var carrierProfileId: UUID?
    var invoiceNumber: String?
    var periodStart: Date?
    var periodEnd: Date?
    var totalGrossRevenue: Double
    var totalFeesDue: Double
    var paymentStatus: DispatchPaymentStatus = .unpaid
    var dueDate: Date?
    var paymentDate: Date?
    var notes: String?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case companyId = "company_id"
        case agreementId = "agreement_id"
        case dispatcherProfileId = "dispatcher_profile_id"
        case dispatcherUserId = "dispatcher_user_id"
        case carrierProfileId = "carrier_profile_id"
        case invoiceNumber = "invoice_number"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case totalGrossRevenue = "total_gross_revenue"
        case totalFeesDue = "total_fees_due"
        case paymentStatus = "payment_status"
        case dueDate = "due_date"
        case paymentDate = "payment_date"
        case notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct DispatchNetworkDashboardSummary {
    var activeCarriers: Int
    var activeLoads: Int
    var grossRevenueManaged: Double
    var feesOwed: Double
    var feesPaid: Double
    var overduePayments: Double
    var monthlyEarnings: Double
    var invoiceCount: Int
    var activeAgreementCount: Int
}

struct DispatchOfferRecipient: Identifiable {
    let profileId: UUID
    let role: DispatchParticipantRole
    let displayName: String
    let agreementId: UUID?

    var id: UUID { profileId }
}

struct DispatchInvoiceSummary: Identifiable {
    let id: String
    let cadence: DispatchInvoiceCadence
    let periodStart: Date
    let periodEnd: Date
    let records: [DispatcherPaymentRecord]

    var totalOwed: Double {
        records.reduce(0) { $0 + $1.calculatedDispatchFee }
    }

    var unpaidTotal: Double {
        records.filter { $0.paymentStatus == .unpaid }.reduce(0) { $0 + $1.calculatedDispatchFee }
    }

    var pendingTotal: Double {
        records.filter { $0.paymentStatus == .pending }.reduce(0) { $0 + $1.calculatedDispatchFee }
    }

    var paidTotal: Double {
        records.filter { $0.paymentStatus == .paid }.reduce(0) { $0 + $1.calculatedDispatchFee }
    }
}

private extension KeyedDecodingContainer {
    func decodeStringEnum<E: RawRepresentable>(
        _ type: E.Type,
        forKey key: Key,
        default fallback: E
    ) throws -> E where E.RawValue == String {
        guard let raw = try decodeIfPresent(String.self, forKey: key) else { return fallback }
        return E(rawValue: raw) ?? fallback
    }
}

extension DispatcherProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        companyId = try c.decodeIfPresent(UUID.self, forKey: .companyId)
        userId = try c.decodeIfPresent(UUID.self, forKey: .userId)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        companyName = try c.decodeIfPresent(String.self, forKey: .companyName)
        yearsExperience = try c.decodeIfPresent(Int.self, forKey: .yearsExperience)
        equipmentTypes = try c.decodeIfPresent([String].self, forKey: .equipmentTypes)
        serviceRegions = try c.decodeIfPresent([String].self, forKey: .serviceRegions)
        languagesSpoken = try c.decodeIfPresent([String].self, forKey: .languagesSpoken)
        servicesOffered = try c.decodeIfPresent([String].self, forKey: .servicesOffered)
        phone = try c.decodeIfPresent(String.self, forKey: .phone)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        contactInfo = try c.decodeIfPresent(String.self, forKey: .contactInfo)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive)
        isTrusted = try c.decodeIfPresent(Bool.self, forKey: .isTrusted)
        platformFeePercentage = try c.decodeIfPresent(Double.self, forKey: .platformFeePercentage)
        ratingAverage = try c.decodeIfPresent(Double.self, forKey: .ratingAverage)
        ratingCount = try c.decodeIfPresent(Int.self, forKey: .ratingCount)
        createdAt = try SPDate.decode(c, forKey: .createdAt)
        updatedAt = try SPDate.decode(c, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(companyId, forKey: .companyId)
        try c.encodeIfPresent(userId, forKey: .userId)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(companyName, forKey: .companyName)
        try c.encodeIfPresent(yearsExperience, forKey: .yearsExperience)
        try c.encodeIfPresent(equipmentTypes, forKey: .equipmentTypes)
        try c.encodeIfPresent(serviceRegions, forKey: .serviceRegions)
        try c.encodeIfPresent(languagesSpoken, forKey: .languagesSpoken)
        try c.encodeIfPresent(servicesOffered, forKey: .servicesOffered)
        try c.encodeIfPresent(phone, forKey: .phone)
        try c.encodeIfPresent(email, forKey: .email)
        try c.encodeIfPresent(contactInfo, forKey: .contactInfo)
        try c.encodeIfPresent(isActive, forKey: .isActive)
        try c.encodeIfPresent(isTrusted, forKey: .isTrusted)
        try c.encodeIfPresent(platformFeePercentage, forKey: .platformFeePercentage)
        try c.encodeIfPresent(ratingAverage, forKey: .ratingAverage)
        try c.encodeIfPresent(ratingCount, forKey: .ratingCount)
        try SPDate.encodeISO(createdAt, into: &c, forKey: .createdAt)
        try SPDate.encodeISO(updatedAt, into: &c, forKey: .updatedAt)
    }
}

extension DispatchParticipant {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        companyId = try c.decode(UUID.self, forKey: .companyId)
        threadId = try c.decodeIfPresent(UUID.self, forKey: .threadId)
        profileId = try c.decode(UUID.self, forKey: .profileId)
        role = try c.decodeStringEnum(DispatchParticipantRole.self, forKey: .role, default: .driver)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        createdAt = try SPDate.decode(c, forKey: .createdAt)
        updatedAt = try SPDate.decode(c, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(companyId, forKey: .companyId)
        try c.encodeIfPresent(threadId, forKey: .threadId)
        try c.encode(profileId, forKey: .profileId)
        try c.encode(role.rawValue, forKey: .role)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encode(isActive, forKey: .isActive)
        try SPDate.encodeISO(createdAt, into: &c, forKey: .createdAt)
        try SPDate.encodeISO(updatedAt, into: &c, forKey: .updatedAt)
    }
}

extension DispatchThread {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        companyId = try c.decode(UUID.self, forKey: .companyId)
        loadOfferId = try c.decodeIfPresent(UUID.self, forKey: .loadOfferId)
        acceptedLoadId = try c.decodeIfPresent(UUID.self, forKey: .acceptedLoadId)
        agreementId = try c.decodeIfPresent(UUID.self, forKey: .agreementId)
        loadNumber = try c.decodeIfPresent(String.self, forKey: .loadNumber)
        driverProfileId = try c.decodeIfPresent(UUID.self, forKey: .driverProfileId)
        dispatcherUserId = try c.decodeIfPresent(UUID.self, forKey: .dispatcherUserId)
        dispatcherName = try c.decodeIfPresent(String.self, forKey: .dispatcherName)
        dispatcherCompany = try c.decodeIfPresent(String.self, forKey: .dispatcherCompany)
        subject = try c.decodeIfPresent(String.self, forKey: .subject)
        lastMessagePreview = try c.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        driverUnreadCount = try c.decodeIfPresent(Int.self, forKey: .driverUnreadCount) ?? 0
        dispatcherUnreadCount = try c.decodeIfPresent(Int.self, forKey: .dispatcherUnreadCount) ?? 0
        carrierUnreadCount = try c.decodeIfPresent(Int.self, forKey: .carrierUnreadCount) ?? 0
        lastMessageAt = try SPDate.decode(c, forKey: .lastMessageAt)
        createdAt = try SPDate.decode(c, forKey: .createdAt)
        updatedAt = try SPDate.decode(c, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(companyId, forKey: .companyId)
        try c.encodeIfPresent(loadOfferId, forKey: .loadOfferId)
        try c.encodeIfPresent(acceptedLoadId, forKey: .acceptedLoadId)
        try c.encodeIfPresent(agreementId, forKey: .agreementId)
        try c.encodeIfPresent(loadNumber, forKey: .loadNumber)
        try c.encodeIfPresent(driverProfileId, forKey: .driverProfileId)
        try c.encodeIfPresent(dispatcherUserId, forKey: .dispatcherUserId)
        try c.encodeIfPresent(dispatcherName, forKey: .dispatcherName)
        try c.encodeIfPresent(dispatcherCompany, forKey: .dispatcherCompany)
        try c.encodeIfPresent(subject, forKey: .subject)
        try c.encodeIfPresent(lastMessagePreview, forKey: .lastMessagePreview)
        try c.encode(driverUnreadCount, forKey: .driverUnreadCount)
        try c.encode(dispatcherUnreadCount, forKey: .dispatcherUnreadCount)
        try c.encode(carrierUnreadCount, forKey: .carrierUnreadCount)
        try SPDate.encodeISO(lastMessageAt, into: &c, forKey: .lastMessageAt)
        try SPDate.encodeISO(createdAt, into: &c, forKey: .createdAt)
        try SPDate.encodeISO(updatedAt, into: &c, forKey: .updatedAt)
    }
}

extension DispatchMessage {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        companyId = try c.decode(UUID.self, forKey: .companyId)
        threadId = try c.decode(UUID.self, forKey: .threadId)
        loadOfferId = try c.decodeIfPresent(UUID.self, forKey: .loadOfferId)
        senderProfileId = try c.decode(UUID.self, forKey: .senderProfileId)
        senderRole = try c.decodeStringEnum(DispatchParticipantRole.self, forKey: .senderRole, default: .driver)
        senderName = try c.decodeIfPresent(String.self, forKey: .senderName)
        body = try c.decode(String.self, forKey: .body)
        kind = try c.decodeStringEnum(DispatchMessageKind.self, forKey: .kind, default: .text)
        readAt = try SPDate.decode(c, forKey: .readAt)
        createdAt = try SPDate.decode(c, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(companyId, forKey: .companyId)
        try c.encode(threadId, forKey: .threadId)
        try c.encodeIfPresent(loadOfferId, forKey: .loadOfferId)
        try c.encode(senderProfileId, forKey: .senderProfileId)
        try c.encode(senderRole.rawValue, forKey: .senderRole)
        try c.encodeIfPresent(senderName, forKey: .senderName)
        try c.encode(body, forKey: .body)
        try c.encode(kind.rawValue, forKey: .kind)
        try SPDate.encodeISO(readAt, into: &c, forKey: .readAt)
        try SPDate.encodeISO(createdAt, into: &c, forKey: .createdAt)
    }
}

extension DispatchLoadOffer {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        companyId = try c.decode(UUID.self, forKey: .companyId)
        threadId = try c.decodeIfPresent(UUID.self, forKey: .threadId)
        dispatcherProfileId = try c.decodeIfPresent(UUID.self, forKey: .dispatcherProfileId)
        dispatcherUserId = try c.decodeIfPresent(UUID.self, forKey: .dispatcherUserId)
        driverProfileId = try c.decodeIfPresent(UUID.self, forKey: .driverProfileId)
        driverId = try c.decodeIfPresent(UUID.self, forKey: .driverId)
        agreementId = try c.decodeIfPresent(UUID.self, forKey: .agreementId)
        dispatcherName = try c.decodeIfPresent(String.self, forKey: .dispatcherName)
        dispatcherCompany = try c.decodeIfPresent(String.self, forKey: .dispatcherCompany)
        loadNumber = try c.decodeIfPresent(String.self, forKey: .loadNumber)
        brokerName = try c.decodeIfPresent(String.self, forKey: .brokerName)
        brokerMcNumber = try c.decodeIfPresent(String.self, forKey: .brokerMcNumber)
        brokerPhone = try c.decodeIfPresent(String.self, forKey: .brokerPhone)
        brokerEmail = try c.decodeIfPresent(String.self, forKey: .brokerEmail)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        destination = try c.decodeIfPresent(String.self, forKey: .destination)
        totalMiles = try c.decodeIfPresent(Double.self, forKey: .totalMiles)
        lineHaulRate = try c.decodeIfPresent(Double.self, forKey: .lineHaulRate)
        fuelSurcharge = try c.decodeIfPresent(Double.self, forKey: .fuelSurcharge)
        accessorialCharges = try c.decodeIfPresent(Double.self, forKey: .accessorialCharges)
        loadGrossAmount = try c.decodeIfPresent(Double.self, forKey: .loadGrossAmount)
        feeType = try c.decodeStringEnum(DispatchFeeType.self, forKey: .feeType, default: .flat)
        feeAmount = try c.decodeIfPresent(Double.self, forKey: .feeAmount)
        feePercentage = try c.decodeIfPresent(Double.self, forKey: .feePercentage)
        invoiceCadence = try c.decodeStringEnum(DispatchInvoiceCadence.self, forKey: .invoiceCadence, default: .weekly)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        status = try c.decodeStringEnum(DispatchOfferStatus.self, forKey: .status, default: .pending)
        acceptedLoadId = try c.decodeIfPresent(UUID.self, forKey: .acceptedLoadId)
        pickupDate = try SPDate.decode(c, forKey: .pickupDate)
        deliveryDate = try SPDate.decode(c, forKey: .deliveryDate)
        dueDate = try SPDate.decode(c, forKey: .dueDate)
        acceptedAt = try SPDate.decode(c, forKey: .acceptedAt)
        declinedAt = try SPDate.decode(c, forKey: .declinedAt)
        createdAt = try SPDate.decode(c, forKey: .createdAt)
        updatedAt = try SPDate.decode(c, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(companyId, forKey: .companyId)
        try c.encodeIfPresent(threadId, forKey: .threadId)
        try c.encodeIfPresent(dispatcherProfileId, forKey: .dispatcherProfileId)
        try c.encodeIfPresent(dispatcherUserId, forKey: .dispatcherUserId)
        try c.encodeIfPresent(driverProfileId, forKey: .driverProfileId)
        try c.encodeIfPresent(driverId, forKey: .driverId)
        try c.encodeIfPresent(agreementId, forKey: .agreementId)
        try c.encodeIfPresent(dispatcherName, forKey: .dispatcherName)
        try c.encodeIfPresent(dispatcherCompany, forKey: .dispatcherCompany)
        try c.encodeIfPresent(loadNumber, forKey: .loadNumber)
        try c.encodeIfPresent(brokerName, forKey: .brokerName)
        try c.encodeIfPresent(brokerMcNumber, forKey: .brokerMcNumber)
        try c.encodeIfPresent(brokerPhone, forKey: .brokerPhone)
        try c.encodeIfPresent(brokerEmail, forKey: .brokerEmail)
        try SPDate.encodeDateOnly(pickupDate, into: &c, forKey: .pickupDate)
        try SPDate.encodeDateOnly(deliveryDate, into: &c, forKey: .deliveryDate)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(destination, forKey: .destination)
        try c.encodeIfPresent(totalMiles, forKey: .totalMiles)
        try c.encodeIfPresent(lineHaulRate, forKey: .lineHaulRate)
        try c.encodeIfPresent(fuelSurcharge, forKey: .fuelSurcharge)
        try c.encodeIfPresent(accessorialCharges, forKey: .accessorialCharges)
        try c.encodeIfPresent(loadGrossAmount, forKey: .loadGrossAmount)
        try c.encode(feeType.rawValue, forKey: .feeType)
        try c.encodeIfPresent(feeAmount, forKey: .feeAmount)
        try c.encodeIfPresent(feePercentage, forKey: .feePercentage)
        try c.encode(invoiceCadence.rawValue, forKey: .invoiceCadence)
        try SPDate.encodeDateOnly(dueDate, into: &c, forKey: .dueDate)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encode(status.rawValue, forKey: .status)
        try c.encodeIfPresent(acceptedLoadId, forKey: .acceptedLoadId)
        try SPDate.encodeISO(acceptedAt, into: &c, forKey: .acceptedAt)
        try SPDate.encodeISO(declinedAt, into: &c, forKey: .declinedAt)
        try SPDate.encodeISO(createdAt, into: &c, forKey: .createdAt)
        try SPDate.encodeISO(updatedAt, into: &c, forKey: .updatedAt)
    }
}

extension DispatcherPaymentRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        companyId = try c.decode(UUID.self, forKey: .companyId)
        dispatcherProfileId = try c.decodeIfPresent(UUID.self, forKey: .dispatcherProfileId)
        dispatcherUserId = try c.decodeIfPresent(UUID.self, forKey: .dispatcherUserId)
        driverProfileId = try c.decodeIfPresent(UUID.self, forKey: .driverProfileId)
        loadId = try c.decodeIfPresent(UUID.self, forKey: .loadId)
        loadOfferId = try c.decodeIfPresent(UUID.self, forKey: .loadOfferId)
        threadId = try c.decodeIfPresent(UUID.self, forKey: .threadId)
        dispatcherName = try c.decodeIfPresent(String.self, forKey: .dispatcherName)
        dispatcherCompany = try c.decodeIfPresent(String.self, forKey: .dispatcherCompany)
        loadNumber = try c.decodeIfPresent(String.self, forKey: .loadNumber)
        loadGrossAmount = try c.decodeIfPresent(Double.self, forKey: .loadGrossAmount) ?? 0
        feeType = try c.decodeStringEnum(DispatchFeeType.self, forKey: .feeType, default: .flat)
        feeAmount = try c.decodeIfPresent(Double.self, forKey: .feeAmount)
        feePercentage = try c.decodeIfPresent(Double.self, forKey: .feePercentage)
        calculatedDispatchFee = try c.decodeIfPresent(Double.self, forKey: .calculatedDispatchFee) ?? 0
        invoiceCadence = try c.decodeStringEnum(DispatchInvoiceCadence.self, forKey: .invoiceCadence, default: .weekly)
        paymentStatus = try c.decodeStringEnum(DispatchPaymentStatus.self, forKey: .paymentStatus, default: .unpaid)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        dueDate = try SPDate.decode(c, forKey: .dueDate)
        createdAt = try SPDate.decode(c, forKey: .createdAt)
        updatedAt = try SPDate.decode(c, forKey: .updatedAt)
        paidAt = try SPDate.decode(c, forKey: .paidAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(companyId, forKey: .companyId)
        try c.encodeIfPresent(dispatcherProfileId, forKey: .dispatcherProfileId)
        try c.encodeIfPresent(dispatcherUserId, forKey: .dispatcherUserId)
        try c.encodeIfPresent(driverProfileId, forKey: .driverProfileId)
        try c.encodeIfPresent(loadId, forKey: .loadId)
        try c.encodeIfPresent(loadOfferId, forKey: .loadOfferId)
        try c.encodeIfPresent(threadId, forKey: .threadId)
        try c.encodeIfPresent(dispatcherName, forKey: .dispatcherName)
        try c.encodeIfPresent(dispatcherCompany, forKey: .dispatcherCompany)
        try c.encodeIfPresent(loadNumber, forKey: .loadNumber)
        try c.encode(loadGrossAmount, forKey: .loadGrossAmount)
        try c.encode(feeType.rawValue, forKey: .feeType)
        try c.encodeIfPresent(feeAmount, forKey: .feeAmount)
        try c.encodeIfPresent(feePercentage, forKey: .feePercentage)
        try c.encode(calculatedDispatchFee, forKey: .calculatedDispatchFee)
        try c.encode(invoiceCadence.rawValue, forKey: .invoiceCadence)
        try c.encode(paymentStatus.rawValue, forKey: .paymentStatus)
        try SPDate.encodeDateOnly(dueDate, into: &c, forKey: .dueDate)
        try c.encodeIfPresent(notes, forKey: .notes)
        try SPDate.encodeISO(createdAt, into: &c, forKey: .createdAt)
        try SPDate.encodeISO(updatedAt, into: &c, forKey: .updatedAt)
        try SPDate.encodeISO(paidAt, into: &c, forKey: .paidAt)
    }
}

extension DispatchServiceRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        companyId = try c.decode(UUID.self, forKey: .companyId)
        requestedByProfileId = try c.decode(UUID.self, forKey: .requestedByProfileId)
        dispatcherProfileId = try c.decodeIfPresent(UUID.self, forKey: .dispatcherProfileId)
        dispatcherUserId = try c.decodeIfPresent(UUID.self, forKey: .dispatcherUserId)
        carrierName = try c.decodeIfPresent(String.self, forKey: .carrierName)
        serviceNotes = try c.decodeIfPresent(String.self, forKey: .serviceNotes)
        status = try c.decodeStringEnum(DispatchServiceRequestStatus.self, forKey: .status, default: .open)
        createdAt = try SPDate.decode(c, forKey: .createdAt)
        updatedAt = try SPDate.decode(c, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(companyId, forKey: .companyId)
        try c.encode(requestedByProfileId, forKey: .requestedByProfileId)
        try c.encodeIfPresent(dispatcherProfileId, forKey: .dispatcherProfileId)
        try c.encodeIfPresent(dispatcherUserId, forKey: .dispatcherUserId)
        try c.encodeIfPresent(carrierName, forKey: .carrierName)
        try c.encodeIfPresent(serviceNotes, forKey: .serviceNotes)
        try c.encode(status.rawValue, forKey: .status)
        try SPDate.encodeISO(createdAt, into: &c, forKey: .createdAt)
        try SPDate.encodeISO(updatedAt, into: &c, forKey: .updatedAt)
    }
}

extension DispatcherReview {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        companyId = try c.decode(UUID.self, forKey: .companyId)
        dispatcherProfileId = try c.decode(UUID.self, forKey: .dispatcherProfileId)
        carrierProfileId = try c.decodeIfPresent(UUID.self, forKey: .carrierProfileId)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        createdAt = try SPDate.decode(c, forKey: .createdAt)
        updatedAt = try SPDate.decode(c, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(companyId, forKey: .companyId)
        try c.encode(dispatcherProfileId, forKey: .dispatcherProfileId)
        try c.encodeIfPresent(carrierProfileId, forKey: .carrierProfileId)
        try c.encode(rating, forKey: .rating)
        try c.encodeIfPresent(comment, forKey: .comment)
        try SPDate.encodeISO(createdAt, into: &c, forKey: .createdAt)
        try SPDate.encodeISO(updatedAt, into: &c, forKey: .updatedAt)
    }
}

extension DispatchAgreement {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        companyId = try c.decode(UUID.self, forKey: .companyId)
        carrierProfileId = try c.decode(UUID.self, forKey: .carrierProfileId)
        dispatcherProfileId = try c.decode(UUID.self, forKey: .dispatcherProfileId)
        dispatcherUserId = try c.decodeIfPresent(UUID.self, forKey: .dispatcherUserId)
        carrierName = try c.decodeIfPresent(String.self, forKey: .carrierName)
        dispatcherName = try c.decodeIfPresent(String.self, forKey: .dispatcherName)
        dispatcherCompany = try c.decodeIfPresent(String.self, forKey: .dispatcherCompany)
        feeType = try c.decodeStringEnum(DispatchFeeType.self, forKey: .feeType, default: .percentageGross)
        feePercentage = try c.decodeIfPresent(Double.self, forKey: .feePercentage)
        feeAmount = try c.decodeIfPresent(Double.self, forKey: .feeAmount)
        status = try c.decodeStringEnum(DispatchAgreementStatus.self, forKey: .status, default: .pending)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        effectiveDate = try SPDate.decode(c, forKey: .effectiveDate)
        createdAt = try SPDate.decode(c, forKey: .createdAt)
        updatedAt = try SPDate.decode(c, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(companyId, forKey: .companyId)
        try c.encode(carrierProfileId, forKey: .carrierProfileId)
        try c.encode(dispatcherProfileId, forKey: .dispatcherProfileId)
        try c.encodeIfPresent(dispatcherUserId, forKey: .dispatcherUserId)
        try c.encodeIfPresent(carrierName, forKey: .carrierName)
        try c.encodeIfPresent(dispatcherName, forKey: .dispatcherName)
        try c.encodeIfPresent(dispatcherCompany, forKey: .dispatcherCompany)
        try SPDate.encodeDateOnly(effectiveDate, into: &c, forKey: .effectiveDate)
        try c.encode(feeType.rawValue, forKey: .feeType)
        try c.encodeIfPresent(feePercentage, forKey: .feePercentage)
        try c.encodeIfPresent(feeAmount, forKey: .feeAmount)
        try c.encode(status.rawValue, forKey: .status)
        try c.encodeIfPresent(notes, forKey: .notes)
        try SPDate.encodeISO(createdAt, into: &c, forKey: .createdAt)
        try SPDate.encodeISO(updatedAt, into: &c, forKey: .updatedAt)
    }
}

extension DispatcherFeeRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        companyId = try c.decode(UUID.self, forKey: .companyId)
        agreementId = try c.decodeIfPresent(UUID.self, forKey: .agreementId)
        dispatcherProfileId = try c.decodeIfPresent(UUID.self, forKey: .dispatcherProfileId)
        dispatcherUserId = try c.decodeIfPresent(UUID.self, forKey: .dispatcherUserId)
        carrierProfileId = try c.decodeIfPresent(UUID.self, forKey: .carrierProfileId)
        loadId = try c.decodeIfPresent(UUID.self, forKey: .loadId)
        settlementDocumentId = try c.decodeIfPresent(UUID.self, forKey: .settlementDocumentId)
        invoiceId = try c.decodeIfPresent(UUID.self, forKey: .invoiceId)
        loadNumber = try c.decodeIfPresent(String.self, forKey: .loadNumber)
        brokerName = try c.decodeIfPresent(String.self, forKey: .brokerName)
        grossRevenue = try c.decodeIfPresent(Double.self, forKey: .grossRevenue) ?? 0
        paymentAmount = try c.decodeIfPresent(Double.self, forKey: .paymentAmount)
        feeType = try c.decodeStringEnum(DispatchFeeType.self, forKey: .feeType, default: .percentageGross)
        feePercentage = try c.decodeIfPresent(Double.self, forKey: .feePercentage)
        feeAmount = try c.decodeIfPresent(Double.self, forKey: .feeAmount)
        calculatedDispatchFee = try c.decodeIfPresent(Double.self, forKey: .calculatedDispatchFee) ?? 0
        paymentStatus = try c.decodeStringEnum(DispatchPaymentStatus.self, forKey: .paymentStatus, default: .unpaid)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        sourceType = try c.decodeIfPresent(String.self, forKey: .sourceType)
        ocrConfidence = try c.decodeIfPresent(Double.self, forKey: .ocrConfidence)
        dueDate = try SPDate.decode(c, forKey: .dueDate)
        paymentDate = try SPDate.decode(c, forKey: .paymentDate)
        createdAt = try SPDate.decode(c, forKey: .createdAt)
        updatedAt = try SPDate.decode(c, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(companyId, forKey: .companyId)
        try c.encodeIfPresent(agreementId, forKey: .agreementId)
        try c.encodeIfPresent(dispatcherProfileId, forKey: .dispatcherProfileId)
        try c.encodeIfPresent(dispatcherUserId, forKey: .dispatcherUserId)
        try c.encodeIfPresent(carrierProfileId, forKey: .carrierProfileId)
        try c.encodeIfPresent(loadId, forKey: .loadId)
        try c.encodeIfPresent(settlementDocumentId, forKey: .settlementDocumentId)
        try c.encodeIfPresent(invoiceId, forKey: .invoiceId)
        try c.encodeIfPresent(loadNumber, forKey: .loadNumber)
        try c.encodeIfPresent(brokerName, forKey: .brokerName)
        try c.encode(grossRevenue, forKey: .grossRevenue)
        try c.encodeIfPresent(paymentAmount, forKey: .paymentAmount)
        try c.encode(feeType.rawValue, forKey: .feeType)
        try c.encodeIfPresent(feePercentage, forKey: .feePercentage)
        try c.encodeIfPresent(feeAmount, forKey: .feeAmount)
        try c.encode(calculatedDispatchFee, forKey: .calculatedDispatchFee)
        try c.encode(paymentStatus.rawValue, forKey: .paymentStatus)
        try SPDate.encodeDateOnly(dueDate, into: &c, forKey: .dueDate)
        try SPDate.encodeDateOnly(paymentDate, into: &c, forKey: .paymentDate)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(sourceType, forKey: .sourceType)
        try c.encodeIfPresent(ocrConfidence, forKey: .ocrConfidence)
        try SPDate.encodeISO(createdAt, into: &c, forKey: .createdAt)
        try SPDate.encodeISO(updatedAt, into: &c, forKey: .updatedAt)
    }
}

extension DispatcherInvoice {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        companyId = try c.decode(UUID.self, forKey: .companyId)
        agreementId = try c.decodeIfPresent(UUID.self, forKey: .agreementId)
        dispatcherProfileId = try c.decodeIfPresent(UUID.self, forKey: .dispatcherProfileId)
        dispatcherUserId = try c.decodeIfPresent(UUID.self, forKey: .dispatcherUserId)
        carrierProfileId = try c.decodeIfPresent(UUID.self, forKey: .carrierProfileId)
        invoiceNumber = try c.decodeIfPresent(String.self, forKey: .invoiceNumber)
        totalGrossRevenue = try c.decodeIfPresent(Double.self, forKey: .totalGrossRevenue) ?? 0
        totalFeesDue = try c.decodeIfPresent(Double.self, forKey: .totalFeesDue) ?? 0
        paymentStatus = try c.decodeStringEnum(DispatchPaymentStatus.self, forKey: .paymentStatus, default: .unpaid)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        periodStart = try SPDate.decode(c, forKey: .periodStart)
        periodEnd = try SPDate.decode(c, forKey: .periodEnd)
        dueDate = try SPDate.decode(c, forKey: .dueDate)
        paymentDate = try SPDate.decode(c, forKey: .paymentDate)
        createdAt = try SPDate.decode(c, forKey: .createdAt)
        updatedAt = try SPDate.decode(c, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(companyId, forKey: .companyId)
        try c.encodeIfPresent(agreementId, forKey: .agreementId)
        try c.encodeIfPresent(dispatcherProfileId, forKey: .dispatcherProfileId)
        try c.encodeIfPresent(dispatcherUserId, forKey: .dispatcherUserId)
        try c.encodeIfPresent(carrierProfileId, forKey: .carrierProfileId)
        try c.encodeIfPresent(invoiceNumber, forKey: .invoiceNumber)
        try SPDate.encodeDateOnly(periodStart, into: &c, forKey: .periodStart)
        try SPDate.encodeDateOnly(periodEnd, into: &c, forKey: .periodEnd)
        try c.encode(totalGrossRevenue, forKey: .totalGrossRevenue)
        try c.encode(totalFeesDue, forKey: .totalFeesDue)
        try c.encode(paymentStatus.rawValue, forKey: .paymentStatus)
        try SPDate.encodeDateOnly(dueDate, into: &c, forKey: .dueDate)
        try SPDate.encodeDateOnly(paymentDate, into: &c, forKey: .paymentDate)
        try c.encodeIfPresent(notes, forKey: .notes)
        try SPDate.encodeISO(createdAt, into: &c, forKey: .createdAt)
        try SPDate.encodeISO(updatedAt, into: &c, forKey: .updatedAt)
    }
}
