import SwiftUI
import UIKit
import AVFoundation

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
    let prefill: ExpenseFormPrefill?
    let onSave: (Expense) -> Void

    init(mode: Mode, prefill: ExpenseFormPrefill? = nil, onSave: @escaping (Expense) -> Void) {
        self.mode = mode
        self.prefill = prefill
        self.onSave = onSave
    }

    /// Dynamic-Type-aware size for the big amount field (A11y, Task 6).
    /// Was a fixed 32pt that ignored the user's text-size setting; now
    /// scales relative to .largeTitle from the same 32pt baseline.
    @ScaledMetric(relativeTo: .largeTitle) private var amountFontSize: CGFloat = 32

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

    // Receipt image state (Phase 1 · Task 3).
    // `pendingReceiptImage` = newly picked/scanned photo, written to
    // ReceiptImageStore ONLY at save time (cancel leaves no orphan file).
    // `existingReceiptFilename` = what the expense already has on disk.
    // `removeExistingReceipt` = user tapped Remove; old file is deleted only
    // AFTER the expense row saves successfully.
    @State private var pendingReceiptImage: UIImage?
    @State private var existingReceiptFilename: String?
    /// Decoded once in `loadFromExpense` — the body must never hit the disk
    /// per re-render (typing re-evaluates the body on every keystroke).
    @State private var existingReceiptImage: UIImage?
    @State private var removeExistingReceipt = false
    @State private var showReceiptSourceDialog = false
    @State private var showReceiptCamera = false
    @State private var showReceiptPhotoPicker = false
    @State private var showReceiptCameraDenied = false

    // Smart document import (2026-09-17). `smartAutoValues` remembers what the
    // importer put in each field so a later read never overwrites a value the
    // user typed; `smartConflicts` lists document values that differ.
    @State private var smartImport: SmartImport?
    @State private var smartAutoValues: [String: String] = [:]
    @State private var smartAutoConfidence: [String: ExtractionConfidence] = [:]
    @State private var smartConflicts: [MergeConflict] = []
    @State private var isReadingReceipt = false
    /// Fuel values exactly as the importer set them; the total is not
    /// recalculated from them unless the user changes one.
    @State private var smartFuelSnapshot: [String]?

    /// Increments on every save failure to drive the error-banner shake
    /// (Phase 2 · S6 micro-interaction; no-op under Reduce Motion).
    @State private var errorShakeTrigger = 0

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

                        if let smartImport {
                            SmartExtractionReviewCard(
                                result: smartImport.result,
                                selectableKinds: smartImport.selectableKinds,
                                familyMismatchMessage: smartImport.familyMismatchMessage,
                                conflicts: smartConflicts,
                                sourceData: smartImport.source.originalData,
                                sourceMimeType: smartImport.source.mimeType,
                                sourceImages: smartImport.source.images,
                                onChooseKind: { chooseSmartKind($0) },
                                onUseDocumentValue: { useDocumentValue($0) }
                            )
                            .padding(.horizontal)
                        } else if let expenseID = mode.expense?.id {
                            SmartImportedDocumentSection(recordType: .expense, recordID: expenseID)
                                .padding(.horizontal)
                        }

                        categorySection
                        amountSection

                        if category == "fuel" {
                            fuelSection
                            defSection
                        }

                        detailsSection

                        receiptSection

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
                                .modifier(ShakeEffect(trigger: errorShakeTrigger))
                        }

                        Button {
                            Task { await saveExpense() }
                        } label: {
                            if isSaving {
                                ProgressView()
                                    .tint(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .accessibilityLabel("Saving expense")
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
                    .font(.system(size: amountFontSize, weight: .bold, design: .rounded))
                    .keyboardType(.decimalPad)
                    .foregroundStyle(Color.spTextPrimary)
                    .accessibilityLabel("Expense amount in dollars")
            }
            .padding()
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            SmartFieldHint(confidence: smartHint("amount", amount))
                .padding(.horizontal)
        }
    }

    private var fuelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Fuel Details", icon: "fuelpump.fill")
            SmartFieldHint(confidence: [smartHint("gallons", gallons), smartHint("pricePerGallon", pricePerGallon)].compactMap { $0 }.min())
                .padding(.horizontal)

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

                SmartFieldHint(confidence: smartHint("vendorName", vendorName))

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
                SmartFieldHint(confidence: smartHint("receiptDate", SimpleDate(date: receiptDate).iso))
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Receipt section (Phase 1 · Task 3)

    /// The receipt shown in the form right now: a newly picked image wins,
    /// otherwise the stored file's cached decode (unless the user removed it).
    private var displayedReceiptImage: UIImage? {
        if let pendingReceiptImage { return pendingReceiptImage }
        if removeExistingReceipt { return nil }
        return existingReceiptImage
    }

    /// True when the row claims a receipt but the file is gone from disk
    /// (e.g. restored from a v1 backup that didn't carry images).
    private var existingReceiptFileMissing: Bool {
        guard pendingReceiptImage == nil, !removeExistingReceipt,
              existingReceiptFilename != nil else { return false }
        return existingReceiptImage == nil
    }

    private var receiptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Receipt Photo", icon: "paperclip")

            VStack(spacing: 12) {
                if let image = displayedReceiptImage {
                    HStack(spacing: 12) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pendingReceiptImage != nil ? "New photo attached" : "Receipt attached")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.spTextPrimary)
                            Text(pendingReceiptImage != nil
                                 ? "Saves with this expense"
                                 : "Stored on this device")
                                .font(.caption2)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                        Spacer()
                        Button("Replace") { showReceiptSourceDialog = true }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.spGoldText)
                            .frame(minWidth: 44, minHeight: 44)   // A11y hit target
                            .accessibilityLabel("Replace receipt photo")
                        Button {
                            if pendingReceiptImage != nil {
                                pendingReceiptImage = nil
                            } else {
                                removeExistingReceipt = true
                            }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(Color.spDanger)
                                .frame(minWidth: 44, minHeight: 44)   // A11y hit target
                        }
                        .accessibilityLabel("Remove receipt photo")
                    }
                    .padding(12)
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    if let photo = pendingReceiptImage, smartImport == nil {
                        Button {
                            readAttachedReceipt(photo)
                        } label: {
                            HStack(spacing: 8) {
                                if isReadingReceipt {
                                    ProgressView().tint(Color.spGold)
                                } else {
                                    Image(systemName: "doc.text.viewfinder")
                                }
                                Text(isReadingReceipt ? "Reading receipt…" : "Fill empty fields from this photo")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                            }
                            .foregroundStyle(Color.spGold)
                            .padding(12)
                            .frame(minHeight: 44)
                            .background(Color.spCardBg)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(isReadingReceipt)
                        .accessibilityIdentifier("expense.readAttachedReceipt")
                    }
                } else {
                    if existingReceiptFileMissing {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.spWarning)
                            Text("The saved receipt photo is missing from this device (it may predate image backups). Attach a new one below.")
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.spWarning.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Button {
                        showReceiptSourceDialog = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "camera.fill")
                            Text("Attach Receipt Photo")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("optional")
                                .font(.caption2)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                        .foregroundStyle(Color.spGold)
                        .padding(12)
                        .background(Color.spCardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("Attach receipt photo")
                }
            }
            .padding(.horizontal)
        }
        .confirmationDialog("Attach a receipt", isPresented: $showReceiptSourceDialog, titleVisibility: .visible) {
            Button("Camera") { requestReceiptCamera() }
            Button("Photo Library") { showReceiptPhotoPicker = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The photo is stored on this device with the expense and included in backups.")
        }
        .fullScreenCover(isPresented: $showReceiptCamera) {
            DocumentCameraView(
                onScan: { images in
                    if let first = images.first { attachReceipt(first) }
                },
                onCancel: { }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showReceiptPhotoPicker) {
            PhotoPickerView(onPick: { image in attachReceipt(image) }, onCancel: { })
        }
        .alert("Camera access needed", isPresented: $showReceiptCameraDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enable camera access in Settings to photograph receipts.")
        }
    }

    private func attachReceipt(_ image: UIImage) {
        pendingReceiptImage = image
        removeExistingReceipt = false
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
        // Values just filled from a document: keep the printed total (it may
        // include tax or other items). Recalculate once the user edits a value.
        if let snapshot = smartFuelSnapshot {
            if snapshot == [gallons, pricePerGallon, defGallons, defPricePerGallon], !amount.isEmpty { return }
            if snapshot != [gallons, pricePerGallon, defGallons, defPricePerGallon] { smartFuelSnapshot = nil }
        }
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
            if let prefill {
                ExpenseDraftStore.clear()
                applyPrefill(prefill)
                return
            }

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

    private func applyPrefill(_ p: ExpenseFormPrefill) {
        category = p.category
        categoryWasAutoSet = true
        vendorName = p.vendorName
        description = p.description
        receiptDate = p.receiptDate
        gallons = p.gallons
        pricePerGallon = p.pricePerGallon
        defGallons = p.defGallons
        defPricePerGallon = p.defPricePerGallon
        amount = p.amount
        // Smart Scan hands the captured photo through the prefill so the
        // OCR source image is persisted with the expense (Task 3).
        pendingReceiptImage = p.receiptImage
        if let imp = p.smartImport {
            smartImport = imp
            // Values exactly as they were put into the form (read from the
            // prefill, not from state that was just written).
            let prefilled: [String: String] = [
                "amount": p.amount, "vendorName": p.vendorName, "description": p.description,
                "category": p.category, "receiptDate": SimpleDate(date: p.receiptDate).iso,
                "gallons": p.gallons, "pricePerGallon": p.pricePerGallon,
                "defGallons": p.defGallons, "defPricePerGallon": p.defPricePerGallon
            ]
            var autoValues: [String: String] = [:]
            var autoConfidence: [String: ExtractionConfidence] = [:]
            for (key, suggestion) in p.smartSuggestions {
                guard let value = prefilled[key], !value.isEmpty else { continue }
                autoValues[key] = value
                autoConfidence[key] = suggestion.confidence
            }
            smartAutoValues = autoValues
            smartAutoConfidence = autoConfidence
            smartFuelSnapshot = [p.gallons, p.pricePerGallon, p.defGallons, p.defPricePerGallon]
        }
    }

    // MARK: - Smart import helpers

    private static let smartKeys = ["amount", "vendorName", "description", "category", "receiptDate",
                                    "gallons", "pricePerGallon", "defGallons", "defPricePerGallon"]

    private func formValue(_ key: String) -> String {
        switch key {
        case "amount": return amount
        case "vendorName": return vendorName
        case "description": return description
        case "category": return category
        case "receiptDate": return SimpleDate(date: receiptDate).iso
        case "gallons": return gallons
        case "pricePerGallon": return pricePerGallon
        case "defGallons": return defGallons
        case "defPricePerGallon": return defPricePerGallon
        default: return ""
        }
    }

    private func setFormValue(_ key: String, _ value: String) {
        switch key {
        case "amount": amount = value
        case "vendorName": vendorName = value
        case "description": description = value
        case "category":
            if SmartImportCoordinator.expenseCategories.contains(value) {
                category = value
                categoryWasAutoSet = true
            }
        case "receiptDate":
            if let d = SmartImportCoordinator.date(fromISO: value) { receiptDate = d }
        case "gallons": gallons = value
        case "pricePerGallon": pricePerGallon = value
        case "defGallons": defGallons = value
        case "defPricePerGallon": defPricePerGallon = value
        default: break
        }
    }

    /// Confidence to show under a field, only while it still holds the imported value.
    private func smartHint(_ key: String, _ current: String) -> ExtractionConfidence? {
        guard let auto = smartAutoValues[key], auto == current else { return nil }
        return smartAutoConfidence[key]
    }

    /// Current form state for the merge policy. A field counts as the user's
    /// own when it differs from what the importer put there.
    private func smartFormStates() -> [String: FormFieldState] {
        let today = SimpleDate(date: Date()).iso
        var states: [String: FormFieldState] = [:]
        for key in Self.smartKeys {
            var value = formValue(key)
            let auto = smartAutoValues[key]
            var edited = auto.map { $0 != value } ?? !value.isEmpty
            if key == "category" {
                edited = !categoryWasAutoSet
                // An automatic default category is not a real value yet.
                if !edited && auto == nil { value = "" }
            }
            if key == "receiptDate", auto == nil, value == today {
                // Untouched default date.
                value = ""
                edited = false
            }
            states[key] = FormFieldState(value: value, userEdited: edited,
                                         autoConfidence: (auto != nil && auto == value) ? smartAutoConfidence[key] : nil)
        }
        return states
    }

    private func applySmartSuggestions(_ suggestions: [String: FormSuggestion]) {
        let outcome = ExtractionMergePolicy.merge(suggestions: suggestions, into: smartFormStates())
        // Vendor before category so vendor-based auto-categorizing cannot undo the document's category.
        var autoValues = smartAutoValues
        var autoConfidence = smartAutoConfidence
        for key in Self.smartKeys {
            guard let s = outcome.applied[key] else { continue }
            setFormValue(key, s.value)
            autoValues[key] = s.value
            autoConfidence[key] = s.confidence
        }
        smartAutoValues = autoValues
        smartAutoConfidence = autoConfidence
        smartConflicts = outcome.conflicts
        smartFuelSnapshot = ["gallons", "pricePerGallon", "defGallons", "defPricePerGallon"].map {
            outcome.applied[$0]?.value ?? formValue($0)
        }
    }

    private func existingExpenseProbes() -> [DuplicateProbe] {
        let expenses = AppMode.shared.isLocal ? LocalExpensesRepository.shared.expenses : []
        return SmartImportCoordinator.expenseProbes(expenses).filter { $0.recordID != mode.expense?.id?.uuidString }
    }

    private func chooseSmartKind(_ kind: SmartDocumentKind) {
        guard let current = smartImport else { return }
        let updated = SmartImportCoordinator.choose(kind, for: current, existing: existingExpenseProbes())
        smartImport = updated
        applySmartSuggestions(SmartImportCoordinator.expenseSuggestions(updated))
    }

    private func useDocumentValue(_ conflict: MergeConflict) {
        // Explicit user choice: replace their value with the document's.
        setFormValue(conflict.key, conflict.suggestedValue)
        smartAutoValues[conflict.key] = conflict.suggestedValue
        smartAutoConfidence[conflict.key] = conflict.confidence
        smartConflicts.removeAll { $0.key == conflict.key }
    }

    /// Reads an attached photo and fills only empty fields (typed values stay).
    private func readAttachedReceipt(_ photo: UIImage) {
        isReadingReceipt = true
        let existing = existingExpenseProbes()
        Task {
            let imp = await SmartImportCoordinator.importDocument(
                ImportedDocument(images: [photo], originalData: nil, mimeType: nil),
                family: .expense, existing: existing)
            smartImport = imp
            applySmartSuggestions(SmartImportCoordinator.expenseSuggestions(imp))
            isReadingReceipt = false
        }
    }

    private func persistSmartImport(for saved: Expense) {
        guard let imp = smartImport, mode.isEditing == false || saved.id != nil else { return }
        let edited = Self.smartKeys.filter { key in
            let value = formValue(key)
            if let auto = smartAutoValues[key] { return auto != value }
            return !value.isEmpty && key != "receiptDate" && key != "category"
        }
        let title = [saved.category.capitalized, saved.vendorName, SmartText.money(saved.amount)]
            .compactMap { $0 }.joined(separator: " · ")
        SmartImportCoordinator.persist(recordType: .expense, recordID: saved.id, imp: imp,
                                       appliedValues: smartAutoValues, userEditedKeys: edited, title: title)
    }

    private func loadFromExpense(_ e: Expense) {
        existingReceiptFilename = e.receiptImageFilename
        existingReceiptImage = ReceiptImageStore.shared.loadImage(filename: e.receiptImageFilename)
        removeExistingReceipt = false
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
        smartImport = nil
        smartAutoValues = [:]
        smartAutoConfidence = [:]
        smartConflicts = []
        smartFuelSnapshot = nil
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
            SPHaptics.error(); errorShakeTrigger += 1
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
                SPHaptics.error(); errorShakeTrigger += 1
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

        // ── Receipt image: write to disk BEFORE the row is persisted ──
        // The filename goes onto the row only after the file provably
        // exists; a failed image write aborts the whole save with a
        // visible error (never "pretend saved"). If the ROW save later
        // fails, the freshly written file is deleted so no orphan remains.
        var newReceiptFilename: String?
        if let image = pendingReceiptImage {
            do {
                newReceiptFilename = try ReceiptImageStore.shared.save(image)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "The receipt photo couldn't be saved to this device. The expense was NOT saved — try again."
                SPHaptics.error(); errorShakeTrigger += 1
                return
            }
        }

        /// The filename the saved row should carry, and the old file to
        /// delete (only after a successful row save).
        let previousFilename = mode.expense?.receiptImageFilename
        let finalReceiptFilename: String? = {
            if let newReceiptFilename { return newReceiptFilename }
            if removeExistingReceipt { return nil }
            return previousFilename
        }()
        /// Roll back the just-written image file when the row save fails.
        func discardNewReceiptFile() {
            if let newReceiptFilename {
                ReceiptImageStore.shared.delete(filename: newReceiptFilename)
            }
        }
        /// After a confirmed row save: drop the replaced/removed old file.
        func cleanUpReplacedReceiptFile() {
            if let previousFilename, previousFilename != finalReceiptFilename {
                ReceiptImageStore.shared.delete(filename: previousFilename)
            }
        }

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
            receiptImageFilename: finalReceiptFilename,
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
            cleanUpReplacedReceiptFile()
            persistSmartImport(for: saved)
            ExpenseDraftStore.clear()
            NotificationCenter.default.post(name: .expensesDidChange, object: nil)
            SPHaptics.success()
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

            // Row is confirmed in the cloud — now it's safe to drop a
            // replaced/removed old image file.
            cleanUpReplacedReceiptFile()
            persistSmartImport(for: saved)

            // Best-effort cloud copy: push the receipt into the Document
            // Vault so cloud users can see it off-device. The AUTHORITATIVE
            // copy is the on-device file + backups; a vault failure must
            // not block the save (documented in RECEIPT_PERSISTENCE.md).
            if let newReceiptFilename,
               let data = ReceiptImageStore.shared.loadData(filename: newReceiptFilename) {
                let vendorLabel = expense.vendorName ?? expense.category.capitalized
                let f = DateFormatter(); f.dateFormat = "MM/dd/yyyy"
                let title = "Receipt — \(vendorLabel) — \(f.string(from: expense.receiptDate ?? Date()))"
                let docType = expense.category == "lumper" ? "lumper_fee" : "fuel_receipt"
                Task {
                    do {
                        _ = try await supabase.saveReceiptImageRecord(
                            jpegData: data,
                            documentType: docType,
                            title: title,
                            loadId: expense.loadId
                        )
                    } catch {
                        #if DEBUG
                        print("[AddEditExpenseView] vault copy failed (local copy is safe): \(error)")
                        #endif
                    }
                }
            }

            // Success only path:
            //   1. Clear the local draft (we now have a real DB row)
            //   2. Notify parent so the list updates
            //   3. THEN dismiss — never before
            ExpenseDraftStore.clear()
            SPHaptics.success()
            onSave(saved)
            isSaving = false
            dismiss()
        } catch {
            // Row save failed → remove the image file written for this
            // attempt so no orphan is left, keep the picked photo in the
            // form so the user can retry without re-shooting it.
            discardNewReceiptFile()
            // Stay on screen with the form values intact; surface a
            // human-readable error (and the underlying detail in DEBUG).
            isSaving = false
            errorMessage = friendlyExpenseError(error)
            SPHaptics.error(); errorShakeTrigger += 1
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
