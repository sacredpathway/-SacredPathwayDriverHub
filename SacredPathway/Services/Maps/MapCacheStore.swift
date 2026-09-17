import Foundation

// =============================================================================
// MARK: - MapCacheStore
// -----------------------------------------------------------------------------
// Tiny, dependency-free disk cache for Codable snapshots (freight rates,
// weather, alert history). Provides the "offline cache support" requirement:
// the last good payload is written to Application Support and re-read on launch
// so the maps and cards show data instantly — and keep working with no network.
//
// This is intentionally generic and synchronous-on-a-background-actor. It does
// NOT use UserDefaults (payloads can be large) and is safe to call from async
// contexts. Each cache is one JSON file keyed by a stable name.
// =============================================================================

actor MapCacheStore {
    static let shared = MapCacheStore()

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("MapCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(for: key), options: .atomic)
    }

    func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    func remove(key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }
}

// Stable cache keys live here so producers and consumers never drift.
enum MapCacheKey {
    static let freightSnapshot = "freight_rate_snapshot_v1"
    static let weatherSnapshot = "weather_snapshot_v1"
    static let alertHistory    = "driver_alert_history_v1"
}
