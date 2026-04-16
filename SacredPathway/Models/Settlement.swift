import Foundation

struct Settlement: Codable, Identifiable {
    var id: UUID?
    let profileId: UUID
    var driverId: UUID?
    var settlementPeriodStart: Date?
    var settlementPeriodEnd: Date?
    var totalRevenue: Double?
    var totalExpenses: Double?
    var grossProfit: Double?
    var driverPayPercentage: Double?
    var driverPayAmount: Double?
    var dispatcherFeePercentage: Double?
    var dispatcherFeeAmount: Double?
    var factoringFeePercentage: Double?
    var factoringFeeAmount: Double?
    var authorityFee: Double?
    var maintenanceReserve: Double?
    var netPay: Double?
    var pdfStoragePath: String?
    var status: String?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case driverId = "driver_id"
        case settlementPeriodStart = "settlement_period_start"
        case settlementPeriodEnd = "settlement_period_end"
        case totalRevenue = "total_revenue"
        case totalExpenses = "total_expenses"
        case grossProfit = "gross_profit"
        case driverPayPercentage = "driver_pay_percentage"
        case driverPayAmount = "driver_pay_amount"
        case dispatcherFeePercentage = "dispatcher_fee_percentage"
        case dispatcherFeeAmount = "dispatcher_fee_amount"
        case factoringFeePercentage = "factoring_fee_percentage"
        case factoringFeeAmount = "factoring_fee_amount"
        case authorityFee = "authority_fee"
        case maintenanceReserve = "maintenance_reserve"
        case netPay = "net_pay"
        case pdfStoragePath = "pdf_storage_path"
        case status
        case createdAt = "created_at"
    }
}
