import SwiftUI
import UIKit

struct SettingsView: View {
    private let roleOverride: AccountRole?

    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var appearance = AppearanceService.shared
    // Observed so plan/mode labels and any gated copy refresh the moment a
    // purchase or restore changes the active StoreKit entitlement.
    @ObservedObject private var subscriptions = SubscriptionService.shared
    @ObservedObject private var appMode = AppMode.shared

    // Subscription plan paywall entry point.
    @State private var showPaywall = false
    @State private var showShareSummary = false

    // Demo seeder feedback (DEBUG-only flow; harmless inert state in Release)
    @State private var isSeeding = false
    @State private var seedAlertTitle: String = ""
    @State private var seedAlertBody: String = ""
    @State private var showSeedAlert: Bool = false

    init(roleOverride: AccountRole? = nil) {
        self.roleOverride = roleOverride
    }

    private var accountRole: AccountRole {
        if let roleOverride {
            return roleOverride
        }
        if appMode.isLocal || ScreenshotMode.isActive {
            return .ownerOperator
        }
        return subscriptions.entitledAccountRole ?? .ownerOperator
    }

    private var canUseDriverHubFinancials: Bool {
        accountRole != .dispatcher
    }

    private var canUseCarrierCompanyTools: Bool {
        accountRole == .carrier || accountRole == .ownerOperator
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            NavigationStack {
                VStack(spacing: 0) {
                    if appMode.isLocal {
                        LocalModeBanner()
                    }
                    // Sacred Pathway Logo Header
                    VStack(spacing: 12) {
                        Image("SacredPathwayLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Text("Sacred Pathway")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.spGold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(Color.spCardBg)

                    List {
                        // ── Local Mode section ────────────────────────────
                        // Visible only when the user picked Free Local Mode
                        // on WelcomeView. Hosts the Backup & Restore flow.
                        // Cloud Sync users never see this — they have iCloud
                        // / Supabase backups by default.
                        if appMode.isLocal {
                            Section("Local Mode") {
                                NavigationLink {
                                    BackupRestoreView()
                                } label: {
                                    HStack {
                                        Image(systemName: "externaldrive.badge.icloud")
                                            .foregroundStyle(Color.spGold)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Backup & Restore")
                                                .foregroundStyle(Color.spTextPrimary)
                                            Text("Export or import your local data")
                                                .font(.caption)
                                                .foregroundStyle(Color.spTextSecondary)
                                        }
                                    }
                                }

                                // ── Escape hatch out of Free Local Mode ──
                                // For users who picked Local Mode on WelcomeView
                                // but actually have an existing Cloud Sync
                                // account with data in Supabase. Tapping this
                                // calls AppMode.setCloud() which flips the
                                // mode flag in UserDefaults; the root view
                                // re-routes through AccessGate → LoginView on
                                // the next render. Local JSON data stays on
                                // disk (BackupRestoreView can still export it
                                // after the switch). No Supabase write, no
                                // migration, no data reset.
                                Button {
                                    appMode.setCloud()
                                } label: {
                                    HStack {
                                        Image(systemName: "icloud.and.arrow.up")
                                            .foregroundStyle(Color.spGold)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Switch to Cloud Sync")
                                                .foregroundStyle(Color.spTextPrimary)
                                            Text("Sign in to see your Supabase account data")
                                                .font(.caption)
                                                .foregroundStyle(Color.spTextSecondary)
                                        }
                                    }
                                }
                            }
                            .listRowBackground(Color.spCardBg)
                            .headerProminence(.increased)
                        }

                        if !appMode.isLocal && !ScreenshotMode.isActive {
                            Section("Account Mode") {
                                AccountModeSummaryRow(role: accountRole)
                            }
                            .listRowBackground(Color.spCardBg)
                            .headerProminence(.increased)
                        }

                        if FeatureFlags.subscriptionsEnabled {
                            Section("Subscription") {
                                Button {
                                    showPaywall = true
                                } label: {
                                    HStack {
                                        Image(systemName: "sparkles")
                                            .foregroundStyle(Color.spGold)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("View Subscription Plans")
                                                .foregroundStyle(Color.spTextPrimary)
                                            Text("Driver, Owner Operator, or Carrier")
                                                .font(.caption)
                                                .foregroundStyle(Color.spTextSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(Color.spTextSecondary)
                                            .font(.caption)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .listRowBackground(Color.spCardBg)
                            .headerProminence(.increased)
                        }

                        Section("Compliance") {
                            NavigationLink {
                                ComplianceHubView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "checkmark.shield.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Compliance")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Inspections, IFTA, permits, insurance")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.spCardBg)
                        .headerProminence(.increased)

                        Section("Appearance") {
                            HStack {
                                Image(systemName: "circle.lefthalf.filled")
                                    .foregroundStyle(Color.spGold)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Theme")
                                        .foregroundStyle(Color.spTextPrimary)
                                    Text("Choose how Driver Hub looks")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                }
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
                        .headerProminence(.increased)

                        Section("Company") {
                            NavigationLink {
                                EditCompanyView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "building.2.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(supabase.currentProfile?.companyName ?? "Not set")
                                            .foregroundStyle(Color.spTextPrimary)
                                        HStack(spacing: 8) {
                                            Text("MC# \(supabase.currentProfile?.mcNumber ?? "—")")
                                            Text("DOT# \(supabase.currentProfile?.dotNumber ?? "—")")
                                        }
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.spCardBg)
                        .headerProminence(.increased)

                        if canUseDriverHubFinancials {
                            Section("Financial") {
                                NavigationLink {
                                    ExpensesListView()
                                        .environmentObject(supabase)
                                } label: {
                                    HStack {
                                        Image(systemName: "receipt")
                                            .foregroundStyle(Color.spGold)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Expenses")
                                                .foregroundStyle(Color.spTextPrimary)
                                            Text("Track fuel, lumper, toll, repair costs")
                                                .font(.caption)
                                                .foregroundStyle(Color.spTextSecondary)
                                        }
                                    }
                                }

                                // CPA Ready Tax Package — added 2026-05.
                                // Generates accountant-grade PDF + CSV exports
                                // for tax season, audits, and quarterly filings.
                                //
                                // Owner Operator-gated 2026-05 via SubscriptionService.Feature.cpaTaxPackage.
                                // Entitled users get the normal NavigationLink → CPAReadyExportView.
                                // Lower-tier users see the same row decorated with a lock; tapping
                                // opens the existing PaywallView sheet instead of the export
                                // screen. No change to the CPA export feature itself.
                                if subscriptions.isEntitled(.cpaTaxPackage) {
                                    NavigationLink {
                                        CPAReadyExportView()
                                            .environmentObject(supabase)
                                    } label: {
                                        cpaTaxPackageRowLabel(locked: false)
                                    }
                                } else {
                                    Button {
                                        showPaywall = true
                                    } label: {
                                        cpaTaxPackageRowLabel(locked: true)
                                    }
                                    .buttonStyle(.plain)
                                }

                                // Monthly Statement Generator — branded PDF of a
                                // month's loads/revenue/expenses/profit, bucketed
                                // by rate-con date (pickup → delivery → created).
                                NavigationLink {
                                    MonthlyStatementView()
                                        .environmentObject(supabase)
                                } label: {
                                    HStack {
                                        Image(systemName: "doc.richtext.fill")
                                            .foregroundStyle(Color.spGold)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Monthly Statement Generator")
                                                .foregroundStyle(Color.spTextPrimary)
                                            Text("Revenue, expenses & profit for a month — branded PDF")
                                                .font(.caption)
                                                .foregroundStyle(Color.spTextSecondary)
                                        }
                                    }
                                }
                            }
                            .listRowBackground(Color.spCardBg)
                            .headerProminence(.increased)
                        }

                        if canUseDriverHubFinancials {
                            Section("Pay Week") {
                                NavigationLink {
                                    PayWeekSettingsView()
                                } label: {
                                    HStack {
                                        Image(systemName: "calendar.badge.clock")
                                            .foregroundStyle(Color.spGold)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Pay Week Start Day")
                                                .foregroundStyle(Color.spTextPrimary)
                                            Text("Starts \(PayWeekService.shared.displayName) — used for every weekly total")
                                                .font(.caption)
                                                .foregroundStyle(Color.spTextSecondary)
                                        }
                                    }
                                }
                            }
                            .listRowBackground(Color.spCardBg)
                            .headerProminence(.increased)
                        }

                        if canUseCarrierCompanyTools {
                            Section("Fees & Deductions") {
                                NavigationLink {
                                    FeeSettingsView()
                                        .environmentObject(supabase)
                                } label: {
                                    HStack {
                                        Image(systemName: "percent")
                                            .foregroundStyle(Color.spGold)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Fee Percentages")
                                                .foregroundStyle(Color.spTextPrimary)
                                            Text("Driver pay, dispatcher, factoring, reserves")
                                                .font(.caption)
                                                .foregroundStyle(Color.spTextSecondary)
                                        }
                                    }
                                }
                            }
                            .listRowBackground(Color.spCardBg)
                            .headerProminence(.increased)
                        }

                        if canUseCarrierCompanyTools {
                            Section("Branding") {
                                NavigationLink {
                                    BrandingSettingsView()
                                } label: {
                                    HStack {
                                        Image(systemName: "paintpalette.fill")
                                            .foregroundStyle(Color.spGold)
                                        Text("Logo & Color Scheme")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Spacer()
                                        if BrandingService.shared.hasCustomBranding {
                                            Text("Custom")
                                                .font(.caption)
                                                .foregroundStyle(Color.spSuccess)
                                        }
                                    }
                                }
                            }
                            .listRowBackground(Color.spCardBg)
                            .headerProminence(.increased)
                        }

                        if canUseDriverHubFinancials {
                            Section("Operations") {
                            NavigationLink {
                                BrokerContactsListView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "person.crop.rectangle.stack.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Broker Contacts")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Auto-added from Smart Scan — phone, email, MC#")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }

                            Button {
                                showShareSummary = true
                            } label: {
                                HStack {
                                    Image(systemName: "square.and.arrow.up.on.square")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Share Summary")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("PDF + text — Today / Week / Month / Custom")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                }
                            }

                            if canUseCarrierCompanyTools {
                                NavigationLink {
                                    DriversListView()
                                        .environmentObject(supabase)
                                } label: {
                                    HStack {
                                        Image(systemName: "person.3.fill")
                                            .foregroundStyle(Color.spGold)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Drivers")
                                                .foregroundStyle(Color.spTextPrimary)
                                            Text("Manage drivers, pay rates, assignments")
                                                .font(.caption)
                                                .foregroundStyle(Color.spTextSecondary)
                                        }
                                    }
                                }
                            }

                            NavigationLink {
                                SettlementGeneratorView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Settlements & Paystubs")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Auto-calculate from your loads & expenses")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }

                            NavigationLink {
                                ManualPaystubView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "square.and.pencil")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Create Paystub Manually")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Type in loads, expenses, fees — export PDF")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }

                            NavigationLink {
                                PaystubDraftsListView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "tray.full.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Payroll Drafts")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Resume unfinished paystubs")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }

                            NavigationLink {
                                DocumentVaultView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "archivebox.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Document Vault")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Attach and browse documents by load, broker, or date")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }

                            NavigationLink {
                                MotiveConnectionView(role: accountRole)
                            } label: {
                                HStack {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Connect Motive ELD")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Auto-fill Trip Planner hours from Motive — read-only")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }

                            // Smart Insights (AI-powered) — hidden in the
                            // manual-first launch. The SmartInsightsView code
                            // and its generate-insights edge function stay in
                            // the repo; flip FeatureFlags.aiScanEnabled to
                            // true (in ScanUploadView.swift) when the AI
                            // backend is re-enabled and this row can come
                            // back as a gated option.
                            if FeatureFlags.aiScanEnabled {
                                NavigationLink {
                                    SmartInsightsView()
                                        .environmentObject(supabase)
                                } label: {
                                    HStack {
                                        Image(systemName: "sparkles")
                                            .foregroundStyle(Color.spGold)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Smart Insights")
                                                .foregroundStyle(Color.spTextPrimary)
                                            Text("Auto-generated weekly summaries")
                                                .font(.caption)
                                                .foregroundStyle(Color.spTextSecondary)
                                        }
                                    }
                                }
                            }
                            }
                            .listRowBackground(Color.spCardBg)
                            .headerProminence(.increased)
                        }

                        Section("Security") {
                            NavigationLink {
                                PinSettingsView()
                            } label: {
                                HStack {
                                    Image(systemName: "lock.shield.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("App Lock / PIN")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Protect financial data with a PIN or Face ID")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                    Spacer()
                                    if PinLockService.shared.isEnabled {
                                        Text("ON")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(Color.spSuccess)
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.spCardBg)
                        .headerProminence(.increased)

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
                                            Text("Mode: \(subscriptions.activePlanRoleName) — upgrade, restore, manage")
                                                .font(.caption)
                                                .foregroundStyle(Color.spTextSecondary)
                                        }
                                    }
                                }
                            }
                            .listRowBackground(Color.spCardBg)
                            .headerProminence(.increased)
                        }

                        Section("Account") {
                            NavigationLink {
                                DeleteAccountView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "person.crop.circle.badge.xmark")
                                        .foregroundStyle(Color.spDanger)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Delete Account")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Permanently remove your account and data")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.spCardBg)
                        .headerProminence(.increased)

                        // Hidden until the portal at Config.Web.dashboardURL is
                        // actually deployed. Flip Config.Web.portalLive → true
                        // once `curl -sI https://app.sacredpathway.org/`
                        // returns 200.
                        if Config.Web.portalLive {
                            Section("Web Access") {
                                Link(destination: Config.Web.dashboardURL) {
                                    HStack {
                                        Image(systemName: "globe")
                                            .foregroundStyle(Color.spGold)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Open Web Dashboard")
                                                .foregroundStyle(Color.spTextPrimary)
                                            Text("Same account — view loads, documents, contacts from any browser")
                                                .font(.caption)
                                                .foregroundStyle(Color.spTextSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.right.square")
                                            .foregroundStyle(Color.spTextSecondary)
                                            .font(.caption)
                                    }
                                }
                            }
                            .listRowBackground(Color.spCardBg)
                            .headerProminence(.increased)
                        }

                        // Sacred Road Supply storefront row.
                        // Hidden until Config.Store.storeLive flips to true
                        // (after Shopify launch + product import + verified
                        // checkout). Opens shop.sacredpathway.org in Safari
                        // — never in an in-app WebView, to keep clean
                        // separation from Apple Guideline 3.1.1 (IAP applies
                        // to digital goods sold IN the app; physical goods
                        // sold via Shopify's external checkout are exempt).
                        if Config.Store.storeLive {
                            Section("Shop Trucker Gear") {
                                Link(destination: Config.Store.storeURL) {
                                    HStack {
                                        Image(systemName: "bag.fill")
                                            .foregroundStyle(Color.spGold)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Sacred Road Supply")
                                                .foregroundStyle(Color.spTextPrimary)
                                            Text("Trucker-tested gear. Built by Sacred Pathway. Ships from U.S.")
                                                .font(.caption)
                                                .foregroundStyle(Color.spTextSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.right.square")
                                            .foregroundStyle(Color.spTextSecondary)
                                            .font(.caption)
                                    }
                                }
                            }
                            .listRowBackground(Color.spCardBg)
                            .headerProminence(.increased)
                        }

                        Section("Support") {
                            Link(destination: Config.Support.mailto(
                                to: Config.Support.supportEmail,
                                subject: "Driver Hub Support",
                                body: supportBody)) {
                                HStack {
                                    Image(systemName: "envelope.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Email Support")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Get help from the Sacred Pathway team")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.right.square")
                                        .foregroundStyle(Color.spTextSecondary)
                                        .font(.caption)
                                }
                            }

                            Link(destination: Config.Support.mailto(
                                to: Config.Support.feedbackEmail,
                                subject: "Driver Hub Feedback",
                                body: supportBody)) {
                                HStack {
                                    Image(systemName: "bubble.left.and.bubble.right.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Send Feedback")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Share ideas, requests, or report a problem")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.right.square")
                                        .foregroundStyle(Color.spTextSecondary)
                                        .font(.caption)
                                }
                            }
                        }
                        .listRowBackground(Color.spCardBg)
                        .headerProminence(.increased)

                        Section("Legal") {
                            Link(destination: Config.Legal.privacyPolicyURL) {
                                HStack {
                                    Image(systemName: "lock.shield")
                                        .foregroundStyle(Color.spGold)
                                    Text("Privacy Policy")
                                        .foregroundStyle(Color.spTextPrimary)
                                    Spacer()
                                    Image(systemName: "arrow.up.right.square")
                                        .foregroundStyle(Color.spTextSecondary)
                                        .font(.caption)
                                }
                            }
                            Link(destination: Config.Legal.termsOfServiceURL) {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(Color.spGold)
                                    Text("Terms of Service")
                                        .foregroundStyle(Color.spTextPrimary)
                                    Spacer()
                                    Image(systemName: "arrow.up.right.square")
                                        .foregroundStyle(Color.spTextSecondary)
                                        .font(.caption)
                                }
                            }
                        }
                        .listRowBackground(Color.spCardBg)
                        .headerProminence(.increased)

                        #if DEBUG
                        Section("Developer") {
                            NavigationLink {
                                DebugScanHarnessView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "hammer.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Debug Menu")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Scan harness, sample rate con, pipeline tests")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }

                            NavigationLink {
                                SacredPathMapDiagnosticsView()
                            } label: {
                                HStack {
                                    Image(systemName: "map.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Map Diagnostics")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Renderer, tile provider, keys, GPS, route errors")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }

                            Toggle(isOn: Binding(
                                get: { DemoMode.unlockAllFeatures },
                                set: { newValue in
                                    DemoMode.unlockAllFeatures = newValue
                                    Task { await SubscriptionService.shared.refreshEntitlements() }
                                }
                            )) {
                                HStack {
                                    Image(systemName: "lock.open.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("QA Entitlement Override")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("DEBUG only — bypass paywall for role-routing QA")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }

                            Button {
                                Task { await runSeeder() }
                            } label: {
                                HStack {
                                    if isSeeding {
                                        ProgressView().tint(Color.spGold)
                                    } else {
                                        Image(systemName: "tray.and.arrow.down.fill")
                                            .foregroundStyle(Color.spGold)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(isSeeding ? "Seeding…" : "Seed Demo Data")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Greg Hinton · 8 loads · 12 expenses · 8 IFTA entries (idempotent)")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }
                            .disabled(isSeeding)
                        }
                        .listRowBackground(Color.spCardBg)
                        .headerProminence(.increased)
                        #endif

                        Section {
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
                }
                .navigationTitle("Settings")
            }
        }
        .alert(seedAlertTitle, isPresented: $showSeedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(seedAlertBody)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .sheet(isPresented: $showShareSummary) {
            ShareSummaryView()
                .environmentObject(supabase)
        }
    }

    // MARK: - Support email body
    // Pre-fills the email with app + device context so support/feedback
    // arrives with the version, build, and OS already attached — no back and
    // forth asking "what version are you on?".
    private var supportBody: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current.model
        let os = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        return """


        ——
        Sacred Pathway Driver Hub
        App Version: \(version) (\(build))
        Device: \(device) · \(os)
        """
    }

    // MARK: - CPA Ready Tax Package row label
    //
    // Shared label content for both the entitled (NavigationLink) and the
    // locked (Button → paywall) variants of the row. `locked` controls the
    // trailing badge: a small lock + "PRO" capsule for free-tier users.
    @ViewBuilder
    private func cpaTaxPackageRowLabel(locked: Bool) -> some View {
        HStack {
            Image(systemName: "doc.badge.gearshape")
                .foregroundStyle(Color.spGold)
            VStack(alignment: .leading, spacing: 2) {
                Text("CPA Ready Tax Package")
                    .foregroundStyle(Color.spTextPrimary)
                Text("Export tax write-offs and expense records")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
            if locked {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                    Text("PRO")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(Color.spGoldLight)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.spGold.opacity(0.18))
                .clipShape(Capsule())
            }
        }
    }

    @MainActor
    private func runSeeder() async {
        #if DEBUG
        isSeeding = true
        defer { isSeeding = false }
        let seeder = DemoDataSeeder(supabase: supabase)
        do {
            let report = try await seeder.seed()
            seedAlertTitle = "Demo Data Seeded"
            seedAlertBody = report.description
        } catch {
            seedAlertTitle = "Seed Failed"
            seedAlertBody = error.localizedDescription
        }
        showSeedAlert = true
        #endif
    }
}

#Preview {
    SettingsView().environmentObject(SupabaseService())
}

struct AccountRoleChangeView: View {
    let initialRole: AccountRole

    init(initialRole: AccountRole) {
        self.initialRole = initialRole
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            List {
                Section("Current Mode") {
                    AccountModeSummaryRow(role: initialRole)
                }
                .listRowBackground(Color.spCardBg)

                Section {
                    Text("Account mode is locked by your active Driver Hub subscription. To change modes, change the subscription plan in the App Store.")
                        .font(.footnote)
                        .foregroundStyle(Color.spTextSecondary)
                }
                .listRowBackground(Color.spCardBg)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Account Mode")
    }
}

struct AccountModeSummaryRow: View {
    let role: AccountRole

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: accountModeIcon(role))
                .foregroundStyle(Color.spGold)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(role.displayName)
                    .foregroundStyle(Color.spTextPrimary)
                Text("Locked by active subscription")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private func accountModeIcon(_ role: AccountRole) -> String {
    switch role {
    case .dispatcher: return "point.3.connected.trianglepath.dotted"
    case .carrier: return "building.2.fill"
    case .driver: return "steeringwheel"
    case .ownerOperator: return "truck.box.fill"
    }
}

// =============================================================================
// MARK: - DEBUG-ONLY SCAN HARNESS
// =============================================================================
// Everything below this line is compiled only in DEBUG builds. It lets you
// exercise the scan pipeline without a camera, Photos access, or AirDrop by
// generating a realistic rate confirmation in-memory and handing it directly
// to DocumentReviewView — the exact same screen the production flow uses.
// =============================================================================
#if DEBUG
import PDFKit
import UIKit

/// Error stages reported by the client-side scan pipeline, in addition to the
/// 5 backend ExtractionError codes. Surface as `Code:` in DocumentReviewView.
enum ScanPipelineStage: String {
    case camera       = "CAMERA_FAILED"
    case picker       = "PICKER_FAILED"
    case fileRead     = "FILE_READ_FAILED"
    case imagePrepare = "IMAGE_PREPARE_FAILED"
    case upload       = "UPLOAD_FAILED"
    case ocr          = "OCR_FAILED"
    case parse        = "PARSE_FAILED"
    case empty        = "EMPTY_RESULT"
}

struct DebugScanHarnessView: View {
    @EnvironmentObject var supabase: SupabaseService

    @State private var showReview = false
    @State private var previewImage: UIImage?
    @State private var previewPDFData: Data?
    @State private var previewPDFMime: String?

    @State private var logLines: [String] = []
    @State private var isRunning = false

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                Section("Sample Rate Confirmation") {
                    row("Preview the sample as a UIImage", icon: "eye") {
                        previewImage = DebugSampleRateCon.renderImage()
                        log("generated PNG bytes=\(estimatedBytes(for: previewImage))")
                    }
                    if let img = previewImage {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .listRowBackground(Color.spCardBg)
                .headerProminence(.increased)

                Section("Pipeline Tests") {
                    row("Test Sample Rate Con (PNG) — Full Flow",
                        icon: "photo.fill",
                        tint: Color.spGold) {
                        openReviewWithSample(asPDF: false)
                    }
                    row("Test Sample Rate Con (PDF) — Full Flow",
                        icon: "doc.richtext.fill",
                        tint: Color.spGold) {
                        openReviewWithSample(asPDF: true)
                    }
                    row("Test Upload Pipeline (no OCR)",
                        icon: "arrow.up.to.line") {
                        Task { await runUploadOnly() }
                    }
                    row("Run Parser Regression Tests",
                        icon: "checkmark.seal.fill",
                        tint: Color.spSuccess) {
                        runParserRegressionTests()
                    }
                    row("Ping extract-document Edge Function",
                        icon: "bolt.fill") {
                        Task { await runPingEdgeFunction() }
                    }
                }
                .listRowBackground(Color.spCardBg)
                .headerProminence(.increased)

                Section("Auth state") {
                    HStack {
                        Text("Signed in as")
                            .foregroundStyle(Color.spTextSecondary)
                        Spacer()
                        Text(supabase.client.auth.currentUser?.email ?? "—")
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.spTextPrimary)
                    }
                    HStack {
                        Text("User ID")
                            .foregroundStyle(Color.spTextSecondary)
                        Spacer()
                        Text(supabase.client.auth.currentUser?.id.uuidString.lowercased() ?? "—")
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color.spTextPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .listRowBackground(Color.spCardBg)
                .headerProminence(.increased)

                Section("Logs (most recent last)") {
                    if logLines.isEmpty {
                        Text("No log entries yet. Tap a test above.")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                    } else {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .foregroundStyle(Color.spTextPrimary)
                                .textSelection(.enabled)
                        }
                    }
                    Button("Clear logs") { logLines.removeAll() }
                        .foregroundStyle(Color.spGoldLight)
                }
                .listRowBackground(Color.spCardBg)
                .headerProminence(.increased)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Debug Menu")
        .disabled(isRunning)
        .sheet(isPresented: $showReview) {
            if let img = previewImage {
                DocumentReviewView(
                    scannedImage: img,
                    originalFileData: previewPDFData,
                    originalFileMime: previewPDFMime
                )
                .environmentObject(supabase)
            }
        }
    }

    // MARK: - Actions

    private func openReviewWithSample(asPDF: Bool) {
        log("=== test: \(asPDF ? "PDF" : "PNG") full flow ===")
        if asPDF {
            let pdf = DebugSampleRateCon.renderPDF()
            previewPDFData = pdf
            previewPDFMime = "application/pdf"
            if let img = renderFirstPage(of: pdf) {
                previewImage = img
                log("generated PDF bytes=\(pdf.count), first-page PNG size=\(img.size)")
            } else {
                log("PDF rendered but first-page UIImage render failed — stage=\(ScanPipelineStage.imagePrepare.rawValue)")
                previewImage = DebugSampleRateCon.renderImage()
            }
        } else {
            previewPDFData = nil
            previewPDFMime = nil
            previewImage = DebugSampleRateCon.renderImage()
            log("generated PNG size=\(previewImage?.size ?? .zero)")
        }
        showReview = true
        log("presented DocumentReviewView — the normal pipeline takes over from here")
    }

    private func runUploadOnly() async {
        isRunning = true
        defer { isRunning = false }
        log("=== test: upload only (no OCR) ===")
        guard let uid = supabase.client.auth.currentUser?.id else {
            log("FAIL stage=\(ScanPipelineStage.upload.rawValue) reason=not_signed_in")
            return
        }
        let img = DebugSampleRateCon.renderImage()
        guard let jpeg = img.jpegData(compressionQuality: 0.85) else {
            log("FAIL stage=\(ScanPipelineStage.imagePrepare.rawValue) reason=jpeg_encode_nil")
            return
        }
        log("jpeg bytes=\(jpeg.count)")
        let path = "\(uid.uuidString.lowercased())/debug-\(UUID().uuidString.lowercased()).jpg"
        do {
            _ = try await supabase.uploadDocument(data: jpeg, path: path, contentType: "image/jpeg")
            log("upload ok path=\(path)")
        } catch {
            log("FAIL stage=\(ScanPipelineStage.upload.rawValue) err=\(clip(error.localizedDescription))")
        }
    }

    private func runPingEdgeFunction() async {
        isRunning = true
        defer { isRunning = false }
        log("=== test: ping extract-document (with bogus document_id) ===")
        struct PingBody: Encodable { let documentId: UUID = UUID(); enum CodingKeys: String, CodingKey { case documentId = "document_id" } }
        struct PingResp: Decodable {
            let success: Bool?; let code: String?; let message: String?; let details: String?
        }
        do {
            let resp: PingResp = try await supabase.invokeFunction(
                name: Config.extractDocumentFunction,
                body: PingBody()
            )
            log("edge response: success=\(resp.success.map(String.init(describing:)) ?? "nil") code=\(resp.code ?? "nil") details=\(clip(resp.details ?? "nil"))")
        } catch {
            // Any non-2xx surfaces here — that's fine for a ping, we just
            // want to see whether auth + routing work.
            log("edge error: \(clip(String(describing: error)))")
        }
    }

    private func runParserRegressionTests() {
        log("=== test: parser regressions ===")
        let results = LocalDocumentParser.runRateConParserRegressionTests()
            + LocalDocumentParser.runFuelReceiptParserRegressionTests()
        for result in results {
            log("\(result.passed ? "PASS" : "FAIL") \(result.name)")
            log("actual=\(result.actual)")
            for failure in result.failures {
                log("  \(failure)")
            }
        }
    }

    // MARK: - Helpers

    private func log(_ s: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "\(stamp)  \(s)"
        logLines.append(line)
        print("[DebugScanHarness] \(line)")
    }

    private func clip(_ s: String, max: Int = 240) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max))
    }

    private func estimatedBytes(for image: UIImage?) -> Int {
        guard let img = image else { return 0 }
        return img.jpegData(compressionQuality: 0.85)?.count ?? 0
    }

    private func renderFirstPage(of pdfData: Data) -> UIImage? {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let doc = CGPDFDocument(provider),
              let page = doc.page(at: 1) else { return nil }
        let rect = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 2.0
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            ctx.cgContext.drawPDFPage(page)
        }
    }

    // MARK: - Row builder

    @ViewBuilder
    private func row(_ title: String,
                     icon: String,
                     tint: Color = Color.spGoldLight,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .foregroundStyle(Color.spTextPrimary)
            }
        }
    }
}

// -----------------------------------------------------------------------------
// MARK: DebugSampleRateCon — realistic rate con generator (DEBUG only)
// -----------------------------------------------------------------------------
enum DebugSampleRateCon {

    /// A single-page high-res PNG rendering of the sample rate con.
    static func renderImage() -> UIImage {
        let size = CGSize(width: 1700, height: 2200)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            draw(in: ctx.cgContext, size: size)
        }
    }

    /// A single-page US Letter PDF rendering of the same rate con.
    static func renderPDF() -> Data {
        let pageSize = CGSize(width: 612, height: 792) // US Letter, points
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        return renderer.pdfData { ctx in
            ctx.beginPage()
            draw(in: ctx.cgContext, size: pageSize)
        }
    }

    // MARK: - Drawing

    private static func draw(in cg: CGContext, size: CGSize) {
        let navy = UIColor(red: 0.04, green: 0.20, blue: 0.42, alpha: 1.0)

        // Background
        UIColor.white.setFill()
        cg.fill(CGRect(origin: .zero, size: size))

        // Header bar
        navy.setFill()
        cg.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.07))

        let baseFont = size.width * 0.010
        let headerTitle = attrs(weight: .bold, size: baseFont * 2.4, color: .white)
        let headerSub   = attrs(weight: .regular, size: baseFont * 1.15, color: .white.withAlphaComponent(0.9))
        let rcTitle     = attrs(weight: .bold, size: baseFont * 1.8, color: .white)

        ("C.H. ROBINSON" as NSString).draw(
            at: CGPoint(x: size.width * 0.035, y: size.height * 0.013),
            withAttributes: headerTitle)
        ("14701 Charlson Road, Eden Prairie, MN 55347 · MC# 484108" as NSString).draw(
            at: CGPoint(x: size.width * 0.035, y: size.height * 0.048),
            withAttributes: headerSub)
        let rc = "RATE CONFIRMATION" as NSString
        let rcSize = rc.size(withAttributes: rcTitle)
        rc.draw(at: CGPoint(x: size.width - rcSize.width - size.width * 0.035,
                            y: size.height * 0.024),
                withAttributes: rcTitle)

        var y = size.height * 0.095
        let margin = size.width * 0.035
        let inner  = size.width - 2 * margin

        let bold = attrs(weight: .bold, size: baseFont * 1.25, color: .black)
        let reg  = attrs(weight: .regular, size: baseFont * 1.25, color: .black)

        // Load / issued row
        ("Load # LD-2841" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: bold)
        let issued = "Issued: 04/18/2026  10:23 CDT" as NSString
        let issuedSz = issued.size(withAttributes: reg)
        issued.draw(at: CGPoint(x: size.width - margin - issuedSz.width, y: y), withAttributes: reg)
        y += size.height * 0.022

        ("Carrier: Sacred Pathway Trucking LLC   MC# 1234567   DOT# 7654321" as NSString).draw(
            at: CGPoint(x: margin, y: y), withAttributes: reg)
        y += size.height * 0.035

        // Pickup / Delivery boxes
        let boxW = (inner - size.width * 0.02) / 2
        let boxH = size.height * 0.16
        UIColor(white: 0.93, alpha: 1.0).setFill()
        cg.fill(CGRect(x: margin, y: y, width: boxW, height: boxH))
        cg.fill(CGRect(x: margin + boxW + size.width * 0.02, y: y, width: boxW, height: boxH))

        let boxTitle = attrs(weight: .bold, size: baseFont * 1.15, color: navy)
        ("PICKUP — STOP 1" as NSString).draw(
            at: CGPoint(x: margin + 10, y: y + 10), withAttributes: boxTitle)
        ("DELIVERY — STOP 2" as NSString).draw(
            at: CGPoint(x: margin + boxW + size.width * 0.02 + 10, y: y + 10),
            withAttributes: boxTitle)

        let pickup = [
            "Acme Distribution Center",
            "1450 Industrial Blvd",
            "Dallas, TX 75201",
            "Date: 04/19/2026  Time: 08:00 CDT",
            "Ref: ACME-PU-99412",
            "Contact: Marisol Ruiz (214) 555-0142",
        ]
        let delivery = [
            "Gulf Coast Receiving",
            "3300 Old Spanish Trail",
            "Houston, TX 77002",
            "Date: 04/20/2026  Time: 14:00 CDT",
            "Ref: GCR-DEL-77821",
            "Contact: Tony Brewer (713) 555-0193",
        ]
        let lineH = size.height * 0.019
        for (i, line) in pickup.enumerated() {
            (line as NSString).draw(
                at: CGPoint(x: margin + 10, y: y + 40 + CGFloat(i) * lineH),
                withAttributes: reg)
        }
        for (i, line) in delivery.enumerated() {
            (line as NSString).draw(
                at: CGPoint(x: margin + boxW + size.width * 0.02 + 10,
                            y: y + 40 + CGFloat(i) * lineH),
                withAttributes: reg)
        }
        y += boxH + size.height * 0.028

        // Shipment
        ("SHIPMENT" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: bold)
        y += size.height * 0.022
        let shipRows: [(String, String)] = [
            ("Commodity:", "Consumer electronics — palletized"),
            ("Weight:", "42,000 lbs"),
            ("Equipment:", "53' Dry Van, swing doors"),
            ("Pieces:", "26 pallets, stackable: NO"),
            ("Hazmat:", "No"),
        ]
        for (k, v) in shipRows {
            (k as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: bold)
            (v as NSString).draw(at: CGPoint(x: margin + size.width * 0.11, y: y), withAttributes: reg)
            y += size.height * 0.019
        }
        y += size.height * 0.015

        // Charges table
        ("CHARGES" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: bold)
        y += size.height * 0.024
        let headerY = y
        navy.setFill()
        cg.fill(CGRect(x: margin, y: headerY - 4, width: inner, height: size.height * 0.026))
        let whiteBold = attrs(weight: .bold, size: baseFont * 1.1, color: .white)
        ("Item" as NSString).draw(at: CGPoint(x: margin + 10, y: headerY), withAttributes: whiteBold)
        ("Description" as NSString).draw(at: CGPoint(x: margin + inner * 0.2, y: headerY), withAttributes: whiteBold)
        let amountLabel = "Amount" as NSString
        let amtSz = amountLabel.size(withAttributes: whiteBold)
        amountLabel.draw(at: CGPoint(x: size.width - margin - 10 - amtSz.width, y: headerY), withAttributes: whiteBold)
        y += size.height * 0.026

        let charges: [(String, String, String, Bool)] = [
            ("Linehaul",    "Dallas, TX → Houston, TX (239 mi)", "$1,650.00", false),
            ("FSC",         "Fuel surcharge ($0.628/mi)",        "$150.00",   false),
            ("Accessorial", "Driver assist at pickup",           "$50.00",    false),
            ("",            "TOTAL RATE",                        "$1,850.00", true),
        ]
        for (label, desc, amt, isBold) in charges {
            let a = isBold ? bold : reg
            if isBold {
                UIColor(red: 1.0, green: 0.97, blue: 0.88, alpha: 1).setFill()
                cg.fill(CGRect(x: margin, y: y - 4, width: inner, height: size.height * 0.024))
            }
            (label as NSString).draw(at: CGPoint(x: margin + 10, y: y), withAttributes: a)
            (desc as NSString).draw(at: CGPoint(x: margin + inner * 0.2, y: y), withAttributes: a)
            let amtStr = amt as NSString
            let amtS2 = amtStr.size(withAttributes: a)
            amtStr.draw(at: CGPoint(x: size.width - margin - 10 - amtS2.width, y: y), withAttributes: a)
            y += size.height * 0.024
        }
        y += size.height * 0.02

        // Special instructions
        ("SPECIAL INSTRUCTIONS" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: bold)
        y += size.height * 0.022
        let instr = attrs(weight: .regular, size: baseFont * 1.1, color: .black)
        let instructions = [
            "Driver must call dispatcher 1 hour before pickup. Confirm seal number on BOL prior to leaving.",
            "Detention: $50/hr after 2 free hrs at each stop. Layover: $250 first day, $200 each additional.",
            "Lumper fees pre-approved up to $200 — submit receipts via TMS within 24 hrs of delivery.",
            "Send signed POD + lumper receipts to settlements@chrobinson.com within 48 hrs of delivery.",
        ]
        for line in instructions {
            ("•  \(line)" as NSString).draw(
                at: CGPoint(x: margin, y: y), withAttributes: instr)
            y += size.height * 0.018
        }

        // Footer
        navy.setFill()
        cg.fill(CGRect(x: 0, y: size.height - size.height * 0.04, width: size.width, height: size.height * 0.003))
        let footAttr = attrs(weight: .regular, size: baseFont * 0.9, color: .black)
        ("Acceptance: Driver/Carrier signature constitutes agreement to all rates and terms." as NSString).draw(
            at: CGPoint(x: margin, y: size.height - size.height * 0.030),
            withAttributes: footAttr)
        ("Generated by C.H. Robinson Navisphere Carrier · Confidential" as NSString).draw(
            at: CGPoint(x: margin, y: size.height - size.height * 0.018),
            withAttributes: footAttr)
    }

    private static func attrs(weight: UIFont.Weight, size: CGFloat, color: UIColor) -> [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
    }
}
#endif

// =============================================================================
// MARK: - Monthly Statement Generator
// =============================================================================
// Branded PDF statement for a chosen month (or custom date range). Loads are
// bucketed by RATE-CON date — pickupDate first, then deliveryDate, then
// createdAt only as a last-resort fallback — identical to the dashboard's
// WeeklyStatsService.windowDate rule, so the statement and dashboard always
// agree. Expenses are bucketed by their own date (receiptDate ?? createdAt).
// The user controls the period with month/year pickers or a custom range.

struct MonthlyStatementView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var appMode = AppMode.shared
    @ObservedObject private var localLoads = LocalLoadsRepository.shared
    @ObservedObject private var localExpenses = LocalExpensesRepository.shared

    @State private var loads: [Load] = []
    @State private var expenses: [Expense] = []
    @State private var isLoading = true
    @State private var month = Calendar.current.component(.month, from: Date())
    @State private var year  = Calendar.current.component(.year, from: Date())
    @State private var useCustomRange = false
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var pdfData: Data?
    @State private var showPreview = false

    private let monthSymbols = Calendar.current.monthSymbols
    private var yearOptions: [Int] {
        let y = Calendar.current.component(.year, from: Date())
        return Array((y - 5)...(y + 1)).reversed()
    }

    private var sourceLoads: [Load] { appMode.isLocal ? localLoads.loads : loads }
    private var sourceExpenses: [Expense] { appMode.isLocal ? localExpenses.expenses : expenses }

    /// Half-open [start, end) interval for the selected month or custom range.
    private var interval: DateInterval {
        let cal = Calendar.current
        if useCustomRange {
            let lo = cal.startOfDay(for: min(customStart, customEnd))
            let hi = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(customStart, customEnd))) ?? customEnd
            return DateInterval(start: lo, end: hi)
        }
        var c = DateComponents(); c.year = year; c.month = month; c.day = 1
        let start = cal.date(from: c) ?? Date()
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    /// Counted on the delivery day — delivery first, then pickup, then created.
    private func windowDate(_ l: Load) -> Date? { l.deliveryDate ?? l.pickupDate ?? l.createdAt }

    private var periodLoads: [Load] {
        WeeklyStatsService.dedupe(sourceLoads)
            .filter {
                guard let d = windowDate($0) else { return false }
                return d >= interval.start && d < interval.end
            }
            .sorted { (windowDate($0) ?? .distantPast) < (windowDate($1) ?? .distantPast) }
    }
    private var periodExpenses: [Expense] {
        sourceExpenses.filter {
            guard let d = $0.receiptDate ?? $0.createdAt else { return false }
            return d >= interval.start && d < interval.end
        }
    }

    private var totalRevenue: Double { periodLoads.reduce(0) { $0 + ($1.totalRevenue ?? 0) } }
    private var totalFuel: Double { periodLoads.reduce(0) { $0 + ($1.fuelSurcharge ?? 0) } }
    private var totalAccessorials: Double { periodLoads.reduce(0) { $0 + ($1.accessorialCharges ?? 0) } }
    private var totalMiles: Double { periodLoads.reduce(0) { $0 + ($1.totalMiles ?? 0) } }
    private var totalExpenses: Double { periodExpenses.reduce(0) { $0 + $1.amount } }
    private var netProfit: Double { totalRevenue - totalExpenses }
    private var avgPerLoad: Double { periodLoads.isEmpty ? 0 : totalRevenue / Double(periodLoads.count) }
    private var avgPerMile: Double { totalMiles > 0 ? totalRevenue / totalMiles : 0 }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            Form {
                Section("Period") {
                    Toggle("Custom date range", isOn: $useCustomRange).tint(Color.spGold)
                    if useCustomRange {
                        DatePicker("Start", selection: $customStart, displayedComponents: .date)
                            .foregroundStyle(Color.spTextPrimary)
                        DatePicker("End", selection: $customEnd, displayedComponents: .date)
                            .foregroundStyle(Color.spTextPrimary)
                    } else {
                        Picker("Month", selection: $month) {
                            ForEach(1...12, id: \.self) { m in Text(monthSymbols[m - 1]).tag(m) }
                        }
                        Picker("Year", selection: $year) {
                            ForEach(yearOptions, id: \.self) { y in Text(String(y)).tag(y) }
                        }
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Summary") {
                    statRow("Total Loads", "\(periodLoads.count)")
                    statRow("Total Revenue", totalRevenue.asCurrency)
                    statRow("Fuel Surcharge", totalFuel.asCurrency)
                    statRow("Accessorials", totalAccessorials.asCurrency)
                    statRow("Expenses", totalExpenses.asCurrency)
                    statRow("Net Profit", netProfit.asCurrency)
                    if totalMiles > 0 { statRow("Miles", String(format: "%.0f", totalMiles)) }
                    statRow("Avg / Load", avgPerLoad.asCurrency)
                    if totalMiles > 0 { statRow("Avg / Mile", String(format: "$%.2f", avgPerMile)) }
                }
                .listRowBackground(Color.spCardBg)

                Section {
                    Button {
                        generate()
                    } label: {
                        HStack {
                            Spacer()
                            Label("Generate PDF Statement", systemImage: "doc.richtext.fill")
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(periodLoads.isEmpty && periodExpenses.isEmpty)
                }
                .listRowBackground(Color.spGold)
                .foregroundStyle(Color.spBlack)
            }
            .scrollContentBackground(.hidden)
            if isLoading { ProgressView().tint(Color.spGold) }
        }
        .navigationTitle("Monthly Statement")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadData() }
        .sheet(isPresented: $showPreview) {
            if let pdfData {
                PDFPreviewView(data: pdfData, title: "Monthly Statement")
            }
        }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.spTextSecondary)
            Spacer()
            Text(value).foregroundStyle(Color.spTextPrimary).fontWeight(.semibold)
        }
    }

    private func generate() {
        let title: String
        if useCustomRange {
            title = "\(Self.titleDF.string(from: interval.start)) – \(Self.titleDF.string(from: customEnd))"
        } else {
            title = "\(monthSymbols[month - 1]) \(year)"
        }
        pdfData = MonthlyStatementPDFService.render(
            periodTitle: title,
            companyName: supabase.currentProfile?.companyName ?? "Sacred Pathway Driver Hub",
            loads: periodLoads,
            totals: MonthlyStatementPDFService.Totals(
                loadCount: periodLoads.count, revenue: totalRevenue, fuel: totalFuel,
                accessorials: totalAccessorials, expenses: totalExpenses, netProfit: netProfit,
                miles: totalMiles, avgPerLoad: avgPerLoad, avgPerMile: avgPerMile
            )
        )
        showPreview = (pdfData != nil)
    }

    private static let titleDF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
    }()

    private func loadData() async {
        if appMode.isLocal {
            localLoads.reload(); localExpenses.reload(); isLoading = false; return
        }
        do {
            async let l = supabase.fetchLoads()
            async let e = supabase.fetchAllExpenses()
            loads = try await l
            expenses = try await e
        } catch {
            #if DEBUG
            print("[MonthlyStatement] load failed: \(error)")
            #endif
        }
        isLoading = false
    }
}

// =============================================================================
// MARK: - MonthlyStatementPDFService
// =============================================================================
// Plain UIKit PDF (US Letter) — branded header with the app logo, the date
// range, a per-load table (load #, broker, route, pickup, delivery, revenue,
// expense, profit) and summary totals at the bottom. Auto-paginates the load
// table. No third-party PDF dependency.

enum MonthlyStatementPDFService {
    struct Totals {
        let loadCount: Int
        let revenue: Double
        let fuel: Double
        let accessorials: Double
        let expenses: Double
        let netProfit: Double
        let miles: Double
        let avgPerLoad: Double
        let avgPerMile: Double
    }

    private static let pageW: CGFloat = 612
    private static let pageH: CGFloat = 792
    private static let margin: CGFloat = 42
    private static let gold = UIColor(red: 0.80, green: 0.64, blue: 0.22, alpha: 1)
    private static let dark = UIColor(white: 0.12, alpha: 1)

    /// Counted on the delivery day — delivery first, then pickup, then created.
    private static func windowDate(_ l: Load) -> Date? {
        l.deliveryDate ?? l.pickupDate ?? l.createdAt
    }

    static func render(periodTitle: String,
                       companyName: String,
                       loads: [Load],
                       totals: Totals) -> Data {
        let df = DateFormatter(); df.dateFormat = "MM/dd/yy"
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: pageW, height: pageH),
            format: UIGraphicsPDFRendererFormat()
        )

        return renderer.pdfData { ctx in
            var y: CGFloat = margin
            ctx.beginPage()

            // ── Header ──
            if let logo = UIImage(named: "SacredPathwayLogo") {
                logo.draw(in: CGRect(x: margin, y: y, width: 52, height: 52))
            }
            text("Monthly Statement", margin + 64, y + 4, .systemFont(ofSize: 20, weight: .bold), dark)
            text(companyName, margin + 64, y + 30, .systemFont(ofSize: 12), .darkGray)
            text(periodTitle, margin + 64, y + 47, .systemFont(ofSize: 11, weight: .semibold), gold)
            y += 70
            rule(y); y += 16

            // ── Summary ──
            text("SUMMARY", margin, y, .systemFont(ofSize: 11, weight: .bold), gold); y += 18
            let summary: [(String, String)] = {
                var r: [(String, String)] = [
                    ("Total Loads", "\(totals.loadCount)"),
                    ("Total Revenue", totals.revenue.asCurrency),
                    ("Fuel Surcharge", totals.fuel.asCurrency),
                    ("Accessorials", totals.accessorials.asCurrency),
                    ("Expenses", totals.expenses.asCurrency),
                    ("Net Profit", totals.netProfit.asCurrency),
                    ("Avg / Load", totals.avgPerLoad.asCurrency)
                ]
                if totals.miles > 0 {
                    r.append(("Miles", String(format: "%.0f", totals.miles)))
                    r.append(("Avg / Mile", String(format: "$%.2f", totals.avgPerMile)))
                }
                return r
            }()
            let colW = (pageW - margin * 2) / 2
            for (i, pair) in summary.enumerated() {
                let col = CGFloat(i % 2), row = CGFloat(i / 2)
                let cx = margin + col * colW
                let cy = y + row * 18
                text(pair.0, cx, cy, .systemFont(ofSize: 10), .gray)
                let v = pair.1 as NSString
                let vAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: dark]
                let vw = v.size(withAttributes: vAttr).width
                v.draw(at: CGPoint(x: cx + colW - vw - 12, y: cy), withAttributes: vAttr)
            }
            y += CGFloat((summary.count + 1) / 2) * 18 + 12
            rule(y); y += 16

            // ── Loads table ──
            text("LOADS", margin, y, .systemFont(ofSize: 11, weight: .bold), gold); y += 18

            // Columns: #  Broker  Route  Pickup  Deliv  Revenue  Exp  Profit
            let xs: [CGFloat] = [margin, margin + 62, margin + 150, margin + 300,
                                 margin + 350, margin + 400, margin + 462, margin + 500]
            @MainActor func headerRow() {
                let hf = UIFont.systemFont(ofSize: 8, weight: .bold)
                let labels = ["LOAD #", "BROKER", "ROUTE", "PICKUP", "DELIV", "REVENUE", "EXP", "PROFIT"]
                for (i, l) in labels.enumerated() { text(l, xs[i], y, hf, .gray) }
                y += 13
                rule(y, light: true); y += 4
            }
            headerRow()

            let rf = UIFont.systemFont(ofSize: 8.5)
            for load in loads {
                if y > pageH - margin - 40 {
                    ctx.beginPage(); y = margin
                    text("LOADS (cont.)", margin, y, .systemFont(ofSize: 11, weight: .bold), gold); y += 18
                    headerRow()
                }
                let rev = load.totalRevenue ?? 0
                let exp = 0.0   // expenses are tracked separately, not per-load
                let profit = rev - exp
                let route = "\(load.origin ?? "—") → \(load.destination ?? "—")"
                let pd = load.pickupDate.map { df.string(from: $0) } ?? "—"
                let dd = load.deliveryDate.map { df.string(from: $0) } ?? "—"
                let cells = [
                    clip(load.loadNumber ?? "—", 10),
                    clip(load.brokerName ?? "—", 14),
                    clip(route, 26),
                    pd, dd,
                    rev.asCurrency, exp.asCurrency, profit.asCurrency
                ]
                for (i, c) in cells.enumerated() { text(c, xs[i], y, rf, dark) }
                y += 14
            }

            if loads.isEmpty {
                text("No loads in this period.", margin, y, .systemFont(ofSize: 10), .gray); y += 16
            }

            // ── Footer (current page) ──
            let footer = "Generated by Sacred Pathway Driver Hub" as NSString
            footer.draw(at: CGPoint(x: margin, y: pageH - margin + 6),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.gray])
        }
    }

    // MARK: Draw helpers (use the active PDF graphics context)

    private static func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ font: UIFont, _ color: UIColor) {
        (s as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
    }

    private static func rule(_ y: CGFloat, light: Bool = false) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: pageW - margin, y: y))
        (light ? UIColor(white: 0.85, alpha: 1) : gold).setStroke()
        path.lineWidth = light ? 0.5 : 1
        path.stroke()
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}
