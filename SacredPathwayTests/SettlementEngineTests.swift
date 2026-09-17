import XCTest
@testable import SacredPathway

/// Golden tests for the money math that prints real paychecks.
/// Every scenario documents the EXPECTED business rule, so a future change
/// that alters paystub output must consciously update the expectation here.
@MainActor
final class SettlementEngineTests: XCTestCase {

    private let accuracy = 0.001

    // MARK: 1. Default percentage driver, pay on NET (gross profit)

    func testPercentageDriver_payOnNet_defaultOrderOfOperations() {
        let loads = [Fixtures.load(revenue: 8_000), Fixtures.load(revenue: 2_000)]   // 10,000
        let expenses = [Fixtures.expense(amount: 1_500), Fixtures.expense(amount: 500)] // 2,000
        let profile = Fixtures.profile(dispatcherPct: 10, factoringPct: 3,
                                       authorityFee: 100, maintenanceReserve: 200)
        let driver = Fixtures.driver(payPercentage: 25, payType: "percent")

        let calc = SettlementEngine.calculate(
            loads: loads, expenses: expenses, profile: profile, driver: driver,
            payOnRevenue: false, customDeductions: []
        )

        XCTAssertEqual(calc.totalRevenue, 10_000, accuracy: accuracy)
        XCTAssertEqual(calc.totalExpenses, 2_000, accuracy: accuracy)
        XCTAssertEqual(calc.grossProfit, 8_000, accuracy: accuracy)
        // Driver: 25% of gross PROFIT (net basis), not revenue
        XCTAssertEqual(calc.driverPayAmount, 2_000, accuracy: accuracy)
        // Dispatcher + factoring: always on REVENUE
        XCTAssertEqual(calc.dispatcherFeeAmount, 1_000, accuracy: accuracy)
        XCTAssertEqual(calc.factoringFeeAmount, 300, accuracy: accuracy)
        // Carrier net = grossProfit − driver − dispatcher − factoring − authority − reserve − custom
        XCTAssertEqual(calc.carrierNetPay, 8_000 - 2_000 - 1_000 - 300 - 100 - 200,
                       accuracy: accuracy)
    }

    // MARK: 2. Percentage driver, pay on REVENUE

    func testPercentageDriver_payOnRevenue() {
        let calc = SettlementEngine.calculate(
            loads: [Fixtures.load(revenue: 10_000)],
            expenses: [Fixtures.expense(amount: 2_000)],
            profile: Fixtures.profile(),
            driver: Fixtures.driver(payPercentage: 30, payType: "percent"),
            payOnRevenue: true, customDeductions: []
        )
        XCTAssertEqual(calc.driverPayAmount, 3_000, accuracy: accuracy)
        XCTAssertEqual(calc.driverPayPercentage, 30, accuracy: accuracy)
    }

    // MARK: 3. Flat-rate driver ignores revenue entirely

    func testFlatRateDriver_fixedAmountRegardlessOfRevenue() {
        let calc = SettlementEngine.calculate(
            loads: [Fixtures.load(revenue: 50_000)],
            expenses: [],
            profile: Fixtures.profile(),
            driver: Fixtures.driver(payType: "flat", flatRate: 1_200),
            customDeductions: []
        )
        XCTAssertEqual(calc.driverPayAmount, 1_200, accuracy: accuracy)
        XCTAssertEqual(calc.driverPayPercentage, 0, accuracy: accuracy)
    }

    // MARK: 4. Driver pct falls back: driver → profile → 25 default

    func testDriverPercentageFallbackChain() {
        // Driver has no pct → profile's 20 wins
        let fromProfile = SettlementEngine.calculate(
            loads: [Fixtures.load(revenue: 1_000)], expenses: [],
            profile: Fixtures.profile(driverPayPct: 20),
            driver: Fixtures.driver(), customDeductions: []
        )
        XCTAssertEqual(fromProfile.driverPayPercentage, 20, accuracy: accuracy)

        // Neither driver nor profile → documented 25% default
        let fromDefault = SettlementEngine.calculate(
            loads: [Fixtures.load(revenue: 1_000)], expenses: [],
            profile: Fixtures.profile(),
            driver: Fixtures.driver(), customDeductions: []
        )
        XCTAssertEqual(fromDefault.driverPayPercentage, 25, accuracy: accuracy)
    }

    // MARK: 5. Custom deductions flow into carrier net + totals

    func testCustomDeductionsAffectNetAndTotals() {
        let custom = [
            SettlementCustomDeduction(id: UUID(), name: "ELD", amount: 45, basis: nil),
            SettlementCustomDeduction(id: UUID(), name: "Trailer wash", amount: 55, basis: nil),
        ]
        let calc = SettlementEngine.calculate(
            loads: [Fixtures.load(revenue: 5_000)], expenses: [],
            profile: Fixtures.profile(),
            driver: Fixtures.driver(payPercentage: 0, payType: "percent"),
            customDeductions: custom
        )
        XCTAssertEqual(calc.customDeductionsTotal, 100, accuracy: accuracy)
        XCTAssertEqual(calc.carrierNetPay, 5_000 - 100, accuracy: accuracy)
        XCTAssertEqual(calc.totalDeductions, calc.standardDeductionsTotal + 100,
                       accuracy: accuracy)
    }

    // MARK: 6. Zero-revenue settlement stays sane (no NaN / negative surprises)

    func testZeroRevenueSettlement() {
        let calc = SettlementEngine.calculate(
            loads: [], expenses: [Fixtures.expense(amount: 300)],
            profile: Fixtures.profile(dispatcherPct: 10, factoringPct: 3),
            driver: Fixtures.driver(payPercentage: 25, payType: "percent"),
            customDeductions: []
        )
        XCTAssertEqual(calc.totalRevenue, 0, accuracy: accuracy)
        XCTAssertEqual(calc.grossProfit, -300, accuracy: accuracy)
        XCTAssertEqual(calc.dispatcherFeeAmount, 0, accuracy: accuracy)
        XCTAssertEqual(calc.factoringFeeAmount, 0, accuracy: accuracy)
        // 25% of a negative gross is negative — documents current behavior:
        // the engine passes the negative share through rather than clamping.
        XCTAssertEqual(calc.driverPayAmount, -75, accuracy: accuracy)
        XCTAssertFalse(calc.carrierNetPay.isNaN)
    }

    // MARK: 7. Nil revenue on a load counts as 0, not a crash

    func testNilRevenueLoadTreatedAsZero() {
        let calc = SettlementEngine.calculate(
            loads: [Fixtures.load(revenue: nil), Fixtures.load(revenue: 750)],
            expenses: [], profile: Fixtures.profile(),
            driver: Fixtures.driver(payType: "flat", flatRate: 0),
            customDeductions: []
        )
        XCTAssertEqual(calc.totalRevenue, 750, accuracy: accuracy)
    }
}
