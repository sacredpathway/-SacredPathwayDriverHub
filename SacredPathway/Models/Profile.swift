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

    static func defaultTruckNumber(profile: Profile?) -> String {
        if AppMode.shared.isLocal {
            return localTruckNumber
        }
        return clean(profile?.truckNumber)
    }

    static func defaultTrailerNumber(profile: Profile?) -> String {
        if AppMode.shared.isLocal {
            return localTrailerNumber
        }
        return clean(profile?.trailerNumber)
    }

    static func saveLocal(truckNumber: String, trailerNumber: String) {
        UserDefaults.standard.set(clean(truckNumber), forKey: truckKey)
        UserDefaults.standard.set(clean(trailerNumber), forKey: trailerKey)
    }

    private static var localTruckNumber: String {
        clean(UserDefaults.standard.string(forKey: truckKey))
    }

    private static var localTrailerNumber: String {
        clean(UserDefaults.standard.string(forKey: trailerKey))
    }

    private static func clean(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
