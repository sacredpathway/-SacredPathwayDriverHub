import SwiftUI

struct AddIFTAEntryView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) var dismiss
    @State private var selectedDate: Date = Date()
    @State private var selectedStateCode: String = "TX"
    @State private var milesDriven: String = ""
    @State private var fuelGallons: String = ""
    @State private var fuelPricePerGallon: String = ""
    @State private var notes: String = ""
    @State private var selectedLoad: Load? = nil
    @State private var loads: [Load] = []
    @State private var logAsExpense: Bool = false
    @State private var isSaving = false
    @State private var errorMessage: String? = nil
    @State private var searchText: String = ""

    var filteredJurisdictions: [IFTAJurisdiction] {
        if searchText.isEmpty {
            return iftaJurisdictions
        }
        return iftaJurisdictions.filter { j in
            j.code.lowercased().contains(searchText.lowercased()) ||
            j.name.lowercased().contains(searchText.lowercased())
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Date picker
                        VStack(alignment: .leading, spacing: 10) {
                            sectionHeader("Entry Date", icon: "calendar")
                            DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextPrimary)
                                .padding(12)
                                .background(Color.spCardBg)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .padding(.horizontal)
                        }

                        // State picker
                        VStack(alignment: .leading, spacing: 10) {
                            sectionHeader("State/Province", icon: "map.fill")
                            Menu {
                                ScrollView {
                                    VStack(alignment: .leading) {
                                        TextField("Search", text: $searchText)
                                            .padding(8)
                                        ForEach(filteredJurisdictions) { j in
                                            Button(j.displayName) {
                                                selectedStateCode = j.code
                                                searchText = ""
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(selectedStateCode)
                                        .font(.subheadline)
                                        .foregroundStyle(Color.spTextPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.spCardBg)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .padding(.horizontal)
                        }

                        // Miles and gallons
                        VStack(alignment: .leading, spacing: 10) {
                            sectionHeader("Mileage & Fuel", icon: "fuelpump.fill")

                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Miles Driven")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                    TextField("0.0", text: $milesDriven)
                                        .keyboardType(.decimalPad)
                                        .font(.headline)
                                        .foregroundStyle(Color.spTextPrimary)
                                        .padding(10)
                                        .background(Color.spCardBg)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Gallons")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                    TextField("0.0", text: $fuelGallons)
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

                        // Fuel price (optional)
                        VStack(alignment: .leading, spacing: 10) {
                            sectionHeader("Fuel Price (Optional)", icon: "dollarsign.circle.fill")

                            TextField("Price per gallon", text: $fuelPricePerGallon)
                                .keyboardType(.decimalPad)
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextPrimary)
                                .padding(12)
                                .background(Color.spCardBg)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .padding(.horizontal)
                        }

                        // Link to load (optional)
                        VStack(alignment: .leading, spacing: 10) {
                            sectionHeader("Link to Load (Optional)", icon: "truck.box.fill")

                            NavigationLink(destination: LoadPickerView(selectedLoad: $selectedLoad)) {
                                HStack {
                                    if let load = selectedLoad {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(load.loadNumber ?? "Load")
                                                .font(.subheadline)
                                                .foregroundStyle(Color.spTextPrimary)
                                            if let origin = load.origin, let dest = load.destination {
                                                Text("\(origin) → \(dest)")
                                                    .font(.caption)
                                                    .foregroundStyle(Color.spTextSecondary)
                                            }
                                        }
                                    } else {
                                        Text("Select a load...")
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(Color.spTextSecondary)
                                }
                                .padding(12)
                                .background(Color.spCardBg)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .padding(.horizontal)
                        }

                        // Log as expense toggle
                        if !fuelGallons.isEmpty && !fuelPricePerGallon.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle(isOn: $logAsExpense) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "receipt.fill")
                                            .foregroundStyle(Color.spGold)
                                        Text("Also log as fuel expense")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Color.spTextPrimary)
                                    }
                                }
                                .tint(Color.spGold)
                                .padding(.horizontal)
                            }
                        }

                        // Notes
                        VStack(alignment: .leading, spacing: 10) {
                            sectionHeader("Notes", icon: "note.text")
                            TextEditor(text: $notes)
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextPrimary)
                                .scrollContentBackground(.hidden)
                                .background(Color.spCardBg)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .frame(minHeight: 80)
                                .padding(.horizontal)
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Color.spDanger)
                                .padding(.horizontal)
                        }

                        // Save button
                        Button {
                            Task { await saveEntry() }
                        } label: {
                            if isSaving {
                                ProgressView()
                                    .tint(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            } else {
                                Text("Add Entry")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            }
                        }
                        .background(Color.spGold)
                        .foregroundStyle(Color.spBlack)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .disabled(isSaving || milesDriven.isEmpty || fuelGallons.isEmpty)
                        .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Add IFTA Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.spGold)
                }
            }
            .task { await loadLoads() }
        }
    }

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

    private func saveEntry() async {
        guard let miles = Double(milesDriven), miles >= 0 else {
            errorMessage = "Please enter valid miles"
            return
        }

        guard let gallons = Double(fuelGallons), gallons >= 0 else {
            errorMessage = "Please enter valid gallons"
            return
        }

        guard let profileId = supabase.currentProfile?.id else {
            errorMessage = "Not signed in"
            return
        }

        isSaving = true
        errorMessage = nil

        do {
            // Compute total fuel cost if a price was entered. Using a closure
            // avoids the expression-if form which can't infer an Optional<Double>
            // when one branch returns `nil`.
            let totalFuelCost: Double? = {
                guard let price = Double(fuelPricePerGallon), price > 0 else { return nil }
                return gallons * price
            }()

            let entry = IFTAEntry(
                profileId: profileId,
                loadId: selectedLoad?.id,
                date: selectedDate,
                stateCode: selectedStateCode,
                milesDriven: miles,
                fuelGallons: gallons,
                fuelPricePerGallon: Double(fuelPricePerGallon),
                totalFuelCost: totalFuelCost,
                notes: notes.isEmpty ? nil : notes
            )

            _ = try await supabase.createIFTAEntry(entry)

            // Optionally create expense
            if logAsExpense, let cost = totalFuelCost, let profileId = supabase.currentProfile?.id {
                let expense = Expense(
                    loadId: selectedLoad?.id,
                    profileId: profileId,
                    category: "fuel",
                    amount: cost,
                    vendorName: "IFTA Fuel",
                    gallons: gallons,
                    pricePerGallon: Double(fuelPricePerGallon),
                    receiptDate: selectedDate
                )
                try await supabase.createExpense(expense)
            }

            dismiss()
        } catch {
            errorMessage = "Failed to save: \(String(describing: error))"
            #if DEBUG
            print("[AddIFTAEntryView] save failed: \(error)")
            #endif
        }

        isSaving = false
    }

    private func loadLoads() async {
        do {
            loads = try await supabase.fetchLoads()
        } catch {
            print("Error loading loads: \(error)")
        }
    }
}

struct LoadPickerView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var supabase: SupabaseService
    @Binding var selectedLoad: Load?
    @State private var loads: [Load] = []
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(Color.spGold)
            } else if loads.isEmpty {
                Text("No loads available")
                    .foregroundStyle(Color.spTextSecondary)
            } else {
                List {
                    ForEach(loads) { load in
                        Button(action: {
                            selectedLoad = load
                            dismiss()
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(load.loadNumber ?? "Load")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.spTextPrimary)
                                if let origin = load.origin, let dest = load.destination {
                                    Text("\(origin) → \(dest)")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                }
                            }
                        }
                        .listRowBackground(Color.spCardBg)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Select Load")
        .task { await loadLoads() }
    }

    private func loadLoads() async {
        do {
            loads = try await supabase.fetchLoads()
        } catch {
            print("Error: \(error)")
        }
        isLoading = false
    }
}

#Preview {
    AddIFTAEntryView().environmentObject(SupabaseService())
}
