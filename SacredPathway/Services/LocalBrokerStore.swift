import Foundation

/// Local-only side-store for the extra Broker contact fields that don't
/// exist in the Supabase `brokers` / `broker_contacts` schema yet.
///
/// The Broker / BrokerContact tables already cover:
///   * broker name, MC number, total loads / revenue   (Broker)
///   * contact name, email, phone                       (BrokerContact)
///
/// This store layers on:
///   * mailing address
///   * free-form notes
///
/// It is intentionally local-only (UserDefaults) so that v1 ships without a
/// DB migration. When server-side support lands, this file can be replaced
/// with a real Supabase column without touching any caller.
enum LocalBrokerStore {

    private static let key = "sp.local.broker_extras.v1"

    struct BrokerExtras: Codable, Equatable {
        var brokerId: UUID
        var mailingAddress: String?
        var notes: String?
    }

    // MARK: - Read / Write

    static func extras(forBrokerId id: UUID) -> BrokerExtras? {
        loadAll()[id]
    }

    static func save(_ extras: BrokerExtras) {
        var all = loadAll()
        all[extras.brokerId] = extras
        persist(all)
    }

    static func remove(brokerId: UUID) {
        var all = loadAll()
        all.removeValue(forKey: brokerId)
        persist(all)
    }

    // MARK: - Internal storage

    private static func loadAll() -> [UUID: BrokerExtras] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([BrokerExtras].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.map { ($0.brokerId, $0) })
    }

    private static func persist(_ dict: [UUID: BrokerExtras]) {
        let array = Array(dict.values)
        if let data = try? JSONEncoder().encode(array) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
