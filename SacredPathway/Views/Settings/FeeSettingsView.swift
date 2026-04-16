import SwiftUI

// MARK: - Editable Fee Row Model
struct EditableFee: Identifiable {
    var id: String                // profileKey for built-in, UUID string for custom
    var name: String
    var icon: String
    var value: String
    var mode: FeeItem.FeeMode     // .percent or .dollar
    var isBuiltIn: Bool
    var profileKey: String?
}

// MARK: - Fee Settings View
struct FeeSettingsView: View {
    @EnvironmentObject var supabase: SupabaseService

    @State private var fees: [EditableFee] = []
    @State private var isSaving = false
    @State private var savedMessage = false
    @State private var errorMessage: String?

    // Rename
    @State private var renamingFee: EditableFee?
    @State private var renameText: String = ""
    @State private var showingRenameAlert = false

    // Add
    @State private var showingAddSheet = false
    @State private var newFeeName: String = ""
    @State private var newFeeValue: String = ""
    @State private var newFeeMode: FeeItem.FeeMode = .dollar
    @State private var newFeeIcon: String = "dollarsign.circle.fill"

    // Delete
    @State private var feeToDelete: EditableFee?
    @State private var showingDeleteAlert = false

    private let customFeeService = CustomFeeService.shared

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    infoCard
                    feesListSection
                    addFeeButton

                    if let error = errorMessage {
                        Text(error).font(.caption).foregroundStyle(Color.spDanger)
                    }

                    saveButton
                    exampleCalculation
                }
                .padding()
            }
        }
        .navigationTitle("Fee Settings")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { loadAllFees() }
        .alert("Rename Fee", isPresented: $showingRenameAlert) {
            TextField("Fee name", text: $renameText)
            Button("Save") { applyRename() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a new name for this fee.")
        }
        .alert("Delete Fee?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) { applyDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This custom fee will be permanently removed.")
        }
        .sheet(isPresented: $showingAddSheet) { addFeeSheet }
    }

    // MARK: - Info Card
    private var infoCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.spGold).font(.title3)
            Text("Tap the $ or % badge to switch between flat dollar and percentage. Long-press a fee name to rename it.")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Fees List
    private var feesListSection: some View {
        VStack(spacing: 0) {
            feeHeader("Fees & Deductions")

            ForEach($fees) { $fee in
                VStack(spacing: 0) {
                    feeRow(fee: $fee)
                    if fee.id != fees.last?.id {
                        Divider().background(Color.spTextSecondary.opacity(0.2)).padding(.horizontal)
                    }
                }
            }
        }
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func feeRow(fee: Binding<EditableFee>) -> some View {
        HStack(spacing: 10) {
            // Icon
            Image(systemName: fee.wrappedValue.icon)
                .foregroundStyle(Color.spGold)
                .frame(width: 26)

            // Name + context
            VStack(alignment: .leading, spacing: 2) {
                Text(fee.wrappedValue.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                    .onLongPressGesture {
                        renamingFee = fee.wrappedValue
                        renameText = fee.wrappedValue.name
                        showingRenameAlert = true
                    }

                Text(fee.wrappedValue.mode == .percent ? "of gross revenue" : "flat per settlement")
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
            }

            Spacer()

            // Value input
            HStack(spacing: 4) {
                if fee.wrappedValue.mode == .dollar {
                    Text("$").font(.subheadline.weight(.bold)).foregroundStyle(Color.spGold)
                }

                TextField("0", text: fee.value)
                    .keyboardType(.decimalPad)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.spTextPrimary)
                    .frame(width: 55)
                    .multilineTextAlignment(.trailing)

                if fee.wrappedValue.mode == .percent {
                    Text("%").font(.subheadline.weight(.bold)).foregroundStyle(Color.spGold)
                }
            }

            // Toggle button ($/%)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    fee.wrappedValue.mode = fee.wrappedValue.mode == .percent ? .dollar : .percent
                }
            } label: {
                Text(fee.wrappedValue.mode == .percent ? "%" : "$")
                    .font(.caption.weight(.black))
                    .frame(width: 30, height: 30)
                    .background(Color.spGold.opacity(0.2))
                    .foregroundStyle(Color.spGold)
                    .clipShape(Circle())
            }

            // Delete (custom only)
            if !fee.wrappedValue.isBuiltIn {
                Button {
                    feeToDelete = fee.wrappedValue
                    showingDeleteAlert = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.spDanger.opacity(0.6))
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Add Fee Button
    private var addFeeButton: some View {
        Button {
            newFeeName = ""
            newFeeValue = ""
            newFeeMode = .dollar
            newFeeIcon = "dollarsign.circle.fill"
            showingAddSheet = true
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                Text("Add Custom Fee")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.spCardBg)
            .foregroundStyle(Color.spGold)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spGold.opacity(0.4), lineWidth: 1))
        }
    }

    // MARK: - Add Fee Sheet
    private var addFeeSheet: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Fee Name")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.spTextSecondary)
                        TextField("e.g. Insurance, ELD, Trailer Lease", text: $newFeeName)
                            .padding()
                            .background(Color.spCardBg)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(Color.spTextPrimary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Amount")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.spTextSecondary)
                        HStack {
                            TextField("0", text: $newFeeValue)
                                .keyboardType(.decimalPad)
                                .padding()
                                .background(Color.spCardBg)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(Color.spTextPrimary)

                            Picker("", selection: $newFeeMode) {
                                Text("$").tag(FeeItem.FeeMode.dollar)
                                Text("%").tag(FeeItem.FeeMode.percent)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 100)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Icon")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.spTextSecondary)
                        iconPicker
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Add Fee")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddSheet = false }
                        .foregroundStyle(Color.spGold)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addCustomFee()
                        showingAddSheet = false
                    }
                    .foregroundStyle(Color.spGold)
                    .disabled(newFeeName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private let iconOptions = [
        "dollarsign.circle.fill", "creditcard.fill", "banknote.fill",
        "building.columns.fill", "wrench.and.screwdriver.fill", "shield.fill",
        "truck.box.fill", "fuelpump.fill", "antenna.radiowaves.left.and.right",
        "phone.fill", "doc.text.fill", "mappin.circle.fill",
        "heart.fill", "star.fill", "bolt.fill"
    ]

    private var iconPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
            ForEach(iconOptions, id: \.self) { icon in
                Button {
                    newFeeIcon = icon
                } label: {
                    Image(systemName: icon)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(newFeeIcon == icon ? Color.spGold.opacity(0.25) : Color.spCardBg)
                        .foregroundStyle(newFeeIcon == icon ? Color.spGold : Color.spTextSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(newFeeIcon == icon ? Color.spGold : .clear, lineWidth: 1.5)
                        )
                }
            }
        }
    }

    // MARK: - Save Button
    private var saveButton: some View {
        Button {
            Task { await saveAllFees() }
        } label: {
            HStack {
                if isSaving {
                    ProgressView().tint(Color.spBlack)
                } else if savedMessage {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Saved!")
                } else {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text("Save Fee Settings")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(savedMessage ? Color.spSuccess : Color.spGold)
            .foregroundStyle(Color.spBlack)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isSaving)
    }

    // MARK: - Example Calculation
    private var exampleCalculation: some View {
        let gross = 5000.0
        var totalDeductions = 0.0
        var driverPayAmt = 0.0

        var rows: [(String, Double, Bool)] = [("Gross Revenue", gross, false)]

        for fee in fees {
            let val = Double(fee.value) ?? 0
            let amount: Double
            if fee.mode == .percent {
                amount = gross * val / 100
            } else {
                amount = val
            }

            if fee.id == "driver_pay_percentage" {
                driverPayAmt = amount
                let label = fee.mode == .percent ? "\(fee.name) (\(fee.value)%)" : "\(fee.name) ($\(fee.value))"
                rows.append((label, amount, false))
            } else {
                totalDeductions += amount
                rows.append((fee.name, amount, true))
            }
        }

        let netPay = driverPayAmt - totalDeductions

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "function").foregroundStyle(Color.spGold)
                Text("Example: $5,000 Load").font(.caption.weight(.semibold)).foregroundStyle(Color.spGold)
            }

            VStack(spacing: 4) {
                ForEach(rows, id: \.0) { label, value, isDeduction in
                    HStack {
                        Text(label).font(.caption).foregroundStyle(Color.spTextSecondary)
                        Spacer()
                        Text(isDeduction ? "-\(abs(value).asCurrency)" : value.asCurrency)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isDeduction ? Color.spDanger : Color.spTextPrimary)
                    }
                }

                Divider().background(Color.spTextSecondary.opacity(0.3))

                HStack {
                    Text("Driver Net Pay").font(.caption.weight(.bold)).foregroundStyle(Color.spTextPrimary)
                    Spacer()
                    Text(netPay.asCurrency)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(netPay >= 0 ? Color.spSuccess : Color.spDanger)
                }
            }
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers
    private func feeHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Color.spGold)
            Spacer()
        }
        .padding(.horizontal).padding(.top, 14).padding(.bottom, 6)
    }

    // MARK: - Data Logic

    private func loadAllFees() {
        let profile = supabase.currentProfile
        let modeOverrides = customFeeService.loadModeOverrides()
        let nameOverrides = customFeeService.loadNameOverrides()

        let builtIns: [(key: String, name: String, icon: String, value: Double?, defaultMode: FeeItem.FeeMode)] = [
            ("driver_pay_percentage", "Driver Pay", "person.fill", profile?.driverPayPercentage, .percent),
            ("dispatcher_fee_percentage", "Dispatcher Fee", "headphones", profile?.dispatcherFeePercentage, .percent),
            ("factoring_fee_percentage", "Factoring Fee", "banknote.fill", profile?.factoringFeePercentage, .percent),
            ("authority_fee", "Authority Fee", "building.columns.fill", profile?.authorityFee, .dollar),
            ("maintenance_reserve", "Maintenance Reserve", "wrench.and.screwdriver.fill", profile?.maintenanceReserve, .dollar),
        ]

        var result: [EditableFee] = []
        for b in builtIns {
            let mode = modeOverrides[b.key] ?? b.defaultMode
            let name = nameOverrides[b.key] ?? b.name
            let defaultVal: Double
            if b.defaultMode == .percent {
                defaultVal = b.value ?? (b.key == "driver_pay_percentage" ? 25 : (b.key == "dispatcher_fee_percentage" ? 5 : 3))
            } else {
                defaultVal = b.value ?? (b.key == "authority_fee" ? 50 : 100)
            }
            result.append(EditableFee(
                id: b.key,
                name: name,
                icon: b.icon,
                value: String(format: defaultVal.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", defaultVal),
                mode: mode,
                isBuiltIn: true,
                profileKey: b.key
            ))
        }

        // Custom fees
        let customs = customFeeService.loadCustomFees()
        for c in customs {
            result.append(EditableFee(
                id: c.id.uuidString,
                name: c.name,
                icon: c.icon,
                value: String(format: c.value.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", c.value),
                mode: c.mode,
                isBuiltIn: false,
                profileKey: nil
            ))
        }

        fees = result
    }

    private func addCustomFee() {
        let fee = EditableFee(
            id: UUID().uuidString,
            name: newFeeName.trimmingCharacters(in: .whitespaces),
            icon: newFeeIcon,
            value: newFeeValue.isEmpty ? "0" : newFeeValue,
            mode: newFeeMode,
            isBuiltIn: false,
            profileKey: nil
        )
        fees.append(fee)
        persistCustomFees()
    }

    private func applyRename() {
        guard let target = renamingFee else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if let idx = fees.firstIndex(where: { $0.id == target.id }) {
            fees[idx].name = trimmed
        }

        if target.isBuiltIn, let key = target.profileKey {
            var overrides = customFeeService.loadNameOverrides()
            overrides[key] = trimmed
            customFeeService.saveNameOverrides(overrides)
        } else {
            persistCustomFees()
        }
    }

    private func applyDelete() {
        guard let target = feeToDelete, !target.isBuiltIn else { return }
        fees.removeAll { $0.id == target.id }
        persistCustomFees()
    }

    private func persistCustomFees() {
        let customs = fees.filter { !$0.isBuiltIn }.enumerated().map { idx, fee in
            FeeItem(
                id: UUID(uuidString: fee.id) ?? UUID(),
                name: fee.name,
                icon: fee.icon,
                subtitle: "",
                value: Double(fee.value) ?? 0,
                mode: fee.mode,
                isBuiltIn: false,
                profileKey: nil,
                sortOrder: idx
            )
        }
        customFeeService.saveCustomFees(customs)
    }

    private func saveAllFees() async {
        isSaving = true
        errorMessage = nil

        // Save mode overrides for built-in fees
        var modeOverrides: [String: FeeItem.FeeMode] = [:]
        for fee in fees where fee.isBuiltIn {
            if let key = fee.profileKey {
                modeOverrides[key] = fee.mode
            }
        }
        customFeeService.saveModeOverrides(modeOverrides)

        // Save built-in values to profile
        var updates: [String: AnyEncodable] = [:]
        for fee in fees where fee.isBuiltIn {
            if let key = fee.profileKey {
                updates[key] = AnyEncodable(Double(fee.value) ?? 0)
            }
        }

        do {
            try await supabase.updateProfile(updates)
            persistCustomFees()
            withAnimation { savedMessage = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { savedMessage = false }
            }
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }

        isSaving = false
    }
}
