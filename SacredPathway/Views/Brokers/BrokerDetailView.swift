import SwiftUI

struct BrokerDetailView: View {
    @EnvironmentObject var supabase: SupabaseService
    let broker: Broker
    @State private var contacts: [BrokerContact] = []
    @State private var loads: [Load] = []
    @State private var isLoading = true

    // Local-only extras (address + notes) — see LocalBrokerStore.swift
    @State private var address: String = ""
    @State private var notes: String = ""
    @State private var extrasDirty = false

    var avgRevenuePerLoad: Double {
        guard let total = broker.totalLoads, total > 0 else { return 0 }
        return (broker.totalRevenue ?? 0) / Double(total)
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    // Broker header card
                    brokerHeaderCard

                    // Stats grid
                    statsSection

                    // Address + notes (local-only)
                    extrasSection

                    // Contacts
                    contactsSection

                    // Load history
                    loadsSection
                }
                .padding()
            }
        }
        .navigationTitle(broker.brokerName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadData() }
        .onAppear(perform: loadExtras)
        .onDisappear(perform: persistExtrasIfDirty)
    }

    // MARK: - Address + notes (local-only via LocalBrokerStore)

    private var extrasSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(Color.spGold)
                Text("Address & Notes").font(.headline).foregroundStyle(Color.spGold)
                Spacer()
                if extrasDirty {
                    Button {
                        persistExtrasIfDirty()
                    } label: {
                        Text("Save")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.spGold)
                            .foregroundStyle(Color.spBlack)
                            .clipShape(Capsule())
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Address").font(.caption2).foregroundStyle(Color.spTextSecondary)
                TextField("123 Main St, City, ST 12345",
                          text: $address, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(10)
                    .background(Color.spCardBgLight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(Color.spTextPrimary)
                    .onChange(of: address) { _, _ in extrasDirty = true }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.caption2).foregroundStyle(Color.spTextSecondary)
                TextField("Detention policy, billing rules, etc.",
                          text: $notes, axis: .vertical)
                    .lineLimit(2...6)
                    .padding(10)
                    .background(Color.spCardBgLight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(Color.spTextPrimary)
                    .onChange(of: notes) { _, _ in extrasDirty = true }
            }
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func loadExtras() {
        guard let id = broker.id,
              let extras = LocalBrokerStore.extras(forBrokerId: id) else { return }
        address = extras.mailingAddress ?? ""
        notes   = extras.notes ?? ""
        extrasDirty = false
    }

    private func persistExtrasIfDirty() {
        guard extrasDirty, let id = broker.id else { return }
        LocalBrokerStore.save(.init(
            brokerId: id,
            mailingAddress: address.trimmingCharacters(in: .whitespaces).isEmpty ? nil : address,
            notes: notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes
        ))
        extrasDirty = false
    }

    private var brokerHeaderCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.spGold.opacity(0.15)).frame(width: 64, height: 64)
                Image(systemName: "building.2.fill").foregroundStyle(Color.spGold).font(.title)
            }
            // Broker name — long-press to copy
            Text(broker.brokerName)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.spTextPrimary)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = broker.brokerName
                    } label: { Label("Copy Broker Name", systemImage: "doc.on.doc") }
                }
            if let mc = broker.mcNumber {
                // MC# — long-press to copy
                Text("MC# \(mc)")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = mc
                        } label: { Label("Copy MC #", systemImage: "doc.on.doc") }
                    }
            }
            if let date = broker.createdAt {
                Text("First interaction: \(date, style: .date)")
                    .font(.caption2).foregroundStyle(Color.spTextSecondary)
            }

            // Copy-all button — bundles every field on the broker + its
            // primary contact into a single clipboard payload.
            Button {
                copyAllBrokerInfo()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc.fill").font(.caption)
                    Text("Copy All Contact Info").font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.spGold.opacity(0.18))
                .foregroundStyle(Color.spGoldLight)
                .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Builds a plain-text payload of every visible field on the broker +
    /// its most recent contact and writes it to the clipboard.
    private func copyAllBrokerInfo() {
        var lines: [String] = []
        lines.append(broker.brokerName)
        if let mc = broker.mcNumber, !mc.isEmpty { lines.append("MC# \(mc)") }
        if let primary = contacts.first {
            lines.append("")
            lines.append("Contact: \(primary.contactName)")
            if let phone = primary.phone, !phone.isEmpty {
                if let ext = primary.phoneExtension, !ext.isEmpty {
                    lines.append("Phone: \(phone) ext \(ext)")
                } else {
                    lines.append("Phone: \(phone)")
                }
            }
            if let email = primary.email, !email.isEmpty {
                lines.append("Email: \(email)")
            }
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "chart.bar.fill").foregroundStyle(Color.spGold)
                Text("Broker Stats").font(.headline).foregroundStyle(Color.spGold)
            }
            HStack(spacing: 12) {
                statCard("Total Revenue", (broker.totalRevenue ?? 0).asCurrency, color: .spGold)
                statCard("Total Loads", "\(broker.totalLoads ?? 0)", color: .spSuccess)
            }
            HStack(spacing: 12) {
                statCard("Avg/Load", avgRevenuePerLoad.asCurrency, color: Color(red: 0.2, green: 0.6, blue: 0.9))
                statCard("Contacts", "\(contacts.count)", color: .spWarning)
            }
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statCard(_ title: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.bold)).foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.spCardBgLight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @State private var contactsToast: String?

    private var contactsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(Color.spGold)
                Text("Contacts").font(.headline).foregroundStyle(Color.spGold)
                Spacer()
                if !contacts.isEmpty {
                    Button {
                        Task { await saveAllContactsToiPhone() }
                    } label: {
                        Label("Save All", systemImage: "person.crop.circle.badge.plus")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.spGold)
                            .foregroundStyle(Color.spBlack)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Text("\(contacts.count)").font(.caption).foregroundStyle(Color.spTextSecondary)
            }
            if let toast = contactsToast {
                Text(toast)
                    .font(.caption2)
                    .foregroundStyle(Color.spGoldLight)
                    .padding(.vertical, 2)
            }

            if contacts.isEmpty {
                Text("No contacts yet for this broker. Add them as you work new loads.")
                    .font(.caption).foregroundStyle(Color.spTextSecondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(contacts) { contact in
                    NavigationLink {
                        ContactDetailView(contact: contact, brokerName: broker.brokerName)
                            .environmentObject(supabase)
                    } label: {
                        contactRow(contact)
                    }
                }
            }
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func contactRow(_ contact: BrokerContact) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.spGreenAccent.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: "person.fill").foregroundStyle(Color.spGreenAccent).font(.subheadline)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.contactName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                HStack(spacing: 8) {
                    if let phone = contact.phone, !phone.isEmpty {
                        if let ext = contact.phoneExtension, !ext.isEmpty {
                            Text("\(phone) · ext \(ext)").font(.caption2).foregroundStyle(Color.spTextSecondary)
                        } else {
                            Text(phone).font(.caption2).foregroundStyle(Color.spTextSecondary)
                        }
                    }
                    if let email = contact.email, !email.isEmpty {
                        Text(email).font(.caption2).foregroundStyle(Color.spTextSecondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            if let date = contact.lastInteractionAt {
                Text(date, style: .date).font(.caption2).foregroundStyle(Color.spTextSecondary)
            }
        }
        // Long-press anywhere on the row → menu with per-field copies + Copy All.
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = contact.contactName
            } label: { Label("Copy Name", systemImage: "doc.on.doc") }
            if let phone = contact.phone, !phone.isEmpty {
                Button {
                    UIPasteboard.general.string = phone
                } label: { Label("Copy Phone", systemImage: "phone") }
                if let ext = contact.phoneExtension, !ext.isEmpty {
                    Button {
                        UIPasteboard.general.string = ext
                    } label: { Label("Copy Extension", systemImage: "number") }
                    Button {
                        UIPasteboard.general.string = "\(phone) ext \(ext)"
                    } label: { Label("Copy Phone + Ext", systemImage: "phone.fill") }
                }
            }
            if let email = contact.email, !email.isEmpty {
                Button {
                    UIPasteboard.general.string = email
                } label: { Label("Copy Email", systemImage: "envelope") }
            }
            Divider()
            Button {
                copyContactAll(contact)
            } label: { Label("Copy All Contact Info", systemImage: "doc.on.doc.fill") }
            Button {
                Task { await saveOneContactToiPhone(contact) }
            } label: { Label("Save to iPhone Contacts", systemImage: "person.crop.circle.badge.plus") }
        }
    }

    // MARK: - iPhone Contacts bridge

    /// Save a single broker contact card into the user's iPhone Contacts via
    /// `ContactsBridge`. Surfaces a transient toast inside the contacts
    /// section ("Saved · Maria Lopez" / "Permission denied"). Silent no-op
    /// if the user has declined Contacts permission previously — the bridge
    /// throws `.notAuthorized` and we render that as a friendly toast.
    @MainActor
    private func saveOneContactToiPhone(_ contact: BrokerContact) async {
        do {
            _ = try await ContactsBridge.save(contact: contact, company: broker.brokerName)
            contactsToast = "Saved · \(contact.contactName) to iPhone Contacts"
        } catch ContactsBridge.BridgeError.notAuthorized {
            contactsToast = "Allow Contacts in Settings → Privacy to save reps."
        } catch {
            contactsToast = "Couldn't save · \(error.localizedDescription)"
        }
        // Auto-dismiss toast after 4s so it doesn't linger.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            contactsToast = nil
        }
    }

    /// Save every contact attached to this broker into iPhone Contacts.
    /// Useful right after a Smart Scan creates two reps for the same TQL
    /// company — one tap and both end up in the user's address book.
    @MainActor
    private func saveAllContactsToiPhone() async {
        guard !contacts.isEmpty else { return }
        if await ContactsBridge.requestAccess() == false {
            contactsToast = "Allow Contacts in Settings → Privacy to save reps."
            return
        }
        var saved = 0
        for c in contacts {
            do {
                _ = try await ContactsBridge.save(contact: c, company: broker.brokerName)
                saved += 1
            } catch {
                // continue — partial-success is better than aborting on one bad row.
            }
        }
        contactsToast = "Saved \(saved) of \(contacts.count) to iPhone Contacts"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            contactsToast = nil
        }
    }

    /// Plain-text payload for a single contact card (rep + phone + ext +
    /// email + parent broker company + MC#).
    private func copyContactAll(_ contact: BrokerContact) {
        var lines: [String] = []
        lines.append(contact.contactName)
        lines.append(broker.brokerName)
        if let mc = broker.mcNumber, !mc.isEmpty { lines.append("MC# \(mc)") }
        if let phone = contact.phone, !phone.isEmpty {
            if let ext = contact.phoneExtension, !ext.isEmpty {
                lines.append("Phone: \(phone) ext \(ext)")
            } else {
                lines.append("Phone: \(phone)")
            }
        }
        if let email = contact.email, !email.isEmpty {
            lines.append("Email: \(email)")
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
    }

    private var loadsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image("SacredPathwayLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                Text("Load History").font(.headline).foregroundStyle(Color.spGold)
                Spacer()
                Text("\(loads.count) loads").font(.caption).foregroundStyle(Color.spTextSecondary)
            }

            if loads.isEmpty {
                Text("No loads linked to this broker yet.")
                    .font(.caption).foregroundStyle(Color.spTextSecondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(loads.prefix(10)) { load in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(load.loadNumber ?? "—")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.spTextPrimary)
                            Text("\(load.origin ?? "?") → \(load.destination ?? "?")")
                                .font(.caption).foregroundStyle(Color.spTextSecondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(load.totalRevenue?.asCurrency ?? "$0.00")
                                .font(.subheadline.weight(.bold)).foregroundStyle(Color.spGold)
                            if let miles = load.totalMiles, miles > 0 {
                                let rpm = (load.totalRevenue ?? 0) / miles
                                Text("$\(String(format: "%.2f", rpm))/mi")
                                    .font(.caption2).foregroundStyle(rpm >= 2.50 ? Color.spSuccess : Color.spWarning)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if load.id != loads.prefix(10).last?.id {
                        Divider().background(Color.spTextSecondary.opacity(0.2))
                    }
                }
            }
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func loadData() async {
        do {
            // Only fetch contacts if we have a persisted broker id. A random
            // UUID fallback would query against a non-existent broker and
            // silently return empty — confusing if the user expects contacts.
            if let brokerId = broker.id {
                contacts = try await supabase.fetchContacts(forBroker: brokerId)
            } else {
                contacts = []
            }
            loads = try await supabase.fetchLoadsForBroker(brokerName: broker.brokerName)
        } catch { print("Error: \(error)") }
        isLoading = false
    }
}
