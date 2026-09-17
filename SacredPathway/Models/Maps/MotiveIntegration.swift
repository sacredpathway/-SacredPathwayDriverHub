import Foundation
import Security

// =============================================================================
// MARK: - Motive integration (READ-ONLY) — auth, sync, cache, service
// -----------------------------------------------------------------------------
// Motive (formerly KeepTruckin) stays the OFFICIAL ELD / hours-of-service log of
// record. Sacred Path Driver Hub only READS a user's *authorized* Motive data
// to display it and help plan trips. There are intentionally NO methods anywhere
// that write, edit, dispatch, update, or delete anything in Motive. Every
// network call below is an HTTP GET and is marked READ-ONLY.
//
// Components (per architecture spec):
//   * MotiveConfig            — placeholder config + dev/mock flag (no secrets)
//   * MotiveAuthManager       — Keychain token storage + expiry (no passwords)
//   * MotiveAPIClient         — read-only GET seam (+ mock data when unconfigured)
//   * MotiveSyncStore         — cached read-only snapshot + last-synced time
//   * MotiveIntegrationService— orchestration, connection state, Sync Now
//
// SECURITY: tokens live only in the Keychain; passwords are never stored;
// tokens, refresh tokens, driver IDs, and ELD data are never logged.
// =============================================================================

// MARK: - Config (placeholders only — never commit real secrets)

enum MotiveConfig {
    /// Motive Fleet API base URL. Left nil until a real integration is wired so
    /// the app runs against mock/dev data. Provide via build config /
    /// environment at integration time — do NOT hardcode production secrets.
    static let baseURL: URL? = {
        if let raw = ProcessInfo.processInfo.environment["MOTIVE_API_BASE_URL"],
           let url = URL(string: raw) {
            return url
        }
        return nil
    }()

    /// OAuth client id placeholder (read scopes only). Supplied at integration
    /// time; nil here so nothing real ships in the binary.
    static let oauthClientId: String? = ProcessInfo.processInfo.environment["MOTIVE_CLIENT_ID"]

    /// True once a real endpoint is configured. Until then the shell uses mock
    /// data so every screen is testable.
    static var isLiveConfigured: Bool { baseURL != nil }
}

// MARK: - Connection state

enum MotiveConnectionState: Equatable {
    case notConnected
    case connecting
    case connected
    case tokenExpired
    case syncFailed(String)

    var label: String {
        switch self {
        case .notConnected: return "Not Connected"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected"
        case .tokenExpired: return "Token Expired"
        case .syncFailed:   return "Sync Failed"
        }
    }

    var isConnected: Bool { self == .connected }
}

// MARK: - Auth manager (Keychain; no passwords)

/// Stores the Motive API/OAuth token securely in the iOS Keychain. Never stores
/// a Motive password. Never logs token material.
final class MotiveAuthManager: @unchecked Sendable {
    static let shared = MotiveAuthManager()

    private let service = "org.sacredpathway.driverhub.motive"
    private let tokenAccount = "motive_access_token"
    private let refreshAccount = "motive_refresh_token"
    private let expiryKey = "sph.motive.tokenExpiresAt"

    // MARK: Save (read scopes only — we request read-only authorization)

    /// Saves an access token (and optional refresh token + expiry). Password is
    /// never accepted or stored.
    func save(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
        let trimmed = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return }
        setKeychain(account: tokenAccount, value: trimmed)
        if let refreshToken, !refreshToken.isEmpty {
            setKeychain(account: refreshAccount, value: refreshToken)
        }
        if let expiresAt {
            UserDefaults.standard.set(expiresAt.timeIntervalSince1970, forKey: expiryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: expiryKey)
        }
    }

    func accessToken() -> String? { getKeychain(account: tokenAccount) }
    func refreshToken() -> String? { getKeychain(account: refreshAccount) }

    var hasToken: Bool { accessToken() != nil }

    /// True when an expiry was recorded and is in the past.
    var isExpired: Bool {
        let ts = UserDefaults.standard.double(forKey: expiryKey)
        guard ts > 0 else { return false }   // no expiry recorded → treat as valid
        return Date().timeIntervalSince1970 >= ts
    }

    var expiresAt: Date? {
        let ts = UserDefaults.standard.double(forKey: expiryKey)
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    func clear() {
        deleteKeychain(account: tokenAccount)
        deleteKeychain(account: refreshAccount)
        UserDefaults.standard.removeObject(forKey: expiryKey)
    }

    // MARK: Keychain primitives

    private func setKeychain(account: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        deleteKeychain(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func getKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Read-only API client (+ mock data)

enum MotiveFetchError: Error, Equatable {
    case notConnected
    case tokenExpired
    case notConfigured
    case unauthorizedScope     // Motive didn't grant this data type
    case http(Int)
    case transport(String)

    var message: String {
        switch self {
        case .notConnected:     return "Motive isn't connected."
        case .tokenExpired:     return "Your Motive token has expired. Reconnect in Settings."
        case .notConfigured:    return "Motive API isn't configured in this build (running in sample mode)."
        case .unauthorizedScope:return "Motive didn't authorize this data type for your account."
        case .http(let code):   return "Motive returned HTTP \(code)."
        case .transport(let m): return m
        }
    }
}

/// Thin REST seam. EVERY method here is READ-ONLY (HTTP GET). There are no POST/
/// PUT/PATCH/DELETE calls anywhere in this type by design.
struct MotiveAPIClient {
    let auth: MotiveAuthManager

    /// READ-ONLY generic GET. Returns mock data when no live endpoint is
    /// configured (dev shell), so screens are testable without real credentials.
    func get<T: Decodable>(_ path: String, as type: T.Type, mock: () -> T) async throws -> T {
        guard auth.hasToken else { throw MotiveFetchError.notConnected }
        guard !auth.isExpired else { throw MotiveFetchError.tokenExpired }

        guard MotiveConfig.isLiveConfigured, let base = MotiveConfig.baseURL,
              let url = URL(string: path, relativeTo: base) else {
            // Dev/mock mode: no real endpoint configured.
            return mock()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"   // READ-ONLY
        if let token = auth.accessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MotiveFetchError.transport("No response from Motive.")
            }
            switch http.statusCode {
            case 200...299: break
            case 401:       throw MotiveFetchError.tokenExpired
            case 403:       throw MotiveFetchError.unauthorizedScope
            default:        throw MotiveFetchError.http(http.statusCode)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch let e as MotiveFetchError {
            throw e
        } catch {
            throw MotiveFetchError.transport(error.localizedDescription)
        }
    }
}

// MARK: - Sync store (cached read-only snapshot)

/// Holds the last successfully-synced read-only snapshot + timestamp. Caches to
/// UserDefaults so the last view survives relaunch. No token material is ever
/// stored here.
@MainActor
final class MotiveSyncStore: ObservableObject {
    static let shared = MotiveSyncStore()

    @Published private(set) var snapshot: MotiveSnapshot = .empty
    @Published private(set) var lastSyncedAt: Date?
    /// Dev toggle: use realistic sample data while no live endpoint is wired.
    @Published var useSampleData: Bool {
        didSet { UserDefaults.standard.set(useSampleData, forKey: sampleKey) }
    }

    private let snapshotKey = "sph.motive.snapshot.v1"
    private let syncedKey = "sph.motive.lastSyncedAt"
    private let sampleKey = "sph.motive.useSampleData"

    init() {
#if DEBUG
        useSampleData = (UserDefaults.standard.object(forKey: sampleKey) as? Bool) ?? true
#else
        // Production must never present realistic demonstration data as live.
        useSampleData = false
        UserDefaults.standard.removeObject(forKey: sampleKey)
#endif
        let ts = UserDefaults.standard.double(forKey: syncedKey)
        lastSyncedAt = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        if let data = UserDefaults.standard.data(forKey: snapshotKey) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(MotiveSnapshot.self, from: data) {
                snapshot = decoded
            }
        }
    }

    func update(_ snapshot: MotiveSnapshot) {
        self.snapshot = snapshot
        lastSyncedAt = Date()
        persist()
    }

    func clear() {
        snapshot = .empty
        lastSyncedAt = nil
        UserDefaults.standard.removeObject(forKey: snapshotKey)
        UserDefaults.standard.removeObject(forKey: syncedKey)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            UserDefaults.standard.set(data, forKey: snapshotKey)
        }
        if let lastSyncedAt {
            UserDefaults.standard.set(lastSyncedAt.timeIntervalSince1970, forKey: syncedKey)
        }
    }
}

// MARK: - Integration service (orchestration)

/// The single entry point the app talks to. Observable so SwiftUI reflects
/// connection state. READ-ONLY: connect/disconnect manage local auth only; sync
/// performs read-only GETs (or mock reads). No Motive-side mutations exist.
@MainActor
final class MotiveIntegrationService: ObservableObject {
    static let shared = MotiveIntegrationService()

    @Published private(set) var state: MotiveConnectionState
    @Published private(set) var isSyncing = false

    private let auth = MotiveAuthManager.shared
    private let store = MotiveSyncStore.shared
    private lazy var client = MotiveAPIClient(auth: auth)

    init() {
        if !auth.hasToken {
            state = .notConnected
        } else if auth.isExpired {
            state = .tokenExpired
        } else {
            state = .connected
        }
    }

    var isConnected: Bool { auth.hasToken && !auth.isExpired }
    var lastSyncedAt: Date? { store.lastSyncedAt }

    // MARK: Connect / disconnect (local auth only — never touches Motive)

    /// Saves the user's read-only token locally. Validation happens on first
    /// sync. Password is never accepted.
    func connect(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
        auth.save(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
        state = auth.hasToken ? .connected : .syncFailed("Could not store the Motive token.")
    }

    func disconnect() {
        auth.clear()
        store.clear()
        state = .notConnected
    }

    // MARK: Sync Now (READ-ONLY)

    /// Pulls the user's authorized Motive data. Role controls scope:
    /// driver / owner-operator → own data only; carrier → also fleet vehicles
    /// IF Motive authorizes it. Read-only throughout.
    func syncNow(role: AccountRole) async {
        guard auth.hasToken else { state = .notConnected; return }
        guard !auth.isExpired else { state = .tokenExpired; return }

        isSyncing = true
        state = .connecting
        defer { isSyncing = false }

        do {
            var snapshot = MotiveSnapshot()
            snapshot.driver = try await client.get("users/me", as: MotiveDriver.self) {
                MotiveMock.driver(role: role)
            }
            snapshot.vehicle = try await client.get("vehicles/current", as: MotiveVehicle.self) {
                MotiveMock.vehicle
            }
            snapshot.location = try await client.get("vehicle_locations/current", as: MotiveVehicleLocation.self) {
                MotiveMock.location
            }
            snapshot.hos = try await client.get("hos/summary", as: MotiveHOSSummary.self) {
                MotiveMock.hos
            }
            snapshot.trips = try await client.get("driving_periods", as: [MotiveTrip].self) {
                MotiveMock.trips
            }
            snapshot.dvirs = try await client.get("inspection_reports", as: [MotiveDVIR].self) {
                MotiveMock.dvirs
            }
            snapshot.fuelEntries = try await client.get("fuel_purchases", as: [MotiveFuelEntry].self) {
                MotiveMock.fuel
            }
            snapshot.iftaByJurisdiction = try await client.get("ifta/summary", as: [MotiveIFTAJurisdiction].self) {
                MotiveMock.ifta
            }
            // Carrier-only fleet data — only if their authorization permits it.
            if role == .carrier {
                snapshot.fleetVehicles = (try? await client.get("fleet/vehicles", as: [MotiveVehicle].self) {
                    MotiveMock.fleet
                }) ?? []
            }

            store.update(snapshot)
            state = .connected
        } catch let e as MotiveFetchError {
            switch e {
            case .tokenExpired: state = .tokenExpired
            case .notConnected: state = .notConnected
            default:            state = .syncFailed(e.message)
            }
        } catch {
            state = .syncFailed(error.localizedDescription)
        }
    }

    // MARK: Planner bridge (READ-ONLY)

    /// Returns the cached/synced Motive HOS as the planner's `HOSStatus`, or nil
    /// to keep the user's manually-entered hours. Read-only.
    func prefillHOS() async -> HOSStatus? {
        if store.snapshot.hos == nil { await syncNow(role: .ownerOperator) }
        return store.snapshot.hos?.asHOSStatus()
    }
}

// MARK: - Mock / dev data (used until a live endpoint is wired)

enum MotiveMock {
    static func driver(role: AccountRole) -> MotiveDriver {
        MotiveDriver(id: "drv_sample", firstName: "Sample", lastName: "Driver",
                     email: "driver@example.com", phone: nil,
                     role: role == .carrier ? "fleet_admin" : "driver",
                     companyName: "Sacred Path Carrier LLC")
    }

    static let vehicle = MotiveVehicle(id: "veh_101", number: "101", make: "Freightliner",
                                       model: "Cascadia", year: 2022, vin: nil,
                                       licensePlate: nil, fuelType: "diesel")

    static let location = MotiveVehicleLocation(
        vehicleId: "veh_101", latitude: 35.1495, longitude: -90.0490,
        bearing: 90, speedMph: 62, fuelPercent: 64, odometerMiles: 412_330,
        description: "I-40 near Memphis, TN", locatedAt: Date()
    )

    static let hos = MotiveHOSSummary(
        driverId: "drv_sample", dutyStatus: "driving",
        driveTimeLeftMinutes: 6 * 60 + 30, shiftTimeLeftMinutes: 8 * 60,
        cycleTimeLeftMinutes: 44 * 60, breakTimeLeftMinutes: 3 * 60,
        updatedAt: Date()
    )

    static let trips: [MotiveTrip] = [
        MotiveTrip(id: "trp_1", driverId: "drv_sample", vehicleId: "veh_101",
                   startTime: Date().addingTimeInterval(-86_400), endTime: Date().addingTimeInterval(-72_000),
                   startLabel: "Dallas, TX", endLabel: "Little Rock, AR", distanceMiles: 318),
        MotiveTrip(id: "trp_2", driverId: "drv_sample", vehicleId: "veh_101",
                   startTime: Date().addingTimeInterval(-172_800), endTime: Date().addingTimeInterval(-158_000),
                   startLabel: "Houston, TX", endLabel: "Dallas, TX", distanceMiles: 239)
    ]

    static let dvirs: [MotiveDVIR] = [
        MotiveDVIR(id: "dvir_1", vehicleId: "veh_101", driverId: "drv_sample",
                   inspectionType: "pre_trip", status: "satisfactory", hasDefects: false,
                   inspectedAt: Date().addingTimeInterval(-21_600), location: "Memphis, TN")
    ]

    static let fuel: [MotiveFuelEntry] = [
        MotiveFuelEntry(id: "fuel_1", vehicleId: "veh_101", date: Date().addingTimeInterval(-90_000),
                        gallons: 142.6, totalCost: 537.0, jurisdiction: "TX", odometerMiles: 411_900)
    ]

    static let ifta: [MotiveIFTAJurisdiction] = [
        MotiveIFTAJurisdiction(jurisdiction: "TX", miles: 557, gallons: 86),
        MotiveIFTAJurisdiction(jurisdiction: "AR", miles: 318, gallons: 49),
        MotiveIFTAJurisdiction(jurisdiction: "TN", miles: 120, gallons: 18)
    ]

    static let fleet: [MotiveVehicle] = [
        vehicle,
        MotiveVehicle(id: "veh_102", number: "102", make: "Kenworth", model: "T680",
                      year: 2021, vin: nil, licensePlate: nil, fuelType: "diesel"),
        MotiveVehicle(id: "veh_103", number: "103", make: "Peterbilt", model: "579",
                      year: 2023, vin: nil, licensePlate: nil, fuelType: "diesel")
    ]
}
