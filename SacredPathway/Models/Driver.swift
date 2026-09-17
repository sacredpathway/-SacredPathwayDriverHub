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

    // ── Driver Pay & Settlements defaults (2026-09-16) ─────────────────
    // All optional and additive. Columns come from migration
    // 20260912120000_driver_pay_and_settlements.sql; rows written before it
    // decode with these as nil and fall back to payPercentage / flatRate.
    var settlementType: SettlementType? = nil
    var payRule: PayRule? = nil
    var payOnGrossRevenue: Bool? = nil
    var leaseConfig: LeaseOperatorConfig? = nil

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
        case settlementType = "settlement_type"
        case payRule = "pay_rule"
        case payOnGrossRevenue = "pay_on_gross_revenue"
        case leaseConfig = "lease_config"
    }

    /// Convenience: is this driver paid a flat rate per settlement?
    var isFlatRate: Bool { (payType ?? "percent") == "flat" }

    /// Settlement defaults for this driver. A saved pay rule wins; otherwise
    /// the legacy percent / flat fields are translated so an existing driver
    /// gets sensible defaults without anyone re-entering them.
    func paySettings(legacyPayOnGrossRevenue: Bool = true) -> DriverPaySettings {
        let rule: PayRule
        if let payRule, !payRule.isEmpty {
            rule = payRule
        } else if isFlatRate, let flatRate, flatRate > 0 {
            // Legacy "flat" meant a flat amount per settlement.
            rule = PayRule(components: [PayComponent(kind: .manual, label: "Flat Settlement Pay",
                                                     fixedAmount: Money(double: flatRate))])
        } else if let payPercentage, payPercentage > 0 {
            rule = .percentOfGross(Money(double: payPercentage).amount)
        } else {
            rule = .none
        }
        return DriverPaySettings(
            id: id ?? UUID(),
            profileId: profileId,
            driverId: id ?? UUID(),
            settlementType: settlementType ?? .companyDriver,
            payRule: rule,
            payOnGrossRevenue: payOnGrossRevenue ?? legacyPayOnGrossRevenue,
            leaseConfig: leaseConfig,
            defaultTruckNumber: truckNumber
        )
    }
}
