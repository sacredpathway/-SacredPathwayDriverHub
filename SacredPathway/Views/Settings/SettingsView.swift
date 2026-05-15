import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var appearance = AppearanceService.shared
    // Observed so the "Current: <tier>" label and any other gated copy
    // refresh the moment a purchase or restore changes activeTier.
    @ObservedObject private var subscriptions = SubscriptionService.shared

    // Pro/upgrade paywall — presented as a sheet from the top "Pro" section.
    // PaywallView itself is unchanged; this is just an additional entry point.
    @State private var showPaywall = false

    // Demo seeder feedback (DEBUG-only flow; harmless inert state in Release)
    @State private var isSeeding = false
    @State private var seedAlertTitle: String = ""
    @State private var seedAlertBody: String = ""
    @State private var showSeedAlert: Bool = false

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            NavigationStack {
                VStack(spacing: 0) {
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
                        if FeatureFlags.subscriptionsEnabled {
                            Section("Pro") {
                                Button {
                                    showPaywall = true
                                } label: {
                                    HStack {
                                        Image(systemName: "sparkles")
                                            .foregroundStyle(Color.spGold)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Upgrade to Pro")
                                                .foregroundStyle(Color.spTextPrimary)
                                            Text("Unlock everything in one tap")
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
                            // Pro-gated 2026-05 via SubscriptionService.Feature.cpaTaxPackage.
                            // Entitled users get the normal NavigationLink → CPAReadyExportView.
                            // Free-tier users see the same row decorated with a lock; tapping
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
                        }
                        .listRowBackground(Color.spCardBg)
                        .headerProminence(.increased)

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

                        Section("Operations") {
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
                                            Text("Current: \(subscriptions.activeTier.displayName) — upgrade, restore, manage")
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
                                        Text("Demo Mode (Unlock All)")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("DEBUG only — bypass paywall for screenshots")
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
