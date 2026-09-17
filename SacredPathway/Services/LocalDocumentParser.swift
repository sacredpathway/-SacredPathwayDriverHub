import Foundation
import ImageIO
import UIKit
@preconcurrency import Vision

// MARK: - Parsed fields

/// All fields the Smart-Scan parser tries to pull off a rate confirmation
/// or BOL. Every value is optional; the review screen lets the user fill
/// in or correct anything the parser missed.
///
/// `confidence` is per-field (0.0 – 1.0) where 1.0 means the regex hit a
/// strong, unambiguous pattern and 0.5 or below means we made a guess. The
/// review screen shows the raw OCR text below any field with confidence
/// < 0.5 so the user can verify by hand.
struct ParsedLoadFields {
    var loadNumber: String?
    var brokerName: String?
    /// Specific human rep / dispatcher who booked this load, parsed from the
    /// name printed near the broker email/phone block (e.g. "Aaron Dini" on a
    /// TQL rate con). Distinct from `brokerName` (the company). Drives the
    /// per-load broker_contact attribution introduced in v2.0.2.
    var brokerContactName: String?
    var brokerPhone: String?
    /// Phone extension printed near the broker phone, e.g. "ext 4421" / "x123".
    /// Stored separately so the UI can render "Phone (555) 555-1212 · ext 4421"
    /// or write it back as a trailing " x123" segment on the contact row.
    var brokerPhoneExtension: String?
    var brokerEmail: String?
    var brokerMcNumber: String?

    var pickupCityState: String?
    var pickupAddress: String?
    var pickupDate: Date?
    var pickupTime: String?

    var deliveryCityState: String?
    var deliveryAddress: String?
    var deliveryDate: Date?
    var deliveryTime: String?

    var rate: Double?
    var weight: String?
    var commodity: String?
    var poNumber: String?
    var pickupNumber: String?
    var notes: String?

    // Added 2026-05: people / company at each end of the route
    var shipperName: String?
    var receiverName: String?
    /// "Reference #" / "Ref #" / etc. — distinct from `loadNumber` and `poNumber`.
    var referenceNumber: String?

    // Added 2026-05: miles parsed from the document if printed there.
    /// Driving miles for the pickup → delivery leg, if the document prints them.
    var loadedMiles: Double?
    /// Empty miles to pickup, if the document prints them.
    var deadheadMiles: Double?

    // ---- Pay breakdown / accessorials (Part 2 upgrade — 2026-05) ----
    /// Fuel surcharge dollar amount printed on the rate con.
    var fuelSurcharge: Double?
    /// Lumper fee.
    var lumperFee: Double?
    /// Detention dollar/hr or flat amount.
    var detentionRate: Double?
    /// Stop-off / extra-pickup pay.
    var stopOffPay: Double?

    // ---- Equipment / shipment metadata ----
    /// Carrier trailer number printed on the doc (e.g. "TR#  T-2418" / "Trailer: 2580").
    var trailerNumber: String?
    /// Bill of Lading number — distinct from load # / PO # / ref #.
    var bolNumber: String?
    /// Driver-facing instructions or notes the broker stamped on the doc.
    var driverNotes: String?
    /// Detected vendor name — used to route to a specialized parser.
    /// Examples: "Lowes", "Amazon", "Walmart", "C.H. Robinson".
    var sourceVendor: String?

    /// Document type classification (rateCon, recon, bol, unknown).
    /// Drives which extractor strategy runs. Recon docs need a fundamentally
    /// different load-number / amount strategy than rate confirmations.
    var documentType: DocumentType = .unknown

    /// Per-field confidence 0.0–1.0
    var confidence: [String: Double] = [:]

    /// Full OCR text — surfaced in the review screen so the user can
    /// double-check anything the parser missed.
    var rawText: String = ""
}

struct ParsedFuelReceiptFields {
    var vendorName: String?
    var totalAmount: Double?
    var gallons: Double?
    var pricePerGallon: Double?
    var dieselAmount: Double?
    var defGallons: Double?
    var defPricePerGallon: Double?
    var defAmount: Double?
    var receiptDate: Date?
    var location: String?
    var paymentMethod: String?
    var confidence: [String: Double] = [:]
    var rawText: String = ""

    /// True when the scan is missing core fields or parsed with low confidence,
    /// so the review screen should require the driver to confirm before saving.
    var needsReview: Bool {
        if totalAmount == nil || gallons == nil { return true }
        let core = ["totalAmount", "gallons", "pricePerGallon"].compactMap { confidence[$0] }
        guard !core.isEmpty else { return true }
        return core.reduce(0, +) / Double(core.count) < 0.6
    }

    var expensePrefill: ExpenseFormPrefill {
        ExpenseFormPrefill(
            category: "fuel",
            amount: totalAmount.map(Self.money) ?? "",
            vendorName: vendorName ?? "",
            description: Self.composedDescription(payment: paymentMethod, location: location,
                                                  defGallons: defGallons, defAmount: defAmount),
            receiptDate: receiptDate ?? Date(),
            gallons: gallons.map { Self.decimal($0, places: 3) } ?? "",
            pricePerGallon: pricePerGallon.map { Self.decimal($0, places: 3) } ?? "",
            defGallons: defGallons.map { Self.decimal($0, places: 3) } ?? "",
            defPricePerGallon: defPricePerGallon.map { Self.decimal($0, places: 3) } ?? ""
        )
    }

    private static func money(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func decimal(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", value)
    }

    private static func composedDescription(payment: String?, location: String?,
                                            defGallons: Double?, defAmount: Double?) -> String {
        var parts = ["Scanned fuel receipt"]
        if let payment, !payment.isEmpty { parts.append(payment) }
        if let location, !location.isEmpty { parts.append(location) }
        // DEF isn't a first-class expense field, so it rides in the note so it's
        // never silently dropped from a scanned receipt.
        if let g = defGallons, g > 0 {
            let amt = defAmount.map { String(format: " ($%.2f)", $0) } ?? ""
            parts.append(String(format: "DEF %.3f gal%@", g, amt))
        } else if let a = defAmount, a > 0 {
            parts.append(String(format: "DEF $%.2f", a))
        }
        return parts.joined(separator: " · ")
    }
}

/// Coarse document-type classification used to route to a strategy.
enum DocumentType: String {
    case rateCon   // rate confirmation
    case recon     // reconciliation / settlement / remittance
    case bol       // bill of lading
    case unknown
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up:
            self = .up
        case .upMirrored:
            self = .upMirrored
        case .down:
            self = .down
        case .downMirrored:
            self = .downMirrored
        case .left:
            self = .leftMirrored
        case .leftMirrored:
            self = .left
        case .right:
            self = .rightMirrored
        case .rightMirrored:
            self = .right
        @unknown default:
            self = .up
        }
    }
}

// MARK: - Service

/// On-device-only parser. Uses Apple's Vision framework for OCR
/// (`VNRecognizeTextRequest`) and pure regex for field extraction.
///
/// Hard rules — DO NOT CHANGE:
///  * No network calls of any kind.
///  * No OpenAI / Claude / Gemini / Anthropic / Supabase Edge Functions.
///  * No API tokens. No remote inference.
///  * Vision framework runs fully on-device on every supported iPhone.
enum LocalDocumentParser {

    // MARK: Public entry points

    /// Run OCR on a UIImage, then extract fields. Async because Vision is
    /// CPU-bound; we hop to a background queue so the UI doesn't block.
    static func parse(image: UIImage) async -> ParsedLoadFields {
        await parse(images: [image])
    }

    /// Run OCR across every page/image in a scan or imported PDF, then extract
    /// fields from the combined page text. Multi-page rate confirmations often
    /// place legal terms first and the actual load table later.
    static func parse(images: [UIImage]) async -> ParsedLoadFields {
        guard !images.isEmpty else { return ParsedLoadFields() }

        var allLines: [String] = []
        for (idx, image) in images.enumerated() {
            let lines = await recognizeText(in: image)
            #if DEBUG
            allLines.append("=== OCR PAGE \(idx + 1) ===")
            #endif
            allLines.append(contentsOf: lines)
        }

        let parsed = extractFields(fromLines: allLines)
        #if DEBUG
        SmartScanDebugStore.capture(lines: allLines, parsed: parsed)
        #endif
        return parsed
    }

    static func parseSinglePageForTesting(image: UIImage) async -> ParsedLoadFields {
        let lines = await recognizeText(in: image)
        return extractFields(fromLines: lines)
    }

    /// Convenience for callers that already have raw OCR text.
    static func parseText(_ text: String) -> ParsedLoadFields {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return extractFields(fromLines: lines)
    }

    /// Run OCR on a fuel receipt and return an expense-ready draft. This
    /// stays on-device and intentionally only fills high-signal receipt
    /// fields; anything uncertain remains editable on the expense screen.
    static func parseFuelReceipt(image: UIImage) async -> ParsedFuelReceiptFields {
        let lines = await recognizeText(in: image)
        return extractFuelReceipt(fromLines: lines)
    }

    static func parseFuelReceiptText(_ text: String) -> ParsedFuelReceiptFields {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return extractFuelReceipt(fromLines: lines)
    }

    #if DEBUG
    enum SmartScanDebugStore {
        private static let fileName = "smart-scan-last-ocr-debug.txt"

        static var lastText: String {
            (try? String(contentsOf: debugFileURL, encoding: .utf8)) ?? ""
        }

        static var debugFileURL: URL {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ??
                FileManager.default.temporaryDirectory
            return dir.appendingPathComponent(fileName)
        }

        static func capture(lines: [String], parsed: ParsedLoadFields) {
            let text = debugText(lines: lines, parsed: parsed)
            try? text.write(to: debugFileURL, atomically: true, encoding: .utf8)
            print("[SP_OCR_DEBUG] wrote \(lines.count) OCR lines to \(debugFileURL.path)")
            print("[SP_OCR_DEBUG] parsed loadNumber=\(parsed.loadNumber ?? "<nil>") pickup=\(parsed.pickupCityState ?? "<nil>") delivery=\(parsed.deliveryCityState ?? "<nil>") weight=\(parsed.weight ?? "<nil>") miles=\(parsed.loadedMiles.map { String($0) } ?? "<nil>") rate=\(parsed.rate.map { String($0) } ?? "<nil>") commodity=\(parsed.commodity ?? "<nil>")")
            print("[SP_OCR_DEBUG_BEGIN]\n\(text)\n[SP_OCR_DEBUG_END]")
        }

        private static func debugText(lines: [String], parsed: ParsedLoadFields) -> String {
            let parsedSummary = """
            === PARSED VALUES ===
            loadNumber: \(parsed.loadNumber ?? "")
            pickupCityState: \(parsed.pickupCityState ?? "")
            deliveryCityState: \(parsed.deliveryCityState ?? "")
            pickupDate: \(debugDateString(parsed.pickupDate))
            deliveryDate: \(debugDateString(parsed.deliveryDate))
            weight: \(parsed.weight ?? "")
            commodity: \(parsed.commodity ?? "")
            loadedMiles: \(parsed.loadedMiles.map { String($0) } ?? "")
            rate: \(parsed.rate.map { String($0) } ?? "")
            poNumber: \(parsed.poNumber ?? "")
            referenceNumber: \(parsed.referenceNumber ?? "")
            confidence: \(parsed.confidence.map { "\($0.key)=\(String(format: "%.2f", $0.value))" }.sorted().joined(separator: ", "))
            debugFile: \(debugFileURL.path)

            === OCR TEXT USED BY LocalDocumentParser ===
            """
            return parsedSummary + "\n" + lines.joined(separator: "\n")
        }
    }

    struct ParserRegressionResult {
        let name: String
        let passed: Bool
        let expected: [String: String]
        let actual: [String: String]
        let failures: [String]
    }

    static func runRateConParserRegressionTests() -> [ParserRegressionResult] {
        [
            ntLogisticsRegression(),
            poLoadNormalizationLoadOnlyRegression(),
            poLoadNormalizationPOOnlyRegression(),
            poLoadNormalizationIdenticalRegression(),
            poLoadNormalizationDifferentRegression()
        ]
    }

    private static func ntLogisticsRegression() -> ParserRegressionResult {
        let fixture = """
        === OCR PAGE 1 ===
        Signature pages may contain page separators and partial words.
        tential
        clearly
        === OCR PAGE 2 ===
        NT LOGISTICS
        Rate Confirmation Agreement for NT Logistics Inc.
        This document can be used as a substitute for an invoice.
        Check calls must be made daily by 9 am EST or carrier will be charged a penalty fee of $100 per day.
        Driver is responsible for all load counts.
        Water loads Blue Triton PRIMO Statement
        Tracking Statement:
        Tracking on Trucker Tools is Required.
        For after hour issues that occur M-F 1800-0600 please call Amber @469-952-7672
        537902
        NT Logistics, Inc.
        Frisco, TX 75034
        7460 Warren Parkway, #301
        Phone: 469-362-5040
        Rate Confirmation
        Page 1
        0527290
        Carrier:
        SACRED PATHWAY LLC
        TUSCALOOSA AL 35406
        Date:
        06/03/2026
        Contact:
        Highway Rate Confirmation Delivery
        Phone:
        334-507-2688
        Factoring Co:
        TAFS - TRANSAM FINANCIAL SERVICES
        Order
        Order 0527290
        Miles:
        1462.0
        Commodity:
        Bentonite Minerals on Pallets
        Weight:
        43244.0
        BOL:
        clearly
        Trailer:
        Van (DAT)
        Reference:
        PU 1
        Name:
        PDS
        Address:
        105 W Sharp St
        Date:
        06/03/2026 0700
        06/03/2026 1600
        Contact:
        870-863-5707
        EL DORADO
        AR 71730
        SO 2 Name:
        Baroid Industrial Drilling Prod
        Date:
        06/05/2026 0800
        Address:
        789 Highway 14A East
        06/05/2026 1500
        LOVELL
        WY 82431
        Payment
        Carrier Freight Pay:
        $5,700.00
        Total Carrier Pay:
        $5,700.00
        Instructions
        PDS - STRAPS AND LOAD BARS REQUIRED
        For after-hours issues please call 469-952-7672
        For any questions, please call NT Logistics at 469-362-5040
        Operations@ntlogistics.com
        billing@ntlogistics.com
        quickpay@ntlogistics.com
        PO #
        tential
        Please Sign: Demarquis
        Driver Name: Demarquis Hinton
        Driver Cell: 3345078894
        Driver Email: jamie@sacredpathway.org
        Tractor #: 2580
        Trailer #: TV530209
        Attention: Sahir Khan
        469-362-5000
        skhan@ntlogistics.com
        Highway Audit Report
        Rate Confirmation ID: 9359302
        Generated: June 03, 2026 13:36 UTC
        Activity History
        06/03/2026 13:36 UTC - Terms Accepted
        User: Jamie (jamie@sacredpathway.org) - IP: 216.103.2.62
        06/03/2026 13:36 UTC - Viewed
        User: Jamie (jamie@sacredpathway.org) - IP: 216.103.2.62
        06/03/2026 13:36 UTC - Delivered
        User: Sahir Khan (skhan@ntlogistics.com) - IP: N/A
        Digital signature audit trail for rate confirmation acceptance.
        """

        let parsed = parseText(fixture)
        let expected: [String: String] = [
            "loadNumber": "0527290",
            "pickupCityState": "El Dorado, AR",
            "deliveryCityState": "Lovell, WY",
            "pickupAddress": "105 W Sharp St",
            "deliveryAddress": "789 Highway 14A East",
            "pickupDate": "06/03/2026",
            "deliveryDate": "06/05/2026",
            "weightDigits": "43244",
            "commodity": "Bentonite Minerals on Pallets",
            "loadedMiles": "1462",
            "rate": "5700",
            "brokerName": "NT Logistics, Inc.",
            "brokerEmail": "skhan@ntlogistics.com",
            "brokerEmailOwnerBlocked": "true",
            "poNumber": "0527290",
            "bolNumber": "",
            "brokerMarkerBlocked": "true",
            "brokerTitleBlocked": "true",
            "loadGarbageBlocked": "true"
        ]
        let actual: [String: String] = [
            "loadNumber": parsed.loadNumber ?? "",
            "pickupCityState": parsed.pickupCityState ?? "",
            "deliveryCityState": parsed.deliveryCityState ?? "",
            "pickupAddress": parsed.pickupAddress ?? "",
            "deliveryAddress": parsed.deliveryAddress ?? "",
            "pickupDate": debugDateString(parsed.pickupDate),
            "deliveryDate": debugDateString(parsed.deliveryDate),
            "weightDigits": (parsed.weight ?? "").filter(\.isNumber),
            "commodity": parsed.commodity ?? "",
            "loadedMiles": parsed.loadedMiles.map { String(Int($0)) } ?? "",
            "rate": parsed.rate.map { String(Int($0)) } ?? "",
            "brokerName": parsed.brokerName ?? "",
            "brokerEmail": parsed.brokerEmail ?? "",
            "brokerEmailOwnerBlocked": ((parsed.brokerEmail ?? "").localizedCaseInsensitiveContains("sacredpathway") || (parsed.brokerEmail ?? "").localizedCaseInsensitiveContains("jamie@") ? "false" : "true"),
            "poNumber": parsed.poNumber ?? "",
            "bolNumber": parsed.bolNumber ?? "",
            "brokerMarkerBlocked": ((parsed.brokerName ?? "").localizedCaseInsensitiveContains("OCR PAGE") ? "false" : "true"),
            "brokerTitleBlocked": (isGenericConfirmationTitle(parsed.brokerName ?? "") ? "false" : "true"),
            "loadGarbageBlocked": ((parsed.loadNumber ?? "").localizedCaseInsensitiveContains("tential") ? "false" : "true")
        ]
        let failures = expected.compactMap { key, value -> String? in
            actual[key] == value ? nil : "\(key): expected \(value), got \(actual[key] ?? "<nil>")"
        }
        return ParserRegressionResult(
            name: "NT Logistics rate confirmation",
            passed: failures.isEmpty,
            expected: expected,
            actual: actual,
            failures: failures
        )
    }

    private static func poLoadNormalizationLoadOnlyRegression() -> ParserRegressionResult {
        let parsed = parseText("""
        Rate Confirmation
        Load Number: LOAD12345
        Carrier Freight Pay: $1200.00
        """)
        return parserRegressionResult(
            name: "PO/Load normalization - load only",
            expected: ["loadNumber": "LOAD12345", "poNumber": "LOAD12345"],
            actual: ["loadNumber": parsed.loadNumber ?? "", "poNumber": parsed.poNumber ?? ""]
        )
    }

    private static func poLoadNormalizationPOOnlyRegression() -> ParserRegressionResult {
        let parsed = parseText("""
        Rate Confirmation
        PO Number: PO98765
        Carrier Freight Pay: $1200.00
        """)
        return parserRegressionResult(
            name: "PO/Load normalization - PO only",
            expected: ["loadNumber": "PO98765", "poNumber": "PO98765"],
            actual: ["loadNumber": parsed.loadNumber ?? "", "poNumber": parsed.poNumber ?? ""]
        )
    }

    private static func poLoadNormalizationIdenticalRegression() -> ParserRegressionResult {
        let parsed = parseText("""
        Rate Confirmation
        Load Number: SAME12345
        PO Number: SAME12345
        Carrier Freight Pay: $1200.00
        """)
        return parserRegressionResult(
            name: "PO/Load normalization - identical",
            expected: ["loadNumber": "SAME12345", "poNumber": "SAME12345"],
            actual: ["loadNumber": parsed.loadNumber ?? "", "poNumber": parsed.poNumber ?? ""]
        )
    }

    private static func poLoadNormalizationDifferentRegression() -> ParserRegressionResult {
        let parsed = parseText("""
        Rate Confirmation
        Load Number: LOAD12345
        PO Number: PO98765
        Carrier Freight Pay: $1200.00
        """)
        return parserRegressionResult(
            name: "PO/Load normalization - different values",
            expected: ["loadNumber": "LOAD12345", "poNumber": "PO98765"],
            actual: ["loadNumber": parsed.loadNumber ?? "", "poNumber": parsed.poNumber ?? ""]
        )
    }

    private static func parserRegressionResult(name: String,
                                               expected: [String: String],
                                               actual: [String: String]) -> ParserRegressionResult {
        let failures = expected.compactMap { key, value -> String? in
            actual[key] == value ? nil : "\(key): expected \(value), got \(actual[key] ?? "<nil>")"
        }
        return ParserRegressionResult(
            name: name,
            passed: failures.isEmpty,
            expected: expected,
            actual: actual,
            failures: failures
        )
    }

    private static func debugDateString(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter.string(from: date)
    }

    // MARK: Fuel receipt regression fixtures (common + messy)

    static func runFuelReceiptParserRegressionTests() -> [ParserRegressionResult] {
        [lovesFuelReceiptRegression(), messyPilotFuelReceiptRegression()]
    }

    private static func lovesFuelReceiptRegression() -> ParserRegressionResult {
        let parsed = parseFuelReceiptText("""
        LOVE'S TRAVEL STOP #356
        AMARILLO, TX
        1-800-555-0142
        Pump 07
        DIESEL  125.482 GAL @ $3.899/GAL  $489.25
        DEF  4.250 GAL @ $2.799/GAL  $11.90
        SUBTOTAL  $501.15
        TAX  $0.00
        TOTAL DUE  $501.15
        VISA XXXX1234 AUTH 004521
        06/10/2026 14:32
        """)
        return parserRegressionResult(
            name: "Love's diesel + DEF receipt",
            expected: ["dieselGalInt": "125", "dieselAmt": "489.25",
                       "defGalInt": "4", "defAmt": "11.90",
                       "total": "501.15", "payment": "VISA", "hasLocation": "true"],
            actual: [
                "dieselGalInt": parsed.gallons.map { String(Int($0)) } ?? "",
                "dieselAmt": parsed.dieselAmount.map { String(format: "%.2f", $0) } ?? "",
                "defGalInt": parsed.defGallons.map { String(Int($0)) } ?? "",
                "defAmt": parsed.defAmount.map { String(format: "%.2f", $0) } ?? "",
                "total": parsed.totalAmount.map { String(format: "%.2f", $0) } ?? "",
                "payment": parsed.paymentMethod ?? "",
                "hasLocation": (parsed.location?.isEmpty == false) ? "true" : "false"
            ]
        )
    }

    private static func messyPilotFuelReceiptRegression() -> ParserRegressionResult {
        let parsed = parseFuelReceiptText("""
        Pilot Travel Center
        store #4421
        THANK YOU FOR YOUR BUSINESS
        DEISEL
        GAL 98.7
        $ / GAL 3.759
        SUBTOTAL 371.01
        TAX 0.00
        GRAND TOTAL $371.01
        REWARDS 8829301
        """)
        return parserRegressionResult(
            name: "Pilot fuel receipt (messy)",
            expected: ["vendor": "Pilot", "total": "371.01", "rewardsNotTotal": "true"],
            actual: [
                "vendor": parsed.vendorName ?? "",
                "total": parsed.totalAmount.map { String(format: "%.2f", $0) } ?? "",
                "rewardsNotTotal": (parsed.totalAmount.map { abs($0 - 8_829_301) > 1 } ?? true) ? "true" : "false"
            ]
        )
    }
    #endif

    // MARK: - OCR

    /// Apple Vision text recognition. Returns lines top-to-bottom in
    /// approximate reading order.
    static func recognizeText(in image: UIImage) async -> [String] {
        guard let cg = image.cgImage else { return [] }
        let primaryOrientation = CGImagePropertyOrientation(image.imageOrientation)
        let primary = await recognizeText(in: cg, orientation: primaryOrientation)
        var best = primary
        var bestOrientation = primaryOrientation

        if primary.score >= OCRCandidate.reliableScore {
            return await linesWithLoadTableSupplement(primary.lines, cgImage: cg, orientation: primaryOrientation)
        }

        for orientation in fallbackOrientations(excluding: primaryOrientation) {
            let candidate = await recognizeText(in: cg, orientation: orientation)
            if candidate.score > best.score {
                best = candidate
                bestOrientation = orientation
            }
            if candidate.score >= OCRCandidate.reliableScore {
                break
            }
        }

        return await linesWithLoadTableSupplement(best.lines, cgImage: cg, orientation: bestOrientation)
    }

    // The app target defaults declarations to MainActor. Vision invokes its
    // completion handler on the executor performing the request, so this
    // low-level bridge must not inherit MainActor isolation. Keeping only this
    // bridge nonisolated confines VNRequest/VNImageRequestHandler and their
    // callback to the worker queue; higher-level parsing and every observable
    // UI mutation retain their existing actor isolation.
    nonisolated private static func recognizeText(in cgImage: CGImage,
                                                  orientation: CGImagePropertyOrientation,
                                                  regionOfInterest: CGRect? = nil) async -> OCRCandidate {
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let observations = req.results as? [VNRecognizedTextObservation] ?? []
                // Sort top-to-bottom (Vision uses normalized coords with origin at bottom-left).
                let sorted = observations.sorted {
                    let dy = abs($0.boundingBox.midY - $1.boundingBox.midY)
                    if dy > 0.012 { return $0.boundingBox.maxY > $1.boundingBox.maxY }
                    return $0.boundingBox.minX < $1.boundingBox.minX
                }
                let lines = sorted.compactMap { obs -> String? in
                    obs.topCandidates(1).first?.string
                }
                continuation.resume(returning: OCRCandidate(lines: lines))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // English first; Vision will still pick up numbers regardless.
            request.recognitionLanguages = ["en-US"]
            if let regionOfInterest {
                request.regionOfInterest = regionOfInterest
            }

            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: orientation,
                options: [:]
            )
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: OCRCandidate(lines: []))
                }
            }
        }
    }

    private static func linesWithLoadTableSupplement(_ lines: [String],
                                                     cgImage: CGImage,
                                                     orientation: CGImagePropertyOrientation) async -> [String] {
        let lower = lines.joined(separator: "\n").lowercased()
        let looksLikeRateCon = lower.contains("rate confirmation") ||
            lower.contains("carrier freight pay") ||
            lower.contains("total carrier pay") ||
            lower.contains("order:")
        guard looksLikeRateCon else { return lines }

        // Full-page Vision can miss narrow right-column table text on scanned
        // McLeod/NT Logistics confirmations. A small table-band pass recovers
        // fields like Commodity and Weight without letting signature/audit pages
        // populate freight fields; downstream load-section filtering still runs.
        let tableBands = [
            CGRect(x: 0.04, y: 0.54, width: 0.92, height: 0.24),
            CGRect(x: 0.50, y: 0.54, width: 0.48, height: 0.26)
        ]

        var merged = lines
        var seen = Set(lines.map { normalizedOCRLineKey($0) })
        for roi in tableBands {
            let candidate = await recognizeText(in: cgImage, orientation: orientation, regionOfInterest: roi)
            for line in candidate.lines {
                let key = normalizedOCRLineKey(line)
                guard !key.isEmpty, !seen.contains(key) else { continue }
                merged.append(line)
                seen.insert(key)
            }
        }
        return merged
    }

    private static func normalizedOCRLineKey(_ line: String) -> String {
        line.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fallbackOrientations(
        excluding primary: CGImagePropertyOrientation
    ) -> [CGImagePropertyOrientation] {
        [.up, .right, .left, .down]
            .filter { $0.rawValue != primary.rawValue }
    }

    private struct OCRCandidate {
        static let reliableScore = 28

        let lines: [String]

        var score: Int {
            let text = lines.joined(separator: "\n").lowercased()
            var total = min(lines.count, 40)

            for token in [
                "load", "pickup", "pick up", "delivery", "deliver",
                "broker", "carrier", "shipper", "receiver", "consignee",
                "rate", "total", "weight", "miles", "commodity"
            ] where text.contains(token) {
                total += 6
            }

            if text.range(of: #"\$\s?\d"#, options: .regularExpression) != nil {
                total += 8
            }
            if text.range(of: #"\b\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?\b"#,
                          options: .regularExpression) != nil {
                total += 5
            }
            if text.range(of: #"\b\d{4,6}\s?(?:lb|lbs|pounds)\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil {
                total += 5
            }

            return total
        }
    }

    // MARK: - Fuel receipt extraction

    static func extractFuelReceipt(fromLines lines: [String]) -> ParsedFuelReceiptFields {
        var out = ParsedFuelReceiptFields()
        out.rawText = lines.joined(separator: "\n")

        if let vendor = pickFuelReceiptVendor(lines: lines) {
            out.vendorName = vendor
            out.confidence["vendorName"] = 0.85
        }

        if let date = firstDate(in: out.rawText) {
            out.receiptDate = date
            out.confidence["receiptDate"] = 0.75
        }

        // ---- Region-based line-item extraction (NOT global regex) ----
        // Diesel and DEF are scanned as separate line regions (label line + up
        // to 2 following lines), so DEF's gallons/price never leak into diesel
        // and DEF is captured separately instead of being dropped.
        let scan = extractFuelLineItems(lines: lines)
        if let g = scan.diesel.gallons        { out.gallons = g;            out.confidence["gallons"] = 0.8 }
        if let p = scan.diesel.pricePerGallon { out.pricePerGallon = p;     out.confidence["pricePerGallon"] = 0.8 }
        if let a = scan.diesel.amount         { out.dieselAmount = a;       out.confidence["dieselAmount"] = 0.78 }
        if let g = scan.def.gallons           { out.defGallons = g;         out.confidence["defGallons"] = 0.75 }
        if let p = scan.def.pricePerGallon    { out.defPricePerGallon = p;  out.confidence["defPricePerGallon"] = 0.7 }
        if let a = scan.def.amount            { out.defAmount = a;          out.confidence["defAmount"] = 0.72 }

        // ---- Receipt total: prefer TOTAL/SALE/AMOUNT DUE, validate vs items ----
        out.totalAmount = selectReceiptTotal(
            lines: lines,
            dieselAmount: out.dieselAmount,
            defAmount: out.defAmount,
            confidence: &out.confidence
        )

        if let location = pickFuelReceiptLocation(lines: lines) {
            out.location = location
            out.confidence["location"] = 0.7
        }
        if let payment = pickFuelPayment(lines: lines) {
            out.paymentMethod = payment
            out.confidence["paymentMethod"] = 0.7
        }

        #if DEBUG
        print("───────── [FuelReceiptScan] RAW OCR ─────────")
        print(out.rawText)
        print("───────── [FuelReceiptScan] CANDIDATES ─────────")
        for line in scan.candidateLog { print("[FuelCandidates] \(line)") }
        print("[FuelCandidates] TOTAL candidates=\(totalCandidates(lines: lines))")
        print("───────── [FuelReceiptScan] SELECTED ─────────")
        print("[FuelReceiptScan] vendor=\(out.vendorName ?? "<nil>") location=\(out.location ?? "<nil>") payment=\(out.paymentMethod ?? "<nil>")")
        print("[FuelReceiptScan] DIESEL gal=\(out.gallons.map { String(format: "%.3f", $0) } ?? "nil") ppg=\(out.pricePerGallon.map { String(format: "%.3f", $0) } ?? "nil") amt=\(out.dieselAmount.map { String(format: "%.2f", $0) } ?? "nil")")
        print("[FuelReceiptScan] DEF    gal=\(out.defGallons.map { String(format: "%.3f", $0) } ?? "nil") ppg=\(out.defPricePerGallon.map { String(format: "%.3f", $0) } ?? "nil") amt=\(out.defAmount.map { String(format: "%.2f", $0) } ?? "nil")")
        print("[FuelReceiptScan] TOTAL=\(out.totalAmount.map { String(format: "%.2f", $0) } ?? "nil")  needsReview=\(out.needsReview)")
        #endif

        return out
    }

    // MARK: Fuel line-item parsing

    private struct FuelItem {
        var gallons: Double?
        var pricePerGallon: Double?
        var amount: Double?
    }

    private struct FuelLineScan {
        var diesel = FuelItem()
        var def = FuelItem()
        var candidateLog: [String] = []
    }

    private static func extractFuelLineItems(lines: [String]) -> FuelLineScan {
        var scan = FuelLineScan()
        let lower = lines.map { $0.lowercased() }

        func isDef(_ s: String) -> Bool { s.contains("def") || s.contains("diesel exhaust") }
        func isDiesel(_ s: String) -> Bool {
            guard !isDef(s) else { return false }
            return s.contains("diesel") || s.contains("dsl") || s.contains("ulsd")
                || s.contains("unleaded") || s.contains("reefer")
                || (s.contains("fuel") && !s.contains("total"))
        }
        // A following line that ends the fuel item (so totals/tax never pollute
        // an item region and get mistaken for gallons/price/amount).
        func isBoundary(_ s: String) -> Bool {
            s.contains("subtotal") || s.contains("sub total") || s.contains("total")
                || s.contains("amount due") || s.contains("balance") || s.contains("tax")
                || s.contains("change") || s.contains("sale")
        }

        // Label line + up to 2 following lines, stopping if the other item's
        // label appears (so diesel and DEF regions never overlap).
        func region(at idx: Int, stopWhen stop: (String) -> Bool) -> String {
            var parts = [lines[idx]]
            var i = idx + 1
            while i < lines.count, i <= idx + 2, !stop(lower[i]) {
                parts.append(lines[i]); i += 1
            }
            return parts.joined(separator: " ")
        }

        if let dIdx = lower.firstIndex(where: { isDiesel($0) }) {
            let text = region(at: dIdx, stopWhen: { isDef($0) || isBoundary($0) })
            let gals = fuelGallonsCandidates(in: text)
            let ppgs = fuelPPGCandidates(in: text)
            let amts = fuelAmountCandidates(in: text)
            scan.diesel.gallons = gals.first
            scan.diesel.pricePerGallon = ppgs.first
            scan.diesel.amount = bestAmount(amts, gallons: gals.first, ppg: ppgs.first)
            reconcileFuelItem(&scan.diesel)
            scan.candidateLog.append("DIESEL region=\"\(text.prefix(70))\" gal=\(gals) ppg=\(ppgs) amt=\(amts)")
        } else {
            scan.candidateLog.append("DIESEL: no diesel/fuel label line found")
        }

        if let fIdx = lower.firstIndex(where: { isDef($0) }) {
            let text = region(at: fIdx, stopWhen: { isDiesel($0) || isBoundary($0) })
            let gals = fuelGallonsCandidates(in: text)
            let ppgs = fuelPPGCandidates(in: text)
            let amts = fuelAmountCandidates(in: text)
            scan.def.gallons = gals.first
            scan.def.pricePerGallon = ppgs.first
            scan.def.amount = bestAmount(amts, gallons: gals.first, ppg: ppgs.first)
            reconcileFuelItem(&scan.def)
            scan.candidateLog.append("DEF region=\"\(text.prefix(70))\" gal=\(gals) ppg=\(ppgs) amt=\(amts)")
        } else {
            scan.candidateLog.append("DEF: no DEF label line found")
        }

        return scan
    }

    /// Volume candidates: numbers near gal/qty, plus standalone 3-decimal
    /// volumes (e.g. 125.482). Excludes prices and dollar amounts.
    private static func fuelGallonsCandidates(in text: String) -> [Double] {
        var vals: [Double] = []
        for p in [
            #"(?i)\b([0-9]{1,3}(?:\.[0-9]{1,3})?)\s*(?:gal|gals|gallon|gallons)\b"#,
            #"(?i)\b(?:gallons?|gals?|qty|quantity)\s*[:#]?\s*([0-9]{1,3}(?:\.[0-9]{1,3})?)\b"#
        ] {
            for raw in allMatches(text, pattern: p) {
                if let v = parseReceiptNumber(raw), (0.3...350).contains(v), !vals.contains(v) { vals.append(v) }
            }
        }
        for raw in allMatches(text, pattern: #"\b([0-9]{1,3}\.[0-9]{3})\b"#) {
            if let v = parseReceiptNumber(raw), (0.3...350).contains(v), !vals.contains(v) { vals.append(v) }
        }
        return vals
    }

    /// Price-per-gallon candidates: 1.00–9.999 near @ / /gal / price / ppg,
    /// plus standalone 3-decimal prices. Excludes volumes and totals.
    private static func fuelPPGCandidates(in text: String) -> [Double] {
        var vals: [Double] = []
        for p in [
            #"(?i)(?:@|/\s*gal|price\s*/?\s*gal|price\s*per\s*gal|ppg|unit\s*price|per\s*gal)\s*[:$ ]*\$?\s*([1-9]\.[0-9]{2,3})\b"#,
            #"(?i)\$?\s*([1-9]\.[0-9]{2,3})\s*/\s*(?:gal|gallon)\b"#
        ] {
            for raw in allMatches(text, pattern: p) {
                if let v = parseReceiptNumber(raw), (1.0...9.999).contains(v), !vals.contains(v) { vals.append(v) }
            }
        }
        for raw in allMatches(text, pattern: #"\b([1-9]\.[0-9]{3})\b"#) {
            if let v = parseReceiptNumber(raw), (1.0...9.999).contains(v), !vals.contains(v) { vals.append(v) }
        }
        return vals
    }

    /// Line-total candidates: $X.XX, or a 2-decimal number ≥ $10 (so a $3.89
    /// price-per-gallon is never mistaken for an amount). Largest first.
    private static func fuelAmountCandidates(in text: String) -> [Double] {
        var vals: [Double] = []
        for raw in allMatches(text, pattern: #"\$\s*([0-9]{1,4}(?:,[0-9]{3})*\.[0-9]{2})\b"#) {
            if let v = parseReceiptNumber(raw), (0.5...10000).contains(v), !vals.contains(v) { vals.append(v) }
        }
        for raw in allMatches(text, pattern: #"\b([0-9]{2,4}\.[0-9]{2})\b"#) {
            if let v = parseReceiptNumber(raw), (10.0...10000).contains(v), !vals.contains(v) { vals.append(v) }
        }
        return vals.sorted(by: >)
    }

    /// Pick the amount that best matches gallons × ppg; otherwise the largest.
    private static func bestAmount(_ amts: [Double], gallons: Double?, ppg: Double?) -> Double? {
        guard !amts.isEmpty else { return nil }
        if let g = gallons, let p = ppg {
            let target = g * p
            return amts.min(by: { abs($0 - target) < abs($1 - target) })
        }
        return amts.first
    }

    /// Fill any missing leg of gallons × price = amount from the other two.
    private static func reconcileFuelItem(_ item: inout FuelItem) {
        if item.amount == nil, let g = item.gallons, let p = item.pricePerGallon {
            item.amount = (g * p * 100).rounded() / 100
        }
        if item.pricePerGallon == nil, let g = item.gallons, let a = item.amount, g > 0 {
            let p = a / g
            if (1.0...9.999).contains(p) { item.pricePerGallon = (p * 1000).rounded() / 1000 }
        }
        if item.gallons == nil, let p = item.pricePerGallon, let a = item.amount, p > 0 {
            item.gallons = (a / p * 1000).rounded() / 1000
        }
    }

    /// Receipt total: prefer an explicit TOTAL/SALE/AMOUNT DUE line; else the
    /// sum of diesel + DEF; else the diesel amount (low confidence → review).
    private static func selectReceiptTotal(lines: [String],
                                           dieselAmount: Double?,
                                           defAmount: Double?,
                                           confidence: inout [String: Double]) -> Double? {
        let itemsSum: Double? = {
            let s = (dieselAmount ?? 0) + (defAmount ?? 0)
            return s > 0 ? (s * 100).rounded() / 100 : nil
        }()
        if let total = totalCandidates(lines: lines).first {
            confidence["totalAmount"] = 0.86
            if let s = itemsSum, total + 0.5 < s { confidence["totalAmount"] = 0.5 } // total < items → suspect
            return total
        }
        if let s = itemsSum {
            confidence["totalAmount"] = 0.6
            return s
        }
        if let d = dieselAmount {
            confidence["totalAmount"] = 0.4 // diesel only — force review
            return d
        }
        return nil
    }

    /// Explicit-total dollar amounts found on labeled lines, excluding
    /// subtotal/tax/auth/rewards/odometer/card etc. Last line wins (printed last).
    private static func totalCandidates(lines: [String]) -> [Double] {
        let good = ["grand total", "total sale", "total due", "amount due", "balance due",
                    "total paid", "sale total", "invoice total", "fuel total", "total"]
        let bad = ["subtotal", "sub total", "tax", "change", "cash back", "discount", "savings",
                   "auth", "approval", "rewards", "points", "odometer", "invoice #", "receipt #",
                   "card", "balance forward", "ppg", "per gal", "price"]
        var vals: [Double] = []
        for line in lines.reversed() {
            let l = line.lowercased()
            guard good.contains(where: { l.contains($0) }), !bad.contains(where: { l.contains($0) }) else { continue }
            if let raw = firstRegex(line, pattern: #"\$?\s*([0-9]{1,4}(?:,[0-9]{3})*\.[0-9]{2})\b"#),
               let v = parseReceiptNumber(raw), (0.01...10000).contains(v) {
                vals.append(v)
            }
        }
        return vals
    }

    private static func pickFuelReceiptVendor(lines: [String]) -> String? {
        let knownBrands: [(needle: String, name: String)] = [
            ("love's", "Love's"),
            ("loves", "Love's"),
            ("pilot", "Pilot"),
            ("flying j", "Flying J"),
            ("ta travel", "TA Travel Center"),
            ("travelcenters", "TA Travel Center"),
            ("petro", "Petro"),
            ("speedway", "Speedway"),
            ("shell", "Shell"),
            ("bp", "BP"),
            ("exxon", "Exxon"),
            ("mobil", "Mobil"),
            ("chevron", "Chevron"),
            ("marathon", "Marathon"),
            ("circle k", "Circle K"),
            ("quiktrip", "QuikTrip"),
            ("quicktrip", "QuikTrip"),
            ("casey's", "Casey's"),
            ("road ranger", "Road Ranger"),
            ("sapp bros", "Sapp Bros"),
            ("kum & go", "Kum & Go"),
            ("sheetz", "Sheetz"),
            ("kwik trip", "Kwik Trip"),
            ("kwik star", "Kwik Star"),
            ("maverik", "Maverik"),
            ("wawa", "Wawa"),
            ("racetrac", "RaceTrac"),
            ("buc-ee", "Buc-ee's"),
            ("bucees", "Buc-ee's"),
            ("ta petro", "TA Petro"),
            ("loves travel", "Love's")
        ]

        for line in lines.prefix(14) {
            let lower = line.lowercased()
            if let hit = knownBrands.first(where: { lower.contains($0.needle) }) {
                return hit.name
            }
        }

        for line in lines.prefix(10) {
            let candidate = line
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = candidate.lowercased()
            guard candidate.count >= 3,
                  candidate.count <= 50,
                  candidate.contains(where: { $0.isLetter }),
                  !matchesRegex(lower, pattern: #"(receipt|invoice|transaction|auth|approval|card|visa|mastercard|diesel|unleaded|gallons?|price|total|subtotal|tax|change|store\s*#|\d{3}[-.\s]\d{3})"#)
            else { continue }
            return candidate
        }

        return nil
    }

    private static func pickFuelReceiptTotal(lines: [String]) -> Double? {
        let goodLabels = [
            "grand total", "total sale", "total due", "amount due",
            "balance due", "total paid", "sale amount", "invoice total",
            "fuel total", "diesel total", "purchase", "total"
        ]
        let badLabels = [
            "subtotal", "tax", "change", "cash back", "discount", "savings",
            "auth", "approval", "balance forward", "price", "ppg", "per gal"
        ]

        for line in lines.reversed() {
            let lower = line.lowercased()
            guard goodLabels.contains(where: { lower.contains($0) }),
                  !badLabels.contains(where: { lower.contains($0) }) else { continue }
            if let raw = firstRegex(line, pattern: #"\$?\s*([0-9]{1,4}(?:,[0-9]{3})*(?:\.[0-9]{2}))\b"#),
               let value = parseReceiptNumber(raw),
               (0.01...10000).contains(value) {
                return value
            }
        }

        var candidates: [Double] = []
        for line in lines {
            let lower = line.lowercased()
            if matchesRegex(lower, pattern: #"(price|ppg|per\s*gal|gallons?|qty|quantity|subtotal|tax|discount|savings|auth|approval|change|cash\s*back)"#) {
                continue
            }
            candidates += allMatches(line, pattern: #"\$\s*([0-9]{1,4}(?:,[0-9]{3})*(?:\.[0-9]{2}))\b"#)
                .compactMap(parseReceiptNumber)
                .filter { (0.01...10000).contains($0) }
        }
        return candidates.max()
    }

    private static func pickFuelGallons(in text: String) -> Double? {
        let patterns = [
            #"(?i)\b([0-9]{1,4}(?:\.[0-9]{1,3})?)\s*(?:gal|gals|gallon|gallons)\b"#,
            #"(?i)\b(?:gallons?|gals?|qty|quantity)\s*[:#]?\s*([0-9]{1,4}(?:\.[0-9]{1,3})?)\b"#,
            #"(?i)\b(?:diesel|dsl|ulsd|fuel).{0,36}?\b([0-9]{1,4}\.[0-9]{1,3})\b.{0,12}(?:gal|gals|gallon|gallons)?"#
        ]

        for pattern in patterns {
            for raw in allMatches(text, pattern: pattern) {
                if let value = parseReceiptNumber(raw),
                   (1.0...500.0).contains(value) {
                    return value
                }
            }
        }
        return nil
    }

    private static func pickFuelPricePerGallon(in text: String) -> Double? {
        let patterns = [
            #"(?i)\$?\s*([1-9][0-9]?\.[0-9]{2,3})\s*/\s*(?:gal|gallon)"#,
            #"(?i)\b(?:price\s*/?\s*gal|price\s*per\s*gal|ppg|unit\s*price|fuel\s*price|rate)\s*[:$ ]*\$?\s*([1-9][0-9]?\.[0-9]{2,3})\b"#,
            #"(?i)@\s*\$?\s*([1-9][0-9]?\.[0-9]{2,3})\b"#
        ]

        for pattern in patterns {
            for raw in allMatches(text, pattern: pattern) {
                if let value = parseReceiptNumber(raw),
                   (1.0...15.0).contains(value) {
                    return value
                }
            }
        }
        return nil
    }

    private static func parseReceiptNumber(_ raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: #"[^0-9\.,]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: ",", with: "")
        return Double(cleaned)
    }

    /// "City, ST" near the top of the receipt; skips street/phone/label lines.
    private static func pickFuelReceiptLocation(lines: [String]) -> String? {
        for line in lines.prefix(12) {
            let lower = line.lowercased()
            if matchesRegex(lower, pattern: #"(receipt|invoice|auth|approval|card|visa|master|amex|discover|total|gallon|price|pump|store\s*#|\d{3}[-.\s]\d{3}[-.\s]\d{4})"#) {
                continue
            }
            if let match = firstRegex(line, pattern: #"([A-Za-z][A-Za-z .'-]{1,28},\s*[A-Z]{2})\b"#) {
                return match.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Payment method (and masked last-4 when present) — guards against treating
    /// auth/approval/reward numbers as a card number (those are the #1 false
    /// positives on fuel receipts).
    private static func pickFuelPayment(lines: [String]) -> String? {
        let cards: [(needle: String, name: String)] = [
            ("mastercard", "Mastercard"), ("master card", "Mastercard"),
            ("american express", "AMEX"), ("amex", "AMEX"),
            ("discover", "Discover"), ("visa", "VISA"),
            ("comdata", "Comdata"), ("fleet one", "Fleet One"),
            ("fuelman", "Fuelman"), ("efs", "EFS"), ("wex", "WEX"),
            ("debit", "Debit"), ("credit", "Credit"), ("cash", "Cash")
        ]
        for line in lines {
            let lower = line.lowercased()
            guard let hit = cards.first(where: { lower.contains($0.needle) }) else { continue }
            if !lower.contains("auth"), !lower.contains("approval"),
               let last4 = firstRegex(line, pattern: #"(?:x{2,4}|\*{2,4}|ending\s*(?:in)?\s*|acct\s*[:#]?\s*)([0-9]{4})\b"#) {
                return "\(hit.name) ••\(last4)"
            }
            return hit.name
        }
        return nil
    }

    // MARK: - Rate confirmation load-section extraction

    private struct LoadTextScope {
        let lines: [String]
        var joined: String { lines.joined(separator: "\n") }
    }

    /// Remove sections that are not load data before freight fields are parsed.
    /// Broker/contact metadata still uses the full OCR text; this scope is only
    /// for load number, stops, dates, weight, commodity, miles, and rate.
    private static func rateConfirmationLoadScope(lines: [String],
                                                  documentType: DocumentType) -> LoadTextScope {
        guard documentType != .recon else { return LoadTextScope(lines: lines) }

        var scoped: [String] = []
        var inIgnoredSection = false
        var sawLoadSignal = false

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()

            if isHardIgnoredLoadLine(lower) { continue }

            if startsIgnoredRateConSection(lower) {
                inIgnoredSection = true
                continue
            }

            if inIgnoredSection {
                if startsLoadDataSection(lower) {
                    inIgnoredSection = false
                } else {
                    continue
                }
            }

            if startsLoadDataSection(lower) || containsLoadDataSignal(lower) {
                sawLoadSignal = true
            }

            if sawLoadSignal || scoped.count < 80 {
                scoped.append(line)
            }
        }

        let fallback = scoped.isEmpty ? lines : scoped
        return LoadTextScope(lines: fallback)
    }

    private static func startsIgnoredRateConSection(_ lower: String) -> Bool {
        let patterns = [
            #"^\s*(audit\s*trail|audit\s*history|acceptance\s*(?:record|history)?|accepted\s*by|signature|signatures?|signed\s*by|electronic\s*signature|docusign)\b"#,
            #"^\s*(highway\s*audit\s*report|digital\s*signature\s*audit\s*trail)\b"#,
            #"^\s*(driver\s*information|driver\s*info|driver\s*details|carrier\s*contact|broker\s*contact|contact\s*information)\b"#,
            #"^\s*(legal\s*terms|terms\s*(?:and\s*conditions)?|conditions|contract\s*terms|tracking\s*instructions|macropoint|project44)\b"#
        ]
        return patterns.contains { matchesRegex(lower, pattern: $0) }
    }

    private static func startsLoadDataSection(_ lower: String) -> Bool {
        let patterns = [
            #"^\s*(load|order|shipment|rate\s*confirmation|pickup|pick[\-\s]?up|delivery|deliver\s*to|origin|destination|stops?|commodity|carrier\s*freight\s*pay|freight\s*pay|rate)\b"#,
            #"^\s*(shipper|receiver|consignee|charges|pay\s*summary|load\s*details|route)\b"#
        ]
        return patterns.contains { matchesRegex(lower, pattern: $0) }
    }

    private static func containsLoadDataSignal(_ lower: String) -> Bool {
        let signals = [
            "rate confirmation", "load number", "load #", "order #",
            "pickup", "delivery", "origin", "destination", "commodity",
            "weight", "miles", "carrier freight pay", "freight pay"
        ]
        return signals.contains { lower.contains($0) }
    }

    private static func isHardIgnoredLoadLine(_ lower: String) -> Bool {
        if matchesRegex(lower, pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#) {
            return true
        }
        if matchesRegex(lower, pattern: #"(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}"#) {
            return true
        }
        if matchesRegex(lower, pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#) {
            return true
        }

        let blocked = [
            "driver cell", "driver phone", "cell phone", "mobile phone",
            "tractor", "truck #", "truck number", "trailer", "trailer #",
            "broker phone", "broker email", "email:", "phone:", "fax:",
            "ip address", "audit id", "envelope id", "signature id",
            "rate confirmation id", "highway audit report",
            "accepted by", "accepted at", "acceptance", "docusign",
            "terms and conditions", "legal terms", "privacy policy",
            "tracking instructions", "tracking required", "macropoint",
            "project44", "fourkites"
        ]
        return blocked.contains { lower.contains($0) }
    }

    /// Highest-confidence extraction for rate confirmations that OCR as table
    /// rows or label/value lists. This is intentionally conservative and only
    /// writes fields when the labels are explicit.
    private static func applyStructuredLoadTable(_ out: inout ParsedLoadFields,
                                                 lines: [String]) {
        let joined = lines.joined(separator: "\n")

        if let load = pickLoadNumberCandidate(lines: lines, joined: joined) {
            out.loadNumber = load
            out.confidence["loadNumber"] = 0.97
        }

        if let pickupLine = labeledRemainder(lines: lines, labels: ["pickup", "pick up", "origin", "ship from"]),
           let city = extractCityState(from: pickupLine) {
            out.pickupCityState = city
            out.confidence["pickupCityState"] = 0.96
            if let date = firstDate(in: pickupLine) {
                out.pickupDate = date
                out.confidence["pickupDate"] = 0.96
            }
        }
        if out.pickupCityState == nil,
           let city = firstRegex(joined, pattern: #"(?im)^\s*(?:pickup|pick[\-\s]?up|origin|ship\s*from)\b[^\n]*?\b([A-Z][A-Za-z\.\s\-']{1,40},\s*[A-Z]{2})\b"#) {
            out.pickupCityState = city
            out.confidence["pickupCityState"] = 0.94
        }

        if let deliveryLine = labeledRemainder(lines: lines, labels: ["delivery", "deliver to", "destination", "receiver", "consignee"]),
           let city = extractCityState(from: deliveryLine) {
            out.deliveryCityState = city
            out.confidence["deliveryCityState"] = 0.96
            if let date = firstDate(in: deliveryLine) {
                out.deliveryDate = date
                out.confidence["deliveryDate"] = 0.96
            }
        }
        if out.deliveryCityState == nil,
           let city = firstRegex(joined, pattern: #"(?im)^\s*(?:delivery|deliver\s*to|destination|receiver|consignee)\b[^\n]*?\b([A-Z][A-Za-z\.\s\-']{1,40},\s*[A-Z]{2})\b"#) {
            out.deliveryCityState = city
            out.confidence["deliveryCityState"] = 0.94
        }

        applyNumberedStopBlocks(&out, lines: lines)

        if out.pickupDate == nil,
           let raw = labeledValue(lines: lines, labels: ["pickup date", "pick up date", "ship date"], valuePattern: #"\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4}"#),
           let date = firstDate(in: raw) {
            out.pickupDate = date
            out.confidence["pickupDate"] = 0.95
        }
        if out.deliveryDate == nil,
           let raw = labeledValue(lines: lines, labels: ["delivery date", "deliver date", "drop date"], valuePattern: #"\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4}"#),
           let date = firstDate(in: raw) {
            out.deliveryDate = date
            out.confidence["deliveryDate"] = 0.95
        }

        if let raw = labeledValue(lines: lines, labels: ["weight", "gross weight", "shipment weight", "lbs", "lb"], valuePattern: #"[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]+)?|[0-9]{4,6}(?:\.[0-9]+)?(?:\s*(?:lbs?|lb|pounds?))?"#),
           let value = parseWeightNumber(raw) {
            out.weight = formatWeight(value, unit: inferWeightUnit(from: raw) ?? "lbs")
            out.confidence["weight"] = 0.97
        }

        if let commodity = labeledRemainder(lines: lines, labels: ["commodity", "product", "description"]),
           isPlausibleCommodity(commodity) {
            out.commodity = commodity.trimmingCharacters(in: .whitespacesAndNewlines)
            out.confidence["commodity"] = 0.96
        }

        if let raw = labeledValue(lines: lines, labels: ["miles", "loaded miles", "trip miles", "distance"], valuePattern: #"[0-9]{2,5}"#),
           let miles = Double(raw.replacingOccurrences(of: ",", with: "")),
           miles > 0, miles < 5_000 {
            out.loadedMiles = miles
            out.confidence["loadedMiles"] = 0.96
        }

        if let raw = labeledValue(lines: lines, labels: ["carrier freight pay", "freight pay", "carrier pay", "carrier rate", "rate"], valuePattern: #"\$?\s*[0-9]{3,6}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?"#),
           let rate = parseMoney(raw),
           rate >= 200, rate <= 50_000 {
            out.rate = rate
            out.confidence["rate"] = 0.97
        }

        // OCR often emits a two-row table:
        // Order Pickup Delivery Weight Commodity Miles Carrier Freight Pay
        // 0527290 El Dorado, AR 06/03/2026 Lovell, WY 06/05/2026 ...
        if shouldApplyNTStyleTableFallback(to: out),
           let table = parseCompactLoadTable(lines: lines) {
            table.apply(to: &out)
        }
    }

    private struct LoadIDCandidate {
        let value: String
        let source: String
        let accepted: Bool
        let reason: String
        let score: Int
    }

    private static func pickLoadNumberCandidate(lines: [String], joined: String) -> String? {
        var candidates: [LoadIDCandidate] = []
        let labels: [(label: String, priority: Int)] = [
            ("customer load number", 100),
            ("load number", 98),
            ("load", 96),
            ("order", 94),
            ("shipment number", 90),
            ("shipment", 88),
            ("mcleod", 86),
            ("reference number", 70),
            ("po number", 60),
            ("bol number", 50)
        ]
        let valuePattern = #"[A-Z0-9][A-Z0-9\-]{3,20}"#

        for (idx, line) in lines.enumerated() {
            for (label, priority) in labels {
                let escaped = label.replacingOccurrences(of: " ", with: #"\s*"#)
                let sameLine = #"(?i)\b"# + escaped + #"\b[ \t]*(?:number|no\.?|num\.?|id|#)?[ \t]*[:#\-]?[ \t]*("# + valuePattern + #")"#
                if let raw = firstRegex(line, pattern: sameLine) {
                    let value = raw.cleanID
                    let rejection = loadIdentifierRejectionReason(value: value, source: line, label: label)
                    candidates.append(LoadIDCandidate(
                        value: value,
                        source: "same-line \(label): \(line)",
                        accepted: rejection == nil,
                        reason: rejection ?? "explicit \(label) label",
                        score: rejection == nil ? priority + loadIdentifierValueBonus(value) : 0
                    ))
                }

                guard matchesRegex(line, pattern: #"(?i)^\s*"# + escaped + #"\b"#) else { continue }
                for offset in 1...6 {
                    let valueIndex = idx + offset
                    guard valueIndex < lines.count else { break }
                    let next = lines[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                    if isHardIgnoredLoadLine(next.lowercased()) { continue }
                    guard let raw = firstRegex(next, pattern: #"(?i)\b("# + valuePattern + #")\b"#) else {
                        candidates.append(LoadIDCandidate(
                            value: next,
                            source: "near \(label) +\(offset): \(next)",
                            accepted: false,
                            reason: "no identifier-shaped token",
                            score: 0
                        ))
                        continue
                    }
                    let value = raw.cleanID
                    let context = weightContext(lines: lines, around: valueIndex, radius: 2)
                    let rejection = loadIdentifierRejectionReason(value: value, source: context, label: label)
                    candidates.append(LoadIDCandidate(
                        value: value,
                        source: "near \(label) +\(offset): \(next)",
                        accepted: rejection == nil,
                        reason: rejection ?? "near explicit \(label) label",
                        score: rejection == nil ? priority + loadIdentifierValueBonus(value) - offset : 0
                    ))
                }
            }
        }

        for raw in allMatches(joined, pattern: #"(?i)\border\s+([0-9]{5,12})\b"#) {
            let value = raw.cleanID
            let rejection = loadIdentifierRejectionReason(value: value, source: "joined order pattern", label: "order")
            candidates.append(LoadIDCandidate(
                value: value,
                source: "joined order pattern",
                accepted: rejection == nil,
                reason: rejection ?? "joined Order value",
                score: rejection == nil ? 94 + loadIdentifierValueBonus(value) : 0
            ))
        }

        let winner = candidates
            .filter(\.accepted)
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.value.count > $1.value.count
            }
            .first?.value

        #if DEBUG
        logLoadIDCandidates(candidates, winner: winner)
        #endif
        return winner
    }

    private static func loadIdentifierRejectionReason(value: String, source: String, label: String) -> String? {
        guard cleanFreightIdentifier(value) != nil else { return "not a plausible freight identifier" }
        let lowerSource = source.lowercased()
        if lowerSource.contains("trailer") || lowerSource.contains("tractor") || lowerSource.contains("truck") {
            return "equipment context"
        }
        if lowerSource.contains("driver") || lowerSource.contains("phone") || lowerSource.contains("email") {
            return "contact context"
        }
        if lowerSource.contains("address") || lowerSource.contains("warren parkway") || lowerSource.contains("suite") {
            return "address context"
        }
        if value.allSatisfy(\.isNumber), value.count <= 4 {
            return "too short numeric identifier"
        }
        if value.allSatisfy(\.isNumber), value.count == 5,
           matchesRegex(lowerSource, pattern: #"\b(?:zip|[a-z]{2}\s+\d{5})\b"#) {
            return "zip/address context"
        }
        if value.uppercased().hasPrefix("TV") || value.uppercased().hasPrefix("TRL") || value.uppercased().hasPrefix("TR") {
            return "trailer-shaped identifier"
        }
        if label.lowercased().contains("bol"), !value.contains(where: { $0.isNumber }) {
            return "BOL candidate has no digits"
        }
        return nil
    }

    private static func loadIdentifierValueBonus(_ value: String) -> Int {
        var bonus = 0
        if value.allSatisfy(\.isNumber) { bonus += 5 }
        if value.count >= 6 { bonus += 4 }
        if value.count >= 7 { bonus += 2 }
        if value.contains(where: \.isLetter) { bonus -= 3 }
        return bonus
    }

    private static func applyNumberedStopBlocks(_ out: inout ParsedLoadFields, lines: [String]) {
        let pickupIndexes = lines.indices.filter {
            matchesRegex(lines[$0], pattern: #"(?i)^\s*(?:PU|PICK\s*UP|PICKUP)\s*\d*\b"#)
        }
        let deliveryIndexes = lines.indices.filter {
            matchesRegex(lines[$0], pattern: #"(?i)^\s*(?:SO|DELIVERY|DELIVER\s*TO|DROP)\s*\d*\b"#)
        }

        if out.pickupAddress == nil || out.pickupCityState == nil || out.shipperName == nil,
           let idx = pickupIndexes.first {
            let block = blockAt(lines: lines, startIndex: idx)
            if out.pickupAddress == nil, let address = block.address {
                out.pickupAddress = address
                out.confidence["pickupAddress"] = 0.9
            }
            if out.pickupCityState == nil, let city = block.cityState {
                out.pickupCityState = city
                out.confidence["pickupCityState"] = 0.9
            }
            if out.shipperName == nil, let name = block.companyName {
                out.shipperName = name
                out.confidence["shipperName"] = 0.75
            }
            if out.pickupDate == nil, let date = firstDate(in: block.allText) {
                out.pickupDate = date
                out.confidence["pickupDate"] = 0.9
            }
        }

        if out.deliveryAddress == nil || out.deliveryCityState == nil || out.receiverName == nil,
           let idx = deliveryIndexes.first {
            let block = blockAt(lines: lines, startIndex: idx)
            if out.deliveryAddress == nil, let address = block.address {
                out.deliveryAddress = address
                out.confidence["deliveryAddress"] = 0.9
            }
            if out.deliveryCityState == nil, let city = block.cityState {
                out.deliveryCityState = city
                out.confidence["deliveryCityState"] = 0.9
            }
            if out.receiverName == nil, let name = block.companyName {
                out.receiverName = name
                out.confidence["receiverName"] = 0.75
            }
            if out.deliveryDate == nil, let date = firstDate(in: block.allText) {
                out.deliveryDate = date
                out.confidence["deliveryDate"] = 0.9
            }
        }
    }

    private static func applyExplicitStopAddressFallbacks(_ out: inout ParsedLoadFields, lines: [String]) {
        func fillAddress(from anchors: [String], assign: (String) -> Void, current: String?) {
            guard current == nil || current?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true else { return }
            for (idx, line) in lines.enumerated() {
                let lower = line.lowercased()
                guard anchors.contains(where: { lower.hasPrefix($0) || lower.contains($0) }) else { continue }
                let end = stopBlockEndIndex(lines: lines, startIndex: idx)
                guard idx < end else { continue }
                let block = Array(lines[idx..<end])

                for (offset, blockLine) in block.enumerated() {
                    let blockLower = blockLine.lowercased()
                    if blockLower.hasPrefix("address") {
                        for candidate in block.dropFirst(offset + 1).prefix(6) {
                            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                            if isStreetAddressLine(trimmed) {
                                assign(trimmed)
                                return
                            }
                        }
                    }
                }

                if let street = block.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .first(where: isStreetAddressLine(_:)) {
                    assign(street)
                    return
                }
            }
        }

        fillAddress(
            from: ["pu ", "pickup", "pick up", "origin", "ship from"],
            assign: {
                out.pickupAddress = $0
                out.confidence["pickupAddress"] = max(out.confidence["pickupAddress"] ?? 0, 0.92)
            },
            current: out.pickupAddress
        )
        fillAddress(
            from: ["so ", "delivery", "deliver to", "drop", "receiver", "consignee", "destination"],
            assign: {
                out.deliveryAddress = $0
                out.confidence["deliveryAddress"] = max(out.confidence["deliveryAddress"] ?? 0, 0.92)
            },
            current: out.deliveryAddress
        )
    }

    private static func isStreetAddressLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard !trimmed.isEmpty else { return false }
        if lower.hasPrefix("po box") { return true }
        guard matchesRegex(trimmed, pattern: #"^\s*\d{1,6}\s+[A-Za-z0-9]"#) else { return false }
        if firstDate(in: trimmed) != nil { return false }
        if matchesRegex(lower, pattern: #"\b(?:phone|fax|mc|dot|usdot|load|order|weight|miles|rate|total|carrier\s*pay)\b"#) {
            return false
        }
        return true
    }

    private struct CompactLoadTable {
        let loadNumber: String
        let pickupCityState: String
        let deliveryCityState: String
        let pickupDate: Date?
        let deliveryDate: Date?
        let weight: Int?
        let commodity: String?
        let miles: Double?
        let rate: Double?

        func apply(to out: inout ParsedLoadFields) {
            out.loadNumber = loadNumber
            out.confidence["loadNumber"] = max(out.confidence["loadNumber"] ?? 0, 0.98)
            out.pickupCityState = pickupCityState
            out.confidence["pickupCityState"] = max(out.confidence["pickupCityState"] ?? 0, 0.98)
            out.deliveryCityState = deliveryCityState
            out.confidence["deliveryCityState"] = max(out.confidence["deliveryCityState"] ?? 0, 0.98)
            if let pickupDate {
                out.pickupDate = pickupDate
                out.confidence["pickupDate"] = max(out.confidence["pickupDate"] ?? 0, 0.98)
            }
            if let deliveryDate {
                out.deliveryDate = deliveryDate
                out.confidence["deliveryDate"] = max(out.confidence["deliveryDate"] ?? 0, 0.98)
            }
            if let weight {
                out.weight = formatWeight(weight, unit: "lbs")
                out.confidence["weight"] = max(out.confidence["weight"] ?? 0, 0.98)
            }
            if let commodity {
                out.commodity = commodity
                out.confidence["commodity"] = max(out.confidence["commodity"] ?? 0, 0.98)
            }
            if let miles {
                out.loadedMiles = miles
                out.confidence["loadedMiles"] = max(out.confidence["loadedMiles"] ?? 0, 0.98)
            }
            if let rate {
                out.rate = rate
                out.confidence["rate"] = max(out.confidence["rate"] ?? 0, 0.98)
            }
        }
    }

    private static func shouldApplyNTStyleTableFallback(to out: ParsedLoadFields) -> Bool {
        out.loadNumber == nil ||
        out.pickupCityState == nil ||
        out.deliveryCityState == nil ||
        out.weight == nil ||
        out.commodity == nil ||
        out.loadedMiles == nil ||
        out.rate == nil
    }

    private static func parseCompactLoadTable(lines: [String]) -> CompactLoadTable? {
        let text = lines.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        let pattern = #"(?i)\b(?:order|load)\b[^\n]{0,250}?\b([0-9]{5,12})\b[^\n]{0,120}?\b([A-Z][A-Za-z\.\s\-']{1,35},\s*[A-Z]{2})\b[^\n]{0,80}?(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})[^\n]{0,160}?\b([A-Z][A-Za-z\.\s\-']{1,35},\s*[A-Z]{2})\b[^\n]{0,80}?(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})[^\n]{0,160}?\b([0-9]{4,6})\b[^\n]{0,160}?\b([0-9]{2,5})\b[^\n]{0,80}?\$?\s*([0-9]{3,6}(?:\.[0-9]{1,2})?)\b"#
        guard let captures = firstCaptureGroups(text, pattern: pattern),
              captures.count >= 8
        else { return nil }

        let loadNumber = captures[0].cleanID
        let pickup = captures[1].trimmingCharacters(in: .whitespaces)
        let pickupDate = firstDate(in: captures[2])
        let delivery = captures[3].trimmingCharacters(in: .whitespaces)
        let deliveryDate = firstDate(in: captures[4])
        let weight = Int(captures[5].replacingOccurrences(of: ",", with: ""))
        let miles = Double(captures[6].replacingOccurrences(of: ",", with: ""))
        let rate = parseMoney(captures[7])

        let commodity = extractCommodityBetweenWeightAndMiles(text: text, weightRaw: captures[5], milesRaw: captures[6])

        guard loadNumber.contains(where: { $0.isNumber }),
              pickup.contains(","),
              delivery.contains(",")
        else { return nil }

        return CompactLoadTable(
            loadNumber: loadNumber,
            pickupCityState: pickup,
            deliveryCityState: delivery,
            pickupDate: pickupDate,
            deliveryDate: deliveryDate,
            weight: weight,
            commodity: commodity,
            miles: miles,
            rate: rate
        )
    }

    private static func extractCommodityBetweenWeightAndMiles(text: String,
                                                              weightRaw: String,
                                                              milesRaw: String) -> String? {
        let escapedWeight = NSRegularExpression.escapedPattern(for: weightRaw)
        let escapedMiles = NSRegularExpression.escapedPattern(for: milesRaw)
        let pattern = escapedWeight + #"\s+(.*?)\s+"# + escapedMiles
        guard let raw = firstRegex(text, pattern: pattern) else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: #"(?i)\b(?:lbs?|pounds?|weight|commodity|miles?)\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return isPlausibleCommodity(cleaned) ? cleaned : nil
    }

    private static func labeledValue(lines: [String],
                                     labels: [String],
                                     valuePattern: String) -> String? {
        for (idx, line) in lines.enumerated() {
            for label in labels {
                let escaped = label.replacingOccurrences(of: " ", with: #"\s*"#)
                let sameLine = #"(?i)\b"# + escaped + #"\b[ \t]*(?:number|no\.?|num\.?|id|#|date)?[ \t]*[:#\-]?[ \t]*("# + valuePattern + #")"#
                if let value = firstRegex(line, pattern: sameLine) {
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if matchesRegex(line, pattern: #"(?i)^\s*"# + escaped + #"\b"#), idx + 1 < lines.count {
                    if let value = firstRegex(lines[idx + 1], pattern: #"(?i)^\s*("# + valuePattern + #")\b"#) {
                        return value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        return nil
    }

    private static func labeledRemainder(lines: [String], labels: [String]) -> String? {
        for (idx, line) in lines.enumerated() {
            for label in labels {
                let escaped = label.replacingOccurrences(of: " ", with: #"\s*"#)
                let pattern = #"(?i)^\s*"# + escaped + #"\b[ \t]*(?:date|location|city|state)?[ \t]*[:#\-]?[ \t]*(.+?)\s*$"#
                if let value = firstRegex(line, pattern: pattern) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, !isHardIgnoredLoadLine(trimmed.lowercased()) {
                        return trimmed
                    }
                }
                if matchesRegex(line, pattern: #"(?i)^\s*"# + escaped + #"\b"#), idx + 1 < lines.count {
                    let next = lines[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !next.isEmpty, !isHardIgnoredLoadLine(next.lowercased()) {
                        return next
                    }
                }
            }
        }
        return nil
    }

    private static func extractCityState(from text: String) -> String? {
        firstRegex(text, pattern: #"\b([A-Z][A-Za-z\.\s\-']{1,40},\s*[A-Z]{2})(?:\s+\d{5})?\b"#)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isPlausibleCommodity(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.count <= 80 else { return false }
        let lower = trimmed.lowercased()
        let blocked = [
            "phone", "email", "signature", "accepted", "audit",
            "terms", "conditions", "tracking", "driver", "tractor",
            "trailer", "rate", "miles", "weight"
        ]
        guard !blocked.contains(where: { lower.contains($0) }) else { return false }
        return trimmed.contains(where: { $0.isLetter })
    }

    private static func formatWeight(_ value: Int, unit: String) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.locale = Locale(identifier: "en_US")
        let formatted = fmt.string(from: NSNumber(value: value)) ?? String(value)
        return "\(formatted) \(unit)"
    }

    private static func sanitizedOCRLinesForFieldExtraction(_ lines: [String]) -> [String] {
        lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isOCRDebugMarker($0) }
    }

    private static func isOCRDebugMarker(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if matchesRegex(text, pattern: #"(?i)^=*\s*OCR\s+PAGE\s+\d+\s*=*$"#) { return true }
        if matchesRegex(text, pattern: #"(?i)^[-=]{3,}\s*(?:PAGE|OCR|OCR\s+PAGE).*$"#) { return true }
        return false
    }

    private static func cleanFreightIdentifier(_ raw: String, minDigits: Int = 1) -> String? {
        let value = raw.cleanID
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard value.count >= 4, value.count <= 24 else { return nil }
        guard !isOCRDebugMarker(value) else { return nil }
        let digitCount = value.filter(\.isNumber).count
        guard digitCount >= minDigits else { return nil }

        let lower = value.lowercased()
        let blockedExact: Set<String> = [
            "tential", "clearly", "potential", "reference", "pickup", "delivery",
            "carrier", "broker", "driver", "phone", "email", "number", "commodity",
            "weight", "miles", "rate", "order", "shipment", "signature", "accepted"
        ]
        guard !blockedExact.contains(lower) else { return nil }
        guard !lower.contains("ocr page") else { return nil }
        guard !matchesRegex(value, pattern: #"^\d{1,3}(?:\.\d{1,3}){3}$"#) else { return nil }
        guard !matchesRegex(value, pattern: #"^\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4}$"#) else { return nil }
        return value
    }

    private static func sanitizeIdentifierFields(_ out: inout ParsedLoadFields) {
        if let value = out.loadNumber, cleanFreightIdentifier(value) == nil {
            out.loadNumber = nil
            out.confidence["loadNumber"] = nil
        }
        if let value = out.poNumber, cleanFreightIdentifier(value) == nil {
            out.poNumber = nil
            out.confidence["poNumber"] = nil
        }
        if let value = out.pickupNumber, cleanFreightIdentifier(value) == nil {
            out.pickupNumber = nil
            out.confidence["pickupNumber"] = nil
        }
        if let value = out.referenceNumber, cleanFreightIdentifier(value) == nil {
            out.referenceNumber = nil
            out.confidence["referenceNumber"] = nil
        }
        if let value = out.bolNumber, cleanFreightIdentifier(value) == nil {
            out.bolNumber = nil
            out.confidence["bolNumber"] = nil
        }
        if let value = out.brokerName,
           cleanBrokerName(
               value,
               documentText: out.rawText,
               explicitlyLabeled: hasExplicitBrokerLabel(value, in: out.rawText)
           ) == nil {
            out.brokerName = nil
            out.confidence["brokerName"] = nil
        }
    }

    // MARK: - Field extraction

    static func extractFields(fromLines lines: [String]) -> ParsedLoadFields {
        let originalLines = lines
        let lines = sanitizedOCRLinesForFieldExtraction(originalLines)
        var out = ParsedLoadFields()
        out.rawText = originalLines.joined(separator: "\n")
        let joined = lines.joined(separator: "\n")

        // ---- Pass 0: vendor + document-type detection ----
        // Document type informs which extractor strategy to favor. Recon /
        // settlement statements have a completely different layout (per-load
        // rows with sequence #s, settlement IDs, paid amounts) than rate
        // confirmations, and need their own load# / amount logic.
        out.sourceVendor = detectVendor(in: joined)
        out.documentType = detectDocumentType(in: joined)
        let loadScope = rateConfirmationLoadScope(lines: lines, documentType: out.documentType)
        let loadLines = loadScope.lines
        let loadJoined = loadScope.joined

        // Structured load tables are the highest-confidence source for actual
        // freight fields. They run before broad text regexes and only against
        // the sanitized load section so signature/audit/contact/legal pages
        // cannot populate load data.
        if out.documentType != .recon {
            applyStructuredLoadTable(&out, lines: loadLines)
        }

        // ---- Load number ----
        // NOTE: "reference|ref" intentionally REMOVED from this regex. On
        // reconciliation docs "Ref # 1234" is the small sequence/reference
        // ID, NOT the load number. Reference numbers are captured separately
        // below and routed into the Reference / Info field.
        //
        // Same-line restriction: [ \t]* (NOT \s*) so the label and value
        // must be on the same line. Without this a column-header label
        // would grab the next column header as the value (e.g.
        // "Load Number     Reference" → "Reference").
        let loadNumberPattern = #"(?i)\b(?:load|order|trip|pro|shipment)[ \t]*(?:number|no\.?|num\.?|id|#)?[ \t]*[:#\-]?[ \t]*([A-Z0-9][A-Z0-9\-]{3,20})"#
        for raw in allMatches(loadJoined, pattern: loadNumberPattern) {
            if out.loadNumber != nil,
               (out.confidence["loadNumber"] ?? 0) >= 0.94 { break }
            if let v = cleanFreightIdentifier(raw) {
                out.loadNumber = v
                out.confidence["loadNumber"] = max(out.confidence["loadNumber"] ?? 0, 0.82)
                break
            }
        }

        // ---- Broker MC number (broadened 2026-05-18) ----
        //
        // Real-world rate cons label the MC# in many ways. Try the most
        // specific patterns first so a generic "MC 12345" doesn't beat a
        // "Motor Carrier No. 12345" pair that's right next to the broker
        // name. The pattern intentionally accepts MC numbers with 5–8
        // digits — current FMCSA assignments are 6–7 digits, but 5-digit
        // numbers still exist on older carriers and 8-digit numbers are
        // reserved for future expansion.
        //
        // Order matters — first hit wins per pattern, but we keep walking
        // the list until something matches. Patterns are roughly ordered
        // by specificity / signal strength.
        let mcPatterns: [String] = [
            // "Motor Carrier No. 12345", "Motor Carrier Number 12345",
            // "Motor Carrier #: 12345", "Motor Carrier MC# 12345".
            #"(?i)\bmotor\s*carrier\s*(?:number|no\.?|#|mc\s*#?)\s*[:#\-]?\s*(\d{5,8})\b"#,
            // "Broker MC 12345", "Broker MC# 12345", "Broker MC: 12345".
            #"(?i)\bbroker\s*mc\s*[#:]?\s*(\d{5,8})\b"#,
            // "MC Number 12345", "MC No. 12345", "MC Num 12345".
            #"(?i)\bMC\s*(?:number|num\.?|no\.?|#)?\s*[:#\-]?\s*(\d{5,8})\b"#,
            // "MC# 12345" / "MC #12345" / "MC 12345" — the legacy pattern.
            #"(?i)\bMC\s*[#:]?\s*(\d{5,8})"#,
            // USDOT/MC paired block — "USDOT 1234567 MC 887766" or
            // "DOT# 1234567 / MC# 887766". Capture the MC half.
            #"(?i)\busdot\s*[#:]?\s*\d{6,8}\s*[\/\|\-,;]?\s*mc\s*[#:]?\s*(\d{5,8})\b"#,
            // "DOT 1234567 MC 887766" (no USDOT prefix).
            #"(?i)\bdot\s*[#:]?\s*\d{6,8}\s*[\/\|\-,;]?\s*mc\s*[#:]?\s*(\d{5,8})\b"#,
        ]
        var mcCandidates: [(value: String, pattern: String)] = []
        for pat in mcPatterns {
            for raw in allMatches(joined, pattern: pat) {
                // Reject patterns that grab a zip code (5 digits next to
                // a city/state) — MC numbers in production are 6+ digits
                // and we only allow 5-digit MCs when context is explicit
                // (the regex anchored them to an MC label, so this is
                // already constrained).
                mcCandidates.append((raw, pat))
            }
        }
        if let first = mcCandidates.first {
            out.brokerMcNumber = first.value.filter(\.isNumber)
            out.confidence["brokerMcNumber"] = 0.95
        }

        #if DEBUG
        let mcTag = "SP_DEBUG_RATECON"
        print("[\(mcTag)] MC candidates from OCR: \(mcCandidates.map { $0.value })")
        if let mc = out.brokerMcNumber {
            print("[\(mcTag)] MC final from OCR: \(mc)")
        } else {
            print("[\(mcTag)] MC not in OCR — caller can fall back to saved brokers.")
        }
        print("[DriverHub Parser] selected broker MC: \(out.brokerMcNumber ?? "<nil>")")
        #endif

        // ---- Broker name ----
        // Best signal in real rate cons: line containing "Broker:" or
        // appearing right above an MC number.
        if let m = firstRegex(joined, pattern: #"(?im)^\s*(?:broker|brokered\s*by|carrier\s*broker|booked\s*by)\s*[:\-]\s*(.+?)\s*$"#),
           let broker = cleanBrokerName(m, documentText: joined, explicitlyLabeled: true) {
            out.brokerName = broker
            out.confidence["brokerName"] = 0.85
        } else if let companyBroker = pickCompanyBrokerCandidate(lines: lines, documentText: joined) {
            out.brokerName = companyBroker
            out.confidence["brokerName"] = 0.8
        } else if let headerBroker = pickHeaderBroker(lines: lines, documentText: joined) {
            out.brokerName = headerBroker
            out.confidence["brokerName"] = 0.72
        } else {
            // Heuristic: first non-empty line that looks like a company
            // (contains LLC / Inc / Logistics / Transport / Freight /
            // Brokerage) and isn't obviously the carrier's own name.
            for line in lines.prefix(15) {
                let l = line.lowercased()
                if l.hasPrefix("carrier:") || l.hasPrefix("carrier ") { continue }
                if l.contains("logistics") || l.contains("freight") ||
                   l.contains("brokerage") || l.contains(" inc") ||
                   l.contains(" llc") || l.contains("transport") {
                    if let broker = cleanBrokerName(line, documentText: joined) {
                        out.brokerName = broker
                        out.confidence["brokerName"] = 0.55
                        break
                    }
                }
            }
        }
        if out.brokerName == nil,
           let ntBroker = ntLogisticsBrokerName(lines: lines, documentText: joined) {
            out.brokerName = ntBroker
            out.confidence["brokerName"] = 0.86
        }

        // ---- Phone numbers (broker phone = first phone we find) ----
        if let m = firstRegex(joined, pattern: #"(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}"#) {
            out.brokerPhone = m.normalizedPhone
            out.confidence["brokerPhone"] = 0.9
        }

        // ---- Phone extension ----
        // Recognises common phrasings printed next to a broker phone:
        //   "ext 4421", "Ext. 4421", "Ext: 4421", "x123", "x. 123".
        //
        // CRITICAL: the lookbehind `(?<=\d)` makes the extension marker only
        // fire when it immediately follows a digit (i.e. a phone number).
        // Without that anchor "TX 75201" / "Box 12345" would match because
        // a lone uppercase `X` looks like the "x123" extension form.
        if let m = firstRegex(joined, pattern: #"(?i)(?<=\d)[\s)\-.]{0,4}(?:ext(?:ension)?\.?|x\.?)\s*[:#]?\s*([0-9]{2,6})\b"#) {
            out.brokerPhoneExtension = m
            out.confidence["brokerPhoneExtension"] = 0.85
        }

        // ---- Email (scored 2026-05-18) ----
        //
        // Scoring vs. the old "first @ wins" heuristic:
        //   (a) Anchor proximity — within ±3 lines of the broker name,
        //       MC#, or phone block is the strongest signal.
        //   (b) Top-of-doc position — first 40% of lines gets a bonus.
        //   (c) HARD REJECT — drop any email whose line OR ±1 neighbour
        //       lines mention factoring / accounting / billing / AR /
        //       AP / remittance / disclaimer / terms / privacy /
        //       copyright / powered by / "send invoices" / payments.
        //   (d) Prefer emails whose local-part contains a letter (not a
        //       pure numeric ID like 12345@some-system.com).
        // The old "grab the first @" heuristic was pulling AR / factoring
        // emails out of the bottom-of-page billing disclaimer.
        if let picked = pickBrokerEmail(
            lines: lines,
            brokerName: out.brokerName,
            brokerPhone: out.brokerPhone,
            brokerMcNumber: out.brokerMcNumber
        ) {
            out.brokerEmail = picked.email
            out.confidence["brokerEmail"] = picked.confidence
        }

        // Crash-bisect 2026-05-17: temporarily disabled the new broker-
        // contact-name extraction. The user can still type the rep name by
        // hand in the review screen; we just won't auto-detect it for now.
        // If the device still crashes with this disabled, the regression is
        // not in the parser additions.
        //
        // out.brokerContactName = Self.extractBrokerContactName(
        //     lines: lines,
        //     emailLowercased: out.brokerEmail,
        //     phoneNormalized: out.brokerPhone
        // )
        // if out.brokerContactName != nil {
        //     out.confidence["brokerContactName"] = 0.75
        // }
        // if out.brokerContactName == nil, let email = out.brokerEmail,
        //    let inferred = Self.inferContactNameFromEmail(email) {
        //     out.brokerContactName = inferred
        //     out.confidence["brokerContactName"] = 0.4
        // }

        // ---- Pickup / Delivery blocks ----
        //
        // Strategy:
        //   1. Anchors are matched as whole *words* at the start of a line
        //      (after optional bullet/number) — NOT loose substring. That
        //      stops "to:" inside "send to: dispatch@x.com" from being
        //      mis-tagged as a delivery anchor.
        //   2. We collect ALL anchor hits for both ends, score each by how
        //      rich the surrounding 6-line block is (city/state present, has
        //      address, has date, etc.) and pick the highest-scoring block.
        //   3. We avoid grabbing the SAME block for both ends — if pickup
        //      wins block at line 12, delivery is forbidden from that block.
        //
        // Anchors expanded per spec to cover real rate-con / BOL phrasing:
        //   Pickup:   pickup, pick up, pick-up, shipper, ship from, origin, from
        //   Delivery: delivery, deliver, deliver to, consignee, receiver,
        //             destination, drop, to, dropoff, drop off, drop-off
        //
        // Bare "from"/"to" only count when they're the ENTIRE label on a
        // line (e.g. "From: ..." / "To: ...") — never mid-sentence.
        let pickupAnchorRegexes = [
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(pickup|pick[\-\s]?up|pu)\s*[:#\-]?"#,
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(shipper)\s*[:#\-]?"#,
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(ship\s*from)\s*[:#\-]?"#,
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(origin)\s*[:#\-]?"#,
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(from)\s*[:]"#
        ]
        let deliveryAnchorRegexes = [
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(delivery)\s*[:#\-]?"#,
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(deliver\s*to)\s*[:#\-]?"#,
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(deliver)\s*[:#\-]?"#,
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(consignee)\s*[:#\-]?"#,
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(receiver)\s*[:#\-]?"#,
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(destination)\s*[:#\-]?"#,
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(so)\s*[:#\-]?"#,
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(drop[\-\s]?off|drop)\s*[:#\-]?"#,
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(to)\s*[:]"#
        ]

        let pickupHits = anchorHits(lines: loadLines, regexes: pickupAnchorRegexes)
        let deliveryHits = anchorHits(lines: loadLines, regexes: deliveryAnchorRegexes)

        let routeBlocks: (pickup: AddrBlock?, delivery: AddrBlock?)
        if let paired = pairedStopBlocks(lines: loadLines, pickupHits: pickupHits, deliveryHits: deliveryHits) {
            routeBlocks = (paired.pickup, paired.delivery)
        } else {
            // Best pickup block (highest score).
            let pickupBlock = pickupHits
                .map { ($0, blockAt(lines: loadLines, startIndex: $0)) }
                .max(by: { score($0.1) < score($1.1) })

            // Best delivery block, but EXCLUDE the line index pickup chose so
            // we never tag the same address twice.
            let deliveryBlock: (Int, AddrBlock)? = deliveryHits
                .filter { $0 != pickupBlock?.0 }
                .map { ($0, blockAt(lines: loadLines, startIndex: $0)) }
                .max(by: { score($0.1) < score($1.1) })

            routeBlocks = (pickupBlock?.1, deliveryBlock?.1)
        }

        if let block = routeBlocks.pickup {
            if let address = block.address {
                out.pickupAddress = address
                out.confidence["pickupAddress"] = max(out.confidence["pickupAddress"] ?? 0, 0.65)
            }
            if let cityState = block.cityState {
                out.pickupCityState = cityState
                out.confidence["pickupCityState"] = max(out.confidence["pickupCityState"] ?? 0, 0.8)
            }
            if let companyName = block.companyName {
                out.shipperName = companyName
                out.confidence["shipperName"] = max(out.confidence["shipperName"] ?? 0, 0.6)
            }

            if let date = firstDate(in: block.allText) {
                out.pickupDate = date
                out.confidence["pickupDate"] = 0.8
            }
            if let t = firstRegex(block.allText, pattern: #"\b\d{1,2}:\d{2}\s*(?:AM|PM|am|pm)?\b"#) {
                out.pickupTime = t.uppercased()
                out.confidence["pickupTime"] = 0.75
            }
        }

        if let block = routeBlocks.delivery {
            if let address = block.address {
                out.deliveryAddress = address
                out.confidence["deliveryAddress"] = max(out.confidence["deliveryAddress"] ?? 0, 0.65)
            }
            if let cityState = block.cityState {
                out.deliveryCityState = cityState
                out.confidence["deliveryCityState"] = max(out.confidence["deliveryCityState"] ?? 0, 0.8)
            }
            if let companyName = block.companyName {
                out.receiverName = companyName
                out.confidence["receiverName"] = max(out.confidence["receiverName"] ?? 0, 0.6)
            }

            if let date = firstDate(in: block.allText) {
                out.deliveryDate = date
                out.confidence["deliveryDate"] = 0.8
            }
            if let t = firstRegex(block.allText, pattern: #"\b\d{1,2}:\d{2}\s*(?:AM|PM|am|pm)?\b"#) {
                out.deliveryTime = t.uppercased()
                out.confidence["deliveryTime"] = 0.75
            }
        }

        // ---- Fallback: if delivery still missing, find the SECOND
        // city-state anywhere in the doc — pickup is almost always the
        // first city-state, delivery the second.
        if out.deliveryCityState == nil {
            let cityStates = allMatches(
                loadJoined,
                pattern: #"\b([A-Z][A-Za-z\.\s\-']{1,40}?,\s*[A-Z]{2})(?:\s+\d{5})?\b"#
            )
            if cityStates.count >= 2 {
                let candidate = cityStates[1].trimmingCharacters(in: .whitespaces)
                if candidate != out.pickupCityState {
                    out.deliveryCityState = candidate
                    out.confidence["deliveryCityState"] = 0.45  // low-confidence
                }
            }
        }

        // ---- Rate (scored multi-candidate, 2026-05-18 rewrite) ----
        //
        // Strategy: collect EVERY $X,XXX(.XX)? amount in the document with
        // its surrounding label context, score each by a priority table
        // (carrier pay > carrier rate > line haul > agreed/total > load
        // pay > bare "rate" > unlabeled), REJECT candidates whose context
        // contains accessorial/fuel/advance/lumper/insurance/detention/
        // escrow/fee/tax/factoring/chargeback keywords, then pick the
        // highest-scoring survivor. DEBUG builds emit `SP_DEBUG_RATECON`
        // lines for every candidate so we can see why one won.
        let picked = pickRate(joined: loadJoined, lines: loadLines, docType: out.documentType)
        if let p = picked {
            if (out.confidence["rate"] ?? 0) < 0.94 {
                out.rate = p.value
                out.confidence["rate"] = p.confidence
            }
        }

        // ---- Weight (scored multi-candidate, 2026-05-28 rewrite) ----
        //
        // Strategy: collect explicit weight-label hits ("Gross Weight: 45,000"),
        // table-style hits where "Weight:" is printed above the value, and
        // unit-bearing hits ("45,000 lbs"). Reject candidates whose source
        // context looks like mileage, money, load IDs, MC numbers, phone
        // numbers, PO/reference IDs, dates, or equipment IDs. If nothing clears
        // the confidence bar, leave the editable field blank.
        if let pickedWeight = pickWeight(lines: loadLines) {
            if (out.confidence["weight"] ?? 0) < 0.94 {
                out.weight = pickedWeight.displayValue
                out.confidence["weight"] = pickedWeight.confidence
            }
        }
        applyExplicitStopAddressFallbacks(&out, lines: loadLines)

        // ---- Commodity ----
        if out.commodity == nil,
           let m = firstRegex(loadJoined, pattern: #"(?im)^\s*commodity\s*[:\-]\s*(.+?)\s*$"#) {
            out.commodity = m
            out.confidence["commodity"] = 0.85
        }

        // ---- PO / Pickup number ----
        if let m = firstRegex(loadJoined, pattern: #"(?i)\bP\.?O\.?\s*(?:number|num|no\.?|#)?\s*[:#]?\s*([A-Z0-9][A-Z0-9-]{2,15})"#) {
            if let value = cleanFreightIdentifier(m) {
                out.poNumber = value
                out.confidence["poNumber"] = 0.8
            }
        }
        if let m = firstRegex(loadJoined, pattern: #"(?i)\b(?:pickup|pick[\-\s]?up|pu)\s*(?:number|num|no\.?|#)\s*[:#]?\s*([A-Z0-9][A-Z0-9-]{2,15})"#) {
            if let value = cleanFreightIdentifier(m) {
                out.pickupNumber = value
                out.confidence["pickupNumber"] = 0.8
            }
        }

        // ---- Reference number (separate from load # / PO #) ----
        // Same-line + digit-required for the same reasons as loadNumber.
        if let m = firstRegex(loadJoined, pattern: #"(?i)\b(?:reference|ref)[ \t]*(?:number|num|no\.?|#)?[ \t]*[:#\-]?[ \t]*([A-Z0-9][A-Z0-9\-]{2,20})"#) {
            if let v = cleanFreightIdentifier(m),
               v.count >= 5 || v.contains(where: \.isLetter) {
                out.referenceNumber = v
                out.confidence["referenceNumber"] = 0.8
            }
        }

        // ---- Loaded / Deadhead miles printed on the document ----
        // Examples that hit:
        //   "Loaded Miles: 1,234"   "Loaded: 1234 mi"   "Total Loaded Miles 1234"
        //   "Deadhead: 50"          "DH miles: 50"      "Empty Miles 50"
        if out.loadedMiles == nil,
           let m = firstRegex(loadJoined, pattern: #"(?i)\b(?:loaded\s*miles?|total\s*loaded\s*miles?|loaded)\s*[:#\-]?\s*([0-9]{1,4}(?:,[0-9]{3})?)"#) {
            if let v = Double(m.replacingOccurrences(of: ",", with: "")) {
                out.loadedMiles = v
                out.confidence["loadedMiles"] = 0.85
            }
        }
        if let m = firstRegex(loadJoined, pattern: #"(?i)\b(?:deadhead\s*miles?|dh\s*miles?|empty\s*miles?|deadhead)\s*[:#\-]?\s*([0-9]{1,4})"#) {
            if let v = Double(m) {
                out.deadheadMiles = v
                out.confidence["deadheadMiles"] = 0.85
            }
        }

        // ---- Special notes ----
        if let m = firstRegex(loadJoined, pattern: #"(?is)(?:special\s*instructions|notes|comments)\s*[:\-]\s*(.{5,300}?)(?:\n\s*\n|$)"#) {
            out.notes = m.trimmingCharacters(in: .whitespacesAndNewlines)
            out.confidence["notes"] = 0.6
        }

        // ---- Driver notes / driver-facing instructions ----
        if out.driverNotes == nil,
           let m = firstRegex(loadJoined, pattern: #"(?is)(?:driver\s*(?:notes|instructions)|instructions\s*to\s*driver)\s*[:\-]\s*(.{5,300}?)(?:\n\s*\n|$)"#) {
            out.driverNotes = m.trimmingCharacters(in: .whitespacesAndNewlines)
            out.confidence["driverNotes"] = 0.7
        }

        // ---- Accessorial pay lines: FSC, lumper, detention, stop-off ----
        // Each scans the document for a labeled dollar amount near common
        // accessorial keywords. Conservative regex — only matches an
        // amount that follows the label within ~40 chars.
        if let v = extractMoney(loadJoined, keywords: ["fsc", "fuel\\s*surcharge", "fuel\\s*sur"]) {
            out.fuelSurcharge = v
            out.confidence["fuelSurcharge"] = 0.85
        }
        if let v = extractMoney(loadJoined, keywords: ["lumper(?:\\s*fee)?"]) {
            out.lumperFee = v
            out.confidence["lumperFee"] = 0.85
        }
        if let v = extractMoney(loadJoined, keywords: ["detention(?:\\s*(?:pay|fee|rate))?"]) {
            out.detentionRate = v
            out.confidence["detentionRate"] = 0.8
        }
        if let v = extractMoney(loadJoined, keywords: ["stop[\\-\\s]?off(?:\\s*pay)?", "extra\\s*(?:stop|pickup)"]) {
            out.stopOffPay = v
            out.confidence["stopOffPay"] = 0.8
        }

        // ---- Trailer number ----
        if let m = firstRegex(loadJoined, pattern: #"(?i)\b(?:trailer\s*(?:number|num|no\.?|#)|tlr\s*#?|tr\s*#)\s*[:#]?\s*([A-Z0-9][A-Z0-9\-]{1,15})"#) {
            out.trailerNumber = m.cleanID
            out.confidence["trailerNumber"] = 0.85
        }

        // ---- BOL number ----
        if let m = firstRegex(loadJoined, pattern: #"(?i)\b(?:bill\s*of\s*lading|b\.?o\.?l\.?)\s*(?:number|num|no\.?|#)?\s*[:#\-]?\s*([A-Z0-9][A-Z0-9\-]{3,20})"#) {
            if let value = cleanFreightIdentifier(m) {
                out.bolNumber = value
                out.confidence["bolNumber"] = 0.85
            }
        }

        // ---- Pass N-1: recon / reconciliation-specific override ----
        // Recon docs have their own load# / amount / reference rules that
        // OVERRIDE the generic regex sweep. This runs before vendor-specific
        // post-pass so vendor patterns can still refine recon output.
        if out.documentType == .recon {
            Recon.fill(&out, joined: joined, lines: lines)
        }

        // ---- Pass N: vendor-specific override pre-pass ----
        // Vendor-specific extractors have higher fidelity than the generic
        // regex sweep — they know each broker's exact label phrasing. They
        // run LAST so they can override anything the generic sweep guessed.
        switch out.sourceVendor {
        case "Lowes":
            Lowes.fill(&out, joined: joined, lines: lines)
        default:
            break
        }

        // ---- Pass N+1: rate-con-only broadening (2026-05-18) ----
        // Real-world rate cons sometimes use labels the generic sweep doesn't
        // know about: "Confirmation #", "Tender #", "Booking #", "Tracking #",
        // "RC #", or even bare "Reference #" as the load identifier. They
        // also sometimes print the rate as "Carrier Rate", "Tender Amount",
        // "Load Pay", "Total Pay" — labels the generic strong-token list
        // doesn't cover. This extractor runs ONLY on non-recon docs so the
        // Ref# protection on settlement statements stays intact.
        if out.documentType != .recon {
            RateCon.fill(&out, joined: loadJoined, lines: loadLines)
        }

        // ---- Final validation: load# vs reference# swap ----
        // If loadNumber is suspiciously short (<= 5 digits, pure numeric)
        // AND a longer freight-style identifier exists in the doc, the short
        // value is almost certainly a sequence/reference number and the
        // longer one is the true load. Promote the longer ID to loadNumber
        // and demote the short one into referenceNumber (Info field).
        validateLoadNumberAgainstAlternates(&out, joined: loadJoined)

        // Fail-safe hardening: do not infer one identifier field from another.
        // Low-confidence IDs stay blank instead of carrying bad OCR words into
        // Load #, PO #, BOL #, or Reference #.
        sanitizeIdentifierFields(&out)
        normalizeLoadAndPONumbers(&out)

        // ---- Debug logging (DEBUG builds only) ----
        // Emits the OCR context around the detected loadNumber + rate and
        // the final parsed values so the on-device console shows exactly
        // what the parser saw. Tag: `SP_DEBUG_RATECON`.
        #if DEBUG
        logRateConExtraction(out: out, lines: lines)
        #endif

        return out
    }

    private static func normalizeLoadAndPONumbers(_ out: inout ParsedLoadFields) {
        guard out.documentType == .rateCon else { return }

        let load = out.loadNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let po = out.poNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !load.isEmpty, po.isEmpty {
            out.poNumber = load
            out.confidence["poNumber"] = max(out.confidence["poNumber"] ?? 0, out.confidence["loadNumber"] ?? 0)
        } else if !po.isEmpty, load.isEmpty {
            out.loadNumber = po
            out.confidence["loadNumber"] = max(out.confidence["loadNumber"] ?? 0, out.confidence["poNumber"] ?? 0)
        }

        #if DEBUG
        print("[DriverHub Parser] Load/PO normalization applied loadNumber=\(out.loadNumber ?? "<nil>") poNumber=\(out.poNumber ?? "<nil>")")
        #endif
    }

    #if DEBUG
    /// Emit `SP_DEBUG_RATECON` lines to the device console showing what the
    /// parser pulled off the page. Used to triage rate-con parser misses on
    /// real broker docs — find the lines, paste them into a test fixture,
    /// regression-test against them.
    static func logRateConExtraction(out: ParsedLoadFields, lines: [String]) {
        let tag = "SP_DEBUG_RATECON"
        print("[\(tag)] documentType=\(out.documentType.rawValue) vendor=\(out.sourceVendor ?? "-")")
        print("[\(tag)] FINAL loadNumber=\(out.loadNumber ?? "<nil>") rate=\(out.rate.map { String($0) } ?? "<nil>")")
        print("[\(tag)] FINAL weight=\(out.weight ?? "<nil>") confidence=\(out.confidence["weight"].map { String(format: "%.2f", $0) } ?? "<nil>")")
        print("[\(tag)] FINAL referenceNumber=\(out.referenceNumber ?? "<nil>") poNumber=\(out.poNumber ?? "<nil>")")

        // Show OCR context around the detected load number (±2 lines).
        if let ln = out.loadNumber, !lines.isEmpty {
            if let idx = lines.firstIndex(where: { $0.contains(ln) }) {
                let lo = max(0, idx - 2)
                let hi = min(lines.count - 1, idx + 2)
                print("[\(tag)] loadNumber OCR context [\(lo)…\(hi)]:")
                for i in lo...hi {
                    let marker = (i == idx) ? "  > " : "    "
                    print("[\(tag)]\(marker)\(i): \(lines[i])")
                }
            } else {
                print("[\(tag)] loadNumber=\(ln) but NOT found verbatim in any OCR line — picked up by post-pass.")
            }
        } else {
            print("[\(tag)] loadNumber=<nil> — no label matched. Top 12 OCR lines:")
            for (i, line) in lines.prefix(12).enumerated() {
                print("[\(tag)]    \(i): \(line)")
            }
        }

        // Show OCR context around the detected rate amount.
        if let r = out.rate {
            // Pretty-print the value with both a `$` form and a comma-grouped
            // form so we can locate it whether OCR kept formatting or not.
            let plain = String(format: "%.2f", r)
            let dollarPlain = "$" + plain
            let withCommas: String = {
                let fmt = NumberFormatter()
                fmt.numberStyle = .currency
                fmt.locale = Locale(identifier: "en_US")
                return fmt.string(from: NSNumber(value: r)) ?? plain
            }()
            let dropCents = String(Int(r))
            if let idx = lines.firstIndex(where: {
                $0.contains(plain) || $0.contains(dollarPlain) ||
                $0.contains(withCommas) || $0.contains(dropCents)
            }) {
                let lo = max(0, idx - 2)
                let hi = min(lines.count - 1, idx + 2)
                print("[\(tag)] rate OCR context [\(lo)…\(hi)]:")
                for i in lo...hi {
                    let marker = (i == idx) ? "  > " : "    "
                    print("[\(tag)]\(marker)\(i): \(lines[i])")
                }
            } else {
                print("[\(tag)] rate=\(plain) but NOT found verbatim in any OCR line.")
            }
        } else {
            print("[\(tag)] rate=<nil> — no rate label matched. Dumping any $ lines:")
            for (i, line) in lines.enumerated() where line.contains("$") {
                print("[\(tag)]    \(i): \(line)")
            }
        }

        if let weight = out.weight {
            let digits = weight.filter(\.isNumber)
            if let idx = lines.firstIndex(where: {
                let compact = $0.filter { $0.isNumber || $0.isLetter }
                return $0.contains(weight) || (!digits.isEmpty && compact.contains(digits))
            }) {
                let lo = max(0, idx - 3)
                let hi = min(lines.count - 1, idx + 3)
                print("[\(tag)] weight OCR context [\(lo)…\(hi)]:")
                for i in lo...hi {
                    let marker = (i == idx) ? "  > " : "    "
                    print("[\(tag)]\(marker)\(i): \(lines[i])")
                }
            } else {
                print("[\(tag)] weight=\(weight) but NOT found verbatim in any OCR line.")
            }
        } else {
            print("[\(tag)] weight=<nil> — no confident weight candidate. Weight-like OCR lines:")
            for (i, line) in lines.enumerated() {
                let lower = line.lowercased()
                if lower.contains("weight") || lower.contains("wt") ||
                    lower.contains("lb") || lower.contains("pound") ||
                    lower.contains("kg") || lower.contains("kilo") {
                    print("[\(tag)]    \(i): \(line)")
                }
            }
        }
    }
    #endif

    // MARK: - Vendor detection

    /// Returns a canonical vendor key when document text matches a known
    /// broker's letterhead / fingerprint. Used to pick a specialized
    /// extractor in the post-pass.
    static func detectVendor(in text: String) -> String? {
        let t = text.lowercased()
        // Lowe's: rate cons + BOLs + delivery manifests. Catch all common
        // store/RDC phrasings; avoid generic "low" substring false positives.
        let lowesSignals = [
            "lowe's home center", "lowes home center",
            "lowe's home improvement", "lowes home improvement",
            "lowe's companies", "lowes companies",
            "lowe's transportation", "lowes transportation",
            "lowe's rdc", "lowes rdc",
            "delivery rdc", "loweslink", "lowes link"
        ]
        if lowesSignals.contains(where: { t.contains($0) }) {
            return "Lowes"
        }
        // Strict Lowe's logo line alone — uppercase "LOWE'S" or "LOWES"
        // on a line by itself near the top.
        if firstRegex(text, pattern: #"(?m)^[\s\W]*LOWE['']?S\b"#) != nil {
            return "Lowes"
        }
        return nil
    }

    // MARK: - Document-type detection

    /// Classify the document as a rate confirmation, recon/settlement, BOL,
    /// or unknown. Signal-driven: a handful of strong tokens push recon over
    /// rateCon; the absence of any rateCon-only language plus presence of
    /// payment-detail tokens locks it in.
    static func detectDocumentType(in text: String) -> DocumentType {
        let t = text.lowercased()

        // Strong recon / settlement / remittance signals.
        let reconSignals = [
            "reconciliation", "recon statement", "carrier reconciliation",
            "settlement statement", "settlement detail", "settlement summary",
            "remittance", "remittance advice", "payment detail",
            "carrier payment", "carrier statement", "paid loads",
            "load payment", "net pay", "net amount", "amount paid",
            "paid amount", "check detail", "ach detail", "factoring statement",
            "deductions", "advances", "chargebacks"
        ]
        let reconScore = reconSignals.reduce(0) { $0 + (t.contains($1) ? 1 : 0) }

        // Strong rateCon signals (so we don't false-positive on a rate con
        // that happens to mention "amount" once).
        let rateConSignals = [
            "rate confirmation", "rate con", "load confirmation",
            "carrier rate confirmation", "agreed rate", "rate agreement",
            "load tender", "carrier dispatch", "load offer"
        ]
        let rateConScore = rateConSignals.reduce(0) { $0 + (t.contains($1) ? 1 : 0) }

        // BOL signals.
        if t.contains("bill of lading") && !t.contains("bol number") {
            // pure BOL doc (not just a rate con that prints the BOL #)
            if reconScore == 0 && rateConScore == 0 {
                return .bol
            }
        }

        if reconScore >= 2 || (reconScore >= 1 && rateConScore == 0) {
            return .recon
        }
        if rateConScore >= 1 {
            return .rateCon
        }
        return .unknown
    }

    // MARK: - Scored rate-amount picker

    /// One candidate for the rate field — an amount, where in the document
    /// it appeared, and its label context.
    struct RateCandidate {
        let value: Double          // dollar amount
        let labelContext: String   // ~80 chars of surrounding text (lowercased)
        let lineIndex: Int         // OCR line index the amount appeared on
        let hadDollarPrefix: Bool  // true if the raw match started with $
        var priority: Int          // assigned by scoring
        var rejectionReason: String?
        var confidence: Double { Double(priority) / 100.0 }
    }

    /// One candidate for the shipment weight field, including the exact OCR
    /// source text used to select or reject it.
    struct WeightCandidate {
        let value: Int
        let unit: String
        let lineIndex: Int
        let sourceText: String
        let confidence: Double
        let reason: String
        var rejectionReason: String?

        var displayValue: String {
            let fmt = NumberFormatter()
            fmt.numberStyle = .decimal
            fmt.locale = Locale(identifier: "en_US")
            let formatted = fmt.string(from: NSNumber(value: value)) ?? String(value)
            return "\(formatted) \(unit)"
        }
    }

    /// Pick the most likely freight weight from OCR text without confusing it
    /// with rate, mileage, load-number, MC-number, or PO/reference values.
    static func pickWeight(lines: [String]) -> WeightCandidate? {
        var candidates: [WeightCandidate] = []

        let sameLinePattern = #"(?i)\b(?:(gross|shipment|cargo|total|actual|net)\s+)?(?:weight|wt\.?)\b(?:\s*\((lbs?|lb|pounds?|kg|kgs|kilograms?|kilos?)\))?\s*[:#\-]?\s*([0-9]{1,3}(?:[,\s][0-9]{3})+|[0-9]{4,6})(?:\.[0-9]+)?(?:\s*(lbs?|lb|pounds?|kg|kgs|kilograms?|kilos?))?\b"#
        let valueWithOptionalUnitPattern = #"(?i)\b([0-9]{1,3}(?:[,\s][0-9]{3})+|[0-9]{4,6})(?:\.[0-9]+)?(?:\s*(lbs?|lb|pounds?|kg|kgs|kilograms?|kilos?))?\b"#
        let valueWithUnitPattern = #"(?i)\b([0-9]{1,3}(?:[,\s][0-9]{3})+|[0-9]{4,6})(?:\.[0-9]+)?\s*(lbs?|lb|pounds?|kg|kgs|kilograms?|kilos?)\b"#

        func addCandidate(numberRaw: String,
                          unitRaw: String?,
                          lineIndex: Int,
                          sourceText: String,
                          context: String,
                          baseConfidence: Double,
                          reason: String,
                          hasWeightLabel: Bool,
                          hasExplicitUnit: Bool) {
            guard let value = parseWeightNumber(numberRaw) else { return }
            let unit = normalizeWeightUnit(unitRaw) ?? inferWeightUnit(from: sourceText) ?? "lbs"
            let boundedConfidence = min(0.98, max(0.0, baseConfidence))
            var candidate = WeightCandidate(
                value: value,
                unit: unit,
                lineIndex: lineIndex,
                sourceText: sourceText,
                confidence: boundedConfidence,
                reason: reason,
                rejectionReason: nil
            )
            candidate.rejectionReason = weightRejectionReason(
                value: value,
                unit: unit,
                context: context,
                hasWeightLabel: hasWeightLabel,
                hasExplicitUnit: hasExplicitUnit
            )
            candidates.append(candidate)
        }

        for (idx, line) in lines.enumerated() {
            let broadContext = weightContext(lines: lines, around: idx, radius: 4)
            let lineHasLabel = containsWeightLabel(line)

            // 1) Explicit same-line labels:
            //    "Gross Weight: 45,000", "Weight (LBS): 45000".
            for groups in regexCaptureMatches(line, pattern: sameLinePattern) {
                guard let numberRaw = capture(groups, 3) else { continue }
                let labelPrefix = capture(groups, 1)?.lowercased()
                let unitRaw = capture(groups, 4) ?? capture(groups, 2)
                let isSpecificLabel = labelPrefix != nil
                let hasUnit = unitRaw != nil
                addCandidate(
                    numberRaw: numberRaw,
                    unitRaw: unitRaw,
                    lineIndex: idx,
                    sourceText: line,
                    context: line,
                    baseConfidence: (isSpecificLabel ? 0.93 : 0.88) + (hasUnit ? 0.03 : 0.0),
                    reason: "same-line weight label",
                    hasWeightLabel: true,
                    hasExplicitUnit: hasUnit || capture(groups, 2) != nil
                )
            }

            // 2) Table-style rate cons often OCR a label column first and
            //    values several lines later:
            //
            //      Weight:
            //      Equipment:
            //      Pieces:
            //      42,000 lbs
            if lineHasLabel {
                for offset in 1...8 {
                    let valueIndex = idx + offset
                    guard valueIndex < lines.count else { break }
                    let valueLine = lines[valueIndex]
                    let context = "\(line) \(valueLine)"
                    for groups in regexCaptureMatches(valueLine, pattern: valueWithOptionalUnitPattern) {
                        guard let numberRaw = capture(groups, 1) else { continue }
                        let unitRaw = capture(groups, 2) ?? inferWeightUnit(from: line)
                        let hasUnit = unitRaw != nil
                        addCandidate(
                            numberRaw: numberRaw,
                            unitRaw: unitRaw,
                            lineIndex: valueIndex,
                            sourceText: "\(line) -> \(valueLine)",
                            context: context,
                            baseConfidence: hasUnit ? 0.88 : 0.76,
                            reason: "near preceding weight label",
                            hasWeightLabel: true,
                            hasExplicitUnit: hasUnit
                        )
                    }
                }
            }

            // 3) Unit-bearing lines inside shipment/cargo context are valid even
            //    when the table label is not nearby.
            for groups in regexCaptureMatches(line, pattern: valueWithUnitPattern) {
                guard let numberRaw = capture(groups, 1),
                      let unitRaw = capture(groups, 2)
                else { continue }

                let supported = containsWeightLabel(broadContext) || hasShipmentWeightContext(broadContext)
                addCandidate(
                    numberRaw: numberRaw,
                    unitRaw: unitRaw,
                    lineIndex: idx,
                    sourceText: line,
                    context: line,
                    baseConfidence: supported ? 0.74 : 0.66,
                    reason: supported ? "unit-bearing shipment context" : "unit-bearing fallback",
                    hasWeightLabel: containsWeightLabel(broadContext),
                    hasExplicitUnit: true
                )
            }
        }

        let winner = candidates
            .filter { $0.rejectionReason == nil && $0.confidence >= 0.72 }
            .sorted {
                if abs($0.confidence - $1.confidence) > 0.001 {
                    return $0.confidence > $1.confidence
                }
                return $0.lineIndex < $1.lineIndex
            }
            .first

        #if DEBUG
        logWeightCandidates(candidates, winner: winner)
        #endif

        return winner
    }

    private static func parseWeightNumber(_ raw: String) -> Int? {
        var cleaned = raw
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: #"(?i)(lbs?|pounds?|kg|kgs|kilograms?|kilos?)"#, with: "", options: .regularExpression)
        if let dot = cleaned.firstIndex(of: ".") {
            cleaned = String(cleaned[..<dot])
        }
        guard !cleaned.isEmpty else { return nil }
        return Int(cleaned)
    }

    private static func normalizeWeightUnit(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lower = raw.lowercased()
        if lower.contains("kg") || lower.contains("kilo") { return "kg" }
        if lower.contains("lb") || lower.contains("pound") { return "lbs" }
        return nil
    }

    private static func inferWeightUnit(from text: String) -> String? {
        normalizeWeightUnit(text)
    }

    private static func containsWeightLabel(_ text: String) -> Bool {
        matchesRegex(text, pattern: #"(?i)\b(?:(?:gross|shipment|cargo|total|actual|net)\s+)?(?:weight|wt\.?)\b"#)
    }

    private static func ntLogisticsBrokerName(lines: [String], documentText: String) -> String? {
        let joined = documentText.lowercased()
        guard joined.contains("nt logistics") ||
              joined.contains("ntlogistics.com") ||
              joined.contains("469-362-5040")
        else { return nil }

        for line in lines.prefix(40) {
            if line.range(of: #"(?i)\bNT\s+Logistics(?:,\s*Inc\.?)?\b"#, options: .regularExpression) != nil,
               let broker = cleanBrokerName(line, documentText: documentText),
               !isGenericConfirmationTitle(broker) {
                return broker
            }
        }
        return "NT Logistics, Inc."
    }

    private static func hasShipmentWeightContext(_ text: String) -> Bool {
        let lower = text.lowercased()
        let signals = [
            "shipment", "commodity", "cargo", "freight", "equipment",
            "truckload", "palletized", "hazmat", "dry van", "reefer", "flatbed"
        ]
        return signals.contains { lower.contains($0) }
    }

    private static func weightContext(lines: [String], around index: Int, radius: Int) -> String {
        guard !lines.isEmpty else { return "" }
        let lo = max(0, index - radius)
        let hi = min(lines.count - 1, index + radius)
        return lines[lo...hi].joined(separator: " ")
    }

    private static func weightRejectionReason(value: Int,
                                              unit: String,
                                              context: String,
                                              hasWeightLabel: Bool,
                                              hasExplicitUnit: Bool) -> String? {
        if unit == "kg" {
            guard (250...60_000).contains(value) else {
                return "outside plausible kg range"
            }
        } else {
            guard (500...120_000).contains(value) else {
                return "outside plausible lbs range"
            }
        }

        let lower = context.lowercased()
        if lower.contains("$") || lower.contains(" usd") || lower.contains("dollars") {
            return "money/rate context"
        }
        if matchesRegex(lower, pattern: #"\b(?:miles?|mi)\b"#) {
            return "mileage context"
        }

        let identifierSignals = [
            "load #", "load no", "load number", "load id", "order #",
            "mc#", "mc #", "motor carrier", "dot#", "dot #", "usdot",
            "phone", "tel", "fax", "email",
            "po #", "po#", "p.o.", "purchase order",
            "reference", "ref #", "ref#", "pickup number", "delivery number",
            "bol #", "bol#", "trailer", "tractor", "date", "time"
        ]
        if identifierSignals.contains(where: { lower.contains($0) }) {
            return "identifier/date/equipment context"
        }

        if !hasWeightLabel {
            let nonWeightSignals = [
                "rate", "pay", "charge", "amount", "revenue", "line haul",
                "fuel", "surcharge", "detention", "lumper", "deadhead",
                "loaded miles", "empty miles"
            ]
            if nonWeightSignals.contains(where: { lower.contains($0) }) {
                return "non-weight amount context"
            }
        }

        if !hasWeightLabel && !hasExplicitUnit {
            return "no weight label or unit"
        }

        return nil
    }

    #if DEBUG
    private static func logLoadIDCandidates(_ candidates: [LoadIDCandidate], winner: String?) {
        let tag = "SP_DEBUG_RATECON"
        if candidates.isEmpty {
            print("[\(tag)] LOAD# no candidates")
            return
        }

        print("[\(tag)] LOAD# candidates=\(candidates.count)")
        for c in candidates.sorted(by: { $0.score > $1.score }).prefix(32) {
            let status = c.accepted ? "ACCEPT" : "REJECT"
            print("[\(tag)] LOAD# \(status) score=\(c.score) value=\(c.value) reason=\(c.reason) source=\"\(c.source)\"")
        }
        if let winner {
            print("[\(tag)] LOAD# PICKED value=\(winner)")
        } else {
            print("[\(tag)] LOAD# no candidate picked; editable field left blank")
        }
    }

    private static func logWeightCandidates(_ candidates: [WeightCandidate], winner: WeightCandidate?) {
        let tag = "SP_DEBUG_RATECON"
        if candidates.isEmpty {
            print("[\(tag)] WEIGHT no candidates")
            return
        }

        print("[\(tag)] WEIGHT candidates=\(candidates.count)")
        for c in candidates.sorted(by: { $0.confidence > $1.confidence }).prefix(12) {
            let status = c.rejectionReason.map { "REJECT \($0)" } ?? "KEEP"
            print("[\(tag)] WEIGHT \(status) conf=\(String(format: "%.2f", c.confidence)) value=\(c.displayValue) line=\(c.lineIndex) reason=\(c.reason) source=\"\(c.sourceText)\"")
        }

        if let winner {
            print("[\(tag)] WEIGHT PICKED value=\(winner.displayValue) conf=\(String(format: "%.2f", winner.confidence)) source=\"\(winner.sourceText)\"")
        } else {
            print("[\(tag)] WEIGHT no confident candidate picked; editable field left blank")
        }
    }
    #endif

    /// Pick the most-likely "true carrier pay" amount from the OCR text.
    ///
    /// Scoring priority (lower = better; higher score wins):
    ///   100  carrier pay, carrier rate, all-in rate, all-in
    ///    95  agreed rate, agreed amount
    ///    90  total rate, total amount, total pay, gross pay, driver pay,
    ///        truck pay, flat rate
    ///    85  line haul, linehaul, freight charge
    ///    80  load pay, load rate, load amount
    ///    70  tender amount, booked rate, trip pay
    ///    50  bare "rate:" / "rate =" / "amount:" / "pay:"
    ///    30  unlabeled $X,XXX in top half of doc
    ///
    /// Rejected outright (context within ~40 chars contains any of):
    ///   fuel surcharge, fsc, fuel, surcharge, accessorial, advance,
    ///   detention, lumper, lumper fee, insurance, escrow, deduction,
    ///   factor, factoring, chargeback, tax, service fee, fee, tolls,
    ///   permit, scale, layover, parking, citation, wash, repair.
    ///
    /// Range guardrails: 200 ≤ value ≤ 50,000 USD.
    static func pickRate(joined: String,
                         lines: [String],
                         docType: DocumentType) -> RateCandidate? {

        // Recon docs already use their own Net Pay / Amount Paid logic in
        // Recon.fill, so the rate picker stays out of their way.
        if docType == .recon { return nil }

        // --- 1) Collect every dollar / bare amount in the document. ---
        // We scan line-by-line so we can record the line index for logging.
        var candidates: [RateCandidate] = []

        // Pattern for $-prefixed amounts: $1,250 / $1,250.00 / $1250.
        let dollarPat = #"\$\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]{3,6}(?:\.[0-9]{1,2})?)"#
        // Pattern for bare amounts (no $) — only used on rateCon docs.
        let barePat = #"\b([0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]{1,2})?|[1-9][0-9]{2,4}(?:\.[0-9]{1,2})?)\b"#

        for (idx, rawLine) in lines.enumerated() {
            // Nearby context: this line plus the closest preceding OCR labels.
            // Rate cons often OCR table labels ("TOTAL RATE") one or two cells
            // before the dollar value. Keep the window tight so unrelated line
            // items like fuel surcharge do not poison the true total.
            let lo = max(0, idx - 2)
            let ctx = (lines[lo...idx].joined(separator: " ")).lowercased()

            // $-prefixed amounts on this line.
            let dollarMatches = allMatches(rawLine, pattern: dollarPat)
            for raw in dollarMatches {
                if let v = parseMoney(raw), v >= 200, v <= 50_000 {
                    candidates.append(RateCandidate(
                        value: v,
                        labelContext: ctx,
                        lineIndex: idx,
                        hadDollarPrefix: true,
                        priority: 0
                    ))
                }
            }

            // Bare amounts — only on rateCon / unknown docs (BOLs print
            // weights & quantities that look like rates).
            if docType == .rateCon || docType == .unknown {
                let bareMatches = allMatches(rawLine, pattern: barePat)
                for raw in bareMatches {
                    if let v = parseMoney(raw),
                       v >= 300, v <= 40_000 {
                        // Skip duplicates with $-prefixed forms on the same line.
                        if candidates.contains(where: {
                            $0.lineIndex == idx && abs($0.value - v) < 0.01
                        }) { continue }
                        candidates.append(RateCandidate(
                            value: v,
                            labelContext: ctx,
                            lineIndex: idx,
                            hadDollarPrefix: false,
                            priority: 0
                        ))
                    }
                }
            }
        }

        if candidates.isEmpty { return nil }

        // --- 2) Score every candidate. ---
        let labelTiers: [(score: Int, regex: String)] = [
            (100, #"\bcarrier\s*pay\b|\bcarrier\s*rate\b|\ball[\s\-]?in(?:\s*rate)?\b"#),
            (95,  #"\bagreed\s*(?:rate|amount)\b"#),
            (90,  #"\btotal\s*(?:rate|amount|pay)\b|\bgross\s*pay\b|\bdriver\s*pay\b|\btruck\s*pay\b|\bflat\s*rate\b|\btotal\b"#),
            (85,  #"\bline\s*haul\b|\blinehaul\b|\bfreight\s*charge\b"#),
            (80,  #"\bload\s*(?:pay|rate|amount)\b"#),
            (70,  #"\btender\s*(?:amount|rate|pay)?\b|\bbooked\s*rate\b|\btrip\s*pay\b"#),
            (50,  #"\brate\s*[:=]|\bamount\s*[:=]|\bpay\s*[:=]"#),
        ]

        // Negative-context keywords. If any of these appear within ~40 chars
        // BEFORE the dollar amount or anywhere on the same line, the
        // candidate is REJECTED outright.
        let rejectKeywords = [
            "fuel surcharge", "fsc", "fuel sur", "fuel",
            "surcharge",
            "accessorial",
            "advance", "advanced",
            "detention",
            "lumper",
            "insurance",
            "escrow",
            "deduction",
            "factor", "factoring",
            "chargeback", "charge back",
            "service fee", "broker fee", "admin fee", "processing fee",
            "tax",
            "tolls", "toll",
            "permit",
            "scale",
            "layover",
            "parking",
            "citation",
            "wash",
            "repair",
            "reimburse",
        ]

        for i in candidates.indices {
            let ctx = candidates[i].labelContext

            // Positive scoring — pick the highest tier that matches.
            for (score, pat) in labelTiers {
                if firstRegex(ctx, pattern: pat) != nil {
                    candidates[i].priority = score
                    break
                }
            }

            // Unlabeled fallback: if no tier matched but the amount sits in
            // the top half of the document and has a $ prefix, give it a
            // very small score so it can still win if absolutely nothing
            // else exists.
            if candidates[i].priority == 0,
               candidates[i].hadDollarPrefix,
               candidates[i].lineIndex < max(1, lines.count / 2) {
                candidates[i].priority = 30
            }

            if candidates[i].priority == 0,
               isImplicitChargesTotal(
                candidate: candidates[i],
                candidates: candidates,
                lines: lines,
                docType: docType
               ) {
                candidates[i].priority = 88
            }

            // Negative context usually wins, but real rate cons often print
            // "Accessorial" or "Fuel surcharge" rows immediately before a
            // clearly labeled "TOTAL RATE" row. Preserve those strong total
            // labels while still rejecting the line-item amounts themselves.
            for bad in rejectKeywords where ctx.contains(bad) {
                if preservesStrongRateContext(ctx, priority: candidates[i].priority) ||
                    isImplicitChargesTotal(
                        candidate: candidates[i],
                        candidates: candidates,
                        lines: lines,
                        docType: docType
                    ) {
                    continue
                }
                candidates[i].rejectionReason = "context contains '\(bad)'"
                break
            }
        }

        // --- 3) Pick the winner. ---
        let valid = candidates.filter { $0.priority > 0 && $0.rejectionReason == nil }

        // Within the same priority tier, prefer the larger value — true
        // totals sit above the line-item breakdown on most rate cons.
        let winner = valid.max { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            return a.value < b.value
        }

        // --- 4) DEBUG: enumerate every candidate, mark winner. ---
        #if DEBUG
        let tag = "SP_DEBUG_RATECON"
        print("[\(tag)] pickRate — \(candidates.count) raw candidate(s):")
        // Sort for stable readable output.
        for c in candidates.sorted(by: { $0.lineIndex < $1.lineIndex }) {
            let isWinner = (winner.map { $0.lineIndex == c.lineIndex && $0.value == c.value } ?? false)
            let marker   = isWinner ? "  WIN " : "      "
            let dollar   = c.hadDollarPrefix ? "$" : " "
            let priStr   = c.priority > 0 ? "p\(c.priority)" : "p- "
            let reason   = c.rejectionReason ?? winReason(for: c)
            print("[\(tag)]\(marker)line[\(c.lineIndex)] \(dollar)\(c.value)  \(priStr)  reason=\(reason)")
            // Print the actual OCR line for context.
            if c.lineIndex < lines.count {
                print("[\(tag)]         OCR: \(lines[c.lineIndex])")
            }
        }
        if let w = winner {
            print("[\(tag)] pickRate WINNER → $\(w.value) (priority \(w.priority))")
        } else {
            print("[\(tag)] pickRate WINNER → <none — all candidates rejected or no matches>")
        }
        #endif

        return winner
    }

    private static func preservesStrongRateContext(_ ctx: String, priority: Int) -> Bool {
        guard priority >= 90 else { return false }
        return firstRegex(
            ctx,
            pattern: #"(?i)\btotal\s*rate\b|\bcarrier\s*(?:pay|rate)\b|\ball[\s\-]?in(?:\s*rate)?\b|\bagreed\s*(?:rate|amount)\b|\bgross\s*pay\b|\bdriver\s*pay\b|\btruck\s*pay\b|\bflat\s*rate\b"#
        ) != nil
    }

    private static func isImplicitChargesTotal(candidate: RateCandidate,
                                               candidates: [RateCandidate],
                                               lines: [String],
                                               docType: DocumentType) -> Bool {
        guard docType == .rateCon || docType == .unknown else { return false }
        guard candidate.hadDollarPrefix, candidate.value >= 500 else { return false }
        guard !lines.isEmpty, candidate.lineIndex < lines.count else { return false }

        let sectionStart = max(0, candidate.lineIndex - 16)
        let scanEnd = min(lines.count - 1, candidate.lineIndex + 8)
        var sectionEnd = scanEnd
        if candidate.lineIndex < lines.count {
            for i in candidate.lineIndex...scanEnd {
                let lower = lines[i].lowercased()
                if lower.contains("special instructions") ||
                    lower.contains("acceptance:") ||
                    lower.contains("terms") ||
                    lower.contains("detention:") ||
                    lower.contains("lumper") {
                    sectionEnd = max(candidate.lineIndex, i - 1)
                    break
                }
            }
        }

        let sectionText = lines[sectionStart...sectionEnd].joined(separator: " ").lowercased()
        let hasChargesTable = sectionText.contains("charges") ||
            sectionText.contains("linehaul") ||
            sectionText.contains("line haul") ||
            sectionText.contains("freight charge")
        let hasLineItems = sectionText.contains("fsc") ||
            sectionText.contains("fuel surcharge") ||
            sectionText.contains("accessorial") ||
            sectionText.contains("linehaul") ||
            sectionText.contains("line haul")
        guard hasChargesTable && hasLineItems else { return false }

        let sectionAmounts = candidates.filter {
            $0.hadDollarPrefix &&
            $0.lineIndex >= sectionStart &&
            $0.lineIndex <= sectionEnd &&
            $0.value >= 200
        }
        guard let maxValue = sectionAmounts.map(\.value).max(),
              abs(candidate.value - maxValue) < 0.01
        else { return false }

        return sectionAmounts.contains {
            $0.lineIndex < candidate.lineIndex &&
            $0.value < candidate.value
        }
    }

    /// Short, human-readable reason a candidate scored its tier (DEBUG only).
    private static func winReason(for c: RateCandidate) -> String {
        switch c.priority {
        case 100: return "carrier pay / carrier rate / all-in"
        case 95:  return "agreed rate / agreed amount"
        case 90:  return "total rate / total pay / flat rate"
        case 88:  return "implicit total from charges table"
        case 85:  return "line haul / linehaul / freight charge"
        case 80:  return "load pay / load rate / load amount"
        case 70:  return "tender / booked / trip pay"
        case 50:  return "bare 'rate:' / 'amount:'"
        case 30:  return "unlabeled $ in top half"
        case 0:   return "no label match"
        default:  return "p\(c.priority)"
        }
    }

    /// Parse a money-formatted string ("1,250", "1,250.00", "1250.50") into
    /// a Double. Strips commas; returns nil on malformed input.
    private static func parseMoney(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ""))
    }

    private static func cleanBrokerName(_ raw: String,
                                        documentText: String,
                                        explicitlyLabeled: Bool = false) -> String? {
        guard !isOCRDebugMarker(raw) else { return nil }
        var candidate = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isOCRDebugMarker(candidate) else { return nil }
        guard !candidate.lowercased().contains("ocr page") else { return nil }
        guard !isGenericConfirmationTitle(candidate) else { return nil }

        if let cutIndex = firstBrokerPromoPhraseIndex(in: candidate) {
            candidate = String(candidate[..<cutIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        candidate = candidate
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .trimmedCompanySuffix

        guard candidate.count >= 2, candidate.count <= 80 else { return nil }
        guard !containsBrokerPromoPhrase(candidate) else { return nil }
        guard !isGenericConfirmationTitle(candidate) else { return nil }
        let blockedNoise = explicitlyLabeled
            ? #"(?i)\b(?:page|signature|accepted|activity|history|driver|phone|email|tracking|instructions)\b"#
            : #"(?i)\b(?:page|signature|audit|accepted|activity|history|driver|phone|email|tracking|instructions)\b"#
        guard !matchesRegex(candidate, pattern: blockedNoise) else {
            return nil
        }

        if shouldNormalizeBrokerToTQL(candidate, documentText: documentText) {
            return "TQL"
        }

        return candidate
    }

    private static func hasExplicitBrokerLabel(_ brokerName: String, in documentText: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: brokerName)
        return matchesRegex(
            documentText,
            pattern: #"(?im)^\s*(?:broker|brokered\s*by|carrier\s*broker|booked\s*by)\s*[:\-]\s*\#(escaped)\s*$"#
        )
    }

    private static func isGenericConfirmationTitle(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z\s]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let blocked: Set<String> = [
            "rate confirmation",
            "rate confirmation agreement",
            "carrier confirmation",
            "load confirmation",
            "confirmation sheet",
            "carrier rate confirmation",
            "load tender",
            "rate agreement"
        ]
        if blocked.contains(normalized) { return true }
        let blockedPrefixes = [
            "rate confirmation agreement for ",
            "rate confirmation for ",
            "carrier confirmation for ",
            "load confirmation for ",
            "confirmation sheet for "
        ]
        return blockedPrefixes.contains { normalized.hasPrefix($0) }
    }

    private static func containsBrokerPromoPhrase(_ text: String) -> Bool {
        firstBrokerPromoPhraseIndex(in: text) != nil
    }

    private static func firstBrokerPromoPhraseIndex(in text: String) -> String.Index? {
        let patterns = [
            #"\bFIND\s+YOUR\s+NEXT\s+LOAD\b"#,
            #"\bVISITING\b"#,
            #"\bWWW\b"#,
            #"HTTPS?://"#,
            #"\bHTTP\b"#,
            #"\bCALL\b"#,
            #"\bEMAIL\b"#
        ]

        var earliest: String.Index?
        for pattern in patterns {
            guard let range = text.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) else { continue }
            if earliest == nil || range.lowerBound < earliest! {
                earliest = range.lowerBound
            }
        }
        return earliest
    }

    private static func shouldNormalizeBrokerToTQL(_ candidate: String,
                                                   documentText: String) -> Bool {
        let broker = candidate.lowercased()
        if broker == "tql" ||
            broker.contains("total quality logistics") ||
            matchesRegex(candidate, pattern: #"(?i)\bTQL\b"#) {
            return true
        }

        let document = documentText.lowercased()
        return broker.contains("quality logistics") &&
            (document.contains("total quality logistics") ||
             matchesRegex(documentText, pattern: #"(?i)\bTQL\b"#))
    }

    private static func pickHeaderBroker(lines: [String],
                                         documentText: String) -> String? {
        var parts: [String] = []

            for raw in lines.prefix(8) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                guard !isOCRDebugMarker(line) else { continue }

            let lower = line.lowercased()
            if isGenericConfirmationTitle(line) {
                if !parts.isEmpty { break }
                continue
            }
            if lower.contains("settlement") ||
                lower.contains("reconciliation") ||
                lower.contains("remittance") ||
                lower.contains("paid amount") ||
                lower.contains("amount paid") ||
                lower.hasPrefix("ref") ||
                lower.contains("$") {
                continue
            }
            if containsBrokerPromoPhrase(line) {
                if !parts.isEmpty { break }
                continue
            }
            if lower.contains("rate confirmation") {
                if !parts.isEmpty { break }
                continue
            }
            if lower.hasPrefix("load") ||
                lower.hasPrefix("issued") ||
                lower.hasPrefix("carrier") ||
                lower.hasPrefix("pickup") ||
                lower.hasPrefix("delivery") {
                continue
            }
            if lower.contains("mc#") ||
                lower.contains("mc #") ||
                lower.contains("dot#") ||
                lower.contains("dot #") ||
                lower.contains("usdot") {
                continue
            }
            if line.contains(":") { continue }
            if matchesRegex(line, pattern: #"^\d{1,6}\s"#) { continue }
            if matchesRegex(lower, pattern: #"\b(?:road|rd|street|st|avenue|ave|boulevard|blvd|drive|dr|lane|ln|suite|ste)\b"#) {
                continue
            }

            let letterCount = line.filter(\.isLetter).count
            guard letterCount >= 2 else { continue }
            parts.append(line)
            if parts.count == 3 { break }
        }

        let combined = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard combined.count >= 3, combined.count <= 80 else { return nil }
        guard !isGenericConfirmationTitle(combined) else { return nil }
        guard !matchesRegex(combined.lowercased(), pattern: #"\b(?:date|time|pickup|delivery|shipment|charges|settlement|reconciliation|remittance|paid|amount|ref)\b"#) else {
            return nil
        }
        return cleanBrokerName(combined, documentText: documentText)
    }

    private static func pickCompanyBrokerCandidate(lines: [String],
                                                   documentText: String) -> String? {
        let candidates = lines.prefix(30).compactMap { raw -> (String, Int)? in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  !isOCRDebugMarker(line),
                  !isGenericConfirmationTitle(line),
                  let broker = cleanBrokerName(line, documentText: documentText)
            else { return nil }

            let lower = broker.lowercased()
            if lower.contains("sacred pathway") { return nil }
            if matchesRegex(lower, pattern: #"\b(?:carrier|phone|email|address|date|contact|factoring|payment|instructions)\b"#) {
                return nil
            }

            var score = 0
            if matchesRegex(broker, pattern: #"(?i)\b(?:inc|llc|ltd|corp|corporation|co)\b\.?"#) { score += 10 }
            if matchesRegex(broker, pattern: #"(?i)\b(?:logistics|freight|transport|transportation|brokerage)\b"#) { score += 6 }
            if broker.contains(",") { score += 2 }
            guard score >= 6 else { return nil }
            return (broker, score)
        }

        return candidates.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.count > $1.0.count
        }.first?.0
    }

    private static func isInvalidStopCompanyLine(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }

        let lower = text.lowercased()
        let rejectPhrases = [
            "appt", "appointment", "arrive", "pickup time",
            "delivery time", "date/time", "date time"
        ]
        if rejectPhrases.contains(where: { lower.contains($0) }) {
            return true
        }

        if lower.contains("$") ||
            lower.contains("paid amount") ||
            lower.contains("amount paid") ||
            lower.contains("settlement") ||
            lower.contains("remittance") {
            return true
        }
        if firstDate(in: text) != nil { return true }
        if matchesRegex(text, pattern: #"\b\d{1,2}:\d{2}\b"#) { return true }
        if matchesRegex(text, pattern: #"(?i)\b\d{1,2}\s*(?:AM|PM)\b"#) { return true }
        if matchesRegex(
            text,
            pattern: #"(?i)\b(?:pickup|delivery|arrival|arrive|ready|close|open)\s*(?:date|time|appt|appointment)\b"#
        ) {
            return true
        }
        if matchesRegex(
            text,
            pattern: #"(?i)^\s*(?:ref(?:erence)?|po|p\.o\.|pickup\s*(?:#|number|no\.?)|delivery\s*(?:#|number|no\.?)|appt\s*(?:#|number|no\.?)|appointment\s*(?:#|number|no\.?)|bol|load|order|confirmation)\b"#
        ) {
            return true
        }
        if matchesRegex(
            text,
            pattern: #"(?i)^\s*[A-Z]{0,5}[\s#:/-]*\d{3,}[A-Z0-9+\-/]*\s*$"#
        ) {
            return true
        }

        let letterCount = text.filter(\.isLetter).count
        let digitCount = text.filter(\.isNumber).count
        if digitCount >= 4 && letterCount <= 6 {
            return true
        }

        return false
    }

    private static func stopCompanyScore(_ raw: String) -> Int {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        var score = 0

        if matchesRegex(
            lower,
            pattern: #"\b(?:inc|llc|ltd|corp|corporation|company|co\.|foods?|logistics|warehouse|distribution|distributing|manufacturing|mfg|produce|farms?|plant|dc|center|centre|cold storage|packing|packaging)\b"#
        ) {
            score += 6
        }
        if lower.split(whereSeparator: { $0.isWhitespace }).count >= 2 {
            score += 1
        }
        if text.filter(\.isLetter).count >= 4 {
            score += 1
        }
        if text.filter(\.isNumber).count > 0 {
            score -= 2
        }
        if text.contains("/") {
            score -= 1
        }
        return score
    }

    // MARK: - Scored broker-email picker (2026-05-18)

    /// Outcome of scoring all the emails on the page.
    struct BrokerEmailPick {
        let email: String       // lowercased
        let lineIndex: Int
        let confidence: Double
        let reason: String      // why it won (DEBUG only)
    }

    /// Pick the broker contact email by proximity to the top-of-doc
    /// broker block, rejecting footer / disclaimer / AR / factoring emails.
    ///
    /// Anchors are the OCR line indices that contain the already-extracted
    /// broker name, phone, or MC#. Emails on the same line or within ±3
    /// lines of any anchor get a large bonus. Emails in the top 40% of
    /// the document also earn a smaller positional bonus.
    ///
    /// Hard-rejected when their line OR the immediate neighbours (±1)
    /// contain finance/disclaimer keywords. This kills the long-standing
    /// "scan grabbed accounting@…" bug on rate cons that print a
    /// "Send invoices to:" block at the bottom of the page.
    static func pickBrokerEmail(lines: [String],
                                brokerName: String?,
                                brokerPhone: String?,
                                brokerMcNumber: String?) -> BrokerEmailPick? {

        // ── 1) Collect every email candidate with its line index. ──
        let emailRegex = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
        struct Cand {
            let email: String          // lowercased
            let lineIndex: Int
            var score: Int = 0
            var rejected: String? = nil
            var reason: String = ""
        }
        var candidates: [Cand] = []
        for (idx, line) in lines.enumerated() {
            let hits = allMatches(line, pattern: emailRegex)
            // For this regex `allMatches` returns the full match because
            // it has no capture group — verify by re-running with the
            // string-level helper. We use a regex object directly to
            // capture every email on a line.
            if hits.isEmpty {
                // Fallback for lines where the regex's first-capture
                // strategy didn't apply: pull addresses with our own scan.
                for m in matchAllEmails(in: line) {
                    candidates.append(Cand(email: m.lowercased(), lineIndex: idx))
                }
            } else {
                for raw in hits {
                    candidates.append(Cand(email: raw.lowercased(), lineIndex: idx))
                }
            }
        }
        // De-duplicate (line-index agnostic — keep the earliest occurrence).
        var seen: Set<String> = []
        candidates = candidates.filter { c in
            if seen.contains(c.email) { return false }
            seen.insert(c.email)
            return true
        }
        #if DEBUG
        print("[DriverHub Parser] broker email candidates: \(candidates.map { $0.email })")
        #endif
        if candidates.isEmpty {
            #if DEBUG
            print("[DriverHub Parser] selected broker email: <nil>")
            #endif
            return nil
        }

        // ── 2) Compute anchor line indices from already-known fields. ──
        var anchors: Set<Int> = []
        if let bn = brokerName, !bn.isEmpty {
            for (i, line) in lines.enumerated() where line.localizedCaseInsensitiveContains(bn) {
                anchors.insert(i)
            }
        }
        if let bp = brokerPhone, !bp.isEmpty {
            // Use the raw digits to be robust against OCR formatting.
            let digits = bp.filter(\.isNumber)
            if !digits.isEmpty {
                for (i, line) in lines.enumerated() {
                    let lineDigits = line.filter(\.isNumber)
                    if lineDigits.contains(digits) { anchors.insert(i) }
                }
            }
        }
        if let mc = brokerMcNumber, !mc.isEmpty {
            for (i, line) in lines.enumerated() where line.contains(mc) {
                anchors.insert(i)
            }
        }

        // ── 3) Score every candidate. ──
        // Footer/disclaimer keywords — case-insensitive substring on the
        // email line and ±1 neighbour lines.
        let rejectKeywords = [
            "factoring", "factor",
            "accounting", "accounts payable", "accounts receivable",
            "remittance",
            "billing", "invoice", "send invoices",
            "ar@", "ap@", "ar dept", "ap dept",
            "disclaimer",
            "terms", "privacy", "conditions",
            "copyright", "©",
            "powered by",
            "confidential",
            "do not reply", "noreply",
            "payments",
        ]
        // Strong-positive keywords near the email — bumps the score even
        // without an anchor match. These are tokens that real rate-con
        // contact blocks routinely print.
        let contactKeywords = [
            "broker", "broker contact",
            "dispatcher", "dispatch contact",
            "sales rep", "account rep", "carrier rep",
            "load contact", "contact:", "email:",
            "phone:", "ph:",
            "mc#", "mc no", "mc number",
        ]
        let topCutoff = max(1, (lines.count * 4) / 10)   // top 40%

        for i in candidates.indices {
            let idx = candidates[i].lineIndex
            // Build the local context = ±1 lines as one lowercased string.
            let lo = max(0, idx - 1)
            let hi = min(lines.count - 1, idx + 1)
            let ctx = lines[lo...hi].joined(separator: " ").lowercased()

            // HARD REJECT first — short-circuit.
            if isOwnerCompanyEmail(candidates[i].email) || containsOwnerCompanyEmailSignal(ctx) {
                candidates[i].rejected = "owner/company email"
                #if DEBUG
                print("[DriverHub Parser] rejected owner/company email: \(candidates[i].email)")
                #endif
                continue
            }
            for bad in rejectKeywords where ctx.contains(bad) {
                candidates[i].rejected = "context contains '\(bad)'"
                break
            }
            if candidates[i].rejected != nil { continue }

            var score = 0
            var why: [String] = []

            // (a) Anchor proximity — strongest signal.
            let nearestAnchor = anchors.map { abs($0 - idx) }.min() ?? Int.max
            switch nearestAnchor {
            case 0:      score += 100; why.append("on anchor line")
            case 1:      score += 80;  why.append("±1 of anchor")
            case 2:      score += 60;  why.append("±2 of anchor")
            case 3:      score += 40;  why.append("±3 of anchor")
            case 4...6:  score += 20;  why.append("±\(nearestAnchor) of anchor")
            default:     break
            }

            // (b) Top-of-doc bonus.
            if idx < topCutoff {
                score += 25
                why.append("top \(topCutoff) lines")
            }

            // (c) Contact-keyword bonus.
            for kw in contactKeywords where ctx.contains(kw) {
                score += 15
                why.append("near '\(kw)'")
                break
            }

            // (d) Local-part shape — prefer a person-shaped local part.
            let local = candidates[i].email.split(separator: "@").first ?? ""
            if local.contains(where: { $0.isLetter }) {
                score += 5
                why.append("alpha local-part")
            }

            candidates[i].score = score
            candidates[i].reason = why.joined(separator: ", ")
        }

        // ── 4) Pick the winner. ──
        let valid = candidates.filter { $0.rejected == nil && $0.score > 0 }
        let winner = valid.max { a, b in
            if a.score != b.score { return a.score < b.score }
            // Tie-break: prefer the earlier line.
            return a.lineIndex > b.lineIndex
        }

        // ── 5) DEBUG enumerate. ──
        #if DEBUG
        let tag = "SP_DEBUG_RATECON"
        print("[\(tag)] pickBrokerEmail — anchors=\(anchors.sorted()) candidates=\(candidates.count)")
        for c in candidates.sorted(by: { $0.lineIndex < $1.lineIndex }) {
            let isWinner = winner.map { $0.email == c.email } ?? false
            let marker = isWinner ? "  WIN " : "      "
            if let r = c.rejected {
                print("[\(tag)]\(marker)line[\(c.lineIndex)] \(c.email) REJECT(\(r))")
            } else {
                print("[\(tag)]\(marker)line[\(c.lineIndex)] \(c.email) score=\(c.score) [\(c.reason)]")
            }
        }
        #endif

        #if DEBUG
        print("[DriverHub Parser] selected broker email: \(winner?.email ?? "<nil>")")
        #endif

        guard let w = winner else { return nil }
        // Confidence: scale 0–200 → 0.5–0.95.
        let conf = min(0.95, 0.5 + Double(w.score) / 400.0)
        return BrokerEmailPick(
            email: w.email,
            lineIndex: w.lineIndex,
            confidence: conf,
            reason: w.reason
        )
    }

    /// Pull every email on a line (used as a fallback when allMatches
    /// returns an empty result for whatever reason).
    private static func matchAllEmails(in text: String) -> [String] {
        let pat = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
        guard let rx = try? NSRegularExpression(pattern: pat) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return rx.matches(in: text, range: range).compactMap { m -> String? in
            guard let r = Range(m.range, in: text) else { return nil }
            return String(text[r])
        }
    }

    private static func isOwnerCompanyEmail(_ email: String) -> Bool {
        containsOwnerCompanyEmailSignal(email)
    }

    private static func containsOwnerCompanyEmailSignal(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("sacredpathway.org") ||
            lower.contains("sacredbilltracker") ||
            lower.contains("sacredpathway") ||
            lower.contains("jamie@") ||
            lower.contains("demarquis@")
    }

    /// Generic accessorial-amount extractor. Tries each keyword in turn and
    /// returns the first plausible dollar value within a short label window.
    private static func extractMoney(_ text: String, keywords: [String]) -> Double? {
        for kw in keywords {
            // Allow up to 40 chars between the label and the amount —
            // handles "FSC ........ $123.45" / "FSC: $123" / "FSC $123".
            let pat = #"(?i)\b\#(kw)\b[^\n$]{0,40}\$?\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?)"#
            if let raw = firstRegex(text, pattern: pat) {
                if let v = Double(raw.replacingOccurrences(of: ",", with: "")) {
                    if v > 0 && v < 50_000 { return v }
                }
            }
        }
        return nil
    }

    // MARK: - Recon / reconciliation extractor

    /// Reconciliation / settlement statement parser.
    ///
    /// Recon docs are fundamentally different from rate confirmations:
    ///   * They list MULTIPLE identifiers per row (Seq #, Ref #, Invoice #,
    ///     Settlement #, Load #, Trip #).
    ///   * The Load # is the TRUE freight identifier (typically 6+ chars,
    ///     often alphanumeric like "LD-2841", "1284756", "TXP-998112").
    ///   * The Sequence/Ref/Invoice # is short (3–5 digits) and is just a
    ///     row counter or factor reference — NOT the load.
    ///   * The Amount field is exact and must be preserved with decimals.
    ///
    /// Strategy:
    ///   1. Collect EVERY labeled ID with its kind (load / seq / ref /
    ///      invoice / settlement / trip / order).
    ///   2. Pick the highest-priority kind for `loadNumber` (load > trip >
    ///      order > pro > shipment).
    ///   3. Send everything else to the `referenceNumber` slot and append
    ///      to `notes` so it shows in the Info / Special Notes section.
    ///   4. Re-extract the Amount strictly with decimal preservation; prefer
    ///      labels: Net Pay > Amount Paid > Paid Amount > Net > Total > Amount.
    enum Recon {

        /// Identifier-kind priority for choosing the true load number.
        /// Lower index = higher priority.
        static let loadKindPriority: [String] = [
            "load", "load id", "load number", "trip", "trip number",
            "order", "order number", "pro", "pro number",
            "shipment", "shipment id", "freight id"
        ]

        /// Identifier-kind tokens that should NEVER be promoted to loadNumber.
        /// These always go into Reference / Info.
        static let nonLoadKinds: Set<String> = [
            "seq", "sequence", "ref", "reference",
            "invoice", "inv", "settlement", "stmt", "statement",
            "check", "ach", "batch", "remit", "row"
        ]

        static func fill(_ out: inout ParsedLoadFields,
                         joined: String,
                         lines: [String]) {

            // 1) Collect every labeled identifier with its kind.
            // The regex below already handles the optional "number/no/num/id/#"
            // suffix, so the label list only contains the BARE labels.
            // Pattern: <label> [number|no|num|id|#]? [:#-]? <value>
            // Examples that match: "Load # 1284756", "Seq No. 12",
            // "Reference #: REF-7821", "Invoice 88123", "Settlement ID 99821".
            let labels = [
                "load id", "load",
                "trip",
                "order",
                "pro",
                "shipment",
                "freight",
                "sequence", "seq",
                "reference", "ref",
                "invoice", "inv",
                "settlement", "stmt", "statement",
                "check",
                "ach",
                "batch", "row"
            ]

            struct Hit {
                let kind: String              // canonical lowercase label
                let value: String             // cleaned identifier
                let isNumeric: Bool
                let length: Int
            }
            var hits: [Hit] = []

            for label in labels {
                // Escape spaces in multi-word labels — within a label we still
                // allow tab-or-space, but NEVER a newline.
                let escapedLabel = label.replacingOccurrences(of: " ", with: "[ \\t]+")
                // CRITICAL: between the label and the value we use [ \t]*
                // (NOT \s*) so the regex CANNOT span a newline. Without this,
                // a column-header label like "Net Pay" on one line would
                // grab "12" from the table row beneath it.
                let pat = #"(?i)\b\#(escapedLabel)\b[ \t]*(?:number|no\.?|num\.?|id|#)?[ \t]*[:#\-]?[ \t]*([A-Z0-9][A-Z0-9\-]{2,24})"#
                let matches = allMatches(joined, pattern: pat)
                for raw in matches {
                    let v = raw.cleanID
                    // Reject obvious non-IDs (single letters, pure dashes).
                    guard v.count >= 3 else { continue }
                    // Reject column-header words like "Reference", "Pickup",
                    // "Delivery", "Number" — a real ID must contain at least
                    // one digit.
                    guard v.contains(where: { $0.isNumber }) else { continue }
                    let isNum = v.allSatisfy { $0.isNumber }
                    hits.append(Hit(
                        kind: canonicalKind(label),
                        value: v,
                        isNumeric: isNum,
                        length: v.count
                    ))
                }
            }

            // 1b) Table-row sequence detection.
            //     Recon docs typically lay out per-load rows as:
            //         "12     LD-1284756   REF-7821   ..."
            //     The leading short number IS the sequence/row counter and
            //     is NOT the load number. Capture it here so it lands in
            //     the Info block even though there's no inline "Seq #" label
            //     on the same line.
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let seq = firstRegex(
                    trimmed,
                    pattern: #"^([0-9]{1,4})[ \t]{2,}(?=[A-Z]{1,4}-?[0-9]{4,}|[A-Z]{2,}[0-9]{4,}|[0-9]{6,})"#
                ) {
                    if seq.count <= 4, !seq.isEmpty {
                        hits.append(Hit(
                            kind: "sequence",
                            value: seq,
                            isNumeric: true,
                            length: seq.count
                        ))
                    }
                }
            }

            // 2) Pick the best loadNumber candidate.
            //    a) Prefer any hit whose canonical kind is in loadKindPriority.
            //    b) Within those, prefer the longest identifier (true load IDs
            //       are typically 6+ chars; row sequence IDs are 1–5 digits).
            //    c) If no labeled load-kind hit exists, fall back to the
            //       longest alphanumeric ID that is NOT a sequence/ref/invoice.
            let loadKinds = Set(loadKindPriority)
            let loadCandidates = hits.filter { loadKinds.contains($0.kind) }
            let bestLoad = loadCandidates.max { a, b in
                // Prefer non-numeric (alphanumeric freight IDs are usually
                // the real load) then longer.
                if a.isNumeric != b.isNumeric { return a.isNumeric && !b.isNumeric }
                return a.length < b.length
            }

            if let pick = bestLoad, pick.length >= 4 {
                // Demote any previous short load# to referenceNumber/Info
                // before overwriting. Common case: generic regex matched
                // "Load # 1234" first, then recon found "Trip TXP-998112"
                // which is the real load — "1234" must NOT just vanish.
                if let prev = out.loadNumber,
                   prev != pick.value,
                   out.referenceNumber == nil {
                    out.referenceNumber = prev
                    out.confidence["referenceNumber"] = 0.85
                }
                out.loadNumber = pick.value
                out.confidence["loadNumber"] = 0.95
            } else if out.loadNumber == nil
                       || (out.loadNumber?.count ?? 0) <= 5
                       || !(out.loadNumber?.contains(where: { $0.isNumber }) ?? false) {
                // No labeled load hit (or the existing one is short/headerish).
                // Fall back to a freight-ID heuristic: scan the doc for tokens
                // that look like real load identifiers (e.g. LD-1284756,
                // TXP-998112, or 6+ digit pure numerics) and pick the most
                // freight-like (alphanumeric over pure numeric, longer wins).
                //
                // CRITICAL: exclude any token that was already labeled as a
                // non-load kind (ACH, Check, Settlement, Invoice, Reference,
                // Sequence). Without this filter, "ACH-882104" would beat
                // "LD-1284756" simply for being encountered first.
                let excluded: Set<String> = Set(hits
                    .filter { !loadKinds.contains($0.kind) }
                    .map { $0.value })
                let freightIDs = allMatches(
                    joined,
                    pattern: #"\b([A-Z]{1,4}-?[0-9]{4,12}|[0-9]{6,12}|[A-Z]{2,}[0-9]{4,})\b"#
                ).filter { !excluded.contains($0) }
                let best = freightIDs.max { a, b in
                    let aHasLetter = a.contains(where: { $0.isLetter })
                    let bHasLetter = b.contains(where: { $0.isLetter })
                    if aHasLetter != bHasLetter { return !aHasLetter }
                    return a.count < b.count
                }
                if let pick = best, pick.count >= 6 {
                    // Demote any previous (short) loadNumber to reference.
                    if let prev = out.loadNumber,
                       prev != pick, out.referenceNumber == nil {
                        out.referenceNumber = prev
                        out.confidence["referenceNumber"] = 0.85
                    }
                    out.loadNumber = pick
                    out.confidence["loadNumber"] = 0.85
                }
            }

            // 3) Pick a referenceNumber candidate (for the Reference field).
            //    Prefer the first labeled "reference" hit; otherwise the
            //    first sequence hit. canonicalKind already collapses
            //    "ref"->"reference" and "seq"->"sequence" so we only check
            //    the canonical form.
            let refCandidates = hits.filter { $0.kind == "reference" }
            if let pick = refCandidates.first, out.referenceNumber == nil {
                out.referenceNumber = pick.value
                out.confidence["referenceNumber"] = 0.9
            } else if out.referenceNumber == nil {
                let seqCandidates = hits.filter { $0.kind == "sequence" }
                if let pick = seqCandidates.first {
                    out.referenceNumber = "Seq " + pick.value
                    out.confidence["referenceNumber"] = 0.85
                }
            }

            // 4) Append every non-load identifier to notes so the user sees
            //    them in the Info / Special Notes field. Deduplicate.
            var infoLines: [String] = []
            var seen: Set<String> = []
            // Avoid duplicating values already assigned to load / reference.
            if let v = out.loadNumber { seen.insert(v) }
            if let v = out.referenceNumber { seen.insert(v) }

            for h in hits {
                // Skip kinds that are load-priority — they already went into
                // loadNumber (or lost to a longer competitor).
                if loadKinds.contains(h.kind) { continue }
                if seen.contains(h.value) { continue }
                if h.value.count < 2 { continue }
                let pretty = prettyKindLabel(h.kind) + ": " + h.value
                infoLines.append(pretty)
                seen.insert(h.value)
            }
            if !infoLines.isEmpty {
                let infoBlock = "Info (from settlement):\n" + infoLines.joined(separator: "\n")
                if let existing = out.notes, !existing.isEmpty {
                    out.notes = existing + "\n\n" + infoBlock
                } else {
                    out.notes = infoBlock
                    out.confidence["notes"] = 0.85
                }
            }

            // 5) Re-extract Amount with strict label priority + decimal
            //    preservation. Recon amounts must NEVER be rounded and must
            //    NEVER come from a nearby unrelated number.
            if let pick = extractReconAmount(joined: joined) {
                out.rate = pick.value
                out.confidence["rate"] = pick.confidence
            }
        }

        /// Canonicalize a label string ("Load Number", "load #", "load id")
        /// to a stable token used in priority/dedupe lookups.
        private static func canonicalKind(_ label: String) -> String {
            let l = label.lowercased()
            // Strip suffixes like "number", "no", "#", "id".
            let cleaned = l.replacingOccurrences(
                of: #"\s*(number|no\.?|num\.?|id|#)\s*$"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            // Map common short forms.
            switch cleaned {
            case "load": return "load"
            case "trip": return "trip"
            case "order": return "order"
            case "pro": return "pro"
            case "shipment": return "shipment"
            case "freight": return "freight id"
            case "seq", "sequence": return "sequence"
            case "ref", "reference": return "reference"
            case "inv", "invoice": return "invoice"
            case "stmt", "statement", "settlement": return "settlement"
            case "check": return "check"
            case "ach": return "ach"
            case "batch": return "batch"
            case "row": return "row"
            default: return cleaned
            }
        }

        /// Title-cased pretty version of a kind for the Info block.
        private static func prettyKindLabel(_ kind: String) -> String {
            switch kind {
            case "sequence": return "Sequence"
            case "reference": return "Reference"
            case "invoice": return "Invoice"
            case "settlement": return "Settlement"
            case "check": return "Check"
            case "ach": return "ACH"
            case "batch": return "Batch"
            case "row": return "Row"
            case "freight id": return "Freight ID"
            case "pro": return "PRO"
            default: return kind.prefix(1).uppercased() + kind.dropFirst()
            }
        }

        /// One amount candidate with the label that anchored it and a
        /// computed confidence score (higher when label is unambiguous).
        struct AmountPick {
            let value: Double
            let raw: String
            let confidence: Double
        }

        /// Strict money extractor for recon docs. Tries labels in priority
        /// order and parses the literal printed value WITHOUT rounding.
        /// Decimal places are preserved exactly as they appear in the doc.
        static func extractReconAmount(joined: String) -> AmountPick? {
            // Ordered by priority — most specific recon-payment labels first.
            // Each entry: (label-regex, confidence).
            let labeled: [(String, Double)] = [
                (#"net\s*pay(?:ment)?"#,          0.98),
                (#"amount\s*paid"#,                0.97),
                (#"paid\s*amount"#,                0.97),
                (#"net\s*amount"#,                 0.96),
                (#"check\s*amount"#,               0.96),
                (#"payment\s*amount"#,             0.95),
                (#"total\s*payment"#,              0.94),
                (#"total\s*paid"#,                 0.94),
                (#"settlement\s*amount"#,          0.93),
                (#"net\b"#,                        0.90),
                (#"total\s*amount"#,               0.88),
                (#"total\b"#,                      0.85),
                (#"amount\b"#,                     0.82),
            ]
            // Capture: optional $, then a dollar value with optional commas
            // and optional decimal. The decimal part is preserved exactly so
            // values like 1234.5, 1234.50, 1234.567 all parse to the right
            // Double without forced rounding.
            let amountCapture = #"\$?\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]+)?|[0-9]+(?:\.[0-9]+)?)"#

            // Two passes per label:
            //   Pass A — same-line: "Net Pay: $4,325.75" on one line.
            //   Pass B — newline-tolerant: "Net Pay:\n $4,325.75" (very common
            //            on real recon footers where the amount is right-aligned
            //            on the next line). This pass requires BOTH (a) the
            //            label to be followed by a `:`/`=`, AND (b) the captured
            //            amount to start with `$`. That two-anchor check makes
            //            it safe to cross a single newline without accidentally
            //            binding a column-header label to a table-row value.
            for (label, conf) in labeled {
                let sameLine = #"(?i)\b"# + label + #"[ \t]*[:=\-]?[ \t]*"# + amountCapture
                if let raw = firstRegex(joined, pattern: sameLine) {
                    let normalized = raw.replacingOccurrences(of: ",", with: "")
                    if let v = Double(normalized), v > 0, v < 1_000_000 {
                        return AmountPick(value: v, raw: raw, confidence: conf)
                    }
                }
                // Newline-tolerant fallback (label must have :/= and value must
                // start with $). The `[ \t]*\r?\n[ \t]*` allows EXACTLY one
                // line break between label and value.
                let crossLine = #"(?i)\b"# + label + #"[ \t]*[:=][ \t]*\r?\n[ \t]*\$[ \t]*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]+)?|[0-9]+(?:\.[0-9]+)?)"#
                if let raw = firstRegex(joined, pattern: crossLine) {
                    let normalized = raw.replacingOccurrences(of: ",", with: "")
                    if let v = Double(normalized), v > 0, v < 1_000_000 {
                        return AmountPick(value: v, raw: raw, confidence: max(0.85, conf - 0.05))
                    }
                }
            }
            return nil
        }
    }

    // MARK: - Load-number cross-validation

    /// Final-pass safety net.
    ///
    /// If the chosen `loadNumber` is suspiciously short (3–5 digits, pure
    /// numeric) AND a longer freight-style identifier exists elsewhere in
    /// the document, swap them: the longer one becomes the load number and
    /// the short numeric goes into `referenceNumber` (Info field). This
    /// catches the common recon failure mode where a tiny sequence number
    /// was picked up before the real load ID.
    static func validateLoadNumberAgainstAlternates(_ out: inout ParsedLoadFields,
                                                    joined: String) {
        guard let current = out.loadNumber else { return }
        // Only "fix" the case where current looks like a row-sequence ID.
        let isShortNumeric = current.count <= 5 && current.allSatisfy { $0.isNumber }
        guard isShortNumeric else { return }

        // Find longer alphanumeric IDs that look like freight identifiers.
        // Hyphenated forms ("LD-2841", "TXP-998112") and 6+ digit numerics
        // are both common.
        let candidates = allMatches(joined, pattern: #"\b([A-Z]{1,4}-?[0-9]{4,10}|[0-9]{6,12}|[A-Z]{2,}[0-9]{4,})\b"#)
            .filter { $0 != current }
            .filter { $0.count >= 6 }
            .filter { loadIdentifierRejectionReason(value: $0, source: joined, label: "alternate") == nil }

        // Prefer alphanumerics over pure numerics (alphanumeric IDs are
        // almost always intentional freight identifiers).
        let best = candidates.max { a, b in
            let aHasLetter = a.contains(where: { $0.isLetter })
            let bHasLetter = b.contains(where: { $0.isLetter })
            if aHasLetter != bHasLetter { return !aHasLetter }
            return a.count < b.count
        }

        if let promoted = best {
            // Demote the short numeric to referenceNumber unless it's already
            // assigned.
            if out.referenceNumber == nil || out.referenceNumber == current {
                out.referenceNumber = current
                out.confidence["referenceNumber"] = 0.85
            } else {
                // Already have a ref — append the short to notes/Info.
                let line = "Sequence: \(current)"
                if let n = out.notes, !n.isEmpty {
                    if !n.contains(line) {
                        out.notes = n + "\n" + line
                    }
                } else {
                    out.notes = "Info:\n" + line
                }
            }
            out.loadNumber = promoted
            out.confidence["loadNumber"] = max(out.confidence["loadNumber"] ?? 0, 0.9)
        }
    }

    // MARK: - Vendor: Lowe's

    /// Lowe's-specific extractor. Lowe's rate cons and delivery manifests
    /// use a small, predictable label vocabulary (PRO #, BOL Number, TR#,
    /// Store #, RDC #, etc.). These patterns are aggressive on Lowe's
    /// terminology and run as a post-pass so they override anything the
    /// generic sweep guessed.
    enum Lowes {
        static func fill(_ out: inout ParsedLoadFields,
                         joined: String,
                         lines: [String]) {
            // PRO #  → primary load identifier on Lowe's docs.
            if let m = firstRegex(joined, pattern: #"(?i)\bpro\s*(?:number|no\.?|#)\s*[:#\-]?\s*([A-Z0-9][A-Z0-9\-]{3,20})"#) {
                out.loadNumber = m.cleanID
                out.confidence["loadNumber"] = 0.95
            }
            // BOL Number
            if let m = firstRegex(joined, pattern: #"(?i)\bBOL\s*(?:number|no\.?|#)?\s*[:#\-]?\s*([A-Z0-9][A-Z0-9\-]{5,20})"#) {
                out.bolNumber = m.cleanID
                out.confidence["bolNumber"] = 0.95
            }
            // TR#  → trailer.
            if let m = firstRegex(joined, pattern: #"(?i)\bTR\s*#?\s*[:#\-]?\s*([A-Z0-9][A-Z0-9\-]{1,15})"#) {
                out.trailerNumber = m.cleanID
                out.confidence["trailerNumber"] = 0.95
            }
            // RDC #  → reference number / destination DC.
            if let m = firstRegex(joined, pattern: #"(?i)\bRDC\s*#?\s*[:#\-]?\s*([0-9]{2,5})"#) {
                if out.referenceNumber == nil {
                    out.referenceNumber = "RDC \(m.cleanID)"
                    out.confidence["referenceNumber"] = 0.9
                }
            }
            // Store #  → also captured as reference if RDC wasn't present.
            if out.referenceNumber == nil,
               let m = firstRegex(joined, pattern: #"(?i)\bstore\s*#?\s*[:#\-]?\s*([0-9]{2,5})"#) {
                out.referenceNumber = "Store \(m.cleanID)"
                out.confidence["referenceNumber"] = 0.85
            }
            // PO No. (Lowe's often uses "PO No.")
            if out.poNumber == nil,
               let m = firstRegex(joined, pattern: #"(?i)\bP\.?O\.?\s*(?:number|no\.?|num\.?|#)\s*[:#\-]?\s*([A-Z0-9][A-Z0-9\-]{2,20})"#) {
                out.poNumber = m.cleanID
                out.confidence["poNumber"] = 0.9
            }
            // Carrier Reference Number
            if let m = firstRegex(joined, pattern: #"(?i)\bcarrier\s*reference\s*(?:number|no\.?|#)?\s*[:#\-]?\s*([A-Z0-9][A-Z0-9\-]{3,20})"#) {
                out.referenceNumber = m.cleanID
                out.confidence["referenceNumber"] = 0.95
            }
            // Lowe's line haul / linehaul pay.
            if out.rate == nil,
               let v = extractMoney(joined, keywords: ["line\\s*haul", "linehaul", "freight\\s*charge"]) {
                out.rate = v
                out.confidence["rate"] = 0.9
            }
            // Lowe's appointment date — "Pickup Appt" / "Delivery Appt".
            if let raw = firstRegex(joined, pattern: #"(?i)pickup\s*appt(?:ointment)?\s*[:#\-]?\s*([0-9/\-]{6,10}(?:\s+\d{1,2}:\d{2})?)"#) {
                if let d = firstDate(in: raw) {
                    out.pickupDate = d
                    out.confidence["pickupDate"] = 0.95
                }
            }
            if let raw = firstRegex(joined, pattern: #"(?i)delivery\s*appt(?:ointment)?\s*[:#\-]?\s*([0-9/\-]{6,10}(?:\s+\d{1,2}:\d{2})?)"#) {
                if let d = firstDate(in: raw) {
                    out.deliveryDate = d
                    out.confidence["deliveryDate"] = 0.95
                }
            }
            // Lowe's-default shipper name when nothing was extracted.
            if out.shipperName == nil {
                out.shipperName = "Lowe's Home Centers, LLC"
                out.confidence["shipperName"] = 0.6
            }
        }
    }

    // MARK: - Rate-con-specific broadening (2026-05-18)

    /// Rate-confirmation extractor that fires AFTER the generic regex sweep
    /// and AFTER any vendor-specific override. Its job is to fill in the
    /// `loadNumber` and `rate` fields when the generic patterns missed.
    ///
    /// Critical constraint — **NEVER runs on recon/settlement docs.**
    /// The caller already gates this with `documentType != .recon`, but the
    /// guard at the top of `fill` re-asserts that invariant. Rate-con docs
    /// use a much wider label vocabulary (Confirmation #, Tender #, Booking
    /// #, sometimes even plain Reference #) — promoting any of those on a
    /// recon doc would defeat the existing Ref# protection.
    ///
    /// Strategy:
    ///   1. If `loadNumber` is missing, try a broadened label list
    ///      (confirmation, conf, tender, booking, tracking, rc, carrier id,
    ///      load id) on the same line as the value.
    ///   2. If STILL missing, allow "Reference"/"Ref" as a load-number
    ///      fallback on rate cons only — many broker rate cons literally
    ///      label the load identifier as "Reference Number".
    ///   3. If STILL missing, pick the most freight-like alphanumeric in
    ///      the top 25 OCR lines, excluding tokens that are obviously a
    ///      phone, MC, weight, mileage, date, or dollar amount.
    ///   4. Then for `rate`: a broader strong-token list (Carrier Rate,
    ///      Tender Amount, Load Pay, Total Pay, Pay Amount, Booked Rate,
    ///      Trip Pay).
    enum RateCon {
        static func fill(_ out: inout ParsedLoadFields,
                         joined: String,
                         lines: [String]) {

            // Hard guard — never touch recon docs.
            guard out.documentType != .recon else { return }

            // ── Step 1: broader label-based loadNumber patterns ──
            if out.loadNumber == nil {
                // Note: keep "ref|reference" OUT of this list. Those land
                // in step 2, where we re-check that it's a rate-con only.
                let labels: [String] = [
                    "confirmation", "rate\\s*confirmation", "load\\s*confirmation",
                    "conf",
                    "tender",
                    "booking",
                    "tracking",
                    "rc",
                    "carrier\\s*id", "carrier\\s*number",
                    "load\\s*id", "load"
                ]
                for label in labels {
                        let pat = #"(?i)\b"# + label + #"[ \t]*(?:number|no\.?|num\.?|id|#)?[ \t]*[:#\-]?[ \t]*([A-Z0-9][A-Z0-9\-]{3,20})"#
                        for raw in allMatches(joined, pattern: pat) {
                            guard let v = cleanFreightIdentifier(raw) else { continue }
                            // Skip if value is just a label word (e.g. "Number",
                            // "Carrier", "Pickup") — these slip through when the
                        // OCR puts two labels next to each other.
                        let lower = v.lowercased()
                        let bad: Set<String> = [
                            "number", "carrier", "pickup", "delivery",
                            "shipper", "consignee", "reference", "phone",
                            "broker"
                        ]
                        if bad.contains(lower) { continue }
                        out.loadNumber = v
                        out.confidence["loadNumber"] = 0.9
                        break
                    }
                    if out.loadNumber != nil { break }
                }
            }

            // Reference / Ref values stay in referenceNumber only. Real device
            // OCR frequently places unrelated Ref# and acceptance/audit IDs near
            // the top of a document, so promoting Ref# to Load # is too risky.

            // ── Step 3: positional fallback in top 25 OCR lines ──
            // Last-ditch: rate cons commonly print the load number near the
            // top with no useful label ("12345678" stamped under the logo).
            // Find the longest digit-only / alphanumeric token in the top
            // 25 lines that isn't obviously a phone, MC#, weight, miles,
            // date, time, or dollar amount.
            if out.loadNumber == nil {
                let topSlice = Array(lines.prefix(25))
                var bestToken: String?
                for line in topSlice {
                    let lower = line.lowercased()
                    // Skip lines that are obviously something else.
                    if lower.contains("phone") || lower.contains("fax")
                        || lower.contains("mc#") || lower.contains("mc ")
                        || lower.contains("weight") || lower.contains("wt")
                        || lower.contains("miles") || lower.contains("mi.")
                        || lower.contains("$") || lower.contains("zip")
                        || lower.contains("dot") || lower.contains("ein") {
                        continue
                    }
                    // Skip date-ish lines.
                    if firstRegex(line, pattern: #"\b\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4}\b"#) != nil { continue }
                    // Pull every alphanumeric token in the line that could
                    // be a freight ID (6–12 chars, contains a digit).
                    let candidates = allMatches(
                        line,
                        pattern: #"\b([A-Z]{0,4}\-?[0-9]{5,10}|[0-9]{6,10}|[A-Z]{2,}[0-9]{4,})\b"#
                    )
                    for c in candidates {
                        guard let clean = cleanFreightIdentifier(c) else { continue }
                        // Exclude tokens that look like phone numbers (10 digits).
                        if clean.allSatisfy({ $0.isNumber }), clean.count == 10 { continue }
                        // Exclude tokens that look like zip codes (5 digits).
                        if clean.allSatisfy({ $0.isNumber }), clean.count == 5 { continue }
                        // Exclude already-known fields.
                        if clean == out.brokerMcNumber || clean == out.poNumber
                            || clean == out.trailerNumber || clean == out.bolNumber {
                            continue
                        }
                        // Keep the longest.
                        if (bestToken?.count ?? 0) < clean.count {
                            bestToken = clean
                        }
                    }
                }
	                if let pick = bestToken,
	                   pick.count >= 6,
	                   loadIdentifierRejectionReason(value: pick, source: joined, label: "positional") == nil {
	                    out.loadNumber = pick
	                    out.confidence["loadNumber"] = 0.55
	                }
            }

            // Rate-amount detection now lives in the scored `pickRate(...)`
            // helper, which runs once from extractFields(...). The previous
            // Step 4 / Step 5 fallbacks here would otherwise *override*
            // pickRate's decision with weaker `extractMoney` matches that
            // didn't carry the reject-keyword guard for fuel / lumper /
            // detention / etc. Keeping rate logic in a single place stops
            // accessorial line items from beating the true carrier pay.
        }
    }

    // MARK: - Helpers

    /// One pickup or delivery block — what `blockAt` returns.
    private struct AddrBlock {
        let address: String?
        let cityState: String?
        let companyName: String?
        let allText: String
    }

    /// Find every line index whose text matches any of the supplied anchor
    /// regexes. Returns indexes in document order so the scorer can pick the
    /// best match.
    private static func anchorHits(lines: [String], regexes: [String]) -> [Int] {
        var hits: Set<Int> = []
        for (idx, line) in lines.enumerated() {
            for pat in regexes {
                if firstRegex(line, pattern: pat) != nil {
                    hits.insert(idx)
                    break
                }
            }
        }
        return hits.sorted()
    }

    /// Score an address block by how rich it is — used to disambiguate when
    /// a doc has multiple anchors (e.g. "Pickup" once in a header table and
    /// once in the body). Higher = more useful block.
    private static func score(_ block: AddrBlock) -> Int {
        var s = 0
        if block.cityState   != nil { s += 4 }
        if block.address     != nil { s += 2 }
        if block.companyName != nil { s += 1 }
        if firstDate(in: block.allText) != nil { s += 2 }
        return s
    }

    private enum StopKind {
        case pickup
        case delivery
    }

    private static func pairedStopBlocks(lines: [String],
                                         pickupHits: [Int],
                                         deliveryHits: [Int]) -> (pickup: AddrBlock, delivery: AddrBlock)? {
        guard let pickupIdx = pickupHits.first,
              let deliveryIdx = deliveryHits.first,
              abs(pickupIdx - deliveryIdx) <= 2
        else { return nil }

        let orderedStops: [StopKind] = pickupIdx < deliveryIdx
            ? [.pickup, .delivery]
            : [.delivery, .pickup]
        let start = max(pickupIdx, deliveryIdx) + 1
        guard start < lines.count else { return nil }

        let maxEnd = min(lines.count, start + 24)
        var end = maxEnd
        for i in start..<maxEnd {
            let lower = lines[i].lowercased()
            if lower.contains("shipment") ||
                lower.contains("charges") ||
                lower.contains("commodity") ||
                lower.contains("weight") {
                end = i
                break
            }
        }

        let body = lines[start..<end]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var companyRows: [String] = []
        var addressRows: [String] = []
        var cityRows: [String] = []
        var dateRows: [String] = []

        for line in body {
            let lower = line.lowercased()
            if firstRegex(
                line,
                pattern: #"^([A-Za-z][A-Za-z\.\s\-']{1,40}?,\s*[A-Z]{2})(?:\s+\d{5})?$"#
            ) != nil {
                cityRows.append(line)
            } else if firstDate(in: line) != nil {
                dateRows.append(line)
            } else if line.range(of: #"^\s*\d{1,6}\s+[A-Za-z]"#, options: .regularExpression) != nil ||
                        lower.hasPrefix("po box") {
                addressRows.append(line)
            } else if !lower.hasPrefix("ref") &&
                        !lower.hasPrefix("contact") &&
                        !lower.hasPrefix("phone") &&
                        !isInvalidStopCompanyLine(line) {
                companyRows.append(line)
            }
        }

        var pickupLines = [lines[pickupIdx]]
        var deliveryLines = [lines[deliveryIdx]]

        func append(_ values: [String], order: [StopKind]) {
            for (idx, value) in values.prefix(2).enumerated() {
                switch order[idx % order.count] {
                case .pickup:
                    pickupLines.append(value)
                case .delivery:
                    deliveryLines.append(value)
                }
            }
        }

        // OCR often reads the wide company/address columns according to the
        // header order it detected, but reads compact city/date rows in stop
        // order. Keep those assignments separate for two-column rate cons.
        append(companyRows, order: orderedStops)
        append(addressRows, order: orderedStops)
        append(cityRows, order: [.pickup, .delivery])
        append(dateRows, order: [.pickup, .delivery])

        if pickupLines.count == 1 || deliveryLines.count == 1 {
            var alternatingIndex = 0
            for line in body {
                switch orderedStops[alternatingIndex % orderedStops.count] {
                case .pickup:
                    pickupLines.append(line)
                case .delivery:
                    deliveryLines.append(line)
                }
                alternatingIndex += 1
            }
        }

        let pickup = addrBlock(from: pickupLines)
        let delivery = addrBlock(from: deliveryLines)
        guard score(pickup) >= 3, score(delivery) >= 3 else { return nil }
        guard pickup.address != delivery.address || pickup.cityState != delivery.cityState else { return nil }
        return (pickup, delivery)
    }

    /// Build an `AddrBlock` from the lines after a stop anchor. McLeod-style
    /// rate cons can spread one stop over 10+ OCR lines, so stop at the next
    /// stop/payment boundary instead of using a fixed short slice.
    /// Looks for: a company-name line, a street-address line, and a
    /// "City, ST" line.
    private static func blockAt(lines: [String], startIndex idx: Int) -> AddrBlock {
        let end = stopBlockEndIndex(lines: lines, startIndex: idx)
        let slice = Array(lines[idx..<end])
        return addrBlock(from: slice)
    }

    private static func stopBlockEndIndex(lines: [String], startIndex idx: Int) -> Int {
        let maxEnd = min(idx + 18, lines.count)
        guard idx + 1 < maxEnd else { return maxEnd }

        for i in (idx + 1)..<maxEnd {
            let line = lines[i]
            let lower = line.lowercased()
            if matchesRegex(line, pattern: #"(?i)^\s*(?:pu|pickup|pick[\-\s]?up|so|delivery|deliver\s*to|receiver|consignee|destination|drop[\-\s]?off)\s*\d*\b"#) {
                return i
            }
            if matchesRegex(lower, pattern: #"^\s*(payment|carrier\s*freight\s*pay|total\s*carrier\s*pay|instructions|highway\s*audit\s*report|please\s*sign)\b"#) {
                return i
            }
        }
        return maxEnd
    }

    private static func addrBlock(from slice: [String]) -> AddrBlock {
        let blob = slice.joined(separator: "\n")

        // First street-line that looks like "123 Foo St" / "PO Box 9".
        var address: String?
        for line in slice.dropFirst() {
            if line.range(of: #"^\s*\d{1,6}\s+[A-Za-z]"#, options: .regularExpression) != nil ||
               line.lowercased().hasPrefix("po box") {
                address = line.trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // City, ST ZIP — strict line-anchored match so we don't pull street
        // suffixes ("Industrial Blvd") into the city.
        var cityState: String?
        for line in slice.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == address { continue }
            if let m = firstRegex(
                trimmed,
                pattern: #"^([A-Za-z][A-Za-z\.\s\-']{1,40}?,\s*[A-Z]{2})(?:\s+\d{5})?$"#
            ) {
                cityState = m.trimmingCharacters(in: .whitespaces)
                break
            }
        }
        if cityState == nil,
           let m = firstRegex(
            "\n" + blob,
            pattern: #"\n([A-Za-z][A-Za-z\.\s\-']{1,40}?,\s*[A-Z]{2})(?:\s+\d{5})?\b"#
           ) {
            cityState = m.trimmingCharacters(in: .whitespaces)
        }
        if cityState == nil {
            for (offset, line) in slice.dropFirst().enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == address { continue }
                if let groups = firstCaptureGroups(
                    trimmed,
                    pattern: #"^([A-Za-z][A-Za-z\.\s\-']{1,40}?)\s+([A-Z]{2})(?:\s+\d{5})?$"#
                ), groups.count >= 2 {
                    let city = groups[0]
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let state = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !city.isEmpty {
                        cityState = "\(city.capitalized), \(state)"
                        break
                    }
                }
                let nextIndex = offset + 2
                if cityState == nil, slice.indices.contains(nextIndex) {
                    let next = slice[nextIndex].trimmingCharacters(in: .whitespaces)
                    if let groups = firstCaptureGroups(
                        next,
                        pattern: #"^([A-Z]{2})(?:\s+\d{5})?$"#
                    ), !groups.isEmpty,
                       matchesRegex(trimmed, pattern: #"^[A-Za-z][A-Za-z\.\s\-']{1,40}$"#),
                       !isInvalidStopCompanyLine(trimmed),
                       !matchesRegex(trimmed, pattern: #"(?i)^(name|address|date|contact|phone|driver|drvr)\b"#) {
                        let city = trimmed
                            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let state = groups[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        cityState = "\(city.capitalized), \(state)"
                        break
                    }
                }
            }
        }

        // Company / shipper / receiver name — prefer actual company-looking
        // rows and reject appointment/reference/date-time fragments.
        var companyCandidates: [(name: String, score: Int, order: Int)] = []
        for (order, line) in slice.dropFirst().enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == address { continue }
            if trimmed == cityState { continue }
            if firstRegex(trimmed, pattern: #"^\d"#) != nil { continue }   // skip numeric / address
            if firstRegex(trimmed, pattern: #"\d{1,2}:\d{2}"#) != nil { continue } // skip times
            if firstDate(in: trimmed) != nil { continue }                  // skip dates
            if isInvalidStopCompanyLine(trimmed) { continue }
            // Strip leading "Name:" / "Company:" labels.
            let cleaned = trimmed.replacingOccurrences(
                of: #"(?i)^(name|company|consignee|shipper|receiver)\s*[:\-]\s*"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if isInvalidStopCompanyLine(cleaned) { continue }
            if cleaned.count >= 3 && cleaned.count <= 80 {
                companyCandidates.append((
                    cleaned.trimmedCompanySuffix,
                    stopCompanyScore(cleaned),
                    order
                ))
            }
        }

        let companyName = companyCandidates
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.order < $1.order
            }
            .first?
            .name

        return AddrBlock(
            address: address,
            cityState: cityState,
            companyName: companyName,
            allText: blob
        )
    }

    // MARK: - Broker contact-name extraction

    /// Search the OCR lines for a `First Last` line that's likely the broker
    /// rep — the human who booked this load. Strategy:
    ///
    ///   1. Find the line index of the broker email and the broker phone.
    ///   2. Search a small window (±3 lines) above each anchor.
    ///   3. Skip lines that are clearly NOT a person:
    ///      - contain digits
    ///      - contain "@" (the email itself)
    ///      - contain company suffixes (LLC, Inc, Logistics, Brokerage, etc.)
    ///      - contain known driver / carrier / equipment labels
    ///      - are ALL UPPERCASE and longer than 25 chars (banner text)
    ///   4. Accept the first 2-4 word line that looks like a proper name.
    ///   5. Return nil if nothing matches — the caller will fall back to
    ///      inferring from the email local-part.
    fileprivate static func extractBrokerContactName(
        lines: [String],
        emailLowercased: String?,
        phoneNormalized: String?
    ) -> String? {
        // 1. Locate anchor line indices
        var anchorIndices: [Int] = []
        if let email = emailLowercased {
            for (i, l) in lines.enumerated() where l.lowercased().contains(email) {
                anchorIndices.append(i)
            }
        }
        if let phone = phoneNormalized {
            // Strip phone to digits-only for fuzzy match
            let digits = phone.filter(\.isNumber)
            if digits.count >= 10 {
                let tail = String(digits.suffix(10))
                for (i, l) in lines.enumerated() {
                    let lineDigits = l.filter(\.isNumber)
                    if lineDigits.contains(tail) {
                        anchorIndices.append(i)
                    }
                }
            }
        }
        if anchorIndices.isEmpty { return nil }

        let companyTokens: Set<String> = [
            "llc", "inc", "inc.", "corp", "corp.", "co", "ltd", "logistics",
            "brokerage", "freight", "transport", "transportation", "trucking",
            "carriers", "carrier", "express", "lines", "shipping", "supply",
            "industries", "company", "international", "global", "group",
            "enterprises"
        ]
        let skipPrefixes: [String] = [
            "driver", "carrier", "tractor", "trailer", "broker:",
            "shipper", "consignee", "receiver", "load #", "load:",
            "pickup", "delivery", "rate", "total", "mc#", "mc ",
            "dot ", "po #", "po:", "ref ", "reference", "fax", "phone",
            "email", "tel", "tel:", "address", "agent", "dispatch"
        ]

        func isPlausibleName(_ raw: String) -> Bool {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 50 else { return false }
            if trimmed.contains("@") { return false }
            if trimmed.contains("/") || trimmed.contains("\\") { return false }
            if trimmed.rangeOfCharacter(from: .decimalDigits) != nil { return false }
            let lower = trimmed.lowercased()
            for skip in skipPrefixes where lower.hasPrefix(skip) { return false }
            for tok in companyTokens where lower.contains(" \(tok)") || lower.hasSuffix(" \(tok)") {
                return false
            }
            // Reject ALL-CAPS banner lines longer than 25 chars (headers).
            if trimmed == trimmed.uppercased() && trimmed.count > 25 { return false }
            // Must be 2-4 alphabetic words.
            let words = trimmed.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" && $0 != "." })
            guard (2...4).contains(words.count) else { return false }
            // Each word ≥ 2 letters and starts with a letter (allow titles like
            // "Mr.", initials like "J.D.", hyphenated names like "Jean-Pierre").
            for w in words where w.count < 2 { return false }
            // First and last word should start with uppercase letter.
            guard let firstChar = words.first?.first, firstChar.isUppercase else { return false }
            guard let lastChar = words.last?.first, lastChar.isUppercase else { return false }
            return true
        }

        // 2. Walk the anchor neighbourhoods and accept the first plausible
        //    name. Closer to the anchor wins.
        let windowAbove = 3
        let windowBelow = 1
        for anchor in anchorIndices.sorted() {
            let lo = max(0, anchor - windowAbove)
            let hi = min(lines.count - 1, anchor + windowBelow)
            // Closer-to-anchor first: anchor-1, anchor-2, ..., then anchor+1, etc.
            var ordered: [Int] = []
            for offset in 1...windowAbove {
                let idx = anchor - offset
                if idx >= lo { ordered.append(idx) }
            }
            for offset in 1...windowBelow {
                let idx = anchor + offset
                if idx <= hi { ordered.append(idx) }
            }
            for idx in ordered {
                let candidate = lines[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                if isPlausibleName(candidate) {
                    // Normalize whitespace
                    let collapsed = candidate
                        .components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    return collapsed
                }
            }
        }
        return nil
    }

    /// Infer a contact name from an email local-part as a low-confidence
    /// fallback. "adini@TQL.com" → "A Dini", "aaron.dini@TQL.com" → "Aaron
    /// Dini", "aaron_dini@TQL.com" → "Aaron Dini".
    fileprivate static func inferContactNameFromEmail(_ email: String) -> String? {
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        guard !local.isEmpty else { return nil }
        // Reject role inboxes — they're not a person.
        let roleInboxes: Set<String> = [
            "info", "support", "sales", "dispatch", "ops", "operations",
            "billing", "ar", "ap", "accounts", "noreply", "no-reply",
            "admin", "team", "hello", "help"
        ]
        if roleInboxes.contains(local.lowercased()) { return nil }
        // dot / underscore / hyphen separators → "First Last"
        let parts = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
        if parts.count >= 2 {
            return parts
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
        // Single token, e.g. "adini" → "A Dini" (best guess: first letter
        // is initial, rest is surname).
        if local.count >= 3, local.count <= 20 {
            let first = String(local.prefix(1)).uppercased()
            let rest  = String(local.dropFirst()).lowercased()
            let restCap = rest.prefix(1).uppercased() + rest.dropFirst()
            return "\(first) \(restCap)"
        }
        return nil
    }

    private static func firstRegex(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        // Prefer capture group 1; fall back to whole match.
        if match.numberOfRanges > 1 {
            let r = match.range(at: 1)
            if r.location != NSNotFound { return ns.substring(with: r) }
        }
        return ns.substring(with: match.range)
    }

    private static func matchesRegex(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func regexCaptureMatches(_ text: String, pattern: String) -> [[String?]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { idx in
                let r = match.range(at: idx)
                guard r.location != NSNotFound else { return nil }
                return ns.substring(with: r)
            }
        }
    }

    private static func firstCaptureGroups(_ text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { idx in
            let r = match.range(at: idx)
            guard r.location != NSNotFound else { return nil }
            return ns.substring(with: r)
        }
    }

    private static func capture(_ groups: [String?], _ index: Int) -> String? {
        guard groups.indices.contains(index) else { return nil }
        return groups[index]
    }

    private static func allMatches(_ text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).map { match in
            let r = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
            return ns.substring(with: r)
        }
    }

    /// Tries several common date formats. Returns the first hit or nil.
    ///
    /// Special case: rate cons often use bare `MM/dd` (no year). When we hit
    /// that we assume the current year — UNLESS the resulting date is more
    /// than 60 days in the past, in which case we roll forward to next year.
    /// That handles the realistic case of a December load scanned in early
    /// January.
    private static func firstDate(in text: String) -> Date? {
        let formatStrings = [
            "MM/dd/yyyy", "M/d/yyyy", "MM-dd-yyyy", "M-d-yyyy",
            "MM/dd/yy", "M/d/yy",
            "yyyy-MM-dd",
            "MMM d, yyyy", "MMMM d, yyyy",
            "MMM d yyyy", "MMMM d yyyy",
            "d MMM yyyy", "d MMMM yyyy",
        ]
        let patternsWithYear = [
            #"\b\d{1,2}/\d{1,2}/\d{2,4}\b"#,
            #"\b\d{1,2}-\d{1,2}-\d{2,4}\b"#,
            #"\b\d{4}-\d{2}-\d{2}\b"#,
            #"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2},?\s+\d{2,4}\b"#,
            #"\b\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{2,4}\b"#,
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.isLenient = false

        // Pass 1 — full dates with year.
        for pat in patternsWithYear {
            if let raw = firstRegex(text, pattern: pat) {
                let cleaned = raw.replacingOccurrences(of: ".", with: "")
                for fmt in formatStrings {
                    df.dateFormat = fmt
                    if let d = df.date(from: cleaned) { return normalizeTwoDigitYear(d) }
                }
            }
        }

        // Pass 2 — bare MM/dd or MM-dd (no year). Assume current year, roll
        // forward if it lands too far in the past.
        if let raw = firstRegex(text, pattern: #"\b(\d{1,2}[/-]\d{1,2})\b"#) {
            let normalized = raw.replacingOccurrences(of: "-", with: "/")
            let calendar = Calendar.current
            let currentYear = calendar.component(.year, from: Date())
            for year in [currentYear, currentYear + 1] {
                df.dateFormat = "M/d/yyyy"
                if let d = df.date(from: "\(normalized)/\(year)") {
                    let daysAgo = calendar.dateComponents([.day], from: d, to: Date()).day ?? 0
                    // Reject anything more than 60 days in the past — caller
                    // gets nil and the user fills it in by hand.
                    if daysAgo <= 60 {
                        return d
                    }
                }
            }
        }
        return nil
    }

    /// ICU's `yyyy` parses a 2-digit year (e.g. "06/14/26") as year 0026, ~2000
    /// years in the past — which then drops the load out of every windowed
    /// revenue total (This Week/Month) while it still shows in Recent Loads.
    /// Any parsed year below 100 is a 2-digit year; map it to the 2000s so a
    /// rate con printed "MM/dd/yy" buckets into the correct current-era week.
    private static func normalizeTwoDigitYear(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = comps.year, year < 100 else { return date }
        comps.year = year + 2000
        return cal.date(from: comps) ?? date
    }
}

// MARK: - String helpers (file-private)

private extension String {
    /// Strip whitespace + trailing punctuation common in OCR'd IDs.
    var cleanID: String {
        trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
    }

    /// "(555) 123-4567" -> "5551234567" then formatted "(555) 123-4567"
    var normalizedPhone: String {
        let digits = filter(\.isNumber)
        let trimmed = digits.hasPrefix("1") && digits.count == 11
            ? String(digits.dropFirst())
            : digits
        guard trimmed.count == 10 else { return self }
        let area = trimmed.prefix(3)
        let mid  = trimmed.dropFirst(3).prefix(3)
        let last = trimmed.suffix(4)
        return "(\(area)) \(mid)-\(last)"
    }

    /// Drop trailing "Inc.", "LLC", etc. but keep core company name.
    var trimmedCompanySuffix: String {
        var t = trimmingCharacters(in: .whitespaces)
        let suffixes = [", Inc.", ", Inc", ", LLC", ", LLC.", " Inc.", " Inc", " LLC", " LLC.", " Corp.", " Corp"]
        for s in suffixes {
            if t.hasSuffix(s) { t = String(t.dropLast(s.count)); break }
        }
        return t
    }
}
