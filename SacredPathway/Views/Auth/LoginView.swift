import SwiftUI

struct LoginView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                // Dark background
                Color.spBackground.ignoresSafeArea()

                VStack(spacing: 24) {
                    Spacer()

                    // Logo area
                    VStack(spacing: 12) {
                        // Use custom logo if available, otherwise fallback icon
                        if UIImage(named: "SacredPathwayLogo") != nil {
                            Image("SacredPathwayLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 160, height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                        } else {
                            Image(systemName: "truck.box.fill")
                                .font(.system(size: 80))
                                .foregroundStyle(Color.spGold)
                                .frame(width: 160, height: 160)
                        }

                        Text("Sacred Pathway")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.spGold)

                        Text("Driver Hub")
                            .font(.title2)
                            .foregroundStyle(Color.spTextSecondary)
                    }

                    Spacer()

                    // Form fields
                    VStack(spacing: 16) {
                        TextField("Email", text: $email)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .tint(Color.spGold)

                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .tint(Color.spGold)

                        if let error = errorMessage {
                            Text(error)
                                .foregroundStyle(Color.spDanger)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }

                        Button(action: handleAuth) {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            } else {
                                Text(isSignUp ? "Create Account" : "Sign In")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.spBlack)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            }
                        }
                        .background(Color.spGold)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .disabled(email.isEmpty || password.isEmpty || isLoading)
                        .opacity((email.isEmpty || password.isEmpty || isLoading) ? 0.5 : 1.0)

                        Button(action: {
                            isSignUp.toggle()
                            errorMessage = nil
                        }) {
                            Text(isSignUp
                                 ? "Already have an account? Sign In"
                                 : "Don't have an account? Sign Up")
                                .font(.subheadline)
                                .foregroundStyle(Color.spGoldLight)
                        }
                    }
                    .padding(.horizontal, 32)

                    Spacer()
                }
            }
        }
    }

    private func handleAuth() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                if isSignUp {
                    try await supabase.signUp(email: email, password: password)
                    try await supabase.signIn(email: email, password: password)
                } else {
                    try await supabase.signIn(email: email, password: password)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#Preview {
    LoginView()
        .environmentObject(SupabaseService())
}
