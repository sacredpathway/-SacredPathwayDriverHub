import Foundation

// =============================================================================
// MARK: - Receipt extraction (fuel + general business receipts)
// =============================================================================

nonisolated struct FuelDetails: Codable, Sendable, Equatable {
    var fuelType: ExtractedValue<String> = .missing
    var gallons: ExtractedValue<Double> = .missing
    var pricePerGallon: ExtractedValue<Double> = .missing
    var fuelAmount: ExtractedValue<Double> = .missing
    var defGallons: ExtractedValue<Double> = .missing
    var defPricePerGallon: ExtractedValue<Double> = .missing
    var defAmount: ExtractedValue<Double> = .missing
    var truckNumber: ExtractedValue<String> = .missing
    var odometer: ExtractedValue<Double> = .missing
    var driver: ExtractedValue<String> = .missing
    var pump: ExtractedValue<String> = .missing
}

nonisolated struct ReceiptExtraction: Codable, Sendable, Equatable {
    var isFuel: Bool = false
    var merchant: ExtractedValue<String> = .missing
    var storeNumber: ExtractedValue<String> = .missing
    var street: ExtractedValue<String> = .missing
    var city: ExtractedValue<String> = .missing
    var state: ExtractedValue<String> = .missing
    var zip: ExtractedValue<String> = .missing
    var phone: ExtractedValue<String> = .missing
    var date: ExtractedValue<SimpleDate> = .missing
    var time: ExtractedValue<String> = .missing
    var receiptNumber: ExtractedValue<String> = .missing
    var subtotal: ExtractedValue<Double> = .missing
    var tax: ExtractedValue<Double> = .missing
    var discount: ExtractedValue<Double> = .missing
    var fees: ExtractedValue<Double> = .missing
    var tip: ExtractedValue<Double> = .missing
    var total: ExtractedValue<Double> = .missing
    var paymentMethod: ExtractedValue<String> = .missing
    /// Only the last four digits are ever kept.
    var cardLastFour: ExtractedValue<String> = .missing
    var suggestedCategory: ExtractedValue<String> = .missing
    var lineItems: [ExtractedLineItem] = []
    var fuel: FuelDetails? = nil
    var issues: [ExtractionIssue] = []

    var location: String? {
        let place = [city.value, state.value].compactMap { $0 }.joined(separator: ", ")
        return place.isEmpty ? nil : place
    }

    /// A readable note for the expense description field.
    var descriptionText: String {
        var parts: [String] = []
        if let fuel {
            if let g = fuel.gallons.value {
                var s = (fuel.fuelType.value ?? "Fuel") + " " + SmartText.trimNumber(g) + " gal"
                if let p = fuel.pricePerGallon.value { s += " @ " + String(format: "$%.3f", p) }
                parts.append(s)
            }
            if let g = fuel.defGallons.value {
                parts.append("DEF " + SmartText.trimNumber(g) + " gal" + (fuel.defAmount.value.map { " (" + SmartText.money($0) + ")" } ?? ""))
            } else if let a = fuel.defAmount.value {
                parts.append("DEF " + SmartText.money(a))
            }
            if let t = fuel.truckNumber.value { parts.append("Unit " + t) }
            if let o = fuel.odometer.value { parts.append("Odo " + SmartText.trimNumber(o)) }
        } else {
            let items = lineItems.filter { $0.kind != .discount && $0.kind != .tax }.prefix(4).map(\.description)
            if !items.isEmpty { parts.append(items.joined(separator: ", ")) }
        }
        if let loc = location { parts.append(loc) }
        if let n = receiptNumber.value { parts.append("Receipt " + n) }
        if let pay = paymentMethod.value { parts.append(pay + (cardLastFour.value.map { " ••" + $0 } ?? "")) }
        return parts.joined(separator: " · ")
    }
}

nonisolated enum ReceiptExtractor {

    static let brands: [(pattern: String, name: String)] = [
        (#"love'?s"#, "Love's"), (#"flying\s*j"#, "Flying J"), (#"pilot"#, "Pilot"),
        (#"\bta\b(?:\s+(?:travel|express|petro))?|travel\s*centers?\s+of\s+america"#, "TA"),
        (#"\bpetro\b"#, "Petro"), (#"speedway"#, "Speedway"), (#"ambest|am\s*best"#, "AMBEST"),
        (#"sapp\s*bros"#, "Sapp Bros"), (#"kwik\s*trip"#, "Kwik Trip"), (#"casey'?s"#, "Casey's"),
        (#"road\s*ranger"#, "Road Ranger"), (#"bosselman"#, "Bosselman"), (#"quik\s*trip|\bqt\b"#, "QuikTrip"),
        (#"circle\s*k"#, "Circle K"), (#"sheetz"#, "Sheetz"), (#"wawa"#, "Wawa"), (#"buc-?ee'?s"#, "Buc-ee's"),
        (#"maverik"#, "Maverik"), (#"town\s*pump"#, "Town Pump"), (#"one9"#, "ONE9"), (#"stuckey'?s"#, "Stuckey's"),
        (#"walmart"#, "Walmart"), (#"home\s*depot"#, "The Home Depot"), (#"lowe'?s"#, "Lowe's"),
        (#"autozone"#, "AutoZone"), (#"o'?reilly"#, "O'Reilly Auto Parts"), (#"napa"#, "NAPA"),
        (#"advance\s+auto"#, "Advance Auto Parts"), (#"fleetpride"#, "FleetPride"), (#"truckpro"#, "TruckPro"),
        (#"cat\s+scale"#, "CAT Scale")
    ]

    static func extract(_ document: DocumentText, forceFuel: Bool? = nil) -> ReceiptExtraction {
        let lines = document.lines
        let text = document.joined
        var out = ReceiptExtraction()
        let fuelSignals = SmartText.contains(#"\bdiesel\b|\bdeisel\b|\bulsd\b|\bdsl\b|#2\b|\bunleaded\b|\breefer\b|\bgal(?:lons?|s)?\b|\bppg\b|/\s*gal\b"#, in: text)
        out.isFuel = forceFuel ?? fuelSignals

        extractHeader(&out, lines: lines)
        extractDateTime(&out, lines: lines)
        extractNumbers(&out, lines: lines)
        extractMoney(&out, lines: lines)
        extractPayment(&out, lines: lines)
        if out.isFuel { out.fuel = extractFuel(lines: lines, out: &out) }
        suggestCategory(&out, text: text)
        validate(&out)
        return out
    }

    // MARK: Header

    private static func extractHeader(_ out: inout ReceiptExtraction, lines: [DocLine]) {
        let top = Array(lines.prefix(10))
        let header = Array(lines.prefix(5))
        let joinedTop = header.map(\.text).joined(separator: "\n")
        if let brand = brands.first(where: { SmartText.contains(#"\b(?:"# + $0.pattern + #")\b"#, in: joinedTop) }) {
            let line = header.first { SmartText.contains(#"\b(?:"# + brand.pattern + #")\b"#, in: $0.text) }
            out.merchant = ExtractedValue(brand.name, .high, raw: line?.text, page: line?.page)
        } else if let l = top.first(where: { isMerchantLine($0.text) }) {
            out.merchant = ExtractedValue(SmartText.trimPunctuation(l.text), .medium, raw: l.text, page: l.page)
        }
        if let l = top.first(where: { SmartText.contains(#"(?:store|site|location|loc|unit)\s*(?:#|no\.?)?\s*\d{1,6}\b|#\s?\d{2,5}\b"#, in: $0.text) }),
           let g = SmartText.groups(#"(?:store|site|location|loc)\s*(?:#|no\.?)?\s*(\d{1,6})\b|#\s?(\d{2,5})\b"#, in: l.text),
           let n = g[1] ?? g[2] {
            out.storeNumber = ExtractedValue(n, .high, raw: l.text, page: l.page)
        }
        for l in top {
            if !out.street.isFound, SmartText.isStreetAddress(l.text) {
                let street = l.text.components(separatedBy: ",").first ?? l.text
                out.street = ExtractedValue(SmartText.trimPunctuation(street), .high, raw: l.text, page: l.page)
            }
            if !out.city.isFound, let c = SmartText.cityStateZip(in: l.text) {
                let conf: ExtractionConfidence = c.zip != nil ? .high : .medium
                out.city = ExtractedValue(c.city, conf, raw: l.text, page: l.page)
                out.state = ExtractedValue(c.state, conf, raw: l.text, page: l.page)
                if let z = c.zip { out.zip = ExtractedValue(z, .high, raw: l.text, page: l.page) }
            }
            if !out.phone.isFound, let p = SmartText.phone(in: l.text) {
                out.phone = ExtractedValue(p.number, .medium, raw: l.text, page: l.page)
            }
        }
    }

    static func isMerchantLine(_ s: String) -> Bool {
        let t = SmartText.trimPunctuation(s)
        guard t.filter(\.isLetter).count >= 3, t.count <= 48 else { return false }
        if SmartText.contains(#"^(welcome|thank|receipt|customer|copy|merchant|sale|transaction|invoice|date|time|store\s*#|tel|phone|www|http)"#, in: t) { return false }
        if SmartText.isStreetAddress(t) || SmartText.cityStateZip(in: t) != nil || SmartText.phone(in: t) != nil { return false }
        if !SmartText.dateTokens(in: t).isEmpty || !SmartText.moneyTokens(in: t).isEmpty { return false }
        return true
    }

    // MARK: Date / time

    private static func extractDateTime(_ out: inout ReceiptExtraction, lines: [DocLine]) {
        let usable = lines.filter { !SmartText.contains(#"\b(exp(?:ires?|iration)?|valid\s+(?:thru|through)|expiry|due|member\s+since|birth)\b"#, in: $0.text) }
        let labeled = SmartText.firstLabeled(["transaction date", "purchase date", "sale date", "receipt date", "date"],
                                             in: usable, lookahead: 1, accept: { SmartText.firstDate(in: $0) != nil })
        if let hit = labeled, let t = SmartText.firstDate(in: hit.value) {
            out.date = ExtractedValue(t.date, t.ambiguous ? .low : .high, raw: hit.rawLine, page: hit.page)
        } else {
            let dated = usable.compactMap { l in SmartText.firstDate(in: l.text).map { (l, $0) } }
            if let (l, t) = dated.first {
                // Several different dates and no label → review.
                let distinct = Set(dated.map { $0.1.date })
                let conf: ExtractionConfidence = t.ambiguous ? .low : (distinct.count > 1 ? .low : .medium)
                out.date = ExtractedValue(t.date, conf, raw: l.text, page: l.page)
                if distinct.count > 1 {
                    out.issues.append(.warning("date", "The receipt shows several dates; check the purchase date."))
                }
            }
        }
        // Time on the date line, or a labeled time.
        let timeSource = [out.date.rawText].compactMap { $0 } + lines.filter { SmartText.contains(#"^\s*time\b"#, in: $0.text) }.map(\.text)
        for s in timeSource {
            var t = s
            if let d = SmartText.firstDate(in: t), let r = t.range(of: d.text) { t.removeSubrange(r) }
            if let g = SmartText.groups(#"\b([01]?\d|2[0-3]):([0-5]\d)(?::[0-5]\d)?\s*([ap]\.?m\.?)?"#, in: t) {
                var hour = Int(g[1] ?? "") ?? 0
                let minute = Int(g[2] ?? "") ?? 0
                if let ap = g[3]?.lowercased().replacingOccurrences(of: ".", with: "") {
                    if ap == "pm", hour < 12 { hour += 12 }
                    if ap == "am", hour == 12 { hour = 0 }
                }
                out.time = ExtractedValue(String(format: "%02d:%02d", hour, minute), .high, raw: s)
                break
            }
        }
    }

    // MARK: Receipt / invoice numbers

    static func identifierAfterLabel(_ v: String) -> String? {
        let s = SmartText.trimPunctuation(v)
        guard let first = s.split(separator: " ").first.map(String.init) else { return nil }
        if SmartText.contains(#"^[x*•]+"#, in: first) { return nil }
        guard let id = SmartText.identifier(in: first, minDigits: 2), id.count >= 3, id.count <= 24 else { return nil }
        return id
    }

    private static func extractNumbers(_ out: inout ReceiptExtraction, lines: [DocLine]) {
        let clean = lines.filter { !SmartText.contains(#"\b(auth|approval|appr|loyalty|rewards?|member|points|card|acct|account)\b"#, in: $0.text) }
        if let hit = SmartText.firstLabeled(["receipt number", "receipt #", "receipt no", "invoice number", "invoice #",
                                             "invoice no", "transaction number", "transaction #", "transaction id",
                                             "trans #", "tran #", "trx #", "ticket #", "ticket number", "sale #",
                                             "order #", "receipt", "invoice", "ticket", "trans", "tran"],
                                            in: clean, lookahead: 1, accept: { identifierAfterLabel($0) != nil }),
           let id = identifierAfterLabel(hit.value) {
            out.receiptNumber = ExtractedValue(id, hit.sameLine ? .high : .medium, raw: hit.rawLine, page: hit.page)
        }
    }

    // MARK: Money

    private static func extractMoney(_ out: inout ReceiptExtraction, lines: [DocLine]) {
        let amounts = LineItemParser.amountLines(lines)
        out.subtotal = LineItemParser.pick(.subtotal, from: amounts)
        out.tax = LineItemParser.sum(.tax, from: amounts)
        out.discount = LineItemParser.sum(.discount, from: amounts)
        out.fees = LineItemParser.sum(.fee, from: amounts)
        out.tip = LineItemParser.pick(.tip, from: amounts)
        out.total = LineItemParser.pick(.total, from: amounts)

        // Line items: amount lines with no totals role (and discounts), before the first total.
        let firstTotalIndex = amounts.first(where: { $0.role == .total || $0.role == .subtotal })?.line.index ?? Int.max
        var ordered: [(Int, ExtractedLineItem)] = []
        for a in amounts where (a.role == nil || a.role == .discount) && a.line.index < firstTotalIndex {
            guard var item = LineItemParser.parseItem(a.line, id: 0, defaultKind: a.role == .discount ? .discount : .item) else { continue }
            if a.role == .discount {
                item.kind = .discount
                item.amount = -(abs(item.amount ?? 0))
            } else if SmartText.contains(#"\bdef\b|diesel\s+exhaust"#, in: a.line.text) {
                item.kind = .def
            } else if SmartText.contains(#"\bdiesel\b|\bdeisel\b|\bulsd\b|\bdsl\b|\bunleaded\b|\breefer\b|\bfuel\b"#, in: a.line.text) {
                item.kind = .fuel
            }
            ordered.append((a.line.index, item))
        }
        out.lineItems = ordered.sorted { $0.0 < $1.0 }.enumerated().map { i, pair in
            var item = pair.1
            item.id = i + 1
            return item
        }

        // No labeled total: the charged amount on the card line is the next best.
        if !out.total.isFound {
            if let pay = amounts.last(where: { $0.role == .payment }) {
                out.total = ExtractedValue(abs(pay.token.value), .medium, raw: pay.line.text, page: pay.line.page)
            } else if let only = amounts.filter({ $0.role == nil }).map(\.token.value).max(),
                      amounts.filter({ $0.role == nil }).count == 1 {
                out.total = ExtractedValue(only, .low, raw: nil)
            } else if !amounts.isEmpty {
                out.issues.append(.warning("total", "Several amounts and no labeled total; enter the total."))
            }
        }
    }

    // MARK: Payment

    private static func extractPayment(_ out: inout ReceiptExtraction, lines: [DocLine]) {
        let methods: [(String, String)] = [
            (#"\bvisa\b"#, "Visa"), (#"master\s*card|\bmc\b"#, "Mastercard"), (#"\bamex\b|american\s+express"#, "Amex"),
            (#"\bdiscover\b"#, "Discover"), (#"\bcomdata\b"#, "Comdata"), (#"\befs\b"#, "EFS"), (#"\bwex\b"#, "WEX"),
            (#"t-?chek"#, "T-Chek"), (#"fleet\s*one"#, "Fleet One"), (#"\bfuelman\b"#, "Fuelman"), (#"\btcs\b"#, "TCS"),
            (#"apple\s+pay"#, "Apple Pay"), (#"google\s+pay"#, "Google Pay"), (#"\bdebit\b"#, "Debit"),
            (#"\bcredit\b"#, "Credit"), (#"\bcash\b"#, "Cash"), (#"\bcheck\b|\bcheque\b"#, "Check")
        ]
        for l in lines.reversed() {
            if let m = methods.first(where: { SmartText.contains($0.0, in: l.text) }) {
                if m.1 == "Cash", SmartText.contains(#"cash\s+back|cashier"#, in: l.text) { continue }
                out.paymentMethod = ExtractedValue(m.1, .high, raw: l.text, page: l.page)
                if let last4 = SmartText.cardLastFour(in: l.text) {
                    out.cardLastFour = ExtractedValue(last4, .high, raw: l.text, page: l.page)
                }
                break
            }
        }
        if !out.cardLastFour.isFound {
            for l in lines {
                if let last4 = SmartText.cardLastFour(in: l.text) {
                    out.cardLastFour = ExtractedValue(last4, .medium, raw: l.text, page: l.page)
                    break
                }
            }
        }
    }

    // MARK: Fuel

    private static func extractFuel(lines: [DocLine], out: inout ReceiptExtraction) -> FuelDetails {
        var f = FuelDetails()
        let text = lines.map(\.text).joined(separator: "\n")
        if let g = SmartText.groups(#"\b(#?\s?2\s+diesel|ulsd|ultra\s+low\s+sulfur\s+diesel|bio-?diesel|b\d{1,2}|dyed\s+diesel|reefer(?:\s+fuel)?|diesel|deisel|dsl|unleaded\s+plus|unleaded|regular|premium|mid-?grade)\b"#, in: text) {
            let raw = (g[1] ?? "").lowercased()
            let name: String
            switch true {
            case raw.contains("reefer"): name = "Reefer diesel"
            case raw.contains("dyed"): name = "Dyed diesel"
            case raw.hasPrefix("b") && raw.count <= 3, raw.contains("bio"): name = "Biodiesel"
            case raw.contains("unleaded"), raw == "regular", raw == "premium", raw.contains("mid"): name = raw.capitalized
            default: name = "Diesel"
            }
            f.fuelType = ExtractedValue(name, raw == "deisel" ? .medium : .high, raw: g[0])
        }

        // Row readers: "DIESEL 125.482 GAL @ $3.899/GAL $489.25" and table rows.
        var tableMode = false
        for (i, l) in lines.enumerated() {
            let t = l.text
            if SmartText.contains(#"\b(product|description|item)\b.*\b(qty|gal|gallons|quantity)\b.*\b(price|ppu|ppg|unit)\b"#, in: t) {
                tableMode = true
                continue
            }
            let isDEF = SmartText.contains(#"\bdef\b|diesel\s+exhaust"#, in: t)
            let isFuelLine = !isDEF && SmartText.contains(#"\bdiesel\b|\bdeisel\b|\bulsd\b|\bdsl\b|\bunleaded\b|\breefer\b|\bregular\b|\bpremium\b|#\s?2\b|\bfuel\b|\bb\d{1,2}\b"#, in: t)
                && !SmartText.contains(#"fuel\s+(?:tax|surcharge|card|rewards?|points)|total\s+fuel"#, in: t)
            guard isDEF || isFuelLine else { continue }
            var reading = readFuelRow(t, tableMode: tableMode)
            // Messy layout: "DEISEL" then "GAL 98.7" and "$ / GAL 3.759" on following lines.
            if reading.gallons == nil && reading.ppg == nil {
                let window = lines[(i + 1)..<min(lines.count, i + 4)]
                for w in window {
                    if reading.gallons == nil, let g = SmartText.groups(#"^\s*(?:gal(?:lons?|s)?|qty|volume)\s*[:.]?\s*(\d{1,4}(?:\.\d{1,3})?)\b"#, in: w.text) {
                        reading.gallons = Double(g[1] ?? ""); reading.sameLine = false
                    }
                    if reading.ppg == nil, let g = SmartText.groups(#"(?:\$\s*/\s*gal|price\s*/\s*gal|ppg|price\s+per\s+gal(?:lon)?|unit\s+price)\s*[:.]?\s*\$?\s*(\d{1,2}\.\d{2,3})\b"#, in: w.text) {
                        reading.ppg = Double(g[1] ?? ""); reading.sameLine = false
                    }
                }
            }
            let conf: ExtractionConfidence = reading.sameLine ? .high : .medium
            if isDEF {
                if !f.defGallons.isFound, let g = reading.gallons { f.defGallons = ExtractedValue(g, conf, raw: t, page: l.page) }
                if !f.defPricePerGallon.isFound, let p = reading.ppg { f.defPricePerGallon = ExtractedValue(p, conf, raw: t, page: l.page) }
                if !f.defAmount.isFound, let a = reading.amount { f.defAmount = ExtractedValue(a, conf, raw: t, page: l.page) }
            } else {
                if !f.gallons.isFound, let g = reading.gallons { f.gallons = ExtractedValue(g, conf, raw: t, page: l.page) }
                if !f.pricePerGallon.isFound, let p = reading.ppg { f.pricePerGallon = ExtractedValue(p, conf, raw: t, page: l.page) }
                if !f.fuelAmount.isFound, let a = reading.amount { f.fuelAmount = ExtractedValue(a, conf, raw: t, page: l.page) }
            }
        }
        // Stand-alone labeled gallons / price.
        if !f.gallons.isFound, let hit = SmartText.firstLabeled(["gallons", "gals", "gal", "volume"], in: lines, lookahead: 0,
                                                                  accept: { SmartText.groups(#"^(\d{1,4}\.\d{1,3})\b"#, in: $0) != nil }),
           let g = SmartText.groups(#"^(\d{1,4}\.\d{1,3})\b"#, in: hit.value), let v = Double(g[1] ?? "") {
            f.gallons = ExtractedValue(v, .medium, raw: hit.rawLine, page: hit.page)
        }
        if !f.pricePerGallon.isFound, let hit = SmartText.firstLabeled(["price per gallon", "price/gal", "ppg", "$/gal", "unit price"],
                                                                         in: lines, lookahead: 0,
                                                                         accept: { SmartText.groups(#"^\$?\s?(\d{1,2}\.\d{2,3})\b"#, in: $0) != nil }),
           let g = SmartText.groups(#"^\$?\s?(\d{1,2}\.\d{2,3})\b"#, in: hit.value), let v = Double(g[1] ?? "") {
            f.pricePerGallon = ExtractedValue(v, .medium, raw: hit.rawLine, page: hit.page)
        }

        // Unit / odometer / driver / pump.
        let unitAccept: (String) -> Bool = { v in
            guard let first = v.split(separator: " ").first else { return false }
            let s = SmartText.trimPunctuation(String(first))
            return (1...10).contains(s.count) && s.contains(where: \.isNumber)
        }
        if let hit = SmartText.firstLabeled(["truck #", "truck number", "truck", "tractor #", "tractor", "unit #", "unit number", "unit", "vehicle #", "vehicle"],
                                            in: lines.filter { !SmartText.contains(#"unit\s+price|per\s+unit"#, in: $0.text) },
                                            stopLabels: ["odometer", "odo", "driver", "trip", "hub", "pump", "trailer"], lookahead: 0, accept: unitAccept) {
            f.truckNumber = ExtractedValue(SmartText.trimPunctuation(String(hit.value.split(separator: " ")[0])).uppercased(), .high, raw: hit.rawLine, page: hit.page)
        }
        if let hit = SmartText.firstLabeled(["odometer", "odo", "hubometer", "hub", "mileage", "miles"], in: lines, lookahead: 0,
                                            accept: { v in (SmartText.numbers(in: v).first.map { $0.start == 0 && $0.value >= 100 && $0.value < 5_000_000 }) ?? false }),
           let n = SmartText.numbers(in: hit.value).first {
            f.odometer = ExtractedValue(n.value, .high, raw: hit.rawLine, page: hit.page)
        }
        if let hit = SmartText.firstLabeled(["driver id", "driver #", "driver name", "driver"], in: lines,
                                            stopLabels: ["odometer", "odo", "unit", "truck", "trip", "hub", "vehicle", "pump", "trailer"], lookahead: 0,
                                            accept: { v in let s = SmartText.trimPunctuation(v); return !s.isEmpty && s.count <= 30 }) {
            f.driver = ExtractedValue(SmartText.trimPunctuation(String(hit.value.split(separator: " ").prefix(3).joined(separator: " "))), .medium, raw: hit.rawLine, page: hit.page)
        }
        if let g = SmartText.groups(#"\bpump\s*(?:#|no\.?)?\s*(\d{1,3})\b"#, in: text) {
            f.pump = ExtractedValue(g[1] ?? "", .high, raw: g[0])
        }
        if !f.gallons.isFound {
            out.issues.append(.warning("gallons", "Fuel gallons were not found."))
        }
        return f
    }

    struct FuelRow { var gallons: Double?; var ppg: Double?; var amount: Double?; var sameLine = true }

    static func readFuelRow(_ raw: String, tableMode: Bool) -> FuelRow {
        var row = FuelRow()
        let t = SmartText.stripLeaders(raw)
        if let g = SmartText.groups(#"(\d{1,4}(?:\.\d{1,3})?)\s*(?:gal(?:lons?|s)?|g)\b"#, in: t) { row.gallons = Double(g[1] ?? "") }
        if let g = SmartText.groups(#"@\s*\$?\s*(\d{1,2}\.\d{2,3})|\$?\s*(\d{1,2}\.\d{2,3})\s*/\s*gal|(?:ppg|price\s*/\s*gal|ppu)\s*[:.]?\s*\$?\s*(\d{1,2}\.\d{2,3})"#, in: t) {
            row.ppg = Double(g[1] ?? g[2] ?? g[3] ?? "")
        }
        // Amount: the last "$"-style amount that is not the price per gallon.
        let money = SmartText.moneyTokens(in: t).filter { tok in row.ppg.map { !SmartText.approxEqual($0, tok.value, tolerance: 0.0001) } ?? true }
        row.amount = money.last.map { abs($0.value) }
        if tableMode, row.gallons == nil {
            // "ULSD  142.310  4.019  571.94"
            let nums = SmartText.numbers(in: t)
            if nums.count >= 3 {
                let q = nums[nums.count - 3].value, p = nums[nums.count - 2].value, a = nums[nums.count - 1].value
                if SmartText.approxEqual((q * p * 100).rounded() / 100, a, tolerance: 0.05) {
                    row.gallons = q; row.ppg = p; row.amount = a
                }
            }
        }
        if row.amount == nil, let g = row.gallons, let p = row.ppg {
            // Only when the line prints a matching plain amount.
            let expected = (g * p * 100).rounded() / 100
            if SmartText.numbers(in: t).contains(where: { SmartText.approxEqual($0.value, expected, tolerance: 0.02) }) {
                row.amount = expected
            }
        }
        return row
    }

    // MARK: Category

    static func suggestCategory(_ out: inout ReceiptExtraction, text: String) {
        let lower = text.lowercased()
        if out.isFuel {
            out.suggestedCategory = ExtractedValue("fuel", out.fuel?.gallons.isFound == true ? .high : .medium)
        } else if SmartText.contains(#"\btoll\b|turnpike|e-?z\s*pass|platepay|pikepass|toll\s*tag|tollway|bridge\s+authority|expressway\s+authority"#, in: lower) {
            out.suggestedCategory = ExtractedValue("toll", .high)
        } else if SmartText.contains(#"\blumper\b|unloading\s+(?:fee|service)|capstone\s+logistics|\bnfi\b|\bdeliver-?ease\b"#, in: lower) {
            out.suggestedCategory = ExtractedValue("lumper", .high)
        } else if SmartText.contains(#"\binsurance\b|\bpremium\s+payment\b|\bpolicy\s*(?:#|number)"#, in: lower) {
            out.suggestedCategory = ExtractedValue("insurance", .medium)
        } else if SmartText.contains(#"\brepair\b|\btow(?:ing)?\b|\bmechanic\b|\broad\s*service\b"#, in: lower) {
            out.suggestedCategory = ExtractedValue("repair", .medium)
        } else if SmartText.contains(#"oil\s+change|\bfilter\b|\bwiper\b|\bbrake\b|\btire\b|\bbattery\b|\bcoolant\b|\bantifreeze\b|\bgrease\b|\bmotor\s+oil\b|\b15w-?40\b"#, in: lower) {
            out.suggestedCategory = ExtractedValue("maintenance", .medium)
        } else {
            out.suggestedCategory = ExtractedValue("other", .low)
        }
    }

    // MARK: Validation

    private static func validate(_ out: inout ReceiptExtraction) {
        // subtotal + tax + fees + tip − discount ≈ total
        if let total = out.total.value {
            if let sub = out.subtotal.value {
                let expected = sub + (out.tax.value ?? 0) + (out.fees.value ?? 0) + (out.tip.value ?? 0)
                let expectedLessDiscount = expected - (out.discount.value ?? 0)
                if SmartText.approxEqual(expected, total) || SmartText.approxEqual(expectedLessDiscount, total) {
                    if out.total.confidence == .medium { out.total.confidence = .high }
                } else {
                    out.issues.append(.warning("total", "Subtotal \(SmartText.money(sub)) + tax/fees does not match the total \(SmartText.money(total))."))
                    out.total = out.total.downgraded()
                    out.subtotal = out.subtotal.downgraded()
                }
                if let tax = out.tax.value, tax > sub {
                    out.issues.append(.warning("tax", "Tax is larger than the subtotal; one of them is misread."))
                    out.tax = out.tax.downgraded()
                }
            }
            // Line items should add up to the subtotal (or total) when every row is reliable.
            let items = out.lineItems.compactMap(\.amount)
            if !items.isEmpty {
                let s = items.reduce(0, +)
                let target = out.subtotal.value ?? total
                if !SmartText.approxEqual(s, target, tolerance: 0.05) {
                    for i in out.lineItems.indices where out.lineItems[i].confidence == .high {
                        out.lineItems[i].confidence = .medium
                    }
                    if out.lineItems.count > 1 {
                        out.issues.append(.info("lineItems", "Line items add up to \(SmartText.money(s)); some rows may be missing or misread."))
                    }
                }
            }
            if total <= 0 || total > 25_000 {
                out.issues.append(.warning("total", "The total \(SmartText.money(total)) looks unusual."))
                out.total = out.total.downgraded()
            }
        } else {
            out.issues.append(.warning("total", "No total was found. Enter the amount paid."))
        }

        // gallons × price ≈ fuel amount
        if var f = out.fuel {
            if let g = f.gallons.value, let p = f.pricePerGallon.value {
                let expected = (g * p * 100).rounded() / 100
                if let a = f.fuelAmount.value {
                    if !SmartText.approxEqual(expected, a, tolerance: max(0.05, a * 0.002)) {
                        out.issues.append(.warning("gallons", "Gallons × price (\(SmartText.money(expected))) does not match the fuel amount \(SmartText.money(a))."))
                        f.gallons = f.gallons.downgraded()
                        f.pricePerGallon = f.pricePerGallon.downgraded()
                    }
                } else if let total = out.total.value, !SmartText.approxEqual(expected, total, tolerance: max(0.05, total * 0.002)) {
                    let withDEF = expected + (f.defAmount.value ?? 0)
                    if !SmartText.approxEqual(withDEF, total, tolerance: max(0.05, total * 0.002)) && f.defAmount.value == nil {
                        out.issues.append(.info("gallons", "Gallons × price is \(SmartText.money(expected)); the total is \(SmartText.money(total)) (other items or tax may be included)."))
                    }
                }
                if p < 1 || p > 9 {
                    out.issues.append(.warning("pricePerGallon", "Price per gallon \(p) looks unusual."))
                    f.pricePerGallon = f.pricePerGallon.downgraded()
                }
            }
            if let g = f.gallons.value, g > 400 {
                out.issues.append(.warning("gallons", "\(SmartText.trimNumber(g)) gallons is more than a truck holds; check it."))
                f.gallons = f.gallons.downgraded()
            }
            if let dg = f.defGallons.value, let dp = f.defPricePerGallon.value, let da = f.defAmount.value,
               !SmartText.approxEqual((dg * dp * 100).rounded() / 100, da, tolerance: 0.05) {
                out.issues.append(.warning("defGallons", "DEF gallons × price does not match the DEF amount."))
                f.defGallons = f.defGallons.downgraded()
            }
            // Gallons must never be taken from a dollar amount.
            if let g = f.gallons.value, let total = out.total.value, SmartText.approxEqual(g, total) {
                out.issues.append(.warning("gallons", "Gallons equal the total; one of them is misread."))
                f.gallons = f.gallons.downgraded()
            }
            out.fuel = f
        }
    }

    // MARK: Review rows

    static func reviewFields(_ r: ReceiptExtraction) -> [ReviewField] {
        var rows: [ReviewField] = []
        func add(_ key: String, _ label: String, _ v: ExtractedValue<String>) {
            rows.append(ReviewField(key: key, label: label, value: v.value ?? "", confidence: v.confidence, rawText: v.rawText))
        }
        func money(_ key: String, _ label: String, _ v: ExtractedValue<Double>, always: Bool = false) {
            guard always || v.isFound else { return }
            rows.append(ReviewField(key: key, label: label, value: v.value.map(SmartText.money) ?? "", confidence: v.confidence, rawText: v.rawText))
        }
        func number(_ key: String, _ label: String, _ v: ExtractedValue<Double>, suffix: String = "") {
            rows.append(ReviewField(key: key, label: label, value: v.value.map { SmartText.trimNumber($0) + suffix } ?? "", confidence: v.confidence, rawText: v.rawText))
        }
        add("vendorName", "Merchant", r.merchant)
        if let loc = r.location {
            rows.append(ReviewField(key: "location", label: "Location", value: [r.street.value, loc].compactMap { $0 }.joined(separator: ", "),
                                    confidence: r.city.confidence, rawText: r.city.rawText))
        }
        rows.append(ReviewField(key: "receiptDate", label: "Date", value: [r.date.value?.usDisplay, r.time.value].compactMap { $0 }.joined(separator: " "),
                                confidence: r.date.confidence, rawText: r.date.rawText))
        add("receiptNumber", "Receipt #", r.receiptNumber)
        if let f = r.fuel {
            add("fuelType", "Fuel type", f.fuelType)
            number("gallons", "Gallons", f.gallons)
            rows.append(ReviewField(key: "pricePerGallon", label: "Price / gal", value: f.pricePerGallon.value.map { String(format: "$%.3f", $0) } ?? "",
                                    confidence: f.pricePerGallon.confidence, rawText: f.pricePerGallon.rawText))
            money("fuelAmount", "Fuel amount", f.fuelAmount)
            if f.defGallons.isFound || f.defAmount.isFound {
                number("defGallons", "DEF gallons", f.defGallons)
                money("defAmount", "DEF amount", f.defAmount, always: true)
            }
            if f.truckNumber.isFound { add("truckNumber", "Truck / unit", f.truckNumber) }
            if f.odometer.isFound { number("odometer", "Odometer", f.odometer) }
            if f.driver.isFound { add("driver", "Driver", f.driver) }
        }
        money("subtotal", "Subtotal", r.subtotal)
        money("tax", "Tax", r.tax)
        money("discount", "Discounts", r.discount)
        money("fees", "Fees", r.fees)
        money("tip", "Tip", r.tip)
        money("amount", "Total", r.total, always: true)
        if r.paymentMethod.isFound {
            rows.append(ReviewField(key: "payment", label: "Paid with",
                                    value: (r.paymentMethod.value ?? "") + (r.cardLastFour.value.map { " ••" + $0 } ?? ""),
                                    confidence: r.paymentMethod.confidence, rawText: nil))
        }
        add("category", "Category", r.suggestedCategory)
        return rows
    }
}
