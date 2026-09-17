import SwiftUI

// =============================================================================
//  SettlementsHomeView — the Settlements tab
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B).
//   • Overview: weekly financial tiles with a date filter
//   • Live estimates per active driver (clearly labelled ESTIMATED)
//   • Settlement history with search and filters
//   • New Settlement, Drivers & Pay, Advances, Recurring, Reports
//
//  Existing screens (Paystub Maker, Settlement Sheet, Manual Paystub) are
//  untouched and still reachable from Settings.
// =============================================================================

enum SettlementRoute: Hashable {
    case settlement(UUID)
    case estimate(driverId: UUID)
    case driver(UUID)
    case drivers
    case advances(driverId: UUID?)
    case recurring(driverId: UUID?)
    case reports
    case preferences
}

struct SettlementsHomeView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var repo = SettlementRepository.shared
    @ObservedObject private var loadsSync = LoadsSyncService.shared
    @ObservedObject private var payWeek = PayWeekService.shared

    @State private var path = NavigationPath()
    @State private var showingNew = false
    @State private var searchText = ""
    @State private var statusFilter: SettlementStatus? = nil
    @State private var paidFilter: SettlementPaidFilter = .all
    @State private var driverFilter: UUID? = nil

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Settlements")
            .searchable(text: $searchText, prompt: "Number, load #, broker, driver")
            .toolbar { toolbarContent }
            .navigationDestination(for: SettlementRoute.self) { route in
                destination(for: route)
            }
            .sheet(isPresented: $showingNew) {
                NewSettlementView { createdId in
                    path.append(SettlementRoute.settlement(createdId))
                }
                .environmentObject(supabase)
            }
            .task { await refresh() }
            .refreshable { await refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .loadsDidChange)) { _ in
                Task { await loadsSync.refresh(supabase: supabase) }
            }
        }
        .tint(Color.spGold)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if repo.role == .driver {
            DriverSettlementsPortalView()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if AppMode.shared.isLocal {
                        LocalModeBanner()
                            .padding(.horizontal, -16)
                    }
                    if let error = repo.lastError {
                        errorBanner(error)
                    }
                    SettlementOverviewSection()
                    estimatesSection
                    historySection
                }
                .padding()
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.spWarning)
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.spTextPrimary)
            Spacer()
        }
        .padding(12)
        .background(Color.spWarning.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Estimates

    private var thisWeek: SettlementDateRange {
        SettlementDateRange.preset(.thisWeek, firstWeekday: payWeek.firstWeekday)
    }

    @ViewBuilder
    private var estimatesSection: some View {
        let drivers = repo.activeDrivers
        if repo.viewer.can(.viewEstimates) {
            SettlementCard(title: "This Week · Estimated", trailing: thisWeek.description) {
                if drivers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add a driver and their pay terms to see a live estimate.")
                            .font(.subheadline)
                            .foregroundStyle(Color.spTextSecondary)
                        if repo.viewer.can(.managePaySettings) {
                            NavigationLink(value: SettlementRoute.drivers) {
                                Label("Set Up Drivers & Pay", systemImage: "person.crop.circle.badge.plus")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                } else {
                    ForEach(drivers.prefix(6), id: \.id) { driver in
                        if let id = driver.id {
                            NavigationLink(value: SettlementRoute.estimate(driverId: id)) {
                                EstimateRow(driver: driver, range: thisWeek)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - History

    private var filteredHistory: [Settlement] {
        var filter = SettlementHistoryFilter(
            driverId: driverFilter,
            query: searchText,
            paid: paidFilter)
        if let statusFilter { filter.statuses = [statusFilter] }
        let visible = SettlementPermissions.scopedLedger(repo.ledger, viewer: repo.viewer)
        return SettlementInsights.filter(visible, filter, driverNames: repo.driverNames)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SETTLEMENT HISTORY")
                    .font(.caption.weight(.heavy))
                    .tracking(1.2)
                    .foregroundStyle(Color.spTextSecondary)
                Spacer()
                filterMenu
            }
            filterChips

            let rows = filteredHistory
            if repo.isLoading && !repo.hasLoaded {
                ProgressView().tint(Color.spGold).frame(maxWidth: .infinity).padding()
            } else if rows.isEmpty {
                SettlementEmptyState(
                    title: repo.ledger.settlements.isEmpty ? "No settlements yet" : "No matches",
                    message: repo.ledger.settlements.isEmpty
                        ? "Tap + to build your first driver settlement from completed loads."
                        : "Try a different search or filter.",
                    systemImage: "doc.text")
            } else {
                ForEach(rows, id: \.id) { settlement in
                    if let id = settlement.id {
                        NavigationLink(value: SettlementRoute.settlement(id)) {
                            SettlementHistoryRow(settlement: settlement,
                                                 driverName: repo.driverName(settlement.driverId))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Driver", selection: $driverFilter) {
                Text("All Drivers").tag(UUID?.none)
                ForEach(repo.drivers, id: \.id) { d in
                    Text(d.name).tag(d.id)
                }
            }
            Picker("Status", selection: $statusFilter) {
                Text("Any Status").tag(SettlementStatus?.none)
                ForEach(SettlementStatus.allCases) { s in
                    Text(s.displayName).tag(SettlementStatus?.some(s))
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                .font(.subheadline)
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SettlementPaidFilter.allCases) { option in
                    Button {
                        paidFilter = option
                    } label: {
                        Text(option.displayName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(paidFilter == option ? Color.spGold : Color.spCardBg)
                            .foregroundStyle(paidFilter == option ? Color.spBlack : Color.spTextSecondary)
                            .clipShape(Capsule())
                    }
                }
                if let statusFilter {
                    chip(statusFilter.displayName) { self.statusFilter = nil }
                }
                if let driverFilter {
                    chip(repo.driverName(driverFilter)) { self.driverFilter = nil }
                }
            }
        }
    }

    private func chip(_ title: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "xmark.circle.fill")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.spGold.opacity(0.18))
            .foregroundStyle(Color.spGold)
            .clipShape(Capsule())
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if repo.viewer.can(.createDraft) {
                Button {
                    showingNew = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.spGold)
                }
                .accessibilityLabel("New Settlement")
                .accessibilityIdentifier("settlements.new")
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            if repo.role != .driver {
                Menu {
                    NavigationLink(value: SettlementRoute.drivers) {
                        Label("Drivers & Pay", systemImage: "person.2.fill")
                    }
                    NavigationLink(value: SettlementRoute.advances(driverId: nil)) {
                        Label("Advances", systemImage: "banknote")
                    }
                    NavigationLink(value: SettlementRoute.recurring(driverId: nil)) {
                        Label("Recurring Deductions", systemImage: "arrow.triangle.2.circlepath")
                    }
                    if repo.viewer.can(.export) || repo.viewer.can(.viewCompanyFinancials) {
                        NavigationLink(value: SettlementRoute.reports) {
                            Label("Reports", systemImage: "chart.bar.doc.horizontal")
                        }
                    }
                    if repo.viewer.can(.managePaySettings) {
                        NavigationLink(value: SettlementRoute.preferences) {
                            Label("Settlement Settings", systemImage: "slider.horizontal.3")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Color.spGold)
                }
                .accessibilityLabel("Settlement tools")
            }
        }
    }

    private func destination(for route: SettlementRoute) -> some View {
        SettlementRouteDestination(route: route, estimateRange: thisWeek)
    }

    private func refresh() async {
        repo.attach(supabase)
        await loadsSync.refresh(supabase: supabase)
        await repo.reload()
    }
}

// MARK: - Route destinations

/// Every Settlements route in one place so any NavigationStack (the tab,
/// Drivers in Settings, the driver portal) can host these screens.
struct SettlementRouteDestination: View {
    let route: SettlementRoute
    var estimateRange: SettlementDateRange? = nil
    @ObservedObject private var payWeek = PayWeekService.shared

    var body: some View {
        switch route {
        case .settlement(let id):
            SettlementDetailView(settlementId: id)
        case .estimate(let driverId):
            SettlementEstimateDetailView(
                driverId: driverId,
                range: estimateRange ?? SettlementDateRange.preset(.thisWeek, firstWeekday: payWeek.firstWeekday))
        case .driver(let id):
            DriverPayProfileView(driverId: id)
        case .drivers:
            SettlementDriversView()
        case .advances(let driverId):
            DriverAdvancesView(driverId: driverId)
        case .recurring(let driverId):
            RecurringDeductionsView(driverId: driverId)
        case .reports:
            SettlementReportsView()
        case .preferences:
            SettlementPreferencesView()
        }
    }
}

extension View {
    /// Registers the Settlements screens on the enclosing NavigationStack.
    func settlementDestinations() -> some View {
        navigationDestination(for: SettlementRoute.self) { route in
            SettlementRouteDestination(route: route)
        }
    }
}

// MARK: - Rows

struct SettlementHistoryRow: View {
    let settlement: Settlement
    let driverName: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(settlement.displayNumber)
                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                        .foregroundStyle(Color.spTextPrimary)
                    SettlementStatusBadge(status: settlement.settlementStatus,
                                          isEstimate: settlement.isEstimateRecord)
                }
                Text(driverName)
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                SettlementMoneyText(amount: settlement.netPayMoney,
                                    font: .system(.headline, design: .monospaced).weight(.bold))
                Text("net")
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
        }
        .padding(12)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(settlement.settlementStatus == .voided ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [settlement.periodDescription]
        if let truck = settlement.truckNumber, !truck.isEmpty { parts.append("Truck \(truck)") }
        parts.append("Gross \(settlement.grossLoadRevenueMoney.formatted)")
        return parts.joined(separator: " · ")
    }
}

private struct EstimateRow: View {
    let driver: Driver
    let range: SettlementDateRange
    @ObservedObject private var repo = SettlementRepository.shared

    var body: some View {
        let bundle = repo.estimate(for: driver, range: range)
        let result = bundle?.calculate()
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(driver.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                    SettlementEstimateTag()
                }
                Text("\(result?.totalLoads ?? 0) loads · gross \((result?.grossLoadRevenue ?? .zero).formatted)")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
            Spacer()
            SettlementMoneyText(amount: result?.netDriverPay ?? .zero,
                                font: .system(.headline, design: .monospaced).weight(.bold))
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settlement preferences

struct SettlementPreferencesView: View {
    @ObservedObject private var repo = SettlementRepository.shared
    @State private var prefix: String = ""

    var body: some View {
        Form {
            Section {
                TextField("Prefix", text: $prefix)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onSubmit(apply)
                Text("Next number: \(SettlementNumberService.nextNumber(existing: repo.ledger.settlementNumbers, periodEnd: Date(), prefix: prefix.isEmpty ? SettlementNumberService.defaultPrefix : prefix))")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            } header: {
                Text("Settlement Numbers")
            } footer: {
                Text("Numbers are unique per account and assigned when a settlement is created.")
            }

            Section {
                Text("Linked drivers see only their own approved and paid settlements. Drafts, estimates and company figures are never shown to drivers.")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            } header: {
                Text("Driver Portal")
            }

            Section("Company Fees") {
                let fees = repo.companyFees
                LabeledContent("Dispatcher Fee", value: fees.dispatcherFeePercent.asPercentString)
                LabeledContent("Factoring Fee", value: fees.factoringFeePercent.asPercentString)
                LabeledContent("Authority Fee", value: fees.authorityFee.formatted)
                LabeledContent("Maintenance Reserve", value: fees.maintenanceReserve.formatted)
                Text("Edit these in Settings → Fees. Who pays each fee is set per driver in Drivers & Pay.")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.spBackground)
        .navigationTitle("Settlement Settings")
        .onAppear { prefix = repo.numberPrefix }
        .onDisappear(perform: apply)
    }

    private func apply() {
        let clean = SettlementNumberService.sanitise(prefix)
        repo.numberPrefix = clean.isEmpty ? SettlementNumberService.defaultPrefix : clean
        prefix = repo.numberPrefix
    }
}
