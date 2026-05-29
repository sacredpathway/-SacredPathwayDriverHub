import SwiftUI
import AuthenticationServices
import CryptoKit

// =============================================================================
//  LoginView — Apple-only first-run sign-in
// -----------------------------------------------------------------------------
//  Per App Review feedback (iPad SIWA + simplified onboarding):
//   • Single primary CTA: "Continue with Apple"
//   • No magic-link form, no email/password fallback on first run
//   • No long registration form before the user is in the app
//   • After successful Apple sign-in → straight to DashboardView (no onboarding)
//   • iPad-tested: SignInWithAppleButton uses iOS-native presentation; the
//     constraining .frame(maxWidth: 420) keeps the button visually centered
//     on iPad without breaking the button's internal hit-testing.
//
//  Profile / business setup is OPTIONAL and lives inside Settings → Company.
// =============================================================================

/// Feature flag retained for compatibility with older callsites. Now hard-on.
enum LoginFeatureFlags {
    /// Apple Sign In is the primary (and only) account creation method.
    static let appleSignInEnabled = true
}

struct LoginView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.colorScheme) private var colorScheme

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var currentNonce: String?

    // ─────────────────────────────────────────────────────────────────────
    // Email/password mode — added so users can sign in on a 2nd device
    // without depending on the original Apple ID. Apple Sign In remains
    // the primary CTA.
    //
    // Supabase auth treats email + apple as separate identities on the
    // same `auth.users` row when the email matches. We never duplicate a
    // profile row because `profiles.id == auth.users.id` (1:1).
    // ─────────────────────────────────────────────────────────────────────
    enum EmailMode { case signIn, signUp, forgotPassword }

    @State private var showEmailForm: Bool = false
    @State private var emailMode: EmailMode = .signIn
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var passwordVisible: Bool = false
    @State private var selectedSignupRole: AccountRole?
    @State private var infoMessage: String?
    @FocusState private var focusedField: EmailField?

    private enum EmailField { case email, password }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // MARK: - Logo + brand
                VStack(spacing: 14) {
                    Image("SacredPathwayLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 24))

                    Text("Sacred Pathway")
                        .font(.title.weight(.heavy))
                        .foregroundStyle(Color.spGold)

                    Text("Fast, secure sign-in for truck drivers and owner-operators.")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                // MARK: - Continue with Apple (primary, only CTA)
                VStack(spacing: 12) {
                    SignInWithAppleButton(
                        .continue,
                        onRequest: configureAppleRequest,
                        onCompletion: handleAppleCompletion
                    )
                    // Apple HIG: choose the variant that contrasts with the
                    // background so the button shape is unmistakable. Light
                    // mode = solid black button on white; dark mode = solid
                    // white button on black. Either way the SIWA button has
                    // a clearly visible background behind the Apple logo.
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 54)
                    .frame(maxWidth: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        // Extra visual affordance so the button reads as a
                        // tappable control on every background, including
                        // edge cases where the system style ever renders flat.
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.spGold.opacity(0.55), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
                    .disabled(isLoading)
                    .opacity(isLoading ? 0.5 : 1.0)

                    if isLoading {
                        ProgressView()
                            .tint(Color.spGold)
                            .padding(.top, 4)
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color.spDanger)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)

                // ─── Email / password block ───────────────────────────
                emailPasswordSection
                    .padding(.horizontal, 32)
                    .padding(.top, 14)

                Spacer().frame(height: 16)

                // MARK: - Trust / legal footer (Apple requires links to T&C and Privacy)
                VStack(spacing: 6) {
                    Text("Private. Ad-free. Your data stays in your account.")
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary)
                    HStack(spacing: 12) {
                        Link("Privacy", destination: Config.Legal.privacyPolicyURL)
                        Link("Terms", destination: Config.Legal.termsOfServiceURL)
                    }
                    .font(.caption2)
                    .foregroundStyle(Color.spGoldLight)
                }
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 560) // iPad: keeps the layout center-anchored
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Email / password section

    @ViewBuilder
    private var emailPasswordSection: some View {
        if !showEmailForm {
            // Collapsed CTA — prefer Apple, but the option is one tap away.
            Button {
                withAnimation { showEmailForm = true }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.fill")
                    Text("Sign in with Email")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Color.spGoldLight)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .frame(maxWidth: 420)
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.spGold.opacity(0.45), lineWidth: 1)
                )
            }
            .disabled(isLoading)
        } else {
            VStack(spacing: 12) {
                // Mode picker
                HStack(spacing: 6) {
                    modeChip(label: "Sign In",        mode: .signIn)
                    modeChip(label: "Create Account", mode: .signUp)
                    modeChip(label: "Forgot",         mode: .forgotPassword)
                }

                emailField
                if emailMode != .forgotPassword {
                    passwordField
                }
                if emailMode == .signUp {
                    signupRoleSection
                }

                Button(action: { Task { await runEmailAction() } }) {
                    HStack {
                        if isLoading {
                            ProgressView().tint(Color.spBlack)
                        }
                        Text(primaryButtonTitle)
                            .font(.subheadline.weight(.bold))
                    }
                    .foregroundStyle(Color.spBlack)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.spGold)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isLoading || !canSubmit)

                if let info = infoMessage {
                    Text(info)
                        .font(.caption)
                        .foregroundStyle(Color.spSuccess)
                        .multilineTextAlignment(.center)
                }

                Button("Hide email sign-in") {
                    withAnimation {
                        showEmailForm = false
                        email = ""
                        password = ""
                        selectedSignupRole = nil
                        errorMessage = nil
                        infoMessage = nil
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
            }
            .frame(maxWidth: 420)
        }
    }

    private func modeChip(label: String, mode: EmailMode) -> some View {
        let active = emailMode == mode
        return Button {
            emailMode = mode
            errorMessage = nil
            infoMessage = nil
            if mode != .signUp {
                selectedSignupRole = nil
            }
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(active ? Color.spGold.opacity(0.22) : Color.clear)
                .foregroundStyle(active ? Color.spGold : Color.spTextSecondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        active ? Color.spGold : Color.spTextSecondary.opacity(0.35),
                        lineWidth: 1
                    )
                )
        }
    }

    private var emailField: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope")
                .foregroundStyle(Color.spTextSecondary)
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .focused($focusedField, equals: .email)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
                .foregroundStyle(Color.spTextPrimary)
        }
        .padding(12)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var signupRoleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose your account role")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.spTextSecondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(AccountRole.allCases) { role in
                    signupRoleButton(role)
                }
            }
        }
    }

    private func signupRoleButton(_ role: AccountRole) -> some View {
        let isSelected = selectedSignupRole == role
        return Button {
            selectedSignupRole = role
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Image(systemName: accountRoleIcon(role))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                    }
                }
                Text(role.displayName)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.spBlack : Color.spTextPrimary)
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background(isSelected ? Color.spGold : Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.spGold : Color.spTextSecondary.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var passwordField: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .foregroundStyle(Color.spTextSecondary)
            Group {
                if passwordVisible {
                    TextField("Password", text: $password)
                } else {
                    SecureField("Password", text: $password)
                }
            }
            .textContentType(emailMode == .signUp ? .newPassword : .password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .focused($focusedField, equals: .password)
            .submitLabel(.go)
            .onSubmit { Task { await runEmailAction() } }
            .foregroundStyle(Color.spTextPrimary)
            Button {
                passwordVisible.toggle()
            } label: {
                Image(systemName: passwordVisible ? "eye.slash" : "eye")
                    .foregroundStyle(Color.spTextSecondary)
            }
        }
        .padding(12)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var primaryButtonTitle: String {
        switch emailMode {
        case .signIn:         return "Sign In"
        case .signUp:         return "Create Account"
        case .forgotPassword: return "Send Reset Link"
        }
    }

    private var canSubmit: Bool {
        let emailOk = isValidEmail(email)
        switch emailMode {
        case .forgotPassword:
            return emailOk
        case .signIn:
            return emailOk && password.count >= 8
        case .signUp:
            return emailOk && password.count >= 8 && selectedSignupRole != nil
        }
    }

    private func isValidEmail(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@"), trimmed.contains("."), trimmed.count >= 5 else {
            return false
        }
        return true
    }

    private func runEmailAction() async {
        guard !isLoading else { return }
        // Reset feedback.
        errorMessage = nil
        infoMessage = nil
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pwd = password

        switch emailMode {
        case .signIn:
            guard isValidEmail(trimmedEmail), pwd.count >= 8 else {
                errorMessage = "Enter a valid email and a password (8+ characters)."
                return
            }
            isLoading = true
            do {
                try await supabase.signIn(email: trimmedEmail, password: pwd)
                // SupabaseService publishes isAuthenticated = true → root view switches.
            } catch {
                errorMessage = friendlyAuthError(
                    error,
                    fallback: "We couldn't sign you in. Double-check the email and password."
                )
            }
            isLoading = false

        case .signUp:
            guard isValidEmail(trimmedEmail), pwd.count >= 8, let selectedSignupRole else {
                errorMessage = "Enter a valid email, password, and account role."
                return
            }
            isLoading = true
            do {
                try await supabase.signUp(email: trimmedEmail, password: pwd, accountRole: selectedSignupRole)
                // Supabase may require email confirmation depending on the
                // project's "Confirm email" setting. We surface a friendly
                // message either way.
                infoMessage = "Account created. Check your inbox if confirmation is required, then sign in."
                emailMode = .signIn
                self.selectedSignupRole = nil
            } catch {
                errorMessage = friendlyAuthError(
                    error,
                    fallback: "We couldn't create the account. Try a different email or sign in instead."
                )
            }
            isLoading = false

        case .forgotPassword:
            guard isValidEmail(trimmedEmail) else {
                errorMessage = "Enter the email on your account so we can send a reset link."
                return
            }
            isLoading = true
            do {
                try await supabase.resetPassword(email: trimmedEmail)
                infoMessage = "If that email is on file, a reset link is on its way."
            } catch {
                // Even on error we keep the message neutral so attackers
                // can't enumerate registered emails.
                infoMessage = "If that email is on file, a reset link is on its way."
            }
            isLoading = false
        }
    }

    private func friendlyAuthError(_ error: Error, fallback: String) -> String {
        let raw = error.localizedDescription.lowercased()
        if raw.contains("invalid login credentials") || raw.contains("invalid email or password") {
            return "Wrong email or password. Tap 'Forgot' if you need a reset link."
        }
        if raw.contains("user already registered") || raw.contains("already exists") {
            return "An account with this email already exists. Try signing in instead."
        }
        if raw.contains("password") && raw.contains("weak") {
            return "Choose a stronger password (8+ characters, mix of letters and numbers)."
        }
        if raw.contains("email") && raw.contains("not confirmed") {
            return "Check your inbox and confirm the email, then sign in."
        }
        if raw.contains("network") || raw.contains("offline") {
            return "Looks like you're offline. Connect and try again."
        }
        if raw.contains("rate") || raw.contains("too many") {
            return "Too many attempts. Wait a minute and try again."
        }
        return fallback
    }

    private func accountRoleIcon(_ role: AccountRole) -> String {
        switch role {
        case .dispatcher: return "point.3.connected.trianglepath.dotted"
        case .carrier: return "building.2.fill"
        case .driver: return "steeringwheel"
        case .ownerOperator: return "truck.box.fill"
        }
    }

    // MARK: - Apple Sign In

    private func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                errorMessage = "Apple sign-in didn't return a valid token. Please try again."
                return
            }
            isLoading = true
            errorMessage = nil
            Task {
                do {
                    try await supabase.signInWithApple(idToken: idToken, nonce: nonce)
                    // SupabaseService publishes isAuthenticated = true; the root
                    // SacredPathwayApp body switches to ContentView automatically.
                } catch {
                    errorMessage = friendlyError(error,
                        fallback: "We couldn't complete sign-in. Please try again.")
                }
                isLoading = false
            }
        case .failure(let error):
            let nsError = error as NSError
            // 1001 = user canceled the sheet — silent.
            if nsError.code == ASAuthorizationError.canceled.rawValue { return }
            errorMessage = friendlyError(error,
                fallback: "Apple sign-in couldn't complete. Please try again.")
        }
    }

    // MARK: - Helpers

    private func friendlyError(_ error: Error, fallback: String) -> String {
        let raw = error.localizedDescription.lowercased()
        if raw.contains("network") || raw.contains("offline") {
            return "Looks like you're offline. Connect to Wi-Fi or cellular and try again."
        }
        if raw.contains("rate") || raw.contains("too many") {
            return "Too many attempts. Wait a minute and try again."
        }
        if raw.contains("provider not enabled") || raw.contains("not configured") {
            return "Sign-in is temporarily unavailable. Please try again shortly."
        }
        return fallback
    }

    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            precondition(status == errSecSuccess)
            for r in randoms where remaining > 0 {
                if r < charset.count * Int(UInt8.max / UInt8(charset.count)) {
                    result.append(charset[Int(r) % charset.count])
                    remaining -= 1
                }
            }
        }
        return result
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

#Preview {
    LoginView()
        .environmentObject(SupabaseService())
}
