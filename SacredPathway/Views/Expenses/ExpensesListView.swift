import SwiftUI
import AVFoundation

struct ExpensesListView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var appMode = AppMode.shared
    @ObservedObject private var localExpenses = LocalExpensesRepository.shared
    @State private var expenses: [Expense] = []
    @State private var isLoading = true
    @State private var showingAddExpense = false
    @State private var editingExpense: Expense?
    @State private var filterCategory: String? = nil

    // ── Receipt Smart Scan (lives in the EXPENSE tab) ──
    // On-device OCR of a receipt → prefilled expense. Receipts create
    // EXPENSES here, not loads.
    @State private var showReceiptSource = false
    @State private var showReceiptCamera = false
    @State private var showReceiptPhotoPicker = false
    @State private var showReceiptFilePicker = false
    @State private var showReceiptCameraDenied = false
    @State private var showReceiptReview = false
    @State private var isParsingReceipt = false
    @State private var receiptPrefill: ExpenseFormPrefill?
    // Weekly view, like Loads. Default "This Week" so expenses naturally reset
    // each pay week; "This Month" and "All" available via the segmented control.
    @State private var periodFilter: ExpensePeriod = .week

    enum ExpensePeriod: String, CaseIterable, Identifiable {
        case week  = "This Week"
        case month = "This Month"
        case all   = "All"
        var id: String { rawValue }
        var stats: StatsPeriod { self == .week ? .week : (self == .month ? .month : .allTime) }
    }

    private let categories = ["fuel", "lumper", "toll", "repair", "insurance", "maintenance", "other"]

    /// Source of truth — local repo when in Free Local Mode, otherwise
    /// the @State expenses array fed by Supabase.
    private var sourceExpenses: [Expense] {
        appMode.isLocal ? localExpenses.expenses : expenses
    }

    var filteredExpenses: [Expense] {
        var result = sourceExpenses
        // Period window (This Week / This Month). Uses the SAME interval rule as
        // the dashboard, and the same effective-date fallback as loads
        // (receiptDate ?? createdAt) so expenses without a receipt date still
        // appear in the week/month they were entered.
        if periodFilter != .all {
            let i = WeeklyStatsService.interval(for: periodFilter.stats)
            result = result.filter {
                guard let d = $0.receiptDate ?? $0.createdAt else { return false }
                return d >= i.start && d < i.end
            }
        }
        if let cat = filterCategory {
            result = result.filter { $0.category.lowercased() == cat }
        }
        return result
    }

    var totalExpenses: Double {
        filteredExpenses.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            NavigationStack {
                VStack(spacing: 0) {
                    if appMode.isLocal {
                        LocalModeBanner()
                    }
                    // Period selector (This Week / This Month / All) — mirrors Loads.
                    Picker("Period", selection: $periodFilter) {
                        ForEach(ExpensePeriod.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)

                    // Summary header
                    VStack(spacing: 8) {
                        Text(periodFilter == .all ? "Total Expenses" : "Total Expenses — \(periodFilter.rawValue)")
                            .font(.subheadline)
                            .foregroundStyle(Color.spTextSecondary)
                        Text(totalExpenses.asCurrency)
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.spDanger)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.spCardBg)

                    // Category filter chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterChip("All", category: nil)
                            ForEach(categories, id: \.self) { cat in
                                filterChip(cat.capitalized, category: cat)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                    }

                    if isLoading {
                        // First-load skeletons keep the list's final shape
                        // instead of a centered spinner (Phase 2 · S6).
                        SPSkeletonList(rows: 6)
                            .padding(.top, 8)
                        Spacer()
                    } else if filteredExpenses.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "receipt")
                                .font(.system(size: 48))
                                .foregroundStyle(Color.spTextSecondary)
                            Text(periodFilter == .all
                                 ? "No expenses yet — tap + to add your first one."
                                 : "No expenses for \(periodFilter.rawValue.lowercased()). Switch to “All” to see everything.")
                                .font(.headline)
                                .foregroundStyle(Color.spTextSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        Spacer()
                    } else {
                        List {
                            ForEach(filteredExpenses) { expense in
                                expenseRow(expense)
                                    .listRowBackground(Color.spCardBg)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        editingExpense = expense
                                    }
                            }
                            .onDelete(perform: deleteExpenses)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
                .navigationTitle("Expenses")
                .toolbar {
                    // Scan a receipt → on-device OCR → prefilled expense.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showReceiptSource = true
                        } label: {
                            if isParsingReceipt {
                                ProgressView().tint(Color.spGold)
                            } else {
                                Image(systemName: "doc.text.viewfinder")
                                    .foregroundStyle(Color.spGold)
                                    .font(.title3)
                            }
                        }
                        .disabled(isParsingReceipt)
                        .accessibilityLabel("Scan Receipt")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingAddExpense = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.spGold)
                                .font(.title3)
                        }
                        .accessibilityLabel("Add Expense")
                    }
                }
                .sheet(isPresented: $showingAddExpense) {
                    AddEditExpenseView(mode: .add) { newExpense in
                        expenses.insert(newExpense, at: 0)
                    }
                    .environmentObject(supabase)
                }
                .sheet(item: $editingExpense) { expense in
                    AddEditExpenseView(mode: .edit(expense)) { updated in
                        if let index = expenses.firstIndex(where: { $0.id == updated.id }) {
                            expenses[index] = updated
                        }
                    }
                    .environmentObject(supabase)
                }
                // ── Receipt Smart Scan flow ──
                .confirmationDialog("Scan a receipt", isPresented: $showReceiptSource, titleVisibility: .visible) {
                    Button("Camera") { requestReceiptCamera() }
                    Button("Photo Library") { showReceiptPhotoPicker = true }
                    Button("Files (PDF / image)") { showReceiptFilePicker = true }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Smart Scan reads the receipt on your device — nothing is uploaded. It fills the amount, vendor, and date for you.")
                }
                .fullScreenCover(isPresented: $showReceiptCamera) {
                    DocumentCameraView(
                        onScan: { images in
                            if let first = images.first { handleReceiptImage(first) }
                        },
                        onCancel: { }
                    )
                    .ignoresSafeArea()
                }
                .sheet(isPresented: $showReceiptPhotoPicker) {
                    PhotoPickerView(onPick: { image in handleReceiptImage(image) }, onCancel: { })
                }
                .sheet(isPresented: $showReceiptFilePicker) {
                    FilePickerView(onPick: { picked in handleReceiptImage(picked.image) }, onCancel: { })
                }
                .sheet(isPresented: $showReceiptReview) {
                    if let prefill = receiptPrefill {
                        AddEditExpenseView(mode: .add, prefill: prefill) { newExpense in
                            expenses.insert(newExpense, at: 0)
                        }
                        .environmentObject(supabase)
                    }
                }
                .alert("Camera access needed", isPresented: $showReceiptCameraDenied) {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    Button("Use Photo Library") { showReceiptPhotoPicker = true }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Enable camera access in Settings → Sacred Pathway to scan receipts. You can also upload from Photos or Files instead.")
                }
                .task { await loadExpenses() }
            }
        }
    }

    // MARK: - Subviews

    private func expenseRow(_ expense: Expense) -> some View {
        HStack(spacing: 12) {
            // Category icon
            ZStack {
                Circle()
                    .fill(categoryColor(expense.category).opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: categoryIcon(expense.category))
                    .foregroundStyle(categoryColor(expense.category))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(expense.category.capitalized)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                    if expense.receiptImageFilename != nil {
                        Image(systemName: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(Color.spTextSecondary)
                            .accessibilityLabel("Receipt photo attached")
                    }
                }
                if let vendor = expense.vendorName, !vendor.isEmpty {
                    Text(vendor)
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                if let date = expense.receiptDate {
                    Text(date, style: .date)
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary)
                }
            }

            Spacer()

            Text(expense.amount.asCurrency)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.spDanger)
        }
        .padding(.vertical, 4)
    }

    // A11y (Phase 1 · Task 6): 44pt hit target (visual capsule unchanged),
    // selection exposed as a VoiceOver trait rather than color alone.
    private func filterChip(_ title: String, category: String?) -> some View {
        Button {
            SPHaptics.selection()
            withAnimation(.spQuick) { filterCategory = category }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(filterCategory == category ? Color.spGold : Color.spCardBg)
                .foregroundStyle(filterCategory == category ? Color.spBlack : Color.spTextPrimary)
                .clipShape(Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Filter: \(title)")
        .accessibilityAddTraits(filterCategory == category ? [.isSelected] : [])
    }

    // MARK: - Actions

    // MARK: - Receipt Smart Scan

    /// OCR the receipt on-device, then open the expense form prefilled with the
    /// parsed amount / vendor / date. Always lands on the editable review form
    /// so the user confirms before saving.
    private func handleReceiptImage(_ image: UIImage) {
        isParsingReceipt = true
        Task {
            let parsed = await LocalDocumentParser.parseFuelReceipt(image: image)
            await MainActor.run {
                var prefill = parsed.expensePrefill
                // Carry the captured photo into the form so saving the
                // expense persists the image too — previously the photo was
                // OCR'd and then thrown away (Phase 1 · Task 3).
                prefill.receiptImage = image
                receiptPrefill = prefill
                isParsingReceipt = false
                SPHaptics.success()   // scan parsed — fields are ready
                showReceiptReview = true
            }
        }
    }

    private func requestReceiptCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showReceiptCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { showReceiptCamera = true } else { showReceiptCameraDenied = true }
                }
            }
        case .denied, .restricted:
            showReceiptCameraDenied = true
        @unknown default:
            showReceiptCameraDenied = true
        }
    }

    private func loadExpenses() async {
        if appMode.isLocal {
            // LocalExpensesRepository is already in memory from disk.
            isLoading = false
            return
        }
        do {
            expenses = try await supabase.fetchAllExpenses()
        } catch {
            print("Error loading expenses: \(error)")
        }
        isLoading = false
    }

    private func deleteExpenses(at offsets: IndexSet) {
        SPHaptics.warning()
        let toDelete = offsets.map { filteredExpenses[$0] }
        for expense in toDelete {
            guard let id = expense.id else { continue }
            if appMode.isLocal {
                // Repo deletes the row AND its receipt image file.
                localExpenses.delete(id: id)
            } else {
                let receiptFilename = expense.receiptImageFilename
                Task {
                    do {
                        try await supabase.deleteExpense(id)
                        // Row confirmed gone → clean up the on-device
                        // receipt file so no orphan remains (Task 3).
                        ReceiptImageStore.shared.delete(filename: receiptFilename)
                    } catch {
                        #if DEBUG
                        print("[ExpensesListView] cloud delete failed: \(error)")
                        #endif
                    }
                }
                expenses.removeAll { $0.id == id }
            }
        }
    }

    // MARK: - Helpers

    private func categoryIcon(_ category: String) -> String {
        switch category.lowercased() {
        case "fuel": return "fuelpump.fill"
        case "lumper": return "person.2.fill"
        case "toll": return "road.lanes"
        case "repair": return "wrench.and.screwdriver.fill"
        case "insurance": return "shield.checkered"
        case "maintenance": return "gearshape.2.fill"
        default: return "dollarsign.circle.fill"
        }
    }

    private func categoryColor(_ category: String) -> Color {
        switch category.lowercased() {
        case "fuel": return Color(red: 0.2, green: 0.6, blue: 0.9)
        case "lumper": return Color(red: 0.8, green: 0.5, blue: 0.2)
        case "toll": return Color(red: 0.6, green: 0.4, blue: 0.8)
        case "repair": return Color.spDanger
        case "insurance": return Color.spSuccess
        case "maintenance": return Color.spWarning
        default: return Color.spTextSecondary
        }
    }
}
