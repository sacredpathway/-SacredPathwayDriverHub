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
    var pickupDate: Date?         // Postgres DATE
    var deliveryDate: Date?       // Postgres DATE
    var origin: String?
    var destination: String?
    var totalMiles: Double?
    var lineHaulRate: Double?
    var fuelSurcharge: Double?
    var accessorialCharges: Double?
    var totalRevenue: Double?
    var status: String?
    var createdAt: Date?          // Postgres TIMESTAMPTZ
    var updatedAt: Date?          // Postgres TIMESTAMPTZ

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case driverId = "driver_id"
        case loadNumber = "load_number"
        case brokerName = "broker_name"
        case brokerMcNumber = "broker_mc_number"
        case pickupDate = "pickup_date"
        case deliveryDate = "delivery_date"
        case origin, destination
        case totalMiles = "total_miles"
        case lineHaulRate = "line_haul_rate"
        case fuelSurcharge = "fuel_surcharge"
        case accessorialCharges = "accessorial_charges"
        case totalRevenue = "total_revenue"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    // Computed properties for quick math
    var expenses: Double { 0 } // Will be calculated from expenses table
    var profit: Double { (totalRevenue ?? 0) - expenses }
    var ratePerMile: Double {
        guard let miles = totalMiles, miles > 0, let rev = totalRevenue else { return 0 }
        return rev / miles
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
        pickupDate: Date? = nil,
        deliveryDate: Date? = nil,
        origin: String? = nil,
        destination: String? = nil,
        totalMiles: Double? = nil,
        lineHaulRate: Double? = nil,
        fuelSurcharge: Double? = nil,
        accessorialCharges: Double? = nil,
        totalRevenue: Double? = nil,
        status: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.driverId = driverId
        self.loadNumber = loadNumber
        self.brokerName = brokerName
        self.brokerMcNumber = brokerMcNumber
        self.pickupDate = pickupDate
        self.deliveryDate = deliveryDate
        self.origin = origin
        self.destination = destination
        self.totalMiles = totalMiles
        self.lineHaulRate = lineHaulRate
        self.fuelSurcharge = fuelSurcharge
        self.accessorialCharges = accessorialCharges
        self.totalRevenue = totalRevenue
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Custom Codable (see SPDate for why)

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                  = try c.decodeIfPresent(UUID.self,   forKey: .id)
        profileId           = try c.decode(UUID.self,            forKey: .profileId)
        driverId            = try c.decodeIfPresent(UUID.self,   forKey: .driverId)
        loadNumber          = try c.decodeIfPresent(String.self, forKey: .loadNumber)
        brokerName          = try c.decodeIfPresent(String.self, forKey: .brokerName)
        brokerMcNumber      = try c.decodeIfPresent(String.self, forKey: .brokerMcNumber)
        origin              = try c.decodeIfPresent(String.self, forKey: .origin)
        destination         = try c.decodeIfPresent(String.self, forKey: .destination)
        totalMiles          = try c.decodeIfPresent(Double.self, forKey: .totalMiles)
        lineHaulRate        = try c.decodeIfPresent(Double.self, forKey: .lineHaulRate)
        fuelSurcharge       = try c.decodeIfPresent(Double.self, forKey: .fuelSurcharge)
        accessorialCharges  = try c.decodeIfPresent(Double.self, forKey: .accessorialCharges)
        totalRevenue        = try c.decodeIfPresent(Double.self, forKey: .totalRevenue)
        status              = try c.decodeIfPresent(String.self, forKey: .status)
        pickupDate          = try SPDate.decode(c, forKey: .pickupDate)
        deliveryDate        = try SPDate.decode(c, forKey: .deliveryDate)
        createdAt           = try SPDate.decode(c, forKey: .createdAt)
        updatedAt           = try SPDate.decode(c, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id,                 forKey: .id)
        try c.encode(profileId,                   forKey: .profileId)
        try c.encodeIfPresent(driverId,           forKey: .driverId)
        try c.encodeIfPresent(loadNumber,         forKey: .loadNumber)
        try c.encodeIfPresent(brokerName,         forKey: .brokerName)
        try c.encodeIfPresent(brokerMcNumber,     forKey: .brokerMcNumber)
        try c.encodeIfPresent(origin,             forKey: .origin)
        try c.encodeIfPresent(destination,        forKey: .destination)
        try c.encodeIfPresent(totalMiles,         forKey: .totalMiles)
        try c.encodeIfPresent(lineHaulRate,       forKey: .lineHaulRate)
        try c.encodeIfPresent(fuelSurcharge,      forKey: .fuelSurcharge)
        try c.encodeIfPresent(accessorialCharges, forKey: .accessorialCharges)
        try c.encodeIfPresent(totalRevenue,       forKey: .totalRevenue)
        try c.encodeIfPresent(status,             forKey: .status)
        try SPDate.encodeDateOnly(pickupDate,   into: &c, forKey: .pickupDate)
        try SPDate.encodeDateOnly(deliveryDate, into: &c, forKey: .deliveryDate)
        try SPDate.encodeISO(createdAt,          into: &c, forKey: .createdAt)
        try SPDate.encodeISO(updatedAt,          into: &c, forKey: .updatedAt)
    }
}
