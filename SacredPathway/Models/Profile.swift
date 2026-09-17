import Foundation

enum AccountRole: String, Codable, CaseIterable, Identifiable {
    case dispatcher
    case carrier
    case driver
    case ownerOperator = "owner_operator"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dispatcher: return "Dispatcher"
        case .carrier: return "Carrier"
        case .driver: return "Driver"
        case .ownerOperator: return "Owner Operator"
        }
    }

    var onboardingDescription: String {
        switch self {
        case .dispatcher:
            return "Manage assigned drivers, dispatch communication, load offers, revenue tracking, and dispatcher expenses."
        case .carrier:
            return "Manage company loads, dispatch relationships, settlements, expenses, and reports."
        case .driver:
            return "Track weekly paycheck estimates, simple loads, mileage pay, expenses, and dispatcher messages."
        case .ownerOperator:
            return "Manage your own trucking operation, loads, expenses, paystubs, and dispatch relationships."
        }
    }

    var dispatchParticipantRole: DispatchParticipantRole {
        switch self {
        case .dispatcher:
            return .dispatcher
        case .driver:
            return .driver
        case .carrier, .ownerOperator:
            return .carrier
        }
    }
}

struct Profile: Codable, Identifiable {
    let id: UUID
    var accountRole: AccountRole?
    var companyName: String?
    var mcNumber: String?
    var dotNumber: String?
    var phone: String?
    var truckNumber: String?
    var trailerNumber: String?
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
        case accountRole = "account_role"
        case companyName = "company_name"
        case mcNumber = "mc_number"
        case dotNumber = "dot_number"
        case phone
        case truckNumber = "truck_number"
        case trailerNumber = "trailer_number"
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

@MainActor
enum DriverEquipmentProfileStore {
    private static let truckKey = "sph.driverEquipment.truckNumber"
    private static let trailerKey = "sph.driverEquipment.trailerNumber"
    private static let legacyTruckKey = "sph.lastTruckNumber"
    private static let legacyTrailerKey = "sph.lastTrailerNumber"
    private static let fallbackTruckKeys = [
        "sph.driverEquipment.truckNumber",
        "sph.lastTruckNumber",
        "truckNumber",
        "truck_number",
        "defaultTruckNumber",
        "default_truck_number"
    ]
    private static let fallbackTrailerKeys = [
        "sph.driverEquipment.trailerNumber",
        "sph.lastTrailerNumber",
        "trailerNumber",
        "trailer_number",
        "defaultTrailerNumber",
        "default_trailer_number"
    ]

    static func defaultTruckNumber(profile: Profile?) -> String {
        let local = firstStoredValue(for: fallbackTruckKeys)
        if !local.isEmpty { return local }
        return clean(profile?.truckNumber)
    }

    static func defaultTrailerNumber(profile: Profile?) -> String {
        let local = firstStoredValue(for: fallbackTrailerKeys)
        if !local.isEmpty { return local }
        return clean(profile?.trailerNumber)
    }

    static func saveLocal(truckNumber: String, trailerNumber: String) {
        UserDefaults.standard.set(clean(truckNumber), forKey: truckKey)
        UserDefaults.standard.set(clean(trailerNumber), forKey: trailerKey)
    }

    private static var localTruckNumber: String {
        firstStoredValue(for: fallbackTruckKeys)
    }

    private static var localTrailerNumber: String {
        firstStoredValue(for: fallbackTrailerKeys)
    }

    private static func firstStoredValue(for keys: [String]) -> String {
        for key in keys {
            let value = clean(UserDefaults.standard.string(forKey: key))
            if !value.isEmpty { return value }
        }
        return ""
    }

    #if DEBUG
    static func debugEquipmentSnapshot(profile: Profile?) -> String {
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        let equipmentKeys = defaults.keys
            .filter {
                let lower = $0.lowercased()
                return lower.contains("truck") || lower.contains("trailer")
            }
            .sorted()
        let pairs = equipmentKeys.map { key in
            "\(key)=\(defaults[key] ?? "<nil>")"
        }.joined(separator: "; ")
        return """
        profileTruck=\(clean(profile?.truckNumber)) profileTrailer=\(clean(profile?.trailerNumber)) \
        defaultTruck=\(defaultTruckNumber(profile: profile)) defaultTrailer=\(defaultTrailerNumber(profile: profile)) \
        userDefaults=[\(pairs)]
        """
    }
    #endif

    private static func clean(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
