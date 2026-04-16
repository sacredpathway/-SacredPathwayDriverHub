import SwiftUI

struct BrokersListView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var brokers: [Broker] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var sortBy: SortOption = .revenue
    @State private var showingAddBroker = false

    enum SortOption: String, CaseIterable {
        case revenue = "Revenue"
        case loads = "Loads"
        case name = "Name"
        case recent = "Recent"
    }

    var filteredBrokers: [Broker] {
        var result = brokers
        if !searchText.isEmpty {
            result = result.filter { $0.brokerName.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortBy {
        case .revenue: result.sort { ($0.totalRevenue ?? 0) > ($1.totalRevenue ?? 0) }
        case .loads: result.sort { ($0.totalLoads ?? 0) > ($1.totalLoads ?? 0) }
        case .name: result.sort { $0.brokerName < $1.brokerName }
        case .recent: result.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        }
        return result
    }

    var topBrokerByRevenue: Broker? {
        brokers.max(by: { ($0.totalRevenue ?? 0) < ($1.totalRevenue ?? 0) })
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            NavigationStack {
                VStack(spacing: 0) {
                    // Search bar
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color.spTextSecondary)
                        TextField("Search brokers...", text: $searchText)
                            .foregroundStyle(Color.spTextPrimary)
                    }
                    .padding(10)
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                    .padding(.top, 8)

                    // Sort pills
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(SortOption.allCases, id: \.self) { option in
                                Button {
                                    withAnimation { sortBy = option }
                                } label: {
                                    Text(option.rawValue)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(sortBy == option ? Color.spGold : Color.spCardBg)
                                        .foregroundStyle(sortBy == option ? Color.spBlack : Color.spTextPrimary)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }

                    // Top broker highlight
                    if let top = topBrokerByRevenue, (top.totalRevenue ?? 0) > 0 {
                        HStack(spacing: 12) {
                            Image(systemName: "crown.fill").foregroundStyle(Color.spGold).font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Top Broker").font(.caption).foregroundStyle(Color.spTextSecondary)
                                Text(top.brokerName).font(.subheadline.weight(.semibold)).foregroundStyle(Color.spTextPrimary)
                            }
                            Spacer()
                            Text((top.totalRevenue ?? 0).asCurrency)
                                .font(.subheadline.weight(.bold)).foregroundStyle(Color.spGold)
                        }
                        .padding(12)
                        .background(Color.spGold.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal)
                    }

                    if isLoading {
                        Spacer()
                        ProgressView().tint(Color.spGold)
                        Spacer()
                    } else if filteredBrokers.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "building.2.fill").font(.system(size: 48)).foregroundStyle(Color.spTextSecondary)
                            Text("No brokers yet").font(.headline).foregroundStyle(Color.spTextSecondary)
                            Text("Scan a rate confirmation and broker info will be auto-detected")
                                .font(.subheadline).foregroundStyle(Color.spTextSecondary)
                                .multilineTextAlignment(.center).padding(.horizontal, 40)
                        }
                        Spacer()
                    } else {
                        List {
                            ForEach(filteredBrokers) { broker in
                                NavigationLink {
                                    BrokerDetailView(broker: broker)
                                        .environmentObject(supabase)
                                } label: {
                                    brokerRow(broker)
                                }
                                .listRowBackground(Color.spCardBg)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
                .navigationTitle("Brokers")
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            Text("\(brokers.count) brokers")
                                .font(.caption).foregroundStyle(Color.spTextSecondary)
                            Button { showingAddBroker = true } label: {
                                Image(systemName: "plus.circle.fill").foregroundStyle(Color.spGold).font(.title3)
                            }
                        }
                    }
                }
                .sheet(isPresented: $showingAddBroker, onDismiss: { Task { await loadBrokers() } }) {
                    AddBrokerView()
                        .environmentObject(supabase)
                }
                .task { await loadBrokers() }
            }
        }
    }

    private func brokerRow(_ broker: Broker) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.spGold.opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: "building.2.fill")
                    .foregroundStyle(Color.spGold)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(broker.brokerName)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.spTextPrimary)
                HStack(spacing: 12) {
                    Label("\(broker.totalLoads ?? 0) loads", systemImage: "truck.box.fill")
                        .font(.caption).foregroundStyle(Color.spTextSecondary)
                    if let mc = broker.mcNumber {
                        Text("MC# \(mc)").font(.caption).foregroundStyle(Color.spTextSecondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text((broker.totalRevenue ?? 0).asCurrency)
                    .font(.subheadline.weight(.bold)).foregroundStyle(Color.spGold)
                Text("total rev")
                    .font(.caption2).foregroundStyle(Color.spTextSecondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func loadBrokers() async {
        do { brokers = try await supabase.fetchBrokers() } catch { print("Error: \(error)") }
        isLoading = false
    }
}

// MARK: - Add Broker Manually

struct AddBrokerView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss

    @State private var brokerName = ""
    @State private var mcNumber = ""
    @State private var contactName = ""
    @State private var contactEmail = ""
    @State private var contactPhone = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        // Broker info
                        sectionCard("Broker Info") {
                            field("Broker Name", text: $brokerName, icon: "building.2.fill", placeholder: "e.g. CH Robinson")
                            field("MC Number", text: $mcNumber, icon: "number", placeholder: "e.g. 128156")
                        }

                        // Optional contact
                        sectionCard("Contact (Optional)") {
                            field("Contact Name", text: $contactName, icon: "person.fill", placeholder: "e.g. John Smith")
                            field("Email", text: $contactEmail, icon: "envelope.fill", placeholder: "john@broker.com", keyboard: .emailAddress)
                            field("Phone", text: $contactPhone, icon: "phone.fill", placeholder: "(555) 555-1234", keyboard: .phonePad)
                        }

                        if let error = errorMessage {
                            Text(error).font(.caption).foregroundStyle(Color.spDanger)
                        }

                        Button { Task { await save() } } label: {
                            HStack {
                                if isSaving { ProgressView().tint(Color.spBlack) }
                                Text(isSaving ? "Saving..." : "Add Broker")
                            }
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.spGold).foregroundStyle(Color.spBlack)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(brokerName.isEmpty || isSaving)
                        .padding(.horizontal)
                    }
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Add Broker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Color.spGold)
                }
            }
        }
    }

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Color.spGold)
            VStack(spacing: 14) { content() }
                .padding(16).background(Color.spCardBg).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal)
    }

    private func field(_ label: String, text: Binding<String>, icon: String, placeholder: String, keyboard: UIKeyboardType = .default) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.spGold).frame(width: 24)
            TextField(placeholder, text: text).keyboardType(keyboard).foregroundStyle(Color.spTextPrimary)
        }
        .padding(12).background(Color.spCardBgLight).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func save() async {
        guard let profileId = supabase.client.auth.currentUser?.id else { errorMessage = "Not signed in"; return }
        isSaving = true
        do {
            let broker = Broker(
                profileId: profileId,
                brokerName: brokerName,
                normalizedName: Broker.normalize(brokerName),
                mcNumber: mcNumber.isEmpty ? nil : mcNumber,
                totalLoads: 0,
                totalRevenue: 0
            )
            let created = try await supabase.createBroker(broker)

            // Add contact if provided
            if !contactName.isEmpty, let brokerId = created.id {
                let contact = BrokerContact(
                    brokerId: brokerId,
                    contactName: contactName,
                    email: contactEmail.isEmpty ? nil : contactEmail,
                    phone: contactPhone.isEmpty ? nil : contactPhone,
                    lastInteractionAt: Date()
                )
                _ = try await supabase.createContact(contact)
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
        isSaving = false
    }
}
