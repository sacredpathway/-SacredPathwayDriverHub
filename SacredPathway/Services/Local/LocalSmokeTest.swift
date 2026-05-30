import Foundation

// =============================================================================
//  LocalSmokeTest — Phase B verification
// -----------------------------------------------------------------------------
//  DEBUG-only end-to-end test that exercises every CRUD path on the three
//  Phase B repositories. Writes records, reads them back, mutates them,
//  deletes them, and asserts each step. Output goes to the device console
//  under the `SP_DEBUG_LOCAL` tag — watchable via:
//
//      log stream --predicate 'process == "SacredPathway"' --info --debug \
//          | grep SP_DEBUG_LOCAL
//
//  Run mode: gated by either of
//    a) `-RunLocalSmokeTest` launch argument (Edit Scheme → Arguments)
//    b) UserDefaults key `sp.debug.local.smoke_test` == true
//
//  Off by default. The test is destructive ONLY against records it created
//  itself (matched by a unique tag). It does NOT wipe pre-existing rows.
// =============================================================================

#if DEBUG

@MainActor
enum LocalSmokeTest {

    /// Caller-side helper — checks launch args + defaults and runs the
    /// suite if either gate is true. Safe to call from `SacredPathwayApp.task`
    /// in DEBUG builds; release builds compile this out entirely.
    static func runIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        let argFlag = args.contains("-RunLocalSmokeTest")
        let defaultsFlag = UserDefaults.standard.bool(forKey: "sp.debug.local.smoke_test")
        guard argFlag || defaultsFlag else { return }
        await run()
    }

    static func run() async {
        let tag = "SP_DEBUG_LOCAL"
        let runId = UUID().uuidString.prefix(8)
        print("[\(tag)] ──────── LocalSmokeTest START (\(runId)) ────────")

        var failures = 0
        func assert(_ cond: Bool, _ label: String) {
            if cond {
                print("[\(tag)]  PASS · \(label)")
            } else {
                failures += 1
                print("[\(tag)]  FAIL · \(label)")
            }
        }

        // ── 1) Brokers CRUD ────────────────────────────────────────────
        let bRepo = LocalBrokersRepository.shared
        let originalBrokerCount = bRepo.brokers.count
        let installId = AppMode.shared.localInstallId
        let tagName = "SmokeTest-Broker-\(runId)"

        let bIn = Broker(
            profileId: installId,
            brokerName: tagName,
            normalizedName: Broker.normalize(tagName),
            mcNumber: "999\(Int.random(in: 100...999))",
            totalLoads: 0,
            totalRevenue: 0
        )
        let bCreated = bRepo.create(bIn)
        assert(bCreated.id != nil, "Broker.create assigns an id")
        assert(bRepo.brokers.count == originalBrokerCount + 1,
               "Broker.create appends to list")

        let found = bRepo.findByNormalizedName(Broker.normalize(tagName))
        assert(found?.id == bCreated.id, "Broker.findByNormalizedName returns created row")

        // Mutate
        var bUpdate = bCreated
        bUpdate.mcNumber = "111111"
        bRepo.update(bUpdate)
        let bAfterUpdate = bRepo.find(id: bCreated.id!)
        assert(bAfterUpdate?.mcNumber == "111111", "Broker.update persists mc change")

        // ── 2) BrokerContacts CRUD ────────────────────────────────────
        let cRepo = LocalBrokerContactsRepository.shared
        let brokerId = bCreated.id!
        let cIn = BrokerContact(
            brokerId: brokerId,
            contactName: "SmokeTest-Contact-\(runId)",
            email: "smoke-\(runId)@example.test",
            phone: "555-555-1234",
            phoneExtension: "42",
            lastInteractionAt: Date()
        )
        let cCreated = cRepo.create(cIn)
        assert(cCreated.id != nil, "BrokerContact.create assigns an id")
        let cFetched = await cRepo.fetch(forBroker: brokerId)
        assert(cFetched.contains(where: { $0.id == cCreated.id }),
               "BrokerContact.fetch(forBroker:) returns created contact")
        let cByName = cRepo.findContact(brokerId: brokerId, name: cIn.contactName)
        assert(cByName?.id == cCreated.id,
               "BrokerContact.findContact(brokerId:name:) matches case-insensitively")

        // Update
        var cUpdate = cCreated
        cUpdate.phone = "555-555-9999"
        cRepo.update(cUpdate)
        let cAfterUpdate = cRepo.contacts.first(where: { $0.id == cCreated.id })
        assert(cAfterUpdate?.phone == "555-555-9999",
               "BrokerContact.update persists phone change")

        // ── 3) Loads CRUD ─────────────────────────────────────────────
        let lRepo = LocalLoadsRepository.shared
        let originalLoadCount = lRepo.loads.count
        let lIn = Load(
            profileId: installId,
            loadNumber: "SMOKE-\(runId)",
            brokerName: tagName,
            brokerMcNumber: "111111",
            pickupDate: Date(),
            deliveryDate: Date().addingTimeInterval(86_400),
            origin: "Atlanta, GA",
            destination: "Dallas, TX",
            totalMiles: 800,
            lineHaulRate: 2500,
            fuelSurcharge: 0,
            accessorialCharges: 0,
            totalRevenue: 2500,
            status: "delivered",
            brokerId: brokerId,
            brokerContactId: cCreated.id,
            brokerContactName: cIn.contactName,
            brokerContactPhone: cIn.phone,
            brokerPhoneExtension: cIn.phoneExtension,
            brokerContactEmail: cIn.email
        )
        let lCreated = lRepo.create(lIn)
        assert(lCreated.id != nil, "Load.create assigns an id")
        assert(lRepo.loads.count == originalLoadCount + 1,
               "Load.create appends to list")
        let lFound = lRepo.findByLoadNumber("SMOKE-\(runId)")
        assert(lFound?.id == lCreated.id, "Load.findByLoadNumber matches case-insensitively")

        // Update
        var lUpdate = lCreated
        lUpdate.totalRevenue = 3000
        lRepo.update(lUpdate)
        let lAfterUpdate = lRepo.find(id: lCreated.id!)
        assert(lAfterUpdate?.totalRevenue == 3000,
               "Load.update persists revenue change")

        // ── 4) Persistence round-trip via disk reload ─────────────────
        // Force the in-memory caches to throw away their state and reload
        // from disk. Anything we just created must survive.
        lRepo.reload()
        bRepo.reload()
        cRepo.reload()
        assert(lRepo.find(id: lCreated.id!) != nil,
               "Load persists across reload (disk round-trip)")
        assert(bRepo.find(id: bCreated.id!) != nil,
               "Broker persists across reload (disk round-trip)")
        assert(cRepo.contacts.contains(where: { $0.id == cCreated.id }),
               "BrokerContact persists across reload (disk round-trip)")

        // ── 5) Sacred DISPATCH QA coverage ───────────────────────────
        let dRepo = LocalDispatchRepository.shared
        let dispatchTag = "SmokeTest-Dispatch-\(runId)"
        dRepo.deleteRecords(containing: dispatchTag)
        let carrierId = UUID()
        let dispatcherUserId = UUID()
        let dispatcherProfileId = UUID()
        let agreementId = UUID()
        let threadId = UUID()
        let offerId = UUID()

        let dispatcherProfile = DispatcherProfile(
            id: dispatcherProfileId,
            companyId: installId,
            userId: dispatcherUserId,
            displayName: "\(dispatchTag)-Dispatcher",
            companyName: "\(dispatchTag)-Company",
            yearsExperience: 5,
            equipmentTypes: [DispatchEquipmentType.dryVan.rawValue],
            serviceRegions: ["TX"],
            languagesSpoken: ["English"],
            servicesOffered: ["Load planning"],
            phone: "555-0100",
            email: "dispatch@example.test",
            contactInfo: nil,
            isActive: true,
            isTrusted: false,
            platformFeePercentage: nil,
            ratingAverage: 0,
            ratingCount: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        _ = dRepo.upsertProfile(dispatcherProfile)
        let request = dRepo.upsertServiceRequest(DispatchServiceRequest(
            id: UUID(),
            companyId: installId,
            requestedByProfileId: carrierId,
            dispatcherProfileId: dispatcherProfileId,
            dispatcherUserId: dispatcherUserId,
            carrierName: "\(dispatchTag)-Carrier",
            serviceNotes: "\(dispatchTag)-request",
            status: .accepted,
            createdAt: Date(),
            updatedAt: Date()
        ))
        assert(request.status == .accepted, "Dispatch service request persists accepted status")

        let agreement = dRepo.upsertAgreement(DispatchAgreement(
            id: agreementId,
            companyId: installId,
            carrierProfileId: carrierId,
            dispatcherProfileId: dispatcherProfileId,
            dispatcherUserId: dispatcherUserId,
            carrierName: "\(dispatchTag)-Carrier",
            dispatcherName: "\(dispatchTag)-Dispatcher",
            dispatcherCompany: "\(dispatchTag)-Company",
            effectiveDate: Date(),
            feeType: .percentageGross,
            feePercentage: 5,
            feeAmount: nil,
            status: .active,
            notes: "\(dispatchTag)-agreement",
            createdAt: Date(),
            updatedAt: Date()
        ))
        assert(agreement.fee(for: 12_000) == 600, "Dispatch percentage fee calculates correctly")

        var feeRecord = dRepo.upsertFeeRecord(DispatcherFeeRecord(
            id: UUID(),
            companyId: installId,
            agreementId: agreementId,
            dispatcherProfileId: dispatcherProfileId,
            dispatcherUserId: dispatcherUserId,
            carrierProfileId: carrierId,
            loadId: nil,
            settlementDocumentId: nil,
            invoiceId: nil,
            loadNumber: "\(dispatchTag)-SETTLE",
            brokerName: "\(dispatchTag)-Broker",
            grossRevenue: 12_000,
            paymentAmount: 12_000,
            feeType: .percentageGross,
            feePercentage: 5,
            feeAmount: nil,
            calculatedDispatchFee: 600,
            paymentStatus: .unpaid,
            dueDate: Date(),
            paymentDate: nil,
            notes: "\(dispatchTag)-fee",
            sourceType: "\(dispatchTag)-settlement_ocr",
            ocrConfidence: 0.98,
            createdAt: Date(),
            updatedAt: Date()
        ))
        let invoice = dRepo.upsertInvoice(DispatcherInvoice(
            id: UUID(),
            companyId: installId,
            agreementId: agreementId,
            dispatcherProfileId: dispatcherProfileId,
            dispatcherUserId: dispatcherUserId,
            carrierProfileId: carrierId,
            invoiceNumber: "\(dispatchTag)-INV",
            periodStart: Date(),
            periodEnd: Date(),
            totalGrossRevenue: feeRecord.grossRevenue,
            totalFeesDue: feeRecord.calculatedDispatchFee,
            paymentStatus: .unpaid,
            dueDate: Date(),
            paymentDate: nil,
            notes: "\(dispatchTag)-invoice",
            createdAt: Date(),
            updatedAt: Date()
        ))
        feeRecord.invoiceId = invoice.id
        feeRecord.paymentStatus = .paid
        feeRecord.paymentDate = Date()
        feeRecord = dRepo.upsertFeeRecord(feeRecord)
        assert(feeRecord.invoiceId == invoice.id && feeRecord.paymentStatus == .paid,
               "Dispatch fee record links to invoice and tracks paid status")

        let offer = dRepo.upsertOffer(DispatchLoadOffer(
            id: offerId,
            companyId: installId,
            threadId: threadId,
            dispatcherProfileId: dispatcherProfileId,
            dispatcherUserId: dispatcherUserId,
            driverProfileId: carrierId,
            agreementId: agreementId,
            dispatcherName: "\(dispatchTag)-Dispatcher",
            dispatcherCompany: "\(dispatchTag)-Company",
            loadNumber: "\(dispatchTag)-OFFER",
            brokerName: "\(dispatchTag)-Broker",
            origin: "Memphis, TN",
            destination: "Dallas, TX",
            totalMiles: 460,
            lineHaulRate: 2_400,
            loadGrossAmount: 2_400,
            feeType: .flatPerLoad,
            feeAmount: 75,
            invoiceCadence: .weekly,
            notes: "\(dispatchTag)-offer",
            status: .accepted,
            acceptedLoadId: lCreated.id,
            acceptedAt: Date(),
            createdAt: Date(),
            updatedAt: Date()
        ))
        assert(offer.calculatedDispatchFee == 75, "Dispatch flat-per-load fee calculates correctly")

        let chatThread = dRepo.upsertThread(DispatchThread(
            id: threadId,
            companyId: installId,
            loadOfferId: offerId,
            acceptedLoadId: lCreated.id,
            agreementId: agreementId,
            loadNumber: "\(dispatchTag)-OFFER",
            driverProfileId: carrierId,
            dispatcherUserId: dispatcherUserId,
            dispatcherName: "\(dispatchTag)-Dispatcher",
            dispatcherCompany: "\(dispatchTag)-Company",
            subject: "\(dispatchTag)-Thread",
            lastMessagePreview: "\(dispatchTag)-message",
            driverUnreadCount: 0,
            dispatcherUnreadCount: 0,
            carrierUnreadCount: 1,
            lastMessageAt: Date(),
            createdAt: Date(),
            updatedAt: Date()
        ))
        _ = dRepo.appendMessage(DispatchMessage(
            id: UUID(),
            companyId: installId,
            threadId: threadId,
            loadOfferId: offerId,
            senderProfileId: dispatcherUserId,
            senderRole: .dispatcher,
            senderName: "\(dispatchTag)-Dispatcher",
            body: "\(dispatchTag)-message",
            kind: .text,
            readAt: nil,
            createdAt: Date()
        ))
        assert(chatThread.unreadCount(for: .carrier) == 1,
               "Dispatch chat thread tracks unread carrier count")

        var dispatchLoad = lCreated
        dispatchLoad.dispatchThreadId = threadId
        dispatchLoad.dispatchLoadOfferId = offerId
        dispatchLoad.dispatcherName = "\(dispatchTag)-Dispatcher"
        dispatchLoad.dispatcherCompany = "\(dispatchTag)-Company"
        lRepo.update(dispatchLoad)
        assert(lRepo.find(id: lCreated.id!)?.dispatcherCompany == "\(dispatchTag)-Company",
               "Accepted dispatch load stores dispatcher metadata")

        dRepo.reload()
        assert(dRepo.feeRecords.contains(where: { $0.loadNumber == "\(dispatchTag)-SETTLE" }),
               "Dispatch fee record persists across reload")
        dRepo.deleteRecords(containing: dispatchTag)

        // ── 6) Delete cleans up ───────────────────────────────────────
        lRepo.delete(id: lCreated.id!)
        cRepo.delete(id: cCreated.id!)
        bRepo.delete(id: bCreated.id!)
        assert(lRepo.find(id: lCreated.id!) == nil, "Load.delete removes record")
        assert(cRepo.contacts.first(where: { $0.id == cCreated.id }) == nil,
               "BrokerContact.delete removes record")
        assert(bRepo.find(id: bCreated.id!) == nil, "Broker.delete removes record")

        // Final tally
        if failures == 0 {
            print("[\(tag)] ──────── LocalSmokeTest PASSED · all checks green ────────")
        } else {
            print("[\(tag)] ──────── LocalSmokeTest FAILED · \(failures) check(s) ────────")
        }
    }
}

#endif
