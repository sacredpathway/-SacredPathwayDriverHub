import SwiftUI

/// Shows the AI-extracted data for user review before saving as a Load
/// or Expense. The actual extraction happens server-side — this view
/// orchestrates the upload → enqueue → wait → display loop.
///
/// Pipeline:
///   1. `.task` → uploadOriginalFile → createDocument(status=pending)
///   2. callExtractionFunction (with 3-attempt retry/back-off in
///      DocumentExtractionService)
///   3. populateFields(from: result.structured) → user edits
///   4. saveDocument → patches `documents` row with edited fields,
///      creates the Load/Expense, links broker (CRM)
///
/// Fallbacks:
///   - "Try Again" rerun of the Edge Function (with `retry_count` bumped)
///   - "Enter Manually" jumps the user past extraction; row marked
///     `status = manual`, `is_manual = true`, `provider = 'manual'`
struct DocumentReviewView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) var dismiss

    let scannedImage: UIImage
    var originalFileData: Data? = nil
    var originalFileMime: String? = nil

    // MARK: - State

    @State private var extractedData: ExtractedData?
    @State private var rawExtractionText = ""
    @State private var documentRow: TruckDocument?
    @State private var isProcessing = true
    @State private var errorMessage: String?
    @State private var errorDetails: String?
    @State private var errorCode: String?
    @State private var showErrorDetails = false
    @State private var isSaving = false
    @State private var showSavedAlert = false
    @State private var brokerLinkResult: BrokerLinkResult?
    @State private var retryCount = 0
    @State private var showRawTextFallback = false

    // Editable fields
    @State private var documentType = ""
    @State private var brokerName = ""
    @State private var loadNumber = ""
    @State private var origin = ""
    @State private var destination = ""
    @State private var totalMiles = ""
    @State private var totalRevenue = ""
    @State private var lineHaulRate = ""
    @State private var fuelSurcharge = ""
    @State private var accessorialCharges = ""
    @State private var expenseAmount = ""
    @State private var expenseCategory = ""
    @State private var vendorName = ""
    @State private var gallons = ""
    @State private var pricePerGallon = ""
    @State private var notes = ""
    @State private var confidence = ""

    var isExpenseType: Bool {
        ["fuel_receipt", "lumper_fee", "toll", "repair"].contains(documentType)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()

                if isProcessing {
                    processingView
                } else if let error = errorMessage {
                    errorView(error)
                } else {
                    reviewForm
                }
            }
            .navigationTitle("Review Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.spBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.spGoldLight)
                }
            }
            .alert("Saved!", isPresented: $showSavedAlert) {
                Button("OK") { dismiss() }
            } message: {
                if let result = brokerLinkResult, let broker = result.broker {
                    switch result.action {
                    case .newBrokerCreated:
                        Text("Load created and new broker '\(broker.brokerName)' auto-detected and added to your CRM.")
                    case .existingBrokerUpdated:
                        Text("Load created and linked to existing broker '\(broker.brokerName)'. Stats updated.")
                    case .noBrokerDetected:
                        Text("Load created successfully.")
                    }
                } else {
                    Text(isExpenseType ? "Expense added successfully." : "Load created successfully.")
                }
            }
        }
        .task { await initialProcess() }
    }

    // MARK: - Processing View

    private var processingView: some View {
        VStack(spacing: 24) {
            Image(uiImage: scannedImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.5), radius: 10)

            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(Color.spGold)

                Text("AI is reading your document…")
                    .font(.headline)
                    .foregroundStyle(Color.spTextPrimary)

                Text("Uploading and extracting rates, dates, locations, and amounts")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    // MARK: - Error View

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.spWarning)

            Text("Couldn't Read Document")
                .font(.headline)
                .foregroundStyle(Color.spTextPrimary)

            Text(error)
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Collapsible technical details — never shown unless present.
            if let details = errorDetails, !details.isEmpty {
                VStack(spacing: 6) {
                    Button(action: { showErrorDetails.toggle() }) {
                        HStack(spacing: 4) {
                            Text(showErrorDetails ? "Hide details" : "Show details")
                            Image(systemName: showErrorDetails ? "chevron.up" : "chevron.down")
                        }
                        .font(.caption)
                        .foregroundStyle(Color.spGoldLight)
                    }
                    if showErrorDetails {
                        VStack(alignment: .leading, spacing: 4) {
                            if let code = errorCode {
                                Text("Code: \(code)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.spTextSecondary)
                            }
                            Text(details)
                                .font(.caption2)
                                .foregroundStyle(Color.spTextSecondary)
                                .multilineTextAlignment(.leading)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.spCardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 32)
                    }
                }
            }

            VStack(spacing: 12) {
                Button(action: { Task { await retryExtraction() } }) {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundStyle(Color.spBlack)
                        .background(Color.spGold)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button(action: { Task { await fallBackToManual() } }) {
                    Label("Enter Manually", systemImage: "square.and.pencil")
                        .font(.subheadline)
                        .foregroundStyle(Color.spGoldLight)
                }
            }
            .padding(.horizontal, 32)
        }
    }

    // MARK: - Review Form

    /// Shown above the form when the backend hit the salvage path — user
    /// gets the raw OCR text so they can copy the missing fields into the
    /// form below instead of being told the scan "failed."
    private var rawTextBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                Text("We couldn't auto-fill the fields — here's the raw text we extracted. Copy anything useful into the form below.")
                    .font(.caption)
            }
            .foregroundStyle(Color.spWarning)

            ScrollView {
                Text(rawExtractionText.isEmpty ? "(no text)" : rawExtractionText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.spTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            .padding(10)
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal)
    }

    private var reviewForm: some View {
        ScrollView {
            VStack(spacing: 20) {
                if showRawTextFallback {
                    rawTextBanner
                }
                Image(uiImage: scannedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)

                if !confidence.isEmpty {
                    HStack {
                        Image(systemName: confidenceIcon)
                        Text("AI Confidence: \(confidence.capitalized)")
                            .font(.caption)
                    }
                    .foregroundStyle(confidenceColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(confidenceColor.opacity(0.15))
                    .clipShape(Capsule())
                }

                docTypeSection

                if isExpenseType {
                    expenseFields
                } else {
                    loadFields
                }

                Button(action: saveDocument) {
                    if isSaving {
                        ProgressView()
                            .tint(Color.spBlack)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    } else {
                        Label(isExpenseType ? "Save Expense" : "Save Load",
                              systemImage: "checkmark.circle.fill")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .foregroundStyle(Color.spBlack)
                    }
                }
                .background(Color.spGold)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(isSaving)
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .padding(.top, 12)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Form Sections

    private var docTypeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Document Type")
            HStack(spacing: 8) {
                typeChip("Rate Con", value: "rate_confirmation")
                typeChip("Fuel", value: "fuel_receipt")
                typeChip("Lumper", value: "lumper_fee")
                typeChip("Toll", value: "toll")
                typeChip("Repair", value: "repair")
            }
            .padding(.horizontal)
        }
    }

    private func typeChip(_ label: String, value: String) -> some View {
        Button(action: { documentType = value }) {
            Text(label)
                .font(.caption)
                .fontWeight(documentType == value ? .bold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(documentType == value ? Color.spBlack : Color.spTextPrimary)
                .background(documentType == value ? Color.spGold : Color.spCardBgLight)
                .clipShape(Capsule())
        }
    }

    private var loadFields: some View {
        VStack(spacing: 16) {
            sectionHeader("Load Details")
            fieldRow("Broker", text: $brokerName)
            fieldRow("Load #", text: $loadNumber)
            fieldRow("Origin", text: $origin)
            fieldRow("Destination", text: $destination)
            fieldRow("Total Miles", text: $totalMiles, keyboard: .decimalPad)

            sectionHeader("Revenue")
            fieldRow("Line Haul", text: $lineHaulRate, keyboard: .decimalPad, prefix: "$")
            fieldRow("Fuel Surcharge", text: $fuelSurcharge, keyboard: .decimalPad, prefix: "$")
            fieldRow("Accessorials", text: $accessorialCharges, keyboard: .decimalPad, prefix: "$")
            fieldRow("Total Revenue", text: $totalRevenue, keyboard: .decimalPad, prefix: "$")

            sectionHeader("Notes")
            fieldRow("Notes", text: $notes)
        }
    }

    private var expenseFields: some View {
        VStack(spacing: 16) {
            sectionHeader("Expense Details")
            fieldRow("Vendor", text: $vendorName)
            fieldRow("Amount", text: $expenseAmount, keyboard: .decimalPad, prefix: "$")
            fieldRow("Category", text: $expenseCategory)

            if documentType == "fuel_receipt" {
                sectionHeader("Fuel Details")
                fieldRow("Gallons", text: $gallons, keyboard: .decimalPad)
                fieldRow("$/Gallon", text: $pricePerGallon, keyboard: .decimalPad, prefix: "$")
            }

            sectionHeader("Notes")
            fieldRow("Notes", text: $notes)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(Color.spGold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 4)
    }

    private func fieldRow(_ label: String, text: Binding<String>, keyboard: UIKeyboardType = .default, prefix: String? = nil) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
                .frame(width: 100, alignment: .leading)

            HStack(spacing: 4) {
                if let prefix = prefix {
                    Text(prefix)
                        .foregroundStyle(Color.spGold)
                        .font(.subheadline)
                }
                TextField(label, text: text)
                    .foregroundStyle(Color.spTextPrimary)
                    .keyboardType(keyboard)
            }
            .padding(10)
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal)
    }

    private var confidenceIcon: String {
        switch confidence.lowercased() {
        case "high": return "checkmark.seal.fill"
        case "medium": return "exclamationmark.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    private var confidenceColor: Color {
        switch confidence.lowercased() {
        case "high": return Color.spSuccess
        case "medium": return Color.spWarning
        default: return Color.spDanger
        }
    }

    // MARK: - Pipeline (upload → row → backend extract → patch row)

    private func initialProcess() async {
        isProcessing = true
        errorMessage = nil
        errorDetails = nil
        errorCode = nil

        guard let profileId = supabase.client.auth.currentUser?.id else {
            errorMessage = "Your session expired. Sign out and sign back in."
            errorCode = "AUTH_EXPIRED"
            errorDetails = "client: no currentUser.id"
            isProcessing = false
            return
        }

        #if DEBUG
        print("[DocumentReview] initialProcess start profileId=\(profileId)")
        #endif

        do {
            // 1) Upload original file (JPEG re-encode; PDFs are pre-rendered upstream)
            let upload = try await uploadOriginalFile(profileId: profileId)
            #if DEBUG
            print("[DocumentReview] upload ok path=\(upload.path) size=\(upload.size) mime=\(upload.mime)")
            #endif

            // 2) Insert pending documents row
            let pending = TruckDocument(
                id: nil,
                profileId: profileId,
                loadId: nil,
                documentType: nil,
                storagePath: upload.path,
                extractedData: nil,
                rawText: nil,
                confidence: nil,
                status: DocumentStatus.pending.rawValue,
                errorMessage: nil,
                isManual: false,
                provider: "openai",
                model: nil,
                fileMimeType: upload.mime,
                fileSize: upload.size,
                retryCount: 0,
                processed: false,
                createdAt: nil,
                updatedAt: nil
            )
            documentRow = try await supabase.createDocument(pending)
            #if DEBUG
            print("[DocumentReview] row created id=\(documentRow?.id?.uuidString ?? "nil")")
            #endif

            // 3) Trigger backend extraction
            await runExtraction()
        } catch {
            // The upload / createDocument path uses raw Supabase/Storage SDK
            // errors. Never surface their text to the user — map to a friendly
            // message and keep the underlying cause under "Show details".
            #if DEBUG
            print("[DocumentReview] initialProcess error: \(error)")
            #endif
            errorMessage = "Something went wrong while uploading. Tap Try Again, or enter it manually."
            errorCode = "UPLOAD_FAILED"
            errorDetails = clipDetail("upload: \(error.localizedDescription)")
            isProcessing = false
        }
    }

    private func runExtraction() async {
        guard let docId = documentRow?.id else {
            errorMessage = "Something went wrong while scanning. Tap Try Again, or enter it manually."
            errorCode = "INTERNAL"
            errorDetails = "client: missing document row id"
            isProcessing = false
            return
        }
        isProcessing = true
        errorMessage = nil
        errorDetails = nil
        errorCode = nil

        #if DEBUG
        print("[DocumentReview] runExtraction start docId=\(docId)")
        #endif

        do {
            let result = try await DocumentExtractionService.extract(
                documentId: docId,
                supabase: supabase
            )
            populateFields(from: result.structured)
            extractedData = result.structured
            rawExtractionText = result.rawText
            confidence = result.confidence
            if result.needsManualReview {
                // Not an error — the backend salvaged partial data. Show the
                // review form with whatever we got AND the raw OCR text, so
                // the user can copy missing fields by hand instead of being
                // told the scan failed.
                showRawTextFallback = true
                #if DEBUG
                print("[DocumentReview] extraction needs manual review (parse_stage=\(result.parseStage ?? "nil")) rawTextLen=\(result.rawText.count)")
                #endif
            } else {
                showRawTextFallback = false
                #if DEBUG
                print("[DocumentReview] extraction ok model=\(result.model) confidence=\(result.confidence)")
                #endif
            }
            isProcessing = false
        } catch let extractionError as ExtractionError {
            // All five ExtractionError cases have fixed user-facing copy;
            // technical detail goes under the "Show details" disclosure.
            #if DEBUG
            print("[DocumentReview] extraction error code=\(extractionError.code) details=\(extractionError.technicalDetails ?? "nil")")
            #endif
            errorMessage = extractionError.localizedDescription
            errorCode = extractionError.code
            errorDetails = extractionError.technicalDetails
            isProcessing = false
        } catch {
            #if DEBUG
            print("[DocumentReview] extraction unknown error: \(error)")
            #endif
            errorMessage = "Something went wrong while scanning. Tap Try Again, or enter it manually."
            errorCode = "UNKNOWN_SCAN_ERROR"
            errorDetails = clipDetail("client: \(error.localizedDescription)")
            isProcessing = false
        }
    }

    /// Try Again restarts the whole pipeline when we don't yet have a
    /// documents row (upload failed) and just re-runs extraction when we
    /// do. Either way, clears stale error state first so the user sees
    /// fresh progress.
    private func retryExtraction() async {
        retryCount += 1
        errorMessage = nil
        errorDetails = nil
        errorCode = nil
        showErrorDetails = false
        if documentRow?.id == nil {
            await initialProcess()
        } else {
            await runExtraction()
        }
    }

    private func clipDetail(_ s: String, max: Int = 200) -> String {
        guard s.count > max else { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        return String(s[..<idx])
    }

    /// User-initiated escape hatch — give them an empty form to fill in
    /// manually. Marks the document row as `manual` so analytics can
    /// distinguish AI-extracted vs. hand-keyed entries.
    private func fallBackToManual() async {
        documentType = "rate_confirmation"
        confidence = ""
        errorMessage = nil
        isProcessing = false

        if let id = documentRow?.id {
            try? await supabase.patchDocument(id: id, fields: [
                "status": AnyEncodable(DocumentStatus.manual.rawValue),
                "is_manual": AnyEncodable(true),
                "provider": AnyEncodable("manual")
            ])
        }
    }

    // MARK: - Upload helpers

    private struct UploadedFile {
        let path: String
        let mime: String
        let size: Int
    }

    /// Upload the canonical document image to Storage.
    ///
    /// We deliberately upload a JPEG render of `scannedImage` — never the
    /// raw PDF bytes — because OpenAI's Chat Completions vision endpoint
    /// only accepts image MIME types. The on-screen `scannedImage` is
    /// already the first-page render of any PDF the user picked, so the
    /// JPEG here is exactly what the AI will see.
    ///
    /// (If we ever want to preserve the raw PDF too, do it as a sibling
    ///  upload at `<path>.original.pdf` and add a column for the path.)
    private func uploadOriginalFile(profileId: UUID) async throws -> UploadedFile {
        // Re-encode at a quality that fits OpenAI's 20 MB ceiling. High-res
        // iPhone scans can push ~8 MB at q=0.85 — safe. Bump down only if
        // the first encode is over cap.
        var quality: CGFloat = 0.85
        guard var jpeg = scannedImage.jpegData(compressionQuality: quality) else {
            throw NSError(domain: "ScanUpload", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode the scanned image."
            ])
        }

        // Retry once at lower quality if absurdly large.
        let maxBytes = 20 * 1024 * 1024
        if jpeg.count > maxBytes {
            quality = 0.6
            if let smaller = scannedImage.jpegData(compressionQuality: quality),
               smaller.count <= maxBytes {
                jpeg = smaller
            }
        }

        // Validate before we spend a network round trip.
        guard jpeg.count >= 1024 else {
            throw NSError(domain: "ScanUpload", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The scanned image is too small or empty. Rescan and try again."
            ])
        }
        guard jpeg.count <= maxBytes else {
            throw NSError(domain: "ScanUpload", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "The scanned image is too large. Try rescanning at a lower resolution."
            ])
        }

        let mime = "image/jpeg"
        // Storage RLS compares the first folder to `auth.uid()::text`, which is
        // lowercase in Postgres. Swift's UUID.uuidString is UPPERCASE by default,
        // so we must lowercase BOTH segments or RLS rejects the insert with
        // "new row violates row-level security policy".
        let path = "\(profileId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"

        #if DEBUG
        print("[DocumentReview] uploading bytes=\(jpeg.count) quality=\(quality) path=\(path)")
        #endif

        try await supabase.uploadDocument(data: jpeg, path: path, contentType: mime)
        // `originalFileData`/`originalFileMime` are accepted from the picker
        // but intentionally unused right now — we always upload a JPEG so
        // OpenAI's vision endpoint accepts it.
        _ = originalFileData
        _ = originalFileMime
        return UploadedFile(path: path, mime: mime, size: jpeg.count)
    }

    // MARK: - Field plumbing

    private func populateFields(from data: ExtractedData) {
        documentType = data.documentType ?? "rate_confirmation"
        brokerName = data.brokerName ?? ""
        loadNumber = data.loadNumber ?? ""
        origin = data.origin ?? ""
        destination = data.destination ?? ""
        totalMiles = data.totalMiles.map { String(format: "%.0f", $0) } ?? ""
        totalRevenue = data.totalRevenue.map { String(format: "%.2f", $0) } ?? ""
        lineHaulRate = data.lineHaulRate.map { String(format: "%.2f", $0) } ?? ""
        fuelSurcharge = data.fuelSurcharge.map { String(format: "%.2f", $0) } ?? ""
        accessorialCharges = data.accessorialCharges.map { String(format: "%.2f", $0) } ?? ""
        expenseAmount = data.expenseAmount.map { String(format: "%.2f", $0) } ?? ""
        expenseCategory = data.expenseCategory ?? ""
        vendorName = data.vendorName ?? ""
        gallons = data.gallons.map { String(format: "%.1f", $0) } ?? ""
        pricePerGallon = data.pricePerGallon.map { String(format: "%.3f", $0) } ?? ""
        notes = data.notes ?? ""
        confidence = data.confidence ?? "medium"
    }

    /// Build the edited ExtractedData payload from current text fields.
    /// This is what we persist back to the documents row on Save so the
    /// audit trail reflects what the user approved (not just what the
    /// AI initially produced).
    private func currentEditedData() -> ExtractedData {
        ExtractedData(
            documentType: documentType.isEmpty ? nil : documentType,
            brokerName: brokerName.isEmpty ? nil : brokerName,
            brokerMcNumber: nil,
            loadNumber: loadNumber.isEmpty ? nil : loadNumber,
            pickupDate: extractedData?.pickupDate,
            deliveryDate: extractedData?.deliveryDate,
            origin: origin.isEmpty ? nil : origin,
            destination: destination.isEmpty ? nil : destination,
            totalMiles: Double(totalMiles),
            lineHaulRate: Double(lineHaulRate),
            fuelSurcharge: Double(fuelSurcharge),
            accessorialCharges: Double(accessorialCharges),
            totalRevenue: Double(totalRevenue),
            expenseAmount: Double(expenseAmount),
            expenseCategory: expenseCategory.isEmpty ? nil : expenseCategory,
            vendorName: vendorName.isEmpty ? nil : vendorName,
            gallons: Double(gallons),
            pricePerGallon: Double(pricePerGallon),
            notes: notes.isEmpty ? nil : notes,
            confidence: confidence.isEmpty ? "medium" : confidence
        )
    }

    // MARK: - Save

    private func saveDocument() {
        guard let profileId = supabase.client.auth.currentUser?.id else { return }
        isSaving = true

        Task {
            do {
                var createdLoadId: UUID? = nil

                if isExpenseType {
                    let expense = Expense(
                        profileId: profileId,
                        category: expenseCategory.isEmpty ? documentType : expenseCategory,
                        amount: Double(expenseAmount) ?? 0,
                        vendorName: vendorName.isEmpty ? nil : vendorName,
                        description: notes.isEmpty ? nil : notes,
                        gallons: Double(gallons),
                        pricePerGallon: Double(pricePerGallon)
                    )
                    _ = try await supabase.createExpense(expense)
                } else {
                    let load = Load(
                        profileId: profileId,
                        loadNumber: loadNumber.isEmpty ? nil : loadNumber,
                        brokerName: brokerName.isEmpty ? nil : brokerName,
                        origin: origin.isEmpty ? nil : origin,
                        destination: destination.isEmpty ? nil : destination,
                        totalMiles: Double(totalMiles),
                        lineHaulRate: Double(lineHaulRate),
                        fuelSurcharge: Double(fuelSurcharge),
                        accessorialCharges: Double(accessorialCharges),
                        totalRevenue: Double(totalRevenue),
                        status: "pending"
                    )
                    let createdLoad = try await supabase.createLoad(load)
                    createdLoadId = createdLoad.id

                    let dataForCRM = extractedData ?? currentEditedData()
                    brokerLinkResult = try? await BrokerIntelligenceService.shared.processExtractedData(
                        dataForCRM,
                        loadRevenue: Double(totalRevenue),
                        supabase: supabase
                    )
                }

                // Persist user edits + link to created load
                if let id = documentRow?.id {
                    var fields: [String: AnyEncodable] = [
                        "extracted_data": AnyEncodable(currentEditedData()),
                        "document_type": AnyEncodable(documentType),
                        "confidence": AnyEncodable(confidence.isEmpty ? "medium" : confidence),
                        "status": AnyEncodable(documentRow?.isManual == true
                                               ? DocumentStatus.manual.rawValue
                                               : DocumentStatus.processed.rawValue),
                        "processed": AnyEncodable(true)
                    ]
                    if let loadId = createdLoadId {
                        fields["load_id"] = AnyEncodable(loadId)
                    }
                    try? await supabase.patchDocument(id: id, fields: fields)
                }

                showSavedAlert = true
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}
