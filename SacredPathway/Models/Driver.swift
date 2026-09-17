import Foundation

struct Driver: Codable, Identifiable {
    var id: UUID?
    let profileId: UUID
    var name: String
    var truckNumber: String?
    var payPercentage: Double?
    /// "percent" or "flat". Defaults to "percent" for backward compatibility.
    var payType: String?
    /// Flat settlement amount (e.g., $1200 per settlement). Only used when payType == "flat".
    var flatRate: Double?
    var phone: String?
    var email: String?
    var active: Bool?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case name
        case truckNumber = "truck_number"
        case payPercentage = "pay_percentage"
        case payType = "pay_type"
        case flatRate = "flat_rate"
        case phone, email, active
        case createdAt = "created_at"
    }

    /// Convenience: is this driver paid a flat rate per settlement?
    var isFlatRate: Bool { (payType ?? "percent") == "flat" }
}
