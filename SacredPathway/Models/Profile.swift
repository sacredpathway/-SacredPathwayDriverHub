import Foundation

struct Profile: Codable, Identifiable {
    let id: UUID
    var companyName: String?
    var mcNumber: String?
    var dotNumber: String?
    var phone: String?
    var subscriptionTier: String?
    var subscriptionStatus: String?
    var driverPayPercentage: Double?
    var dispatcherFeePercentage: Double?
    var factoringFeePercentage: Double?
    var authorityFee: Double?
    var maintenanceReserve: Double?
    var payBasis: String?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case companyName = "company_name"
        case mcNumber = "mc_number"
        case dotNumber = "dot_number"
        case phone
        case subscriptionTier = "subscription_tier"
        case subscriptionStatus = "subscription_status"
        case driverPayPercentage = "driver_pay_percentage"
        case dispatcherFeePercentage = "dispatcher_fee_percentage"
        case factoringFeePercentage = "factoring_fee_percentage"
        case authorityFee = "authority_fee"
        case maintenanceReserve = "maintenance_reserve"
        case payBasis = "pay_basis"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
