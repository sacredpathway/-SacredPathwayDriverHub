import Foundation
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
    var brokerPhone: String?
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

    /// Per-field confidence 0.0–1.0
    var confidence: [String: Double] = [:]

    /// Full OCR text — surfaced in the review screen so the user can
    /// double-check anything the parser missed.
    var rawText: String = ""
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

    // MARK: - OCR

    /// Apple Vision text recognition. Returns lines top-to-bottom in
    /// approximate reading order.
    static func recognizeText(in image: UIImage) async -> [String] {
        guard let cg = image.cgImage else { return [] }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let observations = req.results as? [VNRecognizedTextObservation] ?? []
                // Sort top-to-bottom (Vision uses normalized coords with origin at bottom-left).
                let sorted = observations.sorted {
                    $0.boundingBox.maxY > $1.boundingBox.maxY
                }
                let lines = sorted.compactMap { obs -> String? in
                    obs.topCandidates(1).first?.string
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // English first; Vision will still pick up numbers regardless.
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    // MARK: - Field extraction

    static func extractFields(fromLines lines: [String]) -> ParsedLoadFields {
        var out = ParsedLoadFields()
        out.rawText = lines.joined(separator: "\n")
        let joined = out.rawText

        // ---- Pass 0: vendor detection (informs which specialized
        // post-pass overrides generic regex with vendor-specific patterns). ----
        out.sourceVendor = detectVendor(in: joined)

        // ---- Load number ----
        if let m = firstRegex(joined, pattern: #"(?i)\b(?:load|order|trip|pro|shipment|reference|ref)\s*(?:number|no\.?|num\.?|#)?\s*[:#-]?\s*([A-Z0-9][A-Z0-9-]{3,20})"#) {
            out.loadNumber = m.cleanID
            out.confidence["loadNumber"] = 0.85
        }

        // ---- Broker MC number ----
        if let m = firstRegex(joined, pattern: #"(?i)\bMC\s*[#:]?\s*(\d{5,8})"#) {
            out.brokerMcNumber = m
            out.confidence["brokerMcNumber"] = 0.95
        }

        // ---- Broker name ----
        // Best signal in real rate cons: line containing "Broker:" or
        // appearing right above an MC number.
        if let m = firstRegex(joined, pattern: #"(?im)^\s*(?:broker|brokered\s*by|carrier\s*broker|booked\s*by)\s*[:\-]\s*(.+?)\s*$"#) {
            out.brokerName = m.trimmedCompanySuffix
            out.confidence["brokerName"] = 0.85
        } else {
            // Heuristic: first non-empty line that looks like a company
            // (contains LLC / Inc / Logistics / Transport / Freight /
            // Brokerage) and isn't obviously the carrier's own name.
            for line in lines.prefix(15) {
                let l = line.lowercased()
                if l.contains("logistics") || l.contains("freight") ||
                   l.contains("brokerage") || l.contains(" inc") ||
                   l.contains(" llc") || l.contains("transport") {
                    out.brokerName = line.trimmedCompanySuffix
                    out.confidence["brokerName"] = 0.55
                    break
                }
            }
        }

        // ---- Phone numbers (broker phone = first phone we find) ----
        if let m = firstRegex(joined, pattern: #"(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}"#) {
            out.brokerPhone = m.normalizedPhone
            out.confidence["brokerPhone"] = 0.9
        }

        // ---- Email ----
        if let m = firstRegex(joined, pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#) {
            out.brokerEmail = m.lowercased()
            out.confidence["brokerEmail"] = 0.95
        }

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
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(drop[\-\s]?off|drop)\s*[:#\-]?"#,
            #"(?im)^\s*[•\-\*\d\.\)]*\s*(to)\s*[:]"#
        ]

        let pickupHits = anchorHits(lines: lines, regexes: pickupAnchorRegexes)
        let deliveryHits = anchorHits(lines: lines, regexes: deliveryAnchorRegexes)

        // Best pickup block (highest score).
        let pickupBlock = pickupHits
            .map { ($0, blockAt(lines: lines, startIndex: $0)) }
            .max(by: { score($0.1) < score($1.1) })

        // Best delivery block, but EXCLUDE the line index pickup chose so
        // we never tag the same address twice.
        let deliveryBlock: (Int, AddrBlock)? = deliveryHits
            .filter { $0 != pickupBlock?.0 }
            .map { ($0, blockAt(lines: lines, startIndex: $0)) }
            .max(by: { score($0.1) < score($1.1) })

        if let (_, block) = pickupBlock {
            out.pickupAddress = block.address
            out.pickupCityState = block.cityState
            out.shipperName = block.companyName
            if block.cityState != nil { out.confidence["pickupCityState"] = 0.8 }
            if block.address != nil { out.confidence["pickupAddress"] = 0.65 }
            if block.companyName != nil { out.confidence["shipperName"] = 0.6 }

            if let date = firstDate(in: block.allText) {
                out.pickupDate = date
                out.confidence["pickupDate"] = 0.8
            }
            if let t = firstRegex(block.allText, pattern: #"\b\d{1,2}:\d{2}\s*(?:AM|PM|am|pm)?\b"#) {
                out.pickupTime = t.uppercased()
                out.confidence["pickupTime"] = 0.75
            }
        }

        if let (_, block) = deliveryBlock {
            out.deliveryAddress = block.address
            out.deliveryCityState = block.cityState
            out.receiverName = block.companyName
            if block.cityState != nil { out.confidence["deliveryCityState"] = 0.8 }
            if block.address != nil { out.confidence["deliveryAddress"] = 0.65 }
            if block.companyName != nil { out.confidence["receiverName"] = 0.6 }

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
                joined,
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

        // ---- Rate (most reliable: $X,XXX.XX after "rate"/"total"/"amount") ----
        let ratePatterns = [
            #"(?i)(?:total\s*(?:rate|amount|pay)|line\s*haul|agreed\s*rate|rate\s*conf(?:irmation)?|carrier\s*rate|all[-\s]?in|flat\s*rate)[^\n$]{0,40}\$?\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?)"#,
            #"(?i)\brate\s*[:=]\s*\$?\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?)"#,
        ]
        for pat in ratePatterns {
            if let m = firstRegex(joined, pattern: pat) {
                if let v = Double(m.replacingOccurrences(of: ",", with: "")) {
                    out.rate = v
                    out.confidence["rate"] = 0.85
                    break
                }
            }
        }
        // Fallback: largest dollar amount on the page (only if it's >= $200).
        if out.rate == nil {
            let amounts = allMatches(joined, pattern: #"\$\s*([0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]{1,2})?|[0-9]{3,6}(?:\.[0-9]{1,2})?)"#)
                .compactMap { Double($0.replacingOccurrences(of: ",", with: "")) }
                .filter { $0 >= 200 && $0 <= 50_000 }
            if let max = amounts.max() {
                out.rate = max
                out.confidence["rate"] = 0.45
            }
        }

        // ---- Weight ----
        if let m = firstRegex(joined, pattern: #"(?i)\b(?:weight|wt\.?)[:\s]+([0-9]{1,3}(?:,[0-9]{3})*)\s*(?:lbs?|pounds?|kg|kilos?)?"#) {
            out.weight = m + " lbs"
            out.confidence["weight"] = 0.8
        } else if let m = firstRegex(joined, pattern: #"\b([0-9]{2,3}(?:,[0-9]{3})|[0-9]{4,5})\s*(?:lbs?|pounds?)\b"#) {
            out.weight = m + " lbs"
            out.confidence["weight"] = 0.6
        }

        // ---- Commodity ----
        if let m = firstRegex(joined, pattern: #"(?im)^\s*commodity\s*[:\-]\s*(.+?)\s*$"#) {
            out.commodity = m
            out.confidence["commodity"] = 0.85
        }

        // ---- PO / Pickup number ----
        if let m = firstRegex(joined, pattern: #"(?i)\bP\.?O\.?\s*(?:number|num|no\.?|#)?\s*[:#]?\s*([A-Z0-9][A-Z0-9-]{2,15})"#) {
            out.poNumber = m.cleanID
            out.confidence["poNumber"] = 0.8
        }
        if let m = firstRegex(joined, pattern: #"(?i)\b(?:pickup|pick[\-\s]?up|pu)\s*(?:number|num|no\.?|#)\s*[:#]?\s*([A-Z0-9][A-Z0-9-]{2,15})"#) {
            out.pickupNumber = m.cleanID
            out.confidence["pickupNumber"] = 0.8
        }

        // ---- Reference number (separate from load # / PO #) ----
        if let m = firstRegex(joined, pattern: #"(?i)\b(?:reference|ref)\s*(?:number|num|no\.?|#)?\s*[:#\-]?\s*([A-Z0-9][A-Z0-9-]{2,20})"#) {
            out.referenceNumber = m.cleanID
            out.confidence["referenceNumber"] = 0.8
        }

        // ---- Loaded / Deadhead miles printed on the document ----
        // Examples that hit:
        //   "Loaded Miles: 1,234"   "Loaded: 1234 mi"   "Total Loaded Miles 1234"
        //   "Deadhead: 50"          "DH miles: 50"      "Empty Miles 50"
        if let m = firstRegex(joined, pattern: #"(?i)\b(?:loaded\s*miles?|total\s*loaded\s*miles?|loaded)\s*[:#\-]?\s*([0-9]{1,4}(?:,[0-9]{3})?)"#) {
            if let v = Double(m.replacingOccurrences(of: ",", with: "")) {
                out.loadedMiles = v
                out.confidence["loadedMiles"] = 0.85
            }
        }
        if let m = firstRegex(joined, pattern: #"(?i)\b(?:deadhead\s*miles?|dh\s*miles?|empty\s*miles?|deadhead)\s*[:#\-]?\s*([0-9]{1,4})"#) {
            if let v = Double(m) {
                out.deadheadMiles = v
                out.confidence["deadheadMiles"] = 0.85
            }
        }

        // ---- Special notes ----
        if let m = firstRegex(joined, pattern: #"(?is)(?:special\s*instructions|notes|comments)\s*[:\-]\s*(.{5,300}?)(?:\n\s*\n|$)"#) {
            out.notes = m.trimmingCharacters(in: .whitespacesAndNewlines)
            out.confidence["notes"] = 0.6
        }

        // ---- Driver notes / driver-facing instructions ----
        if out.driverNotes == nil,
           let m = firstRegex(joined, pattern: #"(?is)(?:driver\s*(?:notes|instructions)|instructions\s*to\s*driver)\s*[:\-]\s*(.{5,300}?)(?:\n\s*\n|$)"#) {
            out.driverNotes = m.trimmingCharacters(in: .whitespacesAndNewlines)
            out.confidence["driverNotes"] = 0.7
        }

        // ---- Accessorial pay lines: FSC, lumper, detention, stop-off ----
        // Each scans the document for a labeled dollar amount near common
        // accessorial keywords. Conservative regex — only matches an
        // amount that follows the label within ~40 chars.
        if let v = extractMoney(joined, keywords: ["fsc", "fuel\\s*surcharge", "fuel\\s*sur"]) {
            out.fuelSurcharge = v
            out.confidence["fuelSurcharge"] = 0.85
        }
        if let v = extractMoney(joined, keywords: ["lumper(?:\\s*fee)?"]) {
            out.lumperFee = v
            out.confidence["lumperFee"] = 0.85
        }
        if let v = extractMoney(joined, keywords: ["detention(?:\\s*(?:pay|fee|rate))?"]) {
            out.detentionRate = v
            out.confidence["detentionRate"] = 0.8
        }
        if let v = extractMoney(joined, keywords: ["stop[\\-\\s]?off(?:\\s*pay)?", "extra\\s*(?:stop|pickup)"]) {
            out.stopOffPay = v
            out.confidence["stopOffPay"] = 0.8
        }

        // ---- Trailer number ----
        if let m = firstRegex(joined, pattern: #"(?i)\b(?:trailer\s*(?:number|num|no\.?|#)|tlr\s*#?|tr\s*#)\s*[:#]?\s*([A-Z0-9][A-Z0-9\-]{1,15})"#) {
            out.trailerNumber = m.cleanID
            out.confidence["trailerNumber"] = 0.85
        }

        // ---- BOL number ----
        if let m = firstRegex(joined, pattern: #"(?i)\b(?:bill\s*of\s*lading|b\.?o\.?l\.?)\s*(?:number|num|no\.?|#)?\s*[:#\-]?\s*([A-Z0-9][A-Z0-9\-]{3,20})"#) {
            out.bolNumber = m.cleanID
            out.confidence["bolNumber"] = 0.85
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

        return out
    }

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

    /// Build an `AddrBlock` from the 6 lines after a given anchor index.
    /// Looks for: a company-name line, a street-address line, and a
    /// "City, ST" line.
    private static func blockAt(lines: [String], startIndex idx: Int) -> AddrBlock {
        let slice = Array(lines[idx..<min(idx + 6, lines.count)])
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

        // Company / shipper / receiver name — first non-anchor line that
        // isn't the address or the city-state line, and isn't a date / time.
        var companyName: String?
        for line in slice.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == address { continue }
            if trimmed == cityState { continue }
            if firstRegex(trimmed, pattern: #"^\d"#) != nil { continue }   // skip numeric / address
            if firstRegex(trimmed, pattern: #"\d{1,2}:\d{2}"#) != nil { continue } // skip times
            if firstDate(in: trimmed) != nil { continue }                  // skip dates
            // Strip leading "Name:" / "Company:" labels.
            let cleaned = trimmed.replacingOccurrences(
                of: #"(?i)^(name|company|consignee|shipper|receiver)\s*[:\-]\s*"#,
                with: "",
                options: .regularExpression
            )
            if cleaned.count >= 3 && cleaned.count <= 80 {
                companyName = cleaned.trimmedCompanySuffix
                break
            }
        }

        return AddrBlock(
            address: address,
            cityState: cityState,
            companyName: companyName,
            allText: blob
        )
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

        // Pass 1 — full dates with year.
        for pat in patternsWithYear {
            if let raw = firstRegex(text, pattern: pat) {
                let cleaned = raw.replacingOccurrences(of: ".", with: "")
                for fmt in formatStrings {
                    df.dateFormat = fmt
                    if let d = df.date(from: cleaned) { return d }
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
