import SwiftUI
import PhotosUI

struct BrandingSettingsView: View {
    @StateObject private var branding = BrandingService.shared
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingResetAlert = false
    @State private var savedMessage = false

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // MARK: - Logo Section
                    logoSection

                    // MARK: - Color Scheme Section
                    colorSection

                    // MARK: - Preview Section
                    previewSection

                    // MARK: - Reset Button
                    resetSection
                }
                .padding()
            }
        }
        .navigationTitle("Branding")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    // Resize to reasonable size for logo
                    let resized = resizeImage(image, maxDimension: 512)
                    branding.saveLogo(resized)
                    showSavedFeedback()
                }
            }
        }
        .alert("Reset Branding", isPresented: $showingResetAlert) {
            Button("Reset", role: .destructive) {
                branding.resetToDefaults()
                showSavedFeedback()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove your custom logo and reset colors to Sacred Pathway defaults.")
        }
    }

    // MARK: - Logo Section
    private var logoSection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "photo.badge.plus")
                    .foregroundStyle(branding.primaryColor)
                Text("Company Logo")
                    .font(.headline)
                    .foregroundStyle(Color.spTextPrimary)
                Spacer()
            }

            // Logo preview or placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.spCardBg)
                    .frame(height: 180)

                if let logo = branding.logoImage {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "building.2.crop.circle")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.spTextSecondary)
                        Text("No logo uploaded")
                            .font(.subheadline)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                }
            }

            HStack(spacing: 12) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label(branding.logoImage == nil ? "Upload Logo" : "Change Logo", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(branding.primaryColor.opacity(0.15))
                        .foregroundStyle(branding.primaryColor)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                if branding.logoImage != nil {
                    Button {
                        branding.removeLogo()
                        showSavedFeedback()
                    } label: {
                        Label("Remove", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.spDanger.opacity(0.15))
                            .foregroundStyle(Color.spDanger)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }

            Text("Your logo appears on paystubs, settlements, and exported PDFs.")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Color Section
    private var colorSection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "paintpalette.fill")
                    .foregroundStyle(branding.primaryColor)
                Text("Brand Colors")
                    .font(.headline)
                    .foregroundStyle(Color.spTextPrimary)
                Spacer()
            }

            // Primary Color
            VStack(alignment: .leading, spacing: 8) {
                Text("Primary Color")
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextSecondary)
                HStack {
                    ColorPicker("", selection: $branding.primaryColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 44, height: 44)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(branding.primaryColor)
                        .frame(height: 44)
                    Text("Headers & Highlights")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                .onChange(of: branding.primaryColor) { _, newColor in
                    branding.savePrimaryColor(newColor)
                    showSavedFeedback()
                }
            }

            Divider().background(Color.spTextSecondary.opacity(0.3))

            // Accent Color
            VStack(alignment: .leading, spacing: 8) {
                Text("Accent Color")
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextSecondary)
                HStack {
                    ColorPicker("", selection: $branding.accentColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 44, height: 44)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(branding.accentColor)
                        .frame(height: 44)
                    Text("Buttons & Accents")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                .onChange(of: branding.accentColor) { _, newColor in
                    branding.saveAccentColor(newColor)
                    showSavedFeedback()
                }
            }

            // Preset palettes
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Presets")
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        presetButton("Sacred Pathway", primary: Color.spGold, accent: Color.spGreenAccent)
                        presetButton("Midnight Blue", primary: Color(red: 0.2, green: 0.4, blue: 0.8), accent: Color(red: 0.3, green: 0.6, blue: 0.9))
                        presetButton("Crimson", primary: Color(red: 0.75, green: 0.15, blue: 0.15), accent: Color(red: 0.9, green: 0.3, blue: 0.2))
                        presetButton("Forest", primary: Color(red: 0.2, green: 0.55, blue: 0.3), accent: Color(red: 0.4, green: 0.7, blue: 0.3))
                        presetButton("Orange Fleet", primary: Color(red: 0.9, green: 0.5, blue: 0.1), accent: Color(red: 0.95, green: 0.65, blue: 0.2))
                        presetButton("Steel", primary: Color(red: 0.45, green: 0.5, blue: 0.55), accent: Color(red: 0.6, green: 0.65, blue: 0.7))
                    }
                }
            }
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Preview Section
    private var previewSection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "eye.fill")
                    .foregroundStyle(branding.primaryColor)
                Text("Paystub Preview")
                    .font(.headline)
                    .foregroundStyle(Color.spTextPrimary)
                Spacer()
                if savedMessage {
                    Text("Saved!")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.spSuccess)
                        .transition(.opacity)
                }
            }

            // Mini paystub preview
            VStack(spacing: 0) {
                // Header bar
                HStack {
                    if let logo = branding.logoImage {
                        Image(uiImage: logo)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "truck.box.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                    }
                    Text("Your Company Name")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("PAYSTUB")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(12)
                .background(branding.primaryColor)

                // Body
                VStack(spacing: 8) {
                    HStack {
                        Text("Driver: John Smith")
                            .font(.caption2)
                        Spacer()
                        Text("Period: 04/01 – 04/14")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)

                    Divider()

                    HStack {
                        Text("Gross Revenue")
                            .font(.caption2)
                        Spacer()
                        Text("$4,850.00")
                            .font(.caption2.weight(.semibold))
                    }

                    HStack {
                        Text("Net Pay")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(branding.accentColor)
                        Spacer()
                        Text("$2,425.00")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(branding.accentColor)
                    }
                }
                .padding(12)
                .background(Color(.systemBackground))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Reset Section
    private var resetSection: some View {
        Button {
            showingResetAlert = true
        } label: {
            Label("Reset to Default Branding", systemImage: "arrow.counterclockwise")
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.spCardBg)
                .foregroundStyle(Color.spTextSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Helpers
    private func presetButton(_ name: String, primary: Color, accent: Color) -> some View {
        Button {
            branding.savePrimaryColor(primary)
            branding.saveAccentColor(accent)
            showSavedFeedback()
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle().fill(primary).frame(width: 18, height: 18)
                    Circle().fill(accent).frame(width: 18, height: 18)
                }
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(Color.spTextPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.spCardBgLight)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func showSavedFeedback() {
        withAnimation { savedMessage = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { savedMessage = false }
        }
    }

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let ratio = min(maxDimension / size.width, maxDimension / size.height)
        if ratio >= 1 { return image }
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

#Preview {
    NavigationStack {
        BrandingSettingsView()
    }
}
