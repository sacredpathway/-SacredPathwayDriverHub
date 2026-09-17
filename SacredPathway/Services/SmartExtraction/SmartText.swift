import Foundation

// =============================================================================
// MARK: - SmartText: parsing + normalization toolkit shared by every extractor
// =============================================================================

/// Thread-safe cache of compiled regular expressions.
nonisolated final class SmartRegexCache: @unchecked Sendable {
    static let shared = SmartRegexCache()
    private var cache: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    func regex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let key = (caseInsensitive ? "i:" : "s:") + pattern
        lock.lock(); defer { lock.unlock() }
        if let r = cache[key] { return r }
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let r = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        cache[key] = r
        return r
    }
}

nonisolated struct MoneyToken: Sendable, Equatable {
    var value: Double
    var text: String
    var start: Int
    var end: Int
    var hasSymbol: Bool
    var hasCents: Bool
}

nonisolated struct DateToken: Sendable, Equatable {
    var date: SimpleDate
    var text: String
    var start: Int
    var end: Int
    /// True when the day/month order had to be guessed.
    var ambiguous: Bool
}

nonisolated struct CityStateZip: Sendable, Equatable, Codable {
    var city: String
    var state: String
    var zip: String?
    var cityState: String { "\(city), \(state)" }
}

nonisolated struct LabelHit: Sendable, Equatable {
    var label: String
    var value: String
    var lineIndex: Int
    var valueLineIndex: Int
    var page: Int
    var sameLine: Bool
    var rawLine: String
}

nonisolated enum SmartText {

    // MARK: Regex helpers

    static func regex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression? {
        SmartRegexCache.shared.regex(pattern, caseInsensitive: caseInsensitive)
    }

    static func matches(_ pattern: String, in text: String, caseInsensitive: Bool = true) -> [NSTextCheckingResult] {
        guard let r = regex(pattern, caseInsensitive: caseInsensitive) else { return [] }
        return r.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func contains(_ pattern: String, in text: String, caseInsensitive: Bool = true) -> Bool {
        guard let r = regex(pattern, caseInsensitive: caseInsensitive) else { return false }
        return r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Capture groups of the first match (index 0 = whole match).
    static func groups(_ pattern: String, in text: String, caseInsensitive: Bool = true) -> [String?]? {
        guard let m = matches(pattern, in: text, caseInsensitive: caseInsensitive).first else { return nil }
        return captures(m, in: text)
    }

    static func captures(_ m: NSTextCheckingResult, in text: String) -> [String?] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let range = Range(r, in: text) else { return nil }
            return String(text[range])
        }
    }

    static func replacing(_ pattern: String, in text: String, with template: String, caseInsensitive: Bool = true) -> String {
        guard let r = regex(pattern, caseInsensitive: caseInsensitive) else { return text }
        return r.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func escape(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

    // MARK: Normalization

    /// Unifies look-alike characters and spacing without changing meaning.
    static func normalizeLine(_ raw: String) -> String {
        var s = raw
        let map: [String: String] = [
            "\u{00A0}": " ", "\u{2007}": " ", "\u{202F}": " ", "\t": " ",
            "\u{2013}": "-", "\u{2014}": "-", "\u{2212}": "-", "\u{2010}": "-",
            "\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\"",
            "\u{FF04}": "$", "\u{2026}": "..."
        ]
        for (k, v) in map { s = s.replacingOccurrences(of: k, with: v) }
        s = replacing(#" {2,}"#, in: s, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turns dot/underscore leaders ("Total ....... $12.00") into one space.
    static func stripLeaders(_ s: String) -> String {
        normalizeLine(replacing(#"(?:\s*[.·_]){3,}\s*"#, in: s, with: " "))
    }

    static func lettersOnly(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) }.map(String.init).joined()
    }

    /// Lowercased, alphanumeric-only key for fuzzy comparisons.
    static func key(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func trimPunctuation(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " :;,-#*|/\\.").union(.whitespacesAndNewlines))
    }

    // MARK: Money

    /// Dollar amounts in a line. Rejects dates, times, phone numbers,
    /// percentages and 3-decimal quantities (gallons, prices per gallon).
    static func moneyTokens(in line: String) -> [MoneyToken] {
        let pattern = #"(?<![\w.,/:$-])(-)?\(?(?:USD\s?)?(\$\s?|S(?=\d{1,3}(?:,\d{3})*\.\d{2}(?!\d)))?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{2}))?\)?(-)?(?![\d%/:]|\.\d|,\d{3}|-\d|\s?(?:gal|gallons?|mi|miles|lbs?|pcs?|hrs?|hours?)\b)"#
        let ns = line as NSString
        var out: [MoneyToken] = []
        for m in matches(pattern, in: line) {
            let g = captures(m, in: line)
            guard let intPart = g[3] else { continue }
            let symbol = g[2] != nil
            let cents = g[4]
            // Plain integers without "$" are only money when they carry cents.
            if !symbol && cents == nil { continue }
            let digits = intPart.replacingOccurrences(of: ",", with: "")
            guard var value = Double(digits + "." + (cents ?? "00")) else { continue }
            let negative = g[1] != nil || g[5] != nil || (ns.substring(with: m.range).hasPrefix("(") && ns.substring(with: m.range).hasSuffix(")"))
            if negative { value = -value }
            out.append(MoneyToken(value: (value * 100).rounded() / 100,
                                  text: ns.substring(with: m.range),
                                  start: m.range.location,
                                  end: m.range.location + m.range.length,
                                  hasSymbol: symbol,
                                  hasCents: cents != nil))
        }
        return out
    }

    static func parseMoney(_ s: String) -> Double? {
        if let t = moneyTokens(in: s).first { return t.value }
        // Bare "2850" in a value slot that is clearly money-only.
        let trimmed = trimPunctuation(s).replacingOccurrences(of: ",", with: "")
        if let g = groups(#"^\$?\s?(\d{2,7})(?:\.(\d{1,2}))?$"#, in: trimmed), let i = g[1] {
            return Double(i + "." + (g[2] ?? "00"))
        }
        return nil
    }

    static func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
    }

    static func plainAmount(_ v: Double) -> String { String(format: "%.2f", v) }

    static func trimNumber(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Plain decimal numbers (quantities, gallons, hours, odometer).
    static func numbers(in line: String) -> [(value: Double, text: String, start: Int)] {
        let ns = line as NSString
        return matches(#"(?<![\w.$])(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?(?![\w/:])"#, in: line).compactMap { m in
            let g = captures(m, in: line)
            guard let i = g[1] else { return nil }
            let s = i.replacingOccurrences(of: ",", with: "") + (g[2] ?? "")
            guard let v = Double(s) else { return nil }
            return (v, ns.substring(with: m.range), m.range.location)
        }
    }

    static func approxEqual(_ a: Double, _ b: Double, tolerance: Double = 0.02) -> Bool {
        abs(a - b) <= max(tolerance, abs(b) * 0.0005)
    }

    // MARK: Dates

    static let monthNames: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8,
        "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12
    ]

    static func dateTokens(in line: String) -> [DateToken] {
        var out: [DateToken] = []
        let ns = line as NSString
        func add(_ d: SimpleDate?, _ m: NSTextCheckingResult, ambiguous: Bool = false) {
            guard let d else { return }
            let start = m.range.location, end = start + m.range.length
            if out.contains(where: { $0.start < end && start < $0.end }) { return }
            out.append(DateToken(date: d, text: ns.substring(with: m.range), start: start, end: end, ambiguous: ambiguous))
        }
        func year(_ s: String) -> Int? {
            guard let y = Int(s) else { return nil }
            if s.count == 2 { return 2000 + y }
            return s.count == 4 ? y : nil
        }
        // ISO 2026-09-17
        for m in matches(#"(?<!\d)(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?!\d)"#, in: line) {
            let g = captures(m, in: line)
            if let y = Int(g[1] ?? ""), let mo = Int(g[2] ?? ""), let d = Int(g[3] ?? "") {
                add(SimpleDate(year: y, month: mo, day: d), m)
            }
        }
        // US 09/17/2026, 9-17-26, 09.17.2026
        for m in matches(#"(?<![\d/.-])(\d{1,2})([-/.])(\d{1,2})\2(\d{4}|\d{2})(?![\d/])"#, in: line) {
            let g = captures(m, in: line)
            guard let a = Int(g[1] ?? ""), let b = Int(g[3] ?? ""), let y = year(g[4] ?? "") else { continue }
            if a <= 12 {
                add(SimpleDate(year: y, month: a, day: b), m)
            } else if b <= 12 {
                // 17/09/2026 — day first. Rare on US documents: flag it.
                add(SimpleDate(year: y, month: b, day: a), m, ambiguous: true)
            }
        }
        // Sep 17, 2026 / September 17th 2026
        for m in matches(#"\b(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b"#, in: line) {
            let g = captures(m, in: line)
            if let mo = monthNames[(g[1] ?? "").lowercased()], let d = Int(g[2] ?? ""), let y = Int(g[3] ?? "") {
                add(SimpleDate(year: y, month: mo, day: d), m)
            }
        }
        // 17-Sep-2026 / 17 Sep 26
        for m in matches(#"\b(\d{1,2})[\s-]+(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?[\s,-]+(\d{4}|\d{2})\b"#, in: line) {
            let g = captures(m, in: line)
            if let mo = monthNames[(g[2] ?? "").lowercased()], let d = Int(g[1] ?? ""), let y = year(g[3] ?? "") {
                add(SimpleDate(year: y, month: mo, day: d), m)
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    static func firstDate(in s: String) -> DateToken? { dateTokens(in: s).first }

    // MARK: Times / appointments

    /// "07:00", "0700-1500", "8:00 AM - 3:00 PM", "FCFS", "APPT 0800".
    static func appointment(in s: String) -> String? {
        let text = s
        if let g = groups(#"\b([01]?\d|2[0-3]):([0-5]\d)\s*([ap]\.?m\.?)?(?:\s*(?:-|to|–)\s*([01]?\d|2[0-3]):([0-5]\d)\s*([ap]\.?m\.?)?)?"#, in: text) {
            var out = formatTime(g[1], g[2], g[3])
            if g[4] != nil { out += "–" + formatTime(g[4], g[5], g[6]) }
            if contains(#"\bfcfs\b|first come"#, in: text) { out += " FCFS" }
            return out
        }
        // Military "0700" / "0700-1500" only when next to a date or an appt/time word.
        let hasContext = !dateTokens(in: text).isEmpty || contains(#"\b(appt|appointment|time|window|hours|open|arrive|eta|by)\b"#, in: text)
        if hasContext, let g = groups(#"(?<![\d/.$,])([01]\d|2[0-3])([0-5]\d)(?:\s*(?:-|to)\s*([01]\d|2[0-3])([0-5]\d))?(?![\d/.,])"#, in: text) {
            var out = formatTime(g[1], g[2], nil)
            if g[3] != nil { out += "–" + formatTime(g[3], g[4], nil) }
            return out
        }
        if contains(#"\bfcfs\b|first come,? first serve"#, in: text) { return "FCFS" }
        if contains(#"\bby appt\b|\bappointment required\b|\bappt req"#, in: text) { return "By appointment" }
        return nil
    }

    private static func formatTime(_ h: String?, _ m: String?, _ ampm: String?) -> String {
        guard var hour = Int(h ?? ""), let minute = Int(m ?? "") else { return "" }
        if let ampm = ampm?.lowercased().replacingOccurrences(of: ".", with: "") {
            if ampm == "pm", hour < 12 { hour += 12 }
            if ampm == "am", hour == 12 { hour = 0 }
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    // MARK: Phone / email

    /// "(469) 362-5040" plus an optional extension.
    static func phone(in s: String) -> (number: String, ext: String?)? {
        guard let g = groups(#"(?<!\d)(?:\+?1[\s.-]?)?\(?([2-9]\d{2})\)?[\s.-]?(\d{3})[\s.-]?(\d{4})(?!\d)(?:\s*(?:ext\.?|x|extension|#)\s*(\d{1,6}))?"#, in: s),
              let a = g[1], let b = g[2], let c = g[3] else { return nil }
        return ("(\(a)) \(b)-\(c)", g[4])
    }

    static func email(in s: String) -> String? {
        groups(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, in: s)?.first??.lowercased()
    }

    // MARK: Addresses

    static let stateCodes: Set<String> = [
        "AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA","HI","ID","IL","IN","IA","KS","KY","LA","ME","MD",
        "MA","MI","MN","MS","MO","MT","NE","NV","NH","NJ","NM","NY","NC","ND","OH","OK","OR","PA","RI","SC",
        "SD","TN","TX","UT","VT","VA","WA","WV","WI","WY","DC",
        // Canada (cross-border loads)
        "AB","BC","MB","NB","NL","NS","ON","PE","QC","SK"
    ]

    static let stateNames: [String: String] = [
        "alabama":"AL","alaska":"AK","arizona":"AZ","arkansas":"AR","california":"CA","colorado":"CO","connecticut":"CT",
        "delaware":"DE","florida":"FL","georgia":"GA","hawaii":"HI","idaho":"ID","illinois":"IL","indiana":"IN","iowa":"IA",
        "kansas":"KS","kentucky":"KY","louisiana":"LA","maine":"ME","maryland":"MD","massachusetts":"MA","michigan":"MI",
        "minnesota":"MN","mississippi":"MS","missouri":"MO","montana":"MT","nebraska":"NE","nevada":"NV","new hampshire":"NH",
        "new jersey":"NJ","new mexico":"NM","new york":"NY","north carolina":"NC","north dakota":"ND","ohio":"OH",
        "oklahoma":"OK","oregon":"OR","pennsylvania":"PA","rhode island":"RI","south carolina":"SC","south dakota":"SD",
        "tennessee":"TN","texas":"TX","utah":"UT","vermont":"VT","virginia":"VA","washington":"WA","west virginia":"WV",
        "wisconsin":"WI","wyoming":"WY"
    ]

    /// "El Dorado, AR 71730", "LOVELL WY 82431", "Dallas, Texas".
    static func cityStateZip(in raw: String) -> CityStateZip? {
        let s = stripLeaders(raw)
        let pattern = #"(?:^|[,:]\s*|\s{1})([A-Za-z][A-Za-z .'-]{1,40}?)[,\s]+([A-Za-z]{2})\.?(?:\s+(\d{5})(?:-\d{4})?)?\s*(?:,?\s*(?:USA?|United States))?\s*$"#
        if let g = groups(pattern, in: s), let cityRaw = g[1], let st = g[2]?.uppercased(), stateCodes.contains(st) {
            let city = cleanCity(cityRaw)
            if isPlausibleCity(city) { return CityStateZip(city: city, state: st, zip: g[3]) }
        }
        // Full state name.
        let lower = s.lowercased()
        for (name, code) in stateNames where lower.hasSuffix(name) || lower.contains(name + " ") {
            if let g = groups(#"([A-Za-z][A-Za-z .'-]{1,40}?)[,\s]+"# + escape(name) + #"\.?(?:\s+(\d{5}))?\s*$"#, in: s) {
                let city = cleanCity(g[1] ?? "")
                if isPlausibleCity(city) { return CityStateZip(city: city, state: code, zip: g[2]) }
            }
        }
        return nil
    }

    private static func cleanCity(_ raw: String) -> String {
        let t = trimPunctuation(raw)
        // Title-case ALL CAPS city names.
        if t == t.uppercased() {
            return t.lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        return t
    }

    private static let cityStopWords: Set<String> = [
        "date", "time", "phone", "fax", "email", "contact", "total", "rate", "weight", "miles", "load", "po", "ref",
        "pickup", "delivery", "shipper", "consignee", "appt", "appointment", "invoice", "order", "unit", "truck",
        "trailer", "driver", "carrier", "broker", "amount", "tax", "subtotal", "page", "st", "ave", "rd", "suite",
        "ste", "hwy", "highway", "blvd", "street", "road", "drive", "dr", "ln", "way", "parkway", "pkwy"
    ]

    private static func isPlausibleCity(_ city: String) -> Bool {
        guard city.count >= 3, city.count <= 30 else { return false }
        guard !city.contains(where: { $0.isNumber }) else { return false }
        let words = city.lowercased().split(separator: " ").map(String.init)
        guard words.count <= 4 else { return false }
        if let last = words.last, cityStopWords.contains(last) { return false }
        if let first = words.first, cityStopWords.contains(first) { return false }
        return true
    }

    static func isStreetAddress(_ raw: String) -> Bool {
        let s = stripLeaders(raw)
        if contains(#"^\s*(p\.?\s?o\.?\s+box|pobox)\s+\d+"#, in: s) { return true }
        guard contains(#"^\s*\d{1,6}[A-Za-z]?\s+[A-Za-z0-9]"#, in: s) else { return false }
        if s.count > 70 || !moneyTokens(in: s).isEmpty || contains(#"\d{3}/\d{2}\s?r|\b(qty|gal|hrs?|lbs?)\b|@"#, in: s) { return false }
        if dateTokens(in: s).first?.start == 0 { return false }
        let suffix = #"\b(st|street|ave|avenue|av|rd|road|blvd|boulevard|dr|drive|hwy|highway|pkwy|parkway|ln|lane|way|ct|court|pl|place|cir|circle|trl|trail|pike|loop|ter|terrace|expy|expressway|fwy|freeway|route|rte|rt|us|sr|interstate|i-\d+|industrial|park|plaza|center|centre|row|run|square|sq|crossing|xing|bypass|byp|frontage)\b"#
        return contains(suffix, in: s) || contains(#"^\s*\d{1,6}\s+[NSEW]\.?\s+\w+"#, in: s)
    }

    // MARK: Weights / identifiers

    /// Pounds from "43,244 lbs", "43244.0", "20000 KG" (converted).
    static func weightPounds(in s: String) -> Double? {
        if let g = groups(#"(?<![\d.$])(\d{1,3}(?:,\d{3})+|\d{3,6})(\.\d+)?\s*(lbs?|pounds|#|kgs?|kilograms?)?(?![\d/])"#, in: s),
           let i = g[1], var v = Double(i.replacingOccurrences(of: ",", with: "") + (g[2] ?? "")) {
            if let unit = g[3]?.lowercased(), unit.hasPrefix("k") { v *= 2.20462 }
            guard v >= 10, v <= 200_000 else { return nil }
            return v.rounded()
        }
        return nil
    }

    /// A reference-number-looking token ("0527290", "TQL-88213", "PO#4500123").
    static func identifier(in raw: String, minDigits: Int = 3) -> String? {
        let s = trimPunctuation(raw.replacingOccurrences(of: "#", with: " "))
        for m in matches(#"\b([A-Z0-9][A-Z0-9-]{2,24}[A-Z0-9])\b"#, in: s, caseInsensitive: true) {
            guard let token = captures(m, in: s)[1] else { continue }
            let digits = token.filter(\.isNumber).count
            guard digits >= minDigits else { continue }
            // Not a date, phone, money or ZIP+4 fragment.
            if !dateTokens(in: token).isEmpty { continue }
            if token.range(of: #"^\d{3}-\d{3}-\d{4}$"#, options: .regularExpression) != nil { continue }
            return token.uppercased()
        }
        return nil
    }

    static func normalizedIdentifier(_ s: String) -> String {
        key(s).uppercased()
    }

    // MARK: Payment cards

    /// Replaces anything that looks like a full card number with its last
    /// four digits. Full card numbers are never stored.
    static func maskCardNumbers(_ s: String) -> String {
        var out = s
        // 13–19 digit runs with optional spaces/dashes.
        out = replacing(#"(?<!\d)(?:\d[ -]?){9,15}(\d{4})(?!\d)"#, in: out, with: "••••$1")
        return out
    }

    /// Last four digits only when the receipt prints a masked or full card.
    static func cardLastFour(in s: String) -> String? {
        let lower = s.lowercased()
        let cardContext = contains(#"\b(visa|mastercard|master card|mc|amex|american express|discover|debit|credit|card|acct|account|fleet|comdata|efs|wex|tchek|t-chek|fleetone|chip|contactless)\b"#, in: lower)
        if let g = groups(#"(?:[x*•#]{2,}[\s-]?){1,4}(\d{4})\b"#, in: s) { return g[1] ?? nil }
        if cardContext, let g = groups(#"(?<!\d)(?:\d[ -]?){12,18}(\d{4})(?!\d)"#, in: s) { return g[1] ?? nil }
        if cardContext, let g = groups(#"(?:ending(?: in)?|last ?4|acct\.?|account)\s*[:#]?\s*(\d{4})\b"#, in: s) { return g[1] ?? nil }
        return nil
    }

    // MARK: Label → value lookup

    /// Regex for a document label: case-insensitive, flexible spacing,
    /// optional "#", "No.", "Number" and separators after it.
    static func labelPattern(_ label: String) -> String {
        let parts = label.split(separator: " ").map { escape(String($0)).replacingOccurrences(of: #"\."#, with: #"\.?"#) }
        let body = parts.joined(separator: #"[\s._-]*"#)
        return #"(?<![A-Za-z0-9])"# + body + #"(?![A-Za-z])"#
    }

    /// Finds `label: value` pairs. The value is the rest of the line after
    /// the label (dot leaders removed, cut at the next known label). When the
    /// label ends the line, the next `lookahead` lines are tried.
    static func findLabeled(_ labels: [String],
                            in lines: [DocLine],
                            stopLabels: [String] = [],
                            lookahead: Int = 2,
                            requireLineStart: Bool = false,
                            caseSensitive: Bool = false,
                            midLineNeedsSeparator: Bool = true,
                            accept: (String) -> Bool = { !$0.isEmpty }) -> [LabelHit] {
        var hits: [LabelHit] = []
        let sep = #"\s*(?:#|no\.?|num(?:ber)?\.?|nbr\.?)?\s*[:=#.\-]*\s*"#
        for (i, line) in lines.enumerated() {
            for label in labels {
                let prefix = requireLineStart ? #"^\s*"# : ""
                let pattern = prefix + labelPattern(label) + sep
                guard let m = matches(pattern, in: line.text, caseInsensitive: !caseSensitive).first,
                      let r = Range(m.range, in: line.text) else { continue }
                // Mid-line labels need an explicit separator ("... Carrier: X"),
                // otherwise ordinary sentences ("carrier will be charged") match.
                if m.range.location > 0 && midLineNeedsSeparator {
                    let matched = String(line.text[r])
                    let before = line.text[line.text.startIndex..<r.lowerBound].last
                    let explicit = matched.contains(":") || matched.contains("#") || matched.contains("=")
                    if !explicit || (before.map { $0.isLetter || $0 == "-" } ?? false) { continue }
                }
                var rest = String(line.text[r.upperBound...])
                rest = cutAtNextLabel(stripLeaders(rest), stopLabels: stopLabels + labels.filter { $0 != label })
                rest = trimPunctuation(rest)
                if accept(rest) {
                    hits.append(LabelHit(label: label, value: rest, lineIndex: i, valueLineIndex: i,
                                         page: line.page, sameLine: true, rawLine: line.text))
                    break
                }
                // Label alone at the end of the line → look below.
                if rest.isEmpty {
                    var j = i + 1
                    while j < lines.count && j <= i + lookahead {
                        let candidate = trimPunctuation(cutAtNextLabel(stripLeaders(lines[j].text), stopLabels: stopLabels))
                        if looksLikeLabelOnly(lines[j].text) { break }
                        if accept(candidate) {
                            hits.append(LabelHit(label: label, value: candidate, lineIndex: i, valueLineIndex: j,
                                                 page: lines[j].page, sameLine: false, rawLine: line.text + " / " + lines[j].text))
                            break
                        }
                        j += 1
                    }
                    break
                }
            }
        }
        return hits
    }

    static func firstLabeled(_ labels: [String], in lines: [DocLine], stopLabels: [String] = [],
                             lookahead: Int = 2, requireLineStart: Bool = false,
                             midLineNeedsSeparator: Bool = true,
                             accept: (String) -> Bool = { !$0.isEmpty }) -> LabelHit? {
        findLabeled(labels, in: lines, stopLabels: stopLabels, lookahead: lookahead,
                    requireLineStart: requireLineStart, midLineNeedsSeparator: midLineNeedsSeparator,
                    accept: accept).first
    }

    /// A line like "Pickup Date:" or "Weight" with no value.
    static func looksLikeLabelOnly(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count <= 32 else { return false }
        if t.hasSuffix(":") && !t.contains(where: { $0.isNumber }) { return true }
        return false
    }

    static func cutAtNextLabel(_ value: String, stopLabels: [String]) -> String {
        guard !stopLabels.isEmpty, !value.isEmpty else { return value }
        var cut = value.endIndex
        for label in stopLabels {
            let pattern = #"\s"# + labelPattern(label) + #"\s*(?:#|no\.?|number)?\s*[:#]"#
            if let m = matches(pattern, in: value).first, let r = Range(m.range, in: value), r.lowerBound < cut {
                cut = r.lowerBound
            }
        }
        return String(value[..<cut])
    }

    // MARK: Text quality

    /// Rough 0…1 score of how "document-like" OCR text is.
    static func textQuality(_ lines: [String]) -> Double {
        let joined = lines.joined(separator: " ")
        guard !joined.isEmpty else { return 0 }
        let letters = joined.filter { $0.isLetter || $0.isNumber }.count
        let ratio = Double(letters) / Double(max(joined.count, 1))
        let words = joined.split(separator: " ")
        let realWords = words.filter { w in
            let l = w.filter(\.isLetter)
            return l.count >= 3 && l.count == w.count
        }.count
        let wordRatio = words.isEmpty ? 0 : Double(realWords) / Double(words.count)
        return min(1, 0.5 * ratio + 0.5 * wordRatio + (lines.count >= 8 ? 0.1 : 0))
    }
}
