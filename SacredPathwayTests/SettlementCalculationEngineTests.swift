import XCTest
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

/// Golden tests for the math that prints real paychecks. Each test states the
/// business rule it locks in — a future change that alters driver pay has to
/// consciously update an expectation here.
final class SettlementCalculationEngineTests: XCTestCase {

    // MARK: - 1. Percentage pay

    /// The brief's headline example: $5,000 gross at 70% is $3,500.
    func testPercentagePay() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(payRule: .percentOfGross(70), loads: [Fx.load(1, gross: 5_000)])
        )
        XCTAssertMoney(result.grossLoadRevenue, 5_000)
        XCTAssertMoney(result.driverBaseEarnings, 3_500)
        XCTAssertMoney(result.netDriverPay, 3_500)
    }

    func testPercentagePayAcrossMultipleLoads() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(loads: [Fx.load(1, gross: 3_500), Fx.load(2, gross: 3_750)])
        )
        XCTAssertMoney(result.grossLoadRevenue, 7_250)
        XCTAssertMoney(result.driverBaseEarnings, 5_075)
        XCTAssertEqual(result.totalLoads, 2)
    }

    /// Each load line is rounded on its own, and the total is the sum of those
    /// rounded lines — so the printed table always adds up.
    func testPerLoadRoundingSumsToTheTotal() {
        let loads = [
            Fx.componentLoad(1, linehaul: Money(cents: 33_333)),   // $333.33
            Fx.componentLoad(2, linehaul: Money(cents: 33_333)),
            Fx.componentLoad(3, linehaul: Money(cents: 33_334))
        ]
        let result = SettlementCalculationEngine.calculate(
            Fx.input(payRule: .percentOfGross(33), loads: loads)
        )
        let lineSum = Money.sum(result.earningLines.map(\.amount))
        XCTAssertEqual(lineSum, result.driverBaseEarnings)
        XCTAssertTrue(result.reconciles)
    }

    // MARK: - 2. Fixed per-load pay

    func testFlatPerLoadPay() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                payRule: .flatPerLoad(Fx.money(400)),
                loads: [Fx.load(1, gross: 3_000), Fx.load(2, gross: 2_000), Fx.load(3, gross: 1_000)]
            )
        )
        XCTAssertMoney(result.driverBaseEarnings, 1_200, 0, "3 loads × $400")
        XCTAssertMoney(result.grossLoadRevenue, 6_000)
        // Flat pay is independent of revenue.
        XCTAssertMoney(result.companyRetained, 4_800)
    }

    // MARK: - 3. Per-mile pay

    func testPerMilePayOnLoadedMiles() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                payRule: .perMile(Money(Decimal(string: "0.58")!), basis: .loaded),
                loads: [Fx.load(1, gross: 2_000, loadedMiles: 1_200, deadheadMiles: 150)]
            )
        )
        XCTAssertMoney(result.driverBaseEarnings, 696, 0, "1,200 × $0.58")
        XCTAssertEqual(result.loadedMiles, 1_200)
        XCTAssertEqual(result.deadheadMiles, 150)
        XCTAssertEqual(result.totalMiles, 1_350)
    }

    func testPerMilePayOnAllMilesIncludesDeadhead() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                payRule: .perMile(Money(Decimal(string: "0.58")!), basis: .total),
                loads: [Fx.load(1, gross: 2_000, loadedMiles: 1_200, deadheadMiles: 150)]
            )
        )
        XCTAssertMoney(result.driverBaseEarnings, 783, 0, "1,350 × $0.58")
    }

    func testPerMileFractionalRateRoundsOnce() {
        // $0.585/mi × 1,001 miles = $585.585 -> $585.59
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                payRule: .perMile(Money(Decimal(string: "0.585")!)),
                loads: [Fx.load(1, gross: 2_000, loadedMiles: 1_001)]
            )
        )
        XCTAssertMoney(result.driverBaseEarnings, 585, 59)
    }

    // MARK: - 4. Salary, hourly, manual

    func testWeeklySalaryIsPaidOncePerSettlementNotPerLoad() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                payRule: .weeklySalary(Fx.money(1_400)),
                loads: [Fx.load(1, gross: 3_000), Fx.load(2, gross: 4_000)]
            )
        )
        XCTAssertMoney(result.driverBaseEarnings, 1_400)
        XCTAssertEqual(result.earningLines.filter { $0.kind == .settlementEarning }.count, 1)
    }

    func testHourlyPay() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                payRule: .hourly(Money(cents: 2_800)),
                loads: [Fx.load(1, gross: 2_000)],
                hours: Decimal(string: "42.5")!
            )
        )
        XCTAssertMoney(result.driverBaseEarnings, 1_190, 0, "42.5 hrs × $28.00")
    }

    func testHourlyWithoutHoursWarnsAndPaysZero() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(payRule: .hourly(Money(cents: 2_800)), loads: [Fx.load(1, gross: 2_000)])
        )
        XCTAssertMoney(result.driverBaseEarnings, 0)
        XCTAssertTrue(result.warnings.contains { $0.contains("no hours") })
    }

    func testManualPay() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(payRule: .manual(Fx.money(2_222)), loads: [Fx.load(1, gross: 9_000)])
        )
        XCTAssertMoney(result.driverBaseEarnings, 2_222)
    }

    // MARK: - 5. Combination pay

    func testCombinationPayAddsEveryComponent() {
        let rule = PayRule(components: [
            PayComponent(kind: .percentOfGross, percent: 25),
            PayComponent(kind: .perMile, rate: Money(cents: 10), mileBasis: .loaded),
            PayComponent(kind: .weeklySalary, label: "Base", rate: Fx.money(500))
        ])
        let result = SettlementCalculationEngine.calculate(
            Fx.input(payRule: rule, loads: [Fx.load(1, gross: 4_000, loadedMiles: 1_000)])
        )
        // 25% of 4,000 = 1,000 · 1,000 mi × $0.10 = 100 · salary 500
        XCTAssertMoney(result.driverBaseEarnings, 1_600)
    }

    // MARK: - 6. Per-load overrides

    func testPerLoadPayRuleOverrideWinsOverTheDriverDefault() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                payRule: .percentOfGross(70),
                loads: [
                    Fx.load(1, gross: 1_000),                                     // 700
                    Fx.load(2, gross: 1_000, payRuleOverride: .percentOfGross(50)) // 500
                ]
            )
        )
        XCTAssertMoney(result.driverBaseEarnings, 1_200)
    }

    // MARK: - 7. Additions

    func testAdditionsIncreaseNetPayButNotGrossLoadRevenue() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                loads: [Fx.load(1, gross: 5_000)],
                additions: [
                    Fx.addition(1, .detention, "Detention at receiver", 150),
                    Fx.addition(2, .safetyBonus, "Clean inspection bonus", 250)
                ]
            )
        )
        XCTAssertMoney(result.grossLoadRevenue, 5_000, 0, "additions are not load revenue")
        XCTAssertMoney(result.totalAdditions, 400)
        XCTAssertMoney(result.settlementGross, 5_400)
        XCTAssertMoney(result.driverBaseEarnings, 3_500)
        XCTAssertMoney(result.netDriverPay, 3_900)
    }

    // MARK: - 8. Deductions

    func testMultipleDeductions() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                loads: [Fx.load(1, gross: 10_000)],
                deductions: [
                    Fx.deduction(1, .fuel, "Fuel", 1_500),
                    Fx.deduction(2, .insurance, "Insurance", 450),
                    Fx.deduction(3, .truckLease, "Truck payment", 1_300)
                ]
            )
        )
        XCTAssertMoney(result.driverBaseEarnings, 7_000)
        XCTAssertMoney(result.totalDriverDeductions, 3_250)
        XCTAssertMoney(result.netDriverPay, 3_750)
    }

    func testCompanyResponsibleDeductionsDoNotTouchTheDriverCheck() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                loads: [Fx.load(1, gross: 10_000)],
                deductions: [
                    Fx.deduction(1, .fuel, "Fuel", 1_500, responsibility: .company),
                    Fx.deduction(2, .insurance, "Insurance", 450, responsibility: .driver)
                ]
            )
        )
        XCTAssertMoney(result.totalDriverDeductions, 450)
        XCTAssertMoney(result.companyExpenses, 1_500)
        XCTAssertMoney(result.netDriverPay, 6_550, 0, "7,000 − 450")
        XCTAssertMoney(result.companyRetained, 1_950, 0, "10,000 − 6,550 − 1,500")
    }

    func testSplitResponsibilityDividesTheLine() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                loads: [Fx.load(1, gross: 10_000)],
                deductions: [
                    Fx.deduction(1, .repair, "Tire repair", 1_000,
                                 responsibility: .split, driverShare: 60)
                ]
            )
        )
        XCTAssertMoney(result.totalDriverDeductions, 600)
        XCTAssertMoney(result.companyExpenses, 400)
        XCTAssertMoney(result.netDriverPay, 6_400)
    }

    func testSplitWithOddCentsStillSumsToTheWholeLine() {
        let deduction = SettlementDeduction(
            profileId: Fx.profileId,
            category: .repair,
            descriptionText: "Odd split",
            amount: Money(cents: 100_01),      // $1,000.01
            responsibility: .split,
            driverSharePercent: Decimal(string: "33.3333")!
        )
        let total = deduction.driverAmount + deduction.companyAmount
        XCTAssertEqual(total, deduction.amount.rounded)
    }

    // MARK: - 9. Company fees

    func testCompanyFeesExpandIntoDeductionLines() {
        let fees = CompanyFeeSettings(
            dispatcherFeePercent: 5,
            factoringFeePercent: Decimal(string: "2.5")!,
            authorityFee: Fx.money(100),
            maintenanceReserve: Fx.money(200)
        )
        let result = SettlementCalculationEngine.calculate(
            Fx.input(loads: [Fx.load(1, gross: 10_000)], fees: fees)
        )
        // All four default to company responsibility.
        XCTAssertMoney(result.totalDriverDeductions, 0)
        XCTAssertMoney(result.companyExpenses, 1_050, 0, "500 + 250 + 100 + 200")
        XCTAssertMoney(result.netDriverPay, 7_000)
        XCTAssertMoney(result.companyRetained, 1_950, 0, "10,000 − 7,000 − 1,050")
    }

    func testFeesChargedToTheDriverComeOffTheCheck() {
        let fees = CompanyFeeSettings(
            factoringFeePercent: 3,
            factoringFeeResponsibility: .driver
        )
        let result = SettlementCalculationEngine.calculate(
            Fx.input(loads: [Fx.load(1, gross: 10_000)], fees: fees)
        )
        XCTAssertMoney(result.totalDriverDeductions, 300)
        XCTAssertMoney(result.netDriverPay, 6_700)
    }

    func testFeeLineIdsAreStableAcrossRecalculation() {
        let input = Fx.input(
            loads: [Fx.load(1, gross: 10_000)],
            fees: CompanyFeeSettings(dispatcherFeePercent: 5)
        )
        let first = SettlementCalculationEngine.calculate(input)
        let second = SettlementCalculationEngine.calculate(input)
        XCTAssertEqual(first.companyExpenseLines.map(\.id),
                       second.companyExpenseLines.map(\.id))
    }

    // MARK: - 10. Percent-of-net basis (legacy behaviour)

    func testPercentOfNetPaysOnRevenueMinusCompanyCosts() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                payRule: .percentOfGross(25),
                payOnGross: false,
                loads: [Fx.load(1, gross: 10_000)],
                deductions: [Fx.deduction(1, .fuel, "Fuel", 2_000, responsibility: .company)]
            )
        )
        // Net basis = 10,000 − 2,000 = 8,000. 25% = 2,000.
        XCTAssertMoney(result.driverBaseEarnings, 2_000)
    }

    func testPercentOfNetAllocationSumsExactly() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                payRule: .percentOfGross(Decimal(string: "33.33")!),
                payOnGross: false,
                loads: [
                    Fx.load(1, gross: 3_333),
                    Fx.load(2, gross: 3_333),
                    Fx.load(3, gross: 3_334)
                ],
                deductions: [Fx.deduction(1, .fuel, "Fuel", 1_000, responsibility: .company)]
            )
        )
        let lineSum = Money.sum(result.earningLines.map(\.amount))
        XCTAssertEqual(lineSum, result.driverBaseEarnings)
        XCTAssertTrue(result.warnings.allSatisfy { !$0.contains("residual") },
                      "allocation must not leave a residual: \(result.warnings)")
    }

    // MARK: - 11. Lease operator

    func testLeaseOperatorCarriesItsOwnCosts() {
        // 70/30 split, driver responsible for truck, insurance, fuel; company
        // absorbs the factoring fee.
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                payRule: .percentOfGross(70),
                type: .leaseOperator,
                loads: [Fx.load(1, gross: 8_000)],
                deductions: [
                    Fx.deduction(1, .truckLease, "Weekly truck payment", 1_300),
                    Fx.deduction(2, .insurance, "Occupational + physical damage", 450),
                    Fx.deduction(3, .fuel, "Fuel", 1_600),
                    Fx.deduction(4, .escrow, "Maintenance escrow", 200)
                ],
                fees: CompanyFeeSettings(factoringFeePercent: 3)
            )
        )
        XCTAssertMoney(result.driverBaseEarnings, 5_600)
        XCTAssertMoney(result.totalDriverDeductions, 3_550)
        XCTAssertMoney(result.netDriverPay, 2_050)
        XCTAssertMoney(result.companyExpenses, 240, 0, "3% factoring")
        XCTAssertMoney(result.companyRetained, 5_710, 0, "8,000 − 2,050 − 240")
    }

    func testLeaseConfigDecidesResponsibilityPerCategory() {
        let config = LeaseOperatorConfig(
            driverGrossPercent: 72,
            companyGrossPercent: 28,
            rules: [
                ResponsibilityRule(category: .fuel, responsibility: .driver),
                ResponsibilityRule(category: .insurance, responsibility: .company),
                ResponsibilityRule(category: .repair, responsibility: .split,
                                   driverSharePercent: 50)
            ]
        )
        let settings = DriverPaySettings(
            profileId: Fx.profileId,
            driverId: Fx.driverId,
            settlementType: .leaseOperator,
            payRule: .percentOfGross(72),
            leaseConfig: config
        )

        XCTAssertEqual(settings.responsibility(for: .fuel).0, .driver)
        XCTAssertEqual(settings.responsibility(for: .insurance).0, .company)
        XCTAssertEqual(settings.responsibility(for: .repair).0, .split)
        XCTAssertEqual(settings.responsibility(for: .repair).1, 50)
        // Unlisted category falls back to the settlement type's default.
        XCTAssertEqual(settings.responsibility(for: .truckLease).0, .driver)
    }

    func testCompanyDriverDefaultsDoNotChargeFuelToTheDriver() {
        let settings = DriverPaySettings(
            profileId: Fx.profileId,
            driverId: Fx.driverId,
            settlementType: .companyDriver,
            payRule: .percentOfGross(27)
        )
        XCTAssertEqual(settings.responsibility(for: .fuel).0, .company)
        XCTAssertEqual(settings.responsibility(for: .cashAdvance).0, .driver)
    }

    // MARK: - 12. Company retained and margin

    func testCompanyRetainedIsRevenueMinusDriverMinusCompanyCosts() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                loads: [Fx.load(1, gross: 10_000)],
                additions: [Fx.addition(1, .bonus, "Bonus", 200)],
                deductions: [
                    Fx.deduction(1, .fuel, "Fuel", 2_000, responsibility: .company),
                    Fx.deduction(2, .cashAdvance, "Advance", 500)
                ]
            )
        )
        XCTAssertMoney(result.netDriverPay, 6_700, 0, "7,000 + 200 − 500")
        XCTAssertMoney(result.companyExpenses, 2_000)
        XCTAssertMoney(result.companyRetained, 1_300, 0, "10,000 − 6,700 − 2,000")
        XCTAssertEqual(result.companyMargin, result.companyRetained)
    }

    // MARK: - 13. Metrics

    func testMetrics() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                loads: [
                    Fx.load(1, gross: 4_000, loadedMiles: 1_000, deadheadMiles: 100),
                    Fx.load(2, gross: 3_000, loadedMiles: 800, deadheadMiles: 100)
                ],
                deductions: [Fx.deduction(1, .fuel, "Fuel", 1_000, responsibility: .company)]
            )
        )
        XCTAssertEqual(result.totalMiles, 2_000)
        XCTAssertMoney(result.revenuePerMile, 3, 50, "$7,000 / 2,000 mi")
        XCTAssertMoney(result.driverEarningsPerMile, 2, 45, "$4,900 / 2,000 mi")
        XCTAssertMoney(result.fuelCostPerMile, 0, 50, "$1,000 / 2,000 mi")
        // (4,900 net + 1,000 company) / 7,000 = 0.8429
        XCTAssertEqual(result.expenseRatio, Decimal(string: "0.8429")!)
    }

    func testZeroMilesDoesNotDivideByZero() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(loads: [Fx.load(1, gross: 1_000, loadedMiles: 0)])
        )
        XCTAssertMoney(result.revenuePerMile, 0)
        XCTAssertMoney(result.fuelCostPerMile, 0)
        XCTAssertTrue(result.warnings.contains { $0.contains("No mileage") })
    }

    // MARK: - 14. Reconciliation and determinism

    func testEveryResultReconciles() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(
                payRule: PayRule(components: [
                    PayComponent(kind: .percentOfGross, percent: 68),
                    PayComponent(kind: .perMile, rate: Money(cents: 7))
                ]),
                loads: [Fx.load(1, gross: 3_333, loadedMiles: 777),
                        Fx.load(2, gross: 2_121, loadedMiles: 613)],
                additions: [Fx.addition(1, .detention, "Detention", 137)],
                deductions: [Fx.deduction(1, .fuel, "Fuel", 911),
                             Fx.deduction(2, .repair, "Repair", 333,
                                          responsibility: .split, driverShare: 50)],
                fees: CompanyFeeSettings(dispatcherFeePercent: Decimal(string: "4.5")!)
            )
        )
        XCTAssertTrue(result.reconciles, "lines must sum to net pay")
    }

    func testEngineIsDeterministic() {
        let input = Fx.input(
            loads: [Fx.load(1, gross: 3_500), Fx.load(2, gross: 3_750)],
            deductions: [Fx.deduction(1, .fuel, "Fuel", 1_180)]
        )
        let a = SettlementCalculationEngine.calculate(input)
        let b = SettlementCalculationEngine.calculate(input)
        XCTAssertEqual(a.netDriverPay, b.netDriverPay)
        XCTAssertEqual(a.lineItems, b.lineItems)
        XCTAssertEqual(a.engineVersion, SettlementCalculationEngine.engineVersion)
    }

    func testEmptySettlementIsZeroNotACrash() {
        let result = SettlementCalculationEngine.calculate(Fx.input(loads: []))
        XCTAssertMoney(result.grossLoadRevenue, 0)
        XCTAssertMoney(result.netDriverPay, 0)
        XCTAssertTrue(result.reconciles)
    }

    // MARK: - 15. Estimates

    func testEstimateFlagIsCarriedThrough() {
        let result = SettlementCalculationEngine.calculate(
            Fx.input(loads: [Fx.load(1, gross: 1_000)], isEstimate: true)
        )
        XCTAssertTrue(result.isEstimate)
    }

    // MARK: - 16. Accessorial components

    func testGrossIsBuiltFromAccessorialComponents() {
        let line = Fx.componentLoad(
            1,
            linehaul: Fx.money(2_500),
            fuelSurcharge: Fx.money(300),
            detention: Fx.money(150),
            layover: Fx.money(200),
            tonu: Fx.money(0),
            lumper: Fx.money(75),
            accessorials: Fx.money(25)
        )
        XCTAssertMoney(line.grossRate, 3_250)
    }

    func testGrossOverrideWinsOverComponents() {
        var line = Fx.componentLoad(1, linehaul: Fx.money(2_500), detention: Fx.money(150))
        line.grossRateOverride = Fx.money(2_800)
        XCTAssertMoney(line.grossRate, 2_800)
    }

    // MARK: - 17. Allocation helper

    func testAllocateSplitsWithoutLosingACent() {
        let buckets = [(Fx.id(1), Money(cents: 100)),
                       (Fx.id(2), Money(cents: 100)),
                       (Fx.id(3), Money(cents: 100))]
        let out = SettlementCalculationEngine.allocate(total: Money(cents: 1_000), across: buckets)
        XCTAssertEqual(Money.sum(buckets.map { out[$0.0] ?? .zero }), Money(cents: 1_000))
    }

    func testAllocateWithZeroWeightSplitsEvenly() {
        let buckets = [(Fx.id(1), Money.zero), (Fx.id(2), Money.zero)]
        let out = SettlementCalculationEngine.allocate(total: Money(cents: 1_000), across: buckets)
        XCTAssertEqual(out[Fx.id(1)], Money(cents: 500))
        XCTAssertEqual(out[Fx.id(2)], Money(cents: 500))
    }
}
