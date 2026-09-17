import Foundation

// =============================================================================
// MARK: - Duplicate detection
// -----------------------------------------------------------------------------
// Warns before a second copy of the same document is saved. A matching amount
// alone is never enough: two $50 lumper receipts on different days are both real.
// =============================================================================

/// A comparable summary of an existing record (load or expense) or of a new
/// extraction.
nonisolated struct DuplicateProbe: Codable, Sendable, Equatable {
    enum RecordType: String, Codable, Sendable { case load, expense }
    var recordID: String
    var recordType: RecordType
    var kind: SmartDocumentKind?
    var party: String?          // vendor / broker / shop
    var date: SimpleDate?
    var number: String?         // load #, receipt #, invoice #
    var secondaryNumbers: [String] = []
    var amount: Double?
    var unit: String?
    var fingerprint: String?
    var title: String?          // shown to the user in the warning
}

nonisolated struct DuplicateMatch: Codable, Sendable, Equatable, Identifiable {
    enum Level: String, Codable, Sendable { case likely, possible }
    var id: String { recordID }
    var recordID: String
    var recordType: DuplicateProbe.RecordType
    var level: Level
    var score: Int
    var reasons: [String]
    var title: String?
}

nonisolated enum DuplicateDetector {

    static func partyKey(_ s: String?) -> String? {
        guard let s else { return nil }
        let stop: Set<String> = ["llc", "inc", "co", "corp", "company", "the", "of", "and", "ltd", "store", "travel", "center",
                                 "centers", "stop", "plaza", "logistics", "services", "service", "truck", "trucks"]
        let words = s.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
            .filter { !stop.contains($0) && !$0.allSatisfy(\.isNumber) }
        let k = words.joined()
        return k.isEmpty ? nil : k
    }

    static func partiesMatch(_ a: String?, _ b: String?) -> Bool {
        guard let ka = partyKey(a), let kb = partyKey(b) else { return false }
        if ka == kb { return true }
        let shorter = ka.count <= kb.count ? ka : kb
        let longer = ka.count <= kb.count ? kb : ka
        return shorter.count >= 4 && longer.contains(shorter)
    }

    static func numbersMatch(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let na = SmartText.normalizedIdentifier(a), nb = SmartText.normalizedIdentifier(b)
        guard na.count >= 3, nb.count >= 3 else { return false }
        if na == nb { return true }
        // "SFB-448812" vs "448812"
        let da = na.filter(\.isNumber), db = nb.filter(\.isNumber)
        return da.count >= 5 && da == db
    }

    static func findMatches(for probe: DuplicateProbe, in existing: [DuplicateProbe]) -> [DuplicateMatch] {
        var out: [DuplicateMatch] = []
        for record in existing where record.recordID != probe.recordID {
            var score = 0
            var reasons: [String] = []

            if let f = probe.fingerprint, let g = record.fingerprint, f == g {
                score += 100
                reasons.append("Same document file")
            }
            let sameNumber = numbersMatch(probe.number, record.number)
                || probe.secondaryNumbers.contains { n in numbersMatch(n, record.number) || record.secondaryNumbers.contains { numbersMatch(n, $0) } }
            if sameNumber {
                score += 45
                reasons.append("Same document number")
            }
            let sameParty = partiesMatch(probe.party, record.party)
            if sameParty {
                score += 15
                reasons.append("Same \(probe.recordType == .load ? "broker" : "vendor")")
            }
            var sameDate = false
            if let a = probe.date, let b = record.date {
                let gap = abs(a.days(to: b))
                if gap == 0 { score += 20; sameDate = true; reasons.append("Same date") }
                else if gap == 1 { score += 8; reasons.append("Dates one day apart") }
                else if gap > 7 { score -= 25 }
            }
            var sameAmount = false
            if let a = probe.amount, let b = record.amount, a > 0 {
                if SmartText.approxEqual(a, b, tolerance: 0.01) { score += 20; sameAmount = true; reasons.append("Same amount") }
                else if abs(a - b) > max(1, a * 0.05) { score -= 20 }
            }
            if let u = probe.unit, let v = record.unit, SmartText.normalizedIdentifier(u) == SmartText.normalizedIdentifier(v) {
                score += 5
            }
            if let k1 = probe.kind, let k2 = record.kind, k1 != k2, !(k1.isMaintenance && k2.isMaintenance), !(k1.isReceipt && k2.isReceipt) {
                score -= 15
            }

            // Vendor + day + amount together is a strong signal.
            if sameParty && sameDate && sameAmount { score += 20 }

            // An amount match by itself never flags a duplicate.
            let onlyAmount = sameAmount && !sameNumber && !sameParty && !sameDate && score < 100
            if onlyAmount { continue }

            let level: DuplicateMatch.Level?
            if score >= 70 { level = .likely }
            else if score >= 45 && (sameNumber || (sameParty && sameDate)) { level = .possible }
            else { level = nil }
            if let level {
                out.append(DuplicateMatch(recordID: record.recordID, recordType: record.recordType, level: level,
                                          score: score, reasons: reasons, title: record.title))
            }
        }
        return out.sorted { $0.score > $1.score }
    }
}
