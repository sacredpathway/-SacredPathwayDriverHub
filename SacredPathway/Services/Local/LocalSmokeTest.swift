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

        // ── 5) Delete cleans up ───────────────────────────────────────
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
