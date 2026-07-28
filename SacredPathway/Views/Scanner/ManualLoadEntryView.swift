import SwiftUI

/// Manual entry form for adding AND editing loads without scanning.
///
/// - Pass `existingLoad: nil` (default) to create a brand-new load.
/// - Pass `existingLoad: someLoad` to edit that load; fields pre-fill from
///   it and Save performs an update instead of an insert.
struct ManualLoadEntryView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) var dismiss

    /// If set, the form edits this load instead of creating a new one.
    let existingLoad: Load?

    @State private var loadNumber = ""
    @State private var brokerName = ""
    @State private var brokerMcNumber = ""
    @State private var truckNumber = ""
    @State private var trailerNumber = ""
    @State private var origin = ""
    @State private var destination = ""
    @State private var totalMiles = ""
    @State private var lineHaulRate = ""
    @State private var fuelSurcharge = ""
    @State private var accessorialCharges = ""
    @State private var isSaving = false
    @State private var showSavedAlert = false
    @State private var errorMessage: String?
    @State private var didPrefill = false

    // Broker autocomplete
    @State private var savedBrokers: [Broker] = []
    @State private var matchedBroker: Broker?
    @State private var showAddBrokerPrompt = false

    init(existingLoad: Load? = nil) {
        self.existingLoad = existingLoad
    }

    /// True only when we're editing an existing row (has a real id).
    /// A duplicate template sets `existingLoad` but leaves its id nil so
    /// Save creates a fresh row — the UI should read "Add Load" / "Save
    /// Load" in that case, not "Edit Load" / "Save Changes".
    private var isEditing: Bool { existingLoad?.id != nil }

    private var computedRevenue: Double {
        (Double(lineHaulRate) ?? 0) +
        (Double(fuelSurcharge) ?? 0) +
        (Double(accessorialCharges) ?? 0)
    }

    private var ratePerMile: Double {
        let miles = Double(totalMiles) ?? 0
        guard miles > 0 else { return 0 }
        return computedRevenue / miles
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Load Info
                        sectionCard("Load Info") {
                            formField("Load #", text: $loadNumber, placeholder: "e.g. LD-2841", identifier: "load.form.loadNumber")
                            formField("Broker", text: $brokerName, placeholder: "e.g. CH Robinson", identifier: "load.form.broker")
                            brokerSuggestionStrip
                            formField("MC #", text: $brokerMcNumber, placeholder: "e.g. 128156", identifier: "load.form.brokerMC", keyboard: .numberPad)
                            if let m = matchedBroker {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(Color.spSuccess)
                                    Text("Matched · \(m.brokerName)")
                                        .font(.caption2)
                                        .foregroundStyle(Color.spSuccess)
                                    Spacer()
                                }
                            }
                        }

                        // Route
                        sectionCard("Route") {
                            formField("Origin", text: $origin, placeholder: "e.g. Atlanta, GA", identifier: "load.form.origin")
                            formField("Destination", text: $destination, placeholder: "e.g. Dallas, TX", identifier: "load.form.destination")
                            formField("Miles", text: $totalMiles, placeholder: "e.g. 780", identifier: "load.form.miles", keyboard: .decimalPad)
                        }

                        sectionCard("Equipment") {
                            formField("Truck #", text: $truckNumber, placeholder: "e.g. 101", identifier: "load.form.truckNumber")
                            formField("Trailer #", text: $trailerNumber, placeholder: "e.g. TRL55", identifier: "load.form.trailerNumber")
                        }

                        // Revenue
                        sectionCard("Revenue") {
                            formField("Line Haul", text: $lineHaulRate, placeholder: "0.00", identifier: "load.form.lineHaul", keyboard: .decimalPad, prefix: "$")
                            formField("Fuel Surcharge", text: $fuelSurcharge, placeholder: "0.00", identifier: "load.form.fuelSurcharge", keyboard: .decimalPad, prefix: "$")
                            formField("Accessorials", text: $accessorialCharges, placeholder: "0.00", identifier: "load.form.accessorials", keyboard: .decimalPad, prefix: "$")

                            Divider()
                                .background(Color.spCardBgLight)

                            HStack {
                                Text("Total Revenue")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.spTextPrimary)
                                Spacer()
                                Text("$\(computedRevenue, specifier: "%.2f")")
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .foregroundStyle(Color.spGold)
                            }

                            if ratePerMile > 0 {
                                HStack {
                                    Text("Rate/Mile")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                    Spacer()
                                    Text("$\(ratePerMile, specifier: "%.2f")/mi")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(ratePerMile >= 2.50 ? Color.spSuccess : Color.spWarning)
                                }
                            }
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Color.spDanger)
                                .padding(.horizontal)
                        }

                        // Save button
                        Button(action: saveLoad) {
                            if isSaving {
                                ProgressView()
                                    .tint(Color.spBlack)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                            } else {
                                Label(isEditing ? "Save Changes" : "Save Load",
                                      systemImage: "checkmark.circle.fill")
                                    .fontWeight(.bold)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .foregroundStyle(Color.spBlack)
                            }
                        }
                        .background(Color.spGold)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier(isEditing ? "load.form.saveChanges" : "load.form.save")
                        .disabled(isSaving)
                        .padding(.horizontal)
                        .padding(.bottom, 32)
                    }
                    .padding(.top, 12)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(isEditing ? "Edit Load" : "Add Load")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.spBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.spGoldLight)
                        .accessibilityIdentifier("load.form.cancel")
                }
            }
            .alert(isEditing ? "Changes Saved!" : "Load Saved!",
                   isPresented: $showSavedAlert) {
                Button("OK") { dismiss() }
            } message: {
                Text(isEditing
                     ? "Load \(loadNumber.isEmpty ? "" : loadNumber + " ")updated successfully."
                     : "Load \(loadNumber.isEmpty ? "" : loadNumber + " ")added successfully.")
            }
            .alert("Add this broker to contacts?",
                   isPresented: $showAddBrokerPrompt) {
                Button("Skip") { showSavedAlert = true }
                Button("Add Broker") { Task { await addBrokerAndFinish() } }
            } message: {
                Text("\(brokerName) isn't in your broker list. Save it for one-tap selection on future loads?")
            }
            .onAppear(perform: prefillIfNeeded)
            .task { await loadBrokers() }
            .onChange(of: brokerName) { _, _ in updateMatchedBroker() }
        }
    }

    // MARK: - Broker autocomplete

    private var brokerSuggestionStrip: some View {
        let lower = brokerName.lowercased().trimmingCharacters(in: .whitespaces)
        let suggestions: [Broker] = lower.isEmpty
            ? []
            : Array(savedBrokers.filter {
                $0.brokerName.lowercased().contains(lower) &&
                $0.brokerName.lowercased() != lower
            }.prefix(3))
        return Group {
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.id) { b in
                            Button {
                                brokerName = b.brokerName
                                if brokerMcNumber.isEmpty, let mc = b.mcNumber {
                                    brokerMcNumber = mc
                                }
                                matchedBroker = b
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "building.2.fill")
                                        .font(.caption2)
                                    Text(b.brokerName)
                                        .font(.caption)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.spGold.opacity(0.18))
                                .foregroundStyle(Color.spGoldLight)
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    private func loadBrokers() async {
        // Free Local Mode reads brokers from the on-device repo.
        if AppMode.shared.isLocal {
            savedBrokers = await LocalBrokersRepository.shared.fetchAll()
            updateMatchedBroker()
            return
        }
        do {
            savedBrokers = try await supabase.fetchBrokers()
            updateMatchedBroker()
        } catch {
            // Non-fatal; manual entry still works without broker list.
        }
    }

    private func updateMatchedBroker() {
        let trimmed = brokerName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            matchedBroker = nil
            return
        }
        let target = Broker.normalize(trimmed)
        if let m = savedBrokers.first(where: {
            ($0.normalizedName ?? Broker.normalize($0.brokerName)) == target
        }) {
            matchedBroker = m
            if brokerMcNumber.isEmpty, let mc = m.mcNumber { brokerMcNumber = mc }
        } else {
            matchedBroker = nil
        }
    }

    private func addBrokerAndFinish() async {
        let trimmed = brokerName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { showSavedAlert = true; return }

        // Free Local Mode — write directly to on-device repo.
        if AppMode.shared.isLocal {
            let installId = AppMode.shared.localInstallId
            let broker = Broker(
                profileId: installId,
                brokerName: trimmed,
                normalizedName: Broker.normalize(trimmed),
                mcNumber: brokerMcNumber.isEmpty ? nil : brokerMcNumber,
                totalLoads: 0,
                totalRevenue: 0
            )
            _ = LocalBrokersRepository.shared.create(broker)
            showSavedAlert = true
            return
        }

        guard let profileId = supabase.client.auth.currentUser?.id else {
            showSavedAlert = true
            return
        }
        do {
            let broker = Broker(
                profileId: profileId,
                brokerName: trimmed,
                normalizedName: Broker.normalize(trimmed),
                mcNumber: brokerMcNumber.isEmpty ? nil : brokerMcNumber,
                totalLoads: 0,
                totalRevenue: 0
            )
            _ = try await supabase.createBroker(broker)
        } catch {
            // Don't block the load-saved flow if broker insert fails.
            print("⚠️ Broker save failed: \(error)")
        }
        showSavedAlert = true
    }

    // MARK: - Prefill (edit mode)

    private func prefillIfNeeded() {
        guard !didPrefill else { return }
        didPrefill = true

        guard let load = existingLoad else {
            truckNumber = DriverEquipmentProfileStore.defaultTruckNumber(profile: supabase.currentProfile)
            trailerNumber = DriverEquipmentProfileStore.defaultTrailerNumber(profile: supabase.currentProfile)
            return
        }

        let shouldUseCurrentEquipmentDefaults = load.id == nil
        let defaultTruck = shouldUseCurrentEquipmentDefaults
            ? DriverEquipmentProfileStore.defaultTruckNumber(profile: supabase.currentProfile)
            : ""
        let defaultTrailer = shouldUseCurrentEquipmentDefaults
            ? DriverEquipmentProfileStore.defaultTrailerNumber(profile: supabase.currentProfile)
            : ""
        loadNumber = load.loadNumber ?? ""
        brokerName = load.brokerName ?? ""
        brokerMcNumber = load.brokerMcNumber ?? ""
        truckNumber = load.truckNumber ?? defaultTruck
        trailerNumber = load.trailerNumber ?? defaultTrailer
        origin = load.origin ?? ""
        destination = load.destination ?? ""
        totalMiles = load.totalMiles.map { String(format: "%.0f", $0) } ?? ""
        lineHaulRate = load.lineHaulRate.map { String(format: "%.2f", $0) } ?? ""
        fuelSurcharge = load.fuelSurcharge.map { String(format: "%.2f", $0) } ?? ""
        accessorialCharges = load.accessorialCharges.map { String(format: "%.2f", $0) } ?? ""
    }

    // MARK: - Components

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.spGold)

            VStack(spacing: 14) {
                content()
            }
            .padding(16)
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal)
    }

    private func formField(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        identifier: String,
        keyboard: UIKeyboardType = .default,
        prefix: String? = nil
    ) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
                .frame(width: 90, alignment: .leading)

            HStack(spacing: 4) {
                if let prefix = prefix {
                    Text(prefix)
                        .foregroundStyle(Color.spGold)
                }
                TextField(placeholder, text: text)
                    .foregroundStyle(Color.spTextPrimary)
                    .keyboardType(keyboard)
                    .accessibilityIdentifier(identifier)
            }
            .padding(10)
            .background(Color.spCardBgLight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Save

    private func saveLoad() {
        // ── Free Local Mode ──
        // Persist via LocalLoadsRepository. profileId is the per-install
        // UUID; no Supabase auth required.
        if AppMode.shared.isLocal {
            isSaving = true
            errorMessage = nil
            if let existing = existingLoad, existing.id != nil {
                var updated = existing
                updated.loadNumber = loadNumber.isEmpty ? nil : loadNumber
                updated.brokerName = brokerName.isEmpty ? nil : brokerName
                updated.brokerMcNumber = brokerMcNumber.isEmpty ? nil : brokerMcNumber
                updated.truckNumber = cleanedOrNil(truckNumber)
                updated.trailerNumber = cleanedOrNil(trailerNumber)
                updated.origin = origin.isEmpty ? nil : origin
                updated.destination = destination.isEmpty ? nil : destination
                updated.totalMiles = Double(totalMiles)
                updated.lineHaulRate = Double(lineHaulRate)
                updated.fuelSurcharge = Double(fuelSurcharge)
                updated.accessorialCharges = Double(accessorialCharges)
                updated.totalRevenue = computedRevenue > 0 ? computedRevenue : nil
                LocalLoadsRepository.shared.update(updated)
                showSavedAlert = true
            } else {
                let installId = AppMode.shared.localInstallId
                let load = Load(
                    profileId: installId,
                    loadNumber: loadNumber.isEmpty ? nil : loadNumber,
                    brokerName: brokerName.isEmpty ? nil : brokerName,
                    brokerMcNumber: brokerMcNumber.isEmpty ? nil : brokerMcNumber,
                    truckNumber: cleanedOrNil(truckNumber),
                    trailerNumber: cleanedOrNil(trailerNumber),
                    origin: origin.isEmpty ? nil : origin,
                    destination: destination.isEmpty ? nil : destination,
                    totalMiles: Double(totalMiles),
                    lineHaulRate: Double(lineHaulRate),
                    fuelSurcharge: Double(fuelSurcharge),
                    accessorialCharges: Double(accessorialCharges),
                    totalRevenue: computedRevenue > 0 ? computedRevenue : nil,
                    status: "pending"
                )
                _ = LocalLoadsRepository.shared.create(load)
                // Mirror the cloud broker-attribution path: if the typed
                // broker doesn't yet exist in LocalBrokersRepository, show
                // the prompt so the user can add it for future scans.
                updateMatchedBroker()
                let trimmed = brokerName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, matchedBroker == nil {
                    showAddBrokerPrompt = true
                } else {
                    showSavedAlert = true
                }
            }
            isSaving = false
            return
        }

        // ── Cloud Sync (existing path) ──
        guard let profileId = supabase.client.auth.currentUser?.id else {
            errorMessage = "Not logged in"
            return
        }

        isSaving = true
        errorMessage = nil

        Task {
            do {
                if let existing = existingLoad, existing.id != nil {
                    // UPDATE path — pre-existing row, edit in place.
                    var updated = existing
                    updated.loadNumber = loadNumber.isEmpty ? nil : loadNumber
                    updated.brokerName = brokerName.isEmpty ? nil : brokerName
                    updated.brokerMcNumber = brokerMcNumber.isEmpty ? nil : brokerMcNumber
                    updated.truckNumber = cleanedOrNil(truckNumber)
                    updated.trailerNumber = cleanedOrNil(trailerNumber)
                    updated.origin = origin.isEmpty ? nil : origin
                    updated.destination = destination.isEmpty ? nil : destination
                    updated.totalMiles = Double(totalMiles)
                    updated.lineHaulRate = Double(lineHaulRate)
                    updated.fuelSurcharge = Double(fuelSurcharge)
                    updated.accessorialCharges = Double(accessorialCharges)
                    updated.totalRevenue = computedRevenue > 0 ? computedRevenue : nil
                    try await supabase.updateLoad(updated)
                    showSavedAlert = true
                } else {
                    // CREATE path
                    let load = Load(
                        profileId: profileId,
                        loadNumber: loadNumber.isEmpty ? nil : loadNumber,
                        brokerName: brokerName.isEmpty ? nil : brokerName,
                        brokerMcNumber: brokerMcNumber.isEmpty ? nil : brokerMcNumber,
                        truckNumber: cleanedOrNil(truckNumber),
                        trailerNumber: cleanedOrNil(trailerNumber),
                        origin: origin.isEmpty ? nil : origin,
                        destination: destination.isEmpty ? nil : destination,
                        totalMiles: Double(totalMiles),
                        lineHaulRate: Double(lineHaulRate),
                        fuelSurcharge: Double(fuelSurcharge),
                        accessorialCharges: Double(accessorialCharges),
                        totalRevenue: computedRevenue > 0 ? computedRevenue : nil,
                        status: "pending"
                    )
                    _ = try await supabase.createLoad(load)
                    // Refresh broker match in case the user just typed
                    // a broker that had been added in another tab.
                    updateMatchedBroker()
                    let trimmed = brokerName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty, matchedBroker == nil {
                        showAddBrokerPrompt = true
                    } else {
                        showSavedAlert = true
                    }
                }
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }

    private func cleanedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
