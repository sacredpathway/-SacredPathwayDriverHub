import Foundation

// =============================================================================
// MARK: - ScreenshotMode
// -----------------------------------------------------------------------------
// Launch-arg flag for App Store screenshot capture.
//
// Activated by passing `-screenshot-mode` to the app on launch via the Xcode
// scheme:  Product → Scheme → Edit Scheme… → Run → Arguments → Arguments
// Passed On Launch → "+" → -screenshot-mode  (no value needed).
//
// When `isActive` is true:
//   • SupabaseService.init() short-circuits the live session check and reports
//     authenticated with a fake profile (no network round-trip, instant boot)
//   • SupabaseService.fetchAllExpenses() / fetchLoads() / fetchDrivers() return
//     in-memory seed data (small, user-realistic — no eight-load demo set)
//   • ContentView's TabView hides Loads and Compliance Hub tabs and exposes
//     Expenses + Settings instead, matching the App Store screenshot spec
//
// This is a screenshot-capture aid, NOT a way to bypass auth in production.
// The flag has no effect without the launch arg, and Release/archive builds
// from the App Store Connect–uploaded scheme do not include the launch arg.
// There is no settings toggle, no UserDefaults key, and no RemoteConfig
// switch — the only entry point is a developer-controlled scheme argument.
// =============================================================================

enum ScreenshotMode {

    /// True when `-screenshot-mode` (or `--screenshot-mode`) was passed on
    /// launch. Evaluated once at process start.
    static let isActive: Bool = {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-screenshot-mode")
            || args.contains("--screenshot-mode")
    }()

    /// Stable fake user UUID. Lowercased to match the storage RLS pattern.
    static let fakeUserID: UUID =
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    // -------------------------------------------------------------------------
    // MARK: - Seed data
    // -------------------------------------------------------------------------

    /// Profile with company name pre-filled so OnboardingView is skipped.
    static let seedProfile: Profile = Profile(
        id: fakeUserID,
        companyName: "Sacred Pathway Trucking",
        mcNumber: "1647441",
        dotNumber: "4250348",
        phone: "(555) 414-0001",
        subscriptionTier: nil,
        subscriptionStatus: nil,
        driverPayPercentage: 70,
        dispatcherFeePercentage: 5,
        factoringFeePercentage: 3,
        authorityFee: 150,
        maintenanceReserve: 5,
        payBasis: nil,
        createdAt: nil,
        updatedAt: nil
    )

    /// Two small loads — needed so paystub generator + reports look real
    /// without becoming "demo data" territory.
    static let seedLoads: [Load] = {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let oneDayAgo  = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: today) ?? today

        return [
            Load(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001"),
                profileId: fakeUserID,
                driverId: nil,
                loadNumber: "L-001",
                brokerName: "Direct",
                brokerMcNumber: nil,
                pickupDate: twoDaysAgo,
                deliveryDate: oneDayAgo,
                origin: "Dallas, TX",
                destination: "Houston, TX",
                totalMiles: 239,
                lineHaulRate: 1850 * 0.85,
                fuelSurcharge: 1850 * 0.10,
                accessorialCharges: 1850 * 0.05,
                totalRevenue: 1850,
                status: LoadStatus.settled.rawValue,
                createdAt: twoDaysAgo,
                updatedAt: oneDayAgo
            ),
            Load(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002"),
                profileId: fakeUserID,
                driverId: nil,
                loadNumber: "L-002",
                brokerName: "Direct",
                brokerMcNumber: nil,
                pickupDate: oneDayAgo,
                deliveryDate: today,
                origin: "Houston, TX",
                destination: "San Antonio, TX",
                totalMiles: 197,
                lineHaulRate: 1450 * 0.85,
                fuelSurcharge: 1450 * 0.10,
                accessorialCharges: 1450 * 0.05,
                totalRevenue: 1450,
                status: LoadStatus.readyForSettlement.rawValue,
                createdAt: oneDayAgo,
                updatedAt: today
            )
        ]
    }()

    /// Four expenses tied to the two seed loads. Realistic small amounts.
    static let seedExpenses: [Expense] = {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let oneDay   = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let twoDays  = cal.date(byAdding: .day, value: -2, to: today) ?? today
        let load1 = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let load2 = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!

        return [
            Expense(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000001"),
                loadId: load1,
                profileId: fakeUserID,
                category: "fuel",
                amount: 312.45,
                vendorName: "Pilot Flying J",
                description: "Pilot #428",
                gallons: 78.5,
                pricePerGallon: 312.45 / 78.5,
                receiptDate: twoDays,
                createdAt: twoDays
            ),
            Expense(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000002"),
                loadId: load1,
                profileId: fakeUserID,
                category: "toll",
                amount: 18.75,
                vendorName: "TXTAG",
                description: "I-45 toll",
                receiptDate: twoDays,
                createdAt: twoDays
            ),
            Expense(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000003"),
                loadId: load2,
                profileId: fakeUserID,
                category: "lumper",
                amount: 75.00,
                vendorName: "Houston Distribution",
                description: "Pickup lumper",
                receiptDate: oneDay,
                createdAt: oneDay
            ),
            Expense(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000004"),
                loadId: load2,
                profileId: fakeUserID,
                category: "maintenance",
                amount: 48.00,
                vendorName: "Truck Stop Tire",
                description: "Tire pressure check",
                receiptDate: today,
                createdAt: today
            )
        ]
    }()
}
