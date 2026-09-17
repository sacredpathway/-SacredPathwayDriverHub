import Foundation

// =============================================================================
// MARK: - Pipeline, result snapshot, form mapping and merge policy
// =============================================================================

/// A value proposed for one form field.
nonisolated struct FormSuggestion: Sendable, Equatable {
    var value: String
    var confidence: ExtractionConfidence
    var rawText: String?
}

/// What the form currently holds for one field.
nonisolated struct FormFieldState: Sendable, Equatable {
    var value: String
    /// True once the user typed or picked this value themselves.
    var userEdited: Bool
    /// Confidence of an earlier automatic fill (nil = typed / empty).
    var autoConfidence: ExtractionConfidence?

    init(value: String, userEdited: Bool, autoConfidence: ExtractionConfidence? = nil) {
        self.value = value
        self.userEdited = userEdited
        self.autoConfidence = autoConfidence
    }
}

nonisolated struct MergeConflict: Sendable, Equatable, Identifiable {
    var id: String { key }
    var key: String
    var currentValue: String
    var suggestedValue: String
    var confidence: ExtractionConfidence
}

nonisolated struct MergeOutcome: Sendable, Equatable {
    /// Fields that should be set (they were empty, or an automatic fill is being improved).
    var applied: [String: FormSuggestion] = [:]
    /// Fields the user already filled differently — shown for review, never overwritten.
    var conflicts: [MergeConflict] = []
    var unchanged: [String] = []
    var skipped: [String] = []
}

nonisolated enum ExtractionMergePolicy {

    static func normalized(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let d = Double(t.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")) {
            return String(format: "%.4f", d)
        }
        return SmartText.key(t)
    }

    /// Rules:
    ///  * empty field → fill (any found value; low confidence stays flagged);
    ///  * same value → nothing to do;
    ///  * user-entered value → never overwritten; reported as a conflict;
    ///  * earlier automatic value → replaced only by a strictly more confident reading.
    static func merge(suggestions: [String: FormSuggestion], into current: [String: FormFieldState]) -> MergeOutcome {
        var out = MergeOutcome()
        for key in suggestions.keys.sorted() {
            guard let s = suggestions[key] else { continue }
            let value = s.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, s.confidence != .missing else { out.skipped.append(key); continue }
            let state = current[key] ?? FormFieldState(value: "", userEdited: false)
            let existing = state.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.isEmpty {
                out.applied[key] = FormSuggestion(value: value, confidence: s.confidence, rawText: s.rawText)
            } else if normalized(existing) == normalized(value) {
                out.unchanged.append(key)
            } else if state.userEdited {
                out.conflicts.append(MergeConflict(key: key, currentValue: existing, suggestedValue: value, confidence: s.confidence))
            } else if let auto = state.autoConfidence, s.confidence > auto {
                out.applied[key] = FormSuggestion(value: value, confidence: s.confidence, rawText: s.rawText)
            } else {
                out.conflicts.append(MergeConflict(key: key, currentValue: existing, suggestedValue: value, confidence: s.confidence))
            }
        }
        return out
    }
}

/// Everything learned from one imported document. Stored (masked) next to
/// the saved record so the user can compare it with the original later.
nonisolated struct SmartExtractionResult: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var createdAt: Date
    var classification: DocumentClassification
    var kind: SmartDocumentKind
    var kindChosenByUser: Bool
    var pageCount: Int
    var textSources: [TextSource]
    var fingerprint: String?
    var rateConfirmation: RateConfirmationExtraction?
    var receipt: ReceiptExtraction?
    var maintenance: MaintenanceExtraction?
    /// The recognized text with card numbers masked (audit / debugging).
    var document: DocumentText
    var duplicates: [DuplicateMatch] = []

    var needsKindChoice: Bool { kind == .unknown || (!kindChosenByUser && classification.needsUserChoice) }

    var issues: [ExtractionIssue] {
        var all = (rateConfirmation?.issues ?? []) + (receipt?.issues ?? []) + (maintenance?.issues ?? [])
        if document.usedOCR, document.pages.contains(where: { $0.source == .ocrEnhanced }) {
            all.append(.info("document", "The scan was hard to read; low-contrast or rotated pages were enhanced before reading."))
        }
        if needsKindChoice {
            all.insert(.warning("kind", "The document type could not be determined reliably. Choose the type."), at: 0)
        }
        for d in duplicates {
            all.insert(.warning("duplicate", (d.level == .likely ? "This looks like a document you already saved" : "This may match a saved record")
                                + (d.title.map { ": \($0)" } ?? "") + " (" + d.reasons.joined(separator: ", ") + ")."), at: 0)
        }
        return all
    }

    var reviewFields: [ReviewField] {
        if let r = rateConfirmation { return RateConfirmationExtractor.reviewFields(r) }
        if let m = maintenance { return MaintenanceExtractor.reviewFields(m) }
        if let r = receipt { return ReceiptExtractor.reviewFields(r) }
        return []
    }

    var attentionCount: Int { reviewFields.filter { $0.confidence == .low || ($0.confidence == .missing && Self.requiredKeys.contains($0.key)) }.count }

    static let requiredKeys: Set<String> = ["amount", "totalRate", "vendorName", "receiptDate", "loadNumber", "stop1.place"]

    var lineItems: [ExtractedLineItem] {
        if let m = maintenance { return m.allLineItems }
        return receipt?.lineItems ?? []
    }

    // MARK: Form mapping — expense

    /// Keys match AddEditExpenseView's fields.
    func expenseFormValues() -> [String: FormSuggestion] {
        var out: [String: FormSuggestion] = [:]
        func put(_ key: String, _ value: String?, _ c: ExtractionConfidence, _ raw: String? = nil) {
            guard let value, !value.isEmpty, c != .missing else { return }
            out[key] = FormSuggestion(value: value, confidence: c, rawText: raw)
        }
        if let m = maintenance {
            put("amount", m.total.value.map(SmartText.plainAmount), m.total.confidence, m.total.rawText)
            put("vendorName", m.shopName.value, m.shopName.confidence, m.shopName.rawText)
            put("receiptDate", m.bestDate.value?.iso, m.bestDate.confidence, m.bestDate.rawText)
            put("category", m.expenseCategory, m.category.value == nil ? .low : m.category.confidence)
            put("description", m.descriptionText, .medium)
            return out
        }
        if let r = receipt {
            put("amount", r.total.value.map(SmartText.plainAmount), r.total.confidence, r.total.rawText)
            let vendor = [r.merchant.value, r.storeNumber.value.map { "#" + $0 }].compactMap { $0 }.joined(separator: " ")
            put("vendorName", vendor.isEmpty ? nil : vendor, r.merchant.confidence, r.merchant.rawText)
            put("receiptDate", r.date.value?.iso, r.date.confidence, r.date.rawText)
            put("category", r.suggestedCategory.value, r.suggestedCategory.confidence)
            put("description", r.descriptionText, .medium)
            if let f = r.fuel {
                put("gallons", f.gallons.value.map { String(format: "%.3f", $0) }, f.gallons.confidence, f.gallons.rawText)
                put("pricePerGallon", f.pricePerGallon.value.map { String(format: "%.3f", $0) }, f.pricePerGallon.confidence, f.pricePerGallon.rawText)
                put("defGallons", f.defGallons.value.map { String(format: "%.3f", $0) }, f.defGallons.confidence, f.defGallons.rawText)
                var defPrice = f.defPricePerGallon
                if !defPrice.isFound, let g = f.defGallons.value, let a = f.defAmount.value, g > 0 {
                    // Price from two printed numbers; kept at review level.
                    defPrice = ExtractedValue((a / g * 1000).rounded() / 1000, .medium, raw: f.defAmount.rawText)
                }
                put("defPricePerGallon", defPrice.value.map { String(format: "%.3f", $0) }, defPrice.confidence, defPrice.rawText)
            }
        }
        return out
    }

    // MARK: Form mapping — load

    /// Keys match SmartScanReviewView's fields.
    func loadFormValues() -> [String: FormSuggestion] {
        guard let r = rateConfirmation else { return [:] }
        var out: [String: FormSuggestion] = [:]
        func put(_ key: String, _ v: ExtractedValue<String>) {
            guard let value = v.value, !value.isEmpty else { return }
            out[key] = FormSuggestion(value: value, confidence: v.confidence, rawText: v.rawText)
        }
        func putMoney(_ key: String, _ v: ExtractedValue<Double>) {
            guard let value = v.value, v.confidence != .low || key == "rate" else { return }
            out[key] = FormSuggestion(value: SmartText.plainAmount(value), confidence: v.confidence, rawText: v.rawText)
        }
        put("brokerName", r.brokerName)
        put("brokerContactName", r.brokerContact)
        put("brokerPhone", r.brokerPhone)
        put("brokerPhoneExtension", r.brokerPhoneExtension)
        put("brokerEmail", r.brokerEmail)
        put("brokerMcNumber", r.brokerMC)
        put("loadNumber", r.loadNumber)
        put("poNumber", r.poNumber)
        put("referenceNumber", r.referenceNumber.isFound ? r.referenceNumber : r.confirmationNumber)
        put("pickupNumber", r.pickupNumber.isFound ? r.pickupNumber : (r.firstPickup?.reference ?? .missing))
        put("bolNumber", r.bolNumber)
        put("truckNumber", r.truckNumber)
        put("trailerNumber", r.trailerNumber)
        put("commodity", r.commodity)
        if let w = r.weightPounds.value {
            out["weight"] = FormSuggestion(value: "\(Int(w)) lbs", confidence: r.weightPounds.confidence, rawText: r.weightPounds.rawText)
        }
        if let m = r.miles.value {
            out["loadedMiles"] = FormSuggestion(value: String(Int(m)), confidence: r.miles.confidence, rawText: r.miles.rawText)
        }
        putMoney("rate", r.totalRate)
        putMoney("fuelSurcharge", r.fuelSurcharge)
        putMoney("lumperFee", r.lumper)
        putMoney("detentionRate", r.detention)
        putMoney("stopOffPay", r.stopOff)
        if let p = r.firstPickup {
            if let cs = p.cityState { out["pickupCityState"] = FormSuggestion(value: cs, confidence: min(p.city.confidence, p.state.confidence), rawText: p.city.rawText) }
            put("pickupAddress", p.address)
            if let d = p.date.value { out["pickupDate"] = FormSuggestion(value: d.iso, confidence: p.date.confidence, rawText: p.date.rawText) }
            put("pickupTime", p.appointment)
            put("shipperName", p.facility)
        }
        if let d = r.lastDelivery, d.id != r.firstPickup?.id {
            if let cs = d.cityState { out["deliveryCityState"] = FormSuggestion(value: cs, confidence: min(d.city.confidence, d.state.confidence), rawText: d.city.rawText) }
            put("deliveryAddress", d.address)
            if let date = d.date.value { out["deliveryDate"] = FormSuggestion(value: date.iso, confidence: d.date.confidence, rawText: d.date.rawText) }
            put("deliveryTime", d.appointment)
            put("receiverName", d.facility)
        }
        return out
    }

    // MARK: Duplicate probe

    func duplicateProbe(recordID: String = "new") -> DuplicateProbe {
        if let r = rateConfirmation {
            return DuplicateProbe(recordID: recordID, recordType: .load, kind: kind, party: r.brokerName.value,
                                  date: r.pickupDate.value, number: r.loadNumber.value ?? r.confirmationNumber.value,
                                  secondaryNumbers: [r.confirmationNumber.value, r.poNumber.value, r.referenceNumber.value].compactMap { $0 },
                                  amount: r.totalRate.value, unit: r.truckNumber.value, fingerprint: fingerprint)
        }
        if let m = maintenance {
            return DuplicateProbe(recordID: recordID, recordType: .expense, kind: kind, party: m.shopName.value,
                                  date: m.bestDate.value, number: m.invoiceNumber.value ?? m.repairOrderNumber.value,
                                  secondaryNumbers: [m.repairOrderNumber.value].compactMap { $0 },
                                  amount: m.total.value, unit: m.unitNumber.value, fingerprint: fingerprint)
        }
        let r = receipt
        return DuplicateProbe(recordID: recordID, recordType: .expense, kind: kind, party: r?.merchant.value,
                              date: r?.date.value, number: r?.receiptNumber.value, amount: r?.total.value,
                              unit: r?.fuel?.truckNumber.value, fingerprint: fingerprint)
    }
}

nonisolated enum SmartExtractionPipeline {

    /// Classify and extract. When the type is unclear and the caller did not
    /// force one, no fields are guessed: the result asks the user to choose.
    static func run(_ document: DocumentText,
                    fingerprint: String? = nil,
                    forcedKind: SmartDocumentKind? = nil,
                    existingRecords: [DuplicateProbe] = [],
                    id: UUID = UUID(),
                    now: Date = Date()) -> SmartExtractionResult {
        let classification = SmartDocumentClassifier.classify(document)
        let kind = forcedKind ?? (classification.needsUserChoice ? .unknown : classification.kind)
        var result = SmartExtractionResult(
            id: id,
            createdAt: now,
            classification: classification,
            kind: kind,
            kindChosenByUser: forcedKind != nil,
            pageCount: document.pageCount,
            textSources: document.sources,
            fingerprint: fingerprint ?? DocumentFingerprint.textFingerprint(document.joined),
            document: masked(document)
        )
        switch kind {
        case .rateConfirmation:
            result.rateConfirmation = RateConfirmationExtractor.extract(document)
        case .fuelReceipt:
            result.receipt = ReceiptExtractor.extract(document, forceFuel: true)
        case .generalReceipt:
            result.receipt = ReceiptExtractor.extract(document, forceFuel: false)
        case .maintenanceInvoice, .repairOrder, .partsReceipt:
            result.maintenance = MaintenanceExtractor.extract(document, kind: kind)
        case .unknown:
            break
        }
        if kind != .unknown, !existingRecords.isEmpty {
            result.duplicates = DuplicateDetector.findMatches(for: result.duplicateProbe(), in: existingRecords)
        }
        return result
    }

    /// Re-runs extraction after the user picks the document type.
    static func rerun(_ previous: SmartExtractionResult, as kind: SmartDocumentKind,
                      unmaskedDocument: DocumentText, existingRecords: [DuplicateProbe] = []) -> SmartExtractionResult {
        run(unmaskedDocument, fingerprint: previous.fingerprint, forcedKind: kind, existingRecords: existingRecords,
            id: previous.id, now: previous.createdAt)
    }

    static func masked(_ document: DocumentText) -> DocumentText {
        var copy = document
        for i in copy.pages.indices {
            copy.pages[i].lines = copy.pages[i].lines.map(SmartText.maskCardNumbers)
        }
        return copy
    }
}
