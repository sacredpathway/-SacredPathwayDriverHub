import SwiftUI

// =============================================================================
// AppearanceService
// -----------------------------------------------------------------------------
// Stores the user's preferred appearance: System / Light / Dark.
//
// Persistence: UserDefaults key "spAppearanceMode". Default = .system.
//
// How to use:
//   • At the app root: read AppearanceService.shared.mode and apply
//     .preferredColorScheme(mode.colorScheme) to the root view.
//   • In Settings: bind a Picker to AppearanceService.shared.$mode.
//
// All Sacred Pathway brand surfaces use dynamic Colors (see BrandColors.swift)
// that adapt to userInterfaceStyle, so flipping mode here flips the whole UI
// without per-view work.
// =============================================================================

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System Default"
        case .light:  return "Light Mode"
        case .dark:   return "Dark Mode"
        }
    }

    /// The SwiftUI colorScheme to apply. nil = follow system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

@MainActor
final class AppearanceService: ObservableObject {
    static let shared = AppearanceService()

    private static let storageKey = "spAppearanceMode"

    @Published var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.storageKey)
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppearanceMode.system.rawValue
        self.mode = AppearanceMode(rawValue: raw) ?? .system
    }
}
