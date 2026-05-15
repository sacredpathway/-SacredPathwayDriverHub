import SwiftUI

struct ContentView: View {
    @EnvironmentObject var supabase: SupabaseService
    @StateObject private var pinService = PinLockService.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // ScreenshotMode takes a hard fast-path — bypass PIN, onboarding,
            // and any other gates so the screenshot flow always lands in
            // the curated tab bar with seed data. Production runs unaffected.
            if ScreenshotMode.isActive {
                mainTabView
            }
            // PIN lock takes priority over everything if enabled & not yet unlocked
            else if pinService.isEnabled && !pinService.isUnlocked {
                PinLockView()
            } else {
                // Per App Review feedback: NO required onboarding form on
                // first run. Apple-signed users land straight on the
                // dashboard. Profile/business setup is optional and lives
                // inside Settings → Company.
                mainTabView
            }
        }
        .onAppear {
            // ScreenshotMode: force-mark unlocked so any sub-view doesn't
            // redirect to the PIN screen.
            if ScreenshotMode.isActive {
                pinService.isUnlocked = true
                return
            }
            // If no PIN is set, treat as unlocked
            if !pinService.isEnabled {
                pinService.isUnlocked = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Don't auto-lock during screenshot capture — keeps the UI usable
            // when the user switches devices/apps mid-session.
            if ScreenshotMode.isActive { return }
            // Lock again whenever the app goes to background
            if phase == .background {
                pinService.lock()
            }
        }
    }

    private var mainTabView: some View {
        // Single, unified tab bar — same on iPhone and iPad. Five tabs so iOS
        // never collapses Settings into a "More" overflow menu. Compliance
        // lives one tap deeper inside Settings, as a row, not a tab.
        // Pro / subscription access also lives inside Settings.
        TabView {
            DashboardView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag("home")

            LoadsListView()
                .tabItem {
                    Label("Load", systemImage: "shippingbox.fill")
                }
                .tag("load")

            ExpensesListView()
                .tabItem {
                    Label("Expenses", systemImage: "creditcard.fill")
                }
                .tag("expenses")

            NavigationStack {
                SettlementGeneratorView()
            }
            .tabItem {
                Label("Paystub", systemImage: "doc.text.fill")
            }
            .tag("paystub")

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag("settings")
        }
        .tint(Color.spGold)
    }
}

#Preview {
    ContentView()
        .environmentObject(SupabaseService())
}
