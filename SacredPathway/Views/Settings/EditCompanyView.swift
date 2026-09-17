import SwiftUI

struct EditCompanyView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) var dismiss

    @State private var companyName: String = ""
    @State private var mcNumber: String = ""
    @State private var dotNumber: String = ""
    @State private var phone: String = ""
    @State private var truckNumber: String = ""
    @State private var trailerNumber: String = ""
    @State private var isSaving = false
    @State private var savedMessage = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "building.2.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.spGold)
                        Text("Company Information")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Color.spTextPrimary)
                        Text("This info appears on your paystubs and documents.")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    // Fields
                    VStack(spacing: 0) {
                        editField(
                            label: "Company Name",
                            icon: "building.2",
                            placeholder: "Sacred Pathway LLC",
                            text: $companyName
                        )
                        Divider().background(Color.spTextSecondary.opacity(0.2)).padding(.horizontal)
                        editField(
                            label: "MC Number",
                            icon: "number",
                            placeholder: "MC-1234567",
                            text: $mcNumber,
                            keyboard: .numberPad
                        )
                        Divider().background(Color.spTextSecondary.opacity(0.2)).padding(.horizontal)
                        editField(
                            label: "DOT Number",
                            icon: "number.circle",
                            placeholder: "1234567",
                            text: $dotNumber,
                            keyboard: .numberPad
                        )
                        Divider().background(Color.spTextSecondary.opacity(0.2)).padding(.horizontal)
                        editField(
                            label: "Phone",
                            icon: "phone.fill",
                            placeholder: "(555) 123-4567",
                            text: $phone,
                            keyboard: .phonePad
                        )
                        Divider().background(Color.spTextSecondary.opacity(0.2)).padding(.horizontal)
                        editField(
                            label: "Truck Number",
                            icon: "truck.box.fill",
                            placeholder: "101",
                            text: $truckNumber
                        )
                        Divider().background(Color.spTextSecondary.opacity(0.2)).padding(.horizontal)
                        editField(
                            label: "Trailer Number",
                            icon: "shippingbox.fill",
                            placeholder: "TRL55",
                            text: $trailerNumber
                        )
                    }
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    if let error = errorMessage {
                        Text(error).font(.caption).foregroundStyle(Color.spDanger)
                    }

                    // Save button
                    Button {
                        Task { await saveCompanyInfo() }
                    } label: {
                        HStack {
                            if isSaving {
                                ProgressView().tint(Color.spBlack)
                            } else if savedMessage {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Saved!")
                            } else {
                                Image(systemName: "square.and.arrow.down.fill")
                                Text("Save Company Info")
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(savedMessage ? Color.spSuccess : Color.spGold)
                        .foregroundStyle(Color.spBlack)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isSaving)
                }
                .padding()
            }
        }
        .navigationTitle("Edit Company")
        .onAppear { loadCurrentValues() }
    }

    private func editField(label: String, icon: String, placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.spGold)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
                TextField(placeholder, text: text)
                    .keyboardType(keyboard)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.spTextPrimary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private func loadCurrentValues() {
        let profile = supabase.currentProfile
        companyName = profile?.companyName ?? ""
        mcNumber = profile?.mcNumber ?? ""
        dotNumber = profile?.dotNumber ?? ""
        phone = profile?.phone ?? ""
        truckNumber = DriverEquipmentProfileStore.defaultTruckNumber(profile: profile)
        trailerNumber = DriverEquipmentProfileStore.defaultTrailerNumber(profile: profile)
    }

    private func saveCompanyInfo() async {
        isSaving = true
        errorMessage = nil

        DriverEquipmentProfileStore.saveLocal(
            truckNumber: truckNumber,
            trailerNumber: trailerNumber
        )

        if AppMode.shared.isLocal {
            withAnimation { savedMessage = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { savedMessage = false }
            }
            isSaving = false
            return
        }

        let updates: [String: AnyEncodable] = [
            "company_name": AnyEncodable(companyName.isEmpty ? nil as String? : companyName),
            "mc_number": AnyEncodable(mcNumber.isEmpty ? nil as String? : mcNumber),
            "dot_number": AnyEncodable(dotNumber.isEmpty ? nil as String? : dotNumber),
            "phone": AnyEncodable(phone.isEmpty ? nil as String? : phone),
            "truck_number": AnyEncodable(truckNumber.isEmpty ? nil as String? : truckNumber),
            "trailer_number": AnyEncodable(trailerNumber.isEmpty ? nil as String? : trailerNumber)
        ]

        do {
            try await supabase.updateProfile(updates)
            withAnimation { savedMessage = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { savedMessage = false }
            }
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }

        isSaving = false
    }
}
