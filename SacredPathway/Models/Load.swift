import Foundation

struct Load: Codable, Identifiable {
    var id: UUID?
    let profileId: UUID
    var driverId: UUID?
    var loadNumber: String?
    var brokerName: String?
    var brokerMcNumber: String?
    var pickupDate: Date?
    var deliveryDate: Date?
    var origin: String?
    var destination: String?
    var totalMiles: Double?
    var lineHaulRate: Double?
    var fuelSurcharge: Double?
    var accessorialCharges: Double?
    var totalRevenue: Double?
    var status: String?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case driverId = "driver_id"
        case loadNumber = "load_number"
        case brokerName = "broker_name"
        case brokerMcNumber = "broker_mc_number"
        case pickupDate = "pickup_date"
        case deliveryDate = "delivery_date"
        case origin, destination
        case totalMiles = "total_miles"
        case lineHaulRate = "line_haul_rate"
        case fuelSurcharge = "fuel_surcharge"
        case accessorialCharges = "accessorial_charges"
        case totalRevenue = "total_revenue"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    // Computed properties for quick math
    var expenses: Double { 0 } // Will be calculated from expenses table
    var profit: Double { (totalRevenue ?? 0) - expenses }
    var ratePerMile: Double {
        guard let miles = totalMiles, miles > 0, let rev = totalRevenue else { return 0 }
        return rev / miles
    }
}
