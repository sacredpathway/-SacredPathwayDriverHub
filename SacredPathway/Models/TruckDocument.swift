import Foundation

struct TruckDocument: Codable, Identifiable {
    var id: UUID?
    let profileId: UUID
    var loadId: UUID?
    var documentType: String?
    var storagePath: String
    var extractedData: ExtractedData?
    var confidence: String?
    var processed: Bool?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case loadId = "load_id"
        case documentType = "document_type"
        case storagePath = "storage_path"
        case extractedData = "extracted_data"
        case confidence, processed
        case createdAt = "created_at"
    }
}

// This matches the JSON that Claude AI returns when parsing documents
struct ExtractedData: Codable {
    var documentType: String?
    var brokerName: String?
    var brokerMcNumber: String?
    var loadNumber: String?
    var pickupDate: String?
    var deliveryDate: String?
    var origin: String?
    var destination: String?
    var totalMiles: Double?
    var lineHaulRate: Double?
    var fuelSurcharge: Double?
    var accessorialCharges: Double?
    var totalRevenue: Double?
    var expenseAmount: Double?
    var expenseCategory: String?
    var vendorName: String?
    var gallons: Double?
    var pricePerGallon: Double?
    var notes: String?
    var confidence: String?

    enum CodingKeys: String, CodingKey {
        case documentType = "document_type"
        case brokerName = "broker_name"
        case brokerMcNumber = "broker_mc_number"
        case loadNumber = "load_number"
        case pickupDate = "pickup_date"
        case deliveryDate = "delivery_date"
        case origin, destination
        case totalMiles = "total_miles"
        case lineHaulRate = "line_haul_rate"
        case fuelSurcharge = "fuel_surcharge"
        case accessorialCharges = "accessorial_charges"
        case totalRevenue = "total_revenue"
        case expenseAmount = "expense_amount"
        case expenseCategory = "expense_category"
        case vendorName = "vendor_name"
        case gallons
        case pricePerGallon = "price_per_gallon"
        case notes, confidence
    }
}
