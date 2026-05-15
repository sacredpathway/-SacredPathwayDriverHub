import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// =============================================================================
// MARK: - SettlementSheetView
// -----------------------------------------------------------------------------
// Carrier-style "Settlement Sheet / Paystub" generator. Output is a multi-page
// black-and-white PDF that mirrors the layout owner-operators are used to
// receiving from major carriers — ideal for accounting, financing, and
// proof-of-income.
//
// Flow:
//   1. Auto-fill carrier + owner info from the user's Profile
//   2. Pick weekly date range (defaults to last 7 days)
//   3. Pull saved Loads in the period; user can edit/add/remove trips and
//      enter trip-line breakdowns (revenue pay, taxes, fuel, deductions)
//   4. Add adjustments, repairs, recap balances, YTD summary lines
//   5. Preview the PDF in-app
//   6. Export → Share → Save to Files
// =============================================================================

struct SettlementSheetView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var subscriptions = SubscriptionService.shared

    // MARK: - Header / metadata

    @State private var carrierName: String = "Sacred Pathway"
    @State private var carrierAddressLine1: String = ""
    @State private var carrierAddressLine2: String = ""
    @State private var carrierPhone: String = ""

    @State private var settlementNumber: String = ""
    @State private var settlementDate: Date = Date()
    @State private var periodStart: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var periodEnd: Date = Date()
    @State private var paymentMethod: String = "Direct Deposit"
    @State private var checkNumber: String = ""

    // Owner / tractor
    @State private var ownerNumber: String = ""
    @State private var ownerName: String = ""
    @State private var ownerMailingLine1: String = ""
    @State private var ownerMailingLine2: String = ""
    @State private var ownerMailingLine3: String = ""
    @State private var tractorNumber: String = ""

    // Trips
    @State private var trips: [SheetTripDraft] = []

    // Adjustments / Repairs
    @State private var adjustments: [SheetAdjustmentDraft] = []
    @State private var repairs: [SheetRepairDraft] = []

    // Tractor Summary / Recap totals
    @State private var taxableWages: String = ""
    @State private var advances: String = ""
    @State private var adjExpense: String = ""

    // Recaps
    @State private var maintWeeklyAdd: String = ""
    @State private var maintYTDAdd: String = ""
    @State private var maintWeeklyDed: String = ""
    @State private var maintYTDDed: String = ""
    @State private var maintBalance: String = ""

    @State private var bondWeeklyDed: String = ""
    @State private var bondYTDDed: String = ""
    @State private var bondBalance: String = ""

    @State private var fuelSavingsWeekly: String = ""
    @State private var fuelSavingsYTD: String = ""

    // Tractor Summary lines (Current vs YTD list)
    @State private var summaryLines: [SheetSummaryLineDraft] = []

    // PDF state
    @State private var pdfData: Data?
    @State private var showingPreview = false
    @State private var showingShareSheet = false
    @State private var showingSaveToFiles = false
    @State private var showExportPaywall = false
    @State private var errorMessage: String?

    // Saved-loads picker
    @State private var savedLoadsForPicker: [Load] = []
    @State private var showSavedLoadPicker = false
    @State private var savedLoadsLoading = false

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerSection
                    carrierBlock
                    ownerBlock
                    periodBlock
                    tripsSection
                    adjustmentsSection
                    repairsSection
                    summarySection
                    recapsSection

                    actionButtons

                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(Color.spDanger)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Settlement Sheet")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await openSavedLoadPicker() }
                } label: {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .foregroundStyle(Color.spGold)
                }
            }
        }
        .onAppear { populateFromProfile() }
        .sheet(isPresented: $showingPreview) {
            if let data = pdfData {
                PDFPreviewSheet(data: data,
                                onShare: {
                                    showingPreview = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        showingShareSheet = true
                                    }
                                },
                                onSaveToFiles: {
                                    showingPreview = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        showingSaveToFiles = true
                                    }
                                })
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let data = pdfData {
                ShareSheet(items: [pdfFileURL(data: data)])
            }
        }
        .fileExporter(isPresented: $showingSaveToFiles,
                      document: SettlementPDFDocument(data: pdfData ?? Data()),
                      contentType: .pdf,
                      defaultFilename: defaultFilename) { _ in }
        .sheet(isPresented: $showSavedLoadPicker) {
            savedLoadPickerSheet
        }
        .sheet(isPresented: $showExportPaywall) { PaywallView() }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Carrier-Style Settlement Sheet")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.spGold)
            Text("Generate a professional, multi-page settlement PDF — like the one you'd get from a major carrier.")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
        }
    }

    private var carrierBlock: some View {
        cardSection(title: "Carrier Header", icon: "building.2.fill") {
            VStack(spacing: 8) {
                spField("Carrier Name", text: $carrierName)
                spField("Settlement #", text: $settlementNumber)
                spField("Address Line 1", text: $carrierAddressLine1)
                spField("Address Line 2 (City, ST ZIP)", text: $carrierAddressLine2)
                spField("Phone", text: $carrierPhone, keyboard: .phonePad)
            }
        }
    }

    private var ownerBlock: some View {
        cardSection(title: "Owner / Tractor", icon: "person.crop.square.filled.and.at.rectangle") {
            VStack(spacing: 8) {
                spField("Owner / Company Name", text: $ownerName)
                spField("Owner #", text: $ownerNumber)
                spField("Tractor #", text: $tractorNumber)
                Divider().background(Color.spTextSecondary.opacity(0.3))
                spField("Mailing Line 1", text: $ownerMailingLine1)
                spField("Mailing Line 2", text: $ownerMailingLine2)
                spField("Mailing City, ST ZIP", text: $ownerMailingLine3)
            }
        }
    }

    private var periodBlock: some View {
        cardSection(title: "Settlement Period", icon: "calendar") {
            VStack(spacing: 8) {
                HStack {
                    DatePicker("Settlement Date", selection: $settlementDate,
                               displayedComponents: .date)
                        .tint(Color.spGold)
                        .foregroundStyle(Color.spTextPrimary)
                }
                HStack(spacing: 12) {
                    DatePicker("Start", selection: $periodStart, displayedComponents: .date)
                        .tint(Color.spGold)
                        .foregroundStyle(Color.spTextPrimary)
                    DatePicker("End", selection: $periodEnd, displayedComponents: .date)
                        .tint(Color.spGold)
                        .foregroundStyle(Color.spTextPrimary)
                }
                spField("Payment Method", text: $paymentMethod)
                spField("Check #", text: $checkNumber)
            }
        }
    }

    // MARK: Trips

    private var tripsSection: some View {
        cardSection(title: "Trips (\(trips.count))", icon: "shippingbox.fill",
                    trailing: AnyView(
                        HStack(spacing: 10) {
                            Button {
                                Task { await openSavedLoadPicker() }
                            } label: {
                                Image(systemName: "tray.and.arrow.down.fill")
                                    .foregroundStyle(Color.spGold)
                            }
                            Button {
                                trips.append(SheetTripDraft())
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Color.spGold)
                            }
                        }
                    )) {
            if trips.isEmpty {
                Text("Tap + to add a trip, or import saved loads from the Loads tab.")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
            ForEach($trips) { $trip in
                tripCard(trip: $trip)
            }
        }
    }

    private func tripCard(trip: Binding<SheetTripDraft>) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text("Pro# / Load")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.spGold)
                Spacer()
                Button {
                    trips.removeAll { $0.id == trip.wrappedValue.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.spDanger)
                }
            }
            spField("Pro# (Load #)", text: trip.proNumber)
            DatePicker("Dispatch Date", selection: Binding(
                get: { trip.dispatchDate.wrappedValue ?? Date() },
                set: { trip.dispatchDate.wrappedValue = $0 }
            ), displayedComponents: .date)
                .tint(Color.spGold)
                .foregroundStyle(Color.spTextPrimary)
            spField("Tractor Origin (ST, City)", text: trip.tractorOrigin)
            HStack(spacing: 8) {
                spField("Origin", text: trip.origin)
                spField("Origin Miles", text: trip.originMiles, keyboard: .decimalPad)
            }
            HStack(spacing: 8) {
                spField("Destination", text: trip.destination)
                spField("Dest Miles", text: trip.destinationMiles, keyboard: .decimalPad)
            }
            Divider().background(Color.spTextSecondary.opacity(0.3))
            HStack(spacing: 8) {
                spField("Revenue Pay $", text: trip.revenuePay, keyboard: .decimalPad)
                spField("Pay %", text: trip.revenuePayPct, keyboard: .decimalPad)
            }
            HStack(spacing: 8) {
                spField("Fuel Surcharge $", text: trip.fuelSurcharge, keyboard: .decimalPad)
                spField("Fuel Purchases $", text: trip.fuelPurchases, keyboard: .decimalPad)
            }
            HStack(spacing: 8) {
                spField("Maint. Reserve $", text: trip.maintReserve, keyboard: .decimalPad)
                spField("Bond Deposit $", text: trip.bondDeposit, keyboard: .decimalPad)
            }
            spField("Other Deductions $", text: trip.otherDeductions, keyboard: .decimalPad)
        }
        .padding(10)
        .background(Color.spCardBgLight)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Adjustments

    private var adjustmentsSection: some View {
        cardSection(title: "Adjustments (\(adjustments.count))",
                    icon: "minus.slash.plus",
                    trailing: AnyView(
                        Button { adjustments.append(SheetAdjustmentDraft()) } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.spGold)
                        }
                    )) {
            ForEach($adjustments) { $adj in
                VStack(spacing: 6) {
                    HStack {
                        Text("Adjustment").font(.caption.weight(.bold)).foregroundStyle(Color.spGold)
                        Spacer()
                        Button {
                            adjustments.removeAll { $0.id == adj.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.spDanger)
                        }
                    }
                    spField("Description (e.g. Lease, Insurance)", text: $adj.description)
                    HStack(spacing: 8) {
                        spField("Trans #", text: $adj.transactionId)
                        spField("Driver ID", text: $adj.driverId)
                    }
                    HStack(spacing: 8) {
                        spField("Weekly $ (deduct = -)", text: $adj.weeklyInstall, keyboard: .numbersAndPunctuation)
                        spField("Balance $ (optional)", text: $adj.balance, keyboard: .numbersAndPunctuation)
                    }
                }
                .padding(10)
                .background(Color.spCardBgLight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: Repairs

    private var repairsSection: some View {
        cardSection(title: "Repairs / Maintenance (\(repairs.count))",
                    icon: "wrench.and.screwdriver.fill",
                    trailing: AnyView(
                        Button { repairs.append(SheetRepairDraft()) } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.spGold)
                        }
                    )) {
            ForEach($repairs) { $r in
                VStack(spacing: 6) {
                    HStack {
                        Text("Repair").font(.caption.weight(.bold)).foregroundStyle(Color.spGold)
                        Spacer()
                        Button {
                            repairs.removeAll { $0.id == r.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.spDanger)
                        }
                    }
                    spField("Description", text: $r.description)
                    HStack(spacing: 8) {
                        spField("RO #", text: $r.roNumber)
                        spField("Trans #", text: $r.transactionId)
                    }
                    HStack(spacing: 8) {
                        spField("Weekly $ (deduct = -)", text: $r.weeklyInstall, keyboard: .numbersAndPunctuation)
                        spField("Balance $ (optional)", text: $r.balance, keyboard: .numbersAndPunctuation)
                    }
                }
                .padding(10)
                .background(Color.spCardBgLight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: Summary / Recap

    private var summarySection: some View {
        cardSection(title: "Tractor Recap Totals", icon: "chart.bar.doc.horizontal") {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    spField("Taxable Wages $", text: $taxableWages, keyboard: .decimalPad)
                    spField("Advances $", text: $advances, keyboard: .decimalPad)
                }
                spField("Adj/Expense $ (negative = deduct)", text: $adjExpense,
                        keyboard: .numbersAndPunctuation)
            }
        }
    }

    private var recapsSection: some View {
        cardSection(title: "Reserve Recaps", icon: "tray.full.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Group {
                    Text("Maintenance Reserve")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.spGold)
                    HStack(spacing: 8) {
                        spField("Wkly ADD", text: $maintWeeklyAdd, keyboard: .decimalPad)
                        spField("YTD ADD", text: $maintYTDAdd, keyboard: .decimalPad)
                    }
                    HStack(spacing: 8) {
                        spField("Wkly DED (-)", text: $maintWeeklyDed, keyboard: .numbersAndPunctuation)
                        spField("YTD DED (-)", text: $maintYTDDed, keyboard: .numbersAndPunctuation)
                    }
                    spField("Reserve Bal", text: $maintBalance, keyboard: .numbersAndPunctuation)
                }
                Divider().background(Color.spTextSecondary.opacity(0.3))
                Group {
                    Text("Bond Balance")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.spGold)
                    HStack(spacing: 8) {
                        spField("Wkly DED (-)", text: $bondWeeklyDed, keyboard: .numbersAndPunctuation)
                        spField("YTD DED (-)", text: $bondYTDDed, keyboard: .numbersAndPunctuation)
                    }
                    spField("Bond Bal", text: $bondBalance, keyboard: .numbersAndPunctuation)
                }
                Divider().background(Color.spTextSecondary.opacity(0.3))
                Group {
                    Text("Fuel Savings")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.spGold)
                    HStack(spacing: 8) {
                        spField("Weekly", text: $fuelSavingsWeekly, keyboard: .decimalPad)
                        spField("YTD", text: $fuelSavingsYTD, keyboard: .decimalPad)
                    }
                }
            }
        }
    }

    // MARK: Action buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                generatePreview()
            } label: {
                Label("Preview Settlement", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.spCardBg)
                    .foregroundStyle(Color.spGold)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.spGold, lineWidth: 1.5)
                    )
            }

            if subscriptions.isEntitled(.pdfExport) {
                Button {
                    if pdfData == nil { buildPDF() }
                    showingShareSheet = (pdfData != nil)
                } label: {
                    Label("Export PDF", systemImage: "square.and.arrow.up.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.spGold)
                        .foregroundStyle(Color.spBlack)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Button {
                    if pdfData == nil { buildPDF() }
                    showingShareSheet = (pdfData != nil)
                } label: {
                    Label("Share PDF", systemImage: "paperplane.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.spGreenAccent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Button {
                    if pdfData == nil { buildPDF() }
                    showingSaveToFiles = (pdfData != nil)
                } label: {
                    Label("Save to Files", systemImage: "folder.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.spCardBg)
                        .foregroundStyle(Color.spGold)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.spGold, lineWidth: 1.5)
                        )
                }
            } else {
                Button { showExportPaywall = true } label: {
                    HStack {
                        Image(systemName: "lock.fill")
                        Text("Export PDF")
                        Spacer()
                        Text("PRO")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.spGold.opacity(0.2))
                            .clipShape(Capsule())
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.spCardBgLight)
                    .foregroundStyle(Color.spGold)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: Saved loads picker

    private var savedLoadPickerSheet: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                Group {
                    if savedLoadsLoading {
                        ProgressView().tint(Color.spGold)
                    } else if savedLoadsForPicker.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 40))
                                .foregroundStyle(Color.spGold.opacity(0.5))
                            Text("No saved loads in this period.")
                                .font(.headline)
                                .foregroundStyle(Color.spTextPrimary)
                        }
                    } else {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(savedLoadsForPicker) { load in
                                    Button {
                                        importLoad(load)
                                        showSavedLoadPicker = false
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(load.loadNumber.map { "Load #\($0)" } ?? "Load")
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(Color.spTextPrimary)
                                                if let o = load.origin, let d = load.destination {
                                                    Text("\(o) → \(d)")
                                                        .font(.caption2)
                                                        .foregroundStyle(Color.spTextSecondary)
                                                }
                                            }
                                            Spacer()
                                            if let r = load.totalRevenue {
                                                Text(r.asCurrency)
                                                    .font(.subheadline.weight(.bold))
                                                    .foregroundStyle(Color.spGold)
                                            }
                                        }
                                        .padding(12)
                                        .background(Color.spCardBg)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                }
                            }
                            .padding()
                        }
                    }
                }
            }
            .navigationTitle("Import Loads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSavedLoadPicker = false }
                        .foregroundStyle(Color.spGold)
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func cardSection<Content: View>(
        title: String,
        icon: String,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).foregroundStyle(Color.spGold)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Spacer()
                if let trailing = trailing {
                    trailing
                }
            }
            content()
                .padding()
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func spField(_ placeholder: String,
                         text: Binding<String>,
                         keyboard: UIKeyboardType = .default) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(keyboard)
            .font(.caption)
            .padding(8)
            .background(Color.spBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(Color.spTextPrimary)
    }

    private var defaultFilename: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        let date = f.string(from: settlementDate)
        let owner = ownerName.isEmpty ? "Settlement" : ownerName.replacingOccurrences(of: " ", with: "_")
        return "Settlement_\(owner)_\(date)"
    }

    // MARK: - Profile prefill

    private func populateFromProfile() {
        guard let profile = supabase.currentProfile else { return }
        if carrierName == "Sacred Pathway" {
            carrierName = profile.companyName ?? "Sacred Pathway"
        }
        if ownerName.isEmpty {
            ownerName = profile.companyName ?? ""
        }
    }

    // MARK: - Saved loads

    private func openSavedLoadPicker() async {
        savedLoadsLoading = true
        showSavedLoadPicker = true
        defer { savedLoadsLoading = false }
        do {
            let all = try await supabase.fetchLoads()
            savedLoadsForPicker = all.filter { load in
                let candidate = load.deliveryDate ?? load.pickupDate ?? load.createdAt ?? Date()
                return candidate >= startOfDay(periodStart) &&
                       candidate <= endOfDay(periodEnd)
            }
        } catch {
            savedLoadsForPicker = []
            errorMessage = "Couldn't load: \(error.localizedDescription)"
        }
    }

    private func importLoad(_ load: Load) {
        var draft = SheetTripDraft()
        draft.proNumber = load.loadNumber ?? ""
        draft.dispatchDate = load.pickupDate ?? load.deliveryDate
        draft.origin = load.origin ?? ""
        draft.destination = load.destination ?? ""
        if let m = load.totalMiles {
            draft.destinationMiles = String(format: "%.0f", m)
        }
        if let r = load.totalRevenue {
            draft.revenuePay = String(format: "%.2f", r)
        }
        if let fsc = load.fuelSurcharge {
            draft.fuelSurcharge = String(format: "%.2f", fsc)
        }
        trips.append(draft)
    }

    private func startOfDay(_ d: Date) -> Date {
        Calendar.current.startOfDay(for: d)
    }
    private func endOfDay(_ d: Date) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: DateComponents(day: 1, second: -1),
                        to: cal.startOfDay(for: d)) ?? d
    }

    // MARK: - PDF build

    private func generatePreview() {
        buildPDF()
        if pdfData != nil { showingPreview = true }
    }

    private func buildPDF() {
        let model = buildModel()
        let data = SettlementSheetPDFService.generate(model)
        pdfData = data
    }

    private func buildModel() -> SettlementSheetData {
        let header = ownerNameHeaderShort()
        let branding = BrandingService.shared
        let model = SettlementSheetData(
            carrierName: carrierName,
            carrierAddressLine1: carrierAddressLine1,
            carrierAddressLine2: carrierAddressLine2,
            carrierPhone: carrierPhone,
            settlementDate: settlementDate,
            periodStart: periodStart,
            periodEnd: periodEnd,
            leasedTo: carrierName,
            ownerNumber: ownerNumber,
            ownerNameHeader: header,
            ownerMailingName: ownerName,
            ownerMailingLine1: ownerMailingLine1,
            ownerMailingLine2: ownerMailingLine2,
            ownerMailingLine3: ownerMailingLine3,
            tractorNumber: tractorNumber,
            trips: trips.map { $0.toModel() },
            adjustments: adjustments.map { $0.toModel() },
            repairs: repairs.map { $0.toModel() },
            checkNumber: checkNumber,
            directDepositAmount: 0, // computed by model
            tractorSummary: summaryLines.map { $0.toModel() },
            taxableWages: parseDouble(taxableWages),
            advances: parseDouble(advances),
            adjExpense: parseSignedDouble(adjExpense),
            totalDue: 0,
            maintenanceRecap: SettlementReserveRecap(
                title: "Maintenance Reserve Recap",
                weeklyAdd: parseDouble(maintWeeklyAdd),
                ytdAdd: parseDouble(maintYTDAdd),
                weeklyDed: parseSignedDouble(maintWeeklyDed),
                ytdDed: parseSignedDouble(maintYTDDed),
                balance: parseSignedDouble(maintBalance),
                balanceLabel: "Reserve Bal"
            ),
            tireRecap: SettlementReserveRecap(
                title: "Tire/Lease Reserve Recap",
                balanceLabel: "Reserve Bal"
            ),
            bondRecap: SettlementReserveRecap(
                title: "Bond Balance Recap",
                weeklyDed: parseSignedDouble(bondWeeklyDed),
                ytdDed: parseSignedDouble(bondYTDDed),
                balance: parseSignedDouble(bondBalance),
                balanceLabel: "Bond Bal"
            ),
            fuelSavings: SettlementFuelSavings(
                weekly: parseDouble(fuelSavingsWeekly),
                ytd: parseDouble(fuelSavingsYTD)
            ),
            deliveryMethod: "",
            logo: branding.logoImage
        )
        return model
    }

    private func ownerNameHeaderShort() -> String {
        ownerName.uppercased()
    }

    private func parseDouble(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: "")) ?? 0
    }

    private func parseSignedDouble(_ s: String) -> Double {
        let cleaned = s.replacingOccurrences(of: ",", with: "")
                       .replacingOccurrences(of: "$", with: "")
                       .trimmingCharacters(in: .whitespaces)
        if cleaned.hasSuffix("-") {
            return -(Double(cleaned.dropLast()) ?? 0)
        }
        return Double(cleaned) ?? 0
    }

    private func pdfFileURL(data: Data) -> URL {
        let name = defaultFilename + ".pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: url)
        return url
    }
}

// =============================================================================
// MARK: - Local drafts (UI state) and conversion to model
// =============================================================================

struct SheetTripDraft: Identifiable {
    let id = UUID()
    var proNumber: String = ""
    var dispatchDate: Date? = nil
    var tractorOrigin: String = ""
    var origin: String = ""
    var originMiles: String = ""
    var destination: String = ""
    var destinationMiles: String = ""
    var revenuePay: String = ""
    var revenuePayPct: String = ""        // optional pay basis %
    var fuelSurcharge: String = ""
    var fuelPurchases: String = ""
    var maintReserve: String = ""
    var bondDeposit: String = ""
    var otherDeductions: String = ""

    func toModel() -> SettlementSheetTrip {
        var lines: [SettlementTripLine] = []
        let revenue = doubleFor(revenuePay)
        if revenue != 0 {
            let pctStr = revenuePayPct.isEmpty ? "" : "\(revenuePayPct) %"
            lines.append(SettlementTripLine(
                kind: .revenuePay,
                label: "Revenue Pay",
                basis: revenue > 0 ? "$ \(Int(revenue))" : "",
                rate: pctStr,
                amount: revenue
            ))
        }
        let fsc = doubleFor(fuelSurcharge)
        if fsc != 0 {
            lines.append(SettlementTripLine(
                kind: .fuelSurcharge,
                label: "Fuel Surcharge",
                basis: "1",
                rate: "1.00000",
                amount: fsc
            ))
        }
        let maint = doubleFor(maintReserve)
        if maint != 0 {
            lines.append(SettlementTripLine(
                kind: .deduction,
                label: "Maintenance Reserve",
                amount: -abs(maint)
            ))
        }
        let bond = doubleFor(bondDeposit)
        if bond != 0 {
            lines.append(SettlementTripLine(
                kind: .deduction,
                label: "BOND DEPOSIT",
                amount: -abs(bond)
            ))
        }
        let other = doubleFor(otherDeductions)
        if other != 0 {
            lines.append(SettlementTripLine(
                kind: .deduction,
                label: "Other Deductions",
                amount: -abs(other)
            ))
        }
        let fuel = doubleFor(fuelPurchases)
        if fuel != 0 {
            lines.append(SettlementTripLine(
                kind: .fuelPurchase,
                label: "Fuel Purchases",
                amount: -abs(fuel)
            ))
        }
        return SettlementSheetTrip(
            proNumber: proNumber,
            dispatchDate: dispatchDate,
            tractorOrigin: tractorOrigin,
            origin: origin,
            originMiles: doubleFor(originMiles),
            destination: destination,
            destinationMiles: doubleFor(destinationMiles),
            lines: lines
        )
    }

    private func doubleFor(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: "")) ?? 0
    }
}

struct SheetAdjustmentDraft: Identifiable {
    let id = UUID()
    var date: Date = Date()
    var transactionId: String = ""
    var driverId: String = ""
    var description: String = ""
    var weeklyInstall: String = ""
    var balance: String = ""

    func toModel() -> SettlementAdjustment {
        SettlementAdjustment(
            date: date,
            transactionId: transactionId,
            driverId: driverId,
            description: description,
            weeklyInstall: parseSigned(weeklyInstall),
            balance: parseSigned(balance),
            hasBalance: !balance.isEmpty
        )
    }
    private func parseSigned(_ s: String) -> Double {
        let c = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        if c.hasSuffix("-") { return -(Double(c.dropLast()) ?? 0) }
        return Double(c) ?? 0
    }
}

struct SheetRepairDraft: Identifiable {
    let id = UUID()
    var date: Date = Date()
    var transactionId: String = ""
    var roNumber: String = ""
    var description: String = ""
    var weeklyInstall: String = ""
    var balance: String = ""

    func toModel() -> SettlementRepair {
        SettlementRepair(
            date: date,
            transactionId: transactionId,
            roNumber: roNumber,
            description: description,
            weeklyInstall: parseSigned(weeklyInstall),
            balance: parseSigned(balance),
            hasBalance: !balance.isEmpty
        )
    }
    private func parseSigned(_ s: String) -> Double {
        let c = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        if c.hasSuffix("-") { return -(Double(c.dropLast()) ?? 0) }
        return Double(c) ?? 0
    }
}

struct SheetSummaryLineDraft: Identifiable {
    let id = UUID()
    var label: String = ""
    var current: String = ""
    var ytd: String = ""

    func toModel() -> SettlementSummaryLine {
        let cur = parseSigned(current)
        let yt  = parseSigned(ytd)
        return SettlementSummaryLine(
            label: label,
            current: abs(cur),
            ytd: abs(yt),
            currentNegative: cur < 0,
            ytdNegative: yt < 0
        )
    }
    private func parseSigned(_ s: String) -> Double {
        let c = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        if c.hasSuffix("-") { return -(Double(c.dropLast()) ?? 0) }
        return Double(c) ?? 0
    }
}

// =============================================================================
// MARK: - PDF preview sheet
// =============================================================================

struct PDFPreviewSheet: View {
    let data: Data
    var onShare: () -> Void = {}
    var onSaveToFiles: () -> Void = {}

    var body: some View {
        NavigationStack {
            PDFKitView(data: data)
                .ignoresSafeArea()
                .navigationTitle("Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                onShare()
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Button {
                                onSaveToFiles()
                            } label: {
                                Label("Save to Files", systemImage: "folder")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(Color.spGold)
                        }
                    }
                }
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemGroupedBackground
        view.maxScaleFactor = 6.0
        view.document = PDFDocument(data: data)
        return view
    }
    func updateUIView(_ uiView: PDFView, context: Context) {
        let same = uiView.document?.dataRepresentation() == data
        if !same, let doc = PDFDocument(data: data) {
            uiView.document = doc
            if let firstPage = doc.page(at: 0) {
                uiView.go(to: PDFDestination(page: firstPage, at: .zero))
            }
            // Re-set scale once layout settles so the page opens fit-to-screen
            // instead of zoomed in.
            DispatchQueue.main.async {
                let fit = uiView.scaleFactorForSizeToFit
                uiView.minScaleFactor = fit
                uiView.scaleFactor    = fit
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let fit = uiView.scaleFactorForSizeToFit
                uiView.minScaleFactor = fit
                uiView.scaleFactor    = fit
            }
        }
    }
}

// =============================================================================
// MARK: - File-exporter document wrapper
// =============================================================================

struct SettlementPDFDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.pdf]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        if let d = configuration.file.regularFileContents {
            self.data = d
        } else {
            self.data = Data()
        }
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
