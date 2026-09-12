import XCTest
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

/// The point of `Money` is that a driver can add the statement up by hand and
/// land on the same number. These tests are the contract for that.
final class MoneyTests: XCTestCase {

    // MARK: - The floating-point failures this type exists to prevent

    func testAdditionIsExact() {
        let sum = Money(cents: 10) + Money(cents: 20)
        XCTAssertEqual(sum, Money(cents: 30))
        // The Double version of the same sum is NOT 0.30.
        XCTAssertNotEqual(0.1 + 0.2, 0.3)
    }

    func testRepeatedAdditionDoesNotDrift() {
        var total = Money.zero
        for _ in 0..<1_000 { total += Money(cents: 1) }
        XCTAssertEqual(total, Money(cents: 1_000))
        XCTAssertEqual(total.formatted, "$10.00")
    }

    func testSeventyPercentOfSevenThousandTwoFifty() {
        let gross = Money(cents: 725_000)          // $7,250.00
        let driver = gross.percentage(70).rounded  // $5,075.00
        XCTAssertEqual(driver, Money(cents: 507_500))
        XCTAssertEqual(driver.formatted, "$5,075.00")
    }

    // MARK: - Rounding

    func testRoundsHalfAwayFromZero() {
        XCTAssertEqual(Money(Decimal(string: "1.005")!).rounded, Money(cents: 101))
        XCTAssertEqual(Money(Decimal(string: "2.675")!).rounded, Money(cents: 268))
        XCTAssertEqual(Money(Decimal(string: "-1.005")!).rounded, Money(cents: -101))
    }

    func testRoundingIsIdempotent() {
        let m = Money(Decimal(string: "123.456789")!)
        XCTAssertEqual(m.rounded, m.rounded.rounded)
        XCTAssertEqual(m.rounded.formatted, "$123.46")
    }

    func testIntermediatePrecisionIsKept() {
        // 33.333...% of $100 held at full precision, rounded only at the end.
        let third = Money(cents: 10_000).percentage(Decimal(string: "33.3333333")!)
        XCTAssertEqual(third.rounded, Money(cents: 3_333))
        // Rounding early would lose the third decimal; it must not have.
        XCTAssertNotEqual(third, third.rounded)
    }

    func testPerMileRateKeepsThreeDecimals() {
        let rate = Money(Decimal(string: "0.585")!)
        XCTAssertEqual(rate.rounded(scale: 3).formatted, "$0.59")  // display rounds to cents
        XCTAssertEqual(rate.rounded(scale: 3).amount, Decimal(string: "0.585")!)
    }

    // MARK: - Construction

    func testDoubleBridgeDoesNotCarryBinaryNoise() {
        let m = Money(double: 1234.5699999999999)
        XCTAssertEqual(m.rounded, Money(cents: 123_457))
    }

    func testParsesUserInput() {
        XCTAssertEqual(Money(input: "$1,234.56"), Money(cents: 123_456))
        XCTAssertEqual(Money(input: "1234.56"), Money(cents: 123_456))
        XCTAssertEqual(Money(input: "(50.00)"), Money(cents: -5_000))
        XCTAssertEqual(Money(input: "-50"), Money(cents: -5_000))
        XCTAssertNil(Money(input: ""))
        XCTAssertNil(Money(input: "abc"))
    }

    // MARK: - Guards

    func testClampAndCap() {
        XCTAssertEqual(Money(cents: -500).clampedToZero, .zero)
        XCTAssertEqual(Money(cents: 500).clampedToZero, Money(cents: 500))
        XCTAssertEqual(Money(cents: 500).capped(at: Money(cents: 300)), Money(cents: 300))
        XCTAssertEqual(Money(cents: 200).capped(at: Money(cents: 300)), Money(cents: 200))
        XCTAssertEqual(Money(cents: 200).capped(at: .zero), .zero)
    }

    func testDivideByZeroIsZeroNotACrash() {
        XCTAssertEqual(Money(cents: 100) / 0, .zero)
    }

    // MARK: - Formatting

    func testFormatting() {
        XCTAssertEqual(Money(cents: 0).formatted, "$0.00")
        XCTAssertEqual(Money(cents: 159_500).formatted, "$1,595.00")
        XCTAssertEqual(Money(cents: -118_000).formatted, "-$1,180.00")
        XCTAssertEqual(Money(cents: 118_000).formattedSigned(asCredit: false), "-$1,180.00")
        XCTAssertEqual(Money(cents: 25_000).formattedSigned(asCredit: true), "+$250.00")
        XCTAssertEqual(Money.zero.formattedSigned(asCredit: false), "$0.00")
    }

    // MARK: - Codable

    func testRoundTripsThroughJSONAsANumber() throws {
        let original = Money(cents: 507_500)
        let data = try JSONEncoder().encode(["net": original])
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("5075"), "should encode as a JSON number, got \(json)")

        let decoded = try JSONDecoder().decode([String: Money].self, from: data)
        XCTAssertEqual(decoded["net"], original)
    }

    func testDecodesFromADoubleColumn() throws {
        let data = Data(#"{"net": 5075.00}"#.utf8)
        let decoded = try JSONDecoder().decode([String: Money].self, from: data)
        XCTAssertEqual(decoded["net"]?.rounded, Money(cents: 507_500))
    }

    func testEncodedValueIsAlwaysRounded() throws {
        let messy = Money(Decimal(string: "100.123456789")!)
        let data = try JSONEncoder().encode(["v": messy])
        let decoded = try JSONDecoder().decode([String: Money].self, from: data)
        XCTAssertEqual(decoded["v"], Money(cents: 10_012))
    }

    // MARK: - Sum

    func testSumOfRoundedPartsEqualsPrintedTotal() {
        let parts = [Money(cents: 333), Money(cents: 333), Money(cents: 334)]
        XCTAssertEqual(Money.sum(parts), Money(cents: 1_000))
    }
}
