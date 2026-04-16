import SwiftUI

struct SettlementGeneratorView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var drivers: [Driver] = []
    @State private var selectedDriver: Driver?
    @State private var periodStart = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var periodEnd = Date()
    @State private var loads: [Load] = []
    @State private var expenses: [Expense] = []
    @State private var calculation: SettlementCalculation?
    @State private var isCalculating = false
    @State private var pdfData: Data?
    @State private var showingShareSheet = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    // Period selection
                    periodSection
                    // Driver selection
                    driverSection
                    // Calculate button
                    calculateButton
                    // Results
                    if let calc = calculation {
                        settlementPreview(calc)
                        exportButton
                    }
                    if let error = errorMessage {
                        Text(error).font(.caption).foregroundStyle(Color.spDanger)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Generate Settlement")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await loadDrivers() }
        .sheet(isPresented: $showingShareSheet) {
            if let data = pdfData {
                ShareSheet(items: [data])
            }
        }
    }

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
            .padding().background(Color.spCardBg).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var driverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Driver", icon: "person.fill")
            if drivers.isEmpty {
                Text("No drivers added yet. Add drivers in the Drivers tab.")
                    .font(.caption).foregroundStyle(Color.spTextSecondary)
                    .padding().background(Color.spCardBg).clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(drivers) { driver in
                            Button {
                                selectedDriver = driver
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "person.circle.fill").font(.title2)
                                    Text(driver.name).font(.caption.weight(.semibold))
                                    if let pct = driver.payPercentage {
                                        Text("\(Int(pct))%").font(.caption2).foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                                .frame(width: 80, height: 70)
                                .background(selectedDriver?.id == driver.id ? Color.spGold.opacity(0.2) : Color.spCardBg)
                                .foregroundStyle(selectedDriver?.id == driver.id ? Color.spGold : Color.spTextPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selectedDriver?.id == driver.id ? Color.spGold : .clear, lineWidth: 1.5))
                            }
                        }
                    }
                }
            }
        }
    }

    private var calculateButton: some View {
        Button {
            Task { await calculateSettlement() }
        } label: {
            HStack {
                if isCalculating { ProgressView().tint(Color.spBlack) }
                else { Image(systemName: "function") }
                Text("Calculate Settlement")
            }
            .font(.headline)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Color.spGold).foregroundStyle(Color.spBlack)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isCalculating)
    }

    private func settlementPreview(_ calc: SettlementCalculation) -> some View {
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
            Task { await generatePDF() }
        } label: {
            Label("Export Paystub PDF", systemImage: "square.and.arrow.up.fill")
                .font(.headline)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color.spGreenAccent).foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func calcRow(_ label: String, _ value: String, bold: Bool = false, color: Color = .spTextPrimary) -> some View {
        HStack {
            Text(label).font(bold ? .subheadline.weight(.bold) : .caption).foregroundStyle(Color.spTextSecondary)
            Spacer()
            Text(value).font(bold ? .subheadline.weight(.bold) : .caption.weight(.medium)).foregroundStyle(color)
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(Color.spGold)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.spTextPrimary)
        }
    }

    // MARK: - Actions
    private func loadDrivers() async {
        do { drivers = try await supabase.fetchDrivers() } catch { print("Error: \(error)") }
    }

    private func calculateSettlement() async {
        isCalculating = true
        errorMessage = nil
        do {
            loads = try await supabase.fetchLoads()
            expenses = try await supabase.fetchAllExpenses()
            guard let profile = supabase.currentProfile else { errorMessage = "No profile"; isCalculating = false; return }
            let driver = selectedDriver ?? Driver(profileId: profile.id, name: "Owner-Operator")
            calculation = SettlementEngine.calculate(loads: loads, expenses: expenses, profile: profile, driver: driver)
        } catch {
            errorMessage = error.localizedDescription
        }
        isCalculating = false
    }

    private func generatePDF() async {
        guard let calc = calculation, let profile = supabase.currentProfile else { return }
        let branding = BrandingService.shared
        do {
            let data = try PaystubPDFService.generatePaystub(
                calculation: calc,
                loads: loads,
                expenses: expenses,
                companyName: profile.companyName ?? "Company",
                driverName: selectedDriver?.name ?? "Owner-Operator",
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

// MARK: - Share Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
