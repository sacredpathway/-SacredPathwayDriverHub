import SwiftUI

@main
struct SacredPathwayApp: App {
    @StateObject private var supabase = SupabaseService()

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Always-present dark background prevents white flash
                Color.spBackground.ignoresSafeArea()

                if supabase.isLoading {
                    VStack(spacing: 16) {
                        Image(systemName: "truck.box.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(Color.spGold)
                        ProgressView()
                            .tint(Color.spGold)
                        Text("Loading...")
                            .foregroundStyle(.white)
                    }
                } else if supabase.isAuthenticated {
                    ContentView()
                        .environmentObject(supabase)
                } else {
                    LoginView()
                        .environmentObject(supabase)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                print("🟢 SacredPathwayApp appeared — isLoading: \(supabase.isLoading), isAuth: \(supabase.isAuthenticated)")
                // Safety timeout — if loading hangs for more than 4 seconds, force show login
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if supabase.isLoading {
                        print("🟡 Safety timeout — forcing isLoading = false")
                        supabase.isLoading = false
                    }
                }
            }
        }
    }
}
