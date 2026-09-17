import Foundation

// =============================================================================
// MARK: - Shared line-item + totals parsing (receipts and shop invoices)
// =============================================================================

nonisolated enum TotalsRole: String, Sendable {
    case subtotal, tax, discount, fee, tip, total, partsSubtotal, laborSubtotal, shopSupplies, environmental, payment, change, ignore
}

nonisolated struct AmountLine: Sendable, Equatable {
    var role: TotalsRole
    var label: String
    var amount: Double
    var line: DocLine
    var sameLine: Bool
}

nonisolated enum LineItemParser {

    /// Lines that carry numbers but never a charge.
    static let noisePattern = #"\b(auth(?:orization)?|approval|appr\s*code|approved|ref(?:erence)?\s*(?:#|no)|seq(?:uence)?|trace|terminal|term\s*id|merchant\s*(?:id|#)|mid\b|tid\b|batch|loyalty|rewards?\s*(?:#|no|number|card|id|member)|points|member\s*#|account\s*#|acct\s*#|you\s+saved|card\s*#|entry\s+method|aid\b|tvr\b|tsi\b|arqc|application|chip|contactless|swiped|signature|balance\s+remaining|available\s+balance|pin\s+verified)\b"#

    static func role(for rawText: String) -> TotalsRole? {
        let text = rawText.lowercased()
        if SmartText.contains(#"\bchange(?:\s+due)?\b|\bcash\s+back\b|\btendered\b|\bamount\s+tendered\b|\bcash\s+paid\b"#, in: text) { return .change }
        if SmartText.contains(#"\b(discount|savings|coupon|promo)\b"#, in: text), !SmartText.contains(#"\btotal\s+(?:savings|discount)"#, in: text) { return .discount }
        if SmartText.contains(noisePattern, in: text) { return .ignore }
        if SmartText.contains(#"\bparts?\s+(?:sub\s*-?\s*total|total)\b|\btotal\s+parts\b"#, in: text) { return .partsSubtotal }
        if SmartText.contains(#"\blabou?r\s+(?:sub\s*-?\s*total|total)\b|\btotal\s+labou?r\b"#, in: text) { return .laborSubtotal }
        if SmartText.contains(#"\bshop\s+suppl(?:y|ies)\b|\bmisc(?:ellaneous)?\s+suppl"#, in: text) { return .shopSupplies }
        if SmartText.contains(#"\benvironmental\b|\benv\.?\s+fee\b|\bhazardous\s+waste\b|\b(?:oil|waste|tire)\s+disposal\b|\bdisposal\s+fee\b|\bscrap\s+tire\s+fee\b|\bhaz\s*mat\s+fee\b"#, in: text) { return .environmental }
        if SmartText.contains(#"\bsub\s*-?\s*total\b"#, in: text) { return .subtotal }
        if SmartText.contains(#"\btotal\s+(?:tax|savings|discount|gallons?|qty|quantity|items?|points|volume)\b|\btax\s+total\b"#, in: text) {
            return SmartText.contains(#"tax"#, in: text) ? .tax : .ignore
        }
        if SmartText.contains(#"\b(?:sales\s+)?tax\b|\bhst\b|\bgst\b|\bpst\b|\bvat\b"#, in: text) && !SmartText.contains(#"tax\s*(?:id|exempt\s*#)|excise\s+tax\s+included|tax\s+incl"#, in: text) { return .tax }
        if SmartText.contains(#"\bdiscount\b|\bsavings\b|\bcoupon\b|\bpromo\b|\bprice\s+adj|\brebate\b|\bless\b"#, in: text) { return .discount }
        if SmartText.contains(#"\btip\b|\bgratuity\b"#, in: text) { return .tip }
        if SmartText.contains(#"\bgrand\s+total\b|\btotal\s+(?:due|sale|amount|purchase|charges?|invoice)\b|\bamount\s+(?:due|charged|paid)\b|\bbalance\s+due\b|\binvoice\s+total\b|\btotal\s+to\s+pay\b|\bnet\s+total\b|^\s*total\b|\btotal\s*[:$]|\btotal\s*$|\btoll\s+(?:amount|charge|paid)\b|\bfare\b"#, in: text) { return .total }
        if SmartText.contains(#"\b(visa|mastercard|master\s*card|amex|american\s+express|discover|debit|credit|comdata|efs|wex|t-?chek|fleet\s*one|fuelman|tcs|apple\s+pay|google\s+pay|cash|check|payment)\b"#, in: text) { return .payment }
        if SmartText.contains(#"\bservice\s+call\b|\bcall\s*-?\s*out\b|\bcore\s+charge\b|\bconvenience\s+fee\b|\bservice\s+(?:fee|charge)\b|\b(?:mileage|travel)\s+charge\b|\bfee\b"#, in: text) { return .fee }
        return nil
    }

    /// Every line that carries an amount plus its role (nil role = an item).
    static func amountLines(_ lines: [DocLine]) -> [(role: TotalsRole?, token: MoneyToken, line: DocLine, sameLine: Bool)] {
        var out: [(TotalsRole?, MoneyToken, DocLine, Bool)] = []
        for (i, l) in lines.enumerated() {
            let text = SmartText.stripLeaders(l.text)
            let tokens = SmartText.moneyTokens(in: text)
            let r = role(for: text)
            if let last = tokens.last {
                out.append((r, last, l, true))
            } else if let r, r != .ignore, r != .payment, i + 1 < lines.count,
                      SmartText.looksLikeLabelOnly(text) || text.count <= 24 {
                // "Total" on one line, "$62.20" on the next.
                let next = SmartText.stripLeaders(lines[i + 1].text)
                if role(for: next) == nil, let t = SmartText.moneyTokens(in: next).last,
                   next.filter(\.isLetter).count <= 3 {
                    out.append((r, t, l, false))
                }
            }
        }
        return out
    }

    // MARK: Item rows

    /// "Oil Filter  2  34.99  69.98", "2 @ 18.99  37.98", "PM Service 1.5 hr x $145.00 $217.50".
    static func parseItem(_ line: DocLine, id: Int, defaultKind: ExtractedLineItem.Kind) -> ExtractedLineItem? {
        let text = SmartText.stripLeaders(line.text)
        let money = SmartText.moneyTokens(in: text)
        guard let amountToken = money.last else { return nil }
        guard amountToken.value != 0 || money.count > 1 else { return nil }

        var item = ExtractedLineItem(id: id, kind: defaultKind, description: "", amount: amountToken.value,
                                     confidence: .medium, rawText: line.text, page: line.page)

        // Labor: hours × rate.
        if let g = SmartText.groups(#"(\d+(?:\.\d+)?)\s*(?:hr|hrs|hours?|h)\b\.?\s*(?:x|@|×|at|\*)\s*\$?\s*(\d+(?:\.\d{1,2})?)"#, in: text),
           let h = Double(g[1] ?? ""), let r = Double(g[2] ?? "") {
            item.kind = .labor
            item.hours = h
            item.rate = r
            let expected = (h * r * 100).rounded() / 100
            item.confidence = SmartText.approxEqual(expected, amountToken.value, tolerance: 0.05) ? .high : .low
            if let range = text.range(of: g[0] ?? "") {
                item.description = cleanDescription(String(text[..<range.lowerBound]))
            }
            if SmartText.contains(#"^\s*labou?r\b"#, in: item.description) || item.description.isEmpty {
                item.description = item.description.isEmpty ? "Labor" : item.description
            }
            return item
        }

        // "2 @ 18.99" / "4.250 GAL @ $2.799"
        if let g = SmartText.groups(#"(\d+(?:\.\d+)?)\s*(gal(?:lons?)?|ea|each|pcs?|qt|qts|x)?\s*@\s*\$?\s*(\d+(?:\.\d{1,3})?)"#, in: text),
           let q = Double(g[1] ?? ""), let p = Double(g[3] ?? "") {
            item.quantity = q
            item.unit = g[2].map { $0.lowercased().hasPrefix("gal") ? "gal" : $0.lowercased() }
            item.unitPrice = p
            let expected = (q * p * 100).rounded() / 100
            item.confidence = SmartText.approxEqual(expected, amountToken.value, tolerance: 0.05) ? .high : .low
            if let range = text.range(of: g[0] ?? "") {
                item.description = cleanDescription(String(text[..<range.lowerBound]))
            }
        } else {
            // Table row: [qty] [part #] description [qty] [unit price] amount.
            var cut = amountToken.start
            if money.count >= 2 {
                let priceToken = money[money.count - 2]
                item.unitPrice = abs(priceToken.value)
                cut = priceToken.start
            }
            var head = String(text.prefix(cut))
            // Leading quantity: "2  295/75R22.5 Drive Tire"
            if let lead = SmartText.groups(#"^\s*(\d{1,3}(?:\.\d{1,3})?)\s+(?=[A-Za-z0-9])"#, in: head),
               let q = Double(lead[1] ?? ""), q > 0,
               SmartText.groups(#"^\s*\d{1,3}(?:\.\d{1,3})?\s+[A-Z0-9]{1,8}[-/.]"#, in: head, caseInsensitive: false) == nil || head.contains("/") {
                item.quantity = q
                head = String(head.dropFirst((lead[0] ?? "").count))
            }
            var partNumber: String?
            if let g = SmartText.groups(#"^\s*([A-Z0-9]{1,8}[-/.][A-Z0-9-/.]{1,16}|[A-Z]{1,4}\d{3,}[A-Z0-9-]*|\d{5,}[A-Z]?)\s+(?=[A-Za-z])"#, in: head, caseInsensitive: false),
               let pn = g[1], !SmartText.contains(#"^\d{3}/\d{2}"#, in: pn) {
                partNumber = pn
                head = String(head.dropFirst((g[0] ?? "").count))
            }
            // Trailing numbers after the description: [qty] or [qty price].
            let nums = SmartText.numbers(in: head).filter { n in
                let end = head.index(head.startIndex, offsetBy: min(n.start + n.text.count, head.count))
                return head[end...].allSatisfy { !$0.isLetter }
            }
            if item.quantity == nil {
                if item.unitPrice == nil, nums.count >= 2 {
                    // "ULSD 142.310 4.019 571.94" — the price has 3 decimals, so it is not a money token.
                    let q = nums[nums.count - 2].value, p = nums[nums.count - 1].value
                    if SmartText.approxEqual((q * p * 100).rounded() / 100, amountToken.value, tolerance: 0.05) {
                        item.quantity = q; item.unitPrice = p
                        head = String(head.prefix(nums[nums.count - 2].start))
                    }
                } else if let last = nums.last {
                    item.quantity = last.value
                    head = String(head.prefix(last.start))
                }
            }
            item.partNumber = partNumber
            item.description = cleanDescription(head)
            if let q = item.quantity, let p = item.unitPrice {
                let expected = (q * p * 100).rounded() / 100
                if SmartText.approxEqual(expected, abs(amountToken.value), tolerance: 0.05) {
                    item.confidence = .high
                } else {
                    // Numbers disagree — probably a misread; keep for review.
                    item.confidence = .low
                }
            } else if item.unitPrice != nil, SmartText.approxEqual(item.unitPrice ?? 0, abs(amountToken.value)) {
                item.quantity = 1
            }
            if partNumber != nil, defaultKind != .labor { item.kind = .part }
        }

        guard item.description.filter(\.isLetter).count >= 2 else { return nil }
        if amountToken.value < 0 { item.kind = .discount }
        return item
    }

    static func cleanDescription(_ s: String) -> String {
        var t = SmartText.replacing(#"\$\s*$"#, in: s, with: "")
        t = SmartText.replacing(#"\s+(?:x|@|-|—)\s*$"#, in: t, with: "")
        return SmartText.trimPunctuation(t)
    }

    // MARK: Totals selection

    /// The best amount for a role. Later lines win ties (totals print last).
    static func pick(_ role: TotalsRole, from amounts: [(role: TotalsRole?, token: MoneyToken, line: DocLine, sameLine: Bool)],
                     preferLast: Bool = true) -> ExtractedValue<Double> {
        let matches = amounts.filter { $0.role == role }
        guard !matches.isEmpty else { return .missing }
        let chosen: (role: TotalsRole?, token: MoneyToken, line: DocLine, sameLine: Bool)
        if role == .total {
            // Strongest wording first, then the last one printed.
            chosen = matches.max { a, b in
                let sa = totalStrength(a.line.text), sb = totalStrength(b.line.text)
                return sa == sb ? a.line.index < b.line.index : sa < sb
            }!
        } else {
            chosen = preferLast ? matches.last! : matches.first!
        }
        let distinct = Set(matches.map { Int(($0.token.value * 100).rounded()) })
        var conf: ExtractionConfidence = chosen.sameLine ? .high : .medium
        if distinct.count > 1 && role == .total { conf = .medium }
        if !chosen.token.hasSymbol && !chosen.token.hasCents { conf = conf.downgraded }
        return ExtractedValue(abs(chosen.token.value), conf, raw: chosen.line.text, page: chosen.line.page)
    }

    static func sum(_ role: TotalsRole, from amounts: [(role: TotalsRole?, token: MoneyToken, line: DocLine, sameLine: Bool)]) -> ExtractedValue<Double> {
        let matches = amounts.filter { $0.role == role }
        guard let first = matches.first else { return .missing }
        // Repeated pages print the same fee twice; sum distinct readings only.
        var seen: [Int] = []
        var total = 0.0
        for m in matches {
            let cents = Int((abs(m.token.value) * 100).rounded())
            if seen.contains(cents) { continue }
            seen.append(cents)
            total += abs(m.token.value)
        }
        let conf: ExtractionConfidence = matches.count == 1 ? (first.sameLine ? .high : .medium) : .medium
        return ExtractedValue((total * 100).rounded() / 100, conf, raw: matches.map(\.line.text).joined(separator: " | "), page: first.line.page)
    }

    static func totalStrength(_ text: String) -> Int {
        let t = text.lowercased()
        if SmartText.contains(#"grand\s+total|invoice\s+total|total\s+due|amount\s+due|balance\s+due|total\s+sale|total\s+amount"#, in: t) { return 3 }
        if SmartText.contains(#"^\s*total\b"#, in: t) { return 2 }
        return 1
    }
}
