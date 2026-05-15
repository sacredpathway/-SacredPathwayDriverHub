import Foundation

/// Mirrors the `documents` table after the OpenAI backend refactor migration
/// (see `supabase/migrations/20260417120000_openai_documents.sql`).
///
/// The iPhone never stores the AI key — it just inserts a row with
/// `status = pending`, then asks the `extract-document` Edge Function to
/// fill in `extracted_data`, `raw_text`, `confidence`, and flip the status.
struct TruckDocument: Codable, Identifiable {
    var id: UUID?
    let profileId: UUID
    var loadId: UUID?
    var documentType: String?
    var storagePath: String
    var extractedData: ExtractedData?
    var rawText: String?
    var confidence: String?
    var status: String?           // pending | processing | processed | failed | manual
    var errorMessage: String?
    var isManual: Bool?
    var provider: String?         // "openai" | "manual"
    var model: String?            // e.g. "gpt-4o"
    var fileMimeType: String?
    var fileSize: Int?
    var retryCount: Int?
    var processed: Bool?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case loadId = "load_id"
        case documentType = "document_type"
        case storagePath = "storage_path"
        case extractedData = "extracted_data"
        case rawText = "raw_text"
        case confidence
        case status
        case errorMessage = "error_message"
        case isManual = "is_manual"
        case provider, model
        case fileMimeType = "file_mime_type"
        case fileSize = "file_size"
        case retryCount = "retry_count"
        case processed
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Structured payload that the backend extract-document function returns.
/// Every field is optional — missing fields surface as empty inputs in
/// DocumentReviewView so the driver can fill them in by hand.
struct ExtractedData: Codable, Equatable {
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

    static let empty = ExtractedData()
}

/// Status machine used by the iOS UI (mirrors the DB `status` column).
enum DocumentStatus: String, Codable {
    case pending
    case processing
    case processed
    case failed
    case manual
}
