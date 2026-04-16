import SwiftUI

struct LoadsListView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var loads: [Load] = []
    @State private var isLoading = true
    @State private var showingManualEntry = false

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            NavigationStack {
                Group {
                    if isLoading {
                        ProgressView()
                            .tint(Color.spGold)
                    } else if loads.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "truck.box")
                                .font(.system(size: 50))
                                .foregroundStyle(Color.spTextSecondary)
                            Text("No loads yet")
                                .font(.headline)
                                .foregroundStyle(Color.spTextPrimary)
                            Text("Scan a rate confirmation or add one manually")
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextSecondary)
                            Button {
                                showingManualEntry = true
                            } label: {
                                Label("Add Load Manually", systemImage: "plus.circle.fill")
                                    .font(.headline)
                                    .padding(.vertical, 12).padding(.horizontal, 24)
                                    .background(Color.spGold).foregroundStyle(Color.spBlack)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    } else {
                        List(loads) { load in
                            NavigationLink(destination: LoadDetailView(load: load)) {
                                LoadRowView(load: load)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(Color.spBackground)
                    }
                }
                .navigationTitle("Loads")
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingManualEntry = true } label: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(Color.spGold).font(.title3)
                        }
                    }
                }
                .sheet(isPresented: $showingManualEntry, onDismiss: {
                    Task {
                        do { loads = try await supabase.fetchLoads() } catch {}
                    }
                }) {
                    ManualLoadEntryView()
                        .environmentObject(supabase)
                }
                .task {
                    do {
                        loads = try await supabase.fetchLoads()
                    } catch {
                        print("Error: \(error)")
                    }
                    isLoading = false
                }
            }
        }
    }
}

#Preview {
    LoadsListView().environmentObject(SupabaseService())
}
