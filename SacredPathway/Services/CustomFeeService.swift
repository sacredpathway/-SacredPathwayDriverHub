import Foundation

/// Represents a single fee/deduction — either a built-in profile fee or a user-created custom one.
struct FeeItem: Codable, Identifiable {
    var id: UUID
    var name: String
    var icon: String
    var subtitle: String
    var value: Double
    var mode: FeeMode          // .percent or .dollar
    var isBuiltIn: Bool        // true = maps to a profile column, false = custom
    var profileKey: String?    // e.g. "driver_pay_percentage" — only for built-in fees
    var sortOrder: Int

    enum FeeMode: String, Codable {
        case percent
        case dollar
    }
}

/// Persists custom fees and mode overrides locally so users can add/rename/toggle fees.
class CustomFeeService {
    static let shared = CustomFeeService()

    private let fileManager = FileManager.default

    private var storageURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("custom_fees.json")
    }

    private var overridesURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("fee_overrides.json")
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = .prettyPrinted
        return e
    }

    // MARK: - Custom Fees (user-created)

    func loadCustomFees() -> [FeeItem] {
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        return (try? JSONDecoder().decode([FeeItem].self, from: data)) ?? []
    }

    func saveCustomFees(_ fees: [FeeItem]) {
        guard let data = try? encoder.encode(fees) else { return }
        try? data.write(to: storageURL)
    }

    // MARK: - Mode Overrides (built-in fee $/% toggle)

    func loadModeOverrides() -> [String: FeeItem.FeeMode] {
        guard let data = try? Data(contentsOf: overridesURL) else { return [:] }
        return (try? JSONDecoder().decode([String: FeeItem.FeeMode].self, from: data)) ?? [:]
    }

    func saveModeOverrides(_ overrides: [String: FeeItem.FeeMode]) {
        guard let data = try? encoder.encode(overrides) else { return }
        try? data.write(to: overridesURL)
    }

    // MARK: - Name Overrides

    private var nameOverridesURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("fee_name_overrides.json")
    }

    func loadNameOverrides() -> [String: String] {
        guard let data = try? Data(contentsOf: nameOverridesURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func saveNameOverrides(_ overrides: [String: String]) {
        guard let data = try? encoder.encode(overrides) else { return }
        try? data.write(to: nameOverridesURL)
    }
}
