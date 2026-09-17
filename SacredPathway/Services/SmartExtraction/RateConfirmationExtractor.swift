import Foundation

// =============================================================================
// MARK: - Rate confirmation extraction
// =============================================================================

nonisolated struct ExtractedStop: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable { case pickup, delivery, stop }

    /// 1-based order on the document.
    var id: Int
    var kind: Kind
    var facility: ExtractedValue<String> = .missing
    var address: ExtractedValue<String> = .missing
    var city: ExtractedValue<String> = .missing
    var state: ExtractedValue<String> = .missing
    var zip: ExtractedValue<String> = .missing
    var date: ExtractedValue<SimpleDate> = .missing
    var appointment: ExtractedValue<String> = .missing
    var reference: ExtractedValue<String> = .missing
    var page: Int?

    var cityState: String? {
        guard let c = city.value, let s = state.value else { return nil }
        return "\(c), \(s)"
    }

    var label: String {
        switch kind {
        case .pickup: return "Pickup"
        case .delivery: return "Delivery"
        case .stop: return "Stop"
        }
    }

    var fullAddress: String? {
        var parts: [String] = []
        if let a = address.value { parts.append(a) }
        if let cs = cityState { parts.append(cs + (zip.value.map { " " + $0 } ?? "")) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    var confidence: ExtractionConfidence {
        let core = [city.confidence, state.confidence, date.confidence]
        return core.min() ?? .missing
    }

    var isEmpty: Bool {
        !facility.isFound && !address.isFound && !city.isFound && !date.isFound
    }
}

nonisolated struct ExtractedCharge: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case linehaul, fuelSurcharge, detention, layover, tonu, lumper, stopOff, accessorial, other, total
        var title: String {
            switch self {
            case .linehaul: return "Linehaul"
            case .fuelSurcharge: return "Fuel surcharge"
            case .detention: return "Detention"
            case .layover: return "Layover"
            case .tonu: return "TONU"
            case .lumper: return "Lumper"
            case .stopOff: return "Stop-off"
            case .accessorial: return "Accessorial"
            case .other: return "Other charge"
            case .total: return "Total"
            }
        }
    }
    var id: Int
    var kind: Kind
    var label: String
    var amount: Double
    /// "Detention $50/hr after 2 hrs" is a term, not money owed yet.
    var conditional: Bool
    var confidence: ExtractionConfidence
    var rawText: String?
    var page: Int?
}

nonisolated struct RateConfirmationExtraction: Codable, Sendable, Equatable {
    var brokerName: ExtractedValue<String> = .missing
    var brokerContact: ExtractedValue<String> = .missing
    var brokerPhone: ExtractedValue<String> = .missing
    var brokerPhoneExtension: ExtractedValue<String> = .missing
    var brokerEmail: ExtractedValue<String> = .missing
    var brokerMC: ExtractedValue<String> = .missing

    var loadNumber: ExtractedValue<String> = .missing
    var confirmationNumber: ExtractedValue<String> = .missing
    var referenceNumber: ExtractedValue<String> = .missing
    var poNumber: ExtractedValue<String> = .missing
    var pickupNumber: ExtractedValue<String> = .missing
    var bolNumber: ExtractedValue<String> = .missing

    var carrierName: ExtractedValue<String> = .missing
    var driverName: ExtractedValue<String> = .missing
    var truckNumber: ExtractedValue<String> = .missing
    var trailerNumber: ExtractedValue<String> = .missing
    var equipmentType: ExtractedValue<String> = .missing

    var documentDate: ExtractedValue<SimpleDate> = .missing
    var stops: [ExtractedStop] = []

    var commodity: ExtractedValue<String> = .missing
    var weightPounds: ExtractedValue<Double> = .missing
    var miles: ExtractedValue<Double> = .missing
    var stopCount: ExtractedValue<Int> = .missing

    var linehaul: ExtractedValue<Double> = .missing
    var fuelSurcharge: ExtractedValue<Double> = .missing
    var detention: ExtractedValue<Double> = .missing
    var layover: ExtractedValue<Double> = .missing
    var tonu: ExtractedValue<Double> = .missing
    var lumper: ExtractedValue<Double> = .missing
    var stopOff: ExtractedValue<Double> = .missing
    var otherCharges: ExtractedValue<Double> = .missing
    var totalRate: ExtractedValue<Double> = .missing
    var charges: [ExtractedCharge] = []

    var issues: [ExtractionIssue] = []

    var pickups: [ExtractedStop] { stops.filter { $0.kind == .pickup } }
    var deliveries: [ExtractedStop] { stops.filter { $0.kind == .delivery } }
    var firstPickup: ExtractedStop? { pickups.first ?? stops.first }
    var lastDelivery: ExtractedStop? { deliveries.last ?? (stops.count > 1 ? stops.last : nil) }
    var pickupDate: ExtractedValue<SimpleDate> { firstPickup?.date ?? .missing }
    var deliveryDate: ExtractedValue<SimpleDate> { lastDelivery?.date ?? .missing }

    /// Sum of accessorial charges that are actually owed (not conditional terms).
    var accessorialTotal: Double {
        charges.filter { !$0.conditional && ![.linehaul, .fuelSurcharge, .total].contains($0.kind) }
            .reduce(0) { $0 + $1.amount }
    }
}

nonisolated enum RateConfirmationExtractor {

    // MARK: Label sets

    static let loadLabels = ["load number", "load no", "load #", "load id", "load", "order number", "order #",
                             "order no", "order", "shipment number", "shipment #", "shipment id", "trip number",
                             "trip #", "pro number", "pro #", "tender number", "tender #"]
    static let confirmationLabels = ["confirmation number", "confirmation #", "confirmation no", "conf number",
                                     "conf #", "conf no", "rate confirmation id", "rate confirmation #",
                                     "rate confirmation number", "rate con #", "rate con number", "confirmation id"]
    static let referenceLabels = ["reference number", "reference #", "reference no", "ref number", "ref #",
                                  "ref no", "customer ref", "cust ref", "customer reference", "reference", "ref"]
    static let poLabels = ["purchase order", "po number", "po #", "po no", "p.o. number", "p.o. #", "p.o.", "po"]
    static let pickupNumberLabels = ["pickup number", "pickup #", "pickup no", "pick up #", "pick up number",
                                     "pu number", "pu #", "shipper number", "shipper #"]
    static let bolLabels = ["bill of lading", "bol number", "bol #", "bol no", "b/l #", "bol"]

    static let allFieldLabels: [String] = loadLabels + confirmationLabels + referenceLabels + poLabels +
        pickupNumberLabels + bolLabels + ["date", "phone", "fax", "email", "contact", "weight", "miles", "commodity",
        "equipment", "trailer", "truck", "tractor", "driver", "carrier", "broker", "mc", "dot", "rate", "total",
        "pickup", "delivery", "appt", "appointment", "time", "name", "address", "pieces", "pallets", "temp", "seal"]

    // MARK: Entry

    static func extract(_ document: DocumentText) -> RateConfirmationExtraction {
        let all = document.lines
        // Long legal paragraphs never carry load data.
        let lines = all.filter { !isLegalLine($0.text) }
        var out = RateConfirmationExtraction()

        let blocks = findStopBlocks(lines)
        let blockLineIndexes = Set(blocks.flatMap { $0.range })
        let carrierBlock = carrierBlockIndexes(lines)
        let nonStopLines = lines.enumerated().filter { !blockLineIndexes.contains($0.offset) }.map(\.element)

        extractIdentifiers(&out, lines: lines, nonStop: nonStopLines)
        extractParties(&out, lines: lines, stopIdx: blockLineIndexes, carrierIdx: carrierBlock)
        out.stops = buildStops(blocks, lines: lines)
        applyLooseStopFields(&out, lines: nonStopLines)
        extractCargo(&out, lines: lines)
        extractCharges(&out, lines: lines)
        extractDocumentDate(&out, lines: nonStopLines)
        validate(&out)
        return out
    }

    // MARK: Line filters

    static func isLegalLine(_ s: String) -> Bool {
        if s.count > 160 { return true }
        if s.count > 90 {
            let words = s.split(separator: " ").count
            let hasValueShape = !SmartText.moneyTokens(in: s).isEmpty && s.count < 120
            return words >= 14 && !hasValueShape
        }
        return false
    }

    private static func isIdentifierValue(_ v: String) -> Bool {
        let s = SmartText.trimPunctuation(v)
        guard let first = s.split(separator: " ").first.map(String.init) else { return false }
        let lower = first.lowercased()
        if ["date", "type", "weight", "size", "status", "confirmation", "info", "information", "details", "count",
            "bars", "locks", "box", "pay", "rate", "time", "tracking", "number", "no", "of", "and", "the", "is",
            "must", "will", "shall", "may", "at", "to", "for", "by", "ready", "value", "temp"].contains(lower) {
            return false
        }
        guard let id = SmartText.identifier(in: first, minDigits: 2) else { return false }
        return id.count >= 3 && id.count <= 25
    }

    private static func identifierValue(_ v: String) -> String? {
        let s = SmartText.trimPunctuation(v)
        guard let first = s.split(separator: " ").first.map(String.init) else { return nil }
        return SmartText.identifier(in: first, minDigits: 2)
    }

    private static func confidence(for hit: LabelHit, strongLabels: [String]) -> ExtractionConfidence {
        let strong = strongLabels.contains(hit.label)
        switch (strong, hit.sameLine) {
        case (true, true): return .high
        case (true, false), (false, true): return .medium
        case (false, false): return .low
        }
    }

    // MARK: Identifiers

    private static func extractIdentifiers(_ out: inout RateConfirmationExtraction, lines: [DocLine], nonStop: [DocLine]) {
        func pick(_ labels: [String], strong: [String], from src: [DocLine], exclude: Set<String> = []) -> ExtractedValue<String> {
            for hit in SmartText.findLabeled(labels, in: src, stopLabels: allFieldLabels, accept: isIdentifierValue) {
                guard let id = identifierValue(hit.value), !exclude.contains(SmartText.normalizedIdentifier(id)) else { continue }
                return ExtractedValue(id, confidence(for: hit, strongLabels: strong), raw: hit.rawLine, page: hit.page)
            }
            return .missing
        }
        out.confirmationNumber = pick(confirmationLabels, strong: confirmationLabels, from: lines)
        out.loadNumber = pick(loadLabels, strong: ["load number", "load no", "load #", "load id", "order number", "order #", "shipment number", "shipment #", "shipment id"], from: lines)
        out.referenceNumber = pick(referenceLabels, strong: ["reference number", "reference #", "ref #", "ref number", "customer ref", "customer reference"], from: lines)
        out.poNumber = pick(poLabels, strong: ["purchase order", "po number", "po #", "p.o. #", "p.o. number"], from: lines)
        out.pickupNumber = pick(pickupNumberLabels, strong: pickupNumberLabels, from: lines)
        out.bolNumber = pick(bolLabels, strong: ["bill of lading", "bol number", "bol #"], from: lines)

        // Load # vs confirmation #: when only a confirmation number exists do
        // NOT copy it into load #, and vice versa.
        if let l = out.loadNumber.value, let c = out.confirmationNumber.value,
           SmartText.normalizedIdentifier(l) == SmartText.normalizedIdentifier(c),
           out.loadNumber.rawText == out.confirmationNumber.rawText {
            // Same text matched by both label sets ("Load Confirmation # 123").
            out.issues.append(.info("loadNumber", "Load # and confirmation # are the same number on this document."))
        }
    }

    // MARK: Parties

    private static let companySuffix = #"\b(llc|l\.l\.c|inc|incorporated|corp|corporation|co\.?|company|ltd|logistics|freight|transport(?:ation)?|trucking|brokerage|solutions|express|group|carriers?|lines|services|systems|global|worldwide|shipping|cargo|dispatch|haul(?:ing)?|enterprises|partners)\b"#

    private static func looksLikeCompany(_ s: String) -> Bool {
        let t = SmartText.trimPunctuation(s)
        guard t.count >= 3, t.count <= 60 else { return false }
        guard SmartText.contains(companySuffix, in: t) else { return false }
        if SmartText.contains(#"rate\s+confirmation|confirmation|agreement|terms|page\s+\d|invoice|carrier\s+must|must|shall|please|www\.|http|@"#, in: t) { return false }
        let letters = t.filter(\.isLetter).count
        return Double(letters) / Double(t.count) > 0.55
    }

    private static func looksLikePersonName(_ s: String) -> Bool {
        let t = SmartText.trimPunctuation(s)
        let words = t.split(separator: " ")
        guard (2...4).contains(words.count), t.count <= 40 else { return false }
        guard words.allSatisfy({ w in w.allSatisfy { $0.isLetter || $0 == "." || $0 == "'" || $0 == "-" } }) else { return false }
        let banned: Set<String> = ["cell", "phone", "email", "is", "must", "shall", "will", "responsible", "pay", "load", "unload",
                                   "assist", "count", "name", "number", "rate", "confirmation", "carrier", "broker", "llc",
                                   "inc", "logistics", "freight", "dispatch", "the", "and", "for", "of", "to", "information",
                                   "services", "department", "team", "desk", "operations", "accounting", "billing", "support"]
        return !words.contains { banned.contains($0.lowercased()) }
    }

    private static func carrierBlockIndexes(_ lines: [DocLine]) -> Set<Int> {
        var set = Set<Int>()
        for (i, l) in lines.enumerated() {
            let text = l.text
            if SmartText.contains(#"^\s*(driver\s+(?:name|cell|phone|email|#)|tractor\b|factoring\s+co)"#, in: text) {
                set.insert(i)
                continue
            }
            guard SmartText.contains(#"^\s*(carrier|carrier\s+information|carrier\s+name|carrier\s+info|remit\s+to)\b"#, in: text),
                  !SmartText.contains(#"^\s*carrier\s+(sales|rep|representative|rate|freight|pay|agrees|shall|must|confirmation)"#, in: text) else { continue }
            set.insert(i)
            // The carrier's own address/phone lines follow until the next label.
            var j = i + 1
            while j < lines.count && j <= i + 3 {
                let next = lines[j].text
                if SmartText.contains(#"^[A-Za-z][A-Za-z .#/]{1,24}:"#, in: next) && !SmartText.looksLikeLabelOnly(next) { break }
                if SmartText.looksLikeLabelOnly(next) && !SmartText.contains(#"^\s*(phone|contact|mc|dot|address)\b"#, in: next) { break }
                set.insert(j)
                j += 1
            }
        }
        return set
    }

    private static func extractParties(_ out: inout RateConfirmationExtraction, lines: [DocLine],
                                       stopIdx: Set<Int>, carrierIdx: Set<Int>) {
        let party = lines.enumerated().filter { !stopIdx.contains($0.offset) }

        // Carrier
        if let hit = SmartText.firstLabeled(["carrier name", "carrier"], in: lines, stopLabels: allFieldLabels,
                                            accept: { v in
                                                let lower = v.lowercased()
                                                guard lower.count >= 3, !lower.contains("$") else { return false }
                                                return !SmartText.contains(#"^(pay|rate|freight|agrees|shall|must|is|will|information|info|confirmation|signature|instructions|terms|name$)"#, in: lower)
                                                    && v.filter(\.isLetter).count >= 3
                                            }) {
            out.carrierName = ExtractedValue(SmartText.trimPunctuation(hit.value),
                                             hit.label == "carrier name" || hit.sameLine ? .high : .medium,
                                             raw: hit.rawLine, page: hit.page)
        }
        let carrierKey = out.carrierName.value.map { SmartText.key($0) }

        // Driver
        if let hit = SmartText.firstLabeled(["driver name", "driver"], in: lines, stopLabels: allFieldLabels,
                                            accept: { looksLikePersonName($0) }) {
            out.driverName = ExtractedValue(SmartText.trimPunctuation(hit.value), hit.sameLine ? .high : .medium,
                                            raw: hit.rawLine, page: hit.page)
        }

        // Truck / trailer / equipment
        let unitAccept: (String) -> Bool = { v in
            guard let first = v.split(separator: " ").first else { return false }
            let t = SmartText.trimPunctuation(String(first))
            return t.count >= 1 && t.count <= 14 && t.contains(where: \.isNumber) && SmartText.dateTokens(in: t).isEmpty
                && !t.contains("$")
        }
        if let hit = SmartText.firstLabeled(["truck number", "truck #", "tractor number", "tractor #", "tractor",
                                             "power unit", "unit number", "unit #", "truck"],
                                            in: lines, stopLabels: allFieldLabels, accept: unitAccept) {
            let v = SmartText.trimPunctuation(String(hit.value.split(separator: " ")[0]))
            out.truckNumber = ExtractedValue(v.uppercased(), hit.sameLine ? .high : .medium, raw: hit.rawLine, page: hit.page)
        }
        if let hit = SmartText.firstLabeled(["trailer number", "trailer #", "trailer no", "trailer"],
                                            in: lines, stopLabels: allFieldLabels, accept: unitAccept) {
            let v = SmartText.trimPunctuation(String(hit.value.split(separator: " ")[0]))
            out.trailerNumber = ExtractedValue(v.uppercased(), hit.sameLine ? .high : .medium, raw: hit.rawLine, page: hit.page)
        }
        if let hit = SmartText.firstLabeled(["equipment type", "equipment", "trailer type", "trailer", "mode"],
                                            in: lines, stopLabels: allFieldLabels,
                                            accept: { SmartText.contains(#"\b(van|reefer|refrigerated|flatbed|step\s*deck|conestoga|dry|hot\s*shot|box|power\s*only|tanker|lowboy|rgn|53'?|48'?)\b"#, in: $0) }) {
            out.equipmentType = ExtractedValue(SmartText.trimPunctuation(hit.value), .high, raw: hit.rawLine, page: hit.page)
        }

        // Broker company: labeled first.
        if let hit = SmartText.firstLabeled(["broker name", "broker", "brokerage", "bill to", "remit invoices to",
                                             "send invoices to", "customer name", "company name"],
                                            in: party.map(\.element), stopLabels: allFieldLabels,
                                            requireLineStart: true,
                                            accept: { v in
                                                let t = SmartText.trimPunctuation(v)
                                                let suffixOnly = SmartText.contains(#"^(llc|l\.l\.c\.?|inc\.?|corp\.?|co\.?|ltd\.?|company)$"#, in: t)
                                                return !suffixOnly && t.filter(\.isLetter).count >= 3 && t.count <= 60
                                                    && !SmartText.contains(#"^(agrees|shall|must|is|will|information|contact|phone|email|mc|dot|rate|pay)\b|terms|conditions|agreement|carrier"#, in: t)
                                            }) {
            let name = SmartText.trimPunctuation(hit.value)
            if SmartText.key(name) != carrierKey {
                out.brokerName = ExtractedValue(name, hit.sameLine ? .high : .medium, raw: hit.rawLine, page: hit.page)
            }
        }
        // Header company (first lines of page 1, not the carrier).
        if !out.brokerName.isFound {
            var firstLineOfPage: [Int: Int] = [:]
            for (i, l) in lines.enumerated() where firstLineOfPage[l.page] == nil { firstLineOfPage[l.page] = i }
            let candidates = lines.enumerated().filter { i, l in
                !carrierIdx.contains(i) && !stopIdx.contains(i) && i - (firstLineOfPage[l.page] ?? 0) < 25
            }
            for (_, l) in candidates {
                let raw = SmartText.replacing(#"(?i)^(rate\s+confirmation\s+(?:agreement\s+)?(?:for|from)\s+)"#, in: l.text, with: "")
                guard looksLikeCompany(raw) else { continue }
                let name = SmartText.trimPunctuation(raw)
                if SmartText.key(name) == carrierKey { continue }
                if let carrierKey, SmartText.key(name).contains(carrierKey) || carrierKey.contains(SmartText.key(name)) { continue }
                if SmartText.contains(#"sacred\s*pathway|factoring|financial|bank|insurance|terms|conditions"#, in: name) { continue }
                out.brokerName = ExtractedValue(name, .medium, raw: l.text, page: l.page)
                break
            }
        }

        // Broker email: prefer non-carrier lines and a domain matching the broker.
        let brokerKey = out.brokerName.value.map { SmartText.key($0) } ?? ""
        var emailCandidates: [(String, Int, DocLine)] = []
        for (i, l) in lines.enumerated() {
            guard let e = SmartText.email(in: l.text) else { continue }
            var score = 0
            if carrierIdx.contains(i) || SmartText.contains(#"driver|carrier\s+email|remit|factoring|\bquickpay\b|\bbilling\b|\binvoices?\b|\baccounting\b|\bap@|\bpayables?\b"#, in: l.text + " " + e) { score -= 10 }
            if SmartText.contains(#"^(dispatch|ops|operations|carrier|carriers|capacity|booking|loads?|track|tracking|sales|rep|agent)"#, in: e) { score += 3 }
            if SmartText.contains(#"^\s*(e-?mail|contact|rep|agent|dispatcher|attention|attn)\b"#, in: l.text) { score += 2 }
            // A person's address right under "Attention:/Rep:" is the booking rep.
            let window = lines[max(0, i - 3)..<i]
            if window.contains(where: { SmartText.contains(#"^\s*(attention|attn|rep|carrier\s+sales\s+rep|carrier\s+rep|agent|dispatcher|account\s+manager|booked\s+by|contact\s+name)\b"#, in: $0.text) }) { score += 5 }
            let domain = e.split(separator: "@").last.map { SmartText.key(String($0.split(separator: ".").first ?? "")) } ?? ""
            if !brokerKey.isEmpty, !domain.isEmpty, brokerKey.contains(domain) || domain.contains(brokerKey.prefix(6)) { score += 4 }
            if SmartText.contains(#"gmail|yahoo|hotmail|outlook|icloud|aol"#, in: e) { score -= 1 }
            if SmartText.contains(#"sacredpathway"#, in: e) { score -= 20 }
            emailCandidates.append((e, score, l))
        }
        if let best = emailCandidates.filter({ $0.1 > -5 }).max(by: { $0.1 < $1.1 }) {
            out.brokerEmail = ExtractedValue(best.0, best.1 >= 3 ? .high : .medium, raw: best.2.text, page: best.2.page)
        }

        // Broker phone: labeled, outside stop and carrier blocks.
        for (i, l) in lines.enumerated() {
            guard !stopIdx.contains(i), !carrierIdx.contains(i), let p = SmartText.phone(in: l.text) else { continue }
            if SmartText.contains(#"\bfax\b|\bdriver\b|\bcell\b|after\s*hours?|emergency|24/7|factoring"#, in: l.text) { continue }
            let labeled = SmartText.contains(#"\b(phone|ph|tel|office|contact|rep|agent|dispatch|main|call)\b"#, in: l.text)
            out.brokerPhone = ExtractedValue(p.number, labeled ? .medium : .low, raw: l.text, page: l.page)
            if let ext = p.ext { out.brokerPhoneExtension = ExtractedValue(ext, .medium, raw: l.text, page: l.page) }
            break
        }

        // Broker contact person.
        let contactLabels = ["carrier sales rep", "carrier rep", "account manager", "broker contact", "booked by",
                             "contact name", "dispatcher", "representative", "rep", "agent", "attention", "attn", "contact"]
        let nonCarrierLines = lines.enumerated().filter { !carrierIdx.contains($0.offset) && !stopIdx.contains($0.offset) }.map(\.element)
        if let hit = SmartText.firstLabeled(contactLabels, in: nonCarrierLines, stopLabels: allFieldLabels,
                                            accept: { looksLikePersonName($0) }) {
            out.brokerContact = ExtractedValue(SmartText.trimPunctuation(hit.value), hit.sameLine ? .medium : .low,
                                               raw: hit.rawLine, page: hit.page)
        } else if let email = out.brokerEmail.value,
                  let g = SmartText.groups(#"^([a-z]+)[._]([a-z]{2,})@"#, in: email),
                  let first = g[1], let last = g[2],
                  !["dispatch", "ops", "carrier", "carriers", "info", "sales", "loads", "track", "tracking", "billing"].contains(first) {
            out.brokerContact = ExtractedValue(first.capitalized + " " + last.capitalized, .low,
                                               raw: email, page: out.brokerEmail.page)
        }

        // Broker MC (header area, not carrier block).
        for (i, l) in lines.enumerated() where !carrierIdx.contains(i) {
            if let g = SmartText.groups(#"\bMC\s*(?:#|no\.?|number)?\s*[:#]?\s*(\d{4,8})\b"#, in: l.text), let mc = g[1] {
                out.brokerMC = ExtractedValue(mc, .medium, raw: l.text, page: l.page)
                break
            }
        }
    }

    // MARK: Stops

    struct StopBlock {
        var kind: ExtractedStop.Kind
        var explicitKind: Bool
        var headerRemainder: String
        var range: [Int]
        var page: Int
    }

    private static let pickupHeader = #"^\s*(?:stop\s*#?\s*\d+\s*[:\-.)]?\s*)?(?:\(?\s*)?(pick\s*-?\s*up|pickup|p/u|pu|shipper|origin|ship\s+from|loading|load\s+at)\b(?!\s*(?:date|time|appt|appointment|#|number|no\.?|hours|instructions|window|requirements?|must|and|&|/|by|due|before|no\s+later|charge|fee|pay)\b)\s*(?:#?\s*\d{1,2}\b)?\s*(?:\)|[:\-–]|information|info|location|details|address)?\s*"#
    private static let deliveryHeader = #"^\s*(?:stop\s*#?\s*\d+\s*[:\-.)]?\s*)?(?:\(?\s*)?(deliver(?:y)?|del|drop(?:\s*-?\s*off)?|consignee|receiver|destination|ship\s+to|unloading|unload\s+at)\b(?!\s*(?:date|time|appt|appointment|#|number|no\.?|hours|instructions|window|requirements?|must|and|&|/|by|due|before|no\s+later|charge|fee|pay)\b)\s*(?:#?\s*\d{1,2}\b)?\s*(?:\)|[:\-–]|information|info|location|details|address)?\s*"#
    private static let genericStopHeader = #"^\s*(?:SO|STOP|Stop|EXTRA STOP|Extra Stop)\s*#?\s*(\d{1,2})\b\s*[:\-.)]?\s*"#
    private static let sectionEnd = #"^\s*(payment|pay\s+(?:summary|details)|rates?(?:\s+(?:and|&)\s+charges)?|charges|carrier\s+(?:freight\s+)?pay|total|accessorials?|instructions|special\s+instructions|notes?|terms|comments|driver|signature|please\s+sign|carrier\s+(?:information|info)|commodity\s+information|equipment|load\s+details|dispatch\s+(?:information|instructions)|broker|bill\s+to|billing)\b"#

    private static func headerMatch(_ text: String) -> (ExtractedStop.Kind, Bool, String)? {
        if text.count > 90 { return nil }
        for (pattern, kind) in [(pickupHeader, ExtractedStop.Kind.pickup), (deliveryHeader, .delivery)] {
            if let m = SmartText.matches(pattern, in: text).first, let r = Range(m.range, in: text) {
                let word = SmartText.captures(m, in: text)[1]?.lowercased() ?? ""
                // "PU"/"DEL"/"SO" are only headers when upper-case in the source.
                if ["pu", "del", "p/u"].contains(word), !text.contains(word.uppercased()) { continue }
                let rest = String(text[r.upperBound...])
                // "Shipper agrees…" / "Delivery must…" are sentences, not headers.
                if rest.split(separator: " ").count > 8 && SmartText.moneyTokens(in: rest).isEmpty && SmartText.cityStateZip(in: rest) == nil { continue }
                return (kind, true, rest)
            }
        }
        if let m = SmartText.matches(genericStopHeader, in: text, caseInsensitive: false).first
            ?? SmartText.matches(#"^\s*(?:stop|extra\s+stop)\s*#?\s*(\d{1,2})\b\s*[:\-.)]?\s*"#, in: text).first,
           let r = Range(m.range, in: text) {
            let rest = String(text[r.upperBound...])
            if SmartText.contains(#"\b(pick|pu\b|load)"#, in: rest) { return (.pickup, true, rest) }
            if SmartText.contains(#"\b(deliver|drop|del\b|unload|consignee|receiver)"#, in: rest) { return (.delivery, true, rest) }
            return (.stop, false, rest)
        }
        return nil
    }

    static func findStopBlocks(_ lines: [DocLine]) -> [StopBlock] {
        var starts: [(Int, ExtractedStop.Kind, Bool, String)] = []
        for (i, l) in lines.enumerated() {
            if let (kind, explicit, rest) = headerMatch(l.text) {
                starts.append((i, kind, explicit, rest))
            }
        }
        var blocks: [StopBlock] = []
        for (n, s) in starts.enumerated() {
            let hardEnd = n + 1 < starts.count ? starts[n + 1].0 : lines.count
            var end = min(hardEnd, s.0 + 14)
            if s.0 + 1 < end {
                for j in (s.0 + 1)..<end where SmartText.contains(sectionEnd, in: lines[j].text) && headerMatch(lines[j].text) == nil {
                    // A label that belongs inside a stop ("Driver Notes") still ends it.
                    end = j
                    break
                }
            }
            blocks.append(StopBlock(kind: s.1, explicitKind: s.2, headerRemainder: s.3,
                                    range: Array(s.0..<max(end, s.0 + 1)), page: lines[s.0].page))
        }
        return blocks
    }

    private static let stopFieldLabels = ["name", "facility", "company", "location name", "shipper name",
                                          "consignee name", "receiver name", "address", "date", "appt", "appointment",
                                          "time", "ready", "scheduled", "earliest", "latest", "contact", "phone",
                                          "pu #", "pickup #", "del #", "delivery #", "ref", "reference", "po",
                                          "confirmation", "hours", "notes", "comments", "weight", "pieces", "pallets",
                                          "commodity", "seal"]

    private static func buildStops(_ blocks: [StopBlock], lines: [DocLine]) -> [ExtractedStop] {
        var stops: [ExtractedStop] = []
        for (n, block) in blocks.enumerated() {
            var stop = ExtractedStop(id: n + 1, kind: block.kind, page: block.page)
            let blockLines = block.range.map { lines[$0] }
            let body = Array(blockLines.dropFirst())
            let headerLine = blockLines[0]

            // Header remainder may carry the facility or the city.
            let rest = SmartText.trimPunctuation(SmartText.cutAtNextLabel(block.headerRemainder, stopLabels: stopFieldLabels))

            // Facility: labeled > header remainder > first plain line.
            if let hit = SmartText.firstLabeled(["facility name", "location name", "shipper name", "consignee name",
                                                 "receiver name", "company", "facility", "name"],
                                                in: blockLines, stopLabels: stopFieldLabels, lookahead: 1,
                                                accept: { v in v.filter(\.isLetter).count >= 2 && SmartText.dateTokens(in: v).isEmpty && SmartText.phone(in: v) == nil }) {
                stop.facility = ExtractedValue(SmartText.trimPunctuation(hit.value), hit.sameLine ? .high : .medium, raw: hit.rawLine, page: hit.page)
            }

            // Address / city lines. Collect every city/state reading, then
            // prefer one with a ZIP, then one after the street line.
            var cszCandidates: [(CityStateZip, DocLine, Int)] = []
            var addressIndex: Int?
            for (k, l) in blockLines.enumerated() {
                let text = k == 0 ? rest : SmartText.cutAtNextLabel(SmartText.replacing(#"(?i)^\s*(address|location|addr)\s*[:.]?\s*"#, in: l.text, with: ""), stopLabels: ["phone", "contact", "date", "appt", "fax", "hours"])
                guard !text.isEmpty else { continue }
                if !stop.address.isFound, SmartText.isStreetAddress(text) {
                    addressIndex = k
                    // "105 W Sharp St, El Dorado, AR 71730" on one line.
                    if let c = SmartText.cityStateZip(in: text), let street = text.components(separatedBy: ",").first,
                       street.count < text.count {
                        stop.address = ExtractedValue(SmartText.trimPunctuation(street), .high, raw: l.text, page: l.page)
                        cszCandidates.append((c, l, k))
                    } else {
                        stop.address = ExtractedValue(SmartText.trimPunctuation(text), .high, raw: l.text, page: l.page)
                    }
                    continue
                }
                if let c = SmartText.cityStateZip(in: text) {
                    cszCandidates.append((c, l, k))
                    continue
                }
                // Split city / "ST 12345" over two lines.
                if k + 1 < blockLines.count,
                   let g = SmartText.groups(#"^([A-Za-z]{2})\s+(\d{5})(?:-\d{4})?$"#, in: blockLines[k + 1].text),
                   let st = g[1]?.uppercased(), SmartText.stateCodes.contains(st),
                   text.allSatisfy({ $0.isLetter || $0 == " " || $0 == "." || $0 == "'" }), text.count <= 30 {
                    let merged = text + ", " + st + " " + (g[2] ?? "")
                    if let c = SmartText.cityStateZip(in: merged) { cszCandidates.append((c, blockLines[k + 1], k + 1)) }
                }
            }
            let chosen = cszCandidates.first(where: { $0.0.zip != nil })
                ?? cszCandidates.first(where: { addressIndex != nil && $0.2 > addressIndex! })
                ?? cszCandidates.first(where: { addressIndex == nil || $0.2 != addressIndex! - 1 })
            let csz = chosen?.0
            let cszLine = chosen?.1
            if let csz, let l = cszLine {
                let conf: ExtractionConfidence = csz.zip != nil ? .high : .medium
                stop.city = ExtractedValue(csz.city, conf, raw: l.text, page: l.page)
                stop.state = ExtractedValue(csz.state, conf, raw: l.text, page: l.page)
                if let z = csz.zip { stop.zip = ExtractedValue(z, .high, raw: l.text, page: l.page) }
            }

            // Facility fallback: header remainder or first plain body line.
            if !stop.facility.isFound {
                let plain: (String) -> Bool = { t in
                    let v = SmartText.trimPunctuation(t)
                    return v.filter(\.isLetter).count >= 3 && v.count <= 60
                        && !SmartText.isStreetAddress(v) && SmartText.cityStateZip(in: v) == nil
                        && SmartText.dateTokens(in: v).isEmpty && SmartText.phone(in: v) == nil
                        && SmartText.email(in: v) == nil && !SmartText.looksLikeLabelOnly(v)
                        && !SmartText.contains(#"^(date|appt|appointment|time|ready|contact|phone|ref|reference|po|pu|del|notes?|hours|driver|weight|pieces|pallets|commodity|seal|fcfs|open|closed|by appt)\b"#, in: v)
                        && SmartText.moneyTokens(in: v).isEmpty
                }
                if plain(rest) {
                    stop.facility = ExtractedValue(SmartText.trimPunctuation(rest), .medium, raw: headerLine.text, page: headerLine.page)
                } else if let idx = body.firstIndex(where: { plain($0.text) }) {
                    let l = body[idx]
                    // Directly under the header and above the street line → a facility name.
                    let nextIsStreet = idx + 1 < body.count && SmartText.isStreetAddress(body[idx + 1].text)
                    let conf: ExtractionConfidence = (idx == 0 && nextIsStreet) ? .medium : .low
                    if chosen.map({ $0.1 != l }) ?? true {
                        stop.facility = ExtractedValue(SmartText.trimPunctuation(l.text), conf, raw: l.text, page: l.page)
                    }
                }
            }

            // Dates / appointment.
            let dateLabels = ["pickup date", "pick up date", "delivery date", "ship date", "pu date", "del date",
                              "appointment", "appt date", "appt", "scheduled", "ready date", "ready", "earliest",
                              "latest", "date"]
            var dateLines: [(DocLine, DateToken)] = []
            for l in blockLines {
                if let t = SmartText.dateTokens(in: l.text).first { dateLines.append((l, t)) }
            }
            if let hit = SmartText.firstLabeled(dateLabels, in: blockLines, stopLabels: stopFieldLabels, lookahead: 1,
                                                accept: { SmartText.firstDate(in: $0) != nil }),
               let t = SmartText.firstDate(in: hit.value) {
                stop.date = ExtractedValue(t.date, t.ambiguous ? .low : (hit.sameLine ? .high : .medium), raw: hit.rawLine, page: hit.page)
            } else if let (l, t) = dateLines.first {
                stop.date = ExtractedValue(t.date, t.ambiguous ? .low : .medium, raw: l.text, page: l.page)
            }
            // Appointment window: times on the date lines (same day).
            var times: [String] = []
            for (l, t) in dateLines where stop.date.value == nil || t.date == stop.date.value {
                var rest = l.text
                if let r = rest.range(of: t.text) { rest.removeSubrange(r) }
                if let a = SmartText.appointment(in: rest + " appt") { times.append(a) }
            }
            if times.isEmpty, let hit = SmartText.firstLabeled(["appointment", "appt", "time", "window", "hours"],
                                                               in: blockLines, stopLabels: stopFieldLabels, lookahead: 1,
                                                               accept: { SmartText.appointment(in: $0 + " appt") != nil }),
               let a = SmartText.appointment(in: hit.value + " appt") {
                stop.appointment = ExtractedValue(a, hit.sameLine ? .high : .medium, raw: hit.rawLine, page: hit.page)
            } else if !times.isEmpty {
                let uniq = times.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                let text: String
                if uniq.count >= 2, !uniq[0].contains("–") {
                    text = uniq[0] + "–" + uniq[uniq.count - 1]
                } else {
                    text = uniq[0]
                }
                stop.appointment = ExtractedValue(text, .medium, raw: dateLines.first?.0.text, page: dateLines.first?.0.page)
            }

            // Stop reference number.
            if let hit = SmartText.firstLabeled(["pickup #", "pu #", "del #", "delivery #", "confirmation #", "appt #",
                                                 "ref #", "reference", "po #", "po"],
                                                in: body, stopLabels: stopFieldLabels, lookahead: 0,
                                                accept: { identifierValue($0) != nil }),
               let id = identifierValue(hit.value) {
                stop.reference = ExtractedValue(id, .medium, raw: hit.rawLine, page: hit.page)
            }

            if !stop.isEmpty { stops.append(stop) }
        }

        // Generic "SO 2"/"Stop 3" kinds: first → pickup when none, last → delivery.
        if !stops.isEmpty {
            if !stops.contains(where: { $0.kind == .pickup }), stops[0].kind == .stop { stops[0].kind = .pickup }
            if stops.count > 1, !stops.contains(where: { $0.kind == .delivery }), stops[stops.count - 1].kind == .stop {
                stops[stops.count - 1].kind = .delivery
            }
        }

        // Multi-page documents repeat stops (summary page + detail page).
        var unique: [ExtractedStop] = []
        for s in stops {
            if let idx = unique.firstIndex(where: { u in
                u.kind == s.kind && u.cityState != nil && u.cityState?.lowercased() == s.cityState?.lowercased()
                    && (u.date.value == nil || s.date.value == nil || u.date.value == s.date.value)
            }) {
                // Merge: keep the reading with more detail.
                var m = unique[idx]
                m.facility = m.facility.preferring(s.facility)
                m.address = m.address.preferring(s.address)
                m.zip = m.zip.preferring(s.zip)
                m.date = m.date.preferring(s.date)
                m.appointment = m.appointment.preferring(s.appointment)
                m.reference = m.reference.preferring(s.reference)
                unique[idx] = m
            } else {
                unique.append(s)
            }
        }
        return unique.enumerated().map { i, s in var c = s; c.id = i + 1; return c }
    }

    /// "Origin: Dallas, TX" / "Pickup Date: 09/17/2026" outside stop blocks.
    private static func applyLooseStopFields(_ out: inout RateConfirmationExtraction, lines: [DocLine]) {
        func ensure(_ kind: ExtractedStop.Kind) -> Int {
            if kind == .pickup, let i = out.stops.firstIndex(where: { $0.kind == .pickup }) { return i }
            if kind == .delivery, let i = out.stops.lastIndex(where: { $0.kind == .delivery }) { return i }
            let stop = ExtractedStop(id: out.stops.count + 1, kind: kind)
            if kind == .pickup { out.stops.insert(stop, at: 0) } else { out.stops.append(stop) }
            out.stops = out.stops.enumerated().map { i, s in var c = s; c.id = i + 1; return c }
            return kind == .pickup ? 0 : out.stops.count - 1
        }
        let pairs: [(ExtractedStop.Kind, [String], [String])] = [
            (.pickup, ["pickup date", "pick up date", "pu date", "ship date", "pickup appointment", "pickup appt"],
             ["pickup location", "pickup city", "origin city", "ship from"]),
            (.delivery, ["delivery date", "del date", "deliver date", "drop date", "delivery appointment", "delivery appt", "due date"],
             ["delivery location", "delivery city", "destination city", "ship to"])
        ]
        for (kind, dateLabels, placeLabels) in pairs {
            if let hit = SmartText.firstLabeled(dateLabels, in: lines, stopLabels: allFieldLabels, lookahead: 1,
                                                accept: { SmartText.firstDate(in: $0) != nil }),
               let t = SmartText.firstDate(in: hit.value) {
                let i = ensure(kind)
                if !out.stops[i].date.isFound {
                    out.stops[i].date = ExtractedValue(t.date, t.ambiguous ? .low : (hit.sameLine ? .high : .medium), raw: hit.rawLine, page: hit.page)
                }
                if !out.stops[i].appointment.isFound {
                    var rest = hit.value
                    if let r = rest.range(of: t.text) { rest.removeSubrange(r) }
                    if let a = SmartText.appointment(in: rest + " appt") {
                        out.stops[i].appointment = ExtractedValue(a, .medium, raw: hit.rawLine, page: hit.page)
                    }
                }
            }
            if let hit = SmartText.firstLabeled(placeLabels, in: lines, stopLabels: allFieldLabels, lookahead: 1,
                                                accept: { SmartText.cityStateZip(in: $0) != nil }),
               let c = SmartText.cityStateZip(in: hit.value) {
                let i = ensure(kind)
                if !out.stops[i].city.isFound {
                    out.stops[i].city = ExtractedValue(c.city, .high, raw: hit.rawLine, page: hit.page)
                    out.stops[i].state = ExtractedValue(c.state, .high, raw: hit.rawLine, page: hit.page)
                    if let z = c.zip { out.stops[i].zip = ExtractedValue(z, .high, raw: hit.rawLine, page: hit.page) }
                }
            }
        }
        out.stops.removeAll { $0.isEmpty }
        out.stops = out.stops.enumerated().map { i, s in var c = s; c.id = i + 1; return c }
    }

    // MARK: Cargo

    private static func extractCargo(_ out: inout RateConfirmationExtraction, lines: [DocLine]) {
        if let hit = SmartText.firstLabeled(["commodity description", "commodity", "description of goods",
                                             "freight description", "product description", "goods", "product", "material"],
                                            in: lines, stopLabels: allFieldLabels, lookahead: 1,
                                            accept: { v in
                                                let t = SmartText.trimPunctuation(v)
                                                return t.filter(\.isLetter).count >= 3 && t.count <= 80
                                                    && !SmartText.contains(#"^(weight|value|class|type|code|information|info|details)\b"#, in: t)
                                                    && SmartText.moneyTokens(in: t).isEmpty
                                            }) {
            out.commodity = ExtractedValue(SmartText.trimPunctuation(hit.value), hit.sameLine ? .high : .medium, raw: hit.rawLine, page: hit.page)
        }

        if let hit = SmartText.firstLabeled(["total weight", "gross weight", "estimated weight", "est weight",
                                             "scale weight", "weight", "wt", "lbs"],
                                            in: lines, stopLabels: allFieldLabels, lookahead: 1,
                                            accept: { v in
                                                guard !SmartText.contains(#"^(max|limit|capacity|per)\b|\$"#, in: v) else { return false }
                                                return (SmartText.weightPounds(in: v) ?? 0) >= 100
                                            }),
           let w = SmartText.weightPounds(in: hit.value) {
            out.weightPounds = ExtractedValue(w, hit.sameLine ? .high : .medium, raw: hit.rawLine, page: hit.page)
        }

        let milesAccept: (String) -> Bool = { v in
            guard !v.contains("$"), !SmartText.contains(#"per\s+mile|/\s*mi\b|\brpm\b"#, in: v) else { return false }
            guard let n = SmartText.numbers(in: v).first else { return false }
            return n.value >= 1 && n.value <= 6_000 && n.start <= 2
        }
        let milesLines = lines.filter { !SmartText.contains(#"rate\s+per\s+mile|per\s+mile|\brpm\b|deadhead|empty\s+miles|out\s+of\s+route|oor"#, in: $0.text) }
        if let hit = SmartText.firstLabeled(["total miles", "loaded miles", "trip miles", "practical miles",
                                             "est miles", "estimated miles", "miles", "mileage", "distance"],
                                            in: milesLines, stopLabels: allFieldLabels, lookahead: 1, accept: milesAccept),
           let n = SmartText.numbers(in: hit.value).first {
            out.miles = ExtractedValue(n.value.rounded(), hit.sameLine ? .high : .medium, raw: hit.rawLine, page: hit.page)
        }

        if let hit = SmartText.firstLabeled(["number of stops", "# of stops", "total stops", "stops"],
                                            in: lines, stopLabels: allFieldLabels, lookahead: 0,
                                            accept: { v in (SmartText.numbers(in: v).first.map { $0.value >= 1 && $0.value <= 30 && $0.start == 0 }) ?? false }),
           let n = SmartText.numbers(in: hit.value).first {
            out.stopCount = ExtractedValue(Int(n.value), .high, raw: hit.rawLine, page: hit.page)
        } else if !out.stops.isEmpty {
            let conf: ExtractionConfidence = out.stops.allSatisfy { $0.city.isFound } ? .medium : .low
            out.stopCount = ExtractedValue(out.stops.count, conf)
        }
    }

    // MARK: Charges

    private static let chargePatterns: [(ExtractedCharge.Kind, String)] = [
        (.tonu, #"\btonu\b|truck\s+order(?:ed)?\s+not\s+used"#),
        (.fuelSurcharge, #"fuel\s+sur-?\s?charge|\bfsc\b|fuel\s+adj(?:ustment)?"#),
        (.detention, #"\bdetention\b"#),
        (.layover, #"\blay\s?over\b"#),
        (.lumper, #"\blumper\b|unloading\s+fee"#),
        (.stopOff, #"stop[\s-]?off|extra\s+stop|additional\s+stop|stop\s+charge|drop\s+charge"#),
        (.total, #"total\s+carrier\s+(?:pay|rate|charges?)|total\s+(?:rate|pay|amount|due|charges|cost|payable|linehaul\s+rate)|grand\s+total|agreed(?:\s+upon)?\s+rate|carrier\s+rate|all[\s-]?in\s+rate|flat\s+rate\s+total|^\s*total\b"#),
        (.linehaul, #"\bline\s?-?haul\b|\blh\b|base\s+rate|flat\s+rate|freight\s+charges?|carrier\s+freight\s+pay|freight\s+pay|base\s+pay|transportation\s+charges?|haul\s+rate"#),
        (.accessorial, #"accessorials?|additional\s+charges?|extra\s+charges?|other\s+charges?|\bmisc(?:ellaneous)?\b"#)
    ]

    private static func conditionalCharge(_ text: String) -> Bool {
        SmartText.contains(#"/\s*(?:hr|hour|day)\b|per\s+(?:hour|hr|day)|\bafter\b|\bif\b|will\s+be|\bmay\b|up\s+to|\bmax(?:imum)?\b|\bfree\s+time\b|\bpaid\s+(?:only|upon)|\bwhen\b|\bunless\b|\bpenalty\b|\bfine\b|charged?\s+(?:a|the)\b"#, in: text)
    }

    private static func extractCharges(_ out: inout RateConfirmationExtraction, lines: [DocLine]) {
        var charges: [ExtractedCharge] = []
        var genericRates: [(Double, DocLine, Bool)] = []

        for (i, l) in lines.enumerated() {
            let text = SmartText.stripLeaders(l.text)
            if SmartText.contains(#"rate\s+per\s+mile|per\s+mile|\brpm\b|/\s*mi\b|penalty|fine\s+of|charged\s+a|deduct|\bfee\s+of\b|insurance|cargo\s+(?:value|limit)|liability"#, in: text) { continue }
            guard let kind = chargePatterns.first(where: { SmartText.contains($0.1, in: text) })?.0 else {
                // Generic "Rate: $2,850.00".
                if SmartText.contains(#"^\s*(?:carrier\s+)?rate\s*[:#$]|^\s*rate\s+\$|\bflat\s+rate\b"#, in: text),
                   !SmartText.contains(#"rate\s+con(?:firmation)?|rate\s+agreement"#, in: text) {
                    let m = SmartText.moneyTokens(in: text)
                    if let v = m.first?.value, v > 0 { genericRates.append((v, l, true)) }
                    else if i + 1 < lines.count, let v = SmartText.moneyTokens(in: lines[i + 1].text).first?.value, v > 0 {
                        genericRates.append((v, lines[i + 1], false))
                    }
                }
                continue
            }
            if kind == .fuelSurcharge, SmartText.contains(#"included|incl\.?|all[\s-]?in"#, in: text), SmartText.moneyTokens(in: text).isEmpty { continue }
            var tokens = SmartText.moneyTokens(in: text)
            var sameLine = true
            var valueLine = l
            if tokens.isEmpty, i + 1 < lines.count, headerMatch(lines[i + 1].text) == nil {
                let next = SmartText.stripLeaders(lines[i + 1].text)
                let nextTokens = SmartText.moneyTokens(in: next)
                if !nextTokens.isEmpty, chargePatterns.first(where: { SmartText.contains($0.1, in: next) }) == nil {
                    tokens = nextTokens
                    sameLine = false
                    valueLine = lines[i + 1]
                }
            }
            guard let token = tokens.last(where: { $0.value != 0 }) ?? tokens.first else { continue }
            // "Line Haul 1 x $2,500.00 = $2,500.00" → the last amount on the line.
            let conditional = conditionalCharge(text)
            let label = SmartText.trimPunctuation(String(text.prefix(40)))
            let conf: ExtractionConfidence = conditional ? .low : (sameLine ? (token.hasSymbol || token.hasCents ? .high : .medium) : .medium)
            charges.append(ExtractedCharge(id: charges.count + 1, kind: kind, label: label, amount: abs(token.value),
                                           conditional: conditional, confidence: conf,
                                           rawText: l.text + (sameLine ? "" : " / " + valueLine.text), page: l.page))
        }

        // Drop duplicate readings of the same charge (repeated pages).
        var dedup: [ExtractedCharge] = []
        for c in charges where !dedup.contains(where: { $0.kind == c.kind && SmartText.approxEqual($0.amount, c.amount) && $0.conditional == c.conditional }) {
            dedup.append(c)
        }
        out.charges = dedup.enumerated().map { i, c in var x = c; x.id = i + 1; return x }

        func single(_ kind: ExtractedCharge.Kind) -> ExtractedValue<Double> {
            let owed = out.charges.filter { $0.kind == kind && !$0.conditional }
            guard let first = owed.first else {
                if let cond = out.charges.first(where: { $0.kind == kind }) {
                    return ExtractedValue(cond.amount, .low, raw: cond.rawText, page: cond.page)
                }
                return .missing
            }
            let sum = owed.reduce(0) { $0 + $1.amount }
            let conf = owed.map(\.confidence).min() ?? .medium
            return ExtractedValue((sum * 100).rounded() / 100, conf, raw: first.rawText, page: first.page)
        }
        out.linehaul = single(.linehaul)
        out.fuelSurcharge = single(.fuelSurcharge)
        out.detention = single(.detention)
        out.layover = single(.layover)
        out.tonu = single(.tonu)
        out.lumper = single(.lumper)
        out.stopOff = single(.stopOff)
        let other = single(.accessorial)
        out.otherCharges = other

        // Total: strongest label wins; later pages win ties (summary tables).
        let totals = out.charges.filter { $0.kind == .total && !$0.conditional }
        if !totals.isEmpty {
            let distinct = totals.reduce(into: [Double]()) { acc, c in if !acc.contains(where: { SmartText.approxEqual($0, c.amount) }) { acc.append(c.amount) } }
            let best = totals.max { a, b in
                let sa = totalLabelStrength(a.rawText ?? ""), sb = totalLabelStrength(b.rawText ?? "")
                return sa == sb ? a.amount < b.amount : sa < sb
            }!
            var conf = best.confidence
            if distinct.count > 1 {
                conf = conf.downgraded
                out.issues.append(.warning("totalRate", "The document shows more than one total (\(distinct.map(SmartText.money).joined(separator: ", "))). Check the agreed rate."))
            }
            if totalLabelStrength(best.rawText ?? "") < 2 { conf = min(conf, .medium) }
            out.totalRate = ExtractedValue(best.amount, conf, raw: best.rawText, page: best.page)
        } else if let g = genericRates.first {
            out.totalRate = ExtractedValue(g.0, g.2 ? .medium : .low, raw: g.1.text, page: g.1.page)
        }
    }

    private static func totalLabelStrength(_ text: String) -> Int {
        if SmartText.contains(#"total\s+carrier|agreed(?:\s+upon)?\s+rate|all[\s-]?in|total\s+rate|carrier\s+rate"#, in: text) { return 3 }
        if SmartText.contains(#"total\s+(?:pay|amount|due|charges|payable)|grand\s+total"#, in: text) { return 2 }
        return 1
    }

    // MARK: Document date

    private static func extractDocumentDate(_ out: inout RateConfirmationExtraction, lines: [DocLine]) {
        let labels = ["date issued", "issue date", "issued", "printed", "print date", "created", "generated",
                      "tender date", "order date", "confirmation date", "booked date", "date"]
        let candidates = lines.filter { !SmartText.contains(#"pick|deliver|ship\s+date|appt|appointment|due|eta|arrive|ready"#, in: $0.text) }
        if let hit = SmartText.firstLabeled(labels, in: candidates, stopLabels: allFieldLabels, lookahead: 1,
                                            accept: { SmartText.firstDate(in: $0) != nil }),
           let t = SmartText.firstDate(in: hit.value) {
            out.documentDate = ExtractedValue(t.date, hit.label == "date" ? .medium : .high, raw: hit.rawLine, page: hit.page)
        }
    }

    // MARK: Validation

    private static func validate(_ out: inout RateConfirmationExtraction) {
        // Money consistency: linehaul + FSC + owed accessorials ≈ total.
        if let total = out.totalRate.value {
            let parts = (out.linehaul.value ?? 0) + (out.fuelSurcharge.value ?? 0) + out.accessorialTotal
            if out.linehaul.isFound {
                if SmartText.approxEqual(parts, total) || SmartText.approxEqual(out.linehaul.value ?? 0, total) {
                    if out.totalRate.confidence == .medium, out.linehaul.confidence == .high {
                        out.totalRate.confidence = .high
                    }
                } else if parts > total + 0.02 {
                    out.issues.append(.warning("totalRate", "Charges add up to \(SmartText.money(parts)) but the total says \(SmartText.money(total))."))
                    out.totalRate = out.totalRate.downgraded()
                } else {
                    out.issues.append(.info("totalRate", "The total is \(SmartText.money(total - parts)) more than the listed charges; there may be charges the scan did not read."))
                }
            }
            if total < 50 || total > 50_000 {
                out.issues.append(.warning("totalRate", "The rate \(SmartText.money(total)) looks unusual for a load."))
                out.totalRate = out.totalRate.downgraded()
            }
        } else {
            out.issues.append(.warning("totalRate", "No total rate was found. Enter the agreed rate."))
        }

        // Rate must not be the mileage.
        if let m = out.miles.value, let t = out.totalRate.value, SmartText.approxEqual(m, t, tolerance: 0.5) {
            out.issues.append(.warning("totalRate", "The rate matches the miles value; check that the rate is right."))
            out.totalRate = out.totalRate.downgraded()
        }

        // Dates: delivery must not be before pickup; pickup should not be far from the doc date.
        if let p = out.pickupDate.value, let d = out.deliveryDate.value, d < p,
           let pi = out.stops.firstIndex(where: { $0.id == out.firstPickup?.id }),
           let di = out.stops.lastIndex(where: { $0.id == out.lastDelivery?.id }) {
            out.issues.append(.warning("deliveryDate", "Delivery date is before the pickup date."))
            out.stops[pi].date = out.stops[pi].date.downgraded()
            out.stops[di].date = out.stops[di].date.downgraded()
        }
        if let p = out.pickupDate.value, let doc = out.documentDate.value, abs(doc.days(to: p)) > 60 {
            out.issues.append(.info("pickupDate", "Pickup date is more than 60 days from the document date."))
        }

        if out.stops.isEmpty {
            out.issues.append(.warning("stops", "No pickup or delivery locations were found."))
        } else {
            if out.pickups.isEmpty { out.issues.append(.warning("pickup", "No pickup stop was identified.")) }
            if out.deliveries.isEmpty { out.issues.append(.warning("delivery", "No delivery stop was identified.")) }
            if let explicit = out.stopCount.value, out.stopCount.confidence == .high, explicit != out.stops.count {
                out.issues.append(.info("stops", "The document lists \(explicit) stops; \(out.stops.count) were read."))
            }
        }
        if !out.loadNumber.isFound && !out.confirmationNumber.isFound {
            out.issues.append(.warning("loadNumber", "No load or confirmation number was found."))
        }
    }

    // MARK: Review rows

    static func reviewFields(_ r: RateConfirmationExtraction) -> [ReviewField] {
        var rows: [ReviewField] = []
        func add(_ key: String, _ label: String, _ v: ExtractedValue<String>) {
            rows.append(ReviewField(key: key, label: label, value: v.value ?? "", confidence: v.confidence, rawText: v.rawText))
        }
        func addMoney(_ key: String, _ label: String, _ v: ExtractedValue<Double>) {
            guard v.isFound else { return }
            rows.append(ReviewField(key: key, label: label, value: v.value.map(SmartText.money) ?? "", confidence: v.confidence, rawText: v.rawText))
        }
        func addDate(_ key: String, _ label: String, _ v: ExtractedValue<SimpleDate>) {
            rows.append(ReviewField(key: key, label: label, value: v.value?.usDisplay ?? "", confidence: v.confidence, rawText: v.rawText))
        }
        add("brokerName", "Broker", r.brokerName)
        add("brokerContact", "Broker contact", r.brokerContact)
        add("brokerPhone", "Broker phone", r.brokerPhone)
        add("brokerEmail", "Broker email", r.brokerEmail)
        add("loadNumber", "Load #", r.loadNumber)
        add("confirmationNumber", "Confirmation #", r.confirmationNumber)
        add("referenceNumber", "Reference #", r.referenceNumber)
        add("poNumber", "PO #", r.poNumber)
        add("carrierName", "Carrier", r.carrierName)
        if r.driverName.isFound { add("driverName", "Driver", r.driverName) }
        add("truckNumber", "Truck #", r.truckNumber)
        add("trailerNumber", "Trailer #", r.trailerNumber)
        for s in r.stops {
            let prefix = "stop\(s.id)"
            rows.append(ReviewField(key: prefix + ".place", label: "\(s.label) \(s.id)",
                                    value: [s.facility.value, s.fullAddress].compactMap { $0 }.joined(separator: " — "),
                                    confidence: min(s.city.confidence, s.facility.isFound ? s.facility.confidence : s.city.confidence),
                                    rawText: s.city.rawText ?? s.facility.rawText))
            rows.append(ReviewField(key: prefix + ".date", label: "\(s.label) \(s.id) date",
                                    value: [s.date.value?.usDisplay, s.appointment.value].compactMap { $0 }.joined(separator: " "),
                                    confidence: s.date.confidence, rawText: s.date.rawText))
        }
        add("commodity", "Commodity", r.commodity)
        rows.append(ReviewField(key: "weight", label: "Weight",
                                value: r.weightPounds.value.map { SmartText.trimNumber($0) + " lb" } ?? "",
                                confidence: r.weightPounds.confidence, rawText: r.weightPounds.rawText))
        if r.miles.isFound {
            rows.append(ReviewField(key: "miles", label: "Miles", value: r.miles.value.map(SmartText.trimNumber) ?? "",
                                    confidence: r.miles.confidence, rawText: r.miles.rawText))
        }
        addMoney("linehaul", "Linehaul", r.linehaul)
        addMoney("fuelSurcharge", "Fuel surcharge", r.fuelSurcharge)
        addMoney("detention", "Detention", r.detention)
        addMoney("layover", "Layover", r.layover)
        addMoney("tonu", "TONU", r.tonu)
        addMoney("lumper", "Lumper", r.lumper)
        addMoney("stopOff", "Stop-off", r.stopOff)
        addMoney("otherCharges", "Other charges", r.otherCharges)
        rows.append(ReviewField(key: "totalRate", label: "Total rate", value: r.totalRate.value.map(SmartText.money) ?? "",
                                confidence: r.totalRate.confidence, rawText: r.totalRate.rawText))
        _ = addDate
        return rows
    }
}
