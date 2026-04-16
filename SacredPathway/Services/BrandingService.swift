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
    func saveLogo(_ image: UIImage) {
        self.logoImage = image
        self.hasCustomBranding = true
        UserDefaults.standard.set(true, forKey: hasCustomBrandingKey)

        // Save to Documents directory
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let url = Self.logoFileURL()
        try? data.write(to: url)
    }

    func removeLogo() {
        self.logoImage = nil
        let url = Self.logoFileURL()
        try? FileManager.default.removeItem(at: url)
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
        return docs.appendingPathComponent("company_logo.jpg")
    }

    private static func loadLogoFromDisk() -> UIImage? {
        let url = logoFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
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
