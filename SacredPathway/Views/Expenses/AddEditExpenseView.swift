import SwiftUI

// =============================================================================
// MARK: - ExpenseDraft (local-only)
// -----------------------------------------------------------------------------
// Mirrors the AddEditExpenseView form state so unfinished entries survive a
// sheet dismiss / app backgrounding. Persisted in UserDefaults under a single
// key. NEVER synced to Supabase — only the explicit Save button creates a
// real `expenses` row.
// =============================================================================

private struct ExpenseDraft: Codable {
    var category: String
    var amount: String
    var vendorName: String
    var description: String
    var receiptDate: Date
    var gallons: String
    var pricePerGallon: String
    var defGallons: String
    var defPricePerGallon: String
    var updatedAt: Date

    static let empty = ExpenseDraft(
        category: "fuel",
        amount: "",
        vendorName: "",
        description: "",
        receiptDate: Date(),
        gallons: "",
        pricePerGallon: "",
        defGallons: "",
        defPricePerGallon: "",
        updatedAt: Date()
    )

    var hasContent: Bool {
        !amount.isEmpty
            || !vendorName.isEmpty
            || !description.isEmpty
            || !gallons.isEmpty
            || !pricePerGallon.isEmpty
            || !defGallons.isEmpty
            || !defPricePerGallon.isEmpty
    }
}

private enum ExpenseDraftStore {
    static let key = "sp.addExpense.draft.v1"

    static func load() -> ExpenseDraft? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ExpenseDraft.self, from: data)
    }

    static func save(_ draft: ExpenseDraft) {
        guard draft.hasContent else { clear(); return }
        if let data = try? JSONEncoder().encode(draft) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// =============================================================================
// MARK: - AddEditExpenseView
// =============================================================================

struct AddEditExpenseView: View {
    enum Mode {
        case add
        case edit(Expense)

        var isEditing: Bool {
            if case .edit = self { return true }
            return false
        }

        var expense: Expense? {
            if case .edit(let e) = self { return e }
            return nil
        }
    }

    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let onSave: (Expense) -> Void

    // Form state
    @State private var category: String = "fuel"
    /// True while category is in the "I picked this automatically" state.
    /// Flips to false the moment the user taps a category chip, so user
    /// intent always wins over auto-suggest.
    @State private var categoryWasAutoSet: Bool = true
    @State private var amount: String = ""
    @State private var vendorName: String = ""
    @State private var description: String = ""
    @State private var receiptDate: Date = Date()
    @State private var gallons: String = ""
    @State private var pricePerGallon: String = ""
    @State private var defGallons: String = ""
    @State private var defPricePerGallon: String = ""

    @State private var isSaving = false
    @State private var errorMessage: String?

    // Draft & dismiss-confirmation state
    @State private var didShowDraftRestoredToast = false
    @State private var showDraftRestoredToast = false
    @State private var showDiscardConfirm = false

    private let categories = [
        ("fuel", "fuelpump.fill"),
        ("lumper", "person.2.fill"),
        ("toll", "road.lanes"),
        ("repair", "wrench.and.screwdriver.fill"),
        ("insurance", "shield.checkered"),
        ("maintenance", "gearshape.2.fill"),
        ("other", "dollarsign.circle.fill")
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        if showDraftRestoredToast {
                            draftRestoredBanner
                        }

                        categorySection
                        amountSection

                        if category == "fuel" {
                            fuelSection
                            defSection
                        }

                        detailsSection

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Color.spDanger)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color.spDanger.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .padding(.horizontal)
                        }

                        Button {
                            Task { await saveExpense() }
                        } label: {
                            if isSaving {
                                ProgressView()
                                    .tint(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            } else {
                                Text(mode.isEditing ? "Update Expense" : "Add Expense")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            }
                        }
                        .background(Color.spGold)
                        .foregroundStyle(Color.spBlack)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .disabled(isSaving || amount.isEmpty)
                        .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle(mode.isEditing ? "Edit Expense" : "Add Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { handleCancelTap() }
                        .foregroundStyle(Color.spGold)
                }
            }
            .interactiveDismissDisabled(mode.isEditing == false && currentDraft.hasContent)
            .confirmationDialog(
                "You have unsaved changes",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("Keep Draft") {
                    persistCurrentDraft()
                    dismiss()
                }
                Button("Discard", role: .destructive) {
                    ExpenseDraftStore.clear()
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) { }
            } message: {
                Text("Save your draft so you can finish later, or discard it?")
            }
            .onAppear { onAppearSetup() }
            // Auto-save draft on every change (add mode only — edit mode
            // shouldn't overwrite an in-flight draft for a new expense).
            .onChange(of: category) { _, _ in autosaveIfAdding() }
            .onChange(of: amount) { _, _ in autosaveIfAdding() }
            .onChange(of: vendorName) { _, _ in autosaveIfAdding() }
            .onChange(of: description) { _, _ in autosaveIfAdding() }
            .onChange(of: receiptDate) { _, _ in autosaveIfAdding() }
            .onChange(of: gallons) { _, _ in
                autoCalcFuelTotal()
                autosaveIfAdding()
            }
            .onChange(of: pricePerGallon) { _, _ in
                autoCalcFuelTotal()
                autosaveIfAdding()
            }
            .onChange(of: defGallons) { _, _ in
                autoCalcFuelTotal()
                autosaveIfAdding()
            }
            .onChange(of: defPricePerGallon) { _, _ in
                autoCalcFuelTotal()
                autosaveIfAdding()
            }
        }
    }

    // MARK: - Sections

    private var draftRestoredBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.up.fill")
                .foregroundStyle(Color.spGold)
            Text("Draft restored")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
            Spacer()
            Button("Clear") {
                clearForm()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.spGold)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.spGold.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.spGold.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Category", icon: "tag.fill")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(categories, id: \.0) { cat, icon in
                        Button {
                            withAnimation { category = cat }
                            // User explicitly chose — stop auto-overriding.
                            categoryWasAutoSet = false
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: icon)
                                    .font(.title3)
                                Text(cat.capitalized)
                                    .font(.caption2.weight(.semibold))
                            }
                            .frame(width: 70, height: 60)
                            .background(category == cat ? Color.spGold.opacity(0.2) : Color.spCardBg)
                            .foregroundStyle(category == cat ? Color.spGold : Color.spTextSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(category == cat ? Color.spGold : Color.clear, lineWidth: 1.5)
                            )
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var amountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Amount", icon: "dollarsign.circle.fill")

            HStack {
                Text("$")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.spGold)
                TextField("0.00", text: $amount)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .keyboardType(.decimalPad)
                    .foregroundStyle(Color.spTextPrimary)
            }
            .padding()
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }

    private var fuelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Fuel Details", icon: "fuelpump.fill")

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gallons")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                    TextField("0.0", text: $gallons)
                        .keyboardType(.decimalPad)
                        .font(.headline)
                        .foregroundStyle(Color.spTextPrimary)
                        .padding(10)
                        .background(Color.spCardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Price/Gallon")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                    TextField("0.00", text: $pricePerGallon)
                        .keyboardType(.decimalPad)
                        .font(.headline)
                        .foregroundStyle(Color.spTextPrimary)
                        .padding(10)
                        .background(Color.spCardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal)
        }
    }

    /// Optional DEF (Diesel Exhaust Fluid) purchase made in the same fuel
    /// stop. Tracked separately so rate-per-mile math on diesel stays
    /// clean, but folded into the Amount auto-calc so the expense total
    /// reflects the real out-of-pocket. DEF columns are nullable on the
    /// server — empty fields are dropped from the request body.
    private var defSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "drop.fill")
                    .foregroundStyle(Color.spGreenAccent)
                Text("DEF (Diesel Exhaust Fluid)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text("— optional")
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DEF Gallons")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                    TextField("0.0", text: $defGallons)
                        .keyboardType(.decimalPad)
                        .font(.headline)
                        .foregroundStyle(Color.spTextPrimary)
                        .padding(10)
                        .background(Color.spCardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("DEF Price/Gal")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                    TextField("0.00", text: $defPricePerGallon)
                        .keyboardType(.decimalPad)
                        .font(.headline)
                        .foregroundStyle(Color.spTextPrimary)
                        .padding(10)
                        .background(Color.spCardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal)
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Details", icon: "doc.text.fill")

            VStack(spacing: 12) {
                TextField("Vendor / Location", text: $vendorName)
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextPrimary)
                    .padding(12)
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onChange(of: vendorName) { _, newValue in
                        // Auto-suggest a category from the vendor string,
                        // but only when the user hasn't manually picked
                        // something other than the default ("fuel"). This
                        // means a brand-new expense gets smart defaults
                        // while edits stay sticky.
                        let suggested = AutomationService.categorize(vendor: newValue, description: description)
                        if suggested != "other",
                           (category == "fuel" && categoryWasAutoSet) || category == suggested {
                            category = suggested
                            categoryWasAutoSet = true
                        }
                    }

                TextField("Description (optional)", text: $description)
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextPrimary)
                    .padding(12)
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                DatePicker("Receipt Date", selection: $receiptDate, displayedComponents: .date)
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextPrimary)
                    .padding(12)
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(Color.spGold)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
        }
        .padding(.horizontal)
    }

    private func autoCalcFuelTotal() {
        let dieselTotal: Double = {
            guard let gal = Double(gallons),
                  let ppg = Double(pricePerGallon),
                  gal > 0, ppg > 0 else { return 0 }
            return gal * ppg
        }()
        let defTotal: Double = {
            guard let gal = Double(defGallons),
                  let ppg = Double(defPricePerGallon),
                  gal > 0, ppg > 0 else { return 0 }
            return gal * ppg
        }()
        let total = dieselTotal + defTotal
        if total > 0 {
            amount = String(format: "%.2f", total)
        }
    }

    // MARK: - Mode setup + draft management

    private func onAppearSetup() {
        switch mode {
        case .edit(let e):
            loadFromExpense(e)
        case .add:
            // Restore unsaved draft from prior open, if any.
            if let draft = ExpenseDraftStore.load(), draft.hasContent {
                applyDraft(draft)
                if !didShowDraftRestoredToast {
                    didShowDraftRestoredToast = true
                    withAnimation { showDraftRestoredToast = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        withAnimation { showDraftRestoredToast = false }
                    }
                }
            }
        }
    }

    private func loadFromExpense(_ e: Expense) {
        category = e.category
        // Edits start with the user's prior category locked in. Vendor
        // changes won't auto-overwrite — they have to tap a chip to switch.
        categoryWasAutoSet = false
        amount = String(format: "%.2f", e.amount)
        vendorName = e.vendorName ?? ""
        description = e.description ?? ""
        receiptDate = e.receiptDate ?? Date()
        if let g = e.gallons { gallons = String(format: "%.1f", g) }
        if let p = e.pricePerGallon { pricePerGallon = String(format: "%.3f", p) }
        if let g = e.defGallons { defGallons = String(format: "%.1f", g) }
        if let p = e.defPricePerGallon { defPricePerGallon = String(format: "%.3f", p) }
    }

    private func applyDraft(_ d: ExpenseDraft) {
        category = d.category
        amount = d.amount
        vendorName = d.vendorName
        description = d.description
        receiptDate = d.receiptDate
        gallons = d.gallons
        pricePerGallon = d.pricePerGallon
        defGallons = d.defGallons
        defPricePerGallon = d.defPricePerGallon
    }

    private var currentDraft: ExpenseDraft {
        ExpenseDraft(
            category: category,
            amount: amount,
            vendorName: vendorName,
            description: description,
            receiptDate: receiptDate,
            gallons: gallons,
            pricePerGallon: pricePerGallon,
            defGallons: defGallons,
            defPricePerGallon: defPricePerGallon,
            updatedAt: Date()
        )
    }

    private func autosaveIfAdding() {
        guard mode.isEditing == false else { return }
        ExpenseDraftStore.save(currentDraft)
    }

    private func persistCurrentDraft() {
        ExpenseDraftStore.save(currentDraft)
    }

    private func clearForm() {
        category = "fuel"
        amount = ""
        vendorName = ""
        description = ""
        receiptDate = Date()
        gallons = ""
        pricePerGallon = ""
        defGallons = ""
        defPricePerGallon = ""
        ExpenseDraftStore.clear()
        withAnimation { showDraftRestoredToast = false }
    }

    private func handleCancelTap() {
        // Edit mode: a stray Cancel just dismisses, no draft semantics.
        guard mode.isEditing == false else {
            dismiss()
            return
        }
        if currentDraft.hasContent {
            showDiscardConfirm = true
        } else {
            ExpenseDraftStore.clear()
            dismiss()
        }
    }

    // MARK: - Save (final)

    private func saveExpense() async {
        // Reset prior error so the user sees this attempt's outcome cleanly.
        errorMessage = nil

        guard let amountVal = Double(amount), amountVal > 0 else {
            errorMessage = "Please enter a valid amount."
            return
        }

        // Resolve the profileId. In Free Local Mode there's no signed-in
        // user — use the per-install UUID as a stable placeholder so the
        // Codable model still has the required non-optional field.
        let profileId: UUID
        if AppMode.shared.isLocal {
            profileId = AppMode.shared.localInstallId
        } else {
            guard let cloudId = supabase.currentProfile?.id else {
                errorMessage = "You're not signed in. Please sign in and try again."
                return
            }
            profileId = cloudId
        }

        isSaving = true

        // Defensive: only fold DEF into the model when both gallons and
        // price are filled. Empty/zero stays nil so PostgREST never sees a
        // bad column or partial DEF data.
        let gallonsVal           = nonZeroDouble(gallons)
        let pricePerGallonVal    = nonZeroDouble(pricePerGallon)
        let defGallonsVal        = nonZeroDouble(defGallons)
        let defPricePerGallonVal = nonZeroDouble(defPricePerGallon)

        // Persist defTotal explicitly so analytics queries don't have to
        // recompute it. Rounded to cents to avoid floating-point drift —
        // 8.64 * 4.20 = 36.288 → 36.29.
        let defTotalVal: Double? = {
            guard let g = defGallonsVal, let p = defPricePerGallonVal else { return nil }
            return ((g * p) * 100).rounded() / 100
        }()

        let expense = Expense(
            id: mode.expense?.id,
            loadId: mode.expense?.loadId,
            profileId: profileId,
            category: category,
            amount: amountVal,
            vendorName: vendorName.isEmpty ? nil : vendorName,
            description: description.isEmpty ? nil : description,
            gallons: gallonsVal,
            pricePerGallon: pricePerGallonVal,
            defGallons: defGallonsVal,
            defPricePerGallon: defPricePerGallonVal,
            defTotal: defTotalVal,
            receiptDate: receiptDate,
            createdAt: mode.expense?.createdAt
        )

        // ── Free Local Mode ──
        // No network round-trip; LocalExpensesRepository can't throw.
        if AppMode.shared.isLocal {
            let saved: Expense
            if mode.isEditing {
                LocalExpensesRepository.shared.update(expense)
                saved = expense
            } else {
                saved = LocalExpensesRepository.shared.create(expense)
            }
            ExpenseDraftStore.clear()
            onSave(saved)
            isSaving = false
            dismiss()
            return
        }

        do {
            let saved: Expense
            if mode.isEditing {
                try await supabase.updateExpense(expense)
                saved = expense
            } else {
                saved = try await supabase.createExpense(expense)
            }

            // Success only path:
            //   1. Clear the local draft (we now have a real DB row)
            //   2. Notify parent so the list updates
            //   3. THEN dismiss — never before
            ExpenseDraftStore.clear()
            onSave(saved)
            isSaving = false
            dismiss()
        } catch {
            // Stay on screen with the form values intact; surface a
            // human-readable error (and the underlying detail in DEBUG).
            isSaving = false
            errorMessage = friendlyExpenseError(error)
            #if DEBUG
            print("[AddEditExpenseView] save failed: \(error)")
            #endif
        }
    }

    private func nonZeroDouble(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let v = Double(trimmed), v > 0 else { return nil }
        return v
    }

    private func friendlyExpenseError(_ error: Error) -> String {
        let raw = String(describing: error)
        let lower = raw.lowercased()

        if lower.contains("could not find") && lower.contains("column") {
            // Try to extract the exact column name PostgREST flagged so the
            // user (or developer in DEBUG console) sees it.
            let column = extractMissingColumnName(from: raw) ?? "an expense field"
            #if DEBUG
            print("[AddEditExpenseView] ⚠️ DB is missing column: \(column). " +
                  "Run the matching migration in supabase/migrations.")
            #endif
            return "Couldn't save: the database is missing the '\(column)' column. " +
                   "Run the latest Supabase migration and try again."
        }
        if lower.contains("row-level security") || lower.contains("violates row-level") {
            return "We couldn't save this expense to your account. Please sign out and back in, then try again."
        }
        if lower.contains("network") || lower.contains("offline") || lower.contains("connection") {
            return "Looks like you're offline. Your draft is saved — connect and try again."
        }
        return "We couldn't save this expense. Your draft is saved — please try again."
    }

    /// Pulls "def_total" out of a PostgREST error like:
    ///   "Could not find the 'def_total' column of 'expenses' in the schema cache"
    /// so the UI surface message names the exact failing field.
    private func extractMissingColumnName(from raw: String) -> String? {
        // Single-quoted form first.
        if let r = raw.range(of: #"'([a-z_][a-z0-9_]*)'"#, options: .regularExpression) {
            let m = String(raw[r])
            return m.replacingOccurrences(of: "'", with: "")
        }
        // Double-quoted fallback.
        if let r = raw.range(of: #""([a-z_][a-z0-9_]*)""#, options: .regularExpression) {
            let m = String(raw[r])
            return m.replacingOccurrences(of: "\"", with: "")
        }
        return nil
    }
}
