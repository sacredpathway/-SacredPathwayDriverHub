import XCTest
#if canImport(SmartCore)
@testable import SmartCore
#else
@testable import SacredPathway
#endif

final class SmartTextFormatTests: XCTestCase {

    func testCurrencyFormats() {
        XCTAssertEqual(SmartText.moneyTokens(in: "Rate: $2,850.00").map(\.value), [2850])
        XCTAssertEqual(SmartText.moneyTokens(in: "Invoice Total ........ $1,247.36").map(\.value), [1247.36])
        XCTAssertEqual(SmartText.moneyTokens(in: "TOTAL 62.20").map(\.value), [62.20])
        XCTAssertEqual(SmartText.moneyTokens(in: "Total $ 1,000").map(\.value), [1000])
        XCTAssertEqual(SmartText.moneyTokens(in: "USD 950.00").map(\.value), [950])
        XCTAssertEqual(SmartText.moneyTokens(in: "Discount (3.00)").map(\.value), [-3])
        XCTAssertEqual(SmartText.moneyTokens(in: "Coupon 3.00-").map(\.value), [-3])
        XCTAssertEqual(SmartText.moneyTokens(in: "Carrier Rate S650.00").map(\.value), [650], "OCR 'S' for '$'")
        XCTAssertEqual(SmartText.parseMoney("2850"), 2850)
    }

    func testNonMoneyNumbersAreRejected() {
        XCTAssertTrue(SmartText.moneyTokens(in: "Date 09/17/2026").isEmpty)
        XCTAssertTrue(SmartText.moneyTokens(in: "Phone 469-362-5040").isEmpty)
        XCTAssertTrue(SmartText.moneyTokens(in: "Pickup 08:00").isEmpty)
        XCTAssertTrue(SmartText.moneyTokens(in: "Sales Tax 8.25%").isEmpty)
        XCTAssertTrue(SmartText.moneyTokens(in: "Rate $3.10/mi").isEmpty)
        XCTAssertTrue(SmartText.moneyTokens(in: "125.482 GAL").isEmpty)
        XCTAssertTrue(SmartText.moneyTokens(in: "Weight 42500").isEmpty)
        XCTAssertTrue(SmartText.moneyTokens(in: "Miles 682.00 mi").isEmpty)
        XCTAssertTrue(SmartText.moneyTokens(in: "AUTH 004521").isEmpty)
    }

    func testSeveralAmountsOnOneLine() {
        let tokens = SmartText.moneyTokens(in: "Line Haul 1 x $2,500.00 = $2,500.00   FSC $250.00")
        XCTAssertEqual(tokens.map(\.value), [2500, 2500, 250])
    }

    func testDateFormats() {
        func iso(_ s: String) -> String? { SmartText.firstDate(in: s)?.date.iso }
        XCTAssertEqual(iso("Pickup Date: 09/17/2026"), "2026-09-17")
        XCTAssertEqual(iso("9/7/26"), "2026-09-07")
        XCTAssertEqual(iso("09-17-2026 0700"), "2026-09-17")
        XCTAssertEqual(iso("09.17.2026"), "2026-09-17")
        XCTAssertEqual(iso("2026-09-17T08:00"), "2026-09-17")
        XCTAssertEqual(iso("Sep 17, 2026"), "2026-09-17")
        XCTAssertEqual(iso("September 17th 2026"), "2026-09-17")
        XCTAssertEqual(iso("17-Sep-2026"), "2026-09-17")
        XCTAssertEqual(iso("17 SEPT 26"), "2026-09-17")
        XCTAssertNil(iso("02/30/2026"), "impossible dates are rejected")
        XCTAssertNil(iso("Load 1234/5678"))
        let dayFirst = SmartText.firstDate(in: "17/09/2026")
        XCTAssertEqual(dayFirst?.date.iso, "2026-09-17")
        XCTAssertEqual(dayFirst?.ambiguous, true)
    }

    func testMultipleDatesOnOneLine() {
        let dates = SmartText.dateTokens(in: "Ready 09/12/2026 0600  Deliver by Sep 13, 2026")
        XCTAssertEqual(dates.map(\.date.iso), ["2026-09-12", "2026-09-13"])
    }

    func testSeveralDatesOnReceiptLowerConfidence() throws {
        let r = try XCTUnwrap(SmartExtractionPipeline.run(DocumentText(text: """
            Hilltop Auto Parts
            09/01/2026
            Wiper Blades 24.99
            Total 24.99
            Return by 10/01/2026
            Member since 01/05/2020
            """), forcedKind: .generalReceipt).receipt)
        XCTAssertEqual(r.date.value?.iso, "2026-09-01")
        XCTAssertEqual(r.date.confidence, .low)
        XCTAssertTrue(r.issues.contains { $0.field == "date" })
    }

    func testTimesAndAppointments() {
        XCTAssertEqual(SmartText.appointment(in: "8:00 AM - 3:00 PM"), "08:00–15:00")
        XCTAssertEqual(SmartText.appointment(in: "Appt 0700-1500"), "07:00–15:00")
        XCTAssertEqual(SmartText.appointment(in: "FCFS"), "FCFS")
        XCTAssertNil(SmartText.appointment(in: "Load 0700"), "4-digit numbers need an appointment context")
    }

    func testPhoneEmailAddressWeight() {
        XCTAssertEqual(SmartText.phone(in: "Phone: 469.362.5040 x 12")?.number, "(469) 362-5040")
        XCTAssertEqual(SmartText.phone(in: "Phone: 469.362.5040 x 12")?.ext, "12")
        XCTAssertEqual(SmartText.phone(in: "+1 (800) 555-0142")?.number, "(800) 555-0142")
        XCTAssertEqual(SmartText.email(in: "Email: Ops@Broker.COM"), "ops@broker.com")
        XCTAssertEqual(SmartText.cityStateZip(in: "LOVELL WY 82431"), CityStateZip(city: "Lovell", state: "WY", zip: "82431"))
        XCTAssertEqual(SmartText.cityStateZip(in: "Oklahoma City, OK 73127-4410")?.zip, "73127")
        XCTAssertEqual(SmartText.cityStateZip(in: "Dallas, Texas")?.state, "TX")
        XCTAssertNil(SmartText.cityStateZip(in: "Weight: 42,000 LB"))
        XCTAssertTrue(SmartText.isStreetAddress("105 W Sharp St"))
        XCTAssertTrue(SmartText.isStreetAddress("PO Box 4471"))
        XCTAssertFalse(SmartText.isStreetAddress("2 295/75R22.5 Drive Tire 389.00 778.00"))
        XCTAssertEqual(SmartText.weightPounds(in: "43,244 lbs"), 43_244)
        XCTAssertEqual(SmartText.weightPounds(in: "20000 KG"), 44_092)
    }

    func testCardNumbersAreMaskedAndOnlyLastFourKept() {
        let masked = SmartText.maskCardNumbers("VISA 4111 1111 1111 1234 APPROVED")
        XCTAssertFalse(masked.contains("4111"))
        XCTAssertTrue(masked.contains("1234"))
        XCTAssertEqual(SmartText.cardLastFour(in: "VISA 4111111111111234"), "1234")
        XCTAssertEqual(SmartText.cardLastFour(in: "Mastercard ************8812"), "8812")
        XCTAssertEqual(SmartText.cardLastFour(in: "DEBIT XXXX XXXX XXXX 9901"), "9901")
        XCTAssertNil(SmartText.cardLastFour(in: "Receipt 118-99021"))
        let v = ExtractedValue<String>("x", .high, raw: "Card 4111111111111234")
        XCTAssertFalse(v.rawText?.contains("41111111") ?? true)
        // Stored document text is masked too.
        let result = SmartExtractionPipeline.run(DocumentText(text: "Shell\nDiesel 10.000 gal @ 4.000 40.00\nTotal 40.00\nVISA 4111111111111234"))
        XCTAssertFalse(result.document.joined.contains("4111111111111234"))
    }

    func testLabelValueAcrossLayouts() {
        let lines = DocumentText(text: """
            Invoice Total ........ $1,247.36
            Load #: 12345   PO #: 998877
            Pickup Date:
            09/17/2026
            the carrier will be charged a fee
            """).lines
        XCTAssertEqual(SmartText.firstLabeled(["invoice total"], in: lines)?.value, "$1,247.36")
        XCTAssertEqual(SmartText.firstLabeled(["load #"], in: lines, stopLabels: ["po #"])?.value, "12345")
        XCTAssertEqual(SmartText.firstLabeled(["po #"], in: lines)?.value, "998877")
        let date = SmartText.firstLabeled(["pickup date"], in: lines)
        XCTAssertEqual(date?.value, "09/17/2026")
        XCTAssertEqual(date?.sameLine, false)
        XCTAssertNil(SmartText.firstLabeled(["carrier"], in: lines), "a sentence is not a label")
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(DocumentFingerprint.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(DocumentFingerprint.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(DocumentFingerprint.sha256Hex(Data(String(repeating: "a", count: 1000).utf8)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
        XCTAssertEqual(DocumentFingerprint.textFingerprint("Total 12.00"), DocumentFingerprint.textFingerprint("  total  12.00 "))
    }
}

final class SmartDuplicateAndMergeTests: XCTestCase {

    private func probe(_ id: String, party: String?, date: String?, number: String?, amount: Double?,
                       fingerprint: String? = nil, kind: SmartDocumentKind = .fuelReceipt) -> DuplicateProbe {
        let d = date.flatMap { SmartText.firstDate(in: $0)?.date }
        return DuplicateProbe(recordID: id, recordType: .expense, kind: kind, party: party, date: d,
                              number: number, amount: amount, fingerprint: fingerprint, title: id)
    }

    func testSameFileIsLikelyDuplicate() {
        let a = probe("new", party: nil, date: nil, number: nil, amount: nil, fingerprint: "abc")
        let b = probe("old", party: "Pilot", date: "01/01/2026", number: nil, amount: 10, fingerprint: "abc")
        XCTAssertEqual(DuplicateDetector.findMatches(for: a, in: [b]).first?.level, .likely)
    }

    func testSameVendorDateAndAmountIsLikely() {
        let a = probe("new", party: "Love's Travel Stop #356", date: "06/10/2026", number: "88213", amount: 501.15)
        let b = probe("old", party: "Love's", date: "06/10/2026", number: nil, amount: 501.15)
        let m = DuplicateDetector.findMatches(for: a, in: [b])
        XCTAssertEqual(m.first?.level, .likely)
        XCTAssertTrue(m.first?.reasons.contains("Same date") ?? false)
    }

    func testSameReceiptNumberIsFlagged() {
        let a = probe("new", party: "Flying J", date: "09/14/2026", number: "0714-55213", amount: 593.38)
        let b = probe("old", party: "Flying J #714", date: "09/14/2026", number: "071455213", amount: 593.38)
        XCTAssertEqual(DuplicateDetector.findMatches(for: a, in: [b]).first?.level, .likely)
    }

    func testMatchingAmountAloneIsNotADuplicate() {
        let a = probe("new", party: "Capstone Lumper", date: "09/01/2026", number: nil, amount: 50)
        let others = [
            probe("x1", party: "Other Vendor", date: "09/15/2026", number: nil, amount: 50),
            probe("x2", party: nil, date: nil, number: nil, amount: 50),
            probe("x3", party: "Capstone Lumper", date: "09/20/2026", number: nil, amount: 50)
        ]
        XCTAssertTrue(DuplicateDetector.findMatches(for: a, in: others).isEmpty)
    }

    func testLoadDuplicateByLoadNumber() {
        let result = SmartExtractionPipeline.run(DocumentText(text: SmartFixtures.textRateCon), existingRecords: [
            DuplicateProbe(recordID: "L1", recordType: .load, kind: .rateConfirmation, party: "Summit Freight",
                           date: SimpleDate(year: 2026, month: 9, day: 17), number: "SFB-448812", amount: 2850, title: "Load SFB-448812"),
            DuplicateProbe(recordID: "L2", recordType: .load, kind: .rateConfirmation, party: "Other Broker",
                           date: SimpleDate(year: 2026, month: 3, day: 1), number: "77", amount: 2850, title: "Load 77")
        ])
        XCTAssertEqual(result.duplicates.map(\.recordID), ["L1"])
        XCTAssertTrue(result.issues.first?.field == "duplicate")
    }

    func testRescanningSameDocumentIsDetected() {
        let doc = DocumentText(text: SmartFixtures.maintenanceInvoice)
        let first = SmartExtractionPipeline.run(doc)
        let saved = first.duplicateProbe(recordID: "E1")
        let second = SmartExtractionPipeline.run(doc, existingRecords: [saved])
        XCTAssertEqual(second.duplicates.first?.recordID, "E1")
        XCTAssertEqual(second.duplicates.first?.level, .likely)
    }

    // MARK: Merge safety

    func testExtractionNeverOverwritesUserEnteredValues() {
        let suggestions: [String: FormSuggestion] = [
            "amount": FormSuggestion(value: "501.15", confidence: .high),
            "vendorName": FormSuggestion(value: "Love's", confidence: .high),
            "gallons": FormSuggestion(value: "125.482", confidence: .high),
            "description": FormSuggestion(value: "Diesel", confidence: .medium)
        ]
        let current: [String: FormFieldState] = [
            "amount": FormFieldState(value: "510.00", userEdited: true),
            "vendorName": FormFieldState(value: "", userEdited: false),
            "gallons": FormFieldState(value: "125.482", userEdited: true),
            "description": FormFieldState(value: "Fuel + snacks", userEdited: true)
        ]
        let outcome = ExtractionMergePolicy.merge(suggestions: suggestions, into: current)
        XCTAssertNil(outcome.applied["amount"], "user-entered amount must stay")
        XCTAssertEqual(outcome.applied["vendorName"]?.value, "Love's")
        XCTAssertEqual(outcome.unchanged, ["gallons"])
        XCTAssertEqual(Set(outcome.conflicts.map(\.key)), ["amount", "description"])
        XCTAssertEqual(outcome.conflicts.first { $0.key == "amount" }?.currentValue, "510.00")
    }

    func testAutoFilledValueOnlyReplacedByStrongerReading() {
        let current = ["amount": FormFieldState(value: "12.00", userEdited: false, autoConfidence: .low),
                       "vendorName": FormFieldState(value: "Pilot", userEdited: false, autoConfidence: .high)]
        let outcome = ExtractionMergePolicy.merge(suggestions: [
            "amount": FormSuggestion(value: "120.00", confidence: .high),
            "vendorName": FormSuggestion(value: "Pilot Flying J", confidence: .medium)
        ], into: current)
        XCTAssertEqual(outcome.applied["amount"]?.value, "120.00")
        XCTAssertNil(outcome.applied["vendorName"])
        XCTAssertEqual(outcome.conflicts.map(\.key), ["vendorName"])
    }

    func testMissingAndEmptySuggestionsAreIgnored() {
        let outcome = ExtractionMergePolicy.merge(suggestions: [
            "amount": FormSuggestion(value: "", confidence: .high),
            "gallons": FormSuggestion(value: "10", confidence: .missing)
        ], into: [:])
        XCTAssertTrue(outcome.applied.isEmpty)
        XCTAssertEqual(Set(outcome.skipped), ["amount", "gallons"])
    }

    func testIncorrectExtractionDoesNotReplaceUserEditedLoadForm() {
        // A rate con where the scan reads the wrong rate; the user already typed the right one.
        let result = SmartExtractionPipeline.run(DocumentText(text: SmartFixtures.lowQualityRateCon))
        let suggestions = result.loadFormValues()
        XCTAssertEqual(suggestions["rate"]?.value, "650.00")
        let outcome = ExtractionMergePolicy.merge(suggestions: suggestions, into: [
            "rate": FormFieldState(value: "700.00", userEdited: true),
            "loadNumber": FormFieldState(value: "", userEdited: false)
        ])
        XCTAssertNil(outcome.applied["rate"])
        XCTAssertEqual(outcome.applied["loadNumber"]?.value, "FW30912")
        XCTAssertTrue(outcome.conflicts.contains { $0.key == "rate" && $0.currentValue == "700.00" })
    }

    func testResultRoundTripsThroughJSON() throws {
        let result = SmartExtractionPipeline.run(DocumentText(text: SmartFixtures.maintenanceInvoice))
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SmartExtractionResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }
}
