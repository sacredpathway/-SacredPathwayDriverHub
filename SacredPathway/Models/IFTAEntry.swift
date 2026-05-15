import Foundation

struct IFTAEntry: Codable, Identifiable {
    var id: UUID?
    let profileId: UUID
    var loadId: UUID?
    var date: Date                     // Postgres DATE, required
    var stateCode: String
    var milesDriven: Double
    var fuelGallons: Double
    var fuelPricePerGallon: Double?
    var totalFuelCost: Double?
    var notes: String?
    var createdAt: Date?               // Postgres TIMESTAMPTZ

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case loadId = "load_id"
        case date = "entry_date"
        case stateCode = "state_code"
        case milesDriven = "miles_driven"
        case fuelGallons = "fuel_gallons"
        case fuelPricePerGallon = "fuel_price_per_gallon"
        case totalFuelCost = "total_fuel_cost"
        case notes
        case createdAt = "created_at"
    }

    init(
        id: UUID? = nil,
        profileId: UUID,
        loadId: UUID? = nil,
        date: Date,
        stateCode: String,
        milesDriven: Double = 0,
        fuelGallons: Double = 0,
        fuelPricePerGallon: Double? = nil,
        totalFuelCost: Double? = nil,
        notes: String? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.loadId = loadId
        self.date = date
        self.stateCode = stateCode
        self.milesDriven = milesDriven
        self.fuelGallons = fuelGallons
        self.fuelPricePerGallon = fuelPricePerGallon
        self.totalFuelCost = totalFuelCost
        self.notes = notes
        self.createdAt = createdAt
    }

    // MARK: - Custom Codable

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        profileId = try c.decode(UUID.self, forKey: .profileId)
        loadId = try c.decodeIfPresent(UUID.self, forKey: .loadId)
        date = try {
            if let d = try SPDate.decode(c, forKey: .date) {
                return d
            }
            throw DecodingError.missingRequiredField(in: c, at: .date)
        }()
        stateCode = try c.decode(String.self, forKey: .stateCode)
        milesDriven = try c.decode(Double.self, forKey: .milesDriven)
        fuelGallons = try c.decode(Double.self, forKey: .fuelGallons)
        fuelPricePerGallon = try c.decodeIfPresent(Double.self, forKey: .fuelPricePerGallon)
        totalFuelCost = try c.decodeIfPresent(Double.self, forKey: .totalFuelCost)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try SPDate.decode(c, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(profileId, forKey: .profileId)
        try c.encodeIfPresent(loadId, forKey: .loadId)
        try SPDate.encodeDateOnly(date, into: &c, forKey: .date)
        try c.encode(stateCode, forKey: .stateCode)
        try c.encode(milesDriven, forKey: .milesDriven)
        try c.encode(fuelGallons, forKey: .fuelGallons)
        try c.encodeIfPresent(fuelPricePerGallon, forKey: .fuelPricePerGallon)
        try c.encodeIfPresent(totalFuelCost, forKey: .totalFuelCost)
        try c.encodeIfPresent(notes, forKey: .notes)
        try SPDate.encodeISO(createdAt, into: &c, forKey: .createdAt)
    }
}

// MARK: - Decoding Helper

extension DecodingError {
    static func missingRequiredField<K: CodingKey>(
        in container: KeyedDecodingContainer<K>,
        at key: K
    ) -> DecodingError {
        return DecodingError.keyNotFound(
            key,
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Missing required field: \(key.stringValue)"
            )
        )
    }
}
