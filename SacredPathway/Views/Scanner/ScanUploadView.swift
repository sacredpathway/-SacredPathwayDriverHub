import SwiftUI
import VisionKit
import AVFoundation

// MARK: - Feature flags
//
// Launch v1 ships WITHOUT AI-based document scanning. The pipeline
// (camera, photo picker, file picker, DocumentReviewView, Edge Function
// extraction) is preserved dormant so it can be reactivated by flipping
// `aiScanEnabled` to `true` once the backend JWT/verification path is
// stable and the App Store copy is updated to disclose AI processing.
//
// Launch v1 also ships WITHOUT subscriptions. ASC IAPs are stuck in
// "Missing Metadata" and can't be attached to the v1.0 submission. To
// avoid an empty / broken paywall during App Review (4.0 / 3.1.1 risk),
// every paywall entry point and feature gate short-circuits when
// `subscriptionsEnabled = false`. Flip to true in v1.1 once the four
// subscription products are "Ready to Submit" in App Store Connect.
enum FeatureFlags {
    static let aiScanEnabled = false
    // v1.1: paywall ON. Flip back to false ONLY if all 4 IAPs slip out
    // of "Ready to Submit" before the v1.1 build is uploaded — a true
    // value with empty StoreKit results triggers a 4.0/3.1.1 rejection.
    static let subscriptionsEnabled = true
    // Smart Scan = on-device OCR + regex parsing. Zero network calls,
    // zero API tokens, zero third-party AI. Safe to ship enabled in v1
    // because nothing leaves the phone.
    static let smartScanEnabled = true
}

/// "Add Load" tab. v1 ships with manual entry as the primary path. The
/// scan/auto-fill entry is hidden entirely until FeatureFlags.aiScanEnabled
/// is true, so users only see fully-shipped functionality.
struct ScanUploadView: View {
    @EnvironmentObject var supabase: SupabaseService
    // Observed so canScan flips reactively when entitlement updates.
    // (Path is dormant until aiScanEnabled is flipped on, but keep it
    // consistent with every other gated surface so a future enable doesn't
    // re-introduce the same non-reactive bug.)
    @ObservedObject private var subscriptions = SubscriptionService.shared

    // Active in v1
    @State private var showManualEntry = false
    @State private var showPaywall = false

    // Smart Scan (on-device) source pickers + review.
    @State private var showSmartScanSourceSheet = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var showReview = false                 // legacy AI review
    @State private var showSmartScanReview = false        // local OCR review
    @State private var showCameraDeniedAlert = false
    @State private var scannedImage: UIImage?
    @State private var originalFileData: Data? = nil
    @State private var originalFileMime: String? = nil
    @State private var smartScanParsed: ParsedLoadFields?
    @State private var isParsing = false

    private var canScan: Bool { subscriptions.isEntitled(.aiScan) }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            NavigationStack {
                VStack(spacing: 16) {
                    Spacer()

                    // ---- Primary: Add a Load (manual entry) ----
                    Button(action: { showManualEntry = true }) {
                        VStack(spacing: 12) {
                            Image(systemName: "plus.rectangle.on.rectangle")
                                .font(.system(size: 48))
                                .foregroundStyle(Color.spGold)
                            Text("Add a Load")
                                .font(.headline)
                                .foregroundStyle(Color.spTextPrimary)
                            Text("Quick entry with auto-calculated revenue, rate per mile, and profit.")
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .background(Color.spCardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)

                    // Smart Scan (on-device OCR + regex). 100% local —
                    // no API tokens, no Edge Functions, no Supabase calls
                    // for parsing. The user always lands on a review
                    // screen and confirms before any save.
                    if FeatureFlags.smartScanEnabled {
                        Button(action: { showSmartScanSourceSheet = true }) {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(Color.spCardBgLight)
                                        .frame(width: 48, height: 48)
                                    if isParsing {
                                        ProgressView().tint(Color.spGoldLight)
                                    } else {
                                        Image(systemName: "doc.text.viewfinder")
                                            .font(.system(size: 22))
                                            .foregroundStyle(Color.spGoldLight)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(isParsing ? "Reading document…" : "Smart Scan a Rate Con")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.spTextPrimary)
                                    Text("Camera, Photos, or Files. On-device OCR fills the form for you.")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Color.spTextSecondary)
                            }
                            .padding(16)
                            .background(Color.spCardBg)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .disabled(isParsing)
                    }

                    // Legacy AI auto-fill — server-based pipeline gated by
                    // FeatureFlags.aiScanEnabled. Stays hidden in v1.
                    if FeatureFlags.aiScanEnabled {
                        Button(action: handleAutoFillTap) {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(Color.spCardBgLight)
                                        .frame(width: 48, height: 48)
                                    Image(systemName: "doc.viewfinder")
                                        .font(.system(size: 22))
                                        .foregroundStyle(Color.spGoldLight)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Auto-fill (AI)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.spTextPrimary)
                                    Text("Cloud-AI extraction (legacy path).")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Color.spTextSecondary)
                            }
                            .padding(16)
                            .background(Color.spCardBg)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(Color.spGold)
                        Text("Manual entry · instant calculations")
                            .font(.caption2)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    .padding(.bottom, 8)
                }
                .padding(.horizontal, 24)
                .navigationTitle("Add Load")
                .toolbarBackground(Color.spBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
            }
        }
        // Active sheets
        .sheet(isPresented: $showManualEntry) {
            ManualLoadEntryView()
                .environmentObject(supabase)
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }

        // ---- Smart Scan source picker ----
        .confirmationDialog(
            "Choose a source",
            isPresented: $showSmartScanSourceSheet,
            titleVisibility: .visible
        ) {
            Button("Camera") { requestCameraAndShow() }
            Button("Photo Library") { showPhotoPicker = true }
            Button("Files (PDF / image)") { showFilePicker = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Smart Scan reads the document on your device — nothing is uploaded.")
        }

        // ---- Pickers — always route through Smart Scan parser ----
        .fullScreenCover(isPresented: $showCamera) {
            DocumentCameraView(
                onScan: { images in
                    if let firstImage = images.first {
                        handleSmartScanImage(
                            firstImage,
                            originalData: nil,
                            mime: nil
                        )
                    }
                },
                onCancel: { }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerView(
                onPick: { image in
                    handleSmartScanImage(image, originalData: nil, mime: nil)
                },
                onCancel: { }
            )
        }
        .sheet(isPresented: $showFilePicker) {
            FilePickerView(
                onPick: { picked in
                    handleSmartScanImage(
                        picked.image,
                        originalData: picked.originalData,
                        mime: picked.mimeType
                    )
                },
                onCancel: { }
            )
        }
        .alert("Camera access needed",
               isPresented: $showCameraDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Use Photo Library") { showPhotoPicker = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enable camera access in Settings → Sacred Pathway to scan documents. You can also upload from Photos or Files instead.")
        }
        // Legacy AI review (only reachable when aiScanEnabled = true).
        .sheet(isPresented: $showReview) {
            if let image = scannedImage {
                DocumentReviewView(
                    scannedImage: image,
                    originalFileData: originalFileData,
                    originalFileMime: originalFileMime
                )
                .environmentObject(supabase)
            }
        }
        // Smart Scan review — local OCR results, fully editable.
        .sheet(isPresented: $showSmartScanReview) {
            if let parsed = smartScanParsed {
                SmartScanReviewView(parsed: parsed, sourceImage: scannedImage)
                    .environmentObject(supabase)
            }
        }
    }

    // MARK: - Smart Scan handler
    //
    // BISECT C 2026-05-17 — parser is confirmed clean. Now turn the review
    // sheet back on, but SmartScanReviewView's body has been swapped with a
    // minimal stub to find which part of the body crashes.
    private func handleSmartScanImage(_ image: UIImage,
                                      originalData: Data?,
                                      mime: String?) {
        scannedImage = image
        originalFileData = originalData
        originalFileMime = mime
        isParsing = true
        Task {
            let parsed = await LocalDocumentParser.parse(image: image)
            await MainActor.run {
                smartScanParsed = parsed
                isParsing = false
                showSmartScanReview = true
            }
        }
    }

    // MARK: - Tap handler

    private func handleAutoFillTap() {
        // Only reachable when FeatureFlags.aiScanEnabled is true.
        requestCameraAndShow()
    }

    // ---- Camera permission helper — used by Smart Scan and the legacy AI path. ----
    // Smart Scan is free (on-device only); the paywall gate only applies
    // when the legacy AI cloud pipeline is enabled.
    private func requestCameraAndShow() {
        if FeatureFlags.aiScanEnabled, !canScan {
            showPaywall = true
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { showCamera = true } else { showCameraDeniedAlert = true }
                }
            }
        case .denied, .restricted:
            showCameraDeniedAlert = true
        @unknown default:
            showCameraDeniedAlert = true
        }
    }
}

#Preview {
    ScanUploadView().environmentObject(SupabaseService())
}
