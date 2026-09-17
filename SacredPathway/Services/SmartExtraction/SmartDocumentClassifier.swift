import Foundation

// =============================================================================
// MARK: - Document classification (content-based, never filename-based)
// =============================================================================

nonisolated struct DocumentClassification: Codable, Sendable, Equatable {
    var kind: SmartDocumentKind
    var confidence: ExtractionConfidence
    /// Score per kind (for debugging and the "choose type" picker order).
    var scores: [String: Int]
    var reasons: [String]

    /// True when the app should ask the user which kind this is.
    var needsUserChoice: Bool { kind == .unknown || confidence == .low }

    /// Kinds ordered by score, best first (for the picker).
    var rankedKinds: [SmartDocumentKind] {
        SmartDocumentKind.allCases
            .filter { $0 != .unknown }
            .sorted { (scores[$0.rawValue] ?? 0) > (scores[$1.rawValue] ?? 0) }
    }
}

nonisolated enum SmartDocumentClassifier {

    private struct Signal {
        let pattern: String
        let weight: Int
    }

    private static let rateCon: [Signal] = [
        Signal(pattern: #"rate\s*con(?:firmation)?\b|\bload\s+confirmation|carrier\s+(?:rate\s+)?confirmation|load\s+tender|rate\s+agreement|carrier\s+agreement"#, weight: 14),
        Signal(pattern: #"total\s+carrier\s+pay|carrier\s+(?:freight\s+)?pay|agreed\s+(?:upon\s+)?rate|carrier\s+rate|total\s+rate"#, weight: 8),
        Signal(pattern: #"\bline\s*haul\b|\blinehaul\b|\bfsc\b|fuel\s+surcharge"#, weight: 4),
        Signal(pattern: #"\bshipper\b|\bconsignee\b|\breceiver\b"#, weight: 4),
        Signal(pattern: #"\bpick\s*-?\s*up\b|\bpu\s*#?\s*\d\b|\borigin\b"#, weight: 3),
        Signal(pattern: #"\bdeliver(?:y)?\b|\bdel\s*#?\s*\d\b|\bdestination\b|\bdrop\b"#, weight: 3),
        Signal(pattern: #"\bbroker\b|\bmc\s*#|\bdot\s*#|\bdispatch(?:er)?\b"#, weight: 3),
        Signal(pattern: #"\bload\s*(?:#|no\.?|number|id)\b"#, weight: 4),
        Signal(pattern: #"\bcommodity\b|\bequipment\b|\breefer\b|\bdry\s+van\b|\bflatbed\b"#, weight: 3),
        Signal(pattern: #"\bdetention\b|\blayover\b|\btonu\b|truck\s+order\s+not\s+used|\blumper\b"#, weight: 2),
        Signal(pattern: #"\btracking\b|\bcheck\s+calls?\b|\bmacropoint\b|\btrucker\s+tools\b|\bquick\s*pay\b|\bfactoring\b"#, weight: 3)
    ]

    private static let fuel: [Signal] = [
        Signal(pattern: #"\bdiesel\b|\bulsd\b|#2\s*diesel|\bdsl\b|\breefer\s+fuel\b|\bbiodiesel\b|\bb\d{1,2}\b"#, weight: 10),
        Signal(pattern: #"\bgal(?:lons?|s)?\b|\bppg\b|price\s*/\s*gal|\$?/\s*gal\b|\bpump\s*#?\s*\d+"#, weight: 8),
        Signal(pattern: #"\bdef\b|diesel\s+exhaust"#, weight: 3),
        Signal(pattern: #"pilot|flying\s*j|love'?s|\bta\b|travel\s*centers?|petro\b|speedway|ambest|sapp\s*bros|kwik\s*trip|casey'?s|road\s*ranger|bosselman|\bqt\b|quiktrip|circle\s*k|sheetz|wawa|buc-?ee'?s|maverik|town\s*pump|one9|stuckey"#, weight: 5),
        Signal(pattern: #"\bunleaded\b|\bregular\b|\bpremium\b|\bfuel\b"#, weight: 3),
        Signal(pattern: #"\bodometer\b|\bodo\b|\bunit\s*#?|\btruck\s*#|\bhubometer\b|\btrip\s*#"#, weight: 2),
        Signal(pattern: #"\bcomdata\b|\befs\b|\bwex\b|\bt-?chek\b|\bfleet\s*one\b|\bfuelman\b|\btcs\b"#, weight: 4)
    ]

    private static let maintenance: [Signal] = [
        Signal(pattern: #"\blabor\b|\blabour\b|\btechnician\b|\btech\s*#?\b|\bmechanic\b"#, weight: 8),
        Signal(pattern: #"repair\s+order|\br\.?\s?o\.?\s*#|work\s+order|\bw\.?o\.?\s*#|service\s+order"#, weight: 7),
        Signal(pattern: #"\bvin\b|\blicense\s+plate\b|\bplate\s*#|\bengine\s+hours\b|\beng(?:ine)?\s+hrs\b|\bmileage\s+in\b|\bodometer\b"#, weight: 5),
        Signal(pattern: #"oil\s+change|\bpm\s+service|preventive\s+maintenance|\blube\b|\bfilters?\b|\bbrakes?\b|\btires?\b|\balignment\b|\bdpf\b|\begr\b|\bturbo\b|\btransmission\b|\bradiator\b|\bcoolant\b|\bbattery\b|\bstarter\b|\balternator\b|\bsuspension\b|\bdot\s+inspection\b|annual\s+inspection|\btow(?:ing)?\b|\broad\s*service\b|\broadside\b"#, weight: 5),
        Signal(pattern: #"shop\s+suppl(?:y|ies)|environmental\s+fee|\benv\.?\s+fee|hazardous\s+waste|disposal\s+fee|\bcore\s+charge\b"#, weight: 6),
        Signal(pattern: #"\bparts?\b|part\s*(?:#|no\.?|number)"#, weight: 3),
        Signal(pattern: #"\d{3}/\d{2}\s?r\s?\d{2}|mount\s+(?:and|&)\s+balance|scrap\s+tire|\bmileage\b|\bdrive\s+tires?\b|\bsteer\s+tires?\b|tire\s+(?:mart|center|shop)"#, weight: 6),
        Signal(pattern: #"freightliner|kenworth|peterbilt|volvo\s+trucks|international\s+trucks|navistar|mack\s+trucks|rush\s+truck|truckpro|fleetpride|speedco|boss\s+shop|goodyear|bridgestone|michelin|love'?s\s+truck\s+care|ta\s+truck\s+service|petro\s+lube|thermo\s*king|carrier\s+transicold|cummins|detroit\s+diesel"#, weight: 5),
        Signal(pattern: #"\bservice\s+(?:date|advisor|writer)\b|\bcomplaint\b|\bcause\b|\bcorrection\b|\brecommend"#, weight: 5)
    ]

    private static let general: [Signal] = [
        Signal(pattern: #"\bsub\s*-?\s*total\b"#, weight: 5),
        Signal(pattern: #"\bsales\s+tax\b|\btax\b"#, weight: 3),
        Signal(pattern: #"\bchange\b|\bcash\b|\btendered\b|\bvisa\b|\bmastercard\b|\bamex\b|\bdebit\b|\bcredit\b"#, weight: 3),
        Signal(pattern: #"thank\s+you|\breceipt\b|\bstore\s*#|\bcashier\b|\bregister\b|\btrans(?:action)?\s*#|\bqty\b"#, weight: 4),
        Signal(pattern: #"\btotal\b"#, weight: 2),
        Signal(pattern: #"\btoll\b|turnpike|toll\s+plaza|e-?z\s*pass|platepay|pikepass|\baxles?\b|\blumper\b|unloading\s+(?:fee|service)|\bcat\s+scale\b|\bweigh\s+ticket\b|\bparking\b|\btruck\s+wash\b"#, weight: 9)
    ]

    private static func score(_ signals: [Signal], _ text: String, reasons: inout [String], tag: String) -> Int {
        var total = 0
        for s in signals {
            let hits = SmartText.matches(s.pattern, in: text).count
            guard hits > 0 else { continue }
            // Repeated hits count, with diminishing returns.
            total += s.weight + min(hits - 1, 3) * max(1, s.weight / 4)
            if reasons.count < 12 { reasons.append("\(tag): /\(s.pattern.prefix(24))…/ ×\(hits)") }
        }
        return total
    }

    static func classify(_ document: DocumentText) -> DocumentClassification {
        let text = document.joined
        var reasons: [String] = []
        let rc = score(rateCon, text, reasons: &reasons, tag: "ratecon")
        let fu = score(fuel, text, reasons: &reasons, tag: "fuel")
        let mt = score(maintenance, text, reasons: &reasons, tag: "maint")
        let ge = score(general, text, reasons: &reasons, tag: "receipt")

        let hasLabor = SmartText.contains(#"\blabou?r\b"#, in: text)
        let hasRepairOrderTitle = SmartText.contains(#"repair\s+order|work\s+order|service\s+order|\br\.?o\.?\s*#"#, in: text)
        let hasPartNumbers = SmartText.contains(#"part\s*(?:#|no\.?|number)|\bp/n\b"#, in: text)
        let hasGallons = SmartText.contains(#"\bgal(?:lons?|s)?\b|\bppg\b|/\s*gal"#, in: text)

        let topText = document.lines.prefix(6).map(\.text).joined(separator: "\n")
        let invoiceTitle = SmartText.contains(#"\binvoice\b"#, in: topText)
        var scores: [SmartDocumentKind: Int] = [
            .rateConfirmation: rc,
            .fuelReceipt: fu + (hasGallons ? 4 : -6),
            .generalReceipt: ge,
            .maintenanceInvoice: mt,
            .repairOrder: mt + (hasRepairOrderTitle ? (invoiceTitle ? -2 : 6) : -8),
            .partsReceipt: mt / 2 + (hasPartNumbers ? 14 : -4) + (hasLabor ? -12 : 4)
        ]
        // A fuel stop that also sells a filter is still a fuel receipt; a
        // shop invoice that lists labor is never a plain receipt.
        if hasLabor { scores[.generalReceipt, default: 0] -= 6; scores[.fuelReceipt, default: 0] -= 6 }
        if hasPartNumbers && !hasGallons { scores[.generalReceipt, default: 0] -= 4 }
        if mt >= 14 && !hasGallons { scores[.generalReceipt, default: 0] -= 4 }
        // Rate cons mention "fuel surcharge" — do not let that look like fuel.
        if rc >= 20 { scores[.fuelReceipt, default: 0] -= 8; scores[.generalReceipt, default: 0] -= 6 }
        // Receipts are short. A long legal-heavy document is not a receipt.
        if document.lines.count > 120 { scores[.generalReceipt, default: 0] -= 4 }

        let ranked = scores.sorted { $0.value > $1.value }
        let best = ranked[0]
        let second = ranked.count > 1 ? ranked[1].value : 0
        let margin = best.value - second

        var kind = best.key
        var confidence: ExtractionConfidence
        if best.value < 10 {
            kind = .unknown
            confidence = .low
        } else if best.value >= 24 && margin >= 10 {
            confidence = .high
        } else if best.value >= 14 && margin >= 5 {
            confidence = .medium
        } else {
            confidence = .low
        }
        // Maintenance vs repair order vs parts is a sub-choice: if the family
        // is clear, keep medium confidence instead of forcing the user to pick.
        if confidence == .low, kind.isMaintenance {
            let family = [scores[.maintenanceInvoice] ?? 0, scores[.repairOrder] ?? 0, scores[.partsReceipt] ?? 0].max() ?? 0
            let others = [rc, scores[.fuelReceipt] ?? 0, scores[.generalReceipt] ?? 0].max() ?? 0
            if family >= 14 && family - others >= 8 { confidence = .medium }
        }
        if confidence == .low, kind.isReceipt {
            let fuelVsGeneral = (scores[.fuelReceipt] ?? 0) - (scores[.generalReceipt] ?? 0)
            let receiptBest = max(scores[.fuelReceipt] ?? 0, scores[.generalReceipt] ?? 0)
            let others = max(rc, mt)
            if receiptBest >= 12 && receiptBest - others >= 8 && abs(fuelVsGeneral) >= 6 { confidence = .medium }
        }

        return DocumentClassification(
            kind: kind,
            confidence: confidence,
            scores: Dictionary(uniqueKeysWithValues: scores.map { ($0.key.rawValue, $0.value) }),
            reasons: reasons
        )
    }
}
