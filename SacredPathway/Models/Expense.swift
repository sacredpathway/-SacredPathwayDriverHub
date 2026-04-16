import Foundation

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
    var receiptDate: Date?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case loadId = "load_id"
        case profileId = "profile_id"
        case category, amount
        case vendorName = "vendor_name"
        case description, gallons
        case pricePerGallon = "price_per_gallon"
        case receiptDate = "receipt_date"
        case createdAt = "created_at"
    }
}
