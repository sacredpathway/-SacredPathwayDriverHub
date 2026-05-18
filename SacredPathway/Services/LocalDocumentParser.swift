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

/// Coarse document-type classification used to route to a strategy.
enum DocumentType: String {
    case rateCon   // rate confirmation
    case recon     // reconciliation / settlement / remittance
    case bol       // bill of lading
    case unknown
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

        // ---- Pass 0: vendor + document-type detection ----
        // Document type informs which extractor strategy to favor. Recon /
        // settlement statements have a completely different layout (per-load
        // rows with sequence #s, settlement IDs, paid amounts) than rate
        // confirmations, and need their own load# / amount logic.
        out.sourceVendor = detectVendor(in: joined)
        out.documentType = detectDocumentType(in: joined)

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
        if let m = firstRegex(joined, pattern: #"(?i)\b(?:load|order|trip|pro|shipment)[ \t]*(?:number|no\.?|num\.?|id|#)?[ \t]*[:#\-]?[ \t]*([A-Z0-9][A-Z0-9\-]{3,20})"#) {
            let v = m.cleanID
            // Reject column-header words — real IDs contain a digit.
            if v.contains(where: { $0.isNumber }) {
                out.loadNumber = v
                out.confidence["loadNumber"] = 0.85
            }
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

        // ---- Email ----
        if let m = firstRegex(joined, pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#) {
            out.brokerEmail = m.lowercased()
            out.confidence["brokerEmail"] = 0.95
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
        //
        // Two-pass strategy fixes the long-standing "rate stays blank" bug:
        //   Pass A — same-line label → value. Fast path for cleanly-formatted
        //            rate cons where "TOTAL RATE $1,850.00" lives on one line.
        //   Pass B — cross-line label → value. Critical for table layouts
        //            where the label is in one OCR cell and the dollar amount
        //            in the next ("TOTAL RATE\n$1,850.00"). Pass A's
        //            `[^\n]` window silently rejected those, leaving the rate
        //            blank on real CHR / Coyote / Convoy rate cons.
        // Strong tokens are unambiguous "this IS the total pay" labels and
        // run first. Weak tokens (line haul, carrier rate) often appear as
        // *line items* on a rate con and would otherwise win over the true
        // total when the doc lists linehaul above the total row.
        let strongTokens = #"(?:total\s*(?:rate|amount|pay)|all[-\s]?in(?:\s*rate)?|flat\s*rate|truck\s*pay|driver\s*pay|gross\s*pay|agreed\s*rate|rate\s*conf(?:irmation)?|\btotal\b)"#
        let weakTokens   = #"(?:line\s*haul|linehaul|carrier\s*(?:rate|pay))"#
        let amountCap = #"\$?\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]{3,6}(?:\.[0-9]{1,2})?)"#
        let ratePatterns = [
            // Pass A — strong-label same-line → amount within 40 chars.
            #"(?i)"# + strongTokens + #"[^\n$]{0,40}"# + amountCap,
            // Pass A1 — strong-label cross-line: label on one line, $amount
            // on the next. Critical for table OCR where the TOTAL RATE cell
            // and the dollar cell get split across lines.
            #"(?i)"# + strongTokens + #"[ \t]*[:=\-]?[ \t]*\r?\n[ \t]*\$[ \t]*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)"#,
            // Pass A2 — bare "Rate:" or "Rate =" on one line.
            #"(?i)\brate\s*[:=]\s*"# + amountCap,
            // Pass B — weak-label same-line. Only runs if no strong match.
            #"(?i)"# + weakTokens + #"[^\n$]{0,40}"# + amountCap,
            // Pass B1 — weak-label cross-line.
            #"(?i)"# + weakTokens + #"[ \t]*[:=\-]?[ \t]*\r?\n[ \t]*\$[ \t]*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)"#,
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
        // Fallback 1: largest dollar amount on the page (only if it's >= $200).
        if out.rate == nil {
            let amounts = allMatches(joined, pattern: #"\$\s*([0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]{1,2})?|[0-9]{3,6}(?:\.[0-9]{1,2})?)"#)
                .compactMap { Double($0.replacingOccurrences(of: ",", with: "")) }
                .filter { $0 >= 200 && $0 <= 50_000 }
            if let max = amounts.max() {
                out.rate = max
                out.confidence["rate"] = 0.45
            }
        }
        // Fallback 2: largest UNPREFIXED amount in a freight-realistic range
        // — rate cons sometimes OCR-strip the `$`. We only allow this when
        // the doc is a rate confirmation (avoids grabbing weights / miles).
        if out.rate == nil, out.documentType != .bol, out.documentType != .recon {
            let bareAmounts = allMatches(
                joined,
                pattern: #"\b([0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]{1,2})?|[1-9][0-9]{2,4}(?:\.[0-9]{1,2})?)\b"#
            )
            .compactMap { Double($0.replacingOccurrences(of: ",", with: "")) }
            // Floor of $300 reduces collision with miles/weight; ceiling of
            // $40K covers ~95% of single-leg dry-van runs.
            .filter { $0 >= 300 && $0 <= 40_000 }
            if let max = bareAmounts.max() {
                out.rate = max
                out.confidence["rate"] = 0.35
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
        // Same-line + digit-required for the same reasons as loadNumber.
        if let m = firstRegex(joined, pattern: #"(?i)\b(?:reference|ref)[ \t]*(?:number|num|no\.?|#)?[ \t]*[:#\-]?[ \t]*([A-Z0-9][A-Z0-9\-]{2,20})"#) {
            let v = m.cleanID
            if v.contains(where: { $0.isNumber }) {
                out.referenceNumber = v
                out.confidence["referenceNumber"] = 0.8
            }
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

        // ---- Final validation: load# vs reference# swap ----
        // If loadNumber is suspiciously short (<= 5 digits, pure numeric)
        // AND a longer freight-style identifier exists in the doc, the short
        // value is almost certainly a sequence/reference number and the
        // longer one is the true load. Promote the longer ID to loadNumber
        // and demote the short one into referenceNumber (Info field).
        validateLoadNumberAgainstAlternates(&out, joined: joined)

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
