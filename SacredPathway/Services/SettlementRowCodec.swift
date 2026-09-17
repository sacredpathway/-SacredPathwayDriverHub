import Foundation

// =============================================================================
//  SettlementRowCodec — JSON shape for the Supabase settlement tables
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). Pure Foundation.
//
//  The settlement child models use plain `Date` properties. Postgres has two
//  kinds of date column in these tables and they must be written differently:
//
//    DATE         pickup_date, delivery_date, date, effective_start_date,
//                 effective_end_date           → "yyyy-MM-dd"  (SPDate.dateOnly)
//    TIMESTAMPTZ  created_at, updated_at, timestamp, …
//                                              → ISO-8601 with fractional secs
//
//  This codec decides per KEY, using the same SPDate formatters every other
//  model in the app already uses, so a settlement row round-trips exactly the
//  way loads and expenses do. Reading accepts every shape SPDate accepts.
// =============================================================================

enum SettlementRowCodec {

    static let dateOnlyKeys: Set<String> = [
        "pickup_date", "delivery_date", "date",
        "effective_start_date", "effective_end_date",
        "settlement_period_start", "settlement_period_end"
    ]

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            let key = encoder.codingPath.last?.stringValue ?? ""
            var c = encoder.singleValueContainer()
            if dateOnlyKeys.contains(key) {
                try c.encode(SPDate.dateOnly.string(from: date))
            } else {
                try c.encode(SPDate.isoFractional.string(from: date))
            }
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self), let date = SPDate.parse(s) {
                return date
            }
            if let t = try? c.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: t)
            }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unrecognised date value")
        }
        return d
    }()

    /// Encodes rows to a JSON array. The cloud store turns this into
    /// `[[String: AnyJSON]]` for PostgREST.
    static func encodeRows<T: Encodable>(_ rows: [T]) throws -> Data {
        try encoder.encode(rows)
    }

    static func decodeRows<T: Decodable>(_ type: T.Type, from data: Data) throws -> [T] {
        try decoder.decode([T].self, from: data)
    }

    /// JSON object for a single row — used by tests and by patch updates.
    static func jsonObject<T: Encodable>(_ row: T) throws -> [String: Any] {
        let data = try encoder.encode(row)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
