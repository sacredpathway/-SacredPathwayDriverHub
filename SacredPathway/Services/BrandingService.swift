import SwiftUI
import PhotosUI

/// Manages the carrier's custom branding — logo image and color scheme.
/// Persists locally using UserDefaults (colors) and Documents directory (logo).
@MainActor
class BrandingService: ObservableObject {
    static let shared = BrandingService()

    // MARK: - Published Properties
    @Published var logoImage: UIImage?
    @Published var primaryColor: Color
    @Published var accentColor: Color
    @Published var hasCustomBranding: Bool

    // MARK: - Keys
    private let primaryRedKey = "branding_primary_red"
    private let primaryGreenKey = "branding_primary_green"
    private let primaryBlueKey = "branding_primary_blue"
    private let accentRedKey = "branding_accent_red"
    private let accentGreenKey = "branding_accent_green"
    private let accentBlueKey = "branding_accent_blue"
    private let hasCustomBrandingKey = "branding_has_custom"

    // MARK: - Init
    init() {
        let defaults = UserDefaults.standard
        self.hasCustomBranding = defaults.bool(forKey: hasCustomBrandingKey)

        // Load saved colors or use defaults (Sacred Pathway gold)
        if defaults.object(forKey: primaryRedKey) != nil {
            let r = defaults.double(forKey: primaryRedKey)
            let g = defaults.double(forKey: primaryGreenKey)
            let b = defaults.double(forKey: primaryBlueKey)
            self.primaryColor = Color(red: r, green: g, blue: b)
        } else {
            self.primaryColor = Color.spGold
        }

        if defaults.object(forKey: accentRedKey) != nil {
            let r = defaults.double(forKey: accentRedKey)
            let g = defaults.double(forKey: accentGreenKey)
            let b = defaults.double(forKey: accentBlueKey)
            self.accentColor = Color(red: r, green: g, blue: b)
        } else {
            self.accentColor = Color.spGreenAccent
        }

        // Load saved logo
        self.logoImage = Self.loadLogoFromDisk()
    }

    // MARK: - Save Colors
    func savePrimaryColor(_ color: Color) {
        let components = color.rgbComponents
        let defaults = UserDefaults.standard
        defaults.set(components.red, forKey: primaryRedKey)
        defaults.set(components.green, forKey: primaryGreenKey)
        defaults.set(components.blue, forKey: primaryBlueKey)
        self.primaryColor = color
        self.hasCustomBranding = true
        defaults.set(true, forKey: hasCustomBrandingKey)
    }

    func saveAccentColor(_ color: Color) {
        let components = color.rgbComponents
        let defaults = UserDefaults.standard
        defaults.set(components.red, forKey: accentRedKey)
        defaults.set(components.green, forKey: accentGreenKey)
        defaults.set(components.blue, forKey: accentBlueKey)
        self.accentColor = color
        self.hasCustomBranding = true
        defaults.set(true, forKey: hasCustomBrandingKey)
    }

    // MARK: - Logo Management
    /// Persists the user's logo at the highest fidelity we can. PNG is used
    /// because it's lossless and preserves transparency — critical for logos
    /// dropped on coloured headers. The cached UIImage exposed via
    /// `logoImage` is the same in-memory full-resolution copy used for
    /// PDF/header rendering, so no quality is dropped between upload and
    /// export.
    func saveLogo(_ image: UIImage) {
        self.logoImage = image
        self.hasCustomBranding = true
        UserDefaults.standard.set(true, forKey: hasCustomBrandingKey)

        // Prefer PNG (lossless + alpha). Fall back to high-quality JPEG only
        // if PNG encoding fails (rare — UIImage doesn't always have CGImage).
        let url = Self.logoFileURL()
        // Remove any old .jpg copy so we don't read stale data on next launch.
        try? FileManager.default.removeItem(at: Self.legacyLogoFileURL())

        if let png = image.pngData() {
            try? png.write(to: url, options: .atomic)
        } else if let jpg = image.jpegData(compressionQuality: 1.0) {
            // Lossless-ish JPEG fallback (still better than 0.85).
            try? jpg.write(to: url, options: .atomic)
        }
    }

    func removeLogo() {
        self.logoImage = nil
        try? FileManager.default.removeItem(at: Self.logoFileURL())
        try? FileManager.default.removeItem(at: Self.legacyLogoFileURL())
    }

    /// Returns a properly sized rendition of the logo for an arbitrary target
    /// height in points, using high-quality interpolation and the device
    /// scale (typically 3x on iPhone). The original full-resolution image is
    /// preserved on `logoImage`; this is only for places that genuinely need
    /// a pre-sized bitmap (e.g. UIKit table cells). Most callers — including
    /// PDF generation — should draw `logoImage` directly into a target rect
    /// and let Core Graphics scale on demand.
    func renderLogo(targetHeight: CGFloat) -> UIImage? {
        guard let logo = logoImage, logo.size.height > 0 else { return nil }
        let scale = max(1, logo.size.height) / max(1, targetHeight)
        let newSize = CGSize(
            width: logo.size.width / scale,
            height: targetHeight
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 0  // honor device scale (Retina)
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { ctx in
            ctx.cgContext.interpolationQuality = .high
            logo.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Reset
    func resetToDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: primaryRedKey)
        defaults.removeObject(forKey: primaryGreenKey)
        defaults.removeObject(forKey: primaryBlueKey)
        defaults.removeObject(forKey: accentRedKey)
        defaults.removeObject(forKey: accentGreenKey)
        defaults.removeObject(forKey: accentBlueKey)
        defaults.set(false, forKey: hasCustomBrandingKey)

        self.primaryColor = Color.spGold
        self.accentColor = Color.spGreenAccent
        self.hasCustomBranding = false
        removeLogo()
    }

    // MARK: - File Helpers
    private static func logoFileURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("company_logo.png")
    }

    /// Older builds saved to `company_logo.jpg`. We migrate transparently —
    /// `loadLogoFromDisk` reads the new PNG first, then falls back to the
    /// old JPG for users on this build's first launch.
    private static func legacyLogoFileURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("company_logo.jpg")
    }

    private static func loadLogoFromDisk() -> UIImage? {
        let png = logoFileURL()
        if FileManager.default.fileExists(atPath: png.path),
           let data = try? Data(contentsOf: png),
           let image = UIImage(data: data) {
            return image
        }
        // Migrate legacy JPEG users without losing their old logo.
        let jpg = legacyLogoFileURL()
        if FileManager.default.fileExists(atPath: jpg.path),
           let data = try? Data(contentsOf: jpg),
           let image = UIImage(data: data) {
            return image
        }
        return nil
    }
}

// MARK: - Color Extension for RGB extraction
extension Color {
    var rgbComponents: (red: Double, green: Double, blue: Double) {
        let uiColor = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }
}
