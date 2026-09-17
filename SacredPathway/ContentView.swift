import SwiftUI

struct ContentView: View {
    @EnvironmentObject var supabase: SupabaseService
    @StateObject private var pinService = PinLockService.shared
    @ObservedObject private var appMode = AppMode.shared
    @ObservedObject private var subscriptions = SubscriptionService.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var didAttemptProfileRefresh = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // ScreenshotMode takes a hard fast-path so App Store screenshots
            // stay deterministic and do not get blocked by PIN or account role
            // setup. Production runs unaffected.
            if ScreenshotMode.isActive || DriverHubUITestMode.isActive {
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
            if ScreenshotMode.isActive || DriverHubUITestMode.isActive {
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
            if ScreenshotMode.isActive || DriverHubUITestMode.isActive { return }
            if phase == .background {
                pinService.lock()
            }
        }
    }

    @ViewBuilder
    private var roleRoutedRoot: some View {
        if appMode.isLocal {
            OwnerOperatorRootView()
        } else if let role = subscriptions.entitledAccountRole {
            rootView(for: role)
        } else if supabase.isAuthenticated {
            if didAttemptProfileRefresh {
                entitlementRequiredView
            } else {
                roleLoadingView
                    .task {
                        await subscriptions.refreshEntitlements()
                        await supabase.fetchProfile()
                        didAttemptProfileRefresh = true
                    }
            }
        } else {
            OwnerOperatorRootView()
        }
    }

    private var entitlementRequiredView: some View {
        PaywallView(
            isGatedFullScreen: true,
            onSignOut: {
                Task { try? await supabase.signOut() }
            }
        )
        .environmentObject(supabase)
        .environmentObject(subscriptions)
    }

    @ViewBuilder
    private func rootView(for role: AccountRole) -> some View {
        switch role {
        case .dispatcher:
            FutureDispatcherAppBoundaryView()
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

    var body: some View {
        FutureDispatcherAppBoundaryView()
            .environmentObject(supabase)
    }
}

struct FutureDispatcherAppBoundaryView: View {
    @EnvironmentObject var supabase: SupabaseService

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Dispatcher App Required", systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.headline)
                                .foregroundStyle(Color.spGold)
                            Text("Driver Hub is limited to the driver-facing side of dispatch communication.")
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextPrimary)
                            Text("Dispatcher dashboards, directories, load-board tools, invoices, fee records, and payment workflows belong in the future separate Dispatcher App.")
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(Color.spCardBg)

                    Section("Account") {
                        Button("Sign Out", role: .destructive) {
                            Task { try? await supabase.signOut() }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .listRowBackground(Color.spCardBg)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Driver Hub")
        }
    }
}

struct CarrierRootView: View {
    @EnvironmentObject var supabase: SupabaseService

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

            // Live Rate Map, Weather Map, and Sacred Path. Owner-Operator and Carrier only.
            if MapFeatureFlags.enabled {
                MapsHubView()
                    .tabItem {
                        Label("Maps", systemImage: "map.fill")
                    }
                    .tag("maps")
            }

            SettingsView(roleOverride: .carrier)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag("settings")
        }
        .tint(Color.spGold)
        .onAppear {
            DispatchService.shared.activeRole = .carrier
        }
    }
}

struct DriverRootView: View {
    @EnvironmentObject var supabase: SupabaseService

    var body: some View {
        TabView {
            DriverSimpleDashboardView()
                .environmentObject(supabase)
                .tabItem {
                    Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
                }
                .tag("dashboard")

            DriverSimpleLoadsView()
                .environmentObject(supabase)
                .tabItem {
                    Label("Loads", systemImage: "shippingbox.fill")
                }
                .tag("loads")

            DriverPaycheckView()
                .environmentObject(supabase)
                .tabItem {
                    Label("Paycheck", systemImage: "dollarsign.circle.fill")
                }
                .tag("paycheck")

            DriverExpensesView()
                .environmentObject(supabase)
                .tabItem {
                    Label("Expenses", systemImage: "receipt.fill")
                }
                .tag("expenses")

            DriverMessagesProfileView()
                .environmentObject(supabase)
                .tabItem {
                    Label(FeatureFlags.dispatcherConnectEnabled ? "Dispatch" : "Profile",
                          systemImage: FeatureFlags.dispatcherConnectEnabled ? "point.3.connected.trianglepath.dotted" : "person.crop.circle.fill")
                }
                .tag("dispatch")
        }
        .tint(Color.spGold)
        .onAppear {
            DispatchService.shared.activeRole = .driver
        }
    }
}

struct OwnerOperatorRootView: View {
    @EnvironmentObject var supabase: SupabaseService

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

            // Live Rate Map, Weather Map, and Sacred Path. Owner-Operator and Carrier only.
            if MapFeatureFlags.enabled {
                MapsHubView()
                    .tabItem {
                        Label("Maps", systemImage: "map.fill")
                    }
                    .tag("maps")
            }

            SettingsView(roleOverride: .ownerOperator)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag("settings")
        }
        .tint(Color.spGold)
        .onAppear {
            DispatchService.shared.activeRole = .carrier
        }
    }
}

enum DriverPayType: String, CaseIterable, Identifiable {
    case percentage = "percentage"
    case ratePerMile = "rate_per_mile"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .percentage: return "Percentage Pay"
        case .ratePerMile: return "Rate Per Mile"
        }
    }

    var shortName: String {
        switch self {
        case .percentage: return "Percentage"
        case .ratePerMile: return "Per Mile"
        }
    }
}

enum DriverModeLoadStatus: String, CaseIterable, Identifiable {
    case upcoming
    case inProgress = "in_progress"
    case delivered
    case paid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .upcoming: return "Upcoming"
        case .inProgress: return "In Progress"
        case .delivered: return "Delivered"
        case .paid: return "Paid"
        }
    }

    var systemImage: String {
        switch self {
        case .upcoming: return "calendar"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case .delivered: return "checkmark.seal.fill"
        case .paid: return "dollarsign.circle.fill"
        }
    }
}

enum DriverExpenseCategory: String, CaseIterable, Identifiable {
    case fuel
    case food
    case lodging
    case maintenance
    case advances
    case other

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .fuel: return "fuelpump.fill"
        case .food: return "fork.knife"
        case .lodging: return "bed.double.fill"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .advances: return "banknote.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }
}

enum DispatcherExpenseCategory: String, CaseIterable, Identifiable {
    case software
    case phone
    case office
    case marketing
    case driverSupport = "driver_support"
    case factoringAdmin = "factoring_admin"
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .software: return "Software"
        case .phone: return "Phone"
        case .office: return "Office"
        case .marketing: return "Marketing"
        case .driverSupport: return "Driver Support"
        case .factoringAdmin: return "Factoring/Admin"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .software: return "laptopcomputer"
        case .phone: return "phone.fill"
        case .office: return "printer.fill"
        case .marketing: return "megaphone.fill"
        case .driverSupport: return "person.fill.checkmark"
        case .factoringAdmin: return "folder.fill.badge.gearshape"
        case .other: return "ellipsis.circle.fill"
        }
    }
}

struct DriverLoadPaySummary: Identifiable {
    let id: UUID
    let load: Load
    let driverGross: Double
}

struct DriverContact: Identifiable {
    let id: UUID
    let profileId: UUID
    let displayName: String
    let phone: String?
    let email: String?
    let truckNumber: String?
    let trailerNumber: String?
    let currentStatus: String
    let notes: String?
    let thread: DispatchThread?
    let currentLoads: [DispatchLoadOffer]
}

@MainActor
final class DriverPaySettingsStore: ObservableObject {
    static let shared = DriverPaySettingsStore()

    @Published var payType: DriverPayType {
        didSet { save() }
    }
    @Published var driverPercentage: Double {
        didSet { save() }
    }
    @Published var ratePerMile: Double {
        didSet { save() }
    }

    private let payTypeKey = "sph.driverMode.payType"
    private let percentageKey = "sph.driverMode.percentage"
    private let ratePerMileKey = "sph.driverMode.ratePerMile"

    private init() {
        let defaults = UserDefaults.standard
        let storedType = defaults.string(forKey: payTypeKey)
            .flatMap(DriverPayType.init(rawValue:)) ?? .percentage
        payType = storedType

        let storedPercentage = defaults.double(forKey: percentageKey)
        driverPercentage = storedPercentage > 0 ? storedPercentage : 25

        let storedRate = defaults.double(forKey: ratePerMileKey)
        ratePerMile = storedRate > 0 ? storedRate : 0.65
    }

    func hydrate(from profile: Profile?) {
        if let raw = profile?.payBasis, let profileType = DriverPayType(rawValue: raw) {
            payType = profileType
        }
        if let percent = profile?.driverPayPercentage, percent > 0 {
            driverPercentage = percent
        }
    }

    func syncCloudProfileIfPossible(supabase: SupabaseService) async {
        guard !AppMode.shared.isLocal, supabase.isAuthenticated else { return }
        var updates: [String: AnyEncodable] = [
            "pay_basis": AnyEncodable(payType.rawValue)
        ]
        if payType == .percentage {
            updates["driver_pay_percentage"] = AnyEncodable(driverPercentage)
        }
        try? await supabase.updateProfile(updates)
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(payType.rawValue, forKey: payTypeKey)
        defaults.set(driverPercentage, forKey: percentageKey)
        defaults.set(ratePerMile, forKey: ratePerMileKey)
    }
}

@MainActor
enum DriverProfileLocalStore {
    private static let nameKey = "sph.driverProfile.name"
    private static let phoneKey = "sph.driverProfile.phone"

    static func driverName(profile: Profile?) -> String {
        if AppMode.shared.isLocal {
            return clean(UserDefaults.standard.string(forKey: nameKey))
        }
        return clean(profile?.companyName)
    }

    static func phone(profile: Profile?) -> String {
        if AppMode.shared.isLocal {
            return clean(UserDefaults.standard.string(forKey: phoneKey))
        }
        return clean(profile?.phone)
    }

    static func saveLocal(driverName: String, phone: String) {
        UserDefaults.standard.set(clean(driverName), forKey: nameKey)
        UserDefaults.standard.set(clean(phone), forKey: phoneKey)
    }

    private static func clean(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

@MainActor
enum DriverModeMath {
    static func loadDate(_ load: Load) -> Date? {
        // Delivery first, then pickup, then createdAt — identical priority to
        // WeeklyStatsService.windowDate so loads bucket into the same week
        // everywhere (driver views + owner-operator dashboard). Loads count on
        // the day they deliver.
        load.deliveryDate ?? load.pickupDate ?? load.createdAt
    }

    static func weeklyLoads(_ loads: [Load], now: Date = Date()) -> [Load] {
        let interval = PayWeekService.shared.weekInterval(for: now)
        return loads.filter { load in
            guard let date = loadDate(load) else { return false }
            return date >= interval.start && date < interval.end
        }
    }

    static func weeklyExpenses(_ expenses: [Expense], now: Date = Date()) -> [Expense] {
        let interval = PayWeekService.shared.weekInterval(for: now)
        return expenses.filter { expense in
            guard let date = expense.receiptDate ?? expense.createdAt else { return false }
            return date >= interval.start && date < interval.end
        }
    }

    static func driverGross(for load: Load, settings: DriverPaySettingsStore) -> Double {
        let payType = DriverPayType(rawValue: load.driverPayType ?? "") ?? settings.payType
        switch payType {
        case .percentage:
            let percentage = load.driverPercentage ?? settings.driverPercentage
            return max(0, (load.totalRevenue ?? 0) * (percentage / 100))
        case .ratePerMile:
            let rate = load.driverRatePerMile ?? settings.ratePerMile
            return max(0, (load.totalMiles ?? 0) * rate)
        }
    }

    static func summaries(for loads: [Load], settings: DriverPaySettingsStore) -> [DriverLoadPaySummary] {
        loads.map { load in
            DriverLoadPaySummary(
                id: load.id ?? UUID(),
                load: load,
                driverGross: driverGross(for: load, settings: settings)
            )
        }
    }

    static func status(from load: Load) -> DriverModeLoadStatus {
        DriverModeLoadStatus(rawValue: load.status ?? "") ?? .upcoming
    }

    static func statusText(from load: Load) -> String {
        status(from: load).displayName
    }
}

struct DriverSimpleDashboardView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var appMode = AppMode.shared
    @ObservedObject private var localLoads = LocalLoadsRepository.shared
    @ObservedObject private var localExpenses = LocalExpensesRepository.shared
    @ObservedObject private var settings = DriverPaySettingsStore.shared
    @State private var loads: [Load] = []
    @State private var expenses: [Expense] = []
    @State private var isLoading = true
    @State private var showingLoadEntry = false
    @State private var showingExpenseEntry = false

    private var sourceLoads: [Load] {
        appMode.isLocal ? localLoads.loads : loads
    }

    private var sourceExpenses: [Expense] {
        appMode.isLocal ? localExpenses.expenses : expenses
    }

    private var weeklyLoads: [Load] {
        DriverModeMath.weeklyLoads(sourceLoads)
    }

    private var weeklyExpenses: [Expense] {
        DriverModeMath.weeklyExpenses(sourceExpenses)
    }

    private var totalDriverGross: Double {
        weeklyLoads.reduce(0) { $0 + DriverModeMath.driverGross(for: $1, settings: settings) }
    }

    private var totalExpenses: Double {
        weeklyExpenses.reduce(0) { $0 + $1.amount }
    }

    private var weeklyNet: Double {
        totalDriverGross - totalExpenses
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        if appMode.isLocal {
                            LocalModeBanner()
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            Text("Driver Dashboard")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Color.spTextPrimary)
                            Text("Weekly pay, loads, miles, and road expenses.")
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextSecondary)

                            HStack(spacing: 10) {
                                DriverMetricTile(title: "Paycheck", value: totalDriverGross.asCurrency, systemImage: "dollarsign.circle.fill")
                                DriverMetricTile(title: "Net Estimate", value: weeklyNet.asCurrency, systemImage: "chart.line.uptrend.xyaxis")
                            }
                            HStack(spacing: 10) {
                                DriverMetricTile(title: "Loads", value: "\(weeklyLoads.count)", systemImage: "shippingbox.fill")
                                DriverMetricTile(title: "Expenses", value: totalExpenses.asCurrency, systemImage: "receipt.fill")
                            }
                        }
                        .padding(16)
                        .background(Color.spCardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)

                        DriverPayTypeCard(supabase: supabase)
                            .padding(.horizontal)

                        HStack(spacing: 10) {
                            Button {
                                showingLoadEntry = true
                            } label: {
                                Label("Add Load", systemImage: "plus.circle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                            }
                            .background(Color.spGold)
                            .foregroundStyle(Color.spBlack)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("dashboard.addLoad")

                            Button {
                                showingExpenseEntry = true
                            } label: {
                                Label("Expense", systemImage: "receipt.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                            }
                            .background(Color.spCardBg)
                            .foregroundStyle(Color.spTextPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("dashboard.addExpense")
                        }
                        .padding(.horizontal)

                        DriverWeeklyLoadSummaryCard(
                            summaries: DriverModeMath.summaries(for: weeklyLoads, settings: settings)
                        )
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 14)
                }
            }
            .navigationTitle("Dashboard")
            .task { await loadData() }
            .refreshable { await loadData() }
            .sheet(isPresented: $showingLoadEntry, onDismiss: reload) {
                DriverLoadEntryView()
                    .environmentObject(supabase)
            }
            .sheet(isPresented: $showingExpenseEntry, onDismiss: reload) {
                DriverExpenseEntryView()
                    .environmentObject(supabase)
            }
            .onReceive(NotificationCenter.default.publisher(for: .loadsDidChange)) { _ in reload() }
            .onReceive(NotificationCenter.default.publisher(for: .expensesDidChange)) { _ in reload() }
        }
    }

    private func loadData() async {
        settings.hydrate(from: supabase.currentProfile)
        if appMode.isLocal {
            localLoads.reload()
            localExpenses.reload()
            isLoading = false
            return
        }
        do {
            async let fetchedLoads = supabase.fetchLoads()
            async let fetchedExpenses = supabase.fetchAllExpenses()
            loads = try await fetchedLoads
            expenses = try await fetchedExpenses
        } catch {
            #if DEBUG
            print("[DriverMode] dashboard load failed: \(error)")
            #endif
        }
        isLoading = false
    }

    private func reload() {
        Task { await loadData() }
    }
}

struct DriverSimpleLoadsView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var appMode = AppMode.shared
    @ObservedObject private var localLoads = LocalLoadsRepository.shared
    @ObservedObject private var settings = DriverPaySettingsStore.shared
    @State private var loads: [Load] = []
    @State private var isLoading = true
    @State private var showingLoadEntry = false
    @State private var showAllLoads = false

    private var sourceLoads: [Load] {
        appMode.isLocal ? localLoads.loads : loads
    }

    private var visibleLoads: [Load] {
        let base = showAllLoads ? sourceLoads : DriverModeMath.weeklyLoads(sourceLoads)
        return base.sorted {
            (DriverModeMath.loadDate($0) ?? .distantPast) > (DriverModeMath.loadDate($1) ?? .distantPast)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    if appMode.isLocal {
                        LocalModeBanner()
                    }

                    Picker("", selection: $showAllLoads) {
                        Text("This Week").tag(false)
                        Text("All Loads").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding()

                    if isLoading {
                        Spacer()
                        ProgressView().tint(Color.spGold)
                        Spacer()
                    } else if visibleLoads.isEmpty {
                        Spacer()
                        DriverEmptyState(
                            systemImage: "shippingbox",
                            title: showAllLoads ? "No loads yet" : "No loads this week",
                            message: "Add a simple driver load to calculate your paycheck estimate."
                        )
                        Spacer()
                    } else {
                        List {
                            ForEach(visibleLoads) { load in
                                DriverLoadSimpleRow(load: load, driverGross: DriverModeMath.driverGross(for: load, settings: settings))
                                    .listRowBackground(Color.spCardBg)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Loads")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingLoadEntry = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.spGold)
                    }
                }
            }
            .task { await loadData() }
            .refreshable { await loadData() }
            .sheet(isPresented: $showingLoadEntry, onDismiss: reload) {
                DriverLoadEntryView()
                    .environmentObject(supabase)
            }
            .onReceive(NotificationCenter.default.publisher(for: .loadsDidChange)) { _ in reload() }
        }
    }

    private func loadData() async {
        settings.hydrate(from: supabase.currentProfile)
        if appMode.isLocal {
            localLoads.reload()
            isLoading = false
            return
        }
        do {
            loads = try await supabase.fetchLoads()
        } catch {
            #if DEBUG
            print("[DriverMode] loads load failed: \(error)")
            #endif
        }
        isLoading = false
    }

    private func reload() {
        Task { await loadData() }
    }
}

struct DriverPaycheckView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var appMode = AppMode.shared
    @ObservedObject private var localLoads = LocalLoadsRepository.shared
    @ObservedObject private var localExpenses = LocalExpensesRepository.shared
    @ObservedObject private var settings = DriverPaySettingsStore.shared
    @State private var loads: [Load] = []
    @State private var expenses: [Expense] = []
    @State private var isLoading = true

    private var sourceLoads: [Load] {
        appMode.isLocal ? localLoads.loads : loads
    }

    private var sourceExpenses: [Expense] {
        appMode.isLocal ? localExpenses.expenses : expenses
    }

    private var weeklyLoads: [Load] {
        DriverModeMath.weeklyLoads(sourceLoads)
    }

    private var weeklyExpenses: [Expense] {
        DriverModeMath.weeklyExpenses(sourceExpenses)
    }

    private var gross: Double {
        weeklyLoads.reduce(0) { $0 + DriverModeMath.driverGross(for: $1, settings: settings) }
    }

    private var expensesTotal: Double {
        weeklyExpenses.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                List {
                    if appMode.isLocal {
                        LocalModeBanner()
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }

                    Section {
                        DriverPayTypeCard(supabase: supabase)
                    }
                    .listRowBackground(Color.spCardBg)

                    Section("This Week") {
                        DriverInfoRow("Driver Gross", value: gross.asCurrency, systemImage: "dollarsign.circle.fill")
                        DriverInfoRow("Expenses", value: expensesTotal.asCurrency, systemImage: "receipt.fill")
                        DriverInfoRow("Weekly Net", value: (gross - expensesTotal).asCurrency, systemImage: "equal.circle.fill")
                        DriverInfoRow("Loads", value: "\(weeklyLoads.count)", systemImage: "shippingbox.fill")
                    }
                    .listRowBackground(Color.spCardBg)

                    Section("Load Pay") {
                        if weeklyLoads.isEmpty {
                            Text("No loads in this pay week yet.")
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextSecondary)
                        } else {
                            ForEach(DriverModeMath.summaries(for: weeklyLoads, settings: settings)) { summary in
                                DriverPaySummaryRow(summary: summary)
                            }
                        }
                    }
                    .listRowBackground(Color.spCardBg)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Paycheck")
            .task { await loadData() }
            .refreshable { await loadData() }
            .onReceive(NotificationCenter.default.publisher(for: .loadsDidChange)) { _ in reload() }
            .onReceive(NotificationCenter.default.publisher(for: .expensesDidChange)) { _ in reload() }
        }
    }

    private func loadData() async {
        settings.hydrate(from: supabase.currentProfile)
        if appMode.isLocal {
            localLoads.reload()
            localExpenses.reload()
            isLoading = false
            return
        }
        do {
            async let fetchedLoads = supabase.fetchLoads()
            async let fetchedExpenses = supabase.fetchAllExpenses()
            loads = try await fetchedLoads
            expenses = try await fetchedExpenses
        } catch {
            #if DEBUG
            print("[DriverMode] paycheck load failed: \(error)")
            #endif
        }
        isLoading = false
    }

    private func reload() {
        Task { await loadData() }
    }
}

struct DriverExpensesView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var appMode = AppMode.shared
    @ObservedObject private var localExpenses = LocalExpensesRepository.shared
    @State private var expenses: [Expense] = []
    @State private var isLoading = true
    @State private var showingExpenseEntry = false
    @State private var selectedCategory: DriverExpenseCategory?

    private var sourceExpenses: [Expense] {
        appMode.isLocal ? localExpenses.expenses : expenses
    }

    private var driverExpenses: [Expense] {
        sourceExpenses.filter { expense in
            DriverExpenseCategory(rawValue: expense.category) != nil
        }
    }

    private var visibleExpenses: [Expense] {
        let filtered = selectedCategory.map { category in
            driverExpenses.filter { $0.category == category.rawValue }
        } ?? driverExpenses
        return filtered.sorted { ($0.receiptDate ?? .distantPast) > ($1.receiptDate ?? .distantPast) }
    }

    private var weeklyTotal: Double {
        DriverModeMath.weeklyExpenses(driverExpenses).reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    if appMode.isLocal {
                        LocalModeBanner()
                    }

                    VStack(spacing: 6) {
                        Text("This Week")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                        Text(weeklyTotal.asCurrency)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.spDanger)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.spCardBg)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            DriverCategoryChip(title: "All", isSelected: selectedCategory == nil) {
                                selectedCategory = nil
                            }
                            ForEach(DriverExpenseCategory.allCases) { category in
                                DriverCategoryChip(title: category.displayName, isSelected: selectedCategory == category) {
                                    selectedCategory = category
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                    }

                    if isLoading {
                        Spacer()
                        ProgressView().tint(Color.spGold)
                        Spacer()
                    } else if visibleExpenses.isEmpty {
                        Spacer()
                        DriverEmptyState(systemImage: "receipt", title: "No expenses yet", message: "Track fuel, food, lodging, maintenance, advances, and other road costs.")
                        Spacer()
                    } else {
                        List {
                            ForEach(visibleExpenses) { expense in
                                DriverExpenseSimpleRow(expense: expense)
                                    .listRowBackground(Color.spCardBg)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Expenses")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingExpenseEntry = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.spGold)
                    }
                }
            }
            .task { await loadData() }
            .refreshable { await loadData() }
            .sheet(isPresented: $showingExpenseEntry, onDismiss: reload) {
                DriverExpenseEntryView()
                    .environmentObject(supabase)
            }
            .onReceive(NotificationCenter.default.publisher(for: .expensesDidChange)) { _ in reload() }
        }
    }

    private func loadData() async {
        if appMode.isLocal {
            localExpenses.reload()
            isLoading = false
            return
        }
        do {
            expenses = try await supabase.fetchAllExpenses()
        } catch {
            #if DEBUG
            print("[DriverMode] expenses load failed: \(error)")
            #endif
        }
        isLoading = false
    }

    private func reload() {
        Task { await loadData() }
    }
}

struct DriverMessagesProfileView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var driverDispatch = DriverDispatchClient.shared
    @ObservedObject private var forceUpdate = ForceUpdateService.shared
    @ObservedObject private var subscriptions = SubscriptionService.shared

    // Final runtime gate for the dispatcher↔driver Messages UI. Compile-time flag AND
    // the remote kill switch must both be on; remote default is ON (nil → true) so the
    // invite loop works out of the box — set `dispatcher_messages_enabled: false` in
    // the hosted config to kill it.
    private var messagesEnabled: Bool {
        FeatureFlags.dispatcherConnectEnabled
            && (forceUpdate.config?.dispatcherMessagesEnabled ?? true)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                List {
                    if messagesEnabled {
                        Section("Dispatcher Connect") {
                            driverConnectEmptyState
                            conversationInboxPlaceholder
                            loadOfferPlaceholder
                        }
                        .listRowBackground(Color.spCardBg)

                        Section("Status") {
                            statusControls
                        }
                        .listRowBackground(Color.spCardBg)

                        Section("Connection Safety") {
                            connectionSafetyActions
                        }
                        .listRowBackground(Color.spCardBg)

                        if let message = driverDispatch.lastMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(Color.spTextSecondary)
                                .listRowBackground(Color.spCardBg)
                        }
                    } else if FeatureFlags.dispatcherConnectEnabled {
                        Section("Dispatcher Connect") {
                            Text("Dispatcher messaging is not available yet.")
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                        .listRowBackground(Color.spCardBg)
                    }

                    // Driver Connections (find/invite/message dispatchers) — DEFAULT ON.
                    // Remote `connectionsEnabled: false` in the hosted config is the
                    // kill switch that hides it.
                    if forceUpdate.config?.connectionsEnabled ?? true {
                        Section("Dispatchers") {
                            NavigationLink {
                                DriverConnectionsView()
                                    .environmentObject(supabase)
                            } label: {
                                RoleDispatchMenuRow(
                                    title: "Dispatchers",
                                    subtitle: "Connect & message dispatchers",
                                    systemImage: "person.2.fill"
                                )
                            }
                        }
                        .listRowBackground(Color.spCardBg)
                    }

                    Section("Profile") {
                        AccountModeSummaryRow(role: subscriptions.entitledAccountRole ?? .driver)

                        NavigationLink {
                            DriverProfileEditView()
                                .environmentObject(supabase)
                        } label: {
                            RoleDispatchMenuRow(
                                title: "Driver Profile",
                                subtitle: supabase.currentProfile?.companyName ?? "Name, phone, equipment",
                                systemImage: "person.crop.circle.fill"
                            )
                        }

                        Button("Sign Out", role: .destructive) {
                            Task { try? await supabase.signOut() }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .listRowBackground(Color.spCardBg)

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
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(messagesEnabled ? "Dispatch" : "Profile")
            .onAppear {
                driverDispatch.reloadPlaceholders()
            }
        }
    }

    private var driverConnectEmptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Dispatcher Connect", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
                .foregroundStyle(Color.spGold)
            Text("Connect with a dispatcher to receive load offers and updates.")
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
            Text("Driver Hub only shows the driver side of dispatch communication. Dispatcher dashboards and load-board tools belong in the future separate Dispatcher App.")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
        }
        .padding(.vertical, 6)
    }

    // Routes to the live Dispatchers chat area instead of the legacy placeholder
    // (which always claimed "No dispatcher conversations yet" even with an active
    // connection — conversations live in DriverConnectionsView, not the legacy
    // DriverDispatchClient store).
    private var conversationInboxPlaceholder: some View {
        NavigationLink {
            DriverConnectionsView()
                .environmentObject(supabase)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label("Conversation Inbox", systemImage: "message.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text("Chat with your connected dispatchers.")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var loadOfferPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Load Offer", systemImage: "doc.text.magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
            Text(driverDispatch.pendingOfferCount == 0 ? "No active load offer. Offers from a connected dispatcher will appear here." : "\(driverDispatch.pendingOfferCount) pending offer(s)")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
            HStack(spacing: 10) {
                Button {
                    driverDispatch.acceptPlaceholderOffer()
                } label: {
                    Label("Accept", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.spSuccess)

                Button {
                    driverDispatch.declinePlaceholderOffer()
                } label: {
                    Label("Decline", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Color.spDanger)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusControls: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
            ForEach(DriverDispatchStatus.allCases) { status in
                Button {
                    driverDispatch.setStatus(status)
                } label: {
                    Text(status.displayName)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                }
                .buttonStyle(.borderedProminent)
                .tint(driverDispatch.selectedStatus == status ? Color.spGold : Color.spCardBgLight)
                .foregroundStyle(driverDispatch.selectedStatus == status ? Color.spBlack : Color.spTextPrimary)
            }
        }
        .padding(.vertical, 4)
    }

    private var connectionSafetyActions: some View {
        VStack(spacing: 8) {
            Button {
                driverDispatch.connectionAction(.block)
            } label: {
                Label("Block Dispatcher", systemImage: "hand.raised.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                driverDispatch.connectionAction(.report)
            } label: {
                Label("Report Conversation", systemImage: "exclamationmark.bubble.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(role: .destructive) {
                driverDispatch.connectionAction(.leave)
            } label: {
                Label("Leave Connection", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct DriverProfileEditView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appMode = AppMode.shared

    @State private var driverName = ""
    @State private var phone = ""
    @State private var truckNumber = ""
    @State private var trailerNumber = ""
    @State private var isSaving = false
    @State private var savedMessage = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.spGold)
                        Text("Driver Profile")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Color.spTextPrimary)
                        Text("Keep your contact and equipment ready for new loads.")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    DriverEntryCard("Contact") {
                        DriverTextField("Name", text: $driverName, placeholder: "Driver name")
                        DriverTextField("Phone", text: $phone, placeholder: "(555) 123-4567", keyboard: .phonePad)
                    }

                    DriverEntryCard("Equipment") {
                        DriverTextField("Truck #", text: $truckNumber, placeholder: "101")
                        DriverTextField("Trailer #", text: $trailerNumber, placeholder: "TRL55")
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.spDanger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }

                    Button {
                        Task { await saveProfile() }
                    } label: {
                        if isSaving {
                            ProgressView().tint(Color.spBlack)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                        } else if savedMessage {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                        } else {
                            Label("Save Driver Profile", systemImage: "square.and.arrow.down.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                        }
                    }
                    .background(savedMessage ? Color.spSuccess : Color.spGold)
                    .foregroundStyle(Color.spBlack)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .disabled(isSaving)
                    .padding(.horizontal)
                }
                .padding(.vertical, 14)
            }
        }
        .navigationTitle("Driver Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
                    .foregroundStyle(Color.spGold)
            }
        }
        .onAppear(perform: loadCurrentValues)
    }

    private func loadCurrentValues() {
        let profile = supabase.currentProfile
        driverName = DriverProfileLocalStore.driverName(profile: profile)
        phone = DriverProfileLocalStore.phone(profile: profile)
        truckNumber = DriverEquipmentProfileStore.defaultTruckNumber(profile: profile)
        trailerNumber = DriverEquipmentProfileStore.defaultTrailerNumber(profile: profile)
    }

    private func saveProfile() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        DriverProfileLocalStore.saveLocal(driverName: driverName, phone: phone)
        DriverEquipmentProfileStore.saveLocal(truckNumber: truckNumber, trailerNumber: trailerNumber)

        if appMode.isLocal {
            showSaved()
            return
        }

        let updates: [String: AnyEncodable] = [
            "company_name": AnyEncodable(driverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil as String? : driverName),
            "phone": AnyEncodable(phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil as String? : phone),
            "truck_number": AnyEncodable(truckNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil as String? : truckNumber),
            "trailer_number": AnyEncodable(trailerNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil as String? : trailerNumber)
        ]

        do {
            try await supabase.updateProfile(updates)
            showSaved()
        } catch {
            errorMessage = "Could not save driver profile: \(error.localizedDescription)"
        }
    }

    private func showSaved() {
        withAnimation { savedMessage = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { savedMessage = false }
        }
    }
}

struct DriverLoadEntryView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = DriverPaySettingsStore.shared
    @ObservedObject private var appMode = AppMode.shared

    @State private var loadName = ""
    @State private var pickupLocation = ""
    @State private var deliveryLocation = ""
    @State private var loadedMiles = ""
    @State private var emptyMiles = ""
    @State private var grossLoadPay = ""
    @State private var payType: DriverPayType = DriverPaySettingsStore.shared.payType
    @State private var driverPercentage = String(format: "%.0f", DriverPaySettingsStore.shared.driverPercentage)
    @State private var ratePerMile = String(format: "%.2f", DriverPaySettingsStore.shared.ratePerMile)
    @State private var deliveryDate = Date()
    @State private var status: DriverModeLoadStatus = .upcoming
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var driverGross: Double {
        switch payType {
        case .percentage:
            return (Double(grossLoadPay) ?? 0) * ((Double(driverPercentage) ?? 0) / 100)
        case .ratePerMile:
            return (Double(loadedMiles) ?? 0) * (Double(ratePerMile) ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        DriverEntryCard("Load") {
                            DriverTextField("Load Name / Broker", text: $loadName, placeholder: "Broker, customer, or load name")
                            DriverTextField("Pickup", text: $pickupLocation, placeholder: "City, ST")
                            DriverTextField("Delivery", text: $deliveryLocation, placeholder: "City, ST")
                        }

                        DriverEntryCard("Miles & Pay") {
                            DriverTextField("Loaded Miles", text: $loadedMiles, placeholder: "0", keyboard: .decimalPad)
                            DriverTextField("Empty Miles", text: $emptyMiles, placeholder: "Optional", keyboard: .decimalPad)
                            DriverTextField("Gross Load Pay", text: $grossLoadPay, placeholder: "0.00", keyboard: .decimalPad, prefix: "$")

                            Picker("Pay Type", selection: $payType) {
                                ForEach(DriverPayType.allCases) { type in
                                    Text(type.shortName).tag(type)
                                }
                            }
                            .pickerStyle(.segmented)

                            if payType == .percentage {
                                DriverTextField("Driver %", text: $driverPercentage, placeholder: "25", keyboard: .decimalPad, suffix: "%")
                            } else {
                                DriverTextField("Rate / Mile", text: $ratePerMile, placeholder: "0.65", keyboard: .decimalPad, prefix: "$")
                            }

                            DriverInfoRow("Driver Gross", value: driverGross.asCurrency, systemImage: "dollarsign.circle.fill")
                        }

                        DriverEntryCard("Delivery") {
                            DatePicker("Delivery Date", selection: $deliveryDate, displayedComponents: .date)
                                .foregroundStyle(Color.spTextPrimary)

                            Picker("Status", selection: $status) {
                                ForEach(DriverModeLoadStatus.allCases) { option in
                                    Text(option.displayName).tag(option)
                                }
                            }
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(Color.spDanger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                        }

                        Button {
                            Task { await saveLoad() }
                        } label: {
                            if isSaving {
                                ProgressView().tint(Color.spBlack)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                            } else {
                                Label("Save Load", systemImage: "checkmark.circle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                            }
                        }
                        .background(Color.spGold)
                        .foregroundStyle(Color.spBlack)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .disabled(isSaving)
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                    }
                    .padding(.top, 14)
                }
            }
            .navigationTitle("Driver Load")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.spGold)
                }
            }
        }
    }

    private func saveLoad() async {
        errorMessage = nil
        guard !loadName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter a load name, broker, or customer."
            return
        }
        guard let gross = Double(grossLoadPay), gross >= 0 else {
            errorMessage = "Enter a valid gross load pay amount."
            return
        }
        guard let miles = Double(loadedMiles), miles >= 0 else {
            errorMessage = "Enter valid loaded miles."
            return
        }
        let emptyMileValue: Double?
        if emptyMiles.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyMileValue = nil
        } else if let parsed = Double(emptyMiles), parsed >= 0 {
            emptyMileValue = parsed
        } else {
            errorMessage = "Enter valid empty miles."
            return
        }

        let percentValue: Double?
        let rateValue: Double?
        switch payType {
        case .percentage:
            guard let parsedPercent = Double(driverPercentage), parsedPercent > 0, parsedPercent <= 100 else {
                errorMessage = "Enter a valid driver percentage from 1 to 100."
                return
            }
            percentValue = parsedPercent
            rateValue = nil
            settings.driverPercentage = parsedPercent
        case .ratePerMile:
            guard let parsedRate = Double(ratePerMile), parsedRate > 0 else {
                errorMessage = "Enter a valid rate per mile."
                return
            }
            percentValue = nil
            rateValue = parsedRate
            settings.ratePerMile = parsedRate
        }
        settings.payType = payType

        let profileId: UUID
        if appMode.isLocal {
            profileId = appMode.localInstallId
        } else if let id = supabase.currentProfile?.id ?? supabase.client.auth.currentUser?.id {
            profileId = id
        } else {
            errorMessage = "Sign in before saving this load."
            return
        }

        isSaving = true
        defer { isSaving = false }

        let calculatedDriverGross = DriverModeMath.driverGross(
            for: Load(
                profileId: profileId,
                totalMiles: miles,
                totalRevenue: gross,
                driverPayType: payType.rawValue,
                driverPercentage: payType == .percentage ? percentValue : nil,
                driverRatePerMile: payType == .ratePerMile ? rateValue : nil
            ),
            settings: settings
        )

        let load = Load(
            profileId: profileId,
            brokerName: cleanedOrNil(loadName),
            pickupDate: deliveryDate,
            deliveryDate: deliveryDate,
            origin: cleanedOrNil(pickupLocation),
            destination: cleanedOrNil(deliveryLocation),
            totalMiles: miles,
            emptyMiles: emptyMileValue,
            lineHaulRate: gross,
            totalRevenue: gross,
            driverPayType: payType.rawValue,
            driverPercentage: payType == .percentage ? percentValue : nil,
            driverRatePerMile: payType == .ratePerMile ? rateValue : nil,
            driverGrossPay: calculatedDriverGross,
            status: status.rawValue
        )

        if appMode.isLocal {
            _ = LocalLoadsRepository.shared.create(load)
            NotificationCenter.default.post(name: .loadsDidChange, object: nil)
            dismiss()
            return
        }

        do {
            _ = try await supabase.createLoad(load)
            await settings.syncCloudProfileIfPossible(supabase: supabase)
            dismiss()
        } catch {
            errorMessage = "Couldn't save this driver load: \(error.localizedDescription)"
        }
    }

    private func cleanedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct DriverExpenseEntryView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appMode = AppMode.shared
    @State private var category: DriverExpenseCategory = .fuel
    @State private var amount = ""
    @State private var date = Date()
    @State private var note = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        DriverEntryCard("Expense") {
                            Picker("Category", selection: $category) {
                                ForEach(DriverExpenseCategory.allCases) { category in
                                    Label(category.displayName, systemImage: category.systemImage).tag(category)
                                }
                            }

                            DriverTextField("Amount", text: $amount, placeholder: "0.00", keyboard: .decimalPad, prefix: "$")
                            DatePicker("Date", selection: $date, displayedComponents: .date)
                                .foregroundStyle(Color.spTextPrimary)
                            TextField("Note", text: $note, axis: .vertical)
                                .lineLimit(2...4)
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextPrimary)
                                .padding(12)
                                .background(Color.spCardBgLight)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(Color.spDanger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                        }

                        Button {
                            Task { await saveExpense() }
                        } label: {
                            if isSaving {
                                ProgressView().tint(Color.spBlack)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                            } else {
                                Label("Save Expense", systemImage: "checkmark.circle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                            }
                        }
                        .background(Color.spGold)
                        .foregroundStyle(Color.spBlack)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .disabled(isSaving)
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 14)
                }
            }
            .navigationTitle("Driver Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.spGold)
                }
            }
        }
    }

    private func saveExpense() async {
        errorMessage = nil
        guard let amountValue = Double(amount), amountValue > 0 else {
            errorMessage = "Enter a valid expense amount."
            return
        }

        let profileId: UUID
        if appMode.isLocal {
            profileId = appMode.localInstallId
        } else if let id = supabase.currentProfile?.id ?? supabase.client.auth.currentUser?.id {
            profileId = id
        } else {
            errorMessage = "Sign in before saving this expense."
            return
        }

        isSaving = true
        defer { isSaving = false }

        let expense = Expense(
            profileId: profileId,
            category: category.rawValue,
            amount: amountValue,
            description: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note,
            receiptDate: date
        )

        if appMode.isLocal {
            _ = LocalExpensesRepository.shared.create(expense)
            NotificationCenter.default.post(name: .expensesDidChange, object: nil)
            dismiss()
            return
        }

        do {
            _ = try await supabase.createExpense(expense)
            dismiss()
        } catch {
            errorMessage = "Couldn't save this expense: \(error.localizedDescription)"
        }
    }
}

struct DriverPayTypeCard: View {
    let supabase: SupabaseService
    @ObservedObject private var settings = DriverPaySettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Pay Type", systemImage: "dollarsign.arrow.circlepath")
                    .font(.headline)
                    .foregroundStyle(Color.spTextPrimary)
                Spacer()
            }

            Picker("Pay Type", selection: $settings.payType) {
                ForEach(DriverPayType.allCases) { type in
                    Text(type.shortName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.payType) { _, _ in
                Task { await settings.syncCloudProfileIfPossible(supabase: supabase) }
            }

            if settings.payType == .percentage {
                DriverStepperRow(
                    title: "Driver Percentage",
                    value: settings.driverPercentage,
                    suffix: "%",
                    minus: {
                        settings.driverPercentage = max(0, settings.driverPercentage - 1)
                        Task { await settings.syncCloudProfileIfPossible(supabase: supabase) }
                    },
                    plus: {
                        settings.driverPercentage = min(100, settings.driverPercentage + 1)
                        Task { await settings.syncCloudProfileIfPossible(supabase: supabase) }
                    }
                )
            } else {
                DriverStepperRow(
                    title: "Rate Per Mile",
                    value: settings.ratePerMile,
                    prefix: "$",
                    suffix: "/mi",
                    step: 0.05,
                    minus: { settings.ratePerMile = max(0, settings.ratePerMile - 0.05) },
                    plus: { settings.ratePerMile += 0.05 }
                )
            }
        }
        .padding(16)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct DriverWeeklyLoadSummaryCard: View {
    let summaries: [DriverLoadPaySummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Loads This Week")
                .font(.headline)
                .foregroundStyle(Color.spTextPrimary)

            if summaries.isEmpty {
                Text("No driver loads in this pay week yet.")
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextSecondary)
            } else {
                ForEach(summaries.prefix(5)) { summary in
                    DriverPaySummaryRow(summary: summary)
                    if summary.id != summaries.prefix(5).last?.id {
                        Divider().background(Color.spCardBgLight)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct DriverMetricTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.spGold)
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.spTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.spCardBgLight)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct DriverLoadSimpleRow: View {
    let load: Load
    let driverGross: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(load.brokerName ?? load.loadNumber ?? "Driver Load")
                        .font(.headline)
                        .foregroundStyle(Color.spTextPrimary)
                    Text("\(load.origin ?? "Pickup") → \(load.destination ?? "Delivery")")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                Spacer()
                Text(driverGross.asCurrency)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.spGold)
            }

            HStack(spacing: 12) {
                Label("\(Int(load.totalMiles ?? 0)) mi", systemImage: "road.lanes")
                Label(DriverModeMath.statusText(from: load), systemImage: DriverModeMath.status(from: load).systemImage)
                if let date = DriverModeMath.loadDate(load) {
                    Label(date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                }
            }
            .font(.caption)
            .foregroundStyle(Color.spTextSecondary)
        }
        .padding(.vertical, 6)
    }
}

struct DriverPaySummaryRow: View {
    let summary: DriverLoadPaySummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.load.brokerName ?? summary.load.loadNumber ?? "Driver Load")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text("\(Int(summary.load.totalMiles ?? 0)) loaded miles")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
            Spacer()
            Text(summary.driverGross.asCurrency)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.spGold)
        }
    }
}

struct DriverExpenseSimpleRow: View {
    let expense: Expense

    var body: some View {
        HStack(spacing: 12) {
            let category = DriverExpenseCategory(rawValue: expense.category)
            Image(systemName: category?.systemImage ?? "receipt.fill")
                .foregroundStyle(Color.spGold)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(category?.displayName ?? expense.category.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text(expense.description ?? expense.vendorName ?? expense.receiptDate?.formatted(date: .abbreviated, time: .omitted) ?? "Driver expense")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(expense.amount.asCurrency)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.spDanger)
        }
        .padding(.vertical, 5)
    }
}

struct DriverInfoRow: View {
    let title: String
    let value: String
    let systemImage: String

    init(_ title: String, value: String, systemImage: String) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
    }

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(Color.spTextPrimary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(Color.spGold)
        }
    }
}

struct DriverStepperRow: View {
    let title: String
    let value: Double
    var prefix: String = ""
    var suffix: String = ""
    var step: Double = 1
    let minus: () -> Void
    let plus: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
            Spacer()
            Button(action: minus) {
                Image(systemName: "minus.circle.fill")
            }
            .foregroundStyle(Color.spGold)
            Text("\(prefix)\(formattedValue)\(suffix)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.spTextPrimary)
                .frame(minWidth: 78)
            Button(action: plus) {
                Image(systemName: "plus.circle.fill")
            }
            .foregroundStyle(Color.spGold)
        }
    }

    private var formattedValue: String {
        step == 1 ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}

struct DriverEntryCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.spGold)
            VStack(spacing: 12) {
                content
            }
            .padding(14)
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal)
    }
}

struct DriverTextField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    var keyboard: UIKeyboardType = .default
    var prefix: String?
    var suffix: String?

    init(_ label: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType = .default, prefix: String? = nil, suffix: String? = nil) {
        self.label = label
        _text = text
        self.placeholder = placeholder
        self.keyboard = keyboard
        self.prefix = prefix
        self.suffix = suffix
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
                .frame(width: 118, alignment: .leading)
            HStack(spacing: 4) {
                if let prefix {
                    Text(prefix)
                        .foregroundStyle(Color.spGold)
                }
                TextField(placeholder, text: $text)
                    .keyboardType(keyboard)
                    .foregroundStyle(Color.spTextPrimary)
                if let suffix {
                    Text(suffix)
                        .foregroundStyle(Color.spGold)
                }
            }
            .padding(10)
            .background(Color.spCardBgLight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct DriverCategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? Color.spGold : Color.spCardBg)
                .foregroundStyle(isSelected ? Color.spBlack : Color.spTextPrimary)
                .clipShape(Capsule())
        }
    }
}

struct DriverEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(Color.spTextSecondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.spTextPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
    }
}

struct DriverDispatchView: View {
    @EnvironmentObject var supabase: SupabaseService

    var body: some View {
        DriverMessagesProfileView()
            .environmentObject(supabase)
    }
}

struct CarrierDispatchView: View {
    @EnvironmentObject var supabase: SupabaseService

    var body: some View {
        FutureDispatcherAppBoundaryView()
            .environmentObject(supabase)
    }
}

struct OwnerOperatorDispatchView: View {
    @EnvironmentObject var supabase: SupabaseService

    var body: some View {
        DispatchCommunicationView()
            .environmentObject(supabase)
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
                                Text("Account mode: \(subscriptions.activePlanRoleName)")
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextSecondary)
                            }
                        }
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Account Mode") {
                    AccountModeSummaryRow(role: subscriptions.entitledAccountRole ?? .ownerOperator)
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
    @State private var showPaywall = false

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
                    Text("Choose a Subscription Plan")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.spGold)
                        .multilineTextAlignment(.center)
                    Text("Your dashboard mode is locked to the active Driver Hub subscription on this Apple ID.")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 28)

                Text("Sign in, purchase or restore a plan, and Driver Hub will open only the matching dashboard.")
                    .font(.footnote)
                    .foregroundStyle(Color.spTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        showPaywall = true
                    } label: {
                        Text("View Plans")
                            .font(.headline)
                            .foregroundStyle(Color.spBlack)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.spGold)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    Button("Sign Out", role: .destructive) {
                        Task { try? await supabase.signOut() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spBlack)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(supabase)
        }
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

#Preview {
    ContentView()
        .environmentObject(SupabaseService())
}
