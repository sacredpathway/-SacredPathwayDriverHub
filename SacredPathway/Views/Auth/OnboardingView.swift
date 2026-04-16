import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Binding var hasCompletedOnboarding: Bool

    @State private var companyName = ""
    @State private var mcNumber = ""
    @State private var dotNumber = ""
    @State private var phone = ""
    @State private var driverPayPct = "25"
    @State private var dispatcherFeePct = "5"
    @State private var factoringFeePct = "3"
    @State private var authorityFee = "50"
    @State private var maintenanceReserve = "100"
    @State private var currentStep = 1
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            NavigationStack {
                VStack {
                    HStack(spacing: 8) {
                        ForEach(1...2, id: \.self) { step in
                            Capsule()
                                .fill(step <= currentStep ? Color.spGold : Color.spCardBgLight)
                                .frame(height: 4)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 16)

                    if currentStep == 1 {
                        companyInfoStep
                    } else {
                        feeConfigStep
                    }
                }
                .navigationTitle(currentStep == 1 ? "Company Info" : "Fee Settings")
                .navigationBarTitleDisplayMode(.large)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(Color.spBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .scrollContentBackground(.hidden)
                .background(Color.spBackground)
            }
        }
    }

    private var companyInfoStep: some View {
        VStack(spacing: 20) {
            Text("Let's set up your company profile. This info appears on your paystubs.")
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 8)

            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Company Name")
                        .font(.caption)
                        .foregroundStyle(Color.spGold)
                    TextField("e.g. Sacred Pathway LLC", text: $companyName)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(Color.spTextPrimary)
                        .padding(12)
                        .background(Color.spCardBg)
                        .cornerRadius(8)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("MC Number (optional)")
                        .font(.caption)
                        .foregroundStyle(Color.spGold)
                    TextField("e.g. MC-123456", text: $mcNumber)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(Color.spTextPrimary)
                        .padding(12)
                        .background(Color.spCardBg)
                        .cornerRadius(8)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("DOT Number (optional)")
                        .font(.caption)
                        .foregroundStyle(Color.spGold)
                    TextField("e.g. 1234567", text: $dotNumber)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(Color.spTextPrimary)
                        .padding(12)
                        .background(Color.spCardBg)
                        .cornerRadius(8)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Phone (optional)")
                        .font(.caption)
                        .foregroundStyle(Color.spGold)
                    TextField("e.g. 555-555-5555", text: $phone)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(Color.spTextPrimary)
                        .padding(12)
                        .background(Color.spCardBg)
                        .cornerRadius(8)
                        .keyboardType(.phonePad)
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            Button(action: { currentStep = 2 }) {
                Text("Next")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .foregroundStyle(Color.spBlack)
                    .background(Color.spGold)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
    }

    private var feeConfigStep: some View {
        VStack(spacing: 20) {
            Text("Set your default fee structure. You can change these anytime in Settings.")
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 8)

            VStack(spacing: 16) {
                feeRow(label: "Driver Pay", value: $driverPayPct, suffix: "%")
                feeRow(label: "Dispatcher Fee", value: $dispatcherFeePct, suffix: "%")
                feeRow(label: "Factoring Fee", value: $factoringFeePct, suffix: "%")
                feeRow(label: "Authority Fee", value: $authorityFee, suffix: "$/mo")
                feeRow(label: "Maintenance Reserve", value: $maintenanceReserve, suffix: "$/settlement")
            }
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                Button(action: saveOnboarding) {
                    if isLoading {
                        ProgressView()
                            .tint(Color.spBlack)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    } else {
                        Text("Finish Setup")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .foregroundStyle(Color.spBlack)
                    }
                }
                .background(Color.spGold)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(isLoading)

                Button("Back") { currentStep = 1 }
                    .font(.subheadline)
                    .foregroundStyle(Color.spGoldLight)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
    }

    private func feeRow(label: String, value: Binding<String>, suffix: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
            Spacer()
            HStack(spacing: 4) {
                TextField("0", text: value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Color.spTextPrimary)
                    .padding(8)
                    .background(Color.spCardBg)
                    .cornerRadius(6)
                Text(suffix)
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .frame(width: 80, alignment: .leading)
            }
        }
    }

    private func saveOnboarding() {
        isLoading = true
        Task {
            do {
                try await supabase.updateProfile([
                    "company_name": AnyEncodable(companyName.isEmpty ? nil as String? : companyName),
                    "mc_number": AnyEncodable(mcNumber.isEmpty ? nil as String? : mcNumber),
                    "dot_number": AnyEncodable(dotNumber.isEmpty ? nil as String? : dotNumber),
                    "phone": AnyEncodable(phone.isEmpty ? nil as String? : phone),
                    "driver_pay_percentage": AnyEncodable(Double(driverPayPct) ?? 25.0),
                    "dispatcher_fee_percentage": AnyEncodable(Double(dispatcherFeePct) ?? 5.0),
                    "factoring_fee_percentage": AnyEncodable(Double(factoringFeePct) ?? 3.0),
                    "authority_fee": AnyEncodable(Double(authorityFee) ?? 50.0),
                    "maintenance_reserve": AnyEncodable(Double(maintenanceReserve) ?? 100.0),
                ])
                hasCompletedOnboarding = true
            } catch {
                print("Error saving onboarding: \(error)")
            }
            isLoading = false
        }
    }
}

#Preview {
    OnboardingView(hasCompletedOnboarding: .constant(false))
        .environmentObject(SupabaseService())
}
