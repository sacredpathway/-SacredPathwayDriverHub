import Foundation

// MARK: - SPDate
//
// Shared helpers for decoding/encoding dates that come from Supabase.
//
// Defined inside Expense.swift (not its own file) so the Xcode project
// picks it up automatically — any new file would need to be added to
// the target membership, and we want zero project-surgery to compile.
// Load.swift and Settlement.swift use this type; since Swift types
// default to `internal`, anything in the same target can see it.
//
// Problem it solves:
//   Postgres `DATE` columns return bare "YYYY-MM-DD" strings.
//   Postgres `TIMESTAMPTZ` columns can return "...+00:00" with or
//   without fractional seconds. Swift's default `.iso8601` date
//   strategy only parses one flavor and throws
//   `DecodingError.dataCorrupted` for the rest, surfaced in the UI
//   as "The data couldn't be read because it isn't in the correct format."

enum SPDate {

    /// Decode an optional date from a keyed container. Tries ISO8601 w/
    /// fractional seconds, then plain ISO8601, then bare "YYYY-MM-DD".
    static func decode<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> Date? {
        guard let s = try container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return parse(s)
    }

    /// Encode as "YYYY-MM-DD" for Postgres DATE columns.
    static func encodeDateOnly<K: CodingKey>(
        _ value: Date?,
        into container: inout KeyedEncodingContainer<K>,
        forKey key: K
    ) throws {
        guard let value else { return }
        try container.encode(dateOnly.string(from: value), forKey: key)
    }

    /// Encode as ISO8601 w/ fractional seconds for Postgres TIMESTAMPTZ.
    static func encodeISO<K: CodingKey>(
        _ value: Date?,
        into container: inout KeyedEncodingContainer<K>,
        forKey key: K
    ) throws {
        guard let value else { return }
        try container.encode(isoFractional.string(from: value), forKey: key)
    }

    /// Parse any date string Supabase/Postgres has been seen to return.
    static func parse(_ s: String) -> Date? {
        if let d = isoFractional.date(from: s) { return d }
        if let d = iso.date(from: s)           { return d }
        if let d = dateOnly.date(from: s)      { return d }
        return nil
    }

    // MARK: Formatters

    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar   = Calendar(identifier: .iso8601)
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.timeZone   = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Expense

struct Expense: Codable, Identifiable {
    var id: UUID?
    var loadId: UUID?
    let profileId: UUID
    var category: String
    var amount: Double
    var vendorName: String?
    var description: String?
    var gallons: Double?
    var pricePerGallon: Double?
    var defGallons: Double?           // Diesel Exhaust Fluid — fuel category only
    var defPricePerGallon: Double?    // Diesel Exhaust Fluid — fuel category only
    /// Server-stored DEF subtotal (`def_gallons * def_price_per_gallon`).
    /// Persisted explicitly so analytics queries don't have to recompute it
    /// per row — and so the math is preserved even if input values are later
    /// edited to zero. Always nil when DEF wasn't purchased.
    var defTotal: Double?
    var receiptDate: Date?    // Postgres DATE
    var createdAt: Date?      // Postgres TIMESTAMPTZ

    enum CodingKeys: String, CodingKey {
        case id
        case loadId = "load_id"
        case profileId = "profile_id"
        case category, amount
        case vendorName = "vendor_name"
        case description, gallons
        case pricePerGallon = "price_per_gallon"
        case defGallons = "def_gallons"
        case defPricePerGallon = "def_price_per_gallon"
        case defTotal = "def_total"
        case receiptDate = "receipt_date"
        case createdAt = "created_at"
    }

    init(
        id: UUID? = nil,
        loadId: UUID? = nil,
        profileId: UUID,
        category: String,
        amount: Double,
        vendorName: String? = nil,
        description: String? = nil,
        gallons: Double? = nil,
        pricePerGallon: Double? = nil,
        defGallons: Double? = nil,
        defPricePerGallon: Double? = nil,
        defTotal: Double? = nil,
        receiptDate: Date? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.loadId = loadId
        self.profileId = profileId
        self.category = category
        self.amount = amount
        self.vendorName = vendorName
        self.description = description
        self.gallons = gallons
        self.pricePerGallon = pricePerGallon
        self.defGallons = defGallons
        self.defPricePerGallon = defPricePerGallon
        self.defTotal = defTotal
        self.receiptDate = receiptDate
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decodeIfPresent(UUID.self,   forKey: .id)
        loadId         = try c.decodeIfPresent(UUID.self,   forKey: .loadId)
        profileId      = try c.decode(UUID.self,            forKey: .profileId)
        category       = try c.decode(String.self,          forKey: .category)
        amount         = try c.decode(Double.self,          forKey: .amount)
        vendorName     = try c.decodeIfPresent(String.self, forKey: .vendorName)
        description    = try c.decodeIfPresent(String.self, forKey: .description)
        gallons           = try c.decodeIfPresent(Double.self, forKey: .gallons)
        pricePerGallon    = try c.decodeIfPresent(Double.self, forKey: .pricePerGallon)
        defGallons        = try c.decodeIfPresent(Double.self, forKey: .defGallons)
        defPricePerGallon = try c.decodeIfPresent(Double.self, forKey: .defPricePerGallon)
        defTotal          = try c.decodeIfPresent(Double.self, forKey: .defTotal)
        receiptDate       = try SPDate.decode(c, forKey: .receiptDate)
        createdAt         = try SPDate.decode(c, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id,             forKey: .id)
        try c.encodeIfPresent(loadId,         forKey: .loadId)
        try c.encode(profileId,               forKey: .profileId)
        try c.encode(category,                forKey: .category)
        try c.encode(amount,                  forKey: .amount)
        try c.encodeIfPresent(vendorName,     forKey: .vendorName)
        try c.encodeIfPresent(description,    forKey: .description)
        try c.encodeIfPresent(gallons,           forKey: .gallons)
        try c.encodeIfPresent(pricePerGallon,    forKey: .pricePerGallon)
        try c.encodeIfPresent(defGallons,        forKey: .defGallons)
        try c.encodeIfPresent(defPricePerGallon, forKey: .defPricePerGallon)
        try c.encodeIfPresent(defTotal,          forKey: .defTotal)
        try SPDate.encodeDateOnly(receiptDate, into: &c, forKey: .receiptDate)
        try SPDate.encodeISO(createdAt,        into: &c, forKey: .createdAt)
    }
}
