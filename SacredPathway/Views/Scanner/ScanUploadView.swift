import SwiftUI
import VisionKit

struct ScanUploadView: View {
    @EnvironmentObject var supabase: SupabaseService

    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var showManualEntry = false
    @State private var showReview = false
    @State private var scannedImage: UIImage?

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            NavigationStack {
                VStack(spacing: 20) {
                    Spacer()

                    // Camera scan button
                    Button(action: { showCamera = true }) {
                        VStack(spacing: 12) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 48))
                                .foregroundStyle(Color.spGold)
                            Text("Scan Document")
                                .font(.headline)
                                .foregroundStyle(Color.spTextPrimary)
                            Text("Point camera at any rate con, receipt, or invoice")
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .background(Color.spCardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)

                    // Upload buttons row
                    HStack(spacing: 12) {
                        // Upload from Photos
                        Button(action: { showPhotoPicker = true }) {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.system(size: 28))
                                    .foregroundStyle(Color.spDarkGreen)
                                Text("Photos")
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextPrimary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .background(Color.spCardBgLight)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)

                        // Upload from Files
                        Button(action: { showFilePicker = true }) {
                            VStack(spacing: 8) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 28))
                                    .foregroundStyle(Color.spGreenAccent)
                                Text("Files")
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextPrimary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .background(Color.spCardBgLight)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }

                    // Manual entry
                    Button(action: { showManualEntry = true }) {
                        Label("Add Load Manually", systemImage: "plus.circle")
                            .font(.subheadline)
                            .foregroundStyle(Color.spGoldLight)
                    }

                    Spacer()

                    // Info bar
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color.spGold)
                        Text("Claude AI extracts everything instantly")
                            .font(.caption2)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    .padding(.bottom, 8)
                }
                .padding(.horizontal, 24)
                .navigationTitle("Add Document")
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(Color.spBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
            }
        }
        // Camera scanner sheet
        .fullScreenCover(isPresented: $showCamera) {
            DocumentCameraView(
                onScan: { images in
                    if let firstImage = images.first {
                        scannedImage = firstImage
                        showReview = true
                    }
                },
                onCancel: { }
            )
            .ignoresSafeArea()
        }
        // Photo picker sheet
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerView(
                onPick: { image in
                    scannedImage = image
                    showReview = true
                },
                onCancel: { }
            )
        }
        // File picker sheet
        .sheet(isPresented: $showFilePicker) {
            FilePickerView(
                onPick: { image in
                    scannedImage = image
                    showReview = true
                },
                onCancel: { }
            )
        }
        // Manual entry sheet
        .sheet(isPresented: $showManualEntry) {
            ManualLoadEntryView()
                .environmentObject(supabase)
        }
        // Document review sheet (after scan/upload)
        .sheet(isPresented: $showReview) {
            if let image = scannedImage {
                DocumentReviewView(scannedImage: image)
                    .environmentObject(supabase)
            }
        }
    }
}

#Preview {
    ScanUploadView().environmentObject(SupabaseService())
}
