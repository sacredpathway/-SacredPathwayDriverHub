import Foundation

struct BrokerContact: Codable, Identifiable {
    var id: UUID?
    let brokerId: UUID
    var contactName: String
    var email: String?
    var phone: String?
    var createdAt: Date?
    var lastInteractionAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case brokerId = "broker_id"
        case contactName = "contact_name"
        case email
        case phone
        case createdAt = "created_at"
        case lastInteractionAt = "last_interaction_at"
    }
}
