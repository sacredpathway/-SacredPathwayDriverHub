import SwiftUI

/// Minimum-friction first-run setup. Only asks for what we absolutely need
/// to render a paystub (company name). Everything else — MC, DOT, phone,
/// fee percentages — has sensible defaults and is editable in Settings.
struct OnboardingView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Binding var hasCompletedOnboarding: Bool

    @State private var companyName = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    // Baseline fee defaults — user can tune them in Settings → Fee
    // Percentages later. Chosen to be a reasonable starting point for
    // small-fleet carriers. Nothing about these is locked in.
    private let defaults: [String: AnyEncodable] = [
        "driver_pay_percentage":      AnyEncodable(25.0),
        "dispatcher_fee_percentage":  AnyEncodable(5.0),
        "factoring_fee_percentage":   AnyEncodable(3.0),
        "authority_fee":              AnyEncodable(50.0),
        "maintenance_reserve":        AnyEncodable(100.0),
    ]

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                // Logo
                Image("SacredPathwayLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                // Headline + subhead
                VStack(spacing: 10) {
                    Text("You're in. One last thing.")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.spTextPrimary)
                        .multilineTextAlignment(.center)
                    Text("What's your company name? It appears at the top of every paystub you send.")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // Single field
                VStack(alignment: .leading, spacing: 6) {
                    TextField("e.g. Sacred Pathway Trucking LLC", text: $companyName)
                        .textContentType(.organizationName)
                        .padding(14)
                        .background(Color.spCardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(Color.spTextPrimary)
                        .tint(Color.spGold)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                    Text("You can add MC #, DOT #, phone, and fees later in Settings.")
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary)
                }
                .padding(.horizontal, 24)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Color.spDanger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                // Primary CTA
                Button(action: save) {
                    if isLoading {
                        ProgressView().tint(Color.spBlack)
                            .frame(maxWidth: .infinity).frame(height: 52)
                    } else {
                        Text("Get Started")
                            .font(.headline)
                            .foregroundStyle(Color.spBlack)
                            .frame(maxWidth: .infinity).frame(height: 52)
                    }
                }
                .background(Color.spGold)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(companyName.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                .opacity((companyName.trimmingCharacters(in: .whitespaces).isEmpty || isLoading) ? 0.5 : 1.0)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            // Autofocus so the keyboard pops up immediately — one tap less.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                nameFocused = true
            }
        }
    }

    private func save() {
        let trimmed = companyName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                var updates = defaults
                updates["company_name"] = AnyEncodable(trimmed)
                try await supabase.updateProfile(updates)
                hasCompletedOnboarding = true
            } catch {
                errorMessage = "Couldn't save that. Check your connection and try again."
                #if DEBUG
                print("[Onboarding] save error: \(error)")
                #endif
            }
            isLoading = false
        }
    }
}

#Preview {
    OnboardingView(hasCompletedOnboarding: .constant(false))
        .environmentObject(SupabaseService())
}
