import Foundation

struct Broker: Codable, Identifiable {
    var id: UUID?
    let profileId: UUID
    var brokerName: String
    var normalizedName: String?
    var mcNumber: String?
    var totalLoads: Int?
    var totalRevenue: Double?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case brokerName = "broker_name"
        case normalizedName = "normalized_name"
        case mcNumber = "mc_number"
        case totalLoads = "total_loads"
        case totalRevenue = "total_revenue"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Normalize broker name for matching
    static func normalize(_ name: String) -> String {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Common abbreviation mappings
        let aliases: [String: String] = [
            "tql": "total quality logistics",
            "ch robinson": "c.h. robinson",
            "chr": "c.h. robinson",
            "c h robinson": "c.h. robinson",
            "jb hunt": "j.b. hunt",
            "j b hunt": "j.b. hunt",
            "xpo": "xpo logistics",
            "schneider": "schneider national",
            "landstar": "landstar system",
            "echo": "echo global logistics",
            "coyote": "coyote logistics",
        ]
        if let mapped = aliases[lowered] { return mapped }
        // Remove common suffixes
        let suffixes = [" inc", " inc.", " llc", " llc.", " corp", " corp.", " co", " co.", " ltd", " ltd.", " logistics", " transportation", " transport", " freight", " trucking"]
        var cleaned = lowered
        for suffix in suffixes {
            if cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
            }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
