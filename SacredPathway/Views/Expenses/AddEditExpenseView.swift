import SwiftUI

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

    @State private var category: String = "fuel"
    @State private var amount: String = ""
    @State private var vendorName: String = ""
    @State private var description: String = ""
    @State private var receiptDate: Date = Date()
    @State private var gallons: String = ""
    @State private var pricePerGallon: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

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
                        // Category picker
                        categorySection

                        // Amount
                        amountSection

                        // Fuel-specific fields
                        if category == "fuel" {
                            fuelSection
                        }

                        // Details
                        detailsSection

                        // Error
                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Color.spDanger)
                                .padding(.horizontal)
                        }

                        // Save button
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
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.spGold)
                }
            }
            .onAppear { loadExistingData() }
        }
    }

    // MARK: - Sections

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Category", icon: "tag.fill")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(categories, id: \.0) { cat, icon in
                        Button {
                            withAnimation { category = cat }
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
            .onChange(of: gallons) { _, _ in autoCalcFuelTotal() }
            .onChange(of: pricePerGallon) { _, _ in autoCalcFuelTotal() }
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
        if let gal = Double(gallons), let ppg = Double(pricePerGallon), gal > 0, ppg > 0 {
            amount = String(format: "%.2f", gal * ppg)
        }
    }

    private func loadExistingData() {
        guard let e = mode.expense else { return }
        category = e.category
        amount = String(format: "%.2f", e.amount)
        vendorName = e.vendorName ?? ""
        description = e.description ?? ""
        receiptDate = e.receiptDate ?? Date()
        if let g = e.gallons { gallons = String(format: "%.1f", g) }
        if let p = e.pricePerGallon { pricePerGallon = String(format: "%.3f", p) }
    }

    private func saveExpense() async {
        guard let amountVal = Double(amount), amountVal > 0 else {
            errorMessage = "Please enter a valid amount"
            return
        }
        guard let profileId = supabase.currentProfile?.id else {
            errorMessage = "Not signed in"
            return
        }

        isSaving = true
        errorMessage = nil

        var expense = Expense(
            id: mode.expense?.id,
            loadId: mode.expense?.loadId,
            profileId: profileId,
            category: category,
            amount: amountVal,
            vendorName: vendorName.isEmpty ? nil : vendorName,
            description: description.isEmpty ? nil : description,
            gallons: Double(gallons),
            pricePerGallon: Double(pricePerGallon),
            receiptDate: receiptDate,
            createdAt: mode.expense?.createdAt
        )

        do {
            if mode.isEditing {
                try await supabase.updateExpense(expense)
                onSave(expense)
            } else {
                let created = try await supabase.createExpense(expense)
                onSave(created)
            }
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }

        isSaving = false
    }
}
