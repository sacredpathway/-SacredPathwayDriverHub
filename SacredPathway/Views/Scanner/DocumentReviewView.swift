import SwiftUI

/// Shows the AI-extracted data for user review before saving as a Load or Expense.
/// Users can edit any field before confirming.
struct DocumentReviewView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) var dismiss

    let scannedImage: UIImage
    @State private var extractedData: ExtractedData?
    @State private var isProcessing = true
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var showSavedAlert = false
    @State private var brokerLinkResult: BrokerLinkResult?

    // Editable fields — populated from AI extraction
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
            .toolbarColorScheme(.dark, for: .navigationBar)
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
        .task {
            await processImage()
        }
    }

    // MARK: - Processing View

    private var processingView: some View {
        VStack(spacing: 24) {
            // Show the scanned image as thumbnail
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

                Text("Claude AI is reading your document...")
                    .font(.headline)
                    .foregroundStyle(Color.spTextPrimary)

                Text("Extracting rates, dates, locations, and amounts")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
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

            VStack(spacing: 12) {
                Button(action: { Task { await processImage() } }) {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundStyle(Color.spBlack)
                        .background(Color.spGold)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button("Enter Manually") {
                    // Switch to manual mode with empty fields
                    documentType = "rate_confirmation"
                    errorMessage = nil
                    isProcessing = false
                }
                .font(.subheadline)
                .foregroundStyle(Color.spGoldLight)
            }
            .padding(.horizontal, 32)
        }
    }

    // MARK: - Review Form

    private var reviewForm: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Document image thumbnail
                Image(uiImage: scannedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)

                // Confidence badge
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

                // Document type picker
                docTypeSection

                if isExpenseType {
                    expenseFields
                } else {
                    loadFields
                }

                // Save button
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

            if !notes.isEmpty {
                sectionHeader("Notes")
                fieldRow("Notes", text: $notes)
            }
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

            if !notes.isEmpty {
                sectionHeader("Notes")
                fieldRow("Notes", text: $notes)
            }
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

    // MARK: - Actions

    private func processImage() async {
        isProcessing = true
        errorMessage = nil

        do {
            let data = try await ClaudeAIService.shared.extractData(from: scannedImage)
            populateFields(from: data)
            extractedData = data
            isProcessing = false
        } catch {
            errorMessage = error.localizedDescription
            isProcessing = false
        }
    }

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

    private func saveDocument() {
        guard let profileId = supabase.client.auth.currentUser?.id else { return }
        isSaving = true

        Task {
            do {
                if isExpenseType {
                    // Save as Expense
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
                    // Save as Load
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
                    _ = try await supabase.createLoad(load)

                    // Auto-detect and link broker + contact (AI CRM)
                    if let data = extractedData {
                        brokerLinkResult = try? await BrokerIntelligenceService.shared.processExtractedData(
                            data,
                            loadRevenue: Double(totalRevenue),
                            supabase: supabase
                        )
                    }
                }

                // Upload the scanned image
                if let imageData = scannedImage.jpegData(compressionQuality: 0.6) {
                    let path = "\(profileId)/\(UUID().uuidString).jpg"
                    _ = try? await supabase.uploadDocument(data: imageData, path: path)
                }

                showSavedAlert = true
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}
