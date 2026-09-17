import Foundation

struct BrokerContact: Codable, Identifiable {
    var id: UUID?
    let brokerId: UUID
    var contactName: String
    var email: String?
    var phone: String?
    /// Phone extension (e.g. "54136" from "800-580-3101 x54136"). Stored
    /// separately so the UI can render "(800) 580-3101 · ext 54136" and the
    /// directory can search by extension.
    var phoneExtension: String?
    var createdAt: Date?
    var lastInteractionAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case brokerId = "broker_id"
        case contactName = "contact_name"
        case email
        case phone
        case phoneExtension = "phone_extension"
        case createdAt = "created_at"
        case lastInteractionAt = "last_interaction_at"
    }
}
