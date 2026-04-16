import SwiftUI

// MARK: - Manual Line Items
struct ManualLoadItem: Identifiable {
    let id = UUID()
    var loadNumber: String = ""
    var broker: String = ""
    var origin: String = ""
    var destination: String = ""
    var miles: String = ""
    var revenue: String = ""
}

struct ManualExpenseItem: Identifiable {
    let id = UUID()
    var category: String = "Fuel"
    var description: String = ""
    var amount: String = ""
}

// MARK: - Manual Paystub View
struct ManualPaystubView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) var dismiss

    // Draft support
    var existingDraft: PaystubDraft?
    @State private var draftId: UUID?
    @State private var draftName: String = ""
    @State private var showingSaveAlert = false
    @State private var showingSavedConfirmation = false

    // Company & Driver
    @State private var companyName: String = ""
    @State private var driverName: String = ""
    @State private var periodStart = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var periodEnd = Date()

    // Manual Loads
    @State private var loadItems: [ManualLoadItem] = [ManualLoadItem()]

    // Manual Expenses
    @State private var expenseItems: [ManualExpenseItem] = []

    // Fee Percentages
    @State private var driverPayPct: String = "25"
    @State private var dispatcherFeePct: String = "0"
    @State private var factoringFeePct: String = "0"
    @State private var authorityFee: String = "0"
    @State private var maintenanceReserve: String = "0"

    // State
    @State private var calculation: SettlementCalculation?
    @State private var pdfData: Data?
    @State private var showingShareSheet = false
    @State private var errorMessage: String?

    let expenseCategories = ["Fuel", "Lumper", "Toll", "Repair", "Insurance", "Parking", "Scale", "DEF", "Tires", "Other"]

    init(existingDraft: PaystubDraft? = nil) {
        self.existingDraft = existingDraft
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Draft name bar
                        draftNameSection

                        companyDriverSection
                        periodSection
                        loadsSection
                        expensesSection
                        feesSection

                        // Action buttons
                        saveDraftButton
                        calculateSection

                        if let calc = calculation {
                            previewSection(calc)
                            exportButton
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Color.spDanger)
                                .padding()
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(existingDraft != nil ? "Edit Paystub" : "Create Paystub")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.spGold)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        saveDraft()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(Color.spGold)
                    }
                }
            }
            .onAppear { loadInitialData() }
            .sheet(isPresented: $showingShareSheet) {
                if let data = pdfData {
                    ShareSheet(items: [data])
                }
            }
            .alert("Draft Saved", isPresented: $showingSavedConfirmation) {
                Button("Keep Editing") {}
                Button("Close") { dismiss() }
            } message: {
                Text("Your paystub draft has been saved. You can find it in Payroll Drafts.")
            }
        }
    }

    // MARK: - Draft Name
    private var draftNameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Draft Name", icon: "tag.fill")
            HStack(spacing: 12) {
                TextField("e.g. Week of Apr 7 - John", text: $draftName)
                    .foregroundStyle(Color.spTextPrimary)
                    .font(.subheadline)
                if draftId != nil {
                    Text("DRAFT")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.spGold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.spGold.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding()
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Company & Driver
    private var companyDriverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Company & Driver", icon: "building.2.fill")

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "building.2")
                        .foregroundStyle(Color.spGold)
                        .frame(width: 24)
                    TextField("Company Name", text: $companyName)
                        .foregroundStyle(Color.spTextPrimary)
                }
                Divider().background(Color.spTextSecondary.opacity(0.3))
                HStack(spacing: 12) {
                    Image(systemName: "person.fill")
                        .foregroundStyle(Color.spGold)
                        .frame(width: 24)
                    TextField("Driver Name", text: $driverName)
                        .foregroundStyle(Color.spTextPrimary)
                }
            }
            .padding()
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Period
    private var periodSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Settlement Period", icon: "calendar")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("From").font(.caption).foregroundStyle(Color.spTextSecondary)
                    DatePicker("", selection: $periodStart, displayedComponents: .date)
                        .labelsHidden().tint(Color.spGold)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("To").font(.caption).foregroundStyle(Color.spTextSecondary)
                    DatePicker("", selection: $periodEnd, displayedComponents: .date)
                        .labelsHidden().tint(Color.spGold)
                }
            }
            .padding()
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Loads
    private var loadsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Loads", icon: "shippingbox.fill")
                Spacer()
                Button {
                    loadItems.append(ManualLoadItem())
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.spGold)
                        .font(.title3)
                }
            }

            ForEach($loadItems) { $item in
                loadCard(item: $item)
            }
        }
    }

    private func loadCard(item: Binding<ManualLoadItem>) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Load").font(.caption.weight(.semibold)).foregroundStyle(Color.spGold)
                Spacer()
                if loadItems.count > 1 {
                    Button {
                        loadItems.removeAll { $0.id == item.wrappedValue.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.spDanger)
                    }
                }
            }

            HStack(spacing: 8) {
                fieldBox("Load #", text: item.loadNumber)
                fieldBox("Broker", text: item.broker)
            }
            HStack(spacing: 8) {
                fieldBox("Origin", text: item.origin)
                fieldBox("Destination", text: item.destination)
            }
            HStack(spacing: 8) {
                fieldBox("Miles", text: item.miles, keyboard: .decimalPad)
                fieldBox("Revenue $", text: item.revenue, keyboard: .decimalPad)
            }
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Expenses
    private var expensesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Expenses", icon: "creditcard.fill")
                Spacer()
                Button {
                    expenseItems.append(ManualExpenseItem())
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.spGold)
                        .font(.title3)
                }
            }

            if expenseItems.isEmpty {
                Text("No expenses — tap + to add fuel, lumper, toll, etc.")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            ForEach($expenseItems) { $item in
                expenseCard(item: $item)
            }
        }
    }

    private func expenseCard(item: Binding<ManualExpenseItem>) -> some View {
        VStack(spacing: 10) {
            HStack {
                Picker("Category", selection: item.category) {
                    ForEach(expenseCategories, id: \.self) { cat in
                        Text(cat).tag(cat)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.spGold)

                Spacer()

                Button {
                    expenseItems.removeAll { $0.id == item.wrappedValue.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.spDanger)
                }
            }

            HStack(spacing: 8) {
                fieldBox("Description", text: item.description)
                fieldBox("Amount $", text: item.amount, keyboard: .decimalPad)
            }
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Fees
    private var feesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Fees & Deductions", icon: "percent")

            VStack(spacing: 12) {
                feeRow("Driver Pay %", value: $driverPayPct)
                Divider().background(Color.spTextSecondary.opacity(0.3))
                feeRow("Dispatcher Fee %", value: $dispatcherFeePct)
                Divider().background(Color.spTextSecondary.opacity(0.3))
                feeRow("Factoring Fee %", value: $factoringFeePct)
                Divider().background(Color.spTextSecondary.opacity(0.3))
                feeRow("Authority Fee $", value: $authorityFee)
                Divider().background(Color.spTextSecondary.opacity(0.3))
                feeRow("Maint. Reserve $", value: $maintenanceReserve)
            }
            .padding()
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func feeRow(_ label: String, value: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
            Spacer()
            TextField("0", text: value)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .foregroundStyle(Color.spGold)
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: - Save Draft Button
    private var saveDraftButton: some View {
        Button {
            saveDraft()
        } label: {
            HStack {
                Image(systemName: "square.and.arrow.down")
                Text(draftId != nil ? "Update Draft" : "Save as Draft")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.spCardBg)
            .foregroundStyle(Color.spGold)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spGold, lineWidth: 1.5))
        }
    }

    // MARK: - Calculate
    private var calculateSection: some View {
        Button {
            calculateManualSettlement()
        } label: {
            HStack {
                Image(systemName: "function")
                Text("Calculate Settlement")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.spGold)
            .foregroundStyle(Color.spBlack)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Preview
    private func previewSection(_ calc: SettlementCalculation) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("SETTLEMENT PREVIEW").font(.caption.weight(.heavy)).foregroundStyle(Color.spGold)
                Spacer()
            }
            .padding(12).background(Color.spCardBg)

            VStack(spacing: 6) {
                calcRow("Gross Revenue", calc.totalRevenue.asCurrency, bold: true)
                calcRow("Expenses", "-\(calc.totalExpenses.asCurrency)", color: .spDanger)
                calcRow("Gross Profit", calc.grossProfit.asCurrency)
                Divider().background(Color.spTextSecondary.opacity(0.3))
                calcRow("Driver Pay (\(Int(calc.driverPayPercentage))%)", calc.driverPayAmount.asCurrency)
                calcRow("Dispatcher Fee", "-\(calc.dispatcherFeeAmount.asCurrency)", color: .spDanger)
                calcRow("Factoring Fee", "-\(calc.factoringFeeAmount.asCurrency)", color: .spDanger)
                calcRow("Authority Fee", "-\(calc.authorityFee.asCurrency)", color: .spDanger)
                calcRow("Maint. Reserve", "-\(calc.maintenanceReserve.asCurrency)", color: .spDanger)
                Divider().background(Color.spGold)
                calcRow("NET PAY", calc.carrierNetPay.asCurrency, bold: true, color: calc.carrierNetPay >= 0 ? .spSuccess : .spDanger)
            }
            .padding(12)
        }
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var exportButton: some View {
        Button {
            generateManualPDF()
        } label: {
            Label("Export Paystub PDF", systemImage: "square.and.arrow.up.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.spGreenAccent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Helpers
    private func fieldBox(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(keyboard)
            .font(.caption)
            .padding(8)
            .background(Color.spBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(Color.spTextPrimary)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(Color.spGold)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.spTextPrimary)
        }
    }

    private func calcRow(_ label: String, _ value: String, bold: Bool = false, color: Color = .spTextPrimary) -> some View {
        HStack {
            Text(label).font(bold ? .subheadline.weight(.bold) : .caption).foregroundStyle(Color.spTextSecondary)
            Spacer()
            Text(value).font(bold ? .subheadline.weight(.bold) : .caption.weight(.medium)).foregroundStyle(color)
        }
    }

    // MARK: - Logic
    private func loadInitialData() {
        if let draft = existingDraft {
            // Restore from draft
            draftId = draft.id
            draftName = draft.name
            companyName = draft.companyName
            driverName = draft.driverName
            periodStart = draft.periodStart
            periodEnd = draft.periodEnd
            driverPayPct = draft.driverPayPct
            dispatcherFeePct = draft.dispatcherFeePct
            factoringFeePct = draft.factoringFeePct
            authorityFee = draft.authorityFee
            maintenanceReserve = draft.maintenanceReserve

            // Convert draft loads to ManualLoadItems
            loadItems = draft.loads.map { dl in
                var item = ManualLoadItem()
                item.loadNumber = dl.loadNumber
                item.broker = dl.broker
                item.origin = dl.origin
                item.destination = dl.destination
                item.miles = dl.miles
                item.revenue = dl.revenue
                return item
            }
            if loadItems.isEmpty { loadItems = [ManualLoadItem()] }

            // Convert draft expenses to ManualExpenseItems
            expenseItems = draft.expenses.map { de in
                var item = ManualExpenseItem()
                item.category = de.category
                item.description = de.description
                item.amount = de.amount
                return item
            }
        } else {
            // Load defaults from profile
            if let profile = supabase.currentProfile {
                companyName = profile.companyName ?? ""
                driverPayPct = String(format: "%.0f", profile.driverPayPercentage ?? 25)
                dispatcherFeePct = String(format: "%.0f", profile.dispatcherFeePercentage ?? 0)
                factoringFeePct = String(format: "%.0f", profile.factoringFeePercentage ?? 0)
                authorityFee = String(format: "%.2f", profile.authorityFee ?? 0)
                maintenanceReserve = String(format: "%.2f", profile.maintenanceReserve ?? 0)
            }
        }
    }

    private func saveDraft() {
        let id = draftId ?? UUID()
        draftId = id

        // Auto-generate name if empty
        let name: String
        if draftName.isEmpty {
            let df = DateFormatter()
            df.dateStyle = .short
            let driver = driverName.isEmpty ? "Untitled" : driverName
            name = "\(driver) — \(df.string(from: periodStart))"
        } else {
            name = draftName
        }
        draftName = name

        let draftLoads = loadItems.map { item in
            DraftLoadItem(
                loadNumber: item.loadNumber,
                broker: item.broker,
                origin: item.origin,
                destination: item.destination,
                miles: item.miles,
                revenue: item.revenue
            )
        }

        let draftExpenses = expenseItems.map { item in
            DraftExpenseItem(
                category: item.category,
                description: item.description,
                amount: item.amount
            )
        }

        let draft = PaystubDraft(
            id: id,
            name: name,
            companyName: companyName,
            driverName: driverName,
            periodStart: periodStart,
            periodEnd: periodEnd,
            loads: draftLoads,
            expenses: draftExpenses,
            driverPayPct: driverPayPct,
            dispatcherFeePct: dispatcherFeePct,
            factoringFeePct: factoringFeePct,
            authorityFee: authorityFee,
            maintenanceReserve: maintenanceReserve,
            createdAt: existingDraft?.createdAt ?? Date(),
            updatedAt: Date()
        )

        do {
            try DraftStorageService.shared.saveDraft(draft)
            showingSavedConfirmation = true
        } catch {
            errorMessage = "Failed to save draft: \(error.localizedDescription)"
        }
    }

    private func calculateManualSettlement() {
        errorMessage = nil

        let totalRevenue = loadItems.reduce(0.0) { sum, item in
            sum + (Double(item.revenue) ?? 0)
        }

        let totalExpenses = expenseItems.reduce(0.0) { sum, item in
            sum + (Double(item.amount) ?? 0)
        }

        guard totalRevenue > 0 else {
            errorMessage = "Enter at least one load with revenue."
            return
        }

        let grossProfit = totalRevenue - totalExpenses
        let driverPct = Double(driverPayPct) ?? 25
        let driverPayAmount = grossProfit * (driverPct / 100.0)
        let dispPct = Double(dispatcherFeePct) ?? 0
        let dispatcherFeeAmount = totalRevenue * (dispPct / 100.0)
        let factPct = Double(factoringFeePct) ?? 0
        let factoringFeeAmount = totalRevenue * (factPct / 100.0)
        let authFee = Double(authorityFee) ?? 0
        let maintReserve = Double(maintenanceReserve) ?? 0
        let carrierNetPay = grossProfit - driverPayAmount - dispatcherFeeAmount - factoringFeeAmount - authFee - maintReserve

        calculation = SettlementCalculation(
            totalRevenue: totalRevenue,
            totalExpenses: totalExpenses,
            grossProfit: grossProfit,
            driverPayPercentage: driverPct,
            driverPayAmount: driverPayAmount,
            dispatcherFeePercentage: dispPct,
            dispatcherFeeAmount: dispatcherFeeAmount,
            factoringFeePercentage: factPct,
            factoringFeeAmount: factoringFeeAmount,
            authorityFee: authFee,
            maintenanceReserve: maintReserve,
            carrierNetPay: carrierNetPay
        )
    }

    private func generateManualPDF() {
        guard let calc = calculation else { return }

        let profileId = supabase.currentProfile?.id ?? UUID()

        let loads: [Load] = loadItems.compactMap { item in
            guard let rev = Double(item.revenue), rev > 0 else { return nil }
            return Load(
                profileId: profileId,
                loadNumber: item.loadNumber.isEmpty ? nil : item.loadNumber,
                brokerName: item.broker.isEmpty ? nil : item.broker,
                origin: item.origin.isEmpty ? nil : item.origin,
                destination: item.destination.isEmpty ? nil : item.destination,
                totalMiles: Double(item.miles),
                totalRevenue: rev
            )
        }

        let expenses: [Expense] = expenseItems.compactMap { item in
            guard let amt = Double(item.amount), amt > 0 else { return nil }
            return Expense(
                profileId: profileId,
                category: item.category,
                amount: amt,
                description: item.description.isEmpty ? nil : item.description
            )
        }

        let branding = BrandingService.shared
        do {
            let data = try PaystubPDFService.generatePaystub(
                calculation: calc,
                loads: loads,
                expenses: expenses,
                companyName: companyName.isEmpty ? "Company" : companyName,
                driverName: driverName.isEmpty ? "Driver" : driverName,
                periodStart: periodStart,
                periodEnd: periodEnd,
                logo: branding.logoImage,
                primaryColor: UIColor(branding.primaryColor)
            )
            pdfData = data
            showingShareSheet = true
        } catch {
            errorMessage = "PDF error: \(error.localizedDescription)"
        }
    }
}
