import XCTest
@testable import SacredPathway

@MainActor
final class LocalLoadsDeletionPersistenceTests: XCTestCase {

    func testDeleteCommitsRemovalToLoadsJSONBeforePublishing() throws {
        let repository = LocalLoadsRepository()
        let originalLoads = repository.loads
        defer {
            repository.replaceAll(with: originalLoads)
        }

        let id = UUID()
        let stored = repository.create(Fixtures.load(id: id, revenue: 425))
        XCTAssertEqual(stored.id, id)
        XCTAssertNotNil(repository.find(id: id))
        XCTAssertTrue(
            LocalStore.loadArray(Load.self, fileName: "loads.json")
                .contains(where: { $0.id == id })
        )

        XCTAssertTrue(repository.delete(id: id))
        XCTAssertNil(repository.find(id: id))

        // Simulate a delayed/stale writer trying to recreate the exact record
        // after deletion. The durable deletion ledger must reject it.
        _ = repository.create(stored)
        XCTAssertNil(repository.find(id: id))

        let reloaded = LocalLoadsRepository()
        XCTAssertNil(reloaded.find(id: id))
        XCTAssertFalse(
            LocalStore.loadArray(Load.self, fileName: "loads.json")
                .contains(where: { $0.id == id })
        )
    }
}

// MARK: - WeeklyStatsService (period bucketing, dedupe, window-date fallback)

@MainActor
final class WeeklyStatsServiceTests: XCTestCase {

    // Anchor "now" mid-month to keep month/30-day windows unambiguous.
    private let now = Fixtures.date(2026, 6, 15)

    func testDedupeKeepsMostRecentlyUpdatedCopy() {
        let id = UUID()
        let stale = Fixtures.load(id: id, revenue: 100,
                                  updatedAt: Fixtures.date(2026, 6, 1))
        let fresh = Fixtures.load(id: id, revenue: 900,
                                  updatedAt: Fixtures.date(2026, 6, 10))
        let total = WeeklyStatsService.revenue(in: .allTime,
                                               loads: [stale, fresh], now: now)
        XCTAssertEqual(total, 900, accuracy: 0.001,
                       "duplicate ids must never double-count; newest updatedAt wins")
    }

    func testWindowDateFallbackChain_pickupThenDeliveryThenCreated() {
        let pickup = Fixtures.load(revenue: 1,
                                   pickupDate: Fixtures.date(2026, 6, 14),
                                   deliveryDate: Fixtures.date(2026, 1, 1),
                                   createdAt: Fixtures.date(2026, 1, 1))
        XCTAssertEqual(WeeklyStatsService.windowDate(for: pickup),
                       pickup.pickupDate)

        let delivery = Fixtures.load(revenue: 1,
                                     deliveryDate: Fixtures.date(2026, 6, 14),
                                     createdAt: Fixtures.date(2026, 1, 1))
        XCTAssertEqual(WeeklyStatsService.windowDate(for: delivery),
                       delivery.deliveryDate)

        let created = Fixtures.load(revenue: 1,
                                    createdAt: Fixtures.date(2026, 6, 14))
        XCTAssertEqual(WeeklyStatsService.windowDate(for: created),
                       created.createdAt)
    }

    func testNilPickupLoadStillCountsInMonthViaFallback() {
        // Regression guard for the "load without pickup date vanishes from
        // windowed revenue" class of bug.
        let load = Fixtures.load(revenue: 500,
                                 createdAt: Fixtures.date(2026, 6, 10))
        let total = WeeklyStatsService.revenue(in: .month, loads: [load], now: now)
        XCTAssertEqual(total, 500, accuracy: 0.001)
    }

    func testLoadAwareContainsMatchesRevenueBucketing() {
        // Date-only contains() excludes a nil-pickup load…
        XCTAssertFalse(WeeklyStatsService.contains(period: .month,
                                                   pickupDate: nil, now: now))
        // …but the load-aware overload agrees with revenue(in:) via fallback.
        let load = Fixtures.load(revenue: 500,
                                 createdAt: Fixtures.date(2026, 6, 10))
        XCTAssertTrue(WeeklyStatsService.contains(period: .month,
                                                  load: load, now: now))
    }

    func testLast30DaysWindowIsHalfOpenAndIncludesToday() {
        let i = WeeklyStatsService.interval(for: .last30Days, now: now)
        XCTAssertTrue(now >= i.start && now < i.end,
                      "'now' itself must be inside the 30-day window")
        let thirtyOneDaysAgo = Fixtures.date(2026, 5, 14)
        XCTAssertFalse(thirtyOneDaysAgo >= i.start)
    }

    func testAllTimeIncludesCompletelyUndatedLoads() {
        let undated = Fixtures.load(revenue: 250)
        let total = WeeklyStatsService.revenue(in: .allTime, loads: [undated], now: now)
        XCTAssertEqual(total, 250, accuracy: 0.001)
    }

    // MARK: Performance baseline (Phase 1 · Task 4)

    /// Dedupe + bucket + sum over 5,000 loads (with 20% duplicate ids) —
    /// the exact pipeline LoadsSyncService.recompute + dashboard totals run
    /// on every data change. Establishes an XCTest `measure` baseline so a
    /// future regression (e.g. someone makes dedupe quadratic) fails loudly.
    /// 5k loads ≈ a busy 3-truck carrier's multi-year history — well beyond
    /// today's expected data size.
    func testPerformanceBaseline_dedupeAndRevenueAt5kLoads() {
        var loads: [Load] = []
        loads.reserveCapacity(6_000)
        for i in 0..<5_000 {
            let id = UUID()
            let day = (i % 28) + 1
            loads.append(Fixtures.load(
                id: id,
                revenue: Double(500 + (i % 3_000)),
                pickupDate: Fixtures.date(2026, (i % 12) + 1, day),
                updatedAt: Fixtures.date(2026, 6, 1)
            ))
            if i % 5 == 0 {   // 20% duplicate ids with newer copies
                loads.append(Fixtures.load(
                    id: id,
                    revenue: Double(500 + (i % 3_000)),
                    pickupDate: Fixtures.date(2026, (i % 12) + 1, day),
                    updatedAt: Fixtures.date(2026, 6, 2)
                ))
            }
        }

        measure {
            let deduped = WeeklyStatsService.dedupe(loads)
            XCTAssertEqual(deduped.count, 5_000)
            _ = WeeklyStatsService.revenue(in: .month, loads: loads, now: now)
            _ = WeeklyStatsService.revenue(in: .allTime, loads: loads, now: now)
        }
    }
}

// MARK: - IFTA (quarter boundaries, calculator math, rate-overlay guard)

@MainActor
final class IFTATests: XCTestCase {

    private func entry(state: String, miles: Double, gallons: Double,
                       date: Date) -> IFTAEntry {
        IFTAEntry(id: UUID(), profileId: Fixtures.profileID,
                  date: date, stateCode: state,
                  milesDriven: miles, fuelGallons: gallons,
                  notes: nil, createdAt: nil)
    }

    // MARK: Quarter boundaries

    func testQuarterContainsAfternoonOfFinalDay() {
        // Regression: entries logged during the day on Mar 31 previously fell
        // out of Q1 AND Q2 (contains compared against midnight of the 31st).
        let q1 = IFTAQuarter.q1(year: 2026)
        XCTAssertTrue(q1.contains(Fixtures.date(2026, 3, 31, hour: 14)),
                      "afternoon of the quarter's last day must belong to the quarter")
        XCTAssertFalse(q1.contains(Fixtures.date(2026, 4, 1, hour: 0)))
        XCTAssertTrue(IFTAQuarter.q4(year: 2026)
            .contains(Fixtures.date(2026, 12, 31, hour: 23, minute: 59)))
    }

    func testQuarterFromDate() {
        XCTAssertEqual(IFTAQuarter.from(date: Fixtures.date(2026, 7, 4)),
                       .q3(year: 2026))
        XCTAssertEqual(IFTAQuarter.from(date: Fixtures.date(2026, 3, 31)),
                       .q1(year: 2026))
    }

    // MARK: Calculator math

    func testFleetMPGAndTaxableGallons() {
        // 1,000 mi @ 200 gal fleet-wide → 5.0 MPG (at the documented floor).
        let entries = [
            entry(state: "TX", miles: 600, gallons: 120, date: Fixtures.date(2026, 5, 10)),
            entry(state: "OK", miles: 400, gallons: 80,  date: Fixtures.date(2026, 5, 12)),
        ]
        let summary = IFTACalculator.summarize(entries: entries,
                                               forQuarter: .q2(year: 2026))
        XCTAssertEqual(summary.totalMiles, 1_000, accuracy: 0.001)
        XCTAssertEqual(summary.totalGallons, 200, accuracy: 0.001)
        XCTAssertEqual(summary.averageMPG, 5.0, accuracy: 0.001)

        let tx = summary.statesummaries.first { $0.stateCode == "TX" }
        XCTAssertNotNil(tx)
        // taxableGallons = state miles / fleet MPG (5.0 floor) = 600 / 5 = 120
        XCTAssertEqual(tx!.taxableGallons, 120, accuracy: 0.001)
    }

    func testEntriesOutsideQuarterAreExcluded() {
        let entries = [
            entry(state: "TX", miles: 100, gallons: 20, date: Fixtures.date(2026, 5, 10)),
            entry(state: "TX", miles: 999, gallons: 99, date: Fixtures.date(2026, 1, 10)),
        ]
        let summary = IFTACalculator.summarize(entries: entries,
                                               forQuarter: .q2(year: 2026))
        XCTAssertEqual(summary.totalMiles, 100, accuracy: 0.001)
    }

    // MARK: Rate overlay + $0 sentinel guard

    func testTaxOwedIsZeroSentinelWithoutRateMatrix_andRealWithOne() {
        // Without a loaded matrix the static table's 0.0 sentinel yields 0 —
        // which is exactly why the UI must hide tax output when
        // `ratesAvailable == false` (tested below).
        let service = IFTARatesService.shared
        XCTAssertNil(service.rate(for: "ZZ"))

        // Inject a validated matrix (44 jurisdictions ≥ minimum of 40).
        var rates: [String: Double] = [:]
        for j in iftaJurisdictions.prefix(44) { rates[j.code] = 0.30 }
        rates["TX"] = 0.20
        service.apply(
            IFTARatesService.RatesPayload(quarter: "TESTQ", updated: nil,
                                          source: "unit-test", rates: rates),
            persistToCache: false
        )

        XCTAssertTrue(service.ratesAvailable)
        XCTAssertEqual(service.rate(for: "tx"), 0.20)
        XCTAssertEqual(jurisdictionForCode("TX")?.taxRatePerGallon ?? 0, 0.20,
                       accuracy: 0.0001,
                       "jurisdictionForCode must overlay the official rate")

        // End-to-end: 600 TX miles at 5 MPG → 120 taxable gal × $0.20 = $24
        let entries = [
            entry(state: "TX", miles: 600, gallons: 120, date: Fixtures.date(2026, 5, 10)),
            entry(state: "OK", miles: 400, gallons: 80,  date: Fixtures.date(2026, 5, 12)),
        ]
        let summary = IFTACalculator.summarize(entries: entries,
                                               forQuarter: .q2(year: 2026))
        let tx = summary.statesummaries.first { $0.stateCode == "TX" }!
        XCTAssertEqual(tx.taxOwed, 24.0, accuracy: 0.001)
    }

    func testMalformedRatePayloadIsRejected() {
        let service = IFTARatesService.shared
        let before = service.quarterLabel
        // Too few jurisdictions → must be rejected, state unchanged.
        service.apply(
            IFTARatesService.RatesPayload(quarter: "BADQ", updated: nil,
                                          source: nil, rates: ["TX": 0.2]),
            persistToCache: false
        )
        XCTAssertNotEqual(service.quarterLabel, "BADQ")
        XCTAssertEqual(service.quarterLabel, before)
    }
}

@MainActor
final class ComplianceReminderPlannerTests: XCTestCase {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!

    func testUpcomingExpirationProducesFutureRemindersWithStableUniqueIdentifiers() {
        let now = Fixtures.date(2026, 7, 1)
        let expiration = Fixtures.date(2026, 8, 15)
        let reminders = ComplianceReminderPlanner.reminders(
            documentID: id, expirationDate: expiration, now: now
        )
        XCTAssertFalse(reminders.isEmpty)
        XCTAssertTrue(reminders.allSatisfy { $0.date > now })
        XCTAssertEqual(Set(reminders.map(\.identifier)).count, reminders.count)
        XCTAssertEqual(
            ComplianceReminderPlanner.identifier(documentID: id, daysBefore: 30),
            ComplianceReminderPlanner.identifier(documentID: id, daysBefore: 30)
        )
    }

    func testPastOrMissingExpirationProducesNoReminders() {
        let now = Fixtures.date(2026, 7, 1)
        XCTAssertTrue(ComplianceReminderPlanner.reminders(
            documentID: id, expirationDate: Fixtures.date(2026, 6, 1), now: now
        ).isEmpty)
        XCTAssertTrue(ComplianceReminderPlanner.reminders(
            documentID: id, expirationDate: nil, now: now
        ).isEmpty)
    }

    func testDateUpdateReplacesScheduleAndDeletionIdentifiersCoverEveryInterval() {
        let now = Fixtures.date(2026, 7, 1)
        let first = ComplianceReminderPlanner.reminders(
            documentID: id, expirationDate: Fixtures.date(2026, 8, 15), now: now
        )
        let updated = ComplianceReminderPlanner.reminders(
            documentID: id, expirationDate: Fixtures.date(2026, 9, 15), now: now
        )
        XCTAssertNotEqual(first.map(\.date), updated.map(\.date))
        XCTAssertEqual(
            Set(ComplianceReminderPlanner.identifiers(documentID: id)),
            Set(ComplianceReminderPlanner.intervals.map {
                ComplianceReminderPlanner.identifier(documentID: id, daysBefore: $0)
            })
        )
    }
}

@MainActor
final class HTTPRetryPolicyTests: XCTestCase {
    func testRetriesOnlyDocumentedTransientStatuses() {
        let policy = HTTPRetryPolicy.standard
        for code in [408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(policy.shouldRetry(statusCode: code))
        }
        for code in [400, 401, 403, 404, 409, 422] {
            XCTAssertFalse(policy.shouldRetry(statusCode: code))
        }
    }

    func testRetryAfterIsRespectedAndCapped() {
        let policy = HTTPRetryPolicy.standard
        XCTAssertEqual(policy.delay(attempt: 0, retryAfter: "3", jitter: 0), 3)
        XCTAssertEqual(policy.delay(attempt: 0, retryAfter: "120", jitter: 0), 30)
    }

    func testBackoffIsDeterministicWhenJitterInjected() {
        let policy = HTTPRetryPolicy(maximumRetries: 2, baseDelay: 0.5)
        XCTAssertEqual(policy.delay(attempt: 0, retryAfter: nil, jitter: 0), 0.5)
        XCTAssertEqual(policy.delay(attempt: 1, retryAfter: nil, jitter: 0), 1.0)
    }
}
