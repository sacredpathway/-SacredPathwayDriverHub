import XCTest
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

// =============================================================================
//  Driver authorization and cross-driver privacy
// =============================================================================

final class SettlementPermissionsTests: XCTestCase {

    private func ledgerWithTwoDrivers() throws -> (SettlementLedger, UUID, UUID, UUID) {
        var ledger = SettlementLedger()
        let d1 = Fx.driver(Fx.driverId, name: "Test Driver")
        let d2 = Fx.driver(Fx.driver2Id, name: "Test Driver Two")
        var loadB = Fx.opLoad(2, gross: 5_000, driverId: Fx.driver2Id)
        loadB.loadNumber = "TEST-2"

        let paidA = try Fx.saveDraft([Fx.opLoad(1, gross: 2_000)], into: &ledger, driver: d1,
                                     deductions: [Fx.deduction(1, .repair, "Split repair", 400,
                                                               responsibility: .split, driverShare: 50),
                                                  Fx.deduction(2, .factoringFee, "Company factoring", 60,
                                                               responsibility: .company, driverShare: 0)])
        _ = try Fx.approve(paidA, &ledger)
        _ = try SettlementWorkflowService.transition(settlementId: paidA, to: .paid, ledger: &ledger,
                                                     actor: Fx.actor, now: Fx.now)
        let draftA = try Fx.saveDraft([Fx.opLoad(3, gross: 1_000)], into: &ledger, driver: d1)
        let paidB = try Fx.saveDraft([loadB], into: &ledger, driver: d2)
        _ = try Fx.approve(paidB, &ledger)
        return (ledger, paidA, draftA, paidB)
    }

    func testRoleResolutionFromExistingAccountModel() {
        XCTAssertEqual(SettlementRole.resolve(accountRole: .carrier, isLocalMode: false), .owner)
        XCTAssertEqual(SettlementRole.resolve(accountRole: .ownerOperator, isLocalMode: false), .owner)
        XCTAssertEqual(SettlementRole.resolve(accountRole: .dispatcher, isLocalMode: false), .manager)
        XCTAssertEqual(SettlementRole.resolve(accountRole: .driver, isLocalMode: false), .driver)
        XCTAssertEqual(SettlementRole.resolve(accountRole: .driver, isLocalMode: true), .owner,
                       "Free Local Mode has one operator")
        XCTAssertEqual(SettlementRole.resolve(accountRole: .carrier, isLocalMode: false, membershipRole: "admin"), .accounting)
        XCTAssertEqual(SettlementRole.resolve(accountRole: .carrier, isLocalMode: false, membershipRole: "driver"), .driver)
    }

    func testCapabilityMatrix() {
        let owner = SettlementPermissions.capabilities(for: .owner)
        XCTAssertTrue(owner.contains([.approve, .markPaid, .void, .reopen, .createDraft, .export]))

        let manager = SettlementPermissions.capabilities(for: .manager)
        XCTAssertTrue(manager.contains([.createDraft, .editDraft, .submitForReview]))
        XCTAssertFalse(manager.contains(.approve))
        XCTAssertFalse(manager.contains(.markPaid))
        XCTAssertFalse(manager.contains(.viewCompanyFinancials))

        let accounting = SettlementPermissions.capabilities(for: .accounting)
        XCTAssertTrue(accounting.contains([.approve, .markPaid, .export]))
        XCTAssertFalse(accounting.contains(.createDraft))

        let driver = SettlementPermissions.capabilities(for: .driver)
        XCTAssertEqual(driver, [.viewOwnSettlements, .export])
        XCTAssertFalse(driver.contains(.editDraft))
        XCTAssertTrue(SettlementPermissions.capabilities(for: .driver, driversMaySeeEstimates: true)
            .contains(.viewEstimates))
    }

    func testTransitionPermissions() {
        let manager = SettlementViewer(role: .manager)
        XCTAssertTrue(SettlementPermissions.canTransition(manager, from: .draft, to: .readyForReview))
        XCTAssertFalse(SettlementPermissions.canTransition(manager, from: .readyForReview, to: .approved))
        XCTAssertFalse(SettlementPermissions.canTransition(manager, from: .approved, to: .paid))

        let accounting = SettlementViewer(role: .accounting)
        XCTAssertTrue(SettlementPermissions.canTransition(accounting, from: .readyForReview, to: .approved))
        XCTAssertTrue(SettlementPermissions.canTransition(accounting, from: .approved, to: .paid))
        XCTAssertFalse(SettlementPermissions.canTransition(accounting, from: .paid, to: .approved),
                       "reopening paid history is owner-only")

        let driver = SettlementViewer(role: .driver, linkedDriverIds: [Fx.driverId])
        for target in SettlementStatus.allCases {
            XCTAssertFalse(SettlementPermissions.canTransition(driver, from: .draft, to: target))
        }
    }

    func testDriverSeesOnlyOwnApprovedOrPaidSettlements() throws {
        let (ledger, paidA, draftA, paidB) = try ledgerWithTwoDrivers()
        let viewer = SettlementViewer(role: .driver, linkedDriverIds: [Fx.driverId])
        let visible = SettlementPermissions.visibleSettlements(ledger.settlements, viewer: viewer)
        XCTAssertEqual(visible.compactMap(\.id), [paidA])
        XCTAssertFalse(visible.contains { $0.id == draftA }, "drafts are not shown to drivers")
        XCTAssertFalse(visible.contains { $0.id == paidB }, "another driver's pay is never shown")

        let unlinked = SettlementViewer(role: .driver, linkedDriverIds: [])
        XCTAssertTrue(SettlementPermissions.visibleSettlements(ledger.settlements, viewer: unlinked).isEmpty)
    }

    func testCrossDriverPrivacyInScopedLedger() throws {
        let (ledger, paidA, _, paidB) = try ledgerWithTwoDrivers()
        var withAdvances = ledger
        withAdvances.advances = [Fx.advance(1, dollars: 100),
                                 DriverAdvance(profileId: Fx.profileId, driverId: Fx.driver2Id, type: .cash,
                                               date: Fx.periodStart, amount: Fx.money(999),
                                               descriptionText: "Other driver's advance")]
        let viewer = SettlementViewer(role: .driver, linkedDriverIds: [Fx.driverId])
        let scoped = SettlementPermissions.scopedLedger(withAdvances, viewer: viewer)

        XCTAssertEqual(scoped.settlements.compactMap(\.id), [paidA])
        XCTAssertFalse(scoped.loadLines.contains { $0.settlementId == paidB })
        XCTAssertFalse(scoped.loadLines.contains { $0.loadNumber == "TEST-2" })
        XCTAssertEqual(scoped.advances.map(\.driverId), [Fx.driverId])
        XCTAssertTrue(scoped.auditEvents.isEmpty, "internal audit trail is not exposed")
        XCTAssertTrue(scoped.recurringDeductions.isEmpty)
        XCTAssertNil(scoped.settlements[0].companyRetained, "company margin hidden from drivers")
        XCTAssertNil(scoped.settlements[0].companyExpenses)
        XCTAssertFalse(scoped.deductions.contains { $0.descriptionText == "Company factoring" },
                       "company-paid lines never touched the driver's check")
        XCTAssertTrue(scoped.deductions.contains { $0.descriptionText == "Split repair" })

        // Owner sees everything untouched.
        let owner = SettlementPermissions.scopedLedger(withAdvances, viewer: SettlementViewer(role: .owner))
        XCTAssertEqual(owner.settlements.count, ledger.settlements.count)
    }

    func testRedactedBundleKeepsDriverFiguresIdentical() throws {
        let (ledger, paidA, _, _) = try ledgerWithTwoDrivers()
        let full = ledger.bundle(for: paidA)!
        let redacted = SettlementPermissions.redactedForDriver(full)
        XCTAssertMoney(redacted.calculate().netDriverPay, full.calculate().netDriverPay,
                       "removing company-only lines must not change the driver's net")
        XCTAssertTrue(redacted.auditEvents.isEmpty)
        XCTAssertNil(redacted.settlement.companyRetained)
    }

    /// Percent-of-NET: the driver's copy has no company-paid lines, so it must
    /// show the approved (frozen) load earnings, not re-price on a bigger base.
    func testDriverCopyOfPercentOfNetSettlementShowsApprovedFigures() throws {
        var ledger = SettlementLedger()
        var d = Fx.driver(rule: .percentOfGross(30))
        d.payOnGrossRevenue = false
        let sid = try Fx.saveDraft([Fx.opLoad(1, gross: 5_000)], into: &ledger, driver: d,
                                   deductions: [Fx.deduction(1, .insurance, "Company insurance", 1_000,
                                                             responsibility: .company, driverShare: 0)])
        _ = try Fx.approve(sid, &ledger)
        let full = ledger.bundle(for: sid)!
        XCTAssertMoney(full.calculate().netDriverPay, 1_200, 0, "30% of (5,000 − 1,000)")
        XCTAssertMoney(full.settlement.netPayMoney, 1_200, 0)

        let redacted = SettlementPermissions.redactedForDriver(full)
        XCTAssertFalse(redacted.deductions.contains { $0.descriptionText == "Company insurance" })
        XCTAssertMoney(redacted.calculate().netDriverPay, 1_500, 0,
                       "re-pricing the stripped copy uses the wrong base — the reason frozen figures are used")
        XCTAssertMoney(redacted.calculate(frozenLoadEarnings: true).netDriverPay, 1_200, 0,
                       "driver copy keeps the approved figure")

        let doc = SettlementStatementDocument.make(bundle: redacted, driverName: "Test Driver",
                                                   company: .sacredPathwayDefault, ytd: nil,
                                                   generatedAt: Fx.now, frozenLoadEarnings: true)
        XCTAssertMoney(doc.netPay, 1_200, 0)
        XCTAssertNil(doc.reconciliationWarning)

        // The owner's full copy of an approved (not locked) settlement is
        // re-priced live and agrees with the stored figure.
        XCTAssertFalse(full.settlement.isLocked)
        XCTAssertMoney(full.displayCalculation.netDriverPay, 1_200, 0)
    }

    func testEditPermissionRespectsLockAndRole() throws {
        let (ledger, paidA, draftA, paidB) = try ledgerWithTwoDrivers()
        let owner = SettlementViewer(role: .owner)
        let manager = SettlementViewer(role: .manager)
        let driver = SettlementViewer(role: .driver, linkedDriverIds: [Fx.driverId])
        XCTAssertTrue(SettlementPermissions.canEdit(ledger.settlement(id: draftA)!, viewer: owner))
        XCTAssertTrue(SettlementPermissions.canEdit(ledger.settlement(id: draftA)!, viewer: manager))
        XCTAssertFalse(SettlementPermissions.canEdit(ledger.settlement(id: paidA)!, viewer: owner), "paid is locked")
        XCTAssertFalse(SettlementPermissions.canEdit(ledger.settlement(id: paidB)!, viewer: manager),
                       "approved needs someone who can re-approve")
        XCTAssertFalse(SettlementPermissions.canEdit(ledger.settlement(id: draftA)!, viewer: driver))
    }
}
