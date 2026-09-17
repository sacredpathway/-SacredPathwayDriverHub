import Foundation
import CoreLocation

enum SacredPathSyncState: Equatable {
    case localOnly
    case syncing
    case synced(Date)
    case failed(String)
}

@MainActor
final class SacredPathStore: ObservableObject {
    static let shared = SacredPathStore()

    @Published private(set) var savedStops: [SacredPathPlace] = []
    @Published private(set) var parkingReports: [String: SacredPathParkingReport] = [:]
    @Published private(set) var parkingReportSummaries: [String: SacredPathParkingReportSummary] = [:]
    @Published private(set) var syncState: SacredPathSyncState = .localOnly

    private let savedStopsKey = "sph.maps.roadsideStops.saved"
    private let parkingReportsKey = "sph.maps.roadsideStops.parkingReports"
    private let reportedStopSnapshotsKey = "sph.maps.roadsideStops.reportedStopSnapshots"
    private let pendingDeletedSavedStopIDsKey = "sph.maps.roadsideStops.pendingDeletedSavedStopIDs"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var reportedStopSnapshots: [String: SacredPathPlace] = [:]
    private var pendingDeletedSavedStopIDs: Set<String> = []

    private init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func isSaved(_ stop: SacredPathPlace) -> Bool {
        savedStops.contains { $0.id == stop.id }
    }

    func save(_ stop: SacredPathPlace) {
        guard !isSaved(stop) else { return }
        savedStops.insert(stop, at: 0)
        pendingDeletedSavedStopIDs.remove(stop.id)
        persistSavedStops()
        persistPendingDeletions()
    }

    func save(_ stop: SacredPathPlace, supabase: SupabaseService?, role: AccountRole?) async {
        save(stop)
        guard let context = remoteContext(supabase: supabase, role: role) else { return }
        do {
            try await upsertSavedStop(stop, context: context)
            syncState = .synced(Date())
        } catch {
            syncState = .failed("Saved locally. Cloud sync will retry when available.")
        }
    }

    func remove(_ stop: SacredPathPlace) {
        savedStops.removeAll { $0.id == stop.id }
        pendingDeletedSavedStopIDs.insert(stop.id)
        persistSavedStops()
        persistPendingDeletions()
    }

    func remove(_ stop: SacredPathPlace, supabase: SupabaseService?) async {
        remove(stop)
        guard let userID = supabase?.client.auth.currentUser?.id,
              let supabase else { return }
        do {
            try await deleteSavedStop(stopID: stop.id, userID: userID, supabase: supabase)
            pendingDeletedSavedStopIDs.remove(stop.id)
            persistPendingDeletions()
            syncState = .synced(Date())
        } catch {
            syncState = .failed("Removed locally. Cloud sync will retry when available.")
        }
    }

    func reportParking(_ status: ParkingReportStatus, for stop: SacredPathPlace) {
        reportParking(status, notes: nil, for: stop)
    }

    func reportParking(_ status: ParkingReportStatus, notes: String?, for stop: SacredPathPlace) {
        reportedStopSnapshots[stop.id] = stop
        let now = Date()
        parkingReports[stop.id] = SacredPathParkingReport(
            stopID: stop.id,
            status: status,
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            updatedAt: now
        )
        parkingReportSummaries[stop.id] = SacredPathParkingReportSummary.local(
            stopID: stop.id,
            status: status,
            updatedAt: now
        )
        persistReportedStopSnapshots()
        persistParkingReports()
    }

    func reportParking(_ status: ParkingReportStatus, notes: String?, for stop: SacredPathPlace, supabase: SupabaseService?, role: AccountRole?) async {
        reportParking(status, notes: notes, for: stop)
        guard let context = remoteContext(supabase: supabase, role: role),
              let report = parkingReports[stop.id] else { return }
        do {
            try await upsertParkingReport(report, stop: stop, context: context)
            syncState = .synced(Date())
        } catch {
            syncState = .failed("Parking report saved locally. Cloud sync will retry when available.")
        }
    }

    func syncIfPossible(
        supabase: SupabaseService?,
        role: AccountRole?,
        center: CLLocationCoordinate2D? = nil,
        radiusMeters: Int = 80_000
    ) async {
        guard let context = remoteContext(supabase: supabase, role: role) else {
            syncState = .localOnly
            return
        }

        syncState = .syncing
        do {
            try await pushLocalChanges(context: context)
            try await pullRemoteChanges(context: context, center: center, radiusMeters: radiusMeters)
            syncState = .synced(Date())
        } catch {
            syncState = .failed("Using saved local Sacred Path places until cloud sync reconnects.")
        }
    }

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: savedStopsKey),
           let decoded = try? decoder.decode([SacredPathPlace].self, from: data) {
            savedStops = decoded
        }
        if let data = defaults.data(forKey: parkingReportsKey),
           let decoded = try? decoder.decode([String: SacredPathParkingReport].self, from: data) {
            parkingReports = decoded
        }
        if let data = defaults.data(forKey: reportedStopSnapshotsKey),
           let decoded = try? decoder.decode([String: SacredPathPlace].self, from: data) {
            reportedStopSnapshots = decoded
        }
        parkingReportSummaries = Dictionary(
            uniqueKeysWithValues: parkingReports.values.map { report in
                (
                    report.stopID,
                    SacredPathParkingReportSummary.local(
                        stopID: report.stopID,
                        status: report.status,
                        updatedAt: report.updatedAt
                    )
                )
            }
        )
        pendingDeletedSavedStopIDs = Set(defaults.stringArray(forKey: pendingDeletedSavedStopIDsKey) ?? [])
    }

    private func persistSavedStops() {
        guard let data = try? encoder.encode(savedStops) else { return }
        UserDefaults.standard.set(data, forKey: savedStopsKey)
    }

    private func persistParkingReports() {
        guard let data = try? encoder.encode(parkingReports) else { return }
        UserDefaults.standard.set(data, forKey: parkingReportsKey)
    }

    private func persistReportedStopSnapshots() {
        guard let data = try? encoder.encode(reportedStopSnapshots) else { return }
        UserDefaults.standard.set(data, forKey: reportedStopSnapshotsKey)
    }

    private func persistPendingDeletions() {
        UserDefaults.standard.set(Array(pendingDeletedSavedStopIDs), forKey: pendingDeletedSavedStopIDsKey)
    }

    private func remoteContext(supabase: SupabaseService?, role: AccountRole?) -> SacredPathRemoteContext? {
        guard !AppMode.shared.isLocal,
              let supabase,
              supabase.isAuthenticated,
              let userID = supabase.client.auth.currentUser?.id,
              let mapsRole = mapsEligibleRole(role ?? supabase.currentProfile?.accountRole) else {
            return nil
        }
        return SacredPathRemoteContext(supabase: supabase, userID: userID, role: mapsRole)
    }

    private func mapsEligibleRole(_ role: AccountRole?) -> AccountRole? {
        guard role == .carrier || role == .ownerOperator else { return nil }
        return role
    }

    private func pushLocalChanges(context: SacredPathRemoteContext) async throws {
        for stopID in Array(pendingDeletedSavedStopIDs) {
            try await deleteSavedStop(stopID: stopID, userID: context.userID, supabase: context.supabase)
            pendingDeletedSavedStopIDs.remove(stopID)
            persistPendingDeletions()
        }

        for stop in savedStops where !pendingDeletedSavedStopIDs.contains(stop.id) {
            try await upsertSavedStop(stop, context: context)
        }

        for report in parkingReports.values {
            guard let stop = stop(for: report.stopID) else { continue }
            try await upsertParkingReport(report, stop: stop, context: context)
        }
    }

    private func pullRemoteChanges(
        context: SacredPathRemoteContext,
        center: CLLocationCoordinate2D?,
        radiusMeters: Int
    ) async throws {
        let remoteSaved: [SacredPathSavedPlaceRow] = try await context.supabase.client
            .from("roadside_saved_stops")
            .select()
            .order("updated_at", ascending: false)
            .execute()
            .value

        mergeSavedStops(remoteSaved.compactMap(\.sacredPathPlace))

        guard let center, CLLocationCoordinate2DIsValid(center) else { return }
        let summaries = try await fetchNearbyParkingReportSummaries(
            context: context,
            center: center,
            radiusMeters: radiusMeters
        )
        mergeParkingReportSummaries(summaries)
    }

    private func fetchNearbyParkingReportSummaries(
        context: SacredPathRemoteContext,
        center: CLLocationCoordinate2D,
        radiusMeters: Int
    ) async throws -> [SacredPathParkingReportSummaryRow] {
        let params = NearbyParkingReportsParams(
            latitude: center.latitude,
            longitude: center.longitude,
            radiusMeters: radiusMeters,
            sinceDays: 7,
            limit: 250
        )
        return try await context.supabase.client
            .rpc("sph_nearby_roadside_parking_report_summaries", params: params)
            .execute()
            .value
    }

    private func upsertSavedStop(_ stop: SacredPathPlace, context: SacredPathRemoteContext) async throws {
        let row = SacredPathSavedPlaceUpsert(stop: stop, userID: context.userID, role: context.role)
        try await context.supabase.client
            .from("roadside_saved_stops")
            .upsert(row, onConflict: "user_id,stop_id")
            .execute()
    }

    private func upsertParkingReport(_ report: SacredPathParkingReport, stop: SacredPathPlace, context: SacredPathRemoteContext) async throws {
        let row = SacredPathParkingReportUpsert(report: report, stop: stop, userID: context.userID, role: context.role)
        try await context.supabase.client
            .from("roadside_parking_reports")
            .upsert(row, onConflict: "user_id,stop_id")
            .execute()
    }

    private func deleteSavedStop(stopID: String, userID: UUID, supabase: SupabaseService) async throws {
        try await supabase.client
            .from("roadside_saved_stops")
            .delete()
            .eq("user_id", value: userID)
            .eq("stop_id", value: stopID)
            .execute()
    }

    private func mergeSavedStops(_ remoteStops: [SacredPathPlace]) {
        var seen = Set<String>()
        var merged: [SacredPathPlace] = []

        for stop in remoteStops + savedStops where !pendingDeletedSavedStopIDs.contains(stop.id) {
            guard !seen.contains(stop.id) else { continue }
            seen.insert(stop.id)
            merged.append(stop)
        }

        savedStops = merged
        persistSavedStops()
    }

    private func mergeParkingReports(_ remoteReports: [SacredPathParkingReport]) {
        var merged = parkingReports
        for report in remoteReports {
            if let local = merged[report.stopID], local.updatedAt > report.updatedAt {
                continue
            }
            merged[report.stopID] = report
        }
        parkingReports = merged
        persistParkingReports()
    }

    private func mergeParkingReportSummaries(_ remoteRows: [SacredPathParkingReportSummaryRow]) {
        var mergedReports = parkingReports
        var mergedSummaries = parkingReportSummaries

        for summary in remoteRows.compactMap(\.summary) {
            if let local = mergedReports[summary.stopID], local.updatedAt > summary.latestReportedAt {
                continue
            }

            mergedSummaries[summary.stopID] = summary
            mergedReports[summary.stopID] = SacredPathParkingReport(
                stopID: summary.stopID,
                status: summary.latestStatus,
                notes: nil,
                updatedAt: summary.latestReportedAt
            )
        }

        parkingReports = mergedReports
        parkingReportSummaries = mergedSummaries
        persistParkingReports()
    }

    private func stop(for stopID: String) -> SacredPathPlace? {
        savedStops.first { $0.id == stopID } ?? reportedStopSnapshots[stopID]
    }
}

struct SacredPathParkingReportSummary: Equatable {
    let stopID: String
    let latestStatus: ParkingReportStatus
    let latestReportedAt: Date
    let totalReports: Int
    let availableCount: Int
    let limitedCount: Int
    let fullCount: Int
    let unknownCount: Int

    static func local(stopID: String, status: ParkingReportStatus, updatedAt: Date) -> SacredPathParkingReportSummary {
        SacredPathParkingReportSummary(
            stopID: stopID,
            latestStatus: status,
            latestReportedAt: updatedAt,
            totalReports: 1,
            availableCount: status == .available ? 1 : 0,
            limitedCount: status == .limited ? 1 : 0,
            fullCount: status == .full ? 1 : 0,
            unknownCount: status == .unknown ? 1 : 0
        )
    }
}

private struct SacredPathRemoteContext {
    let supabase: SupabaseService
    let userID: UUID
    let role: AccountRole
}

private struct NearbyParkingReportsParams: Encodable {
    let latitude: Double
    let longitude: Double
    let radiusMeters: Int
    let sinceDays: Int
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case latitude = "p_latitude"
        case longitude = "p_longitude"
        case radiusMeters = "p_radius_meters"
        case sinceDays = "p_since_days"
        case limit = "p_limit"
    }
}

private struct SacredPathSavedPlaceUpsert: Encodable {
    let userID: UUID
    let accountRole: String
    let stopID: String
    let stopName: String
    let stopCategory: String
    let latitude: Double
    let longitude: Double
    let address: String?
    let phoneNumber: String?
    let url: String?
    let openStatus: String?
    let amenities: [String]
    let notes: String?
    let appleMapsName: String?
    let appleMapsPlaceID: String?
    let appleMapsURL: String?
    let appleMapsPointOfInterestCategory: String?

    init(stop: SacredPathPlace, userID: UUID, role: AccountRole) {
        self.userID = userID
        self.accountRole = role.rawValue
        self.stopID = stop.id
        self.stopName = stop.name
        self.stopCategory = stop.category.databaseValue
        self.latitude = stop.latitude
        self.longitude = stop.longitude
        self.address = stop.address
        self.phoneNumber = stop.phoneNumber
        self.url = stop.urlString
        self.openStatus = stop.openStatus
        self.amenities = stop.amenities
        self.notes = nil
        self.appleMapsName = stop.name
        self.appleMapsPlaceID = stop.appleMapsPlaceID
        self.appleMapsURL = stop.urlString
        self.appleMapsPointOfInterestCategory = stop.appleMapsPointOfInterestCategory
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case accountRole = "account_role"
        case stopID = "stop_id"
        case stopName = "stop_name"
        case stopCategory = "stop_category"
        case latitude
        case longitude
        case address
        case phoneNumber = "phone_number"
        case url
        case openStatus = "open_status"
        case amenities
        case notes
        case appleMapsName = "apple_maps_name"
        case appleMapsPlaceID = "apple_maps_place_id"
        case appleMapsURL = "apple_maps_url"
        case appleMapsPointOfInterestCategory = "apple_maps_point_of_interest_category"
    }
}

private struct SacredPathParkingReportUpsert: Encodable {
    let userID: UUID
    let accountRole: String
    let stopID: String
    let stopName: String
    let stopCategory: String
    let parkingStatus: String
    let notes: String?
    let latitude: Double
    let longitude: Double
    let address: String?
    let appleMapsName: String?
    let appleMapsPlaceID: String?
    let appleMapsURL: String?
    let appleMapsPointOfInterestCategory: String?
    let reportedAt: Date

    init(report: SacredPathParkingReport, stop: SacredPathPlace, userID: UUID, role: AccountRole) {
        self.userID = userID
        self.accountRole = role.rawValue
        self.stopID = report.stopID
        self.stopName = stop.name
        self.stopCategory = stop.category.databaseValue
        self.parkingStatus = report.status.rawValue
        self.notes = report.notes
        self.latitude = stop.latitude
        self.longitude = stop.longitude
        self.address = stop.address
        self.appleMapsName = stop.name
        self.appleMapsPlaceID = stop.appleMapsPlaceID
        self.appleMapsURL = stop.urlString
        self.appleMapsPointOfInterestCategory = stop.appleMapsPointOfInterestCategory
        self.reportedAt = report.updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case accountRole = "account_role"
        case stopID = "stop_id"
        case stopName = "stop_name"
        case stopCategory = "stop_category"
        case parkingStatus = "parking_status"
        case notes
        case latitude
        case longitude
        case address
        case appleMapsName = "apple_maps_name"
        case appleMapsPlaceID = "apple_maps_place_id"
        case appleMapsURL = "apple_maps_url"
        case appleMapsPointOfInterestCategory = "apple_maps_point_of_interest_category"
        case reportedAt = "reported_at"
    }
}

private struct SacredPathSavedPlaceRow: Decodable {
    let stopID: String
    let stopName: String
    let stopCategory: String
    let latitude: Double
    let longitude: Double
    let address: String?
    let phoneNumber: String?
    let url: String?
    let openStatus: String?
    let amenities: [String]?
    let appleMapsPlaceID: String?
    let appleMapsPointOfInterestCategory: String?

    var sacredPathPlace: SacredPathPlace? {
        guard let category = SacredPathCategory(databaseValue: stopCategory) else { return nil }
        return SacredPathPlace(
            id: stopID,
            name: stopName,
            category: category,
            latitude: latitude,
            longitude: longitude,
            address: address?.nilIfBlank ?? "Address unavailable",
            phoneNumber: phoneNumber,
            urlString: url,
            openStatus: openStatus,
            amenities: amenities ?? [],
            appleMapsPlaceID: appleMapsPlaceID,
            appleMapsPointOfInterestCategory: appleMapsPointOfInterestCategory
        )
    }

    enum CodingKeys: String, CodingKey {
        case stopID = "stop_id"
        case stopName = "stop_name"
        case stopCategory = "stop_category"
        case latitude
        case longitude
        case address
        case phoneNumber = "phone_number"
        case url
        case openStatus = "open_status"
        case amenities
        case appleMapsPlaceID = "apple_maps_place_id"
        case appleMapsPointOfInterestCategory = "apple_maps_point_of_interest_category"
    }
}

private struct SacredPathParkingReportRow: Decodable {
    let stopID: String
    let parkingStatus: String
    let notes: String?
    let updatedAt: Date

    var parkingReport: SacredPathParkingReport? {
        guard let status = ParkingReportStatus(rawValue: parkingStatus) else { return nil }
        return SacredPathParkingReport(
            stopID: stopID,
            status: status,
            notes: notes,
            updatedAt: updatedAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case stopID = "stop_id"
        case parkingStatus = "parking_status"
        case notes
        case updatedAt = "updated_at"
    }
}

private struct SacredPathParkingReportSummaryRow: Decodable {
    let stopID: String
    let latestStatus: String
    let latestReportedAt: Date
    let totalReports: Int
    let availableCount: Int
    let limitedCount: Int
    let fullCount: Int
    let unknownCount: Int

    var summary: SacredPathParkingReportSummary? {
        guard let status = ParkingReportStatus(rawValue: latestStatus) else { return nil }
        return SacredPathParkingReportSummary(
            stopID: stopID,
            latestStatus: status,
            latestReportedAt: latestReportedAt,
            totalReports: totalReports,
            availableCount: availableCount,
            limitedCount: limitedCount,
            fullCount: fullCount,
            unknownCount: unknownCount
        )
    }

    enum CodingKeys: String, CodingKey {
        case stopID = "stop_id"
        case latestStatus = "latest_status"
        case latestReportedAt = "latest_reported_at"
        case totalReports = "total_reports"
        case availableCount = "available_count"
        case limitedCount = "limited_count"
        case fullCount = "full_count"
        case unknownCount = "unknown_count"
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
