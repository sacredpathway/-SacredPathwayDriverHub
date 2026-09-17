// Sacred Pathway Driver Hub — Connections feature (smallest safe link).
// Mirror of Dispatcher Hub: a Driver-side user finds a DISPATCHER by email →
// invite → accept/decline → 1:1 realtime chat. Backed by the shared new tables
// `user_connections` + `connection_messages` (RLS-enforced; the SECURITY DEFINER
// lookup RPC enforces opposite-side pairing).
//
// Gated by RemoteAppConfig.connectionsEnabled (DEFAULT OFF) at the call site, so
// shipping this changes NOTHING in the live Driver Hub until the remote flag flips.
// Requires supabase-swift >= 2.46.0 (realtimeV2 channel API).
//
// NOTE: Driver Hub injects `SupabaseService` via @EnvironmentObject (no singleton),
// so the services are `bind(_:)`-ed to that instance by the views.
import Foundation
import SwiftUI
import Supabase

// MARK: - Models

struct UserConnection: Identifiable, Decodable, Equatable {
    let id: UUID
    let requester_id: UUID
    let recipient_id: UUID
    let requester_role: String
    let recipient_role: String
    let status: String
    let created_at: Date?
}

struct ConnectionMessage: Identifiable, Decodable, Equatable {
    let id: UUID
    let connection_id: UUID
    let sender_id: UUID
    let body: String
    let created_at: Date?
    let read_at: Date?
}

struct ConnectableUser: Decodable, Equatable {
    let user_id: UUID
    let account_role: String
}

enum ConnectionError: LocalizedError {
    case notReady
    case notPending
    var errorDescription: String? {
        switch self {
        case .notReady: return "You must be signed in."
        case .notPending: return "This request was already handled or no longer exists."
        }
    }
}

// MARK: - ConnectionService

@MainActor
final class ConnectionService: ObservableObject {
    private weak var supabase: SupabaseService?
    func bind(_ s: SupabaseService) { supabase = s }

    private var client: SupabaseClient? { supabase?.client }
    private var myId: UUID? { supabase?.client.auth.currentUser?.id }
    private var myRole: String { SubscriptionService.shared.entitledAccountRole?.rawValue ?? "driver" }

    @Published private(set) var connections: [UserConnection] = []
    private var realtime: ConnectionRealtime?

    var acceptedContacts: [UserConnection] { connections.filter { $0.status == "accepted" } }
    var pendingInvites: [UserConnection] { connections.filter { $0.status == "pending" } }

    func otherPartyId(_ c: UserConnection) -> UUID {
        (c.requester_id == myId) ? c.recipient_id : c.requester_id
    }
    func isIncoming(_ c: UserConnection) -> Bool { c.recipient_id == myId }

    /// The other party's role, using only data already on the row (no UUID, no extra query).
    func otherPartyRole(_ c: UserConnection) -> String {
        let r = (c.requester_id == myId) ? c.recipient_role : c.requester_role
        return r.replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .capitalized
    }
    /// Friendly contact label that avoids raw UUIDs (e.g. "Dispatcher").
    func partyLabel(_ c: UserConnection) -> String {
        let role = otherPartyRole(c)
        return role.isEmpty ? "Connection" : role
    }
    /// Friendly invite label (e.g. "Dispatcher invite" / "Connection request").
    func inviteLabel(_ c: UserConnection) -> String {
        let role = otherPartyRole(c)
        return role.isEmpty ? "Connection request" : "\(role) invite"
    }

    func refresh() async {
        guard let client else { return }
        do {
            let rows: [UserConnection] = try await client.from("user_connections")
                .select()
                .order("created_at", ascending: false)
                .execute().value
            connections = rows
        } catch {
            // Appear-time fetch can race the auth session refresh right after the
            // app resumes — one short retry covers it instead of silently showing
            // an empty list until pull-to-refresh.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let rows: [UserConnection]? = try? await client.from("user_connections")
                .select()
                .order("created_at", ascending: false)
                .execute().value
            if let rows { connections = rows }
        }
    }

    /// Live updates for `user_connections` (accept/decline/new invite) so the
    /// list stays current without pull-to-refresh. Table-level + refetch, same
    /// pattern as chat realtime. Idempotent.
    func startRealtime() {
        guard let client, realtime == nil else { return }
        let rt = ConnectionRealtime(client: client)
        realtime = rt
        rt.subscribe(topic: "rt-user-connections", table: "user_connections") { [weak self] in
            await self?.refresh()
        }
    }
    func stopRealtime() async { await realtime?.stop(); realtime = nil }

    func findByEmail(_ email: String) async throws -> ConnectableUser? {
        guard let client else { throw ConnectionError.notReady }
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty else { return nil }
        let rows: [ConnectableUser] = try await client
            .rpc("sph_find_connectable_user", params: ["p_email": e])
            .execute().value
        return rows.first
    }

    private struct NewConnection: Encodable {
        let requester_id: UUID
        let recipient_id: UUID
        let requester_role: String
        let recipient_role: String
    }

    func sendInvite(to user: ConnectableUser) async throws {
        guard let client, let me = myId else { throw ConnectionError.notReady }
        let dto = NewConnection(requester_id: me, recipient_id: user.user_id,
                                requester_role: myRole, recipient_role: user.account_role)
        try await client.from("user_connections").insert(dto).execute()
        await refresh()
    }

    private struct StatusPatch: Encodable { let status: String }

    func accept(_ c: UserConnection) async throws {
        try await setStatus(c, to: "accepted")
    }
    func decline(_ c: UserConnection) async throws {
        try await setStatus(c, to: "declined")
    }

    /// Transition a *pending* request. The `.eq("status", "pending")` guard makes
    /// the update a no-op when the row was already handled elsewhere (or deleted/
    /// expired) instead of clobbering it; that case surfaces as `.notPending` so
    /// the UI can tell the user, and the refresh reconciles the stale list either
    /// way. Never crashes on a missing row — zero updated rows is a normal path.
    private func setStatus(_ c: UserConnection, to status: String) async throws {
        guard let client else { throw ConnectionError.notReady }
        do {
            let updated: [UserConnection] = try await client.from("user_connections")
                .update(StatusPatch(status: status))
                .eq("id", value: c.id)
                .eq("status", value: "pending")
                .select()
                .execute().value
            await refresh()
            if updated.isEmpty { throw ConnectionError.notPending }
        } catch let e as ConnectionError {
            throw e
        } catch {
            // Network/RLS/decoding failure — reconcile what we can, then surface.
            await refresh()
            throw error
        }
    }
}

// MARK: - MessageService

@MainActor
final class MessageService: ObservableObject {
    private weak var supabase: SupabaseService?
    func bind(_ s: SupabaseService) { supabase = s }

    private var client: SupabaseClient? { supabase?.client }
    private var myId: UUID? { supabase?.client.auth.currentUser?.id }

    @Published private(set) var messages: [ConnectionMessage] = []
    private var realtime: ConnectionRealtime?

    func load(connectionId: UUID) async {
        guard let client else { return }
        let rows: [ConnectionMessage]? = try? await client.from("connection_messages")
            .select()
            .eq("connection_id", value: connectionId)
            .order("created_at", ascending: true)
            .execute().value
        if let rows { messages = rows }
    }

    private struct NewMessage: Encodable {
        let connection_id: UUID
        let sender_id: UUID
        let body: String
    }

    func send(connectionId: UUID, body: String) async throws {
        guard let client, let me = myId else { throw ConnectionError.notReady }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Insert returning the created row and append it immediately (optimistic
        // echo) — the sender sees their bubble without waiting for the realtime
        // round-trip. The next realtime-triggered load() reconciles the list.
        let inserted: ConnectionMessage = try await client.from("connection_messages")
            .insert(NewMessage(connection_id: connectionId, sender_id: me, body: trimmed),
                    returning: .representation)
            .select()
            .single()
            .execute().value
        if !messages.contains(where: { $0.id == inserted.id }) {
            messages.append(inserted)
        }
    }

    func startRealtime(connectionId: UUID) {
        guard let client else { return }
        let rt = ConnectionRealtime(client: client)
        realtime = rt
        rt.subscribe(connectionId: connectionId) { [weak self] in
            await self?.load(connectionId: connectionId)
        }
    }
    func stopRealtime() async { await realtime?.stop(); realtime = nil }

    func isMine(_ m: ConnectionMessage) -> Bool { m.sender_id == myId }
}

// MARK: - Realtime (supabase-swift 2.46.0 realtimeV2; table-level + re-fetch)

@MainActor
final class ConnectionRealtime {
    private let client: SupabaseClient
    private var channel: RealtimeChannelV2?
    private var loopTask: Task<Void, Never>?

    init(client: SupabaseClient) { self.client = client }

    func subscribe(connectionId: UUID, onChange: @escaping () async -> Void) {
        subscribe(topic: "rt-conn-\(connectionId.uuidString)", table: "connection_messages", onChange: onChange)
    }

    /// Generic table-level subscription + refetch (also used for `user_connections`).
    func subscribe(topic: String, table: String, onChange: @escaping () async -> Void) {
        let ch = client.realtimeV2.channel(topic)
        let stream = ch.postgresChange(AnyAction.self, schema: "public", table: table)
        channel = ch
        loopTask = Task { [weak self] in
            try? await ch.subscribeWithError()
            for await _ in stream {
                if Task.isCancelled { break }
                await onChange()
            }
            _ = self
        }
    }
    func stop() async {
        loopTask?.cancel(); loopTask = nil
        if let ch = channel { await ch.unsubscribe() }
        channel = nil
    }
}

// MARK: - UI: Dispatchers (Contacts + Invites)

struct DriverConnectionsView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var service = ConnectionService()
    @State private var email = ""
    @State private var status: String?
    @State private var working = false
    /// Invite row currently being accepted/declined (disables both buttons on
    /// every row so a double-tap or second tap mid-flight can't double-submit).
    @State private var actingOn: UUID?
    @State private var inviteError: String?

    var body: some View {
        List {
            Section("Add a Dispatcher") {
                TextField("Dispatcher email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled(true)
                Button {
                    Task { await sendInvite() }
                } label: {
                    HStack { Image(systemName: "paperplane.fill"); Text("Send Invite") }
                }
                .disabled(working || email.trimmingCharacters(in: .whitespaces).isEmpty)
                if let status {
                    Text(status).font(.caption).foregroundStyle(Color.spTextSecondary)
                }
            }
            .listRowBackground(Color.spCardBg)

            if !service.pendingInvites.isEmpty {
                Section("Pending Invites") {
                    ForEach(service.pendingInvites) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.isIncoming(c) ? "Incoming invite" : "Invite sent")
                                    .font(.subheadline).foregroundStyle(Color.spTextPrimary)
                                Text(service.inviteLabel(c))
                                    .font(.caption).foregroundStyle(Color.spTextSecondary)
                            }
                            Spacer()
                            if service.isIncoming(c) {
                                if actingOn == c.id {
                                    ProgressView()
                                } else {
                                    Button("Accept") { Task { await respond(c, accept: true) } }
                                        .buttonStyle(.borderedProminent).tint(Color.spGold)
                                    Button("Decline", role: .destructive) { Task { await respond(c, accept: false) } }
                                        .buttonStyle(.bordered)
                                }
                            } else {
                                Text("Pending").font(.caption).foregroundStyle(Color.spTextSecondary)
                            }
                        }
                    }
                }
                .listRowBackground(Color.spCardBg)
            }

            Section("Dispatcher Contacts") {
                if service.acceptedContacts.isEmpty {
                    Text("No accepted dispatchers yet.")
                        .font(.caption).foregroundStyle(Color.spTextSecondary)
                } else {
                    ForEach(service.acceptedContacts) { c in
                        NavigationLink {
                            ConnectionChatView(connection: c, title: service.partyLabel(c))
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.circle.fill").foregroundStyle(Color.spGold)
                                Text(service.partyLabel(c))
                                    .foregroundStyle(Color.spTextPrimary)
                                Spacer()
                                Image(systemName: "bubble.left.fill")
                                    .font(.caption).foregroundStyle(Color.spTextSecondary)
                            }
                        }
                    }
                }
            }
            .listRowBackground(Color.spCardBg)
        }
        .scrollContentBackground(.hidden)
        .background(Color.spBackground.ignoresSafeArea())
        .navigationTitle("Dispatchers")
        .alert("Dispatcher Invite", isPresented: Binding(
            get: { inviteError != nil },
            set: { if !$0 { inviteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(inviteError ?? "")
        }
        .refreshable { await service.refresh() }
        .task {
            service.bind(supabase)
            await service.refresh()
            service.startRealtime()
        }
        .onDisappear { Task { await service.stopRealtime() } }
        .onChange(of: scenePhase) { _, phase in
            // Re-fetch when the app returns to the foreground — the realtime
            // socket may have died while suspended.
            if phase == .active { Task { await service.refresh() } }
        }
    }

    /// Accept/decline with explicit error surfacing — a failed or already-handled
    /// request shows an alert instead of silently doing nothing (the list is
    /// refreshed by the service either way, so stale rows disappear).
    private func respond(_ c: UserConnection, accept: Bool) async {
        guard actingOn == nil else { return }
        actingOn = c.id
        defer { actingOn = nil }
        do {
            if accept { try await service.accept(c) } else { try await service.decline(c) }
        } catch let e as ConnectionError {
            inviteError = e.errorDescription
        } catch {
            inviteError = accept
                ? "Couldn’t accept the invite. Check your connection and try again."
                : "Couldn’t decline the invite. Check your connection and try again."
        }
    }

    private func sendInvite() async {
        working = true; defer { working = false }
        status = nil
        do {
            guard let found = try await service.findByEmail(email) else {
                status = "No Dispatcher Hub user found with that email."; return
            }
            try await service.sendInvite(to: found)
            status = "Invite sent."
            email = ""
        } catch {
            status = "Couldn’t send invite. They may already be connected."
        }
    }
}

// MARK: - UI: 1:1 chat

struct ConnectionChatView: View {
    let connection: UserConnection
    let title: String
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var supabase: SupabaseService
    @StateObject private var service = MessageService()
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(service.messages) { m in
                            HStack {
                                if service.isMine(m) { Spacer(minLength: 40) }
                                Text(m.body)
                                    .foregroundStyle(Color.spTextPrimary)
                                    .padding(10)
                                    .background(service.isMine(m) ? Color.spGold.opacity(0.25) : Color.spCardBg)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                if !service.isMine(m) { Spacer(minLength: 40) }
                            }
                            .id(m.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: service.messages) { _, _ in
                    if let last = service.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let body = draft; draft = ""
                    Task { try? await service.send(connectionId: connection.id, body: body) }
                } label: { Image(systemName: "paperplane.fill") }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.spBackground.ignoresSafeArea())
        .task {
            service.bind(supabase)
            await service.load(connectionId: connection.id)
            service.startRealtime(connectionId: connection.id)
        }
        .onDisappear { Task { await service.stopRealtime() } }
        .onChange(of: scenePhase) { _, phase in
            // Re-fetch on foreground: realtime events are missed while the app is
            // suspended, leaving an already-open chat stale until reopened.
            if phase == .active { Task { await service.load(connectionId: connection.id) } }
        }
    }
}
