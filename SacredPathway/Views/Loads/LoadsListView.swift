import SwiftUI

struct LoadsListView: View {
    @EnvironmentObject var supabase: SupabaseService
    // Observed so changing Pay Week Start Day in Settings instantly
    // re-buckets the "This Week" list.
    @ObservedObject private var payWeek = PayWeekService.shared
    // Observed so any AppMode switch (local ↔ cloud) triggers a re-read
    // through the appropriate repository.
    @ObservedObject private var appMode = AppMode.shared
    // Local-mode repo. When AppMode.isLocal, the list is bound to this
    // singleton's @Published `loads`; cloud mode keeps the existing
    // `@State loads` fed by supabase.fetchLoads().
    @ObservedObject private var localLoads = LocalLoadsRepository.shared
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

    /// Source of truth for the displayed list. In Free Local Mode this is
    /// `LocalLoadsRepository.shared.loads`; in cloud mode it's the
    /// `@State loads` array that `loadAsync()` populated from Supabase.
    private var sourceLoads: [Load] {
        appMode.isLocal ? localLoads.loads : loads
    }

    /// Loads filtered to the current pay-week unless "All Loads" is selected.
    /// Filter key: PICKUP DATE only — single source of truth per spec
    /// (2026-05-24). Loads without a pickup date are excluded from
    /// "This Week" (they still show under "All Loads").
    private var visibleLoads: [Load] {
        if showAllLoads { return sourceLoads }
        let week = payWeek.weekInterval()
        return sourceLoads.filter {
            PayWeekService.pickupFalls(in: week, pickupDate: $0.pickupDate)
        }
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            NavigationStack {
                VStack(spacing: 0) {
                    if appMode.isLocal {
                        LocalModeBanner()
                    }
                Group {
                    if isLoading {
                        ProgressView()
                            .tint(Color.spGold)
                    } else if sourceLoads.isEmpty {
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
                            .accessibilityIdentifier("loads.add.empty")
                        }
                    } else {
                        VStack(spacing: 0) {
                            Picker("", selection: $showAllLoads) {
                                Text("This Week")
                                    .tag(false)
                                    .accessibilityIdentifier("loads.filter.thisWeek")
                                Text("All Loads")
                                    .tag(true)
                                    .accessibilityIdentifier("loads.filter.all")
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
                                .accessibilityIdentifier(rowIdentifier(for: load))
                                .accessibilityValue(rowAccessibilityValue(for: load))
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
                        .accessibilityIdentifier("loads.add.toolbar")
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
                }   // closes VStack added for LocalModeBanner
            }
        }
    }

    // MARK: - Data

    private func loadAsync() async {
        // In Free Local Mode the LocalLoadsRepository singleton is the
        // source of truth — already in memory from disk on init — so we
        // just flip the loading flag off and let SwiftUI render from
        // `localLoads.loads` via `sourceLoads`. In cloud mode we keep the
        // existing Supabase fetch.
        if appMode.isLocal {
            isLoading = false
            return
        }
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

    private func rowIdentifier(for load: Load) -> String {
        load.id.map { "load.row.\($0.uuidString.lowercased())" } ?? "load.row.unsaved"
    }

    private func rowAccessibilityValue(for load: Load) -> String {
        let miles = load.totalMiles.map { String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? ""
        let lineHaul = load.lineHaulRate.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? ""
        return [
            "number=\(load.loadNumber ?? "")",
            "broker=\(load.brokerName ?? "")",
            "origin=\(load.origin ?? "")",
            "destination=\(load.destination ?? "")",
            "miles=\(miles)",
            "lineHaul=\(lineHaul)"
        ].joined(separator: ";")
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
        // Free Local Mode: delete from the on-device JSON store. No cloud
        // round-trip required, no auth check, can't fail with a network
        // error.
        if appMode.isLocal {
            localLoads.delete(id: loadId)
            return
        }
        // Tombstone immediately so totals on every observer (Dashboard,
        // Insights, Settlements) drop the row BEFORE the round-trip
        // completes. If the server delete fails the row reappears on the
        // next successful refresh — fail-safe.
        LoadsSyncService.shared.tombstone(loadId)
        Task {
            do {
                try await supabase.deleteLoad(id: loadId)
                loads.removeAll { $0.id == loadId }
            } catch {
                deleteError = "Delete failed: \(error.localizedDescription)"
                // Server delete failed. A successful refresh wipes every
                // tombstone (see LoadsSyncService.refresh), so the row
                // reappears as soon as the next round-trip succeeds —
                // we don't have to clear tombstones by hand here.
                await LoadsSyncService.shared.refresh(supabase: supabase)
            }
        }
    }
}

#Preview {
    LoadsListView().environmentObject(SupabaseService())
}
