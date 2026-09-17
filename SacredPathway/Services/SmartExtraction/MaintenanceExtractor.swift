import Foundation

// =============================================================================
// MARK: - Maintenance / repair document extraction
// =============================================================================

nonisolated enum MaintenanceCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case oilChange, pmService, tires, brakes, engine, transmission, electrical, coolingSystem, hvac,
         suspension, steering, alignment, dpfEmissions, defSystem, battery, trailerRepair, dotInspection,
         roadsideRepair, towing, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oilChange: return "Oil Change"
        case .pmService: return "PM Service"
        case .tires: return "Tires"
        case .brakes: return "Brakes"
        case .engine: return "Engine"
        case .transmission: return "Transmission"
        case .electrical: return "Electrical"
        case .coolingSystem: return "Cooling System"
        case .hvac: return "HVAC"
        case .suspension: return "Suspension"
        case .steering: return "Steering"
        case .alignment: return "Alignment"
        case .dpfEmissions: return "DPF / Emissions"
        case .defSystem: return "DEF System"
        case .battery: return "Battery"
        case .trailerRepair: return "Trailer Repair"
        case .dotInspection: return "DOT Inspection"
        case .roadsideRepair: return "Roadside Repair"
        case .towing: return "Towing"
        case .other: return "Other"
        }
    }

    /// Scheduled upkeep files as "maintenance"; fixing something broken as "repair".
    var expenseCategory: String {
        switch self {
        case .oilChange, .pmService, .tires, .alignment, .dotInspection, .battery: return "maintenance"
        default: return "repair"
        }
    }

    fileprivate var keywords: [(String, Int)] {
        switch self {
        case .oilChange: return [(#"oil\s+(?:and\s+filter\s+)?change|lube\s*,?\s*oil|\blof\b|engine\s+oil|oil\s+filter|15w-?40|10w-?30|drain\s+plug"#, 6)]
        case .pmService: return [(#"\bpm\s*(?:service|[abc]\b|level)|preventive\s+maintenance|preventative\s+maintenance|\bpm\s*-\s*[abc]\b|scheduled\s+maintenance|full\s+service|chassis\s+lube|grease\s+(?:job|chassis)"#, 9)]
        case .tires: return [(#"\btires?\b|\d{3}/\d{2}r\d{2}(?:\.\d)?|\bdrive\s+tire|\bsteer\s+tire|\bretread|mount\s+(?:and|&)\s+balance|\bflat\s+repair|\bvalve\s+stem"#, 7)]
        case .brakes: return [(#"\bbrakes?\b|brake\s+(?:shoes?|pads?|drums?|chambers?|linings?)|slack\s+adjuster|\bs-?cam\b|\brotors?\b|\bcalipers?\b"#, 7)]
        case .engine: return [(#"\bengine\b(?!\s+(?:oil|hours|hrs))|\bturbo(?:charger)?\b|\binjectors?\b|\bhead\s+gasket|valve\s+cover|\bcrankshaft|\bcamshaft|\begr\b|\boverhaul\b|\bcylinder|\bfuel\s+pump|\bfuel\s+filter|\bair\s+compressor"#, 6)]
        case .transmission: return [(#"\btransmission\b|\btrans\b(?!action)|\bclutch\b|\bdifferential\b|\bdriveline\b|\bu-?joints?\b|\bdrive\s+shaft|\bgear\s*box|\brear\s+end"#, 7)]
        case .electrical: return [(#"\belectrical\b|\bwiring\b|\balternator\b|\bstarter\b|\bfuse\b|\brelay\b|\blights?\b|\bheadlamps?\b|\bmarker\s+lamps?|\bharness\b|\bsensor\b|\becm\b"#, 5)]
        case .coolingSystem: return [(#"\bradiator\b|\bcoolant\b|\bantifreeze\b|\bwater\s+pump\b|\bthermostat\b|\bfan\s+clutch\b|\bcooling\s+system|\bheater\s+hose|\bcoolant\s+hose|\bhoses?\b"#, 7)]
        case .hvac: return [(#"\bhvac\b|\ba/?c\b(?:\s+(?:system|compressor|recharge))?|air\s+condition|\bheater\s+core\b|\bblower\s+motor\b|\brefrigerant\b|\bapu\b|\bbunk\s+heater\b"#, 7)]
        case .suspension: return [(#"\bsuspension\b|\bair\s+bags?\b|\bshocks?\b|\bleaf\s+springs?\b|\btorque\s+rods?\b|\bbushings?\b|\bhangers?\b|\bequalizer\b"#, 7)]
        case .steering: return [(#"\bsteering\b|\btie\s+rods?\b|\bdrag\s+link\b|\bking\s*pins?\b|\bpower\s+steering\b|\bsteering\s+gear\b|\bpitman\b"#, 7)]
        case .alignment: return [(#"\balignment\b|\balign\s+(?:front|all|axles?)|\btoe\s+(?:in|set)\b|\bcamber\b|\bcaster\b"#, 9)]
        case .dpfEmissions: return [(#"\bdpf\b|diesel\s+particulate|\bregen(?:eration)?\b|\bdoc\b|\bemissions?\b|\bscr\b|\bnox\s+sensor|\bexhaust\b(?!\s+fluid)|\bafter\s*treatment"#, 8)]
        case .defSystem: return [(#"\bdef\s+(?:pump|heater|sensor|doser|dosing|tank|system|line|filter|injector)|diesel\s+exhaust\s+fluid\s+(?:pump|system|heater)|\bdef\s+module"#, 10)]
        case .battery: return [(#"\bbatter(?:y|ies)\b|\bjump\s+start|\bcharging\s+system|\bterminals?\b"#, 7)]
        case .trailerRepair: return [(#"\btrailer\b|\breefer\s+unit\b|\bthermo\s*king\b|\bcarrier\s+transicold\b|\bswing\s+doors?\b|\broll\s*-?\s*up\s+door|\blanding\s+gear\b|\bmudflaps?\b|\bfloor\s+repair|\bsidewall|\bkingpin\b"#, 6)]
        case .dotInspection: return [(#"\bdot\s+inspection|\bannual\s+inspection|\bfederal\s+inspection|\bperiodic\s+inspection|\binspection\s+sticker|\bfmcsa\s+inspection|\b396\.17\b"#, 12)]
        case .roadsideRepair: return [(#"\broad\s*-?\s*(?:side|service|call)\b|\bmobile\s+(?:repair|service|mechanic)|\bservice\s+call\b|\bon[\s-]?site\s+repair|\bbreakdown\b|\bemergency\s+service"#, 9)]
        case .towing: return [(#"\btow(?:ing|ed)?\b|\bwrecker\b|\brecovery\b|\bwinch(?:ing)?\b|\bhook\s*-?\s*up\s+fee|\bper\s+mile\s+tow"#, 11)]
        case .other: return []
        }
    }
}

nonisolated struct MaintenanceExtraction: Codable, Sendable, Equatable {
    var documentKind: SmartDocumentKind = .maintenanceInvoice
    var shopName: ExtractedValue<String> = .missing
    var shopAddress: ExtractedValue<String> = .missing
    var shopCity: ExtractedValue<String> = .missing
    var shopState: ExtractedValue<String> = .missing
    var shopZip: ExtractedValue<String> = .missing
    var shopPhone: ExtractedValue<String> = .missing
    var invoiceNumber: ExtractedValue<String> = .missing
    var repairOrderNumber: ExtractedValue<String> = .missing
    var serviceDate: ExtractedValue<SimpleDate> = .missing
    var invoiceDate: ExtractedValue<SimpleDate> = .missing
    var unitNumber: ExtractedValue<String> = .missing
    var vin: ExtractedValue<String> = .missing
    var licensePlate: ExtractedValue<String> = .missing
    var odometer: ExtractedValue<Double> = .missing
    var engineHours: ExtractedValue<Double> = .missing
    var technician: ExtractedValue<String> = .missing
    var category: ExtractedValue<MaintenanceCategory> = .missing
    var otherCategories: [MaintenanceCategory] = []
    var workPerformed: [String] = []
    var parts: [ExtractedLineItem] = []
    var labor: [ExtractedLineItem] = []
    var fees: [ExtractedLineItem] = []
    var laborHours: ExtractedValue<Double> = .missing
    var laborRate: ExtractedValue<Double> = .missing
    var laborTotal: ExtractedValue<Double> = .missing
    var partsSubtotal: ExtractedValue<Double> = .missing
    var shopSupplies: ExtractedValue<Double> = .missing
    var environmentalFees: ExtractedValue<Double> = .missing
    var otherFees: ExtractedValue<Double> = .missing
    var tax: ExtractedValue<Double> = .missing
    var discount: ExtractedValue<Double> = .missing
    var subtotal: ExtractedValue<Double> = .missing
    var total: ExtractedValue<Double> = .missing
    var recommendations: [String] = []
    var nextServiceMileage: ExtractedValue<Double> = .missing
    var nextServiceDate: ExtractedValue<SimpleDate> = .missing
    var issues: [ExtractionIssue] = []

    /// The expense-level category ("maintenance" or "repair").
    var expenseCategory: String {
        if documentKind == .partsReceipt, category.value == nil { return "maintenance" }
        return category.value?.expenseCategory ?? "repair"
    }

    var bestDate: ExtractedValue<SimpleDate> { serviceDate.isFound ? serviceDate : invoiceDate }

    var allLineItems: [ExtractedLineItem] { parts + labor + fees }

    var descriptionText: String {
        var parts: [String] = []
        if let c = category.value, c != .other { parts.append(c.displayName) }
        if let w = workPerformed.first { parts.append(w) }
        if let u = unitNumber.value { parts.append("Unit " + u) }
        if let o = odometer.value { parts.append("Odo " + SmartText.trimNumber(o)) }
        if let inv = invoiceNumber.value { parts.append("Inv " + inv) }
        if let ro = repairOrderNumber.value { parts.append("RO " + ro) }
        let itemCount = self.parts.count + labor.count
        if itemCount > 0 { parts.append("\(self.parts.count) part line\(self.parts.count == 1 ? "" : "s"), \(labor.count) labor") }
        return parts.joined(separator: " · ")
    }
}

nonisolated enum MaintenanceExtractor {

    static let shopBrands: [(String, String)] = [
        (#"rush\s+truck"#, "Rush Truck Centers"), (#"ta\s+truck\s+service"#, "TA Truck Service"),
        (#"love'?s\s+truck\s+care|speedco"#, "Love's Truck Care / Speedco"), (#"petro\s+lube"#, "Petro Lube"),
        (#"fleetpride"#, "FleetPride"), (#"truckpro"#, "TruckPro"), (#"southern\s+tire\s+mart"#, "Southern Tire Mart"),
        (#"boss\s+shop"#, "Boss Shop"), (#"goodyear"#, "Goodyear"), (#"bridgestone|firestone"#, "Bridgestone"),
        (#"michelin"#, "Michelin"), (#"freightliner"#, "Freightliner"), (#"kenworth"#, "Kenworth"),
        (#"peterbilt"#, "Peterbilt"), (#"volvo"#, "Volvo"), (#"mack\b"#, "Mack"), (#"international|navistar"#, "International"),
        (#"cummins"#, "Cummins"), (#"thermo\s*king"#, "Thermo King"), (#"carrier\s+transicold"#, "Carrier Transicold")
    ]

    static func extract(_ document: DocumentText, kind: SmartDocumentKind = .maintenanceInvoice) -> MaintenanceExtraction {
        let lines = document.lines
        var out = MaintenanceExtraction()
        out.documentKind = kind
        extractShop(&out, lines: lines)
        extractIdentifiers(&out, lines: lines)
        extractVehicle(&out, lines: lines)
        extractItems(&out, lines: lines)
        extractTotals(&out, lines: lines)
        extractNotes(&out, lines: lines)
        classify(&out, text: document.joined)
        validate(&out)
        return out
    }

    // MARK: Shop

    private static func extractShop(_ out: inout MaintenanceExtraction, lines: [DocLine]) {
        let top = Array(lines.prefix(10))
        if let l = top.first(where: { ReceiptExtractor.isMerchantLine($0.text) && !SmartText.contains(#"^(service|repair|work|parts?)\s+(invoice|order)|^invoice|^estimate|^customer"#, in: $0.text) }) {
            // Keep the printed name ("Rush Truck Centers - Oklahoma City").
            let known = shopBrands.contains { SmartText.contains($0.0, in: l.text) }
            out.shopName = ExtractedValue(SmartText.trimPunctuation(l.text), known ? .high : .medium, raw: l.text, page: l.page)
        }
        for l in top {
            if !out.shopAddress.isFound, SmartText.isStreetAddress(l.text) {
                let street = l.text.components(separatedBy: ",").first ?? l.text
                out.shopAddress = ExtractedValue(SmartText.trimPunctuation(street), .high, raw: l.text, page: l.page)
            }
            if !out.shopCity.isFound, let c = SmartText.cityStateZip(in: l.text) {
                let conf: ExtractionConfidence = c.zip != nil ? .high : .medium
                out.shopCity = ExtractedValue(c.city, conf, raw: l.text, page: l.page)
                out.shopState = ExtractedValue(c.state, conf, raw: l.text, page: l.page)
                if let z = c.zip { out.shopZip = ExtractedValue(z, .high, raw: l.text, page: l.page) }
            }
            if !out.shopPhone.isFound, let p = SmartText.phone(in: l.text) {
                out.shopPhone = ExtractedValue(p.number, .high, raw: l.text, page: l.page)
            }
        }
    }

    // MARK: Numbers and dates

    private static let stopLabels = ["invoice", "repair order", "ro", "work order", "date", "service date", "unit", "vin",
                                     "odometer", "mileage", "engine hours", "technician", "tech", "license plate", "plate",
                                     "po", "customer", "phone", "invoice date", "miles", "hours", "truck"]

    private static func extractIdentifiers(_ out: inout MaintenanceExtraction, lines: [DocLine]) {
        let clean = lines.filter { !SmartText.contains(#"\b(auth|approval|card|acct|account|customer\s*#|cust\s*#|po\s*#)"#, in: $0.text) }
        if let hit = SmartText.firstLabeled(["invoice number", "invoice #", "invoice no", "invoice"], in: clean,
                                            stopLabels: stopLabels, lookahead: 1,
                                            accept: { ReceiptExtractor.identifierAfterLabel($0) != nil && !SmartText.contains(#"^(date|total)\b"#, in: $0) }),
           let id = ReceiptExtractor.identifierAfterLabel(hit.value) {
            out.invoiceNumber = ExtractedValue(id, hit.sameLine ? .high : .medium, raw: hit.rawLine, page: hit.page)
        }
        if let hit = SmartText.firstLabeled(["repair order number", "repair order #", "repair order", "r.o. #", "ro #", "ro number",
                                             "work order #", "work order number", "work order", "w.o. #", "wo #", "service order #", "service order"],
                                            in: clean, stopLabels: stopLabels, lookahead: 1,
                                            accept: { ReceiptExtractor.identifierAfterLabel($0) != nil }),
           let id = ReceiptExtractor.identifierAfterLabel(hit.value) {
            out.repairOrderNumber = ExtractedValue(id, hit.sameLine ? .high : .medium, raw: hit.rawLine, page: hit.page)
        }

        let dateAccept: (String) -> Bool = { SmartText.firstDate(in: $0) != nil }
        if let hit = SmartText.firstLabeled(["service date", "date of service", "date in", "repair date", "date completed", "completed", "work date"],
                                            in: lines, stopLabels: stopLabels, lookahead: 1, accept: dateAccept),
           let t = SmartText.firstDate(in: hit.value) {
            out.serviceDate = ExtractedValue(t.date, t.ambiguous ? .low : .high, raw: hit.rawLine, page: hit.page)
        }
        let invoiceDateLines = lines.filter { !SmartText.contains(#"next\s+service|due\s+(?:date|by)|recommend|service\s+date|date\s+of\s+service|date\s+in\b|expir"#, in: $0.text) }
        if let hit = SmartText.firstLabeled(["invoice date", "billing date", "bill date"], in: lines, stopLabels: stopLabels, lookahead: 1, accept: dateAccept),
           let t = SmartText.firstDate(in: hit.value) {
            out.invoiceDate = ExtractedValue(t.date, t.ambiguous ? .low : .high, raw: hit.rawLine, page: hit.page)
        } else if let hit = SmartText.firstLabeled(["date"], in: invoiceDateLines, stopLabels: stopLabels, lookahead: 1, accept: dateAccept),
           let t = SmartText.firstDate(in: hit.value) {
            out.invoiceDate = ExtractedValue(t.date, t.ambiguous ? .low : .medium, raw: hit.rawLine, page: hit.page)
        } else if !out.serviceDate.isFound,
                  let l = invoiceDateLines.first(where: { SmartText.firstDate(in: $0.text) != nil }),
                  let t = SmartText.firstDate(in: l.text) {
            out.invoiceDate = ExtractedValue(t.date, .low, raw: l.text, page: l.page)
        }
    }

    // MARK: Vehicle

    static func isValidVIN(_ vin: String) -> Bool {
        let v = vin.uppercased()
        guard v.count == 17, v.range(of: #"^[A-HJ-NPR-Z0-9]{17}$"#, options: .regularExpression) != nil else { return false }
        let map: [Character: Int] = [
            "A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6, "G": 7, "H": 8, "J": 1, "K": 2, "L": 3, "M": 4, "N": 5,
            "P": 7, "R": 9, "S": 2, "T": 3, "U": 4, "V": 5, "W": 6, "X": 7, "Y": 8, "Z": 9
        ]
        let weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]
        var sum = 0
        for (i, c) in v.enumerated() {
            let value = c.isNumber ? Int(String(c))! : (map[c] ?? 0)
            sum += value * weights[i]
        }
        let check = sum % 11
        let expected: Character = check == 10 ? "X" : Character(String(check))
        return Array(v)[8] == expected
    }

    private static func extractVehicle(_ out: inout MaintenanceExtraction, lines: [DocLine]) {
        for l in lines {
            for m in SmartText.matches(#"\b([A-HJ-NPR-Z0-9]{17})\b"#, in: l.text) {
                guard let v = SmartText.captures(m, in: l.text)[1]?.uppercased(),
                      v.contains(where: \.isLetter), v.contains(where: \.isNumber) else { continue }
                let labeled = SmartText.contains(#"\bvin\b|serial"#, in: l.text)
                guard labeled || isValidVIN(v) else { continue }
                let conf: ExtractionConfidence = isValidVIN(v) ? .high : .medium
                out.vin = ExtractedValue(v, conf, raw: l.text, page: l.page)
                if !isValidVIN(v) {
                    out.issues.append(.info("vin", "The VIN check digit does not match (non-North-American VIN or a misread character)."))
                }
                break
            }
            if out.vin.isFound { break }
        }

        let unitAccept: (String) -> Bool = { v in
            guard let first = v.split(separator: " ").first else { return false }
            let s = SmartText.trimPunctuation(String(first))
            return (1...12).contains(s.count) && s.contains(where: \.isNumber) && SmartText.moneyTokens(in: s).isEmpty
                && !SmartText.contains(#"^(price|cost|of)\b"#, in: v)
        }
        let unitLines = lines.filter { !SmartText.contains(#"unit\s+(?:price|cost)|per\s+unit"#, in: $0.text) }
        if let hit = SmartText.firstLabeled(["unit number", "unit #", "unit no", "unit", "truck #", "truck number", "truck", "tractor #",
                                             "tractor", "fleet #", "fleet number", "vehicle #", "vehicle id", "equipment #", "trailer #"],
                                            in: unitLines, stopLabels: stopLabels, lookahead: 0, midLineNeedsSeparator: false, accept: unitAccept) {
            let v = SmartText.trimPunctuation(String(hit.value.split(separator: " ")[0])).uppercased()
            out.unitNumber = ExtractedValue(v, hit.sameLine ? .high : .medium, raw: hit.rawLine, page: hit.page)
        }
        if let hit = SmartText.firstLabeled(["license plate", "license #", "plate number", "plate #", "plate", "lic #", "tag #", "tag number"],
                                            in: lines, stopLabels: stopLabels, lookahead: 0,
                                            accept: { v in
                                                let s = SmartText.trimPunctuation(v)
                                                return (2...16).contains(s.count) && s.contains(where: \.isNumber)
                                            }) {
            out.licensePlate = ExtractedValue(SmartText.trimPunctuation(hit.value).uppercased(), .medium, raw: hit.rawLine, page: hit.page)
        }
        let odoLines = lines.filter { !SmartText.contains(#"next\s+service|due\s+(?:at|in)|within|recommend|every\s+\d|interval"#, in: $0.text) }
        if let hit = SmartText.firstLabeled(["odometer in", "odometer", "mileage in", "miles in", "mileage", "odo", "hubometer", "hub miles", "miles"],
                                            in: odoLines, stopLabels: stopLabels, lookahead: 0, midLineNeedsSeparator: false,
                                            accept: { v in (SmartText.numbers(in: v).first.map { $0.start <= 1 && $0.value >= 100 && $0.value < 5_000_000 }) ?? false }),
           let n = SmartText.numbers(in: hit.value).first {
            out.odometer = ExtractedValue(n.value, hit.sameLine ? .high : .medium, raw: hit.rawLine, page: hit.page)
        }
        if let hit = SmartText.firstLabeled(["engine hours", "eng hours", "eng hrs", "engine hrs", "hour meter", "hours meter"],
                                            in: lines, stopLabels: stopLabels, lookahead: 0, midLineNeedsSeparator: false,
                                            accept: { v in (SmartText.numbers(in: v).first.map { $0.start <= 1 && $0.value >= 1 && $0.value < 500_000 }) ?? false }),
           let n = SmartText.numbers(in: hit.value).first {
            out.engineHours = ExtractedValue(n.value, .high, raw: hit.rawLine, page: hit.page)
        }
        if let hit = SmartText.firstLabeled(["technician", "tech name", "tech #", "tech", "mechanic", "serviced by", "performed by"],
                                            in: lines, stopLabels: stopLabels, lookahead: 0,
                                            accept: { v in
                                                let s = SmartText.trimPunctuation(v)
                                                return s.filter(\.isLetter).count >= 2 && s.count <= 30 && SmartText.moneyTokens(in: s).isEmpty
                                            }) {
            out.technician = ExtractedValue(SmartText.trimPunctuation(hit.value), .medium, raw: hit.rawLine, page: hit.page)
        }
    }

    // MARK: Items

    private enum Section { case none, parts, labor, fees }

    private static func extractItems(_ out: inout MaintenanceExtraction, lines: [DocLine]) {
        var section = Section.none
        var nextID = 1
        for l in lines {
            let t = SmartText.stripLeaders(l.text)
            // Section headers.
            if SmartText.contains(#"^\s*(parts?|materials?)\s*(?:used|detail|list)?\s*:?\s*$"#, in: t)
                || SmartText.contains(#"\b(part\s*(?:#|no\.?|number)|p/n)\b.*\b(desc|description)\b"#, in: t)
                || SmartText.contains(#"^\s*qty\s+desc(?:ription)?\b.*\b(price|total|amount)\b"#, in: t) {
                section = .parts
                continue
            }
            if SmartText.contains(#"^\s*(labou?r|services?\s+performed|work\s+performed|operations?)\s*(?:detail|charges)?\s*:?\s*$"#, in: t) {
                section = .labor
                continue
            }
            if SmartText.contains(#"^\s*(fees|misc(?:ellaneous)?|other\s+charges)\s*:?\s*$"#, in: t) {
                section = .fees
                continue
            }
            let role = LineItemParser.role(for: t)
            if let role {
                switch role {
                case .environmental, .shopSupplies, .fee:
                    if var item = LineItemParser.parseItem(l, id: nextID, defaultKind: .fee) {
                        item.kind = .fee
                        out.fees.append(item); nextID += 1
                    }
                    continue
                default:
                    // Totals end an item section.
                    if [.subtotal, .total, .partsSubtotal, .laborSubtotal, .tax].contains(role) { section = .none }
                    continue
                }
            }
            guard !SmartText.moneyTokens(in: t).isEmpty else { continue }
            let isLaborLine = SmartText.contains(#"\blabou?r\b|\d(?:\.\d+)?\s*(?:hr|hrs|hours)\b\.?\s*(?:x|@|×|at)"#, in: t)
            let kind: ExtractedLineItem.Kind = isLaborLine || section == .labor ? .labor : (section == .fees ? .fee : .part)
            guard var item = LineItemParser.parseItem(l, id: nextID, defaultKind: kind) else { continue }
            if SmartText.contains(#"^\s*parts?\s*[:\-]\s*"#, in: t) {
                item.kind = .part
                item.description = SmartText.trimPunctuation(SmartText.replacing(#"^\s*parts?\s*[:\-]\s*"#, in: item.description, with: ""))
            }
            switch item.kind {
            case .labor:
                if item.description.lowercased().hasPrefix("labor") || item.description.lowercased().hasPrefix("labour") {
                    let cleaned = SmartText.trimPunctuation(SmartText.replacing(#"(?i)\s*-?\s*labou?r\s*$|^labou?r\s*[:\-]?\s*"#, in: item.description, with: ""))
                    if !cleaned.isEmpty { item.description = cleaned }
                }
                // "Replace air line - labor 1 hr @ 165.00" → description before "labor".
                item.description = SmartText.trimPunctuation(SmartText.replacing(#"(?i)\s*-?\s*labou?r\s*$"#, in: item.description, with: ""))
                out.labor.append(item)
            case .fee:
                out.fees.append(item)
            case .discount:
                out.fees.append(item)
            default:
                item.kind = .part
                out.parts.append(item)
            }
            nextID += 1
        }

        // Work performed: labor descriptions + "Correction:" / "Work performed:" text.
        var work = out.labor.map(\.description).filter { !$0.isEmpty && $0.lowercased() != "labor" }
        for hit in SmartText.findLabeled(["work performed", "correction", "repairs performed", "service performed", "description of work", "complaint", "cause"],
                                         in: lines, lookahead: 1, requireLineStart: true, accept: { $0.filter(\.isLetter).count >= 4 }) {
            let v = SmartText.trimPunctuation(hit.value)
            if !work.contains(v) { work.append((hit.label == "complaint" ? "Complaint: " : "") + v) }
        }
        if work.isEmpty {
            work = out.parts.prefix(3).map(\.description)
        }
        out.workPerformed = work

        let hours = out.labor.compactMap(\.hours)
        if !hours.isEmpty {
            let conf = out.labor.map(\.confidence).min() ?? .medium
            out.laborHours = ExtractedValue((hours.reduce(0, +) * 100).rounded() / 100, conf)
        }
        let rates = Set(out.labor.compactMap(\.rate))
        if rates.count == 1, let r = rates.first {
            out.laborRate = ExtractedValue(r, out.labor.map(\.confidence).min() ?? .medium)
        } else if rates.count > 1 {
            out.issues.append(.info("laborRate", "Labor is billed at more than one rate."))
        }
    }

    // MARK: Totals

    private static func extractTotals(_ out: inout MaintenanceExtraction, lines: [DocLine]) {
        let amounts = LineItemParser.amountLines(lines)
        out.partsSubtotal = LineItemParser.pick(.partsSubtotal, from: amounts)
        out.laborTotal = LineItemParser.pick(.laborSubtotal, from: amounts)
        out.shopSupplies = LineItemParser.sum(.shopSupplies, from: amounts)
        out.environmentalFees = LineItemParser.sum(.environmental, from: amounts)
        out.otherFees = LineItemParser.sum(.fee, from: amounts)
        out.tax = LineItemParser.sum(.tax, from: amounts)
        out.discount = LineItemParser.sum(.discount, from: amounts)
        out.subtotal = LineItemParser.pick(.subtotal, from: amounts)
        out.total = LineItemParser.pick(.total, from: amounts)
        if !out.laborTotal.isFound, !out.labor.isEmpty {
            let s = out.labor.compactMap(\.amount).reduce(0, +)
            // Derived from printed line amounts, so it is a reading, not a guess — but review it.
            out.laborTotal = ExtractedValue((s * 100).rounded() / 100, .medium)
        }
        if !out.total.isFound, let pay = amounts.last(where: { $0.role == .payment }) {
            out.total = ExtractedValue(abs(pay.token.value), .medium, raw: pay.line.text, page: pay.line.page)
        }
    }

    // MARK: Notes

    private static func extractNotes(_ out: inout MaintenanceExtraction, lines: [DocLine]) {
        for l in lines where SmartText.contains(#"\brecommend(?:ed|ation)?s?\b|\badvis(?:e|ed)\b|\bcustomer\s+declined\b|\bsuggest(?:ed)?\b|\bshould\s+be\s+replaced\b"#, in: l.text)
            && !SmartText.contains(#"^\s*(complaint|cause|concern)\b"#, in: l.text) {
            let v = SmartText.trimPunctuation(SmartText.replacing(#"(?i)^\s*(recommend(?:ed|ations?)?|advis(?:e|ed)|notes?)\s*[:\-]\s*"#, in: l.text, with: ""))
            if !v.isEmpty && !out.recommendations.contains(v) { out.recommendations.append(v) }
        }
        for l in lines where SmartText.contains(#"next\s+(?:service|pm|oil\s+change|inspection)|service\s+due\s+(?:at|in|by|on)\b|due\s+(?:at|by)\s+\d"#, in: l.text)
            && !SmartText.contains(#"^\s*(complaint|cause|concern)\b"#, in: l.text) {
            if !out.nextServiceMileage.isFound,
               let g = SmartText.groups(#"(\d{1,3}(?:,\d{3})+|\d{4,7})\s*(?:mi|miles|km)?\b"#, in: SmartText.replacing(#"\d{1,2}[/-]\d{1,2}[/-]\d{2,4}"#, in: l.text, with: " ")),
               let v = Double((g[1] ?? "").replacingOccurrences(of: ",", with: "")), v >= 1000 {
                out.nextServiceMileage = ExtractedValue(v, .high, raw: l.text, page: l.page)
            }
            if !out.nextServiceDate.isFound, let t = SmartText.firstDate(in: l.text) {
                out.nextServiceDate = ExtractedValue(t.date, .high, raw: l.text, page: l.page)
            }
            let v = SmartText.trimPunctuation(l.text)
            if !out.recommendations.contains(v) { out.recommendations.append(v) }
        }
    }

    // MARK: Category

    private static func classify(_ out: inout MaintenanceExtraction, text: String) {
        var scores: [(MaintenanceCategory, Int)] = []
        let weightedText = ([text] + out.workPerformed + out.parts.map(\.description) + out.labor.map(\.description)).joined(separator: "\n")
        for c in MaintenanceCategory.allCases where c != .other {
            var s = 0
            for (pattern, weight) in c.keywords {
                let hits = SmartText.matches(pattern, in: weightedText).count
                if hits > 0 { s += weight + min(hits - 1, 4) * 2 }
            }
            if s > 0 { scores.append((c, s)) }
        }
        scores.sort { $0.1 > $1.1 }
        // A PM service normally includes an oil change; prefer the PM label.
        if let pm = scores.firstIndex(where: { $0.0 == .pmService }), let oil = scores.firstIndex(where: { $0.0 == .oilChange }), oil < pm {
            scores.swapAt(oil, pm)
        }
        guard let best = scores.first else {
            out.category = ExtractedValue(.other, .low)
            return
        }
        let second = scores.count > 1 ? scores[1].1 : 0
        let conf: ExtractionConfidence = best.1 >= 12 && best.1 - second >= 4 ? .high : (best.1 >= 7 ? .medium : .low)
        out.category = ExtractedValue(best.0, conf)
        out.otherCategories = scores.dropFirst().prefix(3).map(\.0)
    }

    // MARK: Validation

    private static func validate(_ out: inout MaintenanceExtraction) {
        let partsSum = out.parts.compactMap(\.amount).reduce(0, +)
        let laborSum = out.labor.compactMap(\.amount).reduce(0, +)
        if let ps = out.partsSubtotal.value, !out.parts.isEmpty {
            if SmartText.approxEqual(partsSum, ps, tolerance: 0.05) {
                for i in out.parts.indices where out.parts[i].confidence == .medium { out.parts[i].confidence = .high }
            } else {
                out.issues.append(.warning("parts", "Part lines add up to \(SmartText.money(partsSum)) but the parts subtotal is \(SmartText.money(ps))."))
                for i in out.parts.indices { out.parts[i].confidence = min(out.parts[i].confidence, .medium) }
            }
        }
        if let lt = out.laborTotal.value, out.laborTotal.confidence == .high, !out.labor.isEmpty,
           !SmartText.approxEqual(laborSum, lt, tolerance: 0.05) {
            out.issues.append(.warning("labor", "Labor lines add up to \(SmartText.money(laborSum)) but labor total is \(SmartText.money(lt))."))
        }
        for item in out.labor where item.confidence == .low {
            out.issues.append(.warning("labor", "Labor line \"\(item.description)\": hours × rate does not match the amount."))
        }

        guard let total = out.total.value else {
            out.issues.append(.warning("total", "No invoice total was found. Enter the amount."))
            return
        }
        let fees = (out.shopSupplies.value ?? 0) + (out.environmentalFees.value ?? 0) + (out.otherFees.value ?? 0)
        let pieces = (out.partsSubtotal.value ?? partsSum) + (out.laborTotal.value ?? laborSum) + fees
        let tax = out.tax.value ?? 0
        let discount = out.discount.value ?? 0
        var consistent = false
        if let sub = out.subtotal.value {
            if SmartText.approxEqual(sub + tax - discount, total) || SmartText.approxEqual(sub + tax, total) {
                consistent = true
            } else {
                out.issues.append(.warning("total", "Subtotal \(SmartText.money(sub)) + tax \(SmartText.money(tax)) does not equal the total \(SmartText.money(total))."))
                out.total = out.total.downgraded()
            }
            if pieces > 0, !SmartText.approxEqual(pieces - discount, sub, tolerance: 0.05), !SmartText.approxEqual(pieces, sub, tolerance: 0.05) {
                out.issues.append(.info("subtotal", "Parts + labor + fees (\(SmartText.money(pieces))) differ from the subtotal \(SmartText.money(sub))."))
            }
        } else if pieces > 0 {
            if SmartText.approxEqual(pieces + tax - discount, total, tolerance: 0.05) {
                consistent = true
            } else {
                out.issues.append(.info("total", "Parts + labor + fees + tax come to \(SmartText.money(pieces + tax - discount)); the total is \(SmartText.money(total))."))
            }
        }
        if consistent, out.total.confidence == .medium { out.total.confidence = .high }
        if total <= 0 || total > 100_000 {
            out.issues.append(.warning("total", "The total \(SmartText.money(total)) looks unusual."))
            out.total = out.total.downgraded()
        }
        if let s = out.serviceDate.value, let i = out.invoiceDate.value, s.days(to: i) < -1 {
            out.issues.append(.warning("serviceDate", "Service date is after the invoice date."))
            out.serviceDate = out.serviceDate.downgraded()
        }
        if let o = out.odometer.value, let n = out.nextServiceMileage.value, n <= o {
            out.issues.append(.info("nextServiceMileage", "Next-service mileage is not above the current odometer."))
            out.nextServiceMileage = out.nextServiceMileage.downgraded()
        }
    }

    // MARK: Review rows

    static func reviewFields(_ r: MaintenanceExtraction) -> [ReviewField] {
        var rows: [ReviewField] = []
        func add(_ key: String, _ label: String, _ v: ExtractedValue<String>, always: Bool = true) {
            guard always || v.isFound else { return }
            rows.append(ReviewField(key: key, label: label, value: v.value ?? "", confidence: v.confidence, rawText: v.rawText))
        }
        func money(_ key: String, _ label: String, _ v: ExtractedValue<Double>, always: Bool = false) {
            guard always || v.isFound else { return }
            rows.append(ReviewField(key: key, label: label, value: v.value.map(SmartText.money) ?? "", confidence: v.confidence, rawText: v.rawText))
        }
        func number(_ key: String, _ label: String, _ v: ExtractedValue<Double>, always: Bool = false) {
            guard always || v.isFound else { return }
            rows.append(ReviewField(key: key, label: label, value: v.value.map(SmartText.trimNumber) ?? "", confidence: v.confidence, rawText: v.rawText))
        }
        add("vendorName", "Shop", r.shopName)
        if r.shopCity.isFound {
            rows.append(ReviewField(key: "shopLocation", label: "Shop location",
                                    value: [r.shopAddress.value, [r.shopCity.value, r.shopState.value].compactMap { $0 }.joined(separator: ", ")].compactMap { $0 }.joined(separator: ", "),
                                    confidence: r.shopCity.confidence, rawText: r.shopCity.rawText))
        }
        add("shopPhone", "Shop phone", r.shopPhone, always: false)
        add("invoiceNumber", "Invoice #", r.invoiceNumber)
        add("repairOrderNumber", "Repair order #", r.repairOrderNumber, always: false)
        rows.append(ReviewField(key: "receiptDate", label: r.serviceDate.isFound ? "Service date" : "Invoice date",
                                value: r.bestDate.value?.usDisplay ?? "", confidence: r.bestDate.confidence, rawText: r.bestDate.rawText))
        add("unitNumber", "Unit #", r.unitNumber)
        add("vin", "VIN", r.vin, always: false)
        add("licensePlate", "Plate", r.licensePlate, always: false)
        number("odometer", "Odometer", r.odometer, always: true)
        number("engineHours", "Engine hours", r.engineHours)
        add("technician", "Technician", r.technician, always: false)
        rows.append(ReviewField(key: "maintenanceCategory", label: "Maintenance type", value: r.category.value?.displayName ?? "",
                                confidence: r.category.confidence, rawText: nil))
        money("partsSubtotal", "Parts", r.partsSubtotal)
        number("laborHours", "Labor hours", r.laborHours)
        money("laborRate", "Labor rate", r.laborRate)
        money("laborTotal", "Labor", r.laborTotal)
        money("shopSupplies", "Shop supplies", r.shopSupplies)
        money("environmentalFees", "Environmental fees", r.environmentalFees)
        money("otherFees", "Other fees", r.otherFees)
        money("discount", "Discounts", r.discount)
        money("subtotal", "Subtotal", r.subtotal)
        money("tax", "Tax", r.tax)
        money("amount", "Invoice total", r.total, always: true)
        number("nextServiceMileage", "Next service (mi)", r.nextServiceMileage)
        if r.nextServiceDate.isFound {
            rows.append(ReviewField(key: "nextServiceDate", label: "Next service date", value: r.nextServiceDate.value?.usDisplay ?? "",
                                    confidence: r.nextServiceDate.confidence, rawText: r.nextServiceDate.rawText))
        }
        return rows
    }
}
