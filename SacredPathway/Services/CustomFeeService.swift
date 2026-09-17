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

/// A concrete deduction line after a custom fee has been applied to a
/// specific paystub's gross pay.
struct SettlementCustomDeduction: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var amount: Double
    var basis: String?
}

/// Persists custom fees and mode overrides locally so users can add/rename/toggle fees.
final class CustomFeeService: @unchecked Sendable {
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

    func activeCustomDeductions(grossPay: Double) -> [SettlementCustomDeduction] {
        let fees = loadCustomFees()
        logLoadedFeeSettings(fees)
        return customDeductions(grossRevenue: grossPay, fees: fees, shouldLog: true)
    }

    func customDeductions(
        grossRevenue: Double,
        fees: [FeeItem],
        shouldLog: Bool = false
    ) -> [SettlementCustomDeduction] {
        let deductions: [SettlementCustomDeduction] = fees
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { fee -> SettlementCustomDeduction? in
                let rawValue = fee.value
                guard rawValue > 0 else { return nil }
                let amount = fee.mode == .percent
                    ? grossRevenue * rawValue / 100.0
                    : rawValue
                guard amount > 0 else { return nil }

                let basis: String?
                if fee.mode == .percent {
                    basis = String(format: "%.2f%% of gross revenue", rawValue)
                } else {
                    basis = String(format: "$%.2f flat per settlement", rawValue)
                }

                return SettlementCustomDeduction(
                    id: fee.id,
                    name: fee.name,
                    amount: amount,
                    basis: basis
                )
            }

        // Phase 1 · Task 4/5 (2026-07-04): logging is DEBUG-only. These
        // lines previously printed real fee names and dollar amounts to the
        // console in RELEASE builds on every paystub — a privacy leak
        // (financial data in sysdiagnose logs) and wasted I/O in the money
        // path. Behavior in DEBUG builds is unchanged.
        #if DEBUG
        if shouldLog {
            for deduction in deductions {
                let matchingFee = fees.first { $0.id == deduction.id }
                let type = matchingFee?.mode == .percent ? "percent" : "flat"
                print("[DriverHub Paystub] custom fee applied name=\(deduction.name) type=\(type) amount=\(String(format: "%.2f", deduction.amount))")
            }
            let total = deductions.reduce(0) { $0 + $1.amount }
            print("[DriverHub Paystub] total custom deductions=\(String(format: "%.2f", total))")
        }
        #endif

        return deductions
    }

    private func logLoadedFeeSettings(_ fees: [FeeItem]) {
        #if DEBUG
        let summary = fees
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { fee in
                let type = fee.mode == .percent ? "percent" : "flat"
                return "\(fee.name)=\(fee.value) \(type)"
            }
            .joined(separator: "; ")
        print("[DriverHub Paystub] loaded fee settings: \(summary.isEmpty ? "none" : summary)")
        #endif
    }

    #if DEBUG
    @discardableResult
    func runCustomFeeRegressionCheck() -> Bool {
        let percentFee = FeeItem(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Test Custom Fee",
            icon: "percent",
            subtitle: "",
            value: 5,
            mode: .percent,
            isBuiltIn: false,
            profileKey: nil,
            sortOrder: 0
        )
        let flatFee = FeeItem(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "Test Flat Fee",
            icon: "dollarsign",
            subtitle: "",
            value: 100,
            mode: .dollar,
            isBuiltIn: false,
            profileKey: nil,
            sortOrder: 1
        )
        let deductions = customDeductions(
            grossRevenue: 5_000,
            fees: [percentFee, flatFee],
            shouldLog: false
        )
        let percent = deductions.first { $0.name == "Test Custom Fee" }
        let flat = deductions.first { $0.name == "Test Flat Fee" }
        let total = deductions.reduce(0) { $0 + $1.amount }
        let passed = percent?.amount == 250 && flat?.amount == 100 && total == 350
        print("[DriverHub Paystub] custom fee regression grossRevenue=5000 percent=250 flat=100 total=\(String(format: "%.2f", total)) passed=\(passed)")
        return passed
    }
    #endif
}
