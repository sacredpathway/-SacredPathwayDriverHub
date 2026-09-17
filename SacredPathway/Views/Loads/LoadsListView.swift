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
    /// Error from the Ready-to-Settle swipe toggle (S8) — separate from
    /// deleteError so the alert title matches the failed action.
    @State private var settleError: String?
    /// Error from the initial cloud fetch (S8) — previously a silent
    /// `print`, which made a network failure look like an empty list.
    @State private var fetchError: String?

    /// Per-load linked-expense totals (S8): one grouped pass over the
    /// expenses the app already fetches — never a per-row query. Feeds
    /// LoadRowView's NET figure with the same rev−expenses math the
    /// tested dashboard totals use.
    @State private var expenseTotalsByLoad: [UUID: Double] = [:]

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

    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { loadToDelete != nil },
            set: { if !$0 { loadToDelete = nil } }
        )
    }

    private var isDeleteErrorPresented: Binding<Bool> {
        Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )
    }

    private var isSettleErrorPresented: Binding<Bool> {
        Binding(
            get: { settleError != nil },
            set: { if !$0 { settleError = nil } }
        )
    }

    private var emptyLoadsView: some View {
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
                    .padding(.vertical, 12)
                    .padding(.horizontal, 24)
                    .background(Color.spGold)
                    .foregroundStyle(Color.spBlack)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityIdentifier("loads.add.empty")
        }
    }

    private func fetchErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(Color.spDanger)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
            Spacer()
            Button("Retry") {
                isLoading = true
                fetchError = nil
                reload()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.spGoldText)
            .frame(minHeight: 44)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.spDanger.opacity(0.08))
        .accessibilityElement(children: .combine)
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
                        // First-load skeletons (Phase 2 · S6) — the list
                        // keeps its final shape instead of a bare spinner.
                        SPSkeletonList(rows: 6)
                            .padding(.top, 8)
                    } else if sourceLoads.isEmpty {
                        emptyLoadsView
                    } else {
                        VStack(spacing: 0) {
                            Picker("", selection: $showAllLoads) {
                                Text("This Week")
                                    .tag(false)
                                    .accessibilityIdentifier("loads.filter.thisWeek")
                                    .accessibilityAddTraits(showAllLoads ? [] : .isSelected)
                                Text("All Loads")
                                    .tag(true)
                                    .accessibilityIdentifier("loads.filter.all")
                                    .accessibilityAddTraits(showAllLoads ? .isSelected : [])
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .padding(.bottom, 4)

                            // S8: fetch failures are no longer silent — a
                            // network error used to look identical to an
                            // empty week.
                            if let fetchError {
                                fetchErrorBanner(fetchError)
                            }

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
                                    LoadRowView(
                                        load: load,
                                        linkedExpenseTotal: load.id.map { expenseTotalsByLoad[$0] ?? 0 }
                                    )
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

                                    // S8: settle-workflow swipe. Toggles the
                                    // advisory ready_for_settlement status —
                                    // feeds the dashboard attention chip and
                                    // the paystub picker. Settled loads are
                                    // excluded (that status belongs to the
                                    // paystub flow, not a swipe).
                                    if load.loadStatus != .settled {
                                        Button {
                                            toggleReadyForSettlement(load)
                                        } label: {
                                            if load.loadStatus == .readyForSettlement {
                                                Label("Not Ready", systemImage: "arrow.uturn.backward")
                                            } else {
                                                Label("Ready", systemImage: "checkmark.seal")
                                            }
                                        }
                                        .tint(Color.spWarning)
                                    }
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
                    isPresented: isDeleteConfirmationPresented,
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
                       isPresented: isDeleteErrorPresented) {
                    Button("OK") { deleteError = nil }
                } message: {
                    Text(deleteError ?? "")
                }
                .alert("Couldn't update load",
                       isPresented: isSettleErrorPresented) {
                    Button("OK") { settleError = nil }
                } message: {
                    Text(settleError ?? "")
                }
                // Keep row NET totals fresh when expenses change anywhere
                // in the app (add/edit/delete posts .expensesDidChange).
                .onReceive(NotificationCenter.default.publisher(for: .expensesDidChange)) { _ in
                    if appMode.isLocal {
                        rebuildExpenseTotals(from: LocalExpensesRepository.shared.expenses)
                    } else {
                        Task {
                            if let expenses = try? await supabase.fetchAllExpenses() {
                                rebuildExpenseTotals(from: expenses)
                            }
                        }
                    }
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
            rebuildExpenseTotals(from: LocalExpensesRepository.shared.expenses)
            isLoading = false
            return
        }
        do {
            loads = try await supabase.fetchLoads()
            // One grouped pass for per-load NET on rows (S8) — same single
            // fetchAllExpenses call the Dashboard already makes; never a
            // per-row query.
            let expenses = try await supabase.fetchAllExpenses()
            rebuildExpenseTotals(from: expenses)
            fetchError = nil
        } catch {
            fetchError = "Couldn't refresh loads. Showing what's on this device."
            #if DEBUG
            print("[LoadsListView] fetch failed: \(error)")
            #endif
        }
        isLoading = false
    }

    /// Group linked expenses by load id → summed totals for row NET display.
    private func rebuildExpenseTotals(from expenses: [Expense]) {
        var totals: [UUID: Double] = [:]
        for e in expenses {
            guard let loadId = e.loadId else { continue }
            totals[loadId, default: 0] += e.amount
        }
        expenseTotalsByLoad = totals
    }

    /// S8 settle-workflow swipe: toggle the advisory ready_for_settlement
    /// status. Routes through the SAME update paths every other status
    /// change uses — supabase.updateLoad posts `.loadsDidChange` with the
    /// updated load (LoadsSync upserts + coalesces), and the local repo's
    /// published array drives the local recompute. No new sync machinery.
    private func toggleReadyForSettlement(_ load: Load) {
        var updated = load
        updated.status = load.loadStatus == .readyForSettlement
            ? "active"
            : LoadStatus.readyForSettlement.rawValue
        SPHaptics.action()

        if appMode.isLocal {
            localLoads.update(updated)
            return
        }
        Task {
            do {
                try await supabase.updateLoad(updated)
                // Keep this view's own cloud array in step immediately.
                if let idx = loads.firstIndex(where: { $0.id == updated.id }) {
                    loads[idx] = updated
                }
            } catch {
                settleError = "Couldn't update the load's status: \(error.localizedDescription)"
                SPHaptics.error()
            }
        }
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
        copy.status = "active"   // new loads default to Active, never Pending
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
