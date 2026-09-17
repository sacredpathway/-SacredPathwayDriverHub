import Foundation
import Combine

// =============================================================================
//  LocalBrokerContactsRepository — Free Local Mode broker contacts (Phase B)
// -----------------------------------------------------------------------------
//  Mirrors SupabaseService's broker_contacts surface (fetchContacts(forBroker:),
//  findContact(brokerId:name:), createContact, updateContact).
//  Disk file: `Documents/DriverHub/broker_contacts.json`.
// =============================================================================

@MainActor
final class LocalBrokerContactsRepository: ObservableObject {

    static let shared = LocalBrokerContactsRepository()

    private let fileName = "broker_contacts.json"

    @Published private(set) var contacts: [BrokerContact] = []

    init() {
        reload()
    }

    // MARK: - Read

    func reload() {
        contacts = LocalStore.loadArray(BrokerContact.self, fileName: fileName)
        #if DEBUG
        print("[SP_DEBUG_LOCAL] LocalBrokerContactsRepository loaded \(contacts.count) contacts from disk")
        #endif
    }

    func fetchAll() async -> [BrokerContact] {
        contacts
    }

    func fetch(forBroker brokerId: UUID) async -> [BrokerContact] {
        contacts
            .filter { $0.brokerId == brokerId }
            .sorted { ($0.lastInteractionAt ?? .distantPast) > ($1.lastInteractionAt ?? .distantPast) }
    }

    func findContact(brokerId: UUID, name: String) -> BrokerContact? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return contacts.first {
            $0.brokerId == brokerId &&
            $0.contactName.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    // MARK: - Write

    @discardableResult
    func create(_ contact: BrokerContact) -> BrokerContact {
        var copy = contact
        if copy.id == nil { copy.id = UUID() }
        if copy.createdAt == nil { copy.createdAt = Date() }
        contacts.append(copy)
        flush()
        return copy
    }

    func update(_ contact: BrokerContact) {
        guard let id = contact.id, let idx = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[idx] = contact
        flush()
    }

    func delete(id: UUID) {
        let before = contacts.count
        contacts.removeAll { $0.id == id }
        if contacts.count != before { flush() }
    }

    /// Delete every contact owned by a broker — used when the parent broker
    /// is removed so we don't leave orphaned rows on disk.
    func deleteAll(forBroker brokerId: UUID) {
        let before = contacts.count
        contacts.removeAll { $0.brokerId == brokerId }
        if contacts.count != before { flush() }
    }

    func replaceAll(with newContacts: [BrokerContact]) {
        contacts = newContacts
        flush()
    }

    // MARK: - Persistence

    private func flush() {
        LocalStore.saveArray(contacts, fileName: fileName)
    }
}
