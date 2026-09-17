import XCTest
#if canImport(SmartCore)
@testable import SmartCore
#else
@testable import SacredPathway
#endif

// =============================================================================
//  Smart document extraction — rate confirmations, receipts, maintenance
//  invoices, confidence, validation, duplicates and merge safety.
//  Pure text fixtures (see SmartFixtures); the Vision/PDF paths are covered by
//  SmartDocumentReaderTests in the app test target.
// =============================================================================

final class SmartRateConfirmationTests: XCTestCase {

    private func extract(_ text: String) -> SmartExtractionResult {
        SmartExtractionPipeline.run(DocumentText(text: text))
    }

    func testTextRateConfirmationFields() throws {
        let result = extract(SmartFixtures.textRateCon)
        XCTAssertEqual(result.kind, .rateConfirmation)
        XCTAssertEqual(result.classification.confidence, .high)
        let r = try XCTUnwrap(result.rateConfirmation)
        XCTAssertEqual(r.brokerName.value, "Summit Freight Brokerage, LLC")
        XCTAssertEqual(r.brokerContact.value, "Maria Lopez")
        XCTAssertEqual(r.brokerPhone.value, "(214) 555-0199")
        XCTAssertEqual(r.brokerPhoneExtension.value, "204")
        XCTAssertEqual(r.brokerEmail.value, "mlopez@summitfreight.com")
        XCTAssertEqual(r.brokerMC.value, "778812")
        XCTAssertEqual(r.loadNumber.value, "SFB-448812")
        XCTAssertEqual(r.loadNumber.confidence, .high)
        XCTAssertEqual(r.confirmationNumber.value, "99812")
        XCTAssertEqual(r.referenceNumber.value, "REF-55120")
        XCTAssertEqual(r.poNumber.value, "4500123321")
        XCTAssertEqual(r.pickupNumber.value, "PU77120")
        XCTAssertEqual(r.carrierName.value, "Example Carrier LLC")
        XCTAssertEqual(r.driverName.value, "Test Driver")
        XCTAssertEqual(r.truckNumber.value, "2580")
        XCTAssertEqual(r.trailerNumber.value, "TV530209")
        XCTAssertEqual(r.documentDate.value?.iso, "2026-09-15")

        XCTAssertEqual(r.stops.count, 2)
        let pu = try XCTUnwrap(r.firstPickup)
        XCTAssertEqual(pu.kind, .pickup)
        XCTAssertEqual(pu.facility.value, "Riverbend Paper Mill")
        XCTAssertEqual(pu.address.value, "1200 Industrial Pkwy")
        XCTAssertEqual(pu.city.value, "Memphis")
        XCTAssertEqual(pu.state.value, "TN")
        XCTAssertEqual(pu.zip.value, "38118")
        XCTAssertEqual(pu.date.value?.iso, "2026-09-17")
        XCTAssertEqual(pu.appointment.value, "08:00–10:00")
        let del = try XCTUnwrap(r.lastDelivery)
        XCTAssertEqual(del.facility.value, "Coastal Distribution Center")
        XCTAssertEqual(del.cityState, "Savannah, GA")
        XCTAssertEqual(del.zip.value, "31408")
        XCTAssertEqual(del.date.value?.iso, "2026-09-18")
        XCTAssertEqual(del.appointment.value, "14:00")

        XCTAssertEqual(r.commodity.value, "Paper Rolls")
        XCTAssertEqual(r.weightPounds.value, 42_500)
        XCTAssertEqual(r.miles.value, 682)
        XCTAssertEqual(r.linehaul.value, 2_600)
        XCTAssertEqual(r.fuelSurcharge.value, 250)
        XCTAssertEqual(r.totalRate.value, 2_850)
        XCTAssertEqual(r.totalRate.confidence, .high)
        // Conditional terms are shown but never counted as owed.
        XCTAssertEqual(r.tonu.confidence, .low)
        XCTAssertTrue(r.charges.contains { $0.kind == .tonu && $0.conditional })
        XCTAssertEqual(r.accessorialTotal, 0)
    }

    func testScannedRateConfirmation() throws {
        let result = extract(SmartFixtures.scannedRateCon)
        XCTAssertEqual(result.kind, .rateConfirmation)
        let r = try XCTUnwrap(result.rateConfirmation)
        XCTAssertEqual(r.loadNumber.value, "0527290")
        XCTAssertEqual(r.confirmationNumber.value, "9359302")
        XCTAssertNotEqual(r.loadNumber.value, r.confirmationNumber.value)
        XCTAssertEqual(r.brokerEmail.value, "skhan@ntlogistics.com")
        XCTAssertEqual(r.brokerContact.value, "Sahir Khan")
        XCTAssertNotNil(r.brokerName.value)
        XCTAssertFalse((r.brokerName.value ?? "").localizedCaseInsensitiveContains("carrier"))
        XCTAssertEqual(r.carrierName.value, "EXAMPLE CARRIER LLC")
        XCTAssertEqual(r.stops.count, 2)
        XCTAssertEqual(r.firstPickup?.cityState, "El Dorado, AR")
        XCTAssertEqual(r.firstPickup?.address.value, "105 W Sharp St")
        XCTAssertEqual(r.firstPickup?.date.value?.iso, "2026-06-03")
        XCTAssertEqual(r.lastDelivery?.cityState, "Lovell, WY")
        XCTAssertEqual(r.lastDelivery?.address.value, "789 Highway 14A East")
        XCTAssertEqual(r.lastDelivery?.date.value?.iso, "2026-06-05")
        XCTAssertEqual(r.lastDelivery?.kind, .delivery)
        XCTAssertEqual(r.commodity.value, "Bentonite Minerals on Pallets")
        XCTAssertEqual(r.weightPounds.value, 43_244)
        XCTAssertEqual(r.miles.value, 1_462)
        XCTAssertEqual(r.totalRate.value, 5_700)
        // The owner's own e-mail must never become the broker e-mail.
        XCTAssertFalse((r.brokerEmail.value ?? "").contains("example-carrier"))
        // PO # is blank on this document: do not copy the load number into it.
        XCTAssertNil(r.poNumber.value)
    }

    func testMultiPageRateConfirmationSkipsLegalPageAndMergesRepeatedStops() throws {
        let result = extract(SmartFixtures.multiPageRateCon)
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(result.kind, .rateConfirmation)
        let r = try XCTUnwrap(result.rateConfirmation)
        XCTAssertEqual(r.brokerName.value, "Great Plains Logistics Inc")
        XCTAssertEqual(r.loadNumber.value, "GPL-20931")
        XCTAssertEqual(r.stops.count, 2, "page 3 repeats the stops and must not add more")
        XCTAssertEqual(r.firstPickup?.facility.value, "Prairie Grain Co-op")
        XCTAssertEqual(r.firstPickup?.date.value?.iso, "2026-09-12")
        XCTAssertEqual(r.firstPickup?.appointment.value, "06:00–14:00")
        XCTAssertEqual(r.lastDelivery?.facility.value, "Front Range Foods")
        XCTAssertEqual(r.lastDelivery?.date.value?.iso, "2026-09-13")
        XCTAssertEqual(r.lumper.value, 75)
        XCTAssertEqual(r.totalRate.value, 1_735.50)
        // Legal text mentioning "$40.00 per hour" detention is not a charge.
        XCTAssertNil(r.detention.value)
        XCTAssertNil(r.carrierName.value)
        // Pickup is not the tender (document) date.
        XCTAssertEqual(r.documentDate.value?.iso, "2026-09-10")
        XCTAssertNotEqual(r.pickupDate.value, r.documentDate.value)
    }

    func testMultiStopLoadKeepsStopOrder() throws {
        let r = try XCTUnwrap(extract(SmartFixtures.multiStopRateCon).rateConfirmation)
        XCTAssertEqual(r.stops.map(\.kind), [.pickup, .pickup, .delivery, .delivery])
        XCTAssertEqual(r.stops.map { $0.cityState ?? "" }, ["Gary, IN", "Elkhart, IN", "Columbus, OH", "Dayton, OH"])
        XCTAssertEqual(r.stops.map { $0.date.value?.iso ?? "" }, ["2026-09-20", "2026-09-20", "2026-09-21", "2026-09-21"])
        XCTAssertEqual(r.stops.map { $0.appointment.value ?? "" }, ["07:00", "13:00", "06:00", "11:30"])
        XCTAssertEqual(r.stops[2].address.value, "9800 Logistics Way")
        XCTAssertNotEqual(r.stops[2].state.value, "DC", "facility name 'Midwest Retail DC' is not a city in DC")
        XCTAssertEqual(r.stopCount.value, 4)
        XCTAssertEqual(r.loadNumber.value, "LTS-7781")
        XCTAssertEqual(r.linehaul.value, 1_900)
        XCTAssertEqual(r.stopOff.value, 100)
        XCTAssertEqual(r.fuelSurcharge.value, 180)
        XCTAssertEqual(r.totalRate.value, 2_180)
        XCTAssertEqual(r.totalRate.confidence, .high)
        XCTAssertTrue(r.issues.filter { $0.field == "totalRate" }.isEmpty)
    }

    func testLowQualityScanDoesNotConfuseRateWithRatePerMileOrMiles() throws {
        let r = try XCTUnwrap(extract(SmartFixtures.lowQualityRateCon).rateConfirmation)
        XCTAssertEqual(r.totalRate.value, 650)
        XCTAssertNotEqual(r.totalRate.value, 3.10)
        XCTAssertEqual(r.miles.value, 64)
        XCTAssertEqual(r.loadNumber.value, "FW30912")
        XCTAssertEqual(r.firstPickup?.date.value?.iso, "2026-09-22")
        XCTAssertEqual(r.firstPickup?.appointment.value, "05:00")
        XCTAssertEqual(r.lastDelivery?.appointment.value, "16:00")
        XCTAssertEqual(r.lastDelivery?.cityState, "Bentonville, AR")
    }

    func testConfirmationNumberIsNotCopiedIntoLoadNumber() throws {
        let result = extract(SmartFixtures.confirmationOnlyRateCon)
        let r = try XCTUnwrap(result.rateConfirmation)
        XCTAssertEqual(r.confirmationNumber.value, "5521009")
        XCTAssertNil(r.loadNumber.value)
        XCTAssertEqual(r.brokerName.value, "Apex Brokerage Inc")
        XCTAssertEqual(r.documentDate.value?.iso, "2026-09-01")
        XCTAssertEqual(r.pickupDate.value?.iso, "2026-09-03")
        XCTAssertEqual(r.deliveryDate.value?.iso, "2026-09-04")
        XCTAssertEqual(r.firstPickup?.cityState, "Joliet, IL")
        XCTAssertEqual(r.lastDelivery?.cityState, "Toledo, OH")
        // A bare "Rate:" is a medium reading, not high.
        XCTAssertEqual(r.totalRate.value, 1_100)
        XCTAssertEqual(r.totalRate.confidence, .medium)
        let form = result.loadFormValues()
        XCTAssertNil(form["loadNumber"])
        XCTAssertEqual(form["referenceNumber"]?.value, "5521009")
        XCTAssertEqual(form["pickupDate"]?.value, "2026-09-03")
    }

    func testMissingFieldsAreReportedNotInvented() throws {
        let result = extract("""
            Rate Confirmation
            Carrier Rate Confirmation for load tender
            Pickup: Tulsa, OK
            Delivery: Wichita, KS
            Commodity: Tires
            """)
        let r = try XCTUnwrap(result.rateConfirmation)
        XCTAssertNil(r.totalRate.value)
        XCTAssertEqual(r.totalRate.confidence, .missing)
        XCTAssertNil(r.loadNumber.value)
        XCTAssertNil(r.pickupDate.value)
        XCTAssertTrue(result.issues.contains { $0.field == "totalRate" })
        XCTAssertTrue(result.issues.contains { $0.field == "loadNumber" })
        XCTAssertNil(result.loadFormValues()["rate"])
    }

    func testConflictingTotalsLowerConfidence() throws {
        let r = try XCTUnwrap(extract("""
            Rate Confirmation
            Load #: 55120
            Line Haul: $1,000.00
            Total Carrier Pay: $1,200.00
            Total Amount: $1,250.00
            """).rateConfirmation)
        XCTAssertEqual(r.totalRate.value, 1_200, "strongest label wins")
        XCTAssertLessThan(r.totalRate.confidence, .high)
        XCTAssertTrue(r.issues.contains { $0.message.contains("more than one total") })
    }

    func testReviewRowsFlagLowConfidence() {
        let result = extract(SmartFixtures.lowQualityRateCon)
        let rows = result.reviewFields
        XCTAssertTrue(rows.contains { $0.key == "totalRate" })
        XCTAssertTrue(rows.contains { $0.key.hasPrefix("stop1") })
        XCTAssertGreaterThan(result.attentionCount, 0)
    }
}

final class SmartReceiptTests: XCTestCase {

    private func run(_ text: String, kind: SmartDocumentKind? = nil) -> SmartExtractionResult {
        SmartExtractionPipeline.run(DocumentText(text: text), forcedKind: kind)
    }

    func testFuelReceiptWithDEF() throws {
        let result = run(SmartFixtures.lovesFuel)
        XCTAssertEqual(result.kind, .fuelReceipt)
        let r = try XCTUnwrap(result.receipt)
        let f = try XCTUnwrap(r.fuel)
        XCTAssertEqual(r.merchant.value, "Love's")
        XCTAssertEqual(r.storeNumber.value, "356")
        XCTAssertEqual(r.street.value, "2501 S Grand St")
        XCTAssertEqual(r.city.value, "Amarillo")
        XCTAssertEqual(r.state.value, "TX")
        XCTAssertEqual(r.zip.value, "79103")
        XCTAssertEqual(r.date.value?.iso, "2026-06-10")
        XCTAssertEqual(r.time.value, "14:32")
        XCTAssertEqual(r.receiptNumber.value, "88213")
        XCTAssertEqual(f.fuelType.value, "Diesel")
        XCTAssertEqual(f.gallons.value ?? 0, 125.482, accuracy: 0.0001)
        XCTAssertEqual(f.pricePerGallon.value ?? 0, 3.899, accuracy: 0.0001)
        XCTAssertEqual(f.fuelAmount.value, 489.25)
        XCTAssertEqual(f.defGallons.value ?? 0, 4.25, accuracy: 0.0001)
        XCTAssertEqual(f.defPricePerGallon.value ?? 0, 2.799, accuracy: 0.0001)
        XCTAssertEqual(f.defAmount.value, 11.90)
        XCTAssertEqual(f.truckNumber.value, "2580")
        XCTAssertEqual(f.odometer.value, 412_330)
        XCTAssertEqual(f.pump.value, "07")
        XCTAssertEqual(r.subtotal.value, 501.15)
        XCTAssertEqual(r.tax.value, 0)
        XCTAssertEqual(r.total.value, 501.15)
        XCTAssertEqual(r.total.confidence, .high)
        XCTAssertEqual(r.paymentMethod.value, "Visa")
        XCTAssertEqual(r.cardLastFour.value, "1234")
        XCTAssertEqual(r.suggestedCategory.value, "fuel")
        // Authorization number is never the total.
        XCTAssertNotEqual(r.total.value, 4521)
        XCTAssertTrue(r.issues.filter { $0.severity == .warning }.isEmpty, "\(r.issues)")

        let form = result.expenseFormValues()
        XCTAssertEqual(form["amount"]?.value, "501.15")
        XCTAssertEqual(form["gallons"]?.value, "125.482")
        XCTAssertEqual(form["pricePerGallon"]?.value, "3.899")
        XCTAssertEqual(form["defGallons"]?.value, "4.250")
        XCTAssertEqual(form["defPricePerGallon"]?.value, "2.799")
        XCTAssertEqual(form["category"]?.value, "fuel")
        XCTAssertEqual(form["receiptDate"]?.value, "2026-06-10")
    }

    func testMessyFuelReceiptKeepsRewardsOutOfTotal() throws {
        let r = try XCTUnwrap(run(SmartFixtures.messyPilotFuel).receipt)
        XCTAssertEqual(r.merchant.value, "Pilot")
        XCTAssertEqual(r.total.value, 371.01)
        XCTAssertEqual(r.fuel?.gallons.value ?? 0, 98.7, accuracy: 0.001)
        XCTAssertEqual(r.fuel?.pricePerGallon.value ?? 0, 3.759, accuracy: 0.0001)
        XCTAssertNil(r.date.value, "no date is printed; none may be invented")
    }

    func testFleetCardTableReceipt() throws {
        let result = run(SmartFixtures.fleetCardFuel)
        let r = try XCTUnwrap(result.receipt)
        let f = try XCTUnwrap(r.fuel)
        XCTAssertEqual(r.merchant.value, "Flying J")
        XCTAssertEqual(r.receiptNumber.value, "0714-55213")
        XCTAssertEqual(r.date.value?.iso, "2026-09-14")
        XCTAssertEqual(r.time.value, "22:17")
        XCTAssertEqual(f.gallons.value ?? 0, 142.31, accuracy: 0.001)
        XCTAssertEqual(f.pricePerGallon.value ?? 0, 4.019, accuracy: 0.0001)
        XCTAssertEqual(f.fuelAmount.value, 571.94)
        XCTAssertEqual(f.defAmount.value, 21.44)
        XCTAssertEqual(f.truckNumber.value, "12")
        XCTAssertEqual(f.driver.value, "4471")
        XCTAssertEqual(f.odometer.value, 381_244)
        XCTAssertEqual(r.total.value, 593.38)
        XCTAssertEqual(r.paymentMethod.value, "Comdata")
        XCTAssertEqual(r.cardLastFour.value, "4421")
        // The auth code (776120) and gallons are never the total.
        XCTAssertNotEqual(r.total.value, 776_120)
        XCTAssertNotEqual(r.total.value, 142.31)
        // Full card digits never survive into stored text.
        XCTAssertFalse(result.document.joined.contains("************4421") && result.document.joined.contains("0000"))
    }

    func testGeneralReceiptLineItemsDiscountAndTax() throws {
        let result = run(SmartFixtures.generalReceipt)
        XCTAssertEqual(result.kind, .generalReceipt)
        let r = try XCTUnwrap(result.receipt)
        XCTAssertEqual(r.merchant.value, "TRUCK STOP SUPPLY CO")
        XCTAssertEqual(r.receiptNumber.value, "118-99021")
        XCTAssertEqual(r.date.value?.iso, "2026-09-16")
        XCTAssertEqual(r.time.value, "15:41")
        XCTAssertEqual(r.subtotal.value, 57.46)
        XCTAssertEqual(r.tax.value, 4.74)
        XCTAssertEqual(r.discount.value, 3.00)
        XCTAssertEqual(r.total.value, 62.20)
        XCTAssertEqual(r.total.confidence, .high)
        XCTAssertEqual(r.lineItems.count, 4)
        XCTAssertEqual(r.lineItems[0].description, "Ratchet Strap 2in x 27ft")
        XCTAssertEqual(r.lineItems[0].quantity, 2)
        XCTAssertEqual(r.lineItems[0].unitPrice, 18.99)
        XCTAssertEqual(r.lineItems[0].amount, 37.98)
        XCTAssertEqual(r.lineItems.last?.kind, .discount)
        XCTAssertEqual(r.lineItems.compactMap(\.amount).reduce(0, +), 57.46, accuracy: 0.001)
        // Change due (0.00) and the rewards number are not totals.
        XCTAssertNotEqual(r.total.value, 0)
        XCTAssertEqual(r.paymentMethod.value, "Mastercard")
        XCTAssertEqual(r.cardLastFour.value, "8812")
        XCTAssertNil(r.fuel)
        XCTAssertEqual(r.suggestedCategory.value, "other")
        XCTAssertTrue(r.suggestedCategory.confidence.needsAttention)
    }

    func testTollReceiptSuggestsTollCategory() throws {
        let result = run(SmartFixtures.tollReceipt)
        XCTAssertEqual(result.kind, .generalReceipt)
        let r = try XCTUnwrap(result.receipt)
        XCTAssertEqual(r.merchant.value, "Oklahoma Turnpike Authority")
        XCTAssertEqual(r.total.value, 24.50)
        XCTAssertEqual(r.suggestedCategory.value, "toll")
        XCTAssertEqual(r.date.value?.iso, "2026-09-11")
    }

    func testAmbiguousDocumentAsksForType() {
        let result = run(SmartFixtures.ambiguousReceipt)
        XCTAssertEqual(result.kind, .unknown)
        XCTAssertTrue(result.needsKindChoice)
        XCTAssertNil(result.receipt)
        XCTAssertTrue(result.expenseFormValues().isEmpty, "nothing is guessed before the user picks a type")
        // After the user picks a type, amounts stay low-confidence.
        let chosen = SmartExtractionPipeline.rerun(result, as: .generalReceipt, unmaskedDocument: DocumentText(text: SmartFixtures.ambiguousReceipt))
        XCTAssertEqual(chosen.kind, .generalReceipt)
        XCTAssertTrue(chosen.kindChosenByUser)
        XCTAssertFalse(chosen.needsKindChoice)
        let total = chosen.receipt?.total
        XCTAssertTrue(total?.value == nil || total!.confidence <= .low)
        XCTAssertTrue(chosen.issues.contains { $0.field == "total" })
    }

    func testMathMismatchLowersConfidence() throws {
        let r = try XCTUnwrap(run("""
            PILOT TRAVEL CENTER #88
            DIESEL 100.000 GAL @ $4.000 $425.00
            TOTAL $425.00
            """).receipt)
        let f = try XCTUnwrap(r.fuel)
        XCTAssertLessThan(f.gallons.confidence, .high)
        XCTAssertTrue(r.issues.contains { $0.field == "gallons" && $0.message.contains("does not match") })
        // The printed total is kept, never recalculated.
        XCTAssertEqual(r.total.value, 425)
    }

    func testSubtotalTaxMismatchIsFlagged() throws {
        let r = try XCTUnwrap(run("""
            Corner Hardware
            09/02/2026
            Tape 4.99
            Subtotal 4.99
            Tax 0.41
            Total 9.40
            Visa 9.40
            """, kind: .generalReceipt).receipt)
        XCTAssertEqual(r.total.value, 9.40)
        XCTAssertLessThan(r.total.confidence, .high)
        XCTAssertTrue(r.issues.contains { $0.field == "total" })
    }
}

final class SmartMaintenanceTests: XCTestCase {

    private func run(_ text: String) -> SmartExtractionResult {
        SmartExtractionPipeline.run(DocumentText(text: text))
    }

    func testMultiPageRepairInvoiceWithPartsAndLabor() throws {
        let result = run(SmartFixtures.maintenanceInvoice)
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertTrue(result.kind.isMaintenance)
        let m = try XCTUnwrap(result.maintenance)
        XCTAssertEqual(m.shopName.value, "Rush Truck Centers - Oklahoma City")
        XCTAssertEqual(m.shopAddress.value, "8700 W Reno Ave")
        XCTAssertEqual(m.shopCity.value, "Oklahoma City")
        XCTAssertEqual(m.shopState.value, "OK")
        XCTAssertEqual(m.shopZip.value, "73127")
        XCTAssertEqual(m.shopPhone.value, "(405) 555-0177")
        XCTAssertEqual(m.invoiceNumber.value, "7718821")
        XCTAssertEqual(m.repairOrderNumber.value, "RO-55102")
        XCTAssertEqual(m.invoiceDate.value?.iso, "2026-09-12")
        XCTAssertEqual(m.serviceDate.value?.iso, "2026-09-11")
        XCTAssertEqual(m.unitNumber.value, "2580")
        XCTAssertEqual(m.vin.value, "1FUJHHDR0CLBP8834")
        XCTAssertEqual(m.licensePlate.value, "AL 1234ABC")
        XCTAssertEqual(m.odometer.value, 412_105)
        XCTAssertEqual(m.engineHours.value, 18_220)
        XCTAssertEqual(m.technician.value, "J. Alvarez")
        XCTAssertEqual(m.category.value, .pmService)
        XCTAssertEqual(m.expenseCategory, "maintenance")

        XCTAssertEqual(m.parts.count, 4)
        XCTAssertEqual(m.parts.map { $0.partNumber ?? "" }, ["DF-12345", "LF-9001", "15W40-B", "VCG-2231"])
        XCTAssertEqual(m.parts[0].description, "Fuel Filter")
        XCTAssertEqual(m.parts[0].quantity, 2)
        XCTAssertEqual(m.parts[0].unitPrice, 38.50)
        XCTAssertEqual(m.parts[0].amount, 77.00)
        XCTAssertTrue(m.parts.allSatisfy { $0.confidence == .high })

        XCTAssertEqual(m.labor.count, 2, "labor on page 2 is kept as separate lines")
        XCTAssertEqual(m.labor[0].hours, 1.5)
        XCTAssertEqual(m.labor[0].rate, 145)
        XCTAssertEqual(m.labor[0].amount, 217.50)
        XCTAssertEqual(m.labor[1].description, "Replace valve cover gasket")
        XCTAssertEqual(m.laborHours.value, 3.5)
        XCTAssertEqual(m.laborRate.value, 145)
        XCTAssertEqual(m.laborTotal.value, 507.50)

        XCTAssertEqual(m.partsSubtotal.value, 366.14)
        XCTAssertEqual(m.shopSupplies.value, 25)
        XCTAssertEqual(m.environmentalFees.value, 12.50)
        XCTAssertEqual(m.subtotal.value, 911.14)
        XCTAssertEqual(m.tax.value, 30.21)
        XCTAssertEqual(m.total.value, 941.35)
        XCTAssertEqual(m.total.confidence, .high)
        XCTAssertEqual(m.nextServiceMileage.value, 437_000)
        XCTAssertTrue(m.recommendations.contains { $0.contains("brake shoes") })
        XCTAssertFalse(m.recommendations.contains { $0.hasPrefix("Complaint") })
        XCTAssertTrue(m.workPerformed.contains("PM Service - Level A"))
        XCTAssertTrue(m.issues.filter { $0.severity == .warning }.isEmpty, "\(m.issues)")

        let form = result.expenseFormValues()
        XCTAssertEqual(form["amount"]?.value, "941.35")
        XCTAssertEqual(form["receiptDate"]?.value, "2026-09-11")
        XCTAssertEqual(form["category"]?.value, "maintenance")
        XCTAssertTrue(form["description"]?.value.contains("Unit 2580") ?? false)
    }

    func testTireInvoiceLineItems() throws {
        let result = run(SmartFixtures.tireInvoice)
        XCTAssertTrue(result.kind.isMaintenance)
        let m = try XCTUnwrap(result.maintenance)
        XCTAssertEqual(m.category.value, .tires)
        XCTAssertEqual(m.invoiceNumber.value, "44-120983")
        XCTAssertEqual(m.invoiceDate.value?.iso, "2026-09-05")
        XCTAssertEqual(m.unitNumber.value, "2580")
        XCTAssertEqual(m.odometer.value, 409_880)
        XCTAssertEqual(m.parts.first?.description, "295/75R22.5 Drive Tire")
        XCTAssertEqual(m.parts.first?.quantity, 2)
        XCTAssertEqual(m.parts.first?.unitPrice, 389)
        XCTAssertEqual(m.parts.first?.amount, 778)
        XCTAssertEqual(m.environmentalFees.value, 5)
        XCTAssertEqual(m.subtotal.value, 833)
        XCTAssertEqual(m.total.value, 866.32)
        XCTAssertEqual(m.expenseCategory, "maintenance")
    }

    func testRoadsideRepair() throws {
        let result = run(SmartFixtures.roadsideRepair)
        let m = try XCTUnwrap(result.maintenance)
        XCTAssertEqual(m.category.value, .roadsideRepair)
        XCTAssertEqual(m.expenseCategory, "repair")
        XCTAssertEqual(m.repairOrderNumber.value, "30177")
        XCTAssertEqual(m.serviceDate.value?.iso, "2026-09-08")
        XCTAssertEqual(m.labor.first?.hours, 1)
        XCTAssertEqual(m.labor.first?.rate, 165)
        XCTAssertEqual(m.otherFees.value, 150)
        XCTAssertEqual(m.parts.first?.description, "Air line fittings")
        XCTAssertEqual(m.total.value, 357.75)
        XCTAssertEqual(m.total.confidence, .high)
    }

    func testPartsReceipt() throws {
        let result = run(SmartFixtures.partsReceipt)
        XCTAssertEqual(result.kind, .partsReceipt)
        let m = try XCTUnwrap(result.maintenance)
        XCTAssertEqual(m.shopName.value, "FleetPride #212")
        XCTAssertEqual(m.invoiceNumber.value, "212-778120")
        XCTAssertEqual(m.parts.count, 2)
        XCTAssertEqual(m.parts[1].partNumber, "BW-8810")
        XCTAssertEqual(m.parts[1].quantity, 2)
        XCTAssertEqual(m.parts[1].amount, 84.30)
        XCTAssertEqual(m.labor.count, 0)
        XCTAssertEqual(m.category.value, .brakes)
        XCTAssertEqual(m.total.value, 154.47)
    }

    func testUnreliableLineItemsKeepReliableTotal() throws {
        let m = try XCTUnwrap(SmartExtractionPipeline.run(DocumentText(text: """
            Main Street Diesel Repair
            Repair Order # 4471
            Date: 09/03/2026
            Labor
            Diagnose no start 2.0 hr x $120.00 $300.00
            Parts
            St@rter m0tor ??? 41 2 $612.00
            Parts Total $412.00
            Labor Total $300.00
            Invoice Total $712.00
            """), forcedKind: .repairOrder).maintenance)
        XCTAssertEqual(m.total.value, 712)
        XCTAssertEqual(m.labor.first?.confidence, .low, "2 × 120 ≠ 300")
        XCTAssertLessThan(m.parts.first?.confidence ?? .high, .high)
        XCTAssertTrue(m.issues.contains { $0.field == "parts" })
        XCTAssertTrue(m.issues.contains { $0.field == "labor" })
    }

    func testVINCheckDigit() {
        XCTAssertTrue(MaintenanceExtractor.isValidVIN("1M8GDM9AXKP042788"))
        XCTAssertFalse(MaintenanceExtractor.isValidVIN("1M8GDM9A1KP042788"))
        XCTAssertFalse(MaintenanceExtractor.isValidVIN("1M8GDM9AXKP04278"))
        XCTAssertFalse(MaintenanceExtractor.isValidVIN("IM8GDM9AXKP042788"), "I/O/Q never appear in a VIN")
    }

    func testCategoryKeywords() {
        func category(_ s: String) -> MaintenanceCategory? {
            SmartExtractionPipeline.run(DocumentText(text: "Shop Invoice\nLabor\n" + s + " 1.0 hr x $100.00 $100.00\nTotal $100.00"),
                                        forcedKind: .maintenanceInvoice).maintenance?.category.value
        }
        XCTAssertEqual(category("Tow truck to shop 40 miles"), .towing)
        XCTAssertEqual(category("DPF regen and clean"), .dpfEmissions)
        XCTAssertEqual(category("Replace DEF pump"), .defSystem)
        XCTAssertEqual(category("Annual DOT inspection"), .dotInspection)
        XCTAssertEqual(category("Front end alignment"), .alignment)
        XCTAssertEqual(category("Replace radiator and coolant flush"), .coolingSystem)
        XCTAssertEqual(category("A/C compressor recharge"), .hvac)
        XCTAssertEqual(category("Replace batteries"), .battery)
        XCTAssertEqual(category("Trailer landing gear repair"), .trailerRepair)
    }
}
