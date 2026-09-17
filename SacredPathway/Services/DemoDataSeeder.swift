#if DEBUG
import Foundation

// =============================================================================
// MARK: - DemoDataSeeder
// -----------------------------------------------------------------------------
// DEBUG-only utility that populates the signed-in user's account with a
// realistic, repeatable demo dataset for App Store screenshot capture and
// in-house demos.
//
// The whole file is wrapped in `#if DEBUG`, so the type and any reference
// to it are stripped from Release builds. There is no path for this code
// to ship to production users.
//
// Idempotency:
//   - Drivers: matched by (name, email). If Greg Hinton already exists for
//     this profile, his row is reused, not duplicated.
//   - Loads:   matched by `load_number`. Demo load numbers (LD-2841 …
//     LD-2848) are skipped if already present.
//   - Expenses: matched by (load_id, vendor_name, amount). If an exact
//     triple is already saved, that expense is skipped.
//   - IFTA:    matched by (entry_date, state_code, miles_driven). Exact
//     matches are skipped.
//
// User-data safety:
//   - Profile is only updated where fields are currently nil / empty. We
//     never overwrite a value the user has already set.
//   - All inserts go through the existing SupabaseService methods, so RLS,
//     auth, and the `profile_id = auth.uid()` invariant are honored.
// =============================================================================

@MainActor
final class DemoDataSeeder {

    let supabase: SupabaseService

    init(supabase: SupabaseService) {
        self.supabase = supabase
    }

    // MARK: - Public API

    struct Report: CustomStringConvertible {
        var profileFieldsUpdated: [String] = []
        var driverCreated: Bool = false
        var driverReused: Bool = false
        var loadsCreated: Int = 0
        var loadsSkipped: Int = 0
        var expensesCreated: Int = 0
        var expensesSkipped: Int = 0
        var iftaCreated: Int = 0
        var iftaSkipped: Int = 0

        var description: String {
            var lines: [String] = []
            if !profileFieldsUpdated.isEmpty {
                lines.append("Profile updated: \(profileFieldsUpdated.joined(separator: ", "))")
            } else {
                lines.append("Profile: no changes (existing values preserved)")
            }
            if driverCreated {
                lines.append("Driver: Greg Hinton created")
            } else if driverReused {
                lines.append("Driver: Greg Hinton already existed — reused")
            }
            lines.append("Loads: +\(loadsCreated) new · \(loadsSkipped) already present")
            lines.append("Expenses: +\(expensesCreated) new · \(expensesSkipped) already present")
            lines.append("IFTA entries: +\(iftaCreated) new · \(iftaSkipped) already present")
            return lines.joined(separator: "\n")
        }
    }

    enum SeedError: Error, LocalizedError {
        case profileMissing
        var errorDescription: String? {
            switch self {
            case .profileMissing:
                return "Finish onboarding (set company name) before seeding demo data."
            }
        }
    }

    /// Populate the signed-in user's account with the demo dataset.
    /// Safe to run multiple times — duplicates are detected and skipped.
    func seed() async throws -> Report {
        guard let profile = supabase.currentProfile else {
            throw SeedError.profileMissing
        }

        var report = Report()

        // 1. Profile — only fill empty fields
        report.profileFieldsUpdated = try await fillEmptyProfileFields(currentProfile: profile)

        // Re-fetch so the rest of the seeder uses fresh values.
        await supabase.fetchProfile()
        guard let refreshed = supabase.currentProfile else { throw SeedError.profileMissing }
        let profileId = refreshed.id

        // 2. Driver — Greg Hinton
        let driver = try await ensureDemoDriver(profileId: profileId, report: &report)

        // 3. Loads — 8 realistic loads, dates within the last 10 days
        let createdOrExistingLoads = try await ensureDemoLoads(
            profileId: profileId,
            driver: driver,
            report: &report
        )

        // 4. Expenses — 12 entries tied to the loads
        try await ensureDemoExpenses(
            profileId: profileId,
            loads: createdOrExistingLoads,
            report: &report
        )

        // 5. IFTA entries — 8 across multiple states
        try await ensureDemoIFTAEntries(
            profileId: profileId,
            report: &report
        )

        return report
    }

    // MARK: - Profile

    /// Set the company-info fields ONLY if they're currently nil or empty.
    /// Returns the list of field names that were updated.
    private func fillEmptyProfileFields(currentProfile: Profile) async throws -> [String] {
        var updates: [String: AnyEncodable] = [:]
        var updated: [String] = []

        if (currentProfile.companyName ?? "").isEmpty {
            updates["company_name"] = AnyEncodable("Sacred Pathway Trucking")
            updated.append("company_name")
        }
        if (currentProfile.mcNumber ?? "").isEmpty {
            updates["mc_number"] = AnyEncodable("1647441")
            updated.append("mc_number")
        }
        if (currentProfile.dotNumber ?? "").isEmpty {
            updates["dot_number"] = AnyEncodable("4250348")
            updated.append("dot_number")
        }
        if (currentProfile.phone ?? "").isEmpty {
            updates["phone"] = AnyEncodable("(555) 414-0001")
            updated.append("phone")
        }
        if currentProfile.driverPayPercentage == nil {
            updates["driver_pay_percentage"] = AnyEncodable(70.0)
            updated.append("driver_pay_percentage")
        }
        if currentProfile.dispatcherFeePercentage == nil {
            updates["dispatcher_fee_percentage"] = AnyEncodable(5.0)
            updated.append("dispatcher_fee_percentage")
        }
        if currentProfile.factoringFeePercentage == nil {
            updates["factoring_fee_percentage"] = AnyEncodable(3.0)
            updated.append("factoring_fee_percentage")
        }
        if currentProfile.authorityFee == nil {
            updates["authority_fee"] = AnyEncodable(150.0)
            updated.append("authority_fee")
        }
        if currentProfile.maintenanceReserve == nil {
            updates["maintenance_reserve"] = AnyEncodable(5.0)
            updated.append("maintenance_reserve")
        }

        if !updates.isEmpty {
            try await supabase.updateProfile(updates)
        }
        return updated
    }

    // MARK: - Driver

    private func ensureDemoDriver(
        profileId: UUID,
        report: inout Report
    ) async throws -> Driver {
        let demoName = "Greg Hinton"
        let demoEmail = "greg.hinton@sacredpathway.app"

        let existing = try await supabase.fetchDrivers()
        if let match = existing.first(where: { $0.name == demoName && $0.email == demoEmail }) {
            report.driverReused = true
            return match
        }

        let new = Driver(
            profileId: profileId,
            name: demoName,
            truckNumber: "2580",
            payPercentage: 70,
            payType: "percent",
            phone: "(555) 414-0125",
            email: demoEmail,
            active: true
        )
        let created = try await supabase.createDriver(new)
        report.driverCreated = true
        return created
    }

    // MARK: - Loads

    private struct DemoLoadSpec {
        let loadNumber: String
        let broker: String
        let brokerMc: String
        let origin: String
        let destination: String
        let miles: Double
        let revenue: Double
        let pickupDaysAgo: Int
        let deliveryDaysAgo: Int
        let status: LoadStatus
    }

    private static let loadSpecs: [DemoLoadSpec] = [
        // Older — already settled
        DemoLoadSpec(loadNumber: "LD-2834",
                     broker: "Direct", brokerMc: "—",
                     origin: "El Paso, TX", destination: "Phoenix, AZ",
                     miles: 432, revenue: 2100,
                     pickupDaysAgo: 9, deliveryDaysAgo: 8,
                     status: .settled),
        DemoLoadSpec(loadNumber: "LD-2835",
                     broker: "TQL", brokerMc: "1361737",
                     origin: "Atlanta, GA", destination: "Memphis, TN",
                     miles: 396, revenue: 2200,
                     pickupDaysAgo: 8, deliveryDaysAgo: 7,
                     status: .settled),
        DemoLoadSpec(loadNumber: "LD-2836",
                     broker: "Coyote Logistics", brokerMc: "612116",
                     origin: "Charlotte, NC", destination: "Birmingham, AL",
                     miles: 410, revenue: 2150,
                     pickupDaysAgo: 6, deliveryDaysAgo: 5,
                     status: .settled),
        DemoLoadSpec(loadNumber: "LD-2837",
                     broker: "TQL", brokerMc: "1361737",
                     origin: "Knoxville, TN", destination: "Cleveland, OH",
                     miles: 528, revenue: 2850,
                     pickupDaysAgo: 5, deliveryDaysAgo: 3,
                     status: .settled),
        // Recent — ready or assigned
        DemoLoadSpec(loadNumber: "LD-2838",
                     broker: "C.H. Robinson", brokerMc: "484108",
                     origin: "Sparta, TN", destination: "Tucson, AZ",
                     miles: 1612, revenue: 3550,
                     pickupDaysAgo: 4, deliveryDaysAgo: 1,
                     status: .readyForSettlement),
        DemoLoadSpec(loadNumber: "LD-2839",
                     broker: "Coyote Logistics", brokerMc: "612116",
                     origin: "Macon, GA", destination: "Jacksonville, FL",
                     miles: 287, revenue: 1950,
                     pickupDaysAgo: 3, deliveryDaysAgo: 2,
                     status: .readyForSettlement),
        DemoLoadSpec(loadNumber: "LD-2840",
                     broker: "Direct", brokerMc: "—",
                     origin: "Dallas, TX", destination: "Houston, TX",
                     miles: 239, revenue: 1850,
                     pickupDaysAgo: 2, deliveryDaysAgo: 1,
                     status: .assigned),
        DemoLoadSpec(loadNumber: "LD-2841",
                     broker: "Landstar", brokerMc: "125550",
                     origin: "Indianapolis, IN", destination: "Atlanta, GA",
                     miles: 535, revenue: 2400,
                     pickupDaysAgo: 1, deliveryDaysAgo: 0,
                     status: .assigned)
    ]

    private func ensureDemoLoads(
        profileId: UUID,
        driver: Driver,
        report: inout Report
    ) async throws -> [Load] {
        let existing = try await supabase.fetchLoads()
        let existingNumbers = Set(existing.compactMap { $0.loadNumber })
        let now = Date()
        let cal = Calendar.current

        var output: [Load] = []
        for spec in Self.loadSpecs {
            if existingNumbers.contains(spec.loadNumber) {
                if let match = existing.first(where: { $0.loadNumber == spec.loadNumber }) {
                    output.append(match)
                }
                report.loadsSkipped += 1
                continue
            }

            let pickup = cal.date(byAdding: .day, value: -spec.pickupDaysAgo, to: now)
            let delivery = cal.date(byAdding: .day, value: -spec.deliveryDaysAgo, to: now)
            let load = Load(
                profileId: profileId,
                driverId: driver.id,
                loadNumber: spec.loadNumber,
                brokerName: spec.broker,
                brokerMcNumber: spec.brokerMc,
                pickupDate: pickup,
                deliveryDate: delivery,
                origin: spec.origin,
                destination: spec.destination,
                totalMiles: spec.miles,
                lineHaulRate: spec.revenue * 0.85,
                fuelSurcharge: spec.revenue * 0.10,
                accessorialCharges: spec.revenue * 0.05,
                totalRevenue: spec.revenue,
                status: spec.status.rawValue
            )
            let created = try await supabase.createLoad(load)
            output.append(created)
            report.loadsCreated += 1
        }
        return output
    }

    // MARK: - Expenses

    private struct DemoExpenseSpec {
        let loadNumber: String   // matches a DemoLoadSpec.loadNumber
        let category: String
        let description: String
        let vendor: String
        let amount: Double
        let gallons: Double?
        let daysAgo: Int
    }

    private static let expenseSpecs: [DemoExpenseSpec] = [
        DemoExpenseSpec(loadNumber: "LD-2834", category: "Fuel",
                        description: "Pilot #1042", vendor: "Pilot Flying J",
                        amount: 528.40, gallons: 133.8, daysAgo: 9),
        DemoExpenseSpec(loadNumber: "LD-2834", category: "Toll",
                        description: "El Paso toll", vendor: "TXTAG",
                        amount: 18.75, gallons: nil, daysAgo: 9),
        DemoExpenseSpec(loadNumber: "LD-2835", category: "Fuel",
                        description: "Loves #2580", vendor: "Loves",
                        amount: 478.20, gallons: 121.0, daysAgo: 8),
        DemoExpenseSpec(loadNumber: "LD-2835", category: "Lumper",
                        description: "ATL pickup lumper", vendor: "ATL Distribution",
                        amount: 175.00, gallons: nil, daysAgo: 8),
        DemoExpenseSpec(loadNumber: "LD-2836", category: "Fuel",
                        description: "TA #410", vendor: "TravelCenters",
                        amount: 522.78, gallons: 132.4, daysAgo: 6),
        DemoExpenseSpec(loadNumber: "LD-2837", category: "Fuel",
                        description: "Pilot #2002", vendor: "Pilot Flying J",
                        amount: 645.10, gallons: 163.5, daysAgo: 5),
        DemoExpenseSpec(loadNumber: "LD-2837", category: "Maintenance",
                        description: "Tire repair (driver-side rear)", vendor: "Truck Me LLC",
                        amount: 287.50, gallons: nil, daysAgo: 4),
        DemoExpenseSpec(loadNumber: "LD-2838", category: "Fuel",
                        description: "Pilot #1612", vendor: "Pilot Flying J",
                        amount: 985.20, gallons: 249.5, daysAgo: 4),
        DemoExpenseSpec(loadNumber: "LD-2838", category: "Lumper",
                        description: "Sparta pickup lumper", vendor: "Sparta Foods",
                        amount: 220.00, gallons: nil, daysAgo: 4),
        DemoExpenseSpec(loadNumber: "LD-2839", category: "Fuel",
                        description: "Loves #287", vendor: "Loves",
                        amount: 365.40, gallons: 92.5, daysAgo: 3),
        DemoExpenseSpec(loadNumber: "LD-2840", category: "Fuel",
                        description: "Pilot #428", vendor: "Pilot Flying J",
                        amount: 312.45, gallons: 78.5, daysAgo: 2),
        DemoExpenseSpec(loadNumber: "LD-2841", category: "Fuel",
                        description: "TA #535", vendor: "TravelCenters",
                        amount: 678.30, gallons: 171.7, daysAgo: 1)
    ]

    private func ensureDemoExpenses(
        profileId: UUID,
        loads: [Load],
        report: inout Report
    ) async throws {
        let existing = try await supabase.fetchAllExpenses()
        let cal = Calendar.current
        let now = Date()

        // Map load number → Load.id for FK lookup
        let loadIdByNumber: [String: UUID] = Dictionary(
            uniqueKeysWithValues: loads.compactMap { load in
                guard let num = load.loadNumber, let id = load.id else { return nil }
                return (num, id)
            }
        )

        for spec in Self.expenseSpecs {
            guard let loadId = loadIdByNumber[spec.loadNumber] else { continue }

            // Idempotency: skip if a same-load + same-vendor + same-amount
            // expense already exists.
            let dup = existing.contains { e in
                e.loadId == loadId
                    && (e.vendorName ?? "") == spec.vendor
                    && abs(e.amount - spec.amount) < 0.01
            }
            if dup {
                report.expensesSkipped += 1
                continue
            }

            let date = cal.date(byAdding: .day, value: -spec.daysAgo, to: now)
            let expense = Expense(
                loadId: loadId,
                profileId: profileId,
                category: spec.category,
                amount: spec.amount,
                vendorName: spec.vendor,
                description: spec.description,
                gallons: spec.gallons,
                pricePerGallon: spec.gallons.map { spec.amount / $0 },
                receiptDate: date
            )
            _ = try await supabase.createExpense(expense)
            report.expensesCreated += 1
        }
    }

    // MARK: - IFTA

    private struct DemoIFTASpec {
        let state: String
        let miles: Double
        let gallons: Double
        let cost: Double
        let daysAgo: Int
        let notes: String
    }

    private static let iftaSpecs: [DemoIFTASpec] = [
        DemoIFTASpec(state: "TX", miles: 412, gallons: 65.2, cost: 264.41,
                     daysAgo: 9, notes: "El Paso → Phoenix segment"),
        DemoIFTASpec(state: "AZ", miles: 312, gallons: 49.6, cost: 200.83,
                     daysAgo: 8, notes: "Phoenix delivery"),
        DemoIFTASpec(state: "GA", miles: 286, gallons: 45.8, cost: 184.32,
                     daysAgo: 8, notes: "Atlanta loop"),
        DemoIFTASpec(state: "TN", miles: 318, gallons: 50.5, cost: 203.92,
                     daysAgo: 7, notes: "Memphis crossing"),
        DemoIFTASpec(state: "AL", miles: 195, gallons: 31.0, cost: 124.79,
                     daysAgo: 6, notes: "Birmingham route"),
        DemoIFTASpec(state: "OH", miles: 186, gallons: 29.5, cost: 119.63,
                     daysAgo: 3, notes: "Cleveland delivery"),
        DemoIFTASpec(state: "FL", miles: 142, gallons: 22.7, cost: 91.42,
                     daysAgo: 2, notes: "Jacksonville delivery"),
        DemoIFTASpec(state: "NM", miles: 286, gallons: 45.4, cost: 182.88,
                     daysAgo: 1, notes: "Cross-state segment")
    ]

    private func ensureDemoIFTAEntries(
        profileId: UUID,
        report: inout Report
    ) async throws {
        let existing = try await supabase.fetchIFTAEntries()
        let cal = Calendar.current
        let now = Date()

        for spec in Self.iftaSpecs {
            guard let date = cal.date(byAdding: .day, value: -spec.daysAgo, to: now) else { continue }

            // Idempotency: same state + same date (day-precision) + same miles → skip
            let dayStart = cal.startOfDay(for: date)
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? date

            let dup = existing.contains { entry in
                entry.stateCode == spec.state
                    && entry.date >= dayStart && entry.date < dayEnd
                    && abs(entry.milesDriven - spec.miles) < 0.5
            }
            if dup {
                report.iftaSkipped += 1
                continue
            }

            let entry = IFTAEntry(
                profileId: profileId,
                date: date,
                stateCode: spec.state,
                milesDriven: spec.miles,
                fuelGallons: spec.gallons,
                fuelPricePerGallon: spec.cost / spec.gallons,
                totalFuelCost: spec.cost,
                notes: spec.notes
            )
            _ = try await supabase.createIFTAEntry(entry)
            report.iftaCreated += 1
        }
    }
}
#endif
