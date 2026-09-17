import SwiftUI

// =============================================================================
//  DeleteAccountView — App Store Guideline 5.1.1(v) compliance
// -----------------------------------------------------------------------------
//  Apple requires any app that supports account creation to also provide an
//  in-app path to INITIATE account deletion (not just a link to a web form).
//  This screen satisfies that: the user types "DELETE" to confirm, hits the
//  button, and the client calls a server-side Edge Function that hard-deletes
//  the auth row + all user data.
//
//  If the server call fails, we still sign the user out locally so they are
//  never trapped in a partially-deleted state.
// =============================================================================

struct DeleteAccountView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss

    @State private var confirmationText: String = ""
    @State private var isDeleting: Bool = false
    @State private var errorMessage: String?
    @State private var showFinalAlert: Bool = false

    private let requiredConfirmation = "DELETE"

    private var isConfirmed: Bool {
        confirmationText.trimmingCharacters(in: .whitespacesAndNewlines) == requiredConfirmation
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    warningCard
                    whatHappensCard
                    confirmationField
                    deleteButton

                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(Color.spDanger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete your account?", isPresented: $showFinalAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await performDelete() }
            }
        } message: {
            Text("This cannot be undone. All your loads, expenses, paystubs, and documents will be permanently removed.")
        }
    }

    // MARK: - Subviews

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.spDanger)
                Text("This is permanent")
                    .font(.headline)
                    .foregroundStyle(Color.spTextPrimary)
            }
            Text("Deleting your account permanently removes your profile and all associated data. You won't be able to recover anything afterwards.")
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.spDanger.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.spDanger.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var whatHappensCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What will be deleted")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.spGold)
            bulletLine("Your login and profile")
            bulletLine("All loads, expenses, and paystub drafts")
            bulletLine("All uploaded documents and receipts")
            bulletLine("Drivers, brokers, and contacts you've added")
            bulletLine("Compliance records and IFTA entries")

            Divider().background(Color.spTextSecondary.opacity(0.3)).padding(.vertical, 4)

            Text("What won't be deleted")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.spGold)
            Text("Active subscriptions are managed by Apple — cancel them separately in Settings → Apple ID → Subscriptions.")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func bulletLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.spDanger)
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.spTextPrimary)
            Spacer()
        }
    }

    private var confirmationField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type DELETE to confirm")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
            TextField("DELETE", text: $confirmationText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .foregroundStyle(Color.spTextPrimary)
                .padding(12)
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var deleteButton: some View {
        Button {
            showFinalAlert = true
        } label: {
            HStack {
                if isDeleting {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "trash.fill")
                }
                Text(isDeleting ? "Deleting…" : "Delete My Account")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isConfirmed ? Color.spDanger : Color.spDanger.opacity(0.4))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!isConfirmed || isDeleting)
    }

    // MARK: - Actions

    private func performDelete() async {
        isDeleting = true
        errorMessage = nil
        do {
            try await supabase.deleteAccount()
            // supabase.deleteAccount() signs out locally in its defer block,
            // so `isAuthenticated` flips to false and the app returns to the
            // login screen via the root SacredPathwayApp body.
        } catch {
            errorMessage = "We couldn't fully delete your account: \(error.localizedDescription)\n\nYou've been signed out. If this persists, email demarquishinton@gmail.com."
        }
        isDeleting = false
    }
}

#Preview {
    NavigationStack {
        DeleteAccountView()
            .environmentObject(SupabaseService())
    }
}
