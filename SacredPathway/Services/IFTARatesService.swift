import Foundation

enum ReliableHTTPError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case retryExhausted
}

struct HTTPRetryPolicy: Sendable {
    let maximumRetries: Int
    let baseDelay: TimeInterval

    static let standard = HTTPRetryPolicy(maximumRetries: 2, baseDelay: 0.35)

    func shouldRetry(statusCode: Int) -> Bool {
        [408, 429, 500, 502, 503, 504].contains(statusCode)
    }

    func delay(attempt: Int, retryAfter: String?, jitter: Double = Double.random(in: 0...0.2)) -> TimeInterval {
        if let retryAfter, let seconds = TimeInterval(retryAfter), seconds >= 0 {
            return min(seconds, 30)
        }
        return min(baseDelay * pow(2, Double(attempt)) + jitter, 30)
    }
}

/// Shared read-only HTTP transport. Automatic retries are deliberately
/// limited to GET requests so submissions cannot be duplicated.
struct ReliableHTTPClient: Sendable {
    static let shared = ReliableHTTPClient()
    let session: URLSession
    let policy: HTTPRetryPolicy

    init(session: URLSession = .shared, policy: HTTPRetryPolicy = .standard) {
        self.session = session
        self.policy = policy
    }

    func data(for request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = request.timeoutInterval > 0 ? request.timeoutInterval : 10
        let isRetryableMethod = (request.httpMethod ?? "GET").uppercased() == "GET"
        var attempt = 0

        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ReliableHTTPError.invalidResponse
                }
                guard (200..<300).contains(http.statusCode) else {
                    guard isRetryableMethod,
                          attempt < policy.maximumRetries,
                          policy.shouldRetry(statusCode: http.statusCode)
                    else { throw ReliableHTTPError.httpStatus(http.statusCode) }
                    let delay = policy.delay(
                        attempt: attempt,
                        retryAfter: http.value(forHTTPHeaderField: "Retry-After")
                    )
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ReliableHTTPError {
                throw error
            } catch {
                guard isRetryableMethod, attempt < policy.maximumRetries,
                      (error as? URLError).map({
                          [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                           .cannotConnectToHost, .dnsLookupFailed].contains($0.code)
                      }) == true
                else { throw error }
                let delay = policy.delay(attempt: attempt, retryAfter: nil)
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from request: URLRequest,
                              decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        let data = try await data(for: request)
        return try decoder.decode(T.self, from: data)
    }
}

// =============================================================================
// IFTARatesService — official IFTA tax-rate table, remote-first
// -----------------------------------------------------------------------------
// WHY THIS EXISTS (Phase 1 financial-accuracy fix, 2026-07-04):
// `iftaJurisdictions` ships every jurisdiction with `taxRatePerGallon: 0.0`.
// Before this service, the IFTA report + CSV export computed and PRINTED
// "$0.00 tax owed" for every state — dangerously wrong for a tax document.
//
// This service loads the real quarterly rate matrix and overlays it on top of
// the static jurisdiction list (see `jurisdictionForCode` in
// IFTAJurisdiction.swift). Rates are intentionally NOT hardcoded in the app:
// IFTA, Inc. publishes a new matrix every quarter, and a stale bundled table
// is as wrong as a zero one. Instead:
//
//   1. REMOTE  — `config/ifta-rates.json` in the same public Supabase storage
//                bucket that already serves `force-update.json`. Update the
//                file once a quarter; every install picks it up on next open.
//   2. CACHE   — last successfully fetched payload, persisted locally so the
//                report keeps working offline.
//   3. NOTHING — if neither exists, `ratesAvailable == false` and the UI must
//                HIDE tax-owed output (never print $0). IFTAReportView renders
//                a "rates not loaded" banner in this state.
//
// PUBLISHING A QUARTERLY UPDATE (owner runbook):
//   • Download the official rate matrix from ifta.ch (IFTA Inc.) for the
//     current quarter. US diesel column, converted to $/gallon.
//   • Fill the JSON below and upload to Supabase Storage → `config` bucket as
//     `ifta-rates.json` (public read; service-role write — same as
//     force-update.json).
//
//   {
//     "quarter": "3Q2026",
//     "updated": "2026-07-01",
//     "source": "IFTA Inc. official rate matrix (US diesel, USD/gal)",
//     "rates": { "AL": 0.32, "AZ": 0.26, "AR": 0.285, ... "SK": 0.44 }
//   }
//
//   Keys are 2-letter jurisdiction codes matching `iftaJurisdictions`.
//   A payload with fewer than 40 jurisdictions is rejected as malformed.
//
// Thread-safety: `rate(for:)` is called synchronously from view bodies via
// `jurisdictionForCode`, while loading happens in an async task — the payload
// is guarded by a lock. UI observation happens through the @Published
// `status`, always mutated on the main actor.
// =============================================================================

final class IFTARatesService: ObservableObject, @unchecked Sendable {

    static let shared = IFTARatesService()

    // MARK: - Types

    struct RatesPayload: Codable, Equatable {
        let quarter: String            // e.g. "3Q2026" — shown in the report header
        let updated: String?           // ISO date the matrix was published
        let source: String?            // provenance string, shown in exports
        let rates: [String: Double]    // "AL" → 0.32 (USD per gallon, US diesel)
    }

    enum Status: Equatable {
        case unknown                   // not yet attempted
        case unavailable               // attempted; no remote and no cache
        case loaded(quarter: String)
    }

    // MARK: - Published state (main-actor mutations only)

    @Published private(set) var status: Status = .unknown

    // MARK: - Private storage

    private let lock = NSLock()
    private var _payload: RatesPayload?

    private var hasAttemptedLoad = false

    /// Minimum jurisdiction count for a payload to be considered a real
    /// matrix (48 US + 10 CA is the full set; 40 tolerates minor omissions).
    private let minimumJurisdictionCount = 40

    private init() {}

    // MARK: - Lookup (safe from any thread, cheap enough for view bodies)

    /// Official rate for a jurisdiction code, or nil when no matrix is loaded
    /// or the code is missing from the matrix. Callers must treat nil as
    /// "unknown", NOT as zero.
    func rate(for code: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return _payload?.rates[code.uppercased()]
    }

    /// True when a validated rate matrix (remote or cached) is active.
    var ratesAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return (_payload?.rates.count ?? 0) >= minimumJurisdictionCount
    }

    /// Label for report headers/exports, e.g. "3Q2026".
    var quarterLabel: String? {
        lock.lock(); defer { lock.unlock() }
        return _payload?.quarter
    }

    /// Provenance line for exports, e.g. the official-matrix source string.
    var sourceLabel: String? {
        lock.lock(); defer { lock.unlock() }
        return _payload?.source
    }

    // MARK: - Loading

    /// Remote-first load with cache fallback. Idempotent per launch; call from
    /// any IFTA screen's `.task`. Never throws — on total failure the status
    /// becomes `.unavailable` and tax output stays hidden.
    func loadIfNeeded(force: Bool = false) async {
        if hasAttemptedLoad && !force { return }
        hasAttemptedLoad = true

        if let remote = await fetchRemote() {
            apply(remote, persistToCache: true)
            return
        }
        if let cached = loadCache() {
            apply(cached, persistToCache: false)
            return
        }
        await MainActor.run { self.status = .unavailable }
    }

    // MARK: - Internals

    /// Validate + install a payload. Exposed at internal visibility so unit
    /// tests can drive the service without network or disk.
    func apply(_ payload: RatesPayload, persistToCache: Bool) {
        guard payload.rates.count >= minimumJurisdictionCount,
              !payload.quarter.trimmingCharacters(in: .whitespaces).isEmpty,
              payload.rates.values.allSatisfy({ $0 >= 0 && $0 < 5 }) // sanity: $/gal
        else {
            #if DEBUG
            print("[IFTARates] rejected malformed payload (\(payload.rates.count) rates)")
            #endif
            return
        }

        lock.lock()
        _payload = payload
        lock.unlock()

        if persistToCache { saveCache(payload) }

        let quarter = payload.quarter
        Task { @MainActor in
            self.status = .loaded(quarter: quarter)
        }
    }

    private func fetchRemote() async -> RatesPayload? {
        guard let url = URL(string: Config.supabaseURL.absoluteString
            + "/storage/v1/object/public/config/ifta-rates.json") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            return try await ReliableHTTPClient.shared.decode(RatesPayload.self, from: request)
        } catch {
            #if DEBUG
            print("[IFTARates] remote fetch failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    // MARK: - Cache

    private var cacheURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ifta_rates_cache.json")
    }

    private func loadCache() -> RatesPayload? {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RatesPayload.self, from: data)
    }

    private func saveCache(_ payload: RatesPayload) {
        guard let url = cacheURL,
              let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
