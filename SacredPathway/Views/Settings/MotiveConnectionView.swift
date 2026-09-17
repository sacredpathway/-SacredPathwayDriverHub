import SwiftUI

// =============================================================================
// MARK: - Connect Motive ELD (READ-ONLY)
// -----------------------------------------------------------------------------
// Settings screen for linking a driver / owner-operator / carrier's own Motive
// account so Sacred Path can DISPLAY authorized Motive data and pre-fill the
// Trip Planner's hours. Sacred Path only READS Motive — it never controls,
// edits, dispatches, or changes anything in Motive, and is not an FMCSA ELD.
//
// Connection states surfaced: Not Connected · Connected · Token Expired ·
// Sync Failed. Token stored in Keychain (MotiveAuthManager); password never
// stored. Includes a manual "Sync Now", last-synced time, and a sample/dev
// data toggle used until a live Motive endpoint is configured.
// =============================================================================

struct MotiveConnectionView: View {
    var role: AccountRole = .ownerOperator

    @ObservedObject private var motive = MotiveIntegrationService.shared
    @ObservedObject private var store = MotiveSyncStore.shared
    @State private var tokenInput = ""
    @State private var showToken = false
    @State private var showDisconnectConfirm = false

    var body: some View {
        List {
            statusSection
            if motive.isConnected {
                syncSection
                NavigationLink {
                    MotiveDataView(role: role)
                } label: {
                    Label("View Motive Data", systemImage: "rectangle.stack.fill")
                        .foregroundStyle(Color.spTextPrimary)
                }
                .listRowBackground(Color.spCardBg)
                accountSection
            } else {
                connectSection
            }
            devModeSection
            manualModeSection
            disclaimerSection
        }
        .scrollContentBackground(.hidden)
        .background(Color.spBackground)
        .navigationTitle("Connect Motive ELD")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.spGold)
        .onAppear { tokenInput = "" }
        .alert("Disconnect Motive?", isPresented: $showDisconnectConfirm) {
            Button("Disconnect", role: .destructive) { motive.disconnect() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your saved token and cached data are removed from this device. Your Motive logs are unaffected.")
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(motive.state.label)
                        .font(.headline)
                        .foregroundStyle(Color.spTextPrimary)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .listRowBackground(Color.spCardBg)
        }
    }

    private var statusIcon: String {
        switch motive.state {
        case .connected:    return "checkmark.seal.fill"
        case .connecting:   return "arrow.triangle.2.circlepath"
        case .tokenExpired: return "exclamationmark.triangle.fill"
        case .syncFailed:   return "xmark.octagon.fill"
        case .notConnected: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var statusColor: Color {
        switch motive.state {
        case .connected:    return Color.spGreenAccent
        case .connecting:   return Color.spGold
        case .tokenExpired: return Color.spWarning
        case .syncFailed:   return Color.spDanger
        case .notConnected: return Color.spTextSecondary
        }
    }

    private var statusDetail: String {
        switch motive.state {
        case .connected:    return "Reading your authorized Motive data."
        case .connecting:   return "Syncing with Motive…"
        case .tokenExpired: return "Reconnect to refresh your authorization."
        case .syncFailed(let m): return m
        case .notConnected: return "Trip Planner uses the hours you enter by hand."
        }
    }

    // MARK: Sync

    private var syncSection: some View {
        Section {
            Button {
                Task { await motive.syncNow(role: role) }
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Sync Now").font(.subheadline.weight(.semibold))
                    Spacer()
                    if motive.isSyncing { ProgressView().tint(Color.spGold) }
                }
                .foregroundStyle(Color.spTextPrimary)
            }
            .listRowBackground(Color.spCardBg)
            .disabled(motive.isSyncing)

            HStack {
                Label("Last synced", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(Color.spTextSecondary)
                Spacer()
                Text(store.lastSyncedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    .font(.caption)
                    .foregroundStyle(Color.spTextPrimary)
            }
            .listRowBackground(Color.spCardBg)
        }
    }

    // MARK: Account

    private var accountSection: some View {
        Section {
            Button(role: .destructive) {
                showDisconnectConfirm = true
            } label: {
                HStack {
                    Image(systemName: "minus.circle.fill")
                    Text("Disconnect Motive")
                }
            }
            .listRowBackground(Color.spCardBg)
        }
    }

    // MARK: Connect

    private var connectSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paste your Motive read-only API token to link your account. Create one in the Motive Fleet Dashboard under Settings → API. Sacred Path requests read access only.")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Group {
                        if showToken {
                            TextField("Motive API token", text: $tokenInput)
                        } else {
                            SecureField("Motive API token", text: $tokenInput)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(Color.spTextPrimary)

                    Button { showToken.toggle() } label: {
                        Image(systemName: showToken ? "eye.slash.fill" : "eye.fill")
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(Color.spCardBg)

            Button {
                motive.connect(accessToken: tokenInput)
                tokenInput = ""
                Task { await motive.syncNow(role: role) }
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: "link")
                    Text("Connect Motive").font(.subheadline.weight(.bold))
                    Spacer()
                }
                .padding(.vertical, 6)
                .foregroundStyle(.white)
            }
            .listRowBackground(Color.spDarkGreen)
            .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("Link Account (read-only)")
        }
    }

    // MARK: Dev / sample mode

    @ViewBuilder
    private var devModeSection: some View {
        if !MotiveConfig.isLiveConfigured {
            Section {
                Toggle(isOn: $store.useSampleData) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use sample data").foregroundStyle(Color.spTextPrimary)
                        Text("No live Motive endpoint is configured in this build. Sample data lets you preview the screens.")
                            .font(.caption2)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                }
                .tint(Color.spGold)
                .listRowBackground(Color.spCardBg)
            } header: {
                Text("Developer / Preview")
            }
        }
    }

    // MARK: Manual mode

    private var manualModeSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Color.spGold)
                Text("You can always plan trips without Motive. Enter your hours and fuel by hand in the Trip Planner — everything works the same, just without auto-fill.")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(Color.spCardBg)
        } header: {
            Text("Manual Mode")
        }
    }

    // MARK: Disclaimer / privacy

    private var disclaimerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("What Sacred Path reads from Motive")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text("Driver profile, vehicle info, current location, hours of service, trip history & mileage, DVIR/inspection status, and fuel/IFTA data — only what your Motive account authorizes. Sacred Path never writes to or controls Motive, never stores your Motive password, and keeps your token securely on this device only. Motive remains your official ELD and log of record.")
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(Color.spCardBg)
        } header: {
            Text("Privacy")
        }
    }
}

#Preview {
    NavigationStack {
        MotiveConnectionView()
    }
}
