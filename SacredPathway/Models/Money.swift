import Foundation

// =============================================================================
//  Money — decimal-safe currency value type
// -----------------------------------------------------------------------------
//  Every dollar figure that prints on a driver's settlement statement flows
//  through this type. Backed by `Decimal`, never `Double`, so 0.1 + 0.2 is
//  exactly 0.30 and 70% of $7,250.00 is exactly $5,075.00.
//
//  Precision policy (matches how a bookkeeper works):
//   - Intermediate math keeps FULL precision. A percentage of a percentage is
//     not rounded halfway through.
//   - Rounding happens only at an accounting boundary — one printed line, one
//     stored column, one total the driver can add up by hand.
//   - Rounding mode is .plain (half away from zero), the payroll convention.
//     Bankers' rounding is deliberately NOT used: a driver checking
//     $1,234.565 expects $1,234.57, not $1,234.56.
//
//  Interop: the legacy engine, the Supabase `numeric` columns and the existing
//  PDF services all speak Double. `doubleValue` is the single conversion point,
//  and it always rounds first.
// =============================================================================

struct Money: Hashable, Comparable, Codable, CustomStringConvertible {

    /// Exact, unrounded value. Never mutated in place.
    private(set) var amount: Decimal

    // MARK: - Construction

    init(_ amount: Decimal) {
        self.amount = amount
    }

    /// From a whole number of cents — the safest literal form for tests.
    init(cents: Int) {
        self.amount = Decimal(cents) / 100
    }

    /// From a Double coming out of a legacy model or a Supabase `numeric`.
    /// Routes through a fixed-precision string so 1234.5699999999999 does not
    /// survive into Decimal.
    init(double: Double) {
        guard double.isFinite else { self.amount = 0; return }
        self.amount = Decimal(string: String(format: "%.6f", double)) ?? Decimal(0)
    }

    /// Parses user input: "$1,234.56", "1234.56", "(50.00)" -> -50.00, "" -> nil.
    init?(input: String) {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast())
        }
        s = s.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        if s.hasPrefix("-") { negative = true; s = String(s.dropFirst()) }
        guard !s.isEmpty, let d = Decimal(string: s), d.isFinite else { return nil }
        self.amount = negative ? -d : d
    }

    static let zero = Money(Decimal(0))

    // MARK: - Rounding

    /// Rounded to cents, half away from zero. Idempotent.
    var rounded: Money { Money(Money.round(amount, scale: 2)) }

    /// Rounded to an arbitrary scale — for per-mile figures (3dp) and ratios,
    /// never for a printed dollar total.
    func rounded(scale: Int) -> Money { Money(Money.round(amount, scale: scale)) }

    static func round(_ value: Decimal, scale: Int) -> Decimal {
        var result = Decimal()
        var input = value
        NSDecimalRound(&result, &input, scale, .plain)
        return result
    }

    /// Whole cents as an Int. Only meaningful on a rounded value.
    var centsValue: Int {
        NSDecimalNumber(decimal: Money.round(amount * 100, scale: 0)).intValue
    }

    /// Boundary conversion for legacy Double APIs (Supabase, PDF services).
    /// Always rounds first so a stored column can never carry 14 decimals.
    var doubleValue: Double {
        NSDecimalNumber(decimal: rounded.amount).doubleValue
    }

    /// Full-precision Double. For ratio/metric display only, never for money.
    var rawDoubleValue: Double {
        NSDecimalNumber(decimal: amount).doubleValue
    }

    // MARK: - Sign

    var isZero: Bool { amount == 0 }
    var isNegative: Bool { amount < 0 }
    var isPositive: Bool { amount > 0 }
    var magnitude: Money { Money(amount < 0 ? -amount : amount) }
    var negated: Money { Money(-amount) }

    /// Clamped at zero — used wherever a negative amount is nonsense, e.g. an
    /// advance recovery that would exceed the outstanding balance.
    var clampedToZero: Money { amount < 0 ? .zero : self }

    /// Never more than `ceiling`, never less than zero.
    func capped(at ceiling: Money) -> Money {
        if ceiling.amount <= 0 { return .zero }
        return amount > ceiling.amount ? ceiling : clampedToZero
    }

    // MARK: - Arithmetic

    static func + (l: Money, r: Money) -> Money { Money(l.amount + r.amount) }
    static func - (l: Money, r: Money) -> Money { Money(l.amount - r.amount) }
    static func * (l: Money, r: Decimal) -> Money { Money(l.amount * r) }
    static func * (l: Decimal, r: Money) -> Money { Money(l * r.amount) }
    static func / (l: Money, r: Decimal) -> Money {
        guard r != 0 else { return .zero }
        return Money(l.amount / r)
    }
    static func += (l: inout Money, r: Money) { l = l + r }
    static func -= (l: inout Money, r: Money) { l = l - r }
    static prefix func - (m: Money) -> Money { m.negated }

    /// `percent` is expressed the way a carrier says it out loud: 70 means 70%.
    /// Full precision is retained — the caller decides where to round.
    func percentage(_ percent: Decimal) -> Money {
        Money(amount * percent / 100)
    }

    static func < (l: Money, r: Money) -> Bool { l.amount < r.amount }

    static func sum(_ values: [Money]) -> Money { values.reduce(Money.zero, +) }

    // MARK: - Formatting

    /// "$1,234.56" / "-$1,234.56". Locale-fixed to en_US so a statement looks
    /// identical on every device and in every exported PDF.
    var formatted: String {
        Money.formatter.string(from: NSDecimalNumber(decimal: rounded.amount)) ?? "$0.00"
    }

    /// "-$1,180.00" for a deduction line, "+$250.00" for a credit line.
    func formattedSigned(asCredit: Bool) -> String {
        let base = magnitude.formatted
        if rounded.isZero { return base }
        return (asCredit ? "+" : "-") + base
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    var description: String { formatted }

    // MARK: - Codable
    //
    // Encoded as a JSON number so Supabase `numeric` columns and the local JSON
    // store round-trip identically to every other money field already in the app.

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Decimal.self) {
            amount = d
        } else if let s = try? c.decode(String.self), let d = Decimal(string: s) {
            amount = d
        } else {
            amount = Decimal(try c.decode(Double.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rounded.amount)
    }
}

// MARK: - Bridges

extension Double {
    var asMoney: Money { Money(double: self) }
}

extension Optional where Wrapped == Double {
    /// nil becomes $0.00 — every money column in the existing schema is nullable.
    var asMoney: Money { Money(double: self ?? 0) }
}

extension Decimal {
    /// "70" -> "70%", "12.5" -> "12.5%"
    var asPercentString: String {
        let n = NSDecimalNumber(decimal: Money.round(self, scale: 2))
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.locale = Locale(identifier: "en_US")
        return (f.string(from: n) ?? "0") + "%"
    }

    /// Safe parse of a user-entered percentage or rate.
    init?(userInput: String) {
        let s = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: "")
        guard !s.isEmpty, let d = Decimal(string: s), d.isFinite else { return nil }
        self = d
    }
}
