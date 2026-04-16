import SwiftUI

/// Manual entry form for adding loads without scanning.
/// Used when a driver doesn't have the physical document handy.
struct ManualLoadEntryView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) var dismiss

    @State private var loadNumber = ""
    @State private var brokerName = ""
    @State private var origin = ""
    @State private var destination = ""
    @State private var totalMiles = ""
    @State private var lineHaulRate = ""
    @State private var fuelSurcharge = ""
    @State private var accessorialCharges = ""
    @State private var isSaving = false
    @State private var showSavedAlert = false
    @State private var errorMessage: String?

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
                            formField("Load #", text: $loadNumber, placeholder: "e.g. LD-2841")
                            formField("Broker", text: $brokerName, placeholder: "e.g. CH Robinson")
                        }

                        // Route
                        sectionCard("Route") {
                            formField("Origin", text: $origin, placeholder: "e.g. Atlanta, GA")
                            formField("Destination", text: $destination, placeholder: "e.g. Dallas, TX")
                            formField("Miles", text: $totalMiles, placeholder: "e.g. 780", keyboard: .decimalPad)
                        }

                        // Revenue
                        sectionCard("Revenue") {
                            formField("Line Haul", text: $lineHaulRate, placeholder: "0.00", keyboard: .decimalPad, prefix: "$")
                            formField("Fuel Surcharge", text: $fuelSurcharge, placeholder: "0.00", keyboard: .decimalPad, prefix: "$")
                            formField("Accessorials", text: $accessorialCharges, placeholder: "0.00", keyboard: .decimalPad, prefix: "$")

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
                                Label("Save Load", systemImage: "checkmark.circle.fill")
                                    .fontWeight(.bold)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .foregroundStyle(Color.spBlack)
                            }
                        }
                        .background(Color.spGold)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .disabled(isSaving)
                        .padding(.horizontal)
                        .padding(.bottom, 32)
                    }
                    .padding(.top, 12)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add Load")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.spBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.spGoldLight)
                }
            }
            .alert("Load Saved!", isPresented: $showSavedAlert) {
                Button("OK") { dismiss() }
            } message: {
                Text("Load \(loadNumber.isEmpty ? "" : loadNumber + " ")added successfully.")
            }
        }
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

    private func formField(_ label: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType = .default, prefix: String? = nil) -> some View {
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
            }
            .padding(10)
            .background(Color.spCardBgLight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Save

    private func saveLoad() {
        guard let profileId = supabase.client.auth.currentUser?.id else {
            errorMessage = "Not logged in"
            return
        }

        isSaving = true
        errorMessage = nil

        Task {
            do {
                let load = Load(
                    profileId: profileId,
                    loadNumber: loadNumber.isEmpty ? nil : loadNumber,
                    brokerName: brokerName.isEmpty ? nil : brokerName,
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
                showSavedAlert = true
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}
