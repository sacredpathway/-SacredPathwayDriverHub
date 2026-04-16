import Foundation
import Supabase

@MainActor
class SupabaseService: ObservableObject {

    // The Supabase client — your connection to the backend
    let client: SupabaseClient

    // The currently logged-in user's profile
    @Published var currentProfile: Profile?

    // Auth state
    @Published var isAuthenticated = false
    @Published var isLoading = true

    init() {
        print("🔵 SupabaseService init starting")
        self.client = SupabaseClient(
            supabaseURL: Config.supabaseURL,
            supabaseKey: Config.supabaseAnonKey
        )

        // Immediately set loading to false after a short delay
        // This prevents the black screen from hanging
        Task { @MainActor in
            print("🔵 Task started — checking session")

            // Simple session check — no task group to avoid MainActor deadlock
            do {
                _ = try await self.client.auth.session
                print("🟢 Session found")
                self.isAuthenticated = true
                await self.fetchProfile()
            } catch {
                print("🔴 No session: \(error.localizedDescription)")
                self.isAuthenticated = false
            }

            self.isLoading = false
            print("🟢 Loading complete — isAuth: \(self.isAuthenticated)")

            // Listen for future auth state changes
            for await state in client.auth.authStateChanges {
                self.isAuthenticated = state.session != nil
                if state.session != nil {
                    await self.fetchProfile()
                } else {
                    self.currentProfile = nil
                }
            }
        }
    }

    // MARK: - Auth

    func signUp(email: String, password: String) async throws {
        try await client.auth.signUp(email: email, password: password)
    }

    func signIn(email: String, password: String) async throws {
        try await client.auth.signIn(email: email, password: password)
    }

    func signOut() async throws {
        try await client.auth.signOut()
        self.currentProfile = nil
        self.isAuthenticated = false
    }

    // MARK: - Profile

    func fetchProfile() async {
        guard let userId = client.auth.currentUser?.id else { return }
        do {
            let profile: Profile = try await client.from("profiles")
                .select()
                .eq("id", value: userId)
                .single()
                .execute()
                .value
            self.currentProfile = profile
        } catch {
            print("Error fetching profile: \(error)")
        }
    }

    func updateProfile(_ updates: [String: AnyEncodable]) async throws {
        guard let userId = client.auth.currentUser?.id else { return }
        try await client.from("profiles")
            .update(updates)
            .eq("id", value: userId)
            .execute()
        await fetchProfile()
    }

    // MARK: - Loads

    func fetchLoads() async throws -> [Load] {
        let loads: [Load] = try await client.from("loads")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
        return loads
    }

    func createLoad(_ load: Load) async throws -> Load {
        let created: Load = try await client.from("loads")
            .insert(load)
            .select()
            .single()
            .execute()
            .value
        return created
    }

    func updateLoad(_ load: Load) async throws {
        guard let loadId = load.id else { return }
        try await client.from("loads")
            .update(load)
            .eq("id", value: loadId)
            .execute()
    }

    // MARK: - Expenses

    func fetchExpenses(forLoad loadId: UUID) async throws -> [Expense] {
        let expenses: [Expense] = try await client.from("expenses")
            .select()
            .eq("load_id", value: loadId)
            .execute()
            .value
        return expenses
    }

    func fetchAllExpenses() async throws -> [Expense] {
        guard let userId = client.auth.currentUser?.id else { return [] }
        let expenses: [Expense] = try await client.from("expenses")
            .select()
            .eq("profile_id", value: userId)
            .order("created_at", ascending: false)
            .execute()
            .value
        return expenses
    }

    func createExpense(_ expense: Expense) async throws -> Expense {
        let created: Expense = try await client.from("expenses")
            .insert(expense)
            .select()
            .single()
            .execute()
            .value
        return created
    }

    func updateExpense(_ expense: Expense) async throws {
        guard let expenseId = expense.id else { return }
        try await client.from("expenses")
            .update(expense)
            .eq("id", value: expenseId)
            .execute()
    }

    func deleteExpense(_ expenseId: UUID) async throws {
        try await client.from("expenses")
            .delete()
            .eq("id", value: expenseId)
            .execute()
    }

    // MARK: - Drivers

    func fetchDrivers() async throws -> [Driver] {
        let drivers: [Driver] = try await client.from("drivers")
            .select()
            .eq("active", value: true)
            .order("name")
            .execute()
            .value
        return drivers
    }

    func createDriver(_ driver: Driver) async throws -> Driver {
        let created: Driver = try await client.from("drivers")
            .insert(driver)
            .select()
            .single()
            .execute()
            .value
        return created
    }

    // MARK: - Documents

    func fetchDocuments() async throws -> [TruckDocument] {
        guard let userId = client.auth.currentUser?.id else { return [] }
        let documents: [TruckDocument] = try await client.from("documents")
            .select()
            .eq("profile_id", value: userId)
            .order("created_at", ascending: false)
            .execute()
            .value
        return documents
    }

    func createDocument(_ document: TruckDocument) async throws -> TruckDocument {
        let created: TruckDocument = try await client.from("documents")
            .insert(document)
            .select()
            .single()
            .execute()
            .value
        return created
    }

    // MARK: - Settlements

    func fetchSettlements() async throws -> [Settlement] {
        let settlements: [Settlement] = try await client.from("settlements")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
        return settlements
    }

    func createSettlement(_ settlement: Settlement) async throws -> Settlement {
        let created: Settlement = try await client.from("settlements")
            .insert(settlement)
            .select()
            .single()
            .execute()
            .value
        return created
    }

    // MARK: - Brokers

    func fetchBrokers() async throws -> [Broker] {
        guard let userId = client.auth.currentUser?.id else { return [] }
        let brokers: [Broker] = try await client.from("brokers")
            .select()
            .eq("profile_id", value: userId)
            .order("total_revenue", ascending: false)
            .execute()
            .value
        return brokers
    }

    func findBrokerByNormalizedName(_ normalizedName: String) async throws -> Broker? {
        guard let userId = client.auth.currentUser?.id else { return nil }
        let brokers: [Broker] = try await client.from("brokers")
            .select()
            .eq("profile_id", value: userId)
            .eq("normalized_name", value: normalizedName)
            .execute()
            .value
        return brokers.first
    }

    func createBroker(_ broker: Broker) async throws -> Broker {
        let created: Broker = try await client.from("brokers")
            .insert(broker)
            .select()
            .single()
            .execute()
            .value
        return created
    }

    func updateBroker(_ broker: Broker) async throws {
        guard let brokerId = broker.id else { return }
        try await client.from("brokers")
            .update(broker)
            .eq("id", value: brokerId)
            .execute()
    }

    // MARK: - Broker Contacts

    func fetchContacts(forBroker brokerId: UUID) async throws -> [BrokerContact] {
        let contacts: [BrokerContact] = try await client.from("broker_contacts")
            .select()
            .eq("broker_id", value: brokerId)
            .order("last_interaction_at", ascending: false)
            .execute()
            .value
        return contacts
    }

    func findContact(brokerId: UUID, name: String) async throws -> BrokerContact? {
        let contacts: [BrokerContact] = try await client.from("broker_contacts")
            .select()
            .eq("broker_id", value: brokerId)
            .eq("contact_name", value: name)
            .execute()
            .value
        return contacts.first
    }

    func createContact(_ contact: BrokerContact) async throws -> BrokerContact {
        let created: BrokerContact = try await client.from("broker_contacts")
            .insert(contact)
            .select()
            .single()
            .execute()
            .value
        return created
    }

    func updateContact(_ contact: BrokerContact) async throws {
        guard let contactId = contact.id else { return }
        try await client.from("broker_contacts")
            .update(contact)
            .eq("id", value: contactId)
            .execute()
    }

    func fetchLoadsForBroker(brokerName: String) async throws -> [Load] {
        guard let userId = client.auth.currentUser?.id else { return [] }
        let loads: [Load] = try await client.from("loads")
            .select()
            .eq("profile_id", value: userId)
            .eq("broker_name", value: brokerName)
            .order("created_at", ascending: false)
            .execute()
            .value
        return loads
    }

    // MARK: - File Storage

    func uploadDocument(data: Data, path: String) async throws -> String {
        try await client.storage
            .from("documents")
            .upload(path, data: data, options: .init(contentType: "image/jpeg"))
        return path
    }
}

// Helper to encode mixed types in dictionaries
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init<T: Encodable>(_ wrapped: T) {
        _encode = { encoder in
            try wrapped.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
