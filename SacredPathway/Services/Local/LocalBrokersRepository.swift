import Foundation
import Combine

// =============================================================================
//  LocalBrokersRepository — Free Local Mode brokers store (Phase B)
// -----------------------------------------------------------------------------
//  Mirrors SupabaseService's brokers surface (`fetchBrokers`,
//  `findBrokerByNormalizedName`, `createBroker`, `updateBroker`).
//  Disk file: `Documents/DriverHub/brokers.json`.
// =============================================================================

@MainActor
final class LocalBrokersRepository: ObservableObject {

    static let shared = LocalBrokersRepository()

    private let fileName = "brokers.json"

    @Published private(set) var brokers: [Broker] = []

    init() {
        reload()
    }

    // MARK: - Read

    func reload() {
        brokers = LocalStore.loadArray(Broker.self, fileName: fileName)
        #if DEBUG
        print("[SP_DEBUG_LOCAL] LocalBrokersRepository loaded \(brokers.count) brokers from disk")
        #endif
    }

    func fetchAll() async -> [Broker] {
        brokers
    }

    func find(id: UUID) -> Broker? {
        brokers.first { $0.id == id }
    }

    /// Lookup by Broker.normalize-keyed name. Mirrors the cloud
    /// `findBrokerByNormalizedName` method so the MC smart-lookup and
    /// dedup logic from v2.0.2 work unchanged.
    func findByNormalizedName(_ normalized: String) -> Broker? {
        brokers.first {
            ($0.normalizedName ?? Broker.normalize($0.brokerName)) == normalized
        }
    }

    func findByMcNumber(_ mc: String) -> Broker? {
        brokers.first { $0.mcNumber == mc }
    }

    // MARK: - Write

    @discardableResult
    func create(_ broker: Broker) -> Broker {
        var copy = broker
        if copy.id == nil { copy.id = UUID() }
        if copy.createdAt == nil { copy.createdAt = Date() }
        copy.updatedAt = Date()
        brokers.append(copy)
        flush()
        return copy
    }

    func update(_ broker: Broker) {
        guard let id = broker.id, let idx = brokers.firstIndex(where: { $0.id == id }) else { return }
        var copy = broker
        copy.updatedAt = Date()
        brokers[idx] = copy
        flush()
    }

    func delete(id: UUID) {
        let before = brokers.count
        brokers.removeAll { $0.id == id }
        if brokers.count != before { flush() }
    }

    func replaceAll(with newBrokers: [Broker]) {
        brokers = newBrokers
        flush()
    }

    // MARK: - Persistence

    private func flush() {
        LocalStore.saveArray(brokers, fileName: fileName)
    }
}
