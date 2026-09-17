import Foundation
import UIKit

// =============================================================================
// MARK: - SmartImportCoordinator — app glue for smart document import
// -----------------------------------------------------------------------------
// import → DocumentTextReader → SmartExtractionPipeline → form prefill →
// (user review) → save → SmartDocumentStore (original + snapshot).
// The legacy on-device parsers keep running; their readings fill any field the
// shared extractor could not read, so no existing scan result gets worse.
// =============================================================================

/// One imported document after reading and extraction. In memory only.
struct SmartImport {
    var result: SmartExtractionResult
    /// Unmasked text, kept only while the review screen is open (needed to
    /// re-run extraction when the user picks the document type).
    var document: DocumentText
    var legacyOCRLines: [String]
    var source: ImportedDocument
    var family: SmartImportCoordinator.Family

    /// Kinds the user may pick in this flow.
    var selectableKinds: [SmartDocumentKind] {
        let ranked = result.classification.rankedKinds
        switch family {
        case .expense: return ranked.filter { $0.createsExpense }
        case .load: return ranked
        }
    }

    /// A document of the wrong family for this screen (e.g. a receipt scanned from Add Load).
    var familyMismatchMessage: String? {
        guard result.kind != .unknown else { return nil }
        switch family {
        case .load where result.kind != .rateConfirmation && result.classification.confidence >= .medium:
            return "This looks like a \(result.kind.displayName). Receipts and repair invoices are added from the Expenses tab."
        case .expense where result.classification.kind == .rateConfirmation && result.classification.confidence >= .medium:
            return "This looks like a Rate Confirmation. Loads are added from Add Load → Smart Scan."
        default:
            return nil
        }
    }
}

enum SmartImportCoordinator {

    enum Family { case load, expense }

    static let expenseCategories: Set<String> = ["fuel", "lumper", "toll", "repair", "insurance", "maintenance", "other"]

    // MARK: Import

    static func importDocument(_ imported: ImportedDocument,
                               family: Family,
                               existing: [DuplicateProbe]) async -> SmartImport {
        let reading = await DocumentTextReader.read(imported)
        var result = SmartExtractionPipeline.run(reading.document,
                                                 fingerprint: imported.fileFingerprint,
                                                 existingRecords: existing)
        // A rate con scanned from the Expenses tab is never auto-filled as an
        // expense: the card explains where it belongs and the user chooses.
        if family == .expense, result.kind == .rateConfirmation {
            result.rateConfirmation = nil
            result.kind = .unknown
            result.duplicates = []
        }
        return SmartImport(result: result, document: reading.document, legacyOCRLines: reading.legacyOCRLines,
                           source: imported, family: family)
    }

    /// Re-extracts after the user picks the document type.
    static func choose(_ kind: SmartDocumentKind, for imp: SmartImport, existing: [DuplicateProbe]) -> SmartImport {
        var copy = imp
        copy.result = SmartExtractionPipeline.rerun(imp.result, as: kind, unmaskedDocument: imp.document, existingRecords: existing)
        return copy
    }

    // MARK: Expense suggestions (shared extractor + legacy fuel parser)

    static func expenseSuggestions(_ imp: SmartImport) -> [String: FormSuggestion] {
        var suggestions = imp.result.expenseFormValues()
        if let category = suggestions["category"]?.value, !expenseCategories.contains(category) {
            suggestions["category"] = FormSuggestion(value: "other", confidence: .low)
        }
        guard imp.result.kind == .fuelReceipt else { return suggestions }

        // The legacy fuel parser has its own regression-tested rules: use it
        // for anything the shared extractor did not find.
        let lines = imp.document.pages.flatMap(\.lines)
        let legacy = LocalDocumentParser.extractFuelReceipt(fromLines: lines)
        func fill(_ key: String, _ value: String?, _ score: Double?) {
            guard suggestions[key] == nil, let value, !value.isEmpty else { return }
            let conf = min(ExtractionConfidence(legacyScore: score), .medium)
            suggestions[key] = FormSuggestion(value: value, confidence: conf, rawText: nil)
        }
        fill("amount", legacy.totalAmount.map { String(format: "%.2f", $0) }, legacy.confidence["totalAmount"])
        fill("gallons", legacy.gallons.map { String(format: "%.3f", $0) }, legacy.confidence["gallons"])
        fill("pricePerGallon", legacy.pricePerGallon.map { String(format: "%.3f", $0) }, legacy.confidence["pricePerGallon"])
        fill("defGallons", legacy.defGallons.map { String(format: "%.3f", $0) }, legacy.confidence["defGallons"])
        fill("defPricePerGallon", legacy.defPricePerGallon.map { String(format: "%.3f", $0) }, legacy.confidence["defPricePerGallon"])
        fill("vendorName", legacy.vendorName, legacy.confidence["vendorName"])
        if suggestions["receiptDate"] == nil, let d = legacy.receiptDate {
            suggestions["receiptDate"] = FormSuggestion(value: SimpleDate(date: d).iso, confidence: .medium)
        }
        return suggestions
    }

    static func expensePrefill(_ imp: SmartImport) -> ExpenseFormPrefill {
        let s = expenseSuggestions(imp)
        var prefill = ExpenseFormPrefill()
        // Unknown type: nothing is guessed; the form opens with the type chooser.
        prefill.category = s["category"]?.value ?? "other"
        prefill.amount = s["amount"]?.value ?? ""
        prefill.vendorName = s["vendorName"]?.value ?? ""
        prefill.description = s["description"]?.value ?? ""
        if let iso = s["receiptDate"]?.value, let d = date(fromISO: iso) { prefill.receiptDate = d }
        prefill.gallons = s["gallons"]?.value ?? ""
        prefill.pricePerGallon = s["pricePerGallon"]?.value ?? ""
        prefill.defGallons = s["defGallons"]?.value ?? ""
        prefill.defPricePerGallon = s["defPricePerGallon"]?.value ?? ""
        prefill.receiptImage = imp.source.images.first
        prefill.smartImport = imp
        prefill.smartSuggestions = s
        return prefill
    }

    static func date(fromISO iso: String) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let d = SimpleDate(year: parts[0], month: parts[1], day: parts[2]) else { return nil }
        return d.date()
    }

    // MARK: Rate confirmation → legacy review model

    /// Fills fields the legacy parser missed and replaces weak legacy readings
    /// with strong ones. Returns notes for the review card.
    @discardableResult
    static func enhance(_ parsedInOut: inout ParsedLoadFields, with result: SmartExtractionResult) -> [ExtractionIssue] {
        guard result.kind == .rateConfirmation else { return [] }
        var notes: [ExtractionIssue] = []
        let s = result.loadFormValues()
        // Work on a local copy; nested helpers never capture the inout parameter.
        var parsed = parsedInOut
        defer { parsedInOut = parsed }

        func merge(_ key: String, _ current: String?, _ set: (String) -> Void) {
            guard let suggestion = s[key] else { return }
            let legacyScore = parsed.confidence[key]
            let existing = (current ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.isEmpty {
                set(suggestion.value)
                parsed.confidence[key] = suggestion.confidence.legacyScore
            } else if ExtractionMergePolicy.normalized(existing) != ExtractionMergePolicy.normalized(suggestion.value) {
                if suggestion.confidence == .high, let legacyScore, legacyScore < 0.5 {
                    set(suggestion.value)
                    parsed.confidence[key] = suggestion.confidence.legacyScore
                } else if suggestion.confidence >= .medium {
                    notes.append(.info(key, "The document also shows \"\(suggestion.value)\" for \(label(for: key))."))
                }
            }
        }
        func string(_ key: String, _ kp: WritableKeyPath<ParsedLoadFields, String?>) {
            let current = parsed[keyPath: kp]
            merge(key, current) { parsed[keyPath: kp] = $0 }
        }
        func money(_ key: String, _ kp: WritableKeyPath<ParsedLoadFields, Double?>) {
            let current = parsed[keyPath: kp].map { String(format: "%.2f", $0) }
            merge(key, current) { v in
                if let d = Double(v) { parsed[keyPath: kp] = d }
            }
        }
        func dateField(_ key: String, _ kp: WritableKeyPath<ParsedLoadFields, Date?>) {
            let current = parsed[keyPath: kp].map { SimpleDate(date: $0).iso }
            merge(key, current) { v in
                if let d = date(fromISO: v) { parsed[keyPath: kp] = d }
            }
        }

        string("loadNumber", \.loadNumber)
        string("brokerName", \.brokerName)
        string("brokerContactName", \.brokerContactName)
        string("brokerPhone", \.brokerPhone)
        string("brokerPhoneExtension", \.brokerPhoneExtension)
        string("brokerEmail", \.brokerEmail)
        string("brokerMcNumber", \.brokerMcNumber)
        string("pickupCityState", \.pickupCityState)
        string("pickupAddress", \.pickupAddress)
        string("pickupTime", \.pickupTime)
        string("deliveryCityState", \.deliveryCityState)
        string("deliveryAddress", \.deliveryAddress)
        string("deliveryTime", \.deliveryTime)
        string("weight", \.weight)
        string("commodity", \.commodity)
        string("poNumber", \.poNumber)
        string("pickupNumber", \.pickupNumber)
        string("referenceNumber", \.referenceNumber)
        string("shipperName", \.shipperName)
        string("receiverName", \.receiverName)
        string("trailerNumber", \.trailerNumber)
        string("truckNumber", \.truckNumber)
        string("bolNumber", \.bolNumber)
        dateField("pickupDate", \.pickupDate)
        dateField("deliveryDate", \.deliveryDate)
        money("rate", \.rate)
        money("fuelSurcharge", \.fuelSurcharge)
        money("lumperFee", \.lumperFee)
        money("detentionRate", \.detentionRate)
        money("stopOffPay", \.stopOffPay)
        if let miles = s["loadedMiles"], parsed.loadedMiles == nil, let v = Double(miles.value) {
            parsed.loadedMiles = v
            parsed.confidence["loadedMiles"] = miles.confidence.legacyScore
        }
        return notes
    }

    static func label(for key: String) -> String {
        let labels: [String: String] = [
            "amount": "Amount", "vendorName": "Vendor", "description": "Description", "category": "Category",
            "receiptDate": "Date", "gallons": "Gallons", "pricePerGallon": "Price / gal", "defGallons": "DEF gallons",
            "defPricePerGallon": "DEF price / gal", "loadNumber": "Load #", "brokerName": "Broker",
            "brokerContactName": "Broker contact", "brokerPhone": "Broker phone", "brokerPhoneExtension": "Phone ext",
            "brokerEmail": "Broker email", "brokerMcNumber": "MC #", "pickupCityState": "Pickup city",
            "pickupAddress": "Pickup address", "pickupDate": "Pickup date", "pickupTime": "Pickup time",
            "deliveryCityState": "Delivery city", "deliveryAddress": "Delivery address", "deliveryDate": "Delivery date",
            "deliveryTime": "Delivery time", "rate": "Rate", "weight": "Weight", "commodity": "Commodity",
            "poNumber": "PO #", "pickupNumber": "Pickup #", "referenceNumber": "Reference #", "shipperName": "Shipper",
            "receiverName": "Receiver", "trailerNumber": "Trailer #", "truckNumber": "Truck #", "bolNumber": "BOL #",
            "fuelSurcharge": "Fuel surcharge", "lumperFee": "Lumper", "detentionRate": "Detention",
            "stopOffPay": "Stop-off", "loadedMiles": "Loaded miles"
        ]
        return labels[key] ?? key
    }

    // MARK: Duplicate probes from existing records

    static func probe(for expense: Expense) -> DuplicateProbe? {
        guard let id = expense.id else { return nil }
        let kind: SmartDocumentKind
        switch expense.category.lowercased() {
        case "fuel": kind = .fuelReceipt
        case "maintenance", "repair", "repairs": kind = .maintenanceInvoice
        default: kind = .generalReceipt
        }
        let number = expense.description.flatMap { d in
            SmartText.groups(#"(?:receipt|inv|invoice|ro)\s+([A-Z0-9-]{3,})"#, in: d)?[1] ?? nil
        }
        let date = expense.receiptDate ?? expense.createdAt
        var titleParts = [expense.category.capitalized]
        if let v = expense.vendorName, !v.isEmpty { titleParts.append(v) }
        if let date { titleParts.append(SimpleDate(date: date).usDisplay) }
        titleParts.append(SmartText.money(expense.amount))
        return DuplicateProbe(recordID: id.uuidString, recordType: .expense, kind: kind, party: expense.vendorName,
                              date: date.map { SimpleDate(date: $0) }, number: number, amount: expense.amount,
                              unit: nil, fingerprint: nil, title: titleParts.joined(separator: " · "))
    }

    static func probe(for load: Load) -> DuplicateProbe? {
        guard let id = load.id else { return nil }
        var titleParts = ["Load " + (load.loadNumber ?? "—")]
        if let b = load.brokerName, !b.isEmpty { titleParts.append(b) }
        if let d = load.pickupDate { titleParts.append(SimpleDate(date: d).usDisplay) }
        return DuplicateProbe(recordID: id.uuidString, recordType: .load, kind: .rateConfirmation,
                              party: load.brokerName, date: load.pickupDate.map { SimpleDate(date: $0) },
                              number: load.loadNumber, amount: load.totalRevenue ?? load.lineHaulRate,
                              unit: load.truckNumber, fingerprint: nil, title: titleParts.joined(separator: " · "))
    }

    /// Existing records plus everything imported before (which carries file fingerprints).
    static func expenseProbes(_ expenses: [Expense]) -> [DuplicateProbe] {
        merged(expenses.compactMap(probe(for:)), SmartDocumentStore.shared.probes().filter { $0.recordType == .expense })
    }

    static func loadProbes(_ loads: [Load]) -> [DuplicateProbe] {
        merged(loads.compactMap(probe(for:)), SmartDocumentStore.shared.probes().filter { $0.recordType == .load })
    }

    private static func merged(_ records: [DuplicateProbe], _ imported: [DuplicateProbe]) -> [DuplicateProbe] {
        let liveIDs = Set(records.map(\.recordID))
        var out = records
        for p in imported {
            if let i = out.firstIndex(where: { $0.recordID == p.recordID }) {
                // Live record wins for values; the import adds the fingerprint and numbers.
                out[i].fingerprint = p.fingerprint
                if out[i].number == nil { out[i].number = p.number }
                out[i].secondaryNumbers = p.secondaryNumbers
            } else if !liveIDs.isEmpty {
                // Deleted record: its sidecar is stale; ignore it.
                continue
            } else {
                out.append(p)
            }
        }
        return out
    }

    // MARK: Persistence (best-effort, never blocks a save)

    static func persist(recordType: DuplicateProbe.RecordType,
                        recordID: UUID?,
                        imp: SmartImport?,
                        appliedValues: [String: String],
                        userEditedKeys: [String],
                        title: String?,
                        store: SmartDocumentStore = .shared) {
        guard let recordID, let imp else { return }
        var sourceFilename: String?
        var mime = imp.source.mimeType
        do {
            if let data = imp.source.originalData, !data.isEmpty {
                sourceFilename = try store.saveSource(data, mimeType: mime)
            } else if let data = pagesAsPDF(imp.source.images) {
                // Camera scans have no file: keep every captured page as a PDF.
                mime = "application/pdf"
                sourceFilename = try store.saveSource(data, mimeType: mime)
            }
            var probe = imp.result.duplicateProbe(recordID: recordID.uuidString)
            probe.title = title
            let record = SmartDocumentRecord(recordType: recordType, recordID: recordID.uuidString, savedAt: Date(),
                                             sourceFilename: sourceFilename, sourceMimeType: mime,
                                             fingerprint: imp.result.fingerprint, result: imp.result,
                                             appliedValues: appliedValues, userEditedKeys: userEditedKeys.sorted(),
                                             probe: probe)
            try store.save(record)
        } catch {
            if let sourceFilename, store.record(type: recordType, id: recordID.uuidString) == nil,
               let url = store.sourceURL(filename: sourceFilename) {
                try? FileManager.default.removeItem(at: url)
            }
            #if DEBUG
            print("[SmartImport] snapshot not saved (record is safe): \(error.localizedDescription)")
            #endif
        }
    }

    /// Full-resolution pages in one PDF (the images are drawn, not recompressed).
    static func pagesAsPDF(_ images: [UIImage]) -> Data? {
        guard let first = images.first, first.size.width > 0 else { return nil }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.size))
        return renderer.pdfData { ctx in
            for image in images {
                let rect = CGRect(origin: .zero, size: image.size)
                ctx.beginPage(withBounds: rect, pageInfo: [:])
                image.draw(in: rect)
            }
        }
    }
}
