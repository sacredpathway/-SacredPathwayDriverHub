import Foundation

// =============================================================================
//  SettlementNumberService — human-readable, unique settlement numbers
// -----------------------------------------------------------------------------
//  Format: PREFIX-YYYY-NNNN   e.g. SP-2026-0042
//
//  The number is what the driver quotes on the phone, so it must be stable,
//  readable and never reused. Generation is a pure function of the numbers that
//  already exist, which makes it testable and keeps the caller (local repo or
//  Supabase) responsible for the uniqueness check at write time.
// =============================================================================

enum SettlementNumberService {

    static let defaultPrefix = "SP"

    /// Next number for `year`, given every number already issued on the account.
    /// Unparseable or foreign-prefixed numbers are ignored rather than crashing
    /// a settlement the user is trying to create.
    static func nextNumber(
        existing: [String],
        year: Int,
        prefix: String = defaultPrefix
    ) -> String {
        let cleanPrefix = sanitise(prefix)
        let highest = existing
            .compactMap { parse($0) }
            .filter { $0.prefix == cleanPrefix && $0.year == year }
            .map(\.sequence)
            .max() ?? 0
        return format(prefix: cleanPrefix, year: year, sequence: highest + 1)
    }

    /// Convenience for "next number for the year this settlement period ends in".
    static func nextNumber(
        existing: [String],
        periodEnd: Date,
        prefix: String = defaultPrefix,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> String {
        nextNumber(
            existing: existing,
            year: calendar.component(.year, from: periodEnd),
            prefix: prefix
        )
    }

    static func format(prefix: String, year: Int, sequence: Int) -> String {
        String(format: "%@-%04d-%04d", sanitise(prefix), year, max(1, sequence))
    }

    struct Parsed: Hashable {
        let prefix: String
        let year: Int
        let sequence: Int
    }

    /// "SP-2026-0042" -> (SP, 2026, 42). Returns nil for anything else.
    static func parse(_ number: String) -> Parsed? {
        let parts = number
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[1]),
              let sequence = Int(parts[2]),
              !parts[0].isEmpty
        else { return nil }
        return Parsed(prefix: String(parts[0]), year: year, sequence: sequence)
    }

    /// A settlement number is unique per account. Case- and space-insensitive so
    /// "sp-2026-0042" cannot sneak past "SP-2026-0042".
    static func isDuplicate(
        _ candidate: String,
        existing: [String],
        excluding settlementId: UUID? = nil,
        existingBySettlement: [UUID: String] = [:]
    ) -> Bool {
        let normalised = normalise(candidate)
        guard !normalised.isEmpty else { return false }

        if let settlementId, let own = existingBySettlement[settlementId],
           normalise(own) == normalised {
            return false   // it is its own number
        }
        return existing.contains { normalise($0) == normalised }
    }

    static func normalise(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
    }

    /// Company prefixes come from user-entered company names, so strip anything
    /// that would make the number unparseable.
    static func sanitise(_ prefix: String) -> String {
        let allowed = CharacterSet.uppercaseLetters.union(.decimalDigits)
        let cleaned = prefix.uppercased().unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(cleaned))
        return result.isEmpty ? defaultPrefix : String(result.prefix(6))
    }

    /// Derives a prefix from a company name: "Sacred Pathway LLC" -> "SP".
    static func suggestedPrefix(companyName: String?) -> String {
        guard let name = companyName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return defaultPrefix }

        let skip: Set<String> = ["LLC", "INC", "CO", "CORP", "LTD", "THE", "AND", "&"]
        let initials = name
            .uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !skip.contains(String($0)) }
            .compactMap { $0.first }
            .prefix(3)

        let candidate = String(initials)
        return candidate.isEmpty ? defaultPrefix : sanitise(candidate)
    }
}
