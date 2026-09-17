import XCTest
@testable import SacredPathway

// MARK: - CustomFeeService (pure fee → deduction math)

@MainActor
final class CustomFeeServiceTests: XCTestCase {

    private func fee(_ name: String, value: Double, mode: FeeItem.FeeMode,
                     sortOrder: Int = 0) -> FeeItem {
        FeeItem(id: UUID(), name: name, icon: "tag", subtitle: "",
                value: value, mode: mode, isBuiltIn: false,
                profileKey: nil, sortOrder: sortOrder)
    }

    func testPercentFeeAppliesToGrossRevenue() {
        let d = CustomFeeService.shared.customDeductions(
            grossRevenue: 5_000, fees: [fee("Admin", value: 5, mode: .percent)]
        )
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].amount, 250, accuracy: 0.001)
    }

    func testFlatFeeIgnoresRevenue() {
        let d = CustomFeeService.shared.customDeductions(
            grossRevenue: 99_999, fees: [fee("ELD", value: 45, mode: .dollar)]
        )
        XCTAssertEqual(d[0].amount, 45, accuracy: 0.001)
    }

    func testZeroAndNegativeValueFeesAreSkipped() {
        let d = CustomFeeService.shared.customDeductions(
            grossRevenue: 5_000,
            fees: [fee("Zero", value: 0, mode: .percent),
                   fee("Negative", value: -10, mode: .dollar),
                   fee("Real", value: 1, mode: .percent)]
        )
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].name, "Real")
    }

    func testDeductionsRespectSortOrder() {
        let d = CustomFeeService.shared.customDeductions(
            grossRevenue: 1_000,
            fees: [fee("B-second", value: 10, mode: .dollar, sortOrder: 2),
                   fee("A-first", value: 10, mode: .dollar, sortOrder: 1)]
        )
        XCTAssertEqual(d.map(\.name), ["A-first", "B-second"])
    }

    /// Mirrors the DEBUG in-app regression check so the same truth ships in CI.
    func testCanonicalRegressionScenario() {
        let d = CustomFeeService.shared.customDeductions(
            grossRevenue: 5_000,
            fees: [fee("Pct", value: 5, mode: .percent),
                   fee("Flat", value: 100, mode: .dollar)]
        )
        XCTAssertEqual(d.reduce(0) { $0 + $1.amount }, 350, accuracy: 0.001)
    }
}

// MARK: - PaystubExpenseMatcher (which expenses land on a stub)

@MainActor
final class PaystubExpenseMatcherTests: XCTestCase {

    private let start = Fixtures.date(2026, 6, 1)
    private let end   = Fixtures.date(2026, 6, 7)

    func testLoadAttachedExpenseAlwaysIncluded_evenOutsideWindow() {
        let loadID = UUID()
        let r = PaystubExpenseMatcher.match(
            allExpenses: [Fixtures.expense(loadId: loadID, amount: 100,
                                           receiptDate: Fixtures.date(2026, 1, 1))],
            selectedLoadIds: [loadID], periodStart: start, periodEnd: end
        )
        XCTAssertEqual(r.lineItems.count, 1)
        XCTAssertEqual(r.includedTotal, 100, accuracy: 0.001)
    }

    func testExpenseTiedToUnselectedLoadIsSkippedSilently() {
        let r = PaystubExpenseMatcher.match(
            allExpenses: [Fixtures.expense(loadId: UUID(), amount: 100,
                                           receiptDate: Fixtures.date(2026, 6, 3))],
            selectedLoadIds: [], periodStart: start, periodEnd: end
        )
        XCTAssertTrue(r.lineItems.isEmpty)
        XCTAssertEqual(r.unattributedDropped, 0) // skipped ≠ dropped
    }

    func testFreeFloatingExpenseIncludedThroughEndOfLastDay() {
        // 11:59 PM on the final day must count (end is normalized to 23:59:59)
        let lateFinalDay = Fixtures.date(2026, 6, 7, hour: 23, minute: 59)
        let r = PaystubExpenseMatcher.match(
            allExpenses: [Fixtures.expense(amount: 60, receiptDate: lateFinalDay)],
            selectedLoadIds: [], periodStart: start, periodEnd: end
        )
        XCTAssertEqual(r.lineItems.count, 1)
    }

    func testNoLoadAndNoDateIsDroppedAndCounted() {
        let r = PaystubExpenseMatcher.match(
            allExpenses: [Fixtures.expense(amount: 40, receiptDate: nil)],
            selectedLoadIds: [], periodStart: start, periodEnd: end
        )
        XCTAssertTrue(r.lineItems.isEmpty)
        XCTAssertEqual(r.unattributedDropped, 1)
    }

    func testOverrideAmountDrivesTotals() {
        let loadID = UUID()
        var r = PaystubExpenseMatcher.match(
            allExpenses: [Fixtures.expense(loadId: loadID, amount: 100)],
            selectedLoadIds: [loadID], periodStart: start, periodEnd: end
        )
        r.lineItems[0].overrideAmount = 80
        XCTAssertEqual(r.includedTotal, 80, accuracy: 0.001)
        XCTAssertEqual(r.includedExpenses[0].amount, 80, accuracy: 0.001)
    }

    func testCategorySynonymsResolveToCanonicalBuckets() {
        XCTAssertEqual(PaystubExpenseMatcher.Category.resolve(rawCategory: "Tolls"), .toll)
        XCTAssertEqual(PaystubExpenseMatcher.Category.resolve(rawCategory: " FUEL "), .fuel)
        XCTAssertEqual(PaystubExpenseMatcher.Category.resolve(rawCategory: "truck note"), .truckPayment)
        XCTAssertEqual(PaystubExpenseMatcher.Category.resolve(rawCategory: "mystery"), .other)
        XCTAssertEqual(PaystubExpenseMatcher.Category.resolve(rawCategory: nil), .other)
    }
}
