import SwiftUI

struct LoadsListView: View {
    @EnvironmentObject var supabase: SupabaseService
    // Observed so changing Pay Week Start Day in Settings instantly
    // re-buckets the "This Week" list.
    @ObservedObject private var payWeek = PayWeekService.shared
    @State private var loads: [Load] = []
    @State private var isLoading = true
    @State private var showingManualEntry = false

    // Weekly-reset toggle. Default is "This Week" so the list naturally
    // clears every pay-week boundary — drivers asked for a fresh slate each
    // work week. Pay-week start day is user-configurable in Settings → Pay
    // Week (defaults to Monday).
    @State private var showAllLoads = false

    // Swipe-action state
    @State private var loadToDelete: Load?
    @State private var loadToEdit: Load?
    @State private var loadToDuplicate: Load?
    @State private var deleteError: String?

    /// Loads filtered to the current pay-week unless "All Loads" is selected.
    /// Filter key: pickupDate when present, otherwise createdAt. This handles
    /// loads created before pickup is known and back-dated entries.
    private var visibleLoads: [Load] {
        if showAllLoads { return loads }
        let week = payWeek.weekInterval()
        return loads.filter { load in
            let d = load.pickupDate ?? load.createdAt ?? .distantPast
            return d >= week.start && d < week.end
        }
    }

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
                            Text("Add your first load to start tracking revenue, expenses, and profit.")
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                            Button {
                                showingManualEntry = true
                            } label: {
                                Label("Add a Load", systemImage: "plus.circle.fill")
                                    .font(.headline)
                                    .padding(.vertical, 12).padding(.horizontal, 24)
                                    .background(Color.spGold).foregroundStyle(Color.spBlack)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    } else {
                        VStack(spacing: 0) {
                            Picker("", selection: $showAllLoads) {
                                Text("This Week").tag(false)
                                Text("All Loads").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .padding(.bottom, 4)

                            if visibleLoads.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "calendar")
                                        .font(.system(size: 40))
                                        .foregroundStyle(Color.spTextSecondary)
                                    Text("No loads this week")
                                        .font(.headline)
                                        .foregroundStyle(Color.spTextPrimary)
                                    Text("Tap All Loads to see prior weeks, or add a new load.")
                                        .font(.subheadline)
                                        .foregroundStyle(Color.spTextSecondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 32)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                List {
                            ForEach(visibleLoads) { load in
                                NavigationLink(destination: LoadDetailView(load: load)) {
                                    LoadRowView(load: load)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        loadToDelete = load
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }

                                    Button {
                                        loadToEdit = load
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(Color.spGold)
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    // Quick "duplicate" — opens the entry form
                                    // pre-filled with this load's fields but
                                    // as a fresh row (no id). Saves retyping
                                    // on recurring lanes.
                                    Button {
                                        loadToDuplicate = duplicateTemplate(from: load)
                                    } label: {
                                        Label("Duplicate", systemImage: "doc.on.doc")
                                    }
                                    .tint(Color.spDarkGreen)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(Color.spBackground)
                            }
                        }
                    }
                }
                .navigationTitle("Loads")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingManualEntry = true } label: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(Color.spGold).font(.title3)
                        }
                    }
                }
                // The chooser: ScanUploadView shows both "Add a Load" (manual)
                // and "Smart Scan a Rate Con" (on-device OCR). Manual-first
                // remains primary; Smart Scan is one tap deeper.
                .sheet(isPresented: $showingManualEntry, onDismiss: reload) {
                    ScanUploadView()
                        .environmentObject(supabase)
                }
                .sheet(item: $loadToEdit, onDismiss: reload) { load in
                    ManualLoadEntryView(existingLoad: load)
                        .environmentObject(supabase)
                }
                .sheet(item: $loadToDuplicate, onDismiss: reload) { template in
                    // Duplicate: pre-fill same fields as `template` but
                    // without an `id` so Save creates a new row.
                    ManualLoadEntryView(existingLoad: template)
                        .environmentObject(supabase)
                }
                .confirmationDialog(
                    "Delete this load?",
                    isPresented: Binding(
                        get: { loadToDelete != nil },
                        set: { if !$0 { loadToDelete = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: loadToDelete
                ) { load in
                    Button("Delete Load", role: .destructive) {
                        performDelete(load)
                    }
                    Button("Cancel", role: .cancel) {
                        loadToDelete = nil
                    }
                } message: { load in
                    Text("This will permanently remove Load \(load.loadNumber ?? "—") and any expenses or documents attached to it. This cannot be undone.")
                }
                .alert("Couldn't delete load",
                       isPresented: Binding(
                           get: { deleteError != nil },
                           set: { if !$0 { deleteError = nil } }
                       )) {
                    Button("OK") { deleteError = nil }
                } message: {
                    Text(deleteError ?? "")
                }
                .task { await loadAsync() }
            }
        }
    }

    // MARK: - Data

    private func loadAsync() async {
        do {
            loads = try await supabase.fetchLoads()
        } catch {
            print("Error: \(error)")
        }
        isLoading = false
    }

    private func reload() {
        Task { await loadAsync() }
    }

    /// Copy a load's user-entered fields but strip identity + status so the
    /// ManualLoadEntryView treats it as a brand-new row on save.
    private func duplicateTemplate(from load: Load) -> Load {
        var copy = load
        copy.id = nil
        copy.loadNumber = nil          // let the user assign a new load #
        copy.pickupDate = nil
        copy.deliveryDate = nil
        copy.status = "pending"
        copy.createdAt = nil
        copy.updatedAt = nil
        return copy
    }

    private func performDelete(_ load: Load) {
        guard let loadId = load.id else {
            loadToDelete = nil
            return
        }
        loadToDelete = nil
        Task {
            do {
                try await supabase.deleteLoad(id: loadId)
                loads.removeAll { $0.id == loadId }
            } catch {
                deleteError = "Delete failed: \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    LoadsListView().environmentObject(SupabaseService())
}
