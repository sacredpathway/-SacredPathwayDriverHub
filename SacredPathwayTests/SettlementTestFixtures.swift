import XCTest
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

// =============================================================================
//  SettlementTestFixtures — isolated, obviously-fake test data
// -----------------------------------------------------------------------------
//  Every fixture uses fixed UUIDs seeded from a "TEST" namespace and the name
//  "Test Driver", so nothing here can be mistaken for a real driver, load or
//  settlement if it ever shows up in a log or a screenshot. None of it touches
//  storage — fixtures are values, not rows.
// =============================================================================

enum Fx {

    // Deterministic ids so failures are reproducible and readable.
    static let profileId  = UUID(uuidString: "11111111-0000-4000-8000-000000000001")!
    static let driverId   = UUID(uuidString: "11111111-0000-4000-8000-000000000002")!
    static let driver2Id  = UUID(uuidString: "11111111-0000-4000-8000-000000000003")!
    static let truckId    = UUID(uuidString: "11111111-0000-4000-8000-000000000004")!

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "22222222-0000-4000-8000-%012d", n))!
    }

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(from: c)!
    }

    /// Monday 2026-09-07 through Sunday 2026-09-13.
    static let periodStart = date(2026, 9, 7)
    static let periodEnd   = date(2026, 9, 13)

    // MARK: - Loads

    static func load(
        _ n: Int,
        gross: Int,                 // dollars, whole
        loadedMiles: Decimal = 500,
        deadheadMiles: Decimal = 0,
        number: String? = nil,
        broker: String = "Test Broker",
        loadId: UUID? = nil,
        payRuleOverride: PayRule? = nil,
        isAdjustment: Bool = false,
        correctsSettlementId: UUID? = nil,
        sortOrder: Int = 0
    ) -> SettlementLoadLine {
        SettlementLoadLine(
            id: id(n),
            profileId: profileId,
            loadId: loadId ?? id(1_000 + n),
            loadNumber: number ?? "TEST-\(n)",
            brokerName: broker,
            pickupDate: periodStart,
            deliveryDate: periodEnd,
            origin: "Test Origin, TS",
            destination: "Test Destination, TS",
            loadedMiles: loadedMiles,
            deadheadMiles: deadheadMiles,
            linehaul: Money(cents: gross * 100),
            payRuleOverride: payRuleOverride,
            isAdjustment: isAdjustment,
            correctsSettlementId: correctsSettlementId,
            sortOrder: sortOrder
        )
    }

    /// A load whose gross is built from discrete accessorial components.
    static func componentLoad(
        _ n: Int,
        linehaul: Money,
        fuelSurcharge: Money = .zero,
        detention: Money = .zero,
        layover: Money = .zero,
        tonu: Money = .zero,
        lumper: Money = .zero,
        accessorials: Money = .zero,
        loadedMiles: Decimal = 500
    ) -> SettlementLoadLine {
        SettlementLoadLine(
            id: id(n),
            profileId: profileId,
            loadId: id(1_000 + n),
            loadNumber: "TEST-\(n)",
            loadedMiles: loadedMiles,
            linehaul: linehaul,
            fuelSurcharge: fuelSurcharge,
            accessorials: accessorials,
            detention: detention,
            layover: layover,
            tonu: tonu,
            lumperReimbursement: lumper
        )
    }

    // MARK: - Additions / deductions

    static func addition(
        _ n: Int,
        _ category: SettlementAdditionCategory,
        _ description: String,
        _ dollars: Int
    ) -> SettlementAddition {
        SettlementAddition(
            id: id(2_000 + n),
            profileId: profileId,
            category: category,
            descriptionText: description,
            amount: Money(cents: dollars * 100),
            date: periodEnd,
            sortOrder: n
        )
    }

    static func deduction(
        _ n: Int,
        _ category: SettlementDeductionCategory,
        _ description: String,
        _ dollars: Int,
        responsibility: DeductionResponsibility = .driver,
        driverShare: Decimal = 100,
        advanceId: UUID? = nil,
        recurringId: UUID? = nil
    ) -> SettlementDeduction {
        SettlementDeduction(
            id: id(3_000 + n),
            profileId: profileId,
            category: category,
            descriptionText: description,
            amount: Money(cents: dollars * 100),
            date: periodEnd,
            responsibility: responsibility,
            driverSharePercent: driverShare,
            recurringDeductionId: recurringId,
            advanceId: advanceId,
            sortOrder: n
        )
    }

    static func money(_ dollars: Int, _ cents: Int = 0) -> Money {
        Money(cents: dollars * 100 + cents)
    }

    // MARK: - Advances

    static func advance(
        _ n: Int,
        type: AdvanceType = .cash,
        dollars: Int,
        on day: Int = 1,
        recovered: Int = 0
    ) -> DriverAdvance {
        DriverAdvance(
            id: id(4_000 + n),
            profileId: profileId,
            driverId: driverId,
            type: type,
            date: date(2026, 9, day),
            amount: Money(cents: dollars * 100),
            descriptionText: "Test \(type.displayName) \(n)",
            recoveredAmount: Money(cents: recovered * 100)
        )
    }

    static func repayment(
        _ n: Int,
        advanceId: UUID,
        dollars: Int,
        settlementId: UUID? = nil
    ) -> DriverAdvanceRepayment {
        DriverAdvanceRepayment(
            id: id(5_000 + n),
            profileId: profileId,
            advanceId: advanceId,
            settlementId: settlementId,
            amount: Money(cents: dollars * 100),
            date: periodEnd
        )
    }

    // MARK: - Recurring

    static func recurring(
        _ n: Int,
        _ category: SettlementDeductionCategory,
        _ description: String,
        dollars: Int = 0,
        percentOfGross: Decimal? = nil,
        frequency: RecurrenceFrequency = .everySettlement,
        start: Date = date(2026, 1, 1),
        end: Date? = nil,
        active: Bool = true,
        driverId: UUID = Fx.driverId,
        responsibility: DeductionResponsibility = .driver,
        driverShare: Decimal = 100
    ) -> RecurringDeduction {
        RecurringDeduction(
            id: id(6_000 + n),
            profileId: profileId,
            driverId: driverId,
            category: category,
            descriptionText: description,
            amount: Money(cents: dollars * 100),
            percentOfGross: percentOfGross,
            frequency: frequency,
            effectiveStartDate: start,
            effectiveEndDate: end,
            isActive: active,
            responsibility: responsibility,
            driverSharePercent: driverShare
        )
    }

    // MARK: - Settlement

    static func settlement(
        id settlementId: UUID? = nil,
        status: SettlementStatus = .draft,
        number: String? = "SP-2026-0001",
        driverId: UUID? = Fx.driverId,
        payRule: PayRule = .percentOfGross(70),
        type: SettlementType = .companyDriver,
        hours: Decimal? = nil
    ) -> Settlement {
        var s = Settlement(
            id: settlementId ?? id(7_000),
            profileId: profileId,
            driverId: driverId,
            settlementPeriodStart: periodStart,
            settlementPeriodEnd: periodEnd,
            status: status.rawValue,
            settlementNumber: number,
            settlementType: type,
            payRule: payRule,
            payOnGrossRevenue: true,
            hoursWorked: hours
        )
        s.truckId = truckId
        s.truckNumber = "TEST-UNIT-1"
        return s
    }

    // MARK: - Engine input

    static func input(
        payRule: PayRule = .percentOfGross(70),
        type: SettlementType = .companyDriver,
        payOnGross: Bool = true,
        loads: [SettlementLoadLine] = [],
        additions: [SettlementAddition] = [],
        deductions: [SettlementDeduction] = [],
        fees: CompanyFeeSettings = .none,
        hours: Decimal? = nil,
        isEstimate: Bool = false
    ) -> SettlementCalculationInput {
        SettlementCalculationInput(
            settlementType: type,
            payRule: payRule,
            payOnGrossRevenue: payOnGross,
            loadLines: loads,
            additions: additions,
            deductions: deductions,
            hoursWorked: hours,
            companyFees: fees,
            isEstimate: isEstimate
        )
    }
}

// MARK: - Assertion helper

extension XCTestCase {
    /// Money comparison with an exact-cents expectation. Decimal math is exact,
    /// so there is deliberately NO accuracy tolerance here — a tolerance would
    /// hide the very bug this type exists to prevent.
    func XCTAssertMoney(
        _ actual: Money,
        _ expectedDollars: Int,
        _ expectedCents: Int = 0,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = Money(cents: expectedDollars * 100 + expectedCents)
        XCTAssertEqual(
            actual.rounded, expected.rounded,
            message.isEmpty
                ? "expected \(expected.formatted), got \(actual.formatted)"
                : "\(message) — expected \(expected.formatted), got \(actual.formatted)",
            file: file, line: line
        )
    }

    func XCTAssertMoney(
        _ actual: Money,
        _ expected: Money,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual.rounded, expected.rounded,
            message.isEmpty
                ? "expected \(expected.formatted), got \(actual.formatted)"
                : "\(message) — expected \(expected.formatted), got \(actual.formatted)",
            file: file, line: line
        )
    }
}
