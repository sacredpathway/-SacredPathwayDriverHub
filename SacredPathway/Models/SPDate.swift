import Foundation

/// Shared helpers for decoding/encoding dates that come from Supabase.
///
/// Problem we're solving:
///   Postgres `DATE` columns return bare "YYYY-MM-DD" strings.
///   Postgres `TIMESTAMPTZ` columns can return "...+00:00" with or
///   without fractional seconds.
///   Swift's default `.iso8601` date strategy only parses one of
///   those flavors and throws `DecodingError.dataCorrupted` for the
///   rest — which surfaces in the UI as:
///   "The data couldn't be read because it isn't in the correct format."
///
/// Use `SPDate.decode(_:_:forKey:)` and `SPDate.encode(_:_:forKey:)`
/// from custom `init(from:)` / `encode(to:)` on any model that has
/// DATE or TIMESTAMPTZ fields.
enum SPDate {

    // MARK: Public API

    /// Decode an optional date from a keyed container. Tries (in order)
    /// ISO8601 with fractional seconds, ISO8601 without, then bare
    /// "YYYY-MM-DD". Returns `nil` if the key is missing, the value is
    /// null, or none of the formatters match.
    static func decode<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> Date? {
        guard let s = try container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return parse(s)
    }

    /// Encode an optional date as "YYYY-MM-DD" — the format Postgres
    /// DATE columns accept. Use this for any field that maps to a
    /// DATE column. For TIMESTAMPTZ columns use `encodeISO` instead.
    static func encodeDateOnly<K: CodingKey>(
        _ value: Date?,
        into container: inout KeyedEncodingContainer<K>,
        forKey key: K
    ) throws {
        guard let value else { return }
        try container.encode(dateOnly.string(from: value), forKey: key)
    }

    /// Encode an optional date as ISO8601 with fractional seconds — the
    /// format Postgres TIMESTAMPTZ round-trips cleanly with.
    static func encodeISO<K: CodingKey>(
        _ value: Date?,
        into container: inout KeyedEncodingContainer<K>,
        forKey key: K
    ) throws {
        guard let value else { return }
        try container.encode(isoFractional.string(from: value), forKey: key)
    }

    /// Parse any Supabase/Postgres date string we've seen in the wild.
    static func parse(_ s: String) -> Date? {
        if let d = isoFractional.date(from: s) { return d }
        if let d = iso.date(from: s)           { return d }
        if let d = dateOnly.date(from: s)      { return d }
        return nil
    }

    // MARK: Formatters

    /// "YYYY-MM-DD" — Postgres DATE.
    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar   = Calendar(identifier: .iso8601)
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.timeZone   = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// "2026-04-19T10:37:00Z" — ISO8601 without fractional seconds.
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// "2026-04-19T10:37:00.123456Z" — ISO8601 with fractional seconds.
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
