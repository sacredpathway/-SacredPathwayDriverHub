import Foundation

// =============================================================================
// MARK: - Smart extraction: shared models
// -----------------------------------------------------------------------------
// Pure Foundation (no UIKit / Vision / PDFKit) so the whole extraction core can
// be unit-tested anywhere. The on-device pipeline is:
//
//   import → text (PDF text or Vision OCR) → classify → field detection →
//   normalization → confidence → validation → duplicate check → user review
//
// Nothing here makes network calls. Nothing is saved without the user tapping
// Save on a review screen.
// =============================================================================

/// How much the extractor trusts a value.
nonisolated enum ExtractionConfidence: String, Codable, Sendable, CaseIterable, Comparable {
    /// Not found on the document.
    case missing
    /// Ambiguous or inferred. Must be checked.
    case low
    /// Likely right, but review it.
    case medium
    /// Strong direct match (clear label + well-formed value).
    case high

    private var rank: Int {
        switch self {
        case .missing: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// Low-confidence values are highlighted as "needs attention".
    var needsAttention: Bool { self == .low }

    /// Anything below high is shown as "review".
    var needsReview: Bool { self == .low || self == .medium }

    var label: String {
        switch self {
        case .missing: return "Not found"
        case .low: return "Check this"
        case .medium: return "Review"
        case .high: return "Found"
        }
    }

    /// Lower one step (used when validation finds a conflict).
    var downgraded: ExtractionConfidence {
        switch self {
        case .high: return .medium
        case .medium: return .low
        case .low, .missing: return self
        }
    }

    /// Maps the legacy parser's 0…1 score onto the shared scale.
    init(legacyScore: Double?) {
        guard let s = legacyScore else { self = .medium; return }
        if s >= 0.85 { self = .high } else if s >= 0.55 { self = .medium } else if s > 0 { self = .low } else { self = .medium }
    }

    var legacyScore: Double {
        switch self {
        case .high: return 0.95
        case .medium: return 0.7
        case .low: return 0.35
        case .missing: return 0
        }
    }
}

/// One extracted value plus how it was found. `rawText` keeps the original
/// document text for audit (card numbers are masked before it is stored).
nonisolated struct ExtractedValue<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    var value: Value?
    var confidence: ExtractionConfidence
    var rawText: String?
    var page: Int?

    init(_ value: Value?, _ confidence: ExtractionConfidence, raw: String? = nil, page: Int? = nil) {
        if let value {
            self.value = value
            self.confidence = confidence == .missing ? .low : confidence
        } else {
            self.value = nil
            self.confidence = .missing
        }
        self.rawText = raw.map(SmartText.maskCardNumbers)
        self.page = page
    }

    static var missing: ExtractedValue<Value> { ExtractedValue(nil, .missing) }

    var isFound: Bool { value != nil }

    /// Keeps the value but lowers trust one step (validation conflict).
    func downgraded() -> ExtractedValue<Value> {
        var copy = self
        copy.confidence = confidence.downgraded
        return copy
    }

    /// Picks the better of two readings. Never raises confidence.
    func preferring(_ other: ExtractedValue<Value>) -> ExtractedValue<Value> {
        if !isFound { return other }
        if !other.isFound { return self }
        return other.confidence > confidence ? other : self
    }
}

/// A calendar date with no time zone (documents print local dates).
nonisolated struct SimpleDate: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    var year: Int
    var month: Int
    var day: Int

    init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), (1...31).contains(day), (1990...2100).contains(year) else { return nil }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let d = cal.date(from: comps),
              cal.component(.day, from: d) == day,
              cal.component(.month, from: d) == month else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    var description: String { iso }
    var usDisplay: String { String(format: "%02d/%02d/%04d", month, day, year) }

    /// Noon in the given time zone, so the day never shifts when displayed.
    func date(in timeZone: TimeZone = .current) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day; comps.hour = 12
        return cal.date(from: comps) ?? Date()
    }

    init(date: Date, timeZone: TimeZone = .current) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.year = c.year ?? 2000
        self.month = c.month ?? 1
        self.day = c.day ?? 1
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    func days(to other: SimpleDate) -> Int {
        let a = date(in: TimeZone(identifier: "UTC") ?? .current)
        let b = other.date(in: TimeZone(identifier: "UTC") ?? .current)
        return Int((b.timeIntervalSince(a) / 86_400).rounded())
    }
}

/// Where a page's text came from.
nonisolated enum TextSource: String, Codable, Sendable {
    /// Text embedded in a digital PDF (most reliable).
    case pdfText
    /// Apple Vision OCR on an image or rendered PDF page.
    case ocr
    /// OCR after a contrast/rotation retry (lower quality input).
    case ocrEnhanced
    /// Text supplied directly (tests, pasted text).
    case provided
}

nonisolated struct DocumentTextPage: Codable, Sendable, Equatable {
    var number: Int
    var lines: [String]
    var source: TextSource
    /// Degrees the page was rotated before OCR produced the best reading.
    var rotationApplied: Int = 0
}

/// A single line with its page for audit and page-aware rules.
nonisolated struct DocLine: Sendable, Equatable {
    let text: String
    let page: Int
    let index: Int
}

/// The text of a whole document (one or more pages).
nonisolated struct DocumentText: Codable, Sendable, Equatable {
    var pages: [DocumentTextPage]

    init(pages: [DocumentTextPage]) { self.pages = pages }

    /// Convenience for tests and pasted text. A line that is exactly
    /// `=== PAGE n ===` or `--- page break ---` starts a new page.
    init(text: String, source: TextSource = .provided) {
        var pages: [DocumentTextPage] = []
        var current: [String] = []
        func flush() {
            pages.append(DocumentTextPage(number: pages.count + 1, lines: current, source: source))
            current = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            let lower = t.lowercased()
            if (lower.hasPrefix("=== page") || lower.hasPrefix("=== ocr page")) && lower.hasSuffix("===") || lower == "--- page break ---" {
                if !current.isEmpty || !pages.isEmpty { flush() }
                continue
            }
            if !t.isEmpty { current.append(t) }
        }
        if !current.isEmpty || pages.isEmpty { flush() }
        self.pages = pages
    }

    var pageCount: Int { pages.count }

    var lines: [DocLine] {
        var out: [DocLine] = []
        for page in pages {
            for text in page.lines {
                let normalized = SmartText.normalizeLine(text)
                guard !normalized.isEmpty else { continue }
                out.append(DocLine(text: normalized, page: page.number, index: out.count))
            }
        }
        return out
    }

    var joined: String { lines.map(\.text).joined(separator: "\n") }

    var sources: [TextSource] { pages.map(\.source) }

    var usedOCR: Bool { pages.contains { $0.source == .ocr || $0.source == .ocrEnhanced } }
}

/// Document types the importer understands.
nonisolated enum SmartDocumentKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case rateConfirmation
    case fuelReceipt
    case generalReceipt
    case maintenanceInvoice
    case repairOrder
    case partsReceipt
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rateConfirmation: return "Rate Confirmation"
        case .fuelReceipt: return "Fuel Receipt"
        case .generalReceipt: return "Receipt"
        case .maintenanceInvoice: return "Maintenance Invoice"
        case .repairOrder: return "Repair Order"
        case .partsReceipt: return "Parts Receipt"
        case .unknown: return "Other / Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .rateConfirmation: return "doc.text.fill"
        case .fuelReceipt: return "fuelpump.fill"
        case .generalReceipt: return "receipt"
        case .maintenanceInvoice: return "gearshape.2.fill"
        case .repairOrder: return "wrench.and.screwdriver.fill"
        case .partsReceipt: return "shippingbox.fill"
        case .unknown: return "questionmark.folder.fill"
        }
    }

    var isMaintenance: Bool { self == .maintenanceInvoice || self == .repairOrder || self == .partsReceipt }
    var isReceipt: Bool { self == .fuelReceipt || self == .generalReceipt }
    /// Kinds that become an expense (everything except a rate con).
    var createsExpense: Bool { isMaintenance || isReceipt }
}

/// A problem the user should look at before saving.
nonisolated struct ExtractionIssue: Codable, Sendable, Equatable, Identifiable, Hashable {
    enum Severity: String, Codable, Sendable { case info, warning }
    var id: String { field + "|" + message }
    var field: String
    var message: String
    var severity: Severity

    static func warning(_ field: String, _ message: String) -> ExtractionIssue {
        ExtractionIssue(field: field, message: message, severity: .warning)
    }
    static func info(_ field: String, _ message: String) -> ExtractionIssue {
        ExtractionIssue(field: field, message: message, severity: .info)
    }
}

/// A row shown on the review card.
nonisolated struct ReviewField: Sendable, Equatable, Identifiable {
    var id: String { key }
    var key: String
    var label: String
    var value: String
    var confidence: ExtractionConfidence
    var rawText: String?
}

/// A priced line on a receipt or invoice.
nonisolated struct ExtractedLineItem: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable { case item, part, labor, fee, fuel, def, discount, tax }
    var id: Int
    var kind: Kind
    var description: String
    var partNumber: String?
    var quantity: Double?
    var unit: String?
    var unitPrice: Double?
    var amount: Double?
    var hours: Double?
    var rate: Double?
    var confidence: ExtractionConfidence
    var rawText: String?
    var page: Int?

    var summary: String {
        var parts: [String] = [description]
        if let partNumber { parts.append("#\(partNumber)") }
        if kind == .labor, let hours {
            let rateText = rate.map { " × \(SmartText.money($0))/hr" } ?? ""
            parts.append(SmartText.trimNumber(hours) + " hr" + rateText)
        } else if let quantity {
            let unitText = unit.map { " " + $0 } ?? ""
            let priceText = unitPrice.map { p in
                let cents = (p * 100).rounded() / 100
                return " @ " + (SmartText.approxEqual(cents, p, tolerance: 0.0001) ? SmartText.money(p) : String(format: "$%.3f", p))
            } ?? ""
            parts.append(SmartText.trimNumber(quantity) + unitText + priceText)
        }
        if let amount { parts.append(SmartText.money(amount)) }
        return parts.joined(separator: " — ")
    }
}
