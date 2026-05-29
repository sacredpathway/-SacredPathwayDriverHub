import SwiftUI

struct ContentView: View {
    @EnvironmentObject var supabase: SupabaseService
    @StateObject private var pinService = PinLockService.shared
    @ObservedObject private var appMode = AppMode.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var didAttemptProfileRefresh = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // ScreenshotMode takes a hard fast-path so App Store screenshots
            // stay deterministic and do not get blocked by PIN or account role
            // setup. Production runs unaffected.
            if ScreenshotMode.isActive {
                OwnerOperatorRootView()
            }
            // PIN lock takes priority over everything if enabled and not yet unlocked.
            else if pinService.isEnabled && !pinService.isUnlocked {
                PinLockView()
            } else {
                roleRoutedRoot
            }
        }
        .onAppear {
            if ScreenshotMode.isActive {
                pinService.isUnlocked = true
                return
            }
            if !pinService.isEnabled {
                pinService.isUnlocked = true
            }
        }
        .onChange(of: supabase.isAuthenticated) { _, _ in
            didAttemptProfileRefresh = false
        }
        .onChange(of: scenePhase) { _, phase in
            if ScreenshotMode.isActive { return }
            if phase == .background {
                pinService.lock()
            }
        }
    }

    @ViewBuilder
    private var roleRoutedRoot: some View {
        if appMode.isLocal {
            OwnerOperatorRootView()
        } else if let role = supabase.currentProfile?.accountRole {
            rootView(for: role)
        } else if supabase.isAuthenticated {
            if supabase.currentProfile != nil || didAttemptProfileRefresh {
                AccountRoleSelectionView()
            } else {
                roleLoadingView
                    .task {
                        await supabase.fetchProfile()
                        didAttemptProfileRefresh = true
                    }
            }
        } else {
            OwnerOperatorRootView()
        }
    }

    @ViewBuilder
    private func rootView(for role: AccountRole) -> some View {
        switch role {
        case .dispatcher:
            DispatcherRootView()
        case .carrier:
            CarrierRootView()
        case .driver:
            DriverRootView()
        case .ownerOperator:
            OwnerOperatorRootView()
        }
    }

    private var roleLoadingView: some View {
        VStack(spacing: 16) {
            Image("SacredPathwayLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            ProgressView()
                .tint(Color.spGold)
            Text("Loading your account...")
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.spBackground.ignoresSafeArea())
    }
}

struct DispatcherRootView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared

    var body: some View {
        TabView {
            NavigationStack {
                SacredDispatchDashboardView()
                    .environmentObject(supabase)
            }
            .tabItem {
                Label("Dispatch", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .tag("dispatch")

            DispatcherAccountView()
                .tabItem {
                    Label("Account", systemImage: "person.crop.circle.fill")
                }
                .tag("account")
        }
        .tint(Color.spGold)
        .onAppear {
            dispatch.activeRole = .dispatcher
        }
    }
}

struct CarrierRootView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared

    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag("home")

            LoadsListView()
                .tabItem {
                    Label("Loads", systemImage: "shippingbox.fill")
                }
                .tag("loads")

            ExpensesListView()
                .tabItem {
                    Label("Expenses", systemImage: "creditcard.fill")
                }
                .tag("expenses")

            CarrierDispatchView()
                .environmentObject(supabase)
                .tabItem {
                    Label("Dispatch", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .tag("dispatch")

            SettingsView(roleOverride: .carrier)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag("settings")
        }
        .tint(Color.spGold)
        .onAppear {
            dispatch.activeRole = .carrier
        }
    }
}

struct DriverRootView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared

    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag("home")

            LoadsListView()
                .tabItem {
                    Label("Loads", systemImage: "shippingbox.fill")
                }
                .tag("loads")

            ExpensesListView()
                .tabItem {
                    Label("Expenses", systemImage: "creditcard.fill")
                }
                .tag("expenses")

            DriverDispatchView()
                .environmentObject(supabase)
                .tabItem {
                    Label("Dispatch", systemImage: "message.fill")
                }
                .tag("dispatch")

            SettingsView(roleOverride: .driver)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag("settings")
        }
        .tint(Color.spGold)
        .onAppear {
            dispatch.activeRole = .driver
        }
    }
}

struct OwnerOperatorRootView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared

    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag("home")

            LoadsListView()
                .tabItem {
                    Label("Loads", systemImage: "shippingbox.fill")
                }
                .tag("loads")

            ExpensesListView()
                .tabItem {
                    Label("Expenses", systemImage: "creditcard.fill")
                }
                .tag("expenses")

            OwnerOperatorDispatchView()
                .environmentObject(supabase)
                .tabItem {
                    Label("Dispatch", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .tag("dispatch")

            SettingsView(roleOverride: .ownerOperator)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag("settings")
        }
        .tint(Color.spGold)
        .onAppear {
            dispatch.activeRole = .carrier
        }
    }
}

struct DriverDispatchView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared

    var body: some View {
        NavigationStack {
            dispatchMenu(title: "Dispatch")
                .navigationTitle("Dispatch")
        }
        .onAppear {
            dispatch.activeRole = .driver
        }
        .task { await dispatch.reload(supabase: supabase) }
        .refreshable { await dispatch.reload(supabase: supabase) }
    }

    private func dispatchMenu(title: String) -> some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                RoleDispatchErrorBanner(message: dispatch.lastErrorMessage)

                Section("Load Coordination") {
                    NavigationLink {
                        DispatchLoadOffersView()
                            .environmentObject(supabase)
                    } label: {
                        RoleDispatchMenuRow(
                            title: "Load Offers",
                            subtitle: "Review, accept, or decline dispatcher offers",
                            systemImage: "doc.text.magnifyingglass",
                            badge: pendingOfferCount == 0 ? nil : "\(pendingOfferCount)"
                        )
                    }

                    NavigationLink {
                        DispatchChatThreadsView()
                            .environmentObject(supabase)
                    } label: {
                        RoleDispatchMenuRow(
                            title: "Dispatch Chat",
                            subtitle: "Load-specific messages with dispatchers",
                            systemImage: "message.fill",
                            badge: dispatch.unreadCount() == 0 ? nil : "\(dispatch.unreadCount())"
                        )
                    }

                    NavigationLink {
                        AcceptedDispatchLoadsView()
                            .environmentObject(supabase)
                    } label: {
                        RoleDispatchMenuRow(
                            title: "Accepted Dispatch Loads",
                            subtitle: "Loads created from accepted offers",
                            systemImage: "shippingbox.fill",
                            badge: acceptedOfferCount == 0 ? nil : "\(acceptedOfferCount)"
                        )
                    }
                }
                .listRowBackground(Color.spCardBg)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var pendingOfferCount: Int {
        dispatch.offers.filter { $0.status == .pending }.count
    }

    private var acceptedOfferCount: Int {
        dispatch.offers.filter { $0.status == .accepted }.count
    }
}

struct CarrierDispatchView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared

    var body: some View {
        NavigationStack {
            dispatchMenu(includeLoadOffers: false)
                .navigationTitle("Carrier Dispatch")
        }
        .onAppear {
            dispatch.activeRole = .carrier
        }
        .task { await dispatch.reload(supabase: supabase) }
        .refreshable { await dispatch.reload(supabase: supabase) }
    }

    fileprivate func dispatchMenu(includeLoadOffers: Bool) -> some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                RoleDispatchErrorBanner(message: dispatch.lastErrorMessage)

                Section("Dispatcher Network") {
                    NavigationLink {
                        DispatcherDirectoryView()
                            .environmentObject(supabase)
                    } label: {
                        RoleDispatchMenuRow(
                            title: "Dispatcher Directory",
                            subtitle: "Search dispatchers and request service",
                            systemImage: "person.3.fill",
                            badge: dispatch.dispatcherProfiles.isEmpty ? nil : "\(dispatch.dispatcherProfiles.count)"
                        )
                    }

                    NavigationLink {
                        DispatchServiceRequestsView()
                            .environmentObject(supabase)
                    } label: {
                        RoleDispatchMenuRow(
                            title: "Service Requests",
                            subtitle: "Requests sent to dispatchers",
                            systemImage: "envelope.badge.fill",
                            badge: dispatch.serviceRequests.isEmpty ? nil : "\(dispatch.serviceRequests.count)"
                        )
                    }

                    NavigationLink {
                        DispatchAgreementsView()
                            .environmentObject(supabase)
                    } label: {
                        RoleDispatchMenuRow(
                            title: "Agreements",
                            subtitle: "Active dispatcher service terms",
                            systemImage: "doc.text.fill",
                            badge: dispatch.activeAgreements().isEmpty ? nil : "\(dispatch.activeAgreements().count)"
                        )
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Tracking") {
                    NavigationLink {
                        DispatcherNetworkInvoicesView()
                            .environmentObject(supabase)
                    } label: {
                        RoleDispatchMenuRow(
                            title: "Invoice History",
                            subtitle: "Payment tracking only, no in-app payment collection",
                            systemImage: "doc.richtext.fill",
                            badge: dispatch.invoices.isEmpty ? nil : "\(dispatch.invoices.count)"
                        )
                    }

                    NavigationLink {
                        DispatcherPaymentsView()
                            .environmentObject(supabase)
                    } label: {
                        RoleDispatchMenuRow(
                            title: "Payment Tracking",
                            subtitle: "Track owed, pending, paid, and overdue status",
                            systemImage: "creditcard.fill",
                            badge: unpaidPaymentCount == 0 ? nil : "\(unpaidPaymentCount)"
                        )
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Communication") {
                    if includeLoadOffers {
                        NavigationLink {
                            DispatchLoadOffersView()
                                .environmentObject(supabase)
                        } label: {
                            RoleDispatchMenuRow(
                                title: "Load Offers",
                                subtitle: "Review offers sent through dispatch",
                                systemImage: "doc.text.magnifyingglass",
                                badge: pendingOfferCount == 0 ? nil : "\(pendingOfferCount)"
                            )
                        }

                        NavigationLink {
                            AcceptedDispatchLoadsView()
                                .environmentObject(supabase)
                        } label: {
                            RoleDispatchMenuRow(
                                title: "Accepted Dispatch Loads",
                                subtitle: "Loads created from accepted offers",
                                systemImage: "shippingbox.fill",
                                badge: acceptedOfferCount == 0 ? nil : "\(acceptedOfferCount)"
                            )
                        }
                    }

                    NavigationLink {
                        DispatchChatThreadsView()
                            .environmentObject(supabase)
                    } label: {
                        RoleDispatchMenuRow(
                            title: "Dispatch Chat",
                            subtitle: "Messages tied to dispatch work",
                            systemImage: "message.fill",
                            badge: dispatch.unreadCount() == 0 ? nil : "\(dispatch.unreadCount())"
                        )
                    }
                }
                .listRowBackground(Color.spCardBg)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var pendingOfferCount: Int {
        dispatch.offers.filter { $0.status == .pending }.count
    }

    private var acceptedOfferCount: Int {
        dispatch.offers.filter { $0.status == .accepted }.count
    }

    private var unpaidPaymentCount: Int {
        dispatch.payments.filter { $0.paymentStatus != .paid }.count
    }
}

struct OwnerOperatorDispatchView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared

    var body: some View {
        NavigationStack {
            CarrierDispatchView()
                .environmentObject(supabase)
        }
        .onAppear {
            dispatch.activeRole = .carrier
        }
    }
}

struct DispatcherAccountView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var subscriptions = SubscriptionService.shared
    @ObservedObject private var appearance = AppearanceService.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Profile") {
                    NavigationLink {
                        EditCompanyView()
                            .environmentObject(supabase)
                    } label: {
                        HStack {
                            Image(systemName: "building.2.fill")
                                .foregroundStyle(Color.spGold)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(supabase.currentProfile?.companyName ?? "Dispatcher Profile")
                                    .foregroundStyle(Color.spTextPrimary)
                                Text("Account role: Dispatcher")
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextSecondary)
                            }
                        }
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Appearance") {
                    HStack {
                        Image(systemName: "circle.lefthalf.filled")
                            .foregroundStyle(Color.spGold)
                        Text("Theme")
                            .foregroundStyle(Color.spTextPrimary)
                        Spacer()
                        Picker("", selection: $appearance.mode) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Color.spGold)
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Security") {
                    NavigationLink {
                        PinSettingsView()
                    } label: {
                        HStack {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(Color.spGold)
                            Text("App Lock / PIN")
                                .foregroundStyle(Color.spTextPrimary)
                        }
                    }
                }
                .listRowBackground(Color.spCardBg)

                if FeatureFlags.subscriptionsEnabled {
                    Section("Subscription") {
                        NavigationLink {
                            SubscriptionSettingsView()
                        } label: {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(Color.spGold)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Plan & Billing")
                                        .foregroundStyle(Color.spTextPrimary)
                                    Text("Current: \(subscriptions.activeTier.displayName)")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.spCardBg)
                }

                Section("Legal") {
                    Link(destination: Config.Legal.privacyPolicyURL) {
                        Label("Privacy Policy", systemImage: "lock.shield")
                            .foregroundStyle(Color.spTextPrimary)
                    }
                    Link(destination: Config.Legal.termsOfServiceURL) {
                        Label("Terms of Service", systemImage: "doc.text")
                            .foregroundStyle(Color.spTextPrimary)
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Account") {
                    NavigationLink {
                        DeleteAccountView()
                            .environmentObject(supabase)
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.xmark")
                                .foregroundStyle(Color.spDanger)
                            Text("Delete Account")
                                .foregroundStyle(Color.spTextPrimary)
                        }
                    }

                    Button("Sign Out", role: .destructive) {
                        Task { try? await supabase.signOut() }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .listRowBackground(Color.spCardBg)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.spBackground)
            .navigationTitle("Account")
        }
    }
}

struct AccountRoleSelectionView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var selectedRole: AccountRole?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image("SacredPathwayLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                VStack(spacing: 8) {
                    Text("Choose Your Account Role")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.spGold)
                        .multilineTextAlignment(.center)
                    Text("This controls which dashboard and tools your account can use.")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 28)

                VStack(spacing: 10) {
                    ForEach(AccountRole.allCases) { role in
                        AccountRoleOptionRow(
                            role: role,
                            isSelected: selectedRole == role,
                            action: { selectedRole = role }
                        )
                    }
                }
                .padding(.horizontal, 24)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.spDanger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                Spacer()

                Button {
                    Task { await saveRole() }
                } label: {
                    HStack {
                        if isSaving {
                            ProgressView()
                                .tint(Color.spBlack)
                        }
                        Text(isSaving ? "Saving..." : "Continue")
                            .font(.headline)
                    }
                    .foregroundStyle(Color.spBlack)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.spGold)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isSaving || selectedRole == nil)
                .opacity((isSaving || selectedRole == nil) ? 0.55 : 1)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .alert("Role save failed",
               isPresented: Binding(
                   get: { errorMessage != nil },
                   set: { if !$0 { errorMessage = nil } }
               )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func saveRole() async {
        guard let selectedRole else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await supabase.setAccountRole(selectedRole)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

private struct AccountRoleOptionRow: View {
    let role: AccountRole
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: accountRoleSystemImage(role))
                    .font(.title3.weight(.semibold))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(role.displayName)
                        .font(.headline)
                    Text(role.onboardingDescription)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.spBlack.opacity(0.74) : Color.spTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
            }
            .foregroundStyle(isSelected ? Color.spBlack : Color.spTextPrimary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.spGold : Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.spGold : Color.spTextSecondary.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct RoleDispatchMenuRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var badge: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.spGold)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(Color.spTextPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.spBlack)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.spGold)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RoleDispatchErrorBanner: View {
    let message: String?

    var body: some View {
        if let message, !message.isEmpty {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Color.spDanger)
                .listRowBackground(Color.spCardBg)
        }
    }
}

private func accountRoleSystemImage(_ role: AccountRole) -> String {
    switch role {
    case .dispatcher: return "point.3.connected.trianglepath.dotted"
    case .carrier: return "building.2.fill"
    case .driver: return "steeringwheel"
    case .ownerOperator: return "truck.box.fill"
    }
}

#Preview {
    ContentView()
        .environmentObject(SupabaseService())
}
