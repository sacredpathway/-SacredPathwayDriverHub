import Foundation
import Supabase

// =============================================================================
//  SettlementCloudStore — Cloud Pro persistence for settlements
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). Reads and writes the tables created by
//  `supabase/migrations/20260912120000_driver_pay_and_settlements.sql` (and the
//  driver-portal read policies in `20260916120000_…`). RLS scopes every query
//  to the signed-in account, so no query here filters by profile on trust.
//
//  Write order is chosen so a network failure half-way never leaves a
//  settlement with MISSING lines: header upsert → child upserts → prune rows
//  that are no longer on the settlement.
//
//  If the migration has not been applied yet, every call fails with
//  `SettlementCloudError.migrationRequired` rather than a raw PostgREST error.
// =============================================================================

enum SettlementCloudError: Error, LocalizedError {
    case notSignedIn
    case migrationRequired(String)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to sync settlements."
        case .migrationRequired(let detail):
            return "Cloud settlements need the Driver Pay & Settlements database update, which has not been applied to this project yet. (\(detail))"
        case .underlying(let e):
            return e.localizedDescription
        }
    }

    static func wrap(_ error: Error) -> SettlementCloudError {
        if let e = error as? SettlementCloudError { return e }
        let text = String(describing: error).lowercased()
        let missingSchema = text.contains("schema cache")
            || text.contains("does not exist")
            || text.contains("pgrst204")
            || text.contains("pgrst205")
            || text.contains("42p01")
            || text.contains("42703")
        if missingSchema {
            return .migrationRequired(error.localizedDescription)
        }
        return .underlying(error)
    }
}

/// Carrier context for a signed-in DRIVER account (from the
/// `sph_driver_settlement_context()` RPC).
struct DriverPortalContext: Decodable, Hashable {
    var carrierProfileId: UUID
    var linkedDriverId: UUID
    var driverName: String?
    var companyName: String?
    var mcNumber: String?
    var dotNumber: String?
    var phone: String?

    enum CodingKeys: String, CodingKey {
        case carrierProfileId = "carrier_profile_id"
        case linkedDriverId = "linked_driver_id"
        case driverName = "driver_name"
        case companyName = "company_name"
        case mcNumber = "mc_number"
        case dotNumber = "dot_number"
        case phone
    }
}

@MainActor
final class SettlementCloudStore {

    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    /// Driver columns the settlement feature reads. The live `drivers` table
    /// also holds PII (SSN, DOB, address, W-4) — those are never selected.
    static let driverColumns = "id,profile_id,name,truck_number,pay_percentage,pay_type,flat_rate,phone,email,active,created_at,settlement_type,pay_rule,pay_on_gross_revenue,lease_config"
    static let legacyDriverColumns = "id,profile_id,name,truck_number,pay_percentage,pay_type,flat_rate,phone,email,active,created_at"

    // MARK: - Read

    func fetchLedger() async throws -> SettlementLedger {
        guard client.auth.currentUser != nil else { throw SettlementCloudError.notSignedIn }
        do {
            let settlements: Task<[Settlement], Error> = spawn { try await self.rows("settlements", order: "created_at") }
            let lines: Task<[SettlementLoadLine], Error> = spawn { try await self.rows("settlement_loads", order: "sort_order") }
            let adds: Task<[SettlementAddition], Error> = spawn { try await self.rows("settlement_additions", order: "sort_order") }
            let deds: Task<[SettlementDeduction], Error> = spawn { try await self.rows("settlement_deductions", order: "sort_order") }
            let recurring: Task<[RecurringDeduction], Error> = spawn { try await self.rows("recurring_deductions", order: "created_at") }
            let advances: Task<[DriverAdvance], Error> = spawn { try await self.rows("driver_advances", order: "date") }
            let repayments: Task<[DriverAdvanceRepayment], Error> = spawn { try await self.rows("driver_advance_repayments", order: "date") }
            let audit: Task<[SettlementAuditEvent], Error> = spawn { try await self.rows("settlement_audit_events", order: "timestamp") }
            defer { settlements.cancel(); lines.cancel(); adds.cancel(); deds.cancel(); recurring.cancel(); advances.cancel(); repayments.cancel(); audit.cancel() }

            var ledger = SettlementLedger(
                settlements: try await settlements.value,
                loadLines: try await lines.value,
                additions: try await adds.value,
                deductions: try await deds.value,
                recurringDeductions: try await recurring.value,
                advances: try await advances.value,
                advanceRepayments: try await repayments.value,
                auditEvents: try await audit.value
            )
            ledger.reconcileAdvances()
            return ledger
        } catch {
            throw SettlementCloudError.wrap(error)
        }
    }

    /// All of the account's drivers, including inactive ones, so history keeps
    /// its names. Falls back to the legacy column list before the migration.
    func fetchDrivers() async throws -> [Driver] {
        do {
            let response = try await client.from("drivers")
                .select(Self.driverColumns)
                .order("name")
                .execute()
            return try SettlementRowCodec.decodeRows(Driver.self, from: response.data)
        } catch {
            let response = try await client.from("drivers")
                .select(Self.legacyDriverColumns)
                .order("name")
                .execute()
            return try SettlementRowCodec.decodeRows(Driver.self, from: response.data)
        }
    }

    // MARK: - Driver portal

    func fetchDriverPortalContext() async throws -> [DriverPortalContext] {
        do {
            let response = try await client.rpc("sph_driver_settlement_context").execute()
            return try SettlementRowCodec.decodeRows(DriverPortalContext.self, from: response.data)
        } catch {
            throw SettlementCloudError.wrap(error)
        }
    }

    /// A driver's view. RLS returns only approved / paid settlements for the
    /// drivers this user is linked to; the client filters again as a second
    /// line of defence.
    func fetchDriverLedger(linkedDriverIds: Set<UUID>) async throws -> SettlementLedger {
        guard !linkedDriverIds.isEmpty else { return .empty }
        let ids = linkedDriverIds.map { $0.uuidString.lowercased() }
        do {
            let sResponse = try await client.from("settlements")
                .select()
                .in("driver_id", values: ids)
                .in("status", values: [SettlementStatus.approved.rawValue, SettlementStatus.paid.rawValue])
                .order("settlement_period_end", ascending: false)
                .execute()
            let settlements = try SettlementRowCodec.decodeRows(Settlement.self, from: sResponse.data)
            let sids = settlements.compactMap(\.id).map { $0.uuidString.lowercased() }
            guard !sids.isEmpty else { return .empty }

            let lines: Task<[SettlementLoadLine], Error> = spawn { try await self.rows("settlement_loads", order: "sort_order", settlementIds: sids) }
            let adds: Task<[SettlementAddition], Error> = spawn { try await self.rows("settlement_additions", order: "sort_order", settlementIds: sids) }
            let deds: Task<[SettlementDeduction], Error> = spawn { try await self.rows("settlement_deductions", order: "sort_order", settlementIds: sids) }
            // RLS limits these to the linked driver's own advances.
            let advances: Task<[DriverAdvance], Error> = spawn { try await self.rows("driver_advances", order: "date") }
            let repayments: Task<[DriverAdvanceRepayment], Error> = spawn { try await self.rows("driver_advance_repayments", order: "date") }
            defer { lines.cancel(); adds.cancel(); deds.cancel(); advances.cancel(); repayments.cancel() }
            var ledger = SettlementLedger(
                settlements: settlements,
                loadLines: try await lines.value,
                additions: try await adds.value,
                deductions: try await deds.value,
                advances: (try? await advances.value) ?? [],
                advanceRepayments: (try? await repayments.value) ?? []
            )
            ledger.reconcileAdvances()
            let viewer = SettlementViewer(role: .driver, linkedDriverIds: linkedDriverIds)
            ledger = SettlementPermissions.scopedLedger(ledger, viewer: viewer)
            return ledger
        } catch {
            throw SettlementCloudError.wrap(error)
        }
    }

    /// Documents tied to a settlement or to its loads. For a driver account
    /// RLS returns only rate confirmations / BOLs / PODs and the statement.
    func fetchDocuments(settlementId: UUID, loadIds: [UUID]) async throws -> [TruckDocument] {
        do {
            var out: [TruckDocument] = []
            let bySettlement = try await client.from("documents")
                .select()
                .eq("settlement_id", value: settlementId.uuidString.lowercased())
                .execute()
            out += try SettlementRowCodec.decodeRows(TruckDocument.self, from: bySettlement.data)
            if !loadIds.isEmpty {
                let byLoad = try await client.from("documents")
                    .select()
                    .in("load_id", values: loadIds.map { $0.uuidString.lowercased() })
                    .execute()
                out += try SettlementRowCodec.decodeRows(TruckDocument.self, from: byLoad.data)
            }
            var seen: Set<UUID> = []
            return out.filter { doc in
                guard let id = doc.id, !seen.contains(id) else { return false }
                seen.insert(id)
                return true
            }
        } catch {
            throw SettlementCloudError.wrap(error)
        }
    }

    // MARK: - Write: settlements

    /// Persists one settlement (header + all lines) and the audit events that
    /// the workflow produced for it.
    func saveBundle(_ bundle: SettlementBundle, auditEvents: [SettlementAuditEvent]) async throws {
        guard let sid = bundle.settlement.id else { return }
        do {
            try await upsert("settlements", [bundle.settlement])
            try await upsert("settlement_loads", bundle.loadLines)
            try await upsert("settlement_additions", bundle.additions)
            try await upsert("settlement_deductions", bundle.deductions)
            try await prune("settlement_loads", settlementId: sid, keep: bundle.loadLines.map(\.id))
            try await prune("settlement_additions", settlementId: sid, keep: bundle.additions.map(\.id))
            try await prune("settlement_deductions", settlementId: sid, keep: bundle.deductions.map(\.id))
            try await insert("settlement_audit_events", auditEvents)
        } catch {
            throw SettlementCloudError.wrap(error)
        }
    }

    func applyTransition(_ outcome: SettlementTransitionOutcome) async throws {
        do {
            try await upsert("settlements", [outcome.settlement])
            if !outcome.repaymentIdsRemoved.isEmpty {
                try await client.from("driver_advance_repayments")
                    .delete()
                    .in("id", values: outcome.repaymentIdsRemoved.map { $0.uuidString.lowercased() })
                    .execute()
            }
            try await insert("driver_advance_repayments", outcome.repaymentsAdded)
            for advance in outcome.advancesTouched {
                try await patch("driver_advances", id: advance.id, fields: [
                    "recovered_amount": .double(advance.recoveredAmount.doubleValue),
                    "is_closed": .bool(advance.isClosed)
                ])
            }
            try await insert("settlement_audit_events", outcome.auditEvents)
        } catch {
            throw SettlementCloudError.wrap(error)
        }
    }

    // MARK: - Write: standing data

    func saveRecurring(_ rule: RecurringDeduction) async throws {
        do { try await upsert("recurring_deductions", [rule]) }
        catch { throw SettlementCloudError.wrap(error) }
    }

    func saveAdvance(_ advance: DriverAdvance) async throws {
        do { try await upsert("driver_advances", [advance]) }
        catch { throw SettlementCloudError.wrap(error) }
    }

    /// Deleting an advance that has already been recovered against is refused
    /// by the caller; this only removes never-used rows.
    func deleteAdvance(id: UUID) async throws {
        do {
            try await client.from("driver_advances").delete()
                .eq("id", value: id.uuidString.lowercased()).execute()
        } catch { throw SettlementCloudError.wrap(error) }
    }

    /// Puts loads that were flagged `settled` back to "Ready for Settlement"
    /// (void, reopen, or an approved settlement edited back to draft). Rows
    /// the user has since moved to another status are left alone.
    func releaseSettledLoads(_ loadIds: [UUID]) async throws {
        guard !loadIds.isEmpty else { return }
        do {
            try await client.from("loads")
                .update(["status": AnyJSON.string(LoadStatus.readyForSettlement.rawValue)])
                .in("id", values: loadIds.map { $0.uuidString.lowercased() })
                .eq("status", value: LoadStatus.settled.rawValue)
                .execute()
        } catch {
            throw SettlementCloudError.wrap(error)
        }
    }

    func savePaySettings(driverId: UUID, settings: DriverPaySettings) async throws {
        var fields: [String: AnyJSON] = [
            "settlement_type": .string(settings.settlementType.rawValue),
            "pay_on_gross_revenue": .bool(settings.payOnGrossRevenue)
        ]
        fields["pay_rule"] = try anyJSON(settings.payRule)
        fields["lease_config"] = try settings.leaseConfig.map { try anyJSON($0) } ?? .null
        if let truck = settings.defaultTruckNumber {
            fields["truck_number"] = .string(truck)
        }
        // Keep the legacy percent column in step so the existing paystub
        // screens show the same rate.
        if let pct = settings.payRule.components.first(where: { $0.kind == .percentOfGross })?.percent,
           settings.payRule.components.count == 1 {
            fields["pay_percentage"] = .double(NSDecimalNumber(decimal: pct).doubleValue)
            fields["pay_type"] = .string("percent")
        }
        do { try await patch("drivers", id: driverId, fields: fields) }
        catch { throw SettlementCloudError.wrap(error) }
    }

    func createDriver(_ driver: Driver) async throws -> Driver {
        do {
            let rows = try toAnyJSON([driver])
            let response = try await client.from("drivers")
                .insert(rows)
                .select(Self.legacyDriverColumns)
                .execute()
            guard let created = try SettlementRowCodec.decodeRows(Driver.self, from: response.data).first else {
                throw SettlementCloudError.underlying(NSError(domain: "SettlementCloudStore", code: 3))
            }
            return created
        } catch {
            throw SettlementCloudError.wrap(error)
        }
    }

    /// Links a vault document to a settlement object via the columns the
    /// migration added to `documents`.
    func linkDocument(_ link: SettlementDocumentLink) async throws {
        var fields: [String: AnyJSON] = [:]
        if let sid = link.settlementId { fields["settlement_id"] = .string(sid.uuidString.lowercased()) }
        switch link.target {
        case .addition:  fields["addition_id"] = .string(link.targetId.uuidString.lowercased())
        case .deduction: fields["deduction_id"] = .string(link.targetId.uuidString.lowercased())
        case .advance:   fields["advance_id"] = .string(link.targetId.uuidString.lowercased())
        case .load, .settlement, .expense: break
        }
        guard !fields.isEmpty else { return }
        do { try await patch("documents", id: link.documentId, fields: fields) }
        catch { throw SettlementCloudError.wrap(error) }
    }

    // MARK: - Helpers

    /// Starts a read on the main actor so the model types' main-actor
    /// `Decodable` conformances stay on their actor (2.3.3 builds with Swift 6
    /// and default MainActor isolation, where `async let` child tasks are
    /// nonisolated). The network wait still suspends, so reads run in
    /// parallel exactly as before.
    private func spawn<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) -> Task<T, Error> {
        Task { @MainActor in try await operation() }
    }

    private func rows<T: Decodable>(
        _ table: String,
        order: String,
        settlementIds: [String]? = nil
    ) async throws -> [T] {
        var query = client.from(table).select()
        if let settlementIds {
            query = query.in("settlement_id", values: settlementIds)
        }
        let response = try await query.order(order).execute()
        return try SettlementRowCodec.decodeRows(T.self, from: response.data)
    }

    private func toAnyJSON<T: Encodable>(_ rows: [T]) throws -> [[String: AnyJSON]] {
        let data = try SettlementRowCodec.encodeRows(rows)
        return try JSONDecoder().decode([[String: AnyJSON]].self, from: data)
    }

    private func anyJSON<T: Encodable>(_ value: T) throws -> AnyJSON {
        let data = try SettlementRowCodec.encoder.encode(value)
        return try JSONDecoder().decode(AnyJSON.self, from: data)
    }

    private func upsert<T: Encodable>(_ table: String, _ values: [T]) async throws {
        guard !values.isEmpty else { return }
        try await client.from(table)
            .upsert(try toAnyJSON(values), onConflict: "id")
            .execute()
    }

    private func insert<T: Encodable>(_ table: String, _ values: [T]) async throws {
        guard !values.isEmpty else { return }
        try await client.from(table)
            .insert(try toAnyJSON(values))
            .execute()
    }

    private func patch(_ table: String, id: UUID, fields: [String: AnyJSON]) async throws {
        try await client.from(table)
            .update(fields)
            .eq("id", value: id.uuidString.lowercased())
            .execute()
    }

    /// Removes child rows of `settlementId` whose id is not in `keep`.
    private func prune(_ table: String, settlementId: UUID, keep: [UUID]) async throws {
        var query = client.from(table)
            .delete()
            .eq("settlement_id", value: settlementId.uuidString.lowercased())
        if !keep.isEmpty {
            let list = "(" + keep.map { $0.uuidString.lowercased() }.joined(separator: ",") + ")"
            query = query.not("id", operator: .in, value: list)
        }
        try await query.execute()
    }
}
