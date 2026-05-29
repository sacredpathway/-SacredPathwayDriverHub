import Foundation

/// Lifecycle states a load moves through. Stored as a plain string in the
/// existing `loads.status` column — no DB migration required.
///
/// Default policy:
/// - newly-created load with no `driverId` ⇒ `unassigned`
/// - newly-created load with a `driverId`  ⇒ `assigned`
/// - any load whose delivery date has passed and isn't yet settled MAY be
///   marked `readyForSettlement` by the user (advisory; not auto-promoted)
/// - load is marked `settled` after a paystub is generated covering it
enum LoadStatus: String, CaseIterable {
    case unassigned         = "unassigned"
    case assigned           = "assigned"
    case readyForSettlement = "ready_for_settlement"
    case settled            = "settled"

    var displayName: String {
        switch self {
        case .unassigned:         return "Unassigned"
        case .assigned:           return "Assigned"
        case .readyForSettlement: return "Ready for Settlement"
        case .settled:            return "Settled"
        }
    }
}

struct Load: Codable, Identifiable {
    var id: UUID?
    let profileId: UUID
    var driverId: UUID?
    var loadNumber: String?
    var brokerName: String?
    var brokerMcNumber: String?
    var truckNumber: String?
    var trailerNumber: String?
    var pickupDate: Date?         // Postgres DATE
    var deliveryDate: Date?       // Postgres DATE
    var origin: String?
    var destination: String?
    var totalMiles: Double?
    var lineHaulRate: Double?
    var fuelSurcharge: Double?
    var accessorialCharges: Double?
    var totalRevenue: Double?
    var weightValue: Double?
    var weightUnit: String?
    var dispatchThreadId: UUID?
    var dispatchLoadOfferId: UUID?
    var dispatcherName: String?
    var dispatcherCompany: String?
    var status: String?
    var createdAt: Date?          // Postgres TIMESTAMPTZ
    var updatedAt: Date?          // Postgres TIMESTAMPTZ

    // --- Per-load broker rep attribution (added v2.0.2 / 2026-05-17) ---
    // Same TQL company can have multiple reps (Aaron Dini, Mary Smith). Each
    // load snapshots the exact rep/phone/email used on THAT load so future
    // edits to the broker_contacts row don't rewrite history.
    var brokerId: UUID?
    var brokerContactId: UUID?
    var brokerContactName: String?
    var brokerContactPhone: String?
    var brokerPhoneExtension: String?
    var brokerContactEmail: String?

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case driverId = "driver_id"
        case loadNumber = "load_number"
        case brokerName = "broker_name"
        case brokerMcNumber = "broker_mc_number"
        case truckNumber = "truck_number"
        case trailerNumber = "trailer_number"
        case pickupDate = "pickup_date"
        case deliveryDate = "delivery_date"
        case origin, destination
        case totalMiles = "total_miles"
        case lineHaulRate = "line_haul_rate"
        case fuelSurcharge = "fuel_surcharge"
        case accessorialCharges = "accessorial_charges"
        case totalRevenue = "total_revenue"
        case weightValue = "weight_value"
        case weightUnit = "weight_unit"
        case dispatchThreadId = "dispatch_thread_id"
        case dispatchLoadOfferId = "dispatch_load_offer_id"
        case dispatcherName = "dispatcher_name"
        case dispatcherCompany = "dispatcher_company"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case brokerId = "broker_id"
        case brokerContactId = "broker_contact_id"
        case brokerContactName = "broker_contact_name"
        case brokerContactPhone = "broker_contact_phone"
        case brokerPhoneExtension = "broker_phone_extension"
        case brokerContactEmail = "broker_contact_email"
    }

    // Computed properties for quick math
    var expenses: Double { 0 } // Will be calculated from expenses table
    var profit: Double { (totalRevenue ?? 0) - expenses }
    var ratePerMile: Double {
        guard let miles = totalMiles, miles > 0, let rev = totalRevenue else { return 0 }
        return rev / miles
    }

    var weightDisplay: String? {
        guard let value = weightValue, value > 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 1
        let formatted = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        let unit = weightUnit == "kg" ? "kg" : "lbs"
        return "\(formatted) \(unit)"
    }

    /// Decoded LoadStatus, defaulting based on driver assignment when the
    /// row was written before the status field was being populated.
    var loadStatus: LoadStatus {
        if let raw = status, let parsed = LoadStatus(rawValue: raw) {
            return parsed
        }
        return driverId == nil ? .unassigned : .assigned
    }

    /// True if this load has already been rolled into a paystub. Settled
    /// loads are hidden from the Paystub Maker picker by default.
    var isSettled: Bool { loadStatus == .settled }

    // MARK: - Init

    init(
        id: UUID? = nil,
        profileId: UUID,
        driverId: UUID? = nil,
        loadNumber: String? = nil,
        brokerName: String? = nil,
        brokerMcNumber: String? = nil,
        truckNumber: String? = nil,
        trailerNumber: String? = nil,
        pickupDate: Date? = nil,
        deliveryDate: Date? = nil,
        origin: String? = nil,
        destination: String? = nil,
        totalMiles: Double? = nil,
        lineHaulRate: Double? = nil,
        fuelSurcharge: Double? = nil,
        accessorialCharges: Double? = nil,
        totalRevenue: Double? = nil,
        weightValue: Double? = nil,
        weightUnit: String? = nil,
        dispatchThreadId: UUID? = nil,
        dispatchLoadOfferId: UUID? = nil,
        dispatcherName: String? = nil,
        dispatcherCompany: String? = nil,
        status: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        brokerId: UUID? = nil,
        brokerContactId: UUID? = nil,
        brokerContactName: String? = nil,
        brokerContactPhone: String? = nil,
        brokerPhoneExtension: String? = nil,
        brokerContactEmail: String? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.driverId = driverId
        self.loadNumber = loadNumber
        self.brokerName = brokerName
        self.brokerMcNumber = brokerMcNumber
        self.truckNumber = truckNumber
        self.trailerNumber = trailerNumber
        self.pickupDate = pickupDate
        self.deliveryDate = deliveryDate
        self.origin = origin
        self.destination = destination
        self.totalMiles = totalMiles
        self.lineHaulRate = lineHaulRate
        self.fuelSurcharge = fuelSurcharge
        self.accessorialCharges = accessorialCharges
        self.totalRevenue = totalRevenue
        self.weightValue = weightValue
        self.weightUnit = weightUnit
        self.dispatchThreadId = dispatchThreadId
        self.dispatchLoadOfferId = dispatchLoadOfferId
        self.dispatcherName = dispatcherName
        self.dispatcherCompany = dispatcherCompany
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.brokerId = brokerId
        self.brokerContactId = brokerContactId
        self.brokerContactName = brokerContactName
        self.brokerContactPhone = brokerContactPhone
        self.brokerPhoneExtension = brokerPhoneExtension
        self.brokerContactEmail = brokerContactEmail
    }

    // MARK: - Custom Codable (see SPDate for why)

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                    = try c.decodeIfPresent(UUID.self,   forKey: .id)
        profileId             = try c.decode(UUID.self,            forKey: .profileId)
        driverId              = try c.decodeIfPresent(UUID.self,   forKey: .driverId)
        loadNumber            = try c.decodeIfPresent(String.self, forKey: .loadNumber)
        brokerName            = try c.decodeIfPresent(String.self, forKey: .brokerName)
        brokerMcNumber        = try c.decodeIfPresent(String.self, forKey: .brokerMcNumber)
        truckNumber           = try c.decodeIfPresent(String.self, forKey: .truckNumber)
        trailerNumber         = try c.decodeIfPresent(String.self, forKey: .trailerNumber)
        origin                = try c.decodeIfPresent(String.self, forKey: .origin)
        destination           = try c.decodeIfPresent(String.self, forKey: .destination)
        totalMiles            = try c.decodeIfPresent(Double.self, forKey: .totalMiles)
        lineHaulRate          = try c.decodeIfPresent(Double.self, forKey: .lineHaulRate)
        fuelSurcharge         = try c.decodeIfPresent(Double.self, forKey: .fuelSurcharge)
        accessorialCharges    = try c.decodeIfPresent(Double.self, forKey: .accessorialCharges)
        totalRevenue          = try c.decodeIfPresent(Double.self, forKey: .totalRevenue)
        weightValue           = try c.decodeIfPresent(Double.self, forKey: .weightValue)
        weightUnit            = try c.decodeIfPresent(String.self, forKey: .weightUnit)
        dispatchThreadId      = try c.decodeIfPresent(UUID.self,   forKey: .dispatchThreadId)
        dispatchLoadOfferId   = try c.decodeIfPresent(UUID.self,   forKey: .dispatchLoadOfferId)
        dispatcherName        = try c.decodeIfPresent(String.self, forKey: .dispatcherName)
        dispatcherCompany     = try c.decodeIfPresent(String.self, forKey: .dispatcherCompany)
        status                = try c.decodeIfPresent(String.self, forKey: .status)
        brokerId              = try c.decodeIfPresent(UUID.self,   forKey: .brokerId)
        brokerContactId       = try c.decodeIfPresent(UUID.self,   forKey: .brokerContactId)
        brokerContactName     = try c.decodeIfPresent(String.self, forKey: .brokerContactName)
        brokerContactPhone    = try c.decodeIfPresent(String.self, forKey: .brokerContactPhone)
        brokerPhoneExtension  = try c.decodeIfPresent(String.self, forKey: .brokerPhoneExtension)
        brokerContactEmail    = try c.decodeIfPresent(String.self, forKey: .brokerContactEmail)
        pickupDate            = try SPDate.decode(c, forKey: .pickupDate)
        deliveryDate          = try SPDate.decode(c, forKey: .deliveryDate)
        createdAt             = try SPDate.decode(c, forKey: .createdAt)
        updatedAt             = try SPDate.decode(c, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id,                   forKey: .id)
        try c.encode(profileId,                     forKey: .profileId)
        try c.encodeIfPresent(driverId,             forKey: .driverId)
        try c.encodeIfPresent(loadNumber,           forKey: .loadNumber)
        try c.encodeIfPresent(brokerName,           forKey: .brokerName)
        try c.encodeIfPresent(brokerMcNumber,       forKey: .brokerMcNumber)
        try c.encodeIfPresent(truckNumber,          forKey: .truckNumber)
        try c.encodeIfPresent(trailerNumber,        forKey: .trailerNumber)
        try c.encodeIfPresent(origin,               forKey: .origin)
        try c.encodeIfPresent(destination,          forKey: .destination)
        try c.encodeIfPresent(totalMiles,           forKey: .totalMiles)
        try c.encodeIfPresent(lineHaulRate,         forKey: .lineHaulRate)
        try c.encodeIfPresent(fuelSurcharge,        forKey: .fuelSurcharge)
        try c.encodeIfPresent(accessorialCharges,   forKey: .accessorialCharges)
        try c.encodeIfPresent(totalRevenue,         forKey: .totalRevenue)
        try c.encodeIfPresent(weightValue,          forKey: .weightValue)
        try c.encodeIfPresent(weightUnit,           forKey: .weightUnit)
        try c.encodeIfPresent(dispatchThreadId,     forKey: .dispatchThreadId)
        try c.encodeIfPresent(dispatchLoadOfferId,  forKey: .dispatchLoadOfferId)
        try c.encodeIfPresent(dispatcherName,       forKey: .dispatcherName)
        try c.encodeIfPresent(dispatcherCompany,    forKey: .dispatcherCompany)
        try c.encodeIfPresent(status,               forKey: .status)
        try c.encodeIfPresent(brokerId,             forKey: .brokerId)
        try c.encodeIfPresent(brokerContactId,      forKey: .brokerContactId)
        try c.encodeIfPresent(brokerContactName,    forKey: .brokerContactName)
        try c.encodeIfPresent(brokerContactPhone,   forKey: .brokerContactPhone)
        try c.encodeIfPresent(brokerPhoneExtension, forKey: .brokerPhoneExtension)
        try c.encodeIfPresent(brokerContactEmail,   forKey: .brokerContactEmail)
        try SPDate.encodeDateOnly(pickupDate,   into: &c, forKey: .pickupDate)
        try SPDate.encodeDateOnly(deliveryDate, into: &c, forKey: .deliveryDate)
        try SPDate.encodeISO(createdAt,          into: &c, forKey: .createdAt)
        try SPDate.encodeISO(updatedAt,          into: &c, forKey: .updatedAt)
    }
}
