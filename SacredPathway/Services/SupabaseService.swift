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
        self.client = SupabaseClient(
            supabaseURL: Config.supabaseURL,
            supabaseKey: Config.supabaseAnonKey
        )

        // Immediately set loading to false after a short delay
        // This prevents the black screen from hanging
        Task { @MainActor in
            // Simple session check — no task group to avoid MainActor deadlock
            do {
                _ = try await self.client.auth.session
                self.isAuthenticated = true
                await self.fetchProfile()
            } catch {
                self.isAuthenticated = false
            }

            self.isLoading = false

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

    /// Sign in (or auto-create an account) using an Apple ID token returned
    /// by `ASAuthorizationAppleIDCredential`. Supabase upserts the user, so
    /// first-time and returning users both hit this same call.
    ///
    /// Requires the Apple provider to be enabled in Supabase Auth settings
    /// with the app's Services ID + secret. Until that's configured server-
    /// side this throws; LoginView shows a friendly "Apple sign-in isn't set
    /// up yet — use email instead" message.
    func signInWithApple(idToken: String, nonce: String) async throws {
        try await client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
    }

    /// Send a 6-digit one-time code to `email`. The user types it back into
    /// the app and `verifyEmailOTP` signs them in. No password needed.
    func sendEmailOTP(email: String) async throws {
        try await client.auth.signInWithOTP(
            email: email,
            shouldCreateUser: true
        )
    }

    /// Verify the 6-digit code from `sendEmailOTP` and complete sign-in.
    func verifyEmailOTP(email: String, token: String) async throws {
        try await client.auth.verifyOTP(
            email: email,
            token: token,
            type: .email
        )
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

    /// Delete a load and any documents/expenses linked to it via load_id.
    /// Supabase cascades aren't assumed — we wipe children first so the
    /// parent delete never fails on FK constraints.
    func deleteLoad(id loadId: UUID) async throws {
        try await client.from("documents")
            .delete()
            .eq("load_id", value: loadId)
            .execute()
        try await client.from("expenses")
            .delete()
            .eq("load_id", value: loadId)
            .execute()
        try await client.from("loads")
            .delete()
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
        // Verbose logging so the REAL root cause is visible in Xcode's
        // console instead of the generic "data couldn't be read" error
        // that Swift's JSONDecoder surfaces when anything goes sideways.
        #if DEBUG
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let body = try encoder.encode(expense)
            print("[createExpense] → POST /expenses body:\n\(String(data: body, encoding: .utf8) ?? "<bad utf8>")")
        } catch {
            print("[createExpense] could not encode for logging: \(error)")
        }
        #endif

        do {
            // Step 1: do the insert as raw Data so we can see the response
            // bytes before trying to decode them into an Expense.
            let raw = try await client.from("expenses")
                .insert(expense, returning: .representation)
                .select()
                .single()
                .execute()

            #if DEBUG
            let bodyStr = String(data: raw.data, encoding: .utf8) ?? "<bad utf8>"
            print("[createExpense] ← response body:\n\(bodyStr)")
            #endif

            // Step 2: decode the bytes we just logged.
            let decoder = JSONDecoder()
            do {
                return try decoder.decode(Expense.self, from: raw.data)
            } catch {
                #if DEBUG
                print("[createExpense] decode failed: \(error)")
                #endif
                throw error
            }
        } catch {
            #if DEBUG
            print("[createExpense] request failed: \(error)")
            #endif
            throw error
        }
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

    /// Full-row update — re-reads the row from the DB afterwards.
    func updateDocument(_ document: TruckDocument) async throws -> TruckDocument {
        guard let docId = document.id else { return document }
        let updated: TruckDocument = try await client.from("documents")
            .update(document)
            .eq("id", value: docId)
            .select()
            .single()
            .execute()
            .value
        return updated
    }

    /// Patch a small set of fields on a document row — used to record retry
    /// counts, move between statuses, and save user edits without shipping
    /// the whole TruckDocument back to the server.
    func patchDocument(id: UUID, fields: [String: AnyEncodable]) async throws {
        try await client.from("documents")
            .update(fields)
            .eq("id", value: id)
            .execute()
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

    /// Upload any supported document (image or PDF) to the private
    /// `documents` bucket. Every object lives under "<profile_id>/..." so
    /// Storage RLS enforces per-user isolation. Returns the storage path.
    @discardableResult
    func uploadDocument(data: Data, path: String, contentType: String) async throws -> String {
        try await client.storage
            .from(Config.documentsBucket)
            .upload(path, data: data, options: .init(contentType: contentType))
        return path
    }

    /// Backwards-compatible overload. Defaults to JPEG.
    @discardableResult
    func uploadDocument(data: Data, path: String) async throws -> String {
        try await uploadDocument(data: data, path: path, contentType: "image/jpeg")
    }

    /// Short-lived signed URL for fetching a private storage object.
    func signedURL(forPath path: String, expiresIn seconds: Int = 3600) async throws -> URL {
        try await client.storage
            .from(Config.documentsBucket)
            .createSignedURL(path: path, expiresIn: seconds)
    }

    func deleteStorageObject(path: String) async throws {
        _ = try await client.storage
            .from(Config.documentsBucket)
            .remove(paths: [path])
    }

    // MARK: - Compliance Documents

    func fetchComplianceDocuments() async throws -> [ComplianceDocument] {
        guard let userId = client.auth.currentUser?.id else { return [] }
        let documents: [ComplianceDocument] = try await client.from("compliance_documents")
            .select()
            .eq("profile_id", value: userId)
            .order("expiration_date", ascending: false)
            .execute()
            .value
        return documents
    }

    func createComplianceDocument(_ doc: ComplianceDocument) async throws -> ComplianceDocument {
        #if DEBUG
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let body = try encoder.encode(doc)
            print("[createComplianceDocument] → POST /compliance_documents body:\n\(String(data: body, encoding: .utf8) ?? "<bad utf8>")")
        } catch {
            print("[createComplianceDocument] could not encode for logging: \(error)")
        }
        #endif

        do {
            let raw = try await client.from("compliance_documents")
                .insert(doc, returning: .representation)
                .select()
                .single()
                .execute()

            #if DEBUG
            let bodyStr = String(data: raw.data, encoding: .utf8) ?? "<bad utf8>"
            print("[createComplianceDocument] ← response body:\n\(bodyStr)")
            #endif

            let decoder = JSONDecoder()
            do {
                return try decoder.decode(ComplianceDocument.self, from: raw.data)
            } catch {
                #if DEBUG
                print("[createComplianceDocument] decode failed: \(error)")
                #endif
                throw error
            }
        } catch {
            #if DEBUG
            print("[createComplianceDocument] request failed: \(error)")
            #endif
            throw error
        }
    }

    func updateComplianceDocument(_ doc: ComplianceDocument) async throws {
        guard let docId = doc.id else { return }
        try await client.from("compliance_documents")
            .update(doc)
            .eq("id", value: docId)
            .execute()
    }

    func deleteComplianceDocument(id docId: UUID) async throws {
        try await client.from("compliance_documents")
            .delete()
            .eq("id", value: docId)
            .execute()
    }

    func uploadComplianceFile(_ data: Data, mimeType: String) async throws -> String {
        guard let userId = client.auth.currentUser?.id else {
            throw NSError(domain: "SupabaseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }

        let ext = extensionForMimeType(mimeType)
        let fileName = "\(UUID().uuidString.lowercased()).\(ext)"
        // IMPORTANT: Postgres returns auth.uid()::text lowercased, and the
        // storage RLS policy compares the first path segment against it.
        // Swift's UUID interpolates uppercase by default, which causes the
        // policy to deny with "new row violates row-level security policy".
        // Always lowercase the UUID when building the storage path.
        let path = "\(userId.uuidString.lowercased())/\(fileName)"

        try await client.storage
            .from("compliance-docs")
            .upload(path, data: data, options: .init(contentType: mimeType))

        return path
    }

    func signedURLForCompliance(_ path: String) async throws -> URL {
        try await client.storage
            .from("compliance-docs")
            .createSignedURL(path: path, expiresIn: 3600)
    }

    // MARK: - IFTA Entries

    func fetchIFTAEntries() async throws -> [IFTAEntry] {
        guard let userId = client.auth.currentUser?.id else { return [] }
        let entries: [IFTAEntry] = try await client.from("ifta_entries")
            .select()
            .eq("profile_id", value: userId)
            .order("entry_date", ascending: false)
            .execute()
            .value
        return entries
    }

    func fetchIFTAEntries(forQuarter q: Int, year: Int) async throws -> [IFTAEntry] {
        guard let userId = client.auth.currentUser?.id else { return [] }
        let entries: [IFTAEntry] = try await client.from("ifta_entries")
            .select()
            .eq("profile_id", value: userId)
            .order("entry_date", ascending: false)
            .execute()
            .value

        // Filter client-side by quarter
        let quarter = quarterFromNumber(q, year: year)
        return entries.filter { quarter.contains($0.date) }
    }

    func createIFTAEntry(_ entry: IFTAEntry) async throws -> IFTAEntry {
        #if DEBUG
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let body = try encoder.encode(entry)
            print("[createIFTAEntry] → POST /ifta_entries body:\n\(String(data: body, encoding: .utf8) ?? "<bad utf8>")")
        } catch {
            print("[createIFTAEntry] could not encode for logging: \(error)")
        }
        #endif

        do {
            let raw = try await client.from("ifta_entries")
                .insert(entry, returning: .representation)
                .select()
                .single()
                .execute()

            #if DEBUG
            let bodyStr = String(data: raw.data, encoding: .utf8) ?? "<bad utf8>"
            print("[createIFTAEntry] ← response body:\n\(bodyStr)")
            #endif

            let decoder = JSONDecoder()
            do {
                return try decoder.decode(IFTAEntry.self, from: raw.data)
            } catch {
                #if DEBUG
                print("[createIFTAEntry] decode failed: \(error)")
                #endif
                throw error
            }
        } catch {
            #if DEBUG
            print("[createIFTAEntry] request failed: \(error)")
            #endif
            throw error
        }
    }

    func updateIFTAEntry(_ entry: IFTAEntry) async throws {
        guard let entryId = entry.id else { return }
        try await client.from("ifta_entries")
            .update(entry)
            .eq("id", value: entryId)
            .execute()
    }

    func deleteIFTAEntry(id entryId: UUID) async throws {
        try await client.from("ifta_entries")
            .delete()
            .eq("id", value: entryId)
            .execute()
    }

    // MARK: - Daily Inspections (DVIR)

    /// History list, most-recent first. Drives DailyInspectionListView.
    func fetchDailyInspections() async throws -> [DailyInspection] {
        guard let userId = client.auth.currentUser?.id else { return [] }
        let inspections: [DailyInspection] = try await client.from("daily_inspections")
            .select()
            .eq("profile_id", value: userId)
            .order("inspection_date", ascending: false)
            .order("created_at", ascending: false)
            .execute()
            .value
        return inspections
    }

    /// Single most-recent inspection for smart-default prefill on the add form.
    func fetchMostRecentInspection() async throws -> DailyInspection? {
        guard let userId = client.auth.currentUser?.id else { return nil }
        let rows: [DailyInspection] = try await client.from("daily_inspections")
            .select()
            .eq("profile_id", value: userId)
            .order("inspection_date", ascending: false)
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    func createDailyInspection(_ inspection: DailyInspection) async throws -> DailyInspection {
        #if DEBUG
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let body = try encoder.encode(inspection)
            print("[createDailyInspection] → POST /daily_inspections body:\n\(String(data: body, encoding: .utf8) ?? "<bad utf8>")")
        } catch {
            print("[createDailyInspection] could not encode for logging: \(error)")
        }
        #endif

        do {
            let raw = try await client.from("daily_inspections")
                .insert(inspection, returning: .representation)
                .select()
                .single()
                .execute()

            #if DEBUG
            let bodyStr = String(data: raw.data, encoding: .utf8) ?? "<bad utf8>"
            print("[createDailyInspection] ← response body:\n\(bodyStr)")
            #endif

            let decoder = JSONDecoder()
            do {
                return try decoder.decode(DailyInspection.self, from: raw.data)
            } catch {
                #if DEBUG
                print("[createDailyInspection] decode failed: \(error)")
                #endif
                throw error
            }
        } catch {
            #if DEBUG
            print("[createDailyInspection] request failed: \(error)")
            #endif
            throw error
        }
    }

    func updateDailyInspection(_ inspection: DailyInspection) async throws {
        guard let id = inspection.id else { return }
        try await client.from("daily_inspections")
            .update(inspection)
            .eq("id", value: id)
            .execute()
    }

    func deleteDailyInspection(id inspectionId: UUID) async throws {
        try await client.from("daily_inspections")
            .delete()
            .eq("id", value: inspectionId)
            .execute()
    }

    // MARK: - Helpers

    private func extensionForMimeType(_ mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "application/pdf": return "pdf"
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "bin"
        }
    }

    private func quarterFromNumber(_ q: Int, year: Int) -> IFTAQuarter {
        switch q {
        case 1: return .q1(year: year)
        case 2: return .q2(year: year)
        case 3: return .q3(year: year)
        default: return .q4(year: year)
        }
    }

    // MARK: - Edge Function invocation

    /// POST an arbitrary `Encodable` payload to a Supabase Edge Function
    /// using the currently authenticated user's access token. Returns the
    /// decoded response.
    ///
    /// Example:
    ///   let response: ExtractResponse = try await supabase.invokeFunction(
    ///       name: "extract-document",
    ///       body: ExtractRequest(documentId: id))
    func invokeFunction<Request: Encodable, Response: Decodable>(
        name: String,
        body: Request
    ) async throws -> Response {
        let session = try await client.auth.session
        let url = Config.supabaseURL
            .appendingPathComponent("functions/v1")
            .appendingPathComponent(name)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        #if DEBUG
        let reqBodyLen = request.httpBody?.count ?? 0
        print("[EdgeFunction][\(name)] POST bytes=\(reqBodyLen)")
        #endif

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            #if DEBUG
            print("[EdgeFunction][\(name)] non-HTTP response")
            #endif
            throw EdgeFunctionError.invalidResponse
        }

        #if DEBUG
        let bodyPreview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
        print("[EdgeFunction][\(name)] status=\(http.statusCode) bytes=\(data.count) body=\(bodyPreview)")
        #endif

        if !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw EdgeFunctionError.httpError(statusCode: http.statusCode, body: message)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data)
    }
}

// MARK: - Edge Function Errors

enum EdgeFunctionError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The backend returned an unexpected response."
        case .httpError(let code, let body):
            return "Backend error (\(code)): \(body)"
        }
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
