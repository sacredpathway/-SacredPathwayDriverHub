import SwiftUI

/// "Broker Contacts" — a flat, searchable directory of every broker
/// contact the user has scanned or entered. Lives under
/// Settings → Operations.
///
/// Data model: each row is a `Broker` (parent company) plus its newest
/// `BrokerContact` (phone, email, optional extension stored as a trailing
/// "x123" segment on the phone string).
///
/// Auto-add path: `SmartScanReviewView` silently inserts new contacts
/// whenever Smart Scan finds broker info that isn't already saved.
/// Dedupe priority: MC number → email/phone → broker name.
struct BrokerContactsListView: View {
    @EnvironmentObject var supabase: SupabaseService

    @State private var rows: [Row] = []
    @State private var isLoading = true
    @State private var search: String = ""
    @State private var errorMessage: String?

    /// iPhone Contacts import sheet state.
    @State private var showImportSheet = false
    @State private var importToast: String?

    /// One row in the directory view: broker + latest contact card.
    struct Row: Identifiable {
        let id: UUID
        let broker: Broker
        let contact: BrokerContact?
        /// Most recent load number this contact appears on (best-effort,
        /// optional). Populated when we already have it from the loads
        /// table; nil otherwise.
        let lastLoadReference: String?
    }

    var filteredRows: [Row] {
        guard !search.isEmpty else { return rows }
        let q = search.lowercased()
        return rows.filter { row in
            let parts: [String] = [
                row.broker.brokerName,
                row.broker.mcNumber ?? "",
                row.contact?.contactName ?? "",
                row.contact?.email ?? "",
                row.contact?.phone ?? "",
            ]
            return parts.joined(separator: " ").lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.spTextSecondary)
                    TextField("Search name, MC, email, or phone",
                              text: $search)
                        .foregroundStyle(Color.spTextPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(10)
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.top, 8)

                if isLoading {
                    Spacer()
                    ProgressView().tint(Color.spGold)
                    Spacer()
                } else if filteredRows.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.rectangle.stack")
                            .font(.system(size: 44))
                            .foregroundStyle(Color.spTextSecondary)
                        Text("No broker contacts yet")
                            .font(.headline)
                            .foregroundStyle(Color.spTextSecondary)
                        Text("Smart Scan a rate con and broker info is added here automatically.")
                            .font(.subheadline)
                            .foregroundStyle(Color.spTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button {
                            showImportSheet = true
                        } label: {
                            Label("Import from iPhone Contacts", systemImage: "person.crop.circle.badge.plus")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .background(Color.spGold)
                                .foregroundStyle(Color.spBlack)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(filteredRows) { row in
                            NavigationLink {
                                BrokerDetailView(broker: row.broker)
                                    .environmentObject(supabase)
                            } label: {
                                contactRow(row)
                            }
                            .listRowBackground(Color.spCardBg)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = row.broker.brokerName
                                } label: { Label("Copy Broker", systemImage: "doc.on.doc") }
                                if let mc = row.broker.mcNumber, !mc.isEmpty {
                                    Button {
                                        UIPasteboard.general.string = mc
                                    } label: { Label("Copy MC #", systemImage: "number") }
                                }
                                if let c = row.contact {
                                    Button {
                                        UIPasteboard.general.string = c.contactName
                                    } label: { Label("Copy Contact", systemImage: "person") }
                                    if let phone = c.phone, !phone.isEmpty {
                                        Button {
                                            UIPasteboard.general.string = phone
                                        } label: { Label("Copy Phone", systemImage: "phone") }
                                        if let ext = c.phoneExtension, !ext.isEmpty {
                                            Button {
                                                UIPasteboard.general.string = "\(phone) ext \(ext)"
                                            } label: { Label("Copy Phone + Ext", systemImage: "phone.fill") }
                                        }
                                    }
                                    if let email = c.email, !email.isEmpty {
                                        Button {
                                            UIPasteboard.general.string = email
                                        } label: { Label("Copy Email", systemImage: "envelope") }
                                    }
                                }
                                Divider()
                                Button {
                                    UIPasteboard.general.string = copyAllForRow(row)
                                } label: { Label("Copy All Contact Info", systemImage: "doc.on.doc.fill") }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .navigationTitle("Broker Contacts")
        .task { await reload() }
        .refreshable { await reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showImportSheet = true
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .foregroundStyle(Color.spGold)
                }
                .accessibilityLabel("Import from iPhone Contacts")
            }
        }
        .sheet(isPresented: $showImportSheet) {
            ImportContactsSheet(supabase: supabase) { imported in
                showImportSheet = false
                if imported > 0 {
                    importToast = "Imported \(imported) contact\(imported == 1 ? "" : "s")"
                    Task { await reload() }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        importToast = nil
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = importToast {
                Text(toast)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.spGold)
                    .foregroundStyle(Color.spBlack)
                    .clipShape(Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Row UI

    private func contactRow(_ row: Row) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.spGold.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: "building.2.fill")
                    .foregroundStyle(Color.spGold)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(row.broker.brokerName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                if let mc = row.broker.mcNumber, !mc.isEmpty {
                    Text("MC# \(mc)")
                        .font(.caption2)
                        .foregroundStyle(Color.spGoldLight)
                }
                if let c = row.contact {
                    if let phone = c.phone, !phone.isEmpty {
                        Text(phone)
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    if let email = c.email, !email.isEmpty {
                        Text(email)
                            .font(.caption2)
                            .foregroundStyle(Color.spTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let ref = row.lastLoadReference {
                    Text("Last load · \(ref)")
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// Plain-text payload for the "Copy All Contact Info" menu entry on
    /// a directory row — broker company + MC# + primary contact (name,
    /// phone, ext, email).
    private func copyAllForRow(_ row: Row) -> String {
        var lines: [String] = []
        lines.append(row.broker.brokerName)
        if let mc = row.broker.mcNumber, !mc.isEmpty { lines.append("MC# \(mc)") }
        if let c = row.contact {
            lines.append("")
            lines.append("Contact: \(c.contactName)")
            if let phone = c.phone, !phone.isEmpty {
                if let ext = c.phoneExtension, !ext.isEmpty {
                    lines.append("Phone: \(phone) ext \(ext)")
                } else {
                    lines.append("Phone: \(phone)")
                }
            }
            if let email = c.email, !email.isEmpty {
                lines.append("Email: \(email)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Data

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let brokers = try await supabase.fetchBrokers()
            // Fetch contacts in parallel; cap concurrency at 6 so we don't
            // pin Supabase if the user has hundreds of brokers.
            var built: [Row] = []
            for broker in brokers {
                guard let id = broker.id else { continue }
                let contacts = (try? await supabase.fetchContacts(forBroker: id)) ?? []
                let best = contacts.first  // already ordered last_interaction_at desc
                built.append(Row(
                    id: id,
                    broker: broker,
                    contact: best,
                    lastLoadReference: nil
                ))
            }
            // Sort by most recent activity (broker.updatedAt) for usefulness.
            rows = built.sorted { a, b in
                (a.broker.updatedAt ?? .distantPast) > (b.broker.updatedAt ?? .distantPast)
            }
        } catch {
            errorMessage = error.localizedDescription
            rows = []
        }
    }
}

#Preview {
    NavigationStack { BrokerContactsListView().environmentObject(SupabaseService()) }
}

// MARK: - Import from iPhone Contacts

/// Sheet that lets the user search their iPhone address book and import
/// matching cards as new broker contacts in Sacred Pathway. Each imported
/// row creates (or reuses) a `Broker` named after the contact's
/// organization (falling back to "(iPhone Contact)" if none), then attaches
/// a `BrokerContact` snapshot under it.
///
/// Auth handling: the underlying `ContactsBridge.search` prompts the user
/// the first time. If denied, this sheet renders an actionable empty
/// state pointing to Settings → Privacy → Contacts.
struct ImportContactsSheet: View {
    @ObservedObject var supabase: SupabaseService
    /// Fires when the sheet is dismissed via Cancel or Done. Argument is
    /// the number of contacts successfully imported.
    var onDone: (Int) -> Void

    @State private var query = ""
    @State private var results: [ImportedContact] = []
    @State private var selected: Set<String> = []
    @State private var isSearching = false
    @State private var permissionDenied = false
    @State private var didLoadInitial = false
    @State private var importInFlight = false
    @State private var importedThisSession = 0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Color.spTextSecondary)
                        TextField("Search iPhone Contacts",
                                  text: $query)
                            .foregroundStyle(Color.spTextPrimary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.words)
                            .submitLabel(.search)
                            .onSubmit { Task { await runSearch() } }
                        if !query.isEmpty {
                            Button { query = ""; results = [] } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.spTextSecondary)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                    .padding(.top, 8)

                    if permissionDenied {
                        permissionDeniedView
                    } else if !didLoadInitial {
                        Spacer()
                        ProgressView().tint(Color.spGold)
                        Spacer()
                    } else if results.isEmpty {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .font(.system(size: 40))
                                .foregroundStyle(Color.spTextSecondary)
                            Text(query.isEmpty
                                 ? "Type a name to search your iPhone Contacts."
                                 : "No matches in iPhone Contacts.")
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        Spacer()
                    } else {
                        List {
                            ForEach(results) { c in
                                Button { toggle(c.id) } label: { resultRow(c) }
                                    .listRowBackground(Color.spCardBg)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Import Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(importedThisSession) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await runImport() }
                    } label: {
                        if importInFlight { ProgressView() }
                        else { Text("Import (\(selected.count))") }
                    }
                    .disabled(selected.isEmpty || importInFlight)
                }
            }
            .alert("Import error",
                   isPresented: .constant(errorMessage != nil),
                   actions: {
                       Button("OK") { errorMessage = nil }
                   },
                   message: { Text(errorMessage ?? "") })
            .onChange(of: query) { _, _ in
                Task { await runSearch() }
            }
            .task {
                if !didLoadInitial { await runSearch() }
            }
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(Color.spTextSecondary)
            Text("Contacts access is off")
                .font(.headline)
                .foregroundStyle(Color.spTextPrimary)
            Text("Enable Sacred Pathway under Settings → Privacy → Contacts to import broker reps.")
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.spGold)
                    .foregroundStyle(Color.spBlack)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private func resultRow(_ c: ImportedContact) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.spGold.opacity(0.18)).frame(width: 36, height: 36)
                Image(systemName: selected.contains(c.id) ? "checkmark" : "person.fill")
                    .foregroundStyle(Color.spGold)
                    .font(.subheadline.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(c.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                if let org = c.organization {
                    Text(org).font(.caption2).foregroundStyle(Color.spGoldLight)
                }
                HStack(spacing: 8) {
                    if let phone = c.phone, !phone.isEmpty {
                        if let ext = c.phoneExtension, !ext.isEmpty {
                            Text("\(phone) · ext \(ext)").font(.caption2).foregroundStyle(Color.spTextSecondary)
                        } else {
                            Text(phone).font(.caption2).foregroundStyle(Color.spTextSecondary)
                        }
                    }
                    if let email = c.email, !email.isEmpty {
                        Text(email).font(.caption2).foregroundStyle(Color.spTextSecondary).lineLimit(1)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    // MARK: - Search + Import

    @MainActor
    private func runSearch() async {
        isSearching = true
        defer { isSearching = false; didLoadInitial = true }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; return }
        do {
            results = try await ContactsBridge.search(trimmed)
        } catch ContactsBridge.BridgeError.notAuthorized {
            permissionDenied = true
            results = []
        } catch {
            errorMessage = error.localizedDescription
            results = []
        }
    }

    @MainActor
    private func runImport() async {
        importInFlight = true
        defer { importInFlight = false }
        let picks = results.filter { selected.contains($0.id) }
        var importedCount = 0
        for pick in picks {
            do {
                try await importOne(pick)
                importedCount += 1
            } catch {
                // partial success — keep going
            }
        }
        importedThisSession += importedCount
        onDone(importedThisSession)
    }

    /// Find-or-create a broker for this contact, then attach a contact
    /// snapshot under it. Broker name = imported organization, or fallback
    /// to the contact's display name when no organization is set. Matches
    /// against existing brokers via `Broker.normalize(_:)` so "TQL" and
    /// "Total Quality Logistics" don't end up as two separate companies.
    private func importOne(_ c: ImportedContact) async throws {
        guard let profileId = supabase.client.auth.currentUser?.id else { return }
        let brokerName = (c.organization?.isEmpty == false ? c.organization! : c.displayName)
        let normalized = Broker.normalize(brokerName)

        // Try to find an existing broker by normalized name; otherwise create one.
        let broker: Broker
        if let lookup = try? await supabase.findBrokerByNormalizedName(normalized), let existing = lookup {
            broker = existing
        } else {
            let newBroker = Broker(
                profileId: profileId,
                brokerName: brokerName,
                normalizedName: normalized,
                mcNumber: nil,
                totalLoads: 0,
                totalRevenue: 0
            )
            broker = try await supabase.createBroker(newBroker)
        }
        guard let brokerId = broker.id else { return }

        // Avoid duplicates by name within the same broker.
        if let lookup = try? await supabase.findContact(brokerId: brokerId, name: c.displayName),
           lookup != nil {
            return
        }

        let contact = BrokerContact(
            brokerId: brokerId,
            contactName: c.displayName,
            email: c.email,
            phone: c.phone,
            phoneExtension: c.phoneExtension,
            lastInteractionAt: Date()
        )
        _ = try await supabase.createContact(contact)
    }
}
