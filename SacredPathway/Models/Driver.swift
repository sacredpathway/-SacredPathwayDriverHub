import Foundation

struct Driver: Codable, Identifiable {
    var id: UUID?
    let profileId: UUID
    var name: String
    var truckNumber: String?
    var payPercentage: Double?
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
        case phone, email, active
        case createdAt = "created_at"
    }
}
