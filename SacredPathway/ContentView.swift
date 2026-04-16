import SwiftUI

struct ContentView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var hasCompletedOnboarding: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if !hasCompletedOnboarding && supabase.currentProfile?.companyName == nil {
                    OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                        .environmentObject(supabase)
                } else {
                    mainTabView
                }
            }
        }
        .onAppear {
            if supabase.currentProfile?.companyName != nil {
                hasCompletedOnboarding = true
            }
        }
    }

    private var mainTabView: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            ScanUploadView()
                .tabItem {
                    Label("Scan", systemImage: "camera.fill")
                }

            LoadsListView()
                .tabItem {
                    Label("Loads", systemImage: "truck.box.fill")
                }

            BrokersListView()
                .tabItem {
                    Label("Brokers", systemImage: "building.2.fill")
                }

            SettingsView()
                .tabItem {
                    Label("More", systemImage: "ellipsis.circle.fill")
                }
        }
        .tint(Color.spGold)
    }
}

#Preview {
    ContentView()
        .environmentObject(SupabaseService())
}
