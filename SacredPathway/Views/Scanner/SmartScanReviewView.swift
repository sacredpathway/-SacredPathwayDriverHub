import SwiftUI

/// Smart-Scan review screen.
///
/// Users land here AFTER `LocalDocumentParser.parse(image:)` returns. Every
/// field is editable. Save never fires automatically — the user must tap
/// "Save Load" to commit.
///
/// On save:
///  1. Insert a new `Load` row.
///  2. If broker name is non-empty AND not already in saved brokers, prompt
///     "Add this broker to contacts?". User confirms before any contact
///     row is written.
struct SmartScanReviewView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) var dismiss

    /// What the on-device parser pulled off the document.
    let parsed: ParsedLoadFields

    /// Original scan image — used to persist the document into the Document
    /// Vault when the user saves the load. Passed in from `ScanUploadView`
    /// alongside `parsed` so we have the exact bytes the user reviewed.
    var sourceImage: UIImage? = nil

    // MARK: Editable load fields
    @State private var loadNumber: String = ""
    @State private var brokerName: String = ""
    // brokerContactName temporarily removed 2026-05-17 to isolate the
    // upload crash. Will return once the root cause is fixed.
    @State private var brokerContactName: String = ""
    @State private var brokerPhone: String = ""
    @State private var brokerPhoneExtension: String = ""
    @State private var brokerEmail: String = ""
    @State private var brokerMcNumber: String = ""

    @State private var pickupCityState: String = ""
    @State private var pickupAddress: String = ""
    @State private var pickupDate: Date = Date()
    @State private var pickupDateSet: Bool = false
    @State private var pickupTime: String = ""

    @State private var deliveryCityState: String = ""
    @State private var deliveryAddress: String = ""
    @State private var deliveryDate: Date = Date()
    @State private var deliveryDateSet: Bool = false
    @State private var deliveryTime: String = ""

    @State private var rate: String = ""
    @State private var weight: String = ""
    @State private var commodity: String = ""
    @State private var poNumber: String = ""
    @State private var pickupNumber: String = ""
    @State private var referenceNumber: String = ""
    @State private var notes: String = ""

    @State private var shipperName: String = ""
    @State private var receiverName: String = ""

    // Pay breakdown (Part 2 — 2026-05). Captured for display only in v1;
    // settlement math still runs off the headline `rate`.
    @State private var fuelSurcharge: String = ""
    @State private var lumperFee: String = ""
    @State private var detentionRate: String = ""
    @State private var stopOffPay: String = ""

    // Equipment / shipment metadata (Part 2).
    @State private var trailerNumber: String = ""
    @State private var bolNumber: String = ""
    @State private var driverNotes: String = ""

    // Miles — Loaded (pickup→delivery), Deadhead (homeBase→pickup), Total.
    // `loadedMilesIsManual` flips on as soon as the user types in the field,
    // so we never overwrite their value with the auto-calc result.
    @State private var loadedMiles: String = ""
    @State private var deadheadMiles: String = ""
    @State private var homeBaseCityState: String = ""
    @State private var loadedMilesIsManual: Bool = false
    @State private var loadedMilesEstimated: Bool = false
    @State private var isCalculatingDistance: Bool = false
    @State private var distanceErrorMessage: String?

    // MARK: UI state
    @State private var savedBrokers: [Broker] = []
    @State private var matchedBroker: Broker?
    @State private var showRawOCR = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    @State private var showAddBrokerPrompt = false
    @State private var pendingLoadIdAfterSave: UUID?
    @State private var showSavedAlert = false

    // ─────────────────────────────────────────────────────────────────────
    // DEBUG-only safety guard.
    //
    // When this build is running on a simulator (DEBUG + targetEnvironment
    // == .simulator), the Save button is gated behind a confirmation
    // banner so test scans can't pollute the production Supabase account.
    // The user can flip the toggle to allow real saves OR keep it on for
    // a "dry-run" save that prints the payload to the console without
    // touching the network.
    //
    // In Release builds this flag is forced to `false` and the banner
    // never appears — production users always get the normal save flow.
    // ─────────────────────────────────────────────────────────────────────
    @State private var dryRunOnly: Bool = ScanSafety.defaultDryRun
    @State private var showDryRunReceipt: Bool = false

    /// BISECT-F — adds Pickup, Delivery, Money & Cargo, Trailer & BOL,
    /// Special Notes, saveButton (without the alerts). milesSection,
    /// rawOCRDisclosure, Pay Breakdown, Driver Notes, debug banner, and
    /// alerts still excluded.
    var body: some View {
        if true {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 18) {
                        confidenceBanner

                        sectionCard("Load Info") {
                            field("Load #", text: $loadNumber, key: "loadNumber",
                                  placeholder: "e.g. LD-2841")
                            brokerNameField
                            field("MC #", text: $brokerMcNumber, key: "brokerMcNumber",
                                  placeholder: "e.g. 128156", keyboard: .numberPad)
                            field("Phone", text: $brokerPhone, key: "brokerPhone",
                                  placeholder: "(555) 555-1234", keyboard: .phonePad)
                            field("Ext", text: $brokerPhoneExtension, key: "brokerPhoneExtension",
                                  placeholder: "Optional — e.g. 4421", keyboard: .numberPad)
                            field("Email", text: $brokerEmail, key: "brokerEmail",
                                  placeholder: "dispatch@broker.com", keyboard: .emailAddress)
                        }

                        sectionCard("Pickup") {
                            field("Shipper", text: $shipperName, key: "shipperName",
                                  placeholder: "e.g. ABC Manufacturing")
                            field("City, ST", text: $pickupCityState, key: "pickupCityState",
                                  placeholder: "e.g. Atlanta, GA")
                            field("Address", text: $pickupAddress, key: "pickupAddress",
                                  placeholder: "e.g. 123 Industrial Blvd")
                            datePickerRow("Date", date: $pickupDate, isSet: $pickupDateSet,
                                          confidence: parsed.confidence["pickupDate"])
                            field("Time", text: $pickupTime, key: "pickupTime",
                                  placeholder: "e.g. 08:00 AM")
                        }

                        sectionCard("Delivery") {
                            field("Receiver", text: $receiverName, key: "receiverName",
                                  placeholder: "e.g. XYZ Distribution")
                            field("City, ST", text: $deliveryCityState, key: "deliveryCityState",
                                  placeholder: "e.g. Dallas, TX")
                            field("Address", text: $deliveryAddress, key: "deliveryAddress",
                                  placeholder: "e.g. 456 Warehouse Dr")
                            datePickerRow("Date", date: $deliveryDate, isSet: $deliveryDateSet,
                                          confidence: parsed.confidence["deliveryDate"])
                            field("Time", text: $deliveryTime, key: "deliveryTime",
                                  placeholder: "e.g. 16:00")
                        }

                        sectionCard("Money & Cargo") {
                            field("Rate ($)", text: $rate, key: "rate",
                                  placeholder: "0.00", keyboard: .decimalPad, prefix: "$")
                            field("Weight", text: $weight, key: "weight",
                                  placeholder: "e.g. 42,000 lbs")
                            field("Commodity", text: $commodity, key: "commodity",
                                  placeholder: "e.g. Frozen Foods")
                            field("PO #", text: $poNumber, key: "poNumber",
                                  placeholder: "e.g. PO-9381")
                            field("Pickup #", text: $pickupNumber, key: "pickupNumber",
                                  placeholder: "e.g. PU-3344")
                            field("Reference #", text: $referenceNumber, key: "referenceNumber",
                                  placeholder: "e.g. REF-7821")
                        }

                        sectionCard("Trailer & BOL") {
                            field("Trailer #", text: $trailerNumber, key: "trailerNumber",
                                  placeholder: "e.g. T-2418")
                            field("BOL #", text: $bolNumber, key: "bolNumber",
                                  placeholder: "e.g. BOL-988221")
                        }

                        sectionCard("Special Notes") {
                            TextEditor(text: $notes)
                                .frame(minHeight: 80)
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(Color.spTextPrimary)
                                .padding(8)
                                .background(Color.spCardBgLight)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        saveButton
                            .padding(.horizontal)
                            .padding(.bottom, 32)
                    }
                    .padding(.top, 12)
                }
                .background(Color.spBackground.ignoresSafeArea())
                .navigationTitle("Review & Save")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color.spBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(Color.spGoldLight)
                    }
                }
                .onAppear(perform: prefillFromParsed)
                .task { await loadBrokers() }
            }
        } else {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        confidenceBanner

                        // Reverted to v2.0 Load Info card layout 2026-05-17
                        // to isolate the upload crash. All v2.0.2 UI additions
                        // are removed for this build.
                        sectionCard("Load Info") {
                            field("Load #", text: $loadNumber, key: "loadNumber",
                                  placeholder: "e.g. LD-2841")
                            brokerNameField
                            field("MC #", text: $brokerMcNumber, key: "brokerMcNumber",
                                  placeholder: "e.g. 128156", keyboard: .numberPad)
                            field("Phone", text: $brokerPhone, key: "brokerPhone",
                                  placeholder: "(555) 555-1234", keyboard: .phonePad)
                            field("Ext", text: $brokerPhoneExtension, key: "brokerPhoneExtension",
                                  placeholder: "Optional — e.g. 4421", keyboard: .numberPad)
                            field("Email", text: $brokerEmail, key: "brokerEmail",
                                  placeholder: "dispatch@broker.com", keyboard: .emailAddress)
                        }

                        sectionCard("Pickup") {
                            field("Shipper", text: $shipperName, key: "shipperName",
                                  placeholder: "e.g. ABC Manufacturing")
                            field("City, ST", text: $pickupCityState, key: "pickupCityState",
                                  placeholder: "e.g. Atlanta, GA")
                            field("Address", text: $pickupAddress, key: "pickupAddress",
                                  placeholder: "e.g. 123 Industrial Blvd")
                            datePickerRow("Date", date: $pickupDate, isSet: $pickupDateSet,
                                          confidence: parsed.confidence["pickupDate"])
                            field("Time", text: $pickupTime, key: "pickupTime",
                                  placeholder: "e.g. 08:00 AM")
                        }

                        sectionCard("Delivery") {
                            field("Receiver", text: $receiverName, key: "receiverName",
                                  placeholder: "e.g. XYZ Distribution")
                            field("City, ST", text: $deliveryCityState, key: "deliveryCityState",
                                  placeholder: "e.g. Dallas, TX")
                            field("Address", text: $deliveryAddress, key: "deliveryAddress",
                                  placeholder: "e.g. 456 Warehouse Dr")
                            datePickerRow("Date", date: $deliveryDate, isSet: $deliveryDateSet,
                                          confidence: parsed.confidence["deliveryDate"])
                            field("Time", text: $deliveryTime, key: "deliveryTime",
                                  placeholder: "e.g. 16:00")
                        }

                        milesSection

                        sectionCard("Money & Cargo") {
                            field("Rate ($)", text: $rate, key: "rate",
                                  placeholder: "0.00", keyboard: .decimalPad, prefix: "$")
                            field("Weight", text: $weight, key: "weight",
                                  placeholder: "e.g. 42,000 lbs")
                            field("Commodity", text: $commodity, key: "commodity",
                                  placeholder: "e.g. Frozen Foods")
                            field("PO #", text: $poNumber, key: "poNumber",
                                  placeholder: "e.g. PO-9381")
                            field("Pickup #", text: $pickupNumber, key: "pickupNumber",
                                  placeholder: "e.g. PU-3344")
                            field("Reference #", text: $referenceNumber, key: "referenceNumber",
                                  placeholder: "e.g. REF-7821")
                        }

                        // Accessorial pay lines extracted from the rate con.
                        // Hidden when nothing was extracted to keep the form lean.
                        if hasAnyPayBreakdown {
                            sectionCard("Pay Breakdown") {
                                field("FSC ($)", text: $fuelSurcharge, key: "fuelSurcharge",
                                      placeholder: "0.00", keyboard: .decimalPad, prefix: "$")
                                field("Lumper ($)", text: $lumperFee, key: "lumperFee",
                                      placeholder: "0.00", keyboard: .decimalPad, prefix: "$")
                                field("Detention ($)", text: $detentionRate, key: "detentionRate",
                                      placeholder: "0.00", keyboard: .decimalPad, prefix: "$")
                                field("Stop-off ($)", text: $stopOffPay, key: "stopOffPay",
                                      placeholder: "0.00", keyboard: .decimalPad, prefix: "$")
                            }
                        }

                        // Equipment + BOL metadata. Always shown so users can
                        // type even when nothing was auto-detected.
                        sectionCard("Trailer & BOL") {
                            field("Trailer #", text: $trailerNumber, key: "trailerNumber",
                                  placeholder: "e.g. T-2418")
                            field("BOL #", text: $bolNumber, key: "bolNumber",
                                  placeholder: "e.g. BOL-988221")
                        }

                        sectionCard("Special Notes") {
                            TextEditor(text: $notes)
                                .frame(minHeight: 80)
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(Color.spTextPrimary)
                                .padding(8)
                                .background(Color.spCardBgLight)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        if !driverNotes.isEmpty || parsed.driverNotes != nil {
                            sectionCard("Driver Notes (from broker)") {
                                TextEditor(text: $driverNotes)
                                    .frame(minHeight: 60)
                                    .scrollContentBackground(.hidden)
                                    .foregroundStyle(Color.spTextPrimary)
                                    .padding(8)
                                    .background(Color.spCardBgLight)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }

                        rawOCRDisclosure

                        #if DEBUG
                        if ScanSafety.isSimulator {
                            dryRunBanner
                        }
                        #endif

                        if let err = errorMessage {
                            Text(err).font(.caption).foregroundStyle(Color.spDanger)
                                .padding(.horizontal)
                        }

                        saveButton
                            .padding(.horizontal)
                            .padding(.bottom, 32)
                    }
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Review & Save")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.spBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Color.spGoldLight)
                }
            }
            .onAppear(perform: prefillFromParsed)
            .task { await loadBrokers() }
            .alert("Add this broker to contacts?",
                   isPresented: $showAddBrokerPrompt) {
                Button("Skip") { finishSave() }
                Button("Add Broker") { Task { await addBrokerToContactsAndFinish() } }
            } message: {
                Text("\(brokerName) isn't in your broker list. Save it for one-tap selection on future loads?")
            }
            .alert("Load Saved", isPresented: $showSavedAlert) {
                Button("OK") { dismiss() }
            } message: {
                Text("Load \(loadNumber.isEmpty ? "" : loadNumber + " ")added to your loads.")
            }
            #if DEBUG
            .alert("Dry-run save complete", isPresented: $showDryRunReceipt) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Test mode is ON. The load was NOT written to your Supabase " +
                     "production account. Check the Xcode console for the payload.")
            }
            #endif
        }
        }  // close bisect-C else
    }

    // MARK: - Subviews

    private var confidenceBanner: some View {
        let lowConf = parsed.confidence.filter { $0.value < 0.5 }.count
        return HStack(spacing: 10) {
            Image(systemName: "doc.text.viewfinder")
                .foregroundStyle(Color.spGold)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Auto-filled from your document")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                    if let vendor = parsed.sourceVendor {
                        Text(vendorLabel(vendor))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.spGold.opacity(0.25))
                            .foregroundStyle(Color.spGoldLight)
                            .clipShape(Capsule())
                    }
                }
                Text(lowConf > 0
                     ? "Review \(lowConf) field\(lowConf == 1 ? "" : "s") — low confidence"
                     : "Looks clean. Edit anything before saving.")
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    private func vendorLabel(_ vendor: String) -> String {
        switch vendor {
        case "Lowes": return "LOWE'S"
        default: return vendor.uppercased()
        }
    }

    /// True when the parser pulled at least one accessorial dollar value.
    /// Hides the entire Pay Breakdown card when nothing was detected to
    /// keep the form lean.
    private var hasAnyPayBreakdown: Bool {
        !fuelSurcharge.isEmpty || !lumperFee.isEmpty ||
        !detentionRate.isEmpty || !stopOffPay.isEmpty ||
        parsed.fuelSurcharge != nil || parsed.lumperFee != nil ||
        parsed.detentionRate != nil || parsed.stopOffPay != nil
    }

    private var brokerNameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            field("Broker", text: $brokerName, key: "brokerName",
                  placeholder: "e.g. CH Robinson")

            // Suggestion chips matching what the user has typed
            let lower = brokerName.lowercased()
            let suggestions = lower.isEmpty
                ? []
                : savedBrokers.filter {
                    $0.brokerName.lowercased().contains(lower) &&
                    $0.brokerName.lowercased() != lower
                }.prefix(3)
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(suggestions), id: \.id) { b in
                            Button {
                                applyBroker(b)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "building.2.fill")
                                        .font(.caption2)
                                    Text(b.brokerName)
                                        .font(.caption)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.spGold.opacity(0.18))
                                .foregroundStyle(Color.spGoldLight)
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
            }

            if let m = matchedBroker {
                Text("Matched saved broker · \(m.brokerName)")
                    .font(.caption2)
                    .foregroundStyle(Color.spSuccess)
            }
        }
    }

    private var rawOCRDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation { showRawOCR.toggle() } } label: {
                HStack {
                    Image(systemName: showRawOCR ? "chevron.down" : "chevron.right")
                    Text("View OCR text")
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(Color.spTextSecondary)
            }
            if showRawOCR {
                ScrollView {
                    Text(parsed.rawText.isEmpty ? "No text was recognized." : parsed.rawText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.spTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(Color.spCardBgLight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Miles section
    //
    // Calculates loaded miles (pickup → delivery) automatically when both
    // city/state strings are filled in. Distance is computed by
    // `DistanceService` using ONLY Apple's free `CLGeocoder` + `MKDirections`
    // — no API key, no monthly paid service, no Google.
    //
    // The user can:
    //   • Tap "Calculate" to re-run after editing pickup/delivery.
    //   • Type into the Loaded Miles field directly — that flips
    //     `loadedMilesIsManual` and we never overwrite their value.
    //   • Optionally enter a home-base city to compute deadhead miles.

    private var milesSection: some View {
        sectionCard("Miles") {
            milesField(
                label: "Loaded",
                text: $loadedMiles,
                isManual: $loadedMilesIsManual,
                estimated: loadedMilesEstimated,
                placeholder: "e.g. 1024"
            )

            field("Home base", text: $homeBaseCityState, key: "homeBaseCityState",
                  placeholder: "Optional — e.g. Memphis, TN")

            milesField(
                label: "Deadhead",
                text: $deadheadMiles,
                isManual: .constant(true),     // deadhead is always manual / DistanceService below
                estimated: false,
                placeholder: "Optional — empty miles to pickup"
            )

            HStack(spacing: 10) {
                Button(action: { Task { await runDistanceCalc(force: true) } }) {
                    HStack(spacing: 6) {
                        if isCalculatingDistance {
                            ProgressView().tint(Color.spGold).scaleEffect(0.8)
                        } else {
                            Image(systemName: "map")
                        }
                        Text(isCalculatingDistance ? "Calculating…" : "Calculate Distance")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.spGoldLight)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.spGold.opacity(0.18))
                    .clipShape(Capsule())
                }
                .disabled(isCalculatingDistance)

                Spacer()

                if !loadedMiles.isEmpty || !deadheadMiles.isEmpty {
                    Text("Total: \(totalMilesDisplay) mi")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                }
            }

            if let err = distanceErrorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
            }

            Text("Distances are calculated on-device with Apple Maps. Free, no API keys.")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
        }
    }

    /// Custom miles row — text field + optional "Estimated" badge + manual flag.
    private func milesField(label: String,
                            text: Binding<String>,
                            isManual: Binding<Bool>,
                            estimated: Bool,
                            placeholder: String) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
                .frame(width: 84, alignment: .leading)
            HStack(spacing: 6) {
                TextField(placeholder, text: text)
                    .keyboardType(.numberPad)
                    .foregroundStyle(Color.spTextPrimary)
                    .onChange(of: text.wrappedValue) { _, _ in
                        // Any user edit means manual override.
                        if !isCalculatingDistance { isManual.wrappedValue = true }
                    }
                if estimated && !text.wrappedValue.isEmpty {
                    Text("Estimated")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.spWarning)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.spWarning.opacity(0.18))
                        .clipShape(Capsule())
                }
            }
            .padding(10)
            .background(Color.spCardBgLight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Sum of loaded + deadhead, rendered as integer string. Empty when both blank.
    private var totalMilesDisplay: String {
        let l = Double(loadedMiles) ?? 0
        let d = Double(deadheadMiles) ?? 0
        let sum = l + d
        guard sum > 0 else { return "0" }
        return String(Int(sum.rounded()))
    }

    /// Run DistanceService for pickup→delivery and (if home-base set) home→pickup.
    /// Re-entrant safe via `isCalculatingDistance`.
    private func runDistanceCalc(force: Bool) async {
        if isCalculatingDistance { return }
        let pickup = pickupCityState.trimmingCharacters(in: .whitespacesAndNewlines)
        let delivery = deliveryCityState.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pickup.isEmpty, !delivery.isEmpty else {
            distanceErrorMessage = "Fill pickup and delivery city/state first."
            return
        }

        isCalculatingDistance = true
        distanceErrorMessage = nil

        // Loaded miles — pickup → delivery. Skip if user has already typed
        // a value AND this isn't a forced re-calc.
        let canFillLoaded = force || (!loadedMilesIsManual && loadedMiles.isEmpty)
        if canFillLoaded {
            let result = await DistanceService.shared.distance(from: pickup, to: delivery)
            switch result {
            case .driving(let m):
                loadedMiles = String(Int(m.rounded()))
                loadedMilesEstimated = false
                loadedMilesIsManual = false   // result of auto-calc, NOT manual
            case .estimatedStraightLine(let m):
                loadedMiles = String(Int(m.rounded()))
                loadedMilesEstimated = true
                loadedMilesIsManual = false
            case .unavailable(let reason):
                distanceErrorMessage = reason
            }
        }

        // Deadhead miles — home base → pickup, only if user provided a home base.
        let home = homeBaseCityState.trimmingCharacters(in: .whitespacesAndNewlines)
        if !home.isEmpty {
            let dh = await DistanceService.shared.distance(from: home, to: pickup)
            if let m = dh.miles, force || deadheadMiles.isEmpty {
                deadheadMiles = String(Int(m.rounded()))
            }
        }

        isCalculatingDistance = false
    }

    // MARK: - DEBUG safety banner

    /// Visible only in DEBUG simulator builds. Lets the developer keep saves
    /// LOCAL ONLY (dry-run) so test scans never touch the user's production
    /// Supabase account. Off by default in DEBUG too — must be opted in.
    private var dryRunBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: dryRunOnly ? "shield.lefthalf.filled" : "shield")
                    .foregroundStyle(dryRunOnly ? Color.spWarning : Color.spTextSecondary)
                Toggle(isOn: $dryRunOnly) {
                    Text(dryRunOnly ? "Test mode — save will NOT hit Supabase" : "Production save (will hit Supabase)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                }
                .tint(Color.spWarning)
            }
            Text("This banner only appears on simulator DEBUG builds. " +
                 "Use Test mode when testing scans so the production account " +
                 "stays clean.")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
        }
        .padding(12)
        .background(dryRunOnly ? Color.spWarning.opacity(0.10) : Color.spCardBg)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(dryRunOnly ? Color.spWarning.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    private var saveButton: some View {
        Button(action: { Task { await save() } }) {
            HStack {
                if isSaving {
                    ProgressView().tint(Color.spBlack)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                }
                Text(isSaving ? "Saving…" : "Save Load")
                    .fontWeight(.bold)
            }
            .frame(maxWidth: .infinity).frame(height: 50)
            .foregroundStyle(Color.spBlack)
            .background(Color.spGold)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(isSaving)
    }

    // MARK: - Field components

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.caption.weight(.semibold))
                .foregroundStyle(Color.spGold)
            VStack(spacing: 14) { content() }
                .padding(16)
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal)
    }

    private func field(_ label: String,
                       text: Binding<String>,
                       key: String,
                       placeholder: String,
                       keyboard: UIKeyboardType = .default,
                       prefix: String? = nil) -> some View {
        let conf = parsed.confidence[key] ?? 0
        return HStack(alignment: .center) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
                .frame(width: 84, alignment: .leading)

            HStack(spacing: 4) {
                if let p = prefix {
                    Text(p).foregroundStyle(Color.spGold)
                }
                TextField(placeholder, text: text)
                    .keyboardType(keyboard)
                    .foregroundStyle(Color.spTextPrimary)
                    .autocorrectionDisabled(keyboard == .emailAddress)
                    .textInputAutocapitalization(keyboard == .emailAddress ? .never : .sentences)
                if conf > 0 && conf < 0.5 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.spWarning)
                }
            }
            .padding(10)
            .background(Color.spCardBgLight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func datePickerRow(_ label: String,
                               date: Binding<Date>,
                               isSet: Binding<Bool>,
                               confidence: Double?) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
                .frame(width: 84, alignment: .leading)
            if isSet.wrappedValue {
                DatePicker("", selection: date, displayedComponents: .date)
                    .labelsHidden()
                    .colorScheme(.dark)
                Spacer()
                Button { isSet.wrappedValue = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.spTextSecondary)
                }
            } else {
                Button { isSet.wrappedValue = true } label: {
                    HStack {
                        Image(systemName: "calendar")
                        Text("Set date")
                            .font(.subheadline)
                    }
                    .foregroundStyle(Color.spGoldLight)
                }
                Spacer()
            }
            if let c = confidence, c < 0.5 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.spWarning)
            }
        }
    }

    // MARK: - Prefill

    private func prefillFromParsed() {
        loadNumber           = parsed.loadNumber           ?? ""
        brokerName           = parsed.brokerName           ?? ""
        brokerContactName    = parsed.brokerContactName    ?? ""
        brokerPhone          = parsed.brokerPhone          ?? ""
        brokerPhoneExtension = parsed.brokerPhoneExtension ?? ""
        brokerEmail          = parsed.brokerEmail          ?? ""
        brokerMcNumber       = parsed.brokerMcNumber       ?? ""

        pickupCityState   = parsed.pickupCityState  ?? ""
        pickupAddress     = parsed.pickupAddress    ?? ""
        if let d = parsed.pickupDate { pickupDate = d; pickupDateSet = true }
        pickupTime        = parsed.pickupTime       ?? ""

        deliveryCityState = parsed.deliveryCityState ?? ""
        deliveryAddress   = parsed.deliveryAddress   ?? ""
        if let d = parsed.deliveryDate { deliveryDate = d; deliveryDateSet = true }
        deliveryTime      = parsed.deliveryTime      ?? ""

        rate              = parsed.rate.map { String(format: "%.2f", $0) } ?? ""
        weight            = parsed.weight       ?? ""
        commodity         = parsed.commodity    ?? ""
        poNumber          = parsed.poNumber     ?? ""
        pickupNumber      = parsed.pickupNumber ?? ""
        referenceNumber   = parsed.referenceNumber ?? ""
        notes             = parsed.notes        ?? ""

        shipperName       = parsed.shipperName  ?? ""
        receiverName      = parsed.receiverName ?? ""

        // Pay breakdown
        fuelSurcharge  = parsed.fuelSurcharge.map  { String(format: "%.2f", $0) } ?? ""
        lumperFee      = parsed.lumperFee.map      { String(format: "%.2f", $0) } ?? ""
        detentionRate  = parsed.detentionRate.map  { String(format: "%.2f", $0) } ?? ""
        stopOffPay     = parsed.stopOffPay.map     { String(format: "%.2f", $0) } ?? ""

        // Equipment + BOL
        trailerNumber  = parsed.trailerNumber ?? ""
        bolNumber      = parsed.bolNumber     ?? ""
        driverNotes    = parsed.driverNotes   ?? ""

        // Pre-fill miles from the document if present, otherwise leave empty
        // and let the auto-calc fill them.
        if let lm = parsed.loadedMiles {
            loadedMiles = String(Int(lm.rounded()))
            loadedMilesIsManual = true   // came from the document, treat as authoritative
            loadedMilesEstimated = false
        }
        if let dh = parsed.deadheadMiles {
            deadheadMiles = String(Int(dh.rounded()))
        }

        // If we have both endpoints AND no loaded-miles value yet, auto-calc.
        if loadedMiles.isEmpty,
           !pickupCityState.trimmingCharacters(in: .whitespaces).isEmpty,
           !deliveryCityState.trimmingCharacters(in: .whitespaces).isEmpty {
            Task { await runDistanceCalc(force: false) }
        }
    }

    // MARK: - Broker matching

    private func loadBrokers() async {
        do {
            savedBrokers = try await supabase.fetchBrokers()
            updateMatchedBroker()
        } catch {
            // Non-fatal — we still show the form.
        }
    }

    private func updateMatchedBroker() {
        guard !brokerName.isEmpty else { matchedBroker = nil; return }
        let target = Broker.normalize(brokerName)
        matchedBroker = savedBrokers.first { ($0.normalizedName ?? Broker.normalize($0.brokerName)) == target }
        // If matched, auto-fill MC# only when the user hasn't typed one.
        if let m = matchedBroker {
            if brokerMcNumber.isEmpty, let mc = m.mcNumber { brokerMcNumber = mc }
        }
    }

    private func applyBroker(_ b: Broker) {
        brokerName = b.brokerName
        if brokerMcNumber.isEmpty, let mc = b.mcNumber { brokerMcNumber = mc }
        matchedBroker = b
    }

    // MARK: - Save

    private func save() async {
        guard let profileId = supabase.client.auth.currentUser?.id else {
            errorMessage = "Not signed in"; return
        }
        updateMatchedBroker()
        isSaving = true
        errorMessage = nil

        let rateD = Double(rate.replacingOccurrences(of: ",", with: ""))
        let totalRev = (rateD ?? 0) > 0 ? rateD : nil

        // Compose readable origin / destination.
        let origin = composedRoute(cityState: pickupCityState, address: pickupAddress)
        let destination = composedRoute(cityState: deliveryCityState, address: deliveryAddress)

        #if DEBUG
        if dryRunOnly && ScanSafety.isSimulator {
            // Dry-run: print the payload that WOULD have been sent and bail
            // out without touching Supabase. Production data stays clean.
            print("""
            [SmartScanReview] 🛡 DRY-RUN — not saving to Supabase.
              loadNumber=\(loadNumber)
              broker=\(brokerName) (mc=\(brokerMcNumber))
              origin=\(origin)
              destination=\(destination)
              rate=\(rate)
              loadedMiles=\(loadedMiles)  deadhead=\(deadheadMiles)
            """)
            isSaving = false
            showDryRunReceipt = true
            return
        }
        #endif

        // Total miles = loaded + deadhead. Empty inputs are treated as 0.
        let loadedD = Double(loadedMiles) ?? 0
        let deadheadD = Double(deadheadMiles) ?? 0
        let totalMilesD: Double? = (loadedD + deadheadD) > 0 ? (loadedD + deadheadD) : nil

        let load = Load(
            profileId: profileId,
            loadNumber: loadNumber.isEmpty ? nil : loadNumber,
            brokerName: brokerName.isEmpty ? nil : brokerName,
            brokerMcNumber: brokerMcNumber.isEmpty ? nil : brokerMcNumber,
            pickupDate: pickupDateSet ? pickupDate : nil,
            deliveryDate: deliveryDateSet ? deliveryDate : nil,
            origin: origin.isEmpty ? nil : origin,
            destination: destination.isEmpty ? nil : destination,
            totalMiles: totalMilesD,
            lineHaulRate: rateD,
            totalRevenue: totalRev,
            status: nil
        )
        let savedLoad: Load
        do {
            savedLoad = try await supabase.createLoad(load)
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            isSaving = false
            return
        }

        // Auto-add broker + contact silently. Dedupe priority:
        //   1. MC number, 2. email/phone, 3. normalized broker name.
        // Then patch the load with per-load broker attribution + snapshot.
        // Failures are non-fatal — the load is already saved.
        let (resolvedBrokerId, resolvedContactId) =
            await autoAddBrokerContact(profileId: profileId)
        await patchLoadWithBrokerAttribution(
            load: savedLoad,
            brokerId: resolvedBrokerId,
            contactId: resolvedContactId
        )

        // Persist the scanned document into the Document Vault so the user
        // can find, reopen, and link the original rate-con file later.
        await persistScannedDocument(profileId: profileId, loadId: savedLoad.id)

        isSaving = false
        finishSave()
    }

    /// Silent broker + contact auto-add path. Resolves a (brokerId, contactId)
    /// pair for the current scan so the load can be tagged with per-load
    /// attribution. Distinct reps within the same broker are preserved.
    ///
    /// Dedupe order:
    ///   1. Existing broker via normalized name match
    ///   2. Existing broker via MC#
    ///   3. Create new broker
    /// Then within that broker:
    ///   a. Existing contact via exact contact_name match → update missing fields
    ///   b. Create new contact tied to THIS rep
    private func autoAddBrokerContact(profileId: UUID) async -> (brokerId: UUID?, contactId: UUID?) {
        let trimmedCompany = brokerName.trimmingCharacters(in: .whitespaces)
        guard !trimmedCompany.isEmpty else { return (nil, nil) }

        // The rep name — falls back to the company name if Smart Scan did not
        // pick up a separate human rep (so we still create a contact row).
        let trimmedRep: String = {
            let r = brokerContactName.trimmingCharacters(in: .whitespaces)
            return r.isEmpty ? trimmedCompany : r
        }()

        // Refresh the broker list so we dedupe against the latest state.
        if let fresh = try? await supabase.fetchBrokers() {
            savedBrokers = fresh
        }
        updateMatchedBroker()

        // 1) Resolve broker
        var resolvedBroker: Broker? = matchedBroker
        if resolvedBroker == nil, !brokerMcNumber.isEmpty {
            resolvedBroker = savedBrokers.first { $0.mcNumber == brokerMcNumber }
        }
        if resolvedBroker == nil {
            let newBroker = Broker(
                profileId: profileId,
                brokerName: trimmedCompany,
                normalizedName: Broker.normalize(trimmedCompany),
                mcNumber: brokerMcNumber.isEmpty ? nil : brokerMcNumber,
                totalLoads: 0,
                totalRevenue: 0
            )
            resolvedBroker = try? await supabase.createBroker(newBroker)
        }
        guard let brokerId = resolvedBroker?.id else { return (nil, nil) }

        // 2) Resolve contact within that broker
        let phoneToSave = combinedPhone()
        let ext = brokerPhoneExtension.trimmingCharacters(in: .whitespaces)
        let emailToSave = brokerEmail.trimmingCharacters(in: .whitespaces).lowercased()

        // Look for existing contact with the same name on this broker.
        let existingContact: BrokerContact? = (try? await supabase.findContact(
            brokerId: brokerId,
            name: trimmedRep
        )) ?? nil

        var contactId: UUID? = existingContact?.id

        if var existing = existingContact, let _ = existing.id {
            // Patch only missing fields — never overwrite info the user
            // already curated for this rep.
            var didUpdate = false
            if (existing.email?.isEmpty ?? true), !emailToSave.isEmpty {
                existing.email = emailToSave; didUpdate = true
            }
            if (existing.phone?.isEmpty ?? true), !phoneToSave.isEmpty {
                existing.phone = phoneToSave; didUpdate = true
            }
            if (existing.phoneExtension?.isEmpty ?? true), !ext.isEmpty {
                existing.phoneExtension = ext; didUpdate = true
            }
            existing.lastInteractionAt = Date()
            if didUpdate {
                try? await supabase.updateContact(existing)
            } else {
                // Touch lastInteractionAt only.
                try? await supabase.updateContact(existing)
            }
            contactId = existing.id
        } else {
            // New rep on this broker (or first contact for this broker).
            let contact = BrokerContact(
                brokerId: brokerId,
                contactName: trimmedRep,
                email: emailToSave.isEmpty ? nil : emailToSave,
                phone: phoneToSave.isEmpty ? nil : phoneToSave,
                phoneExtension: ext.isEmpty ? nil : ext,
                lastInteractionAt: Date()
            )
            let created = try? await supabase.createContact(contact)
            contactId = created?.id
        }

        return (brokerId, contactId)
    }

    /// Patches the just-saved load with the resolved broker_id + broker_contact_id
    /// plus the rep snapshot (name/phone/ext/email). Snapshot fields preserve
    /// the exact info used on THIS load even if the broker_contact row is
    /// later renamed or deleted.
    private func patchLoadWithBrokerAttribution(
        load: Load,
        brokerId: UUID?,
        contactId: UUID?
    ) async {
        guard let _ = load.id else { return }
        guard brokerId != nil || contactId != nil ||
              !brokerContactName.isEmpty ||
              !brokerPhone.isEmpty ||
              !brokerEmail.isEmpty
        else { return }

        var patched = load
        patched.brokerId             = brokerId
        patched.brokerContactId      = contactId
        patched.brokerContactName    = brokerContactName.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? nil : brokerContactName.trimmingCharacters(in: .whitespaces)
        patched.brokerContactPhone   = brokerPhone.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? nil : brokerPhone.trimmingCharacters(in: .whitespaces)
        patched.brokerPhoneExtension = brokerPhoneExtension.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? nil : brokerPhoneExtension.trimmingCharacters(in: .whitespaces)
        patched.brokerContactEmail   = brokerEmail.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? nil : brokerEmail.trimmingCharacters(in: .whitespaces).lowercased()

        try? await supabase.updateLoad(patched)
    }

    /// Combine phone + extension into a single contact-row phone string so
    /// nothing is lost without needing a schema migration.
    /// "(555) 555-1234 x4421" if extension present, else just the phone.
    private func combinedPhone() -> String {
        let p = brokerPhone.trimmingCharacters(in: .whitespaces)
        let ext = brokerPhoneExtension.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return "" }
        if ext.isEmpty { return p }
        return "\(p) x\(ext)"
    }

    /// Save the original scan image to Supabase Storage + create a
    /// `documents` row so the file shows up in Document Vault, linked to
    /// the load when we have one. Failures are logged but never block save.
    private func persistScannedDocument(profileId: UUID, loadId: UUID?) async {
        guard let img = sourceImage else { return }
        guard let jpeg = img.jpegData(compressionQuality: 0.85) else { return }
        // Lowercased UUIDs to satisfy Storage RLS (auth.uid()::text).
        let docId = UUID().uuidString.lowercased()
        let timestamp = Int(Date().timeIntervalSince1970)
        let path = "\(profileId.uuidString.lowercased())/rate_confirmation/\(timestamp)-\(docId).jpg"
        do {
            _ = try await supabase.uploadDocument(
                data: jpeg, path: path, contentType: "image/jpeg")

            // Build a minimal extracted-data payload so the vault row shows
            // the broker / load number / origin / destination at a glance.
            var extracted = ExtractedData()
            extracted.documentType = "rate_confirmation"
            extracted.brokerName = brokerName.isEmpty ? nil : brokerName
            extracted.brokerMcNumber = brokerMcNumber.isEmpty ? nil : brokerMcNumber
            extracted.loadNumber = loadNumber.isEmpty ? nil : loadNumber
            extracted.origin = pickupCityState.isEmpty ? nil : pickupCityState
            extracted.destination = deliveryCityState.isEmpty ? nil : deliveryCityState
            extracted.lineHaulRate = Double(rate.replacingOccurrences(of: ",", with: ""))
            extracted.totalRevenue = extracted.lineHaulRate
            // Re-use notes for the human-readable title (DocumentVaultView
            // already keys off this field for display + search).
            let title = "Rate Con · \(brokerName.isEmpty ? "Broker" : brokerName)" +
                        (loadNumber.isEmpty ? "" : " · #\(loadNumber)")
            extracted.notes = title
            extracted.confidence = "high"

            let row = TruckDocument(
                id: nil,
                profileId: profileId,
                loadId: loadId,
                documentType: "rate_confirmation",
                storagePath: path,
                extractedData: extracted,
                rawText: parsed.rawText.isEmpty ? nil : parsed.rawText,
                confidence: "high",
                status: "processed",
                errorMessage: nil,
                isManual: true,
                provider: "smart_scan",
                model: "vision-ocr",
                fileMimeType: "image/jpeg",
                fileSize: jpeg.count,
                retryCount: 0,
                processed: true,
                createdAt: nil,
                updatedAt: nil
            )
            _ = try? await supabase.createDocument(row)
        } catch {
            print("⚠️ persistScannedDocument failed: \(error)")
        }
    }

    private func finishSave() {
        showSavedAlert = true
    }

    private func addBrokerToContactsAndFinish() async {
        guard let profileId = supabase.client.auth.currentUser?.id else {
            finishSave(); return
        }
        let trimmedName = brokerName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { finishSave(); return }
        do {
            let broker = Broker(
                profileId: profileId,
                brokerName: trimmedName,
                normalizedName: Broker.normalize(trimmedName),
                mcNumber: brokerMcNumber.isEmpty ? nil : brokerMcNumber,
                totalLoads: 0,
                totalRevenue: 0
            )
            let created = try await supabase.createBroker(broker)

            // Save phone + email + extension as a contact row if any is present.
            // Use the parsed rep name when we have one; otherwise fall back
            // to the broker company name so we still get a contact row.
            let repName = brokerContactName.trimmingCharacters(in: .whitespaces)
            let contactName = repName.isEmpty ? trimmedName : repName
            let extTrimmed = brokerPhoneExtension.trimmingCharacters(in: .whitespaces)
            if let id = created.id,
               !(brokerPhone.isEmpty && brokerEmail.isEmpty && extTrimmed.isEmpty) {
                let contact = BrokerContact(
                    brokerId: id,
                    contactName: contactName,
                    email: brokerEmail.isEmpty ? nil : brokerEmail,
                    phone: brokerPhone.isEmpty ? nil : brokerPhone,
                    phoneExtension: extTrimmed.isEmpty ? nil : extTrimmed,
                    lastInteractionAt: Date()
                )
                _ = try? await supabase.createContact(contact)
            }
        } catch {
            // Don't block save flow if broker save fails.
            print("⚠️ Broker save failed: \(error)")
        }
        finishSave()
    }

    private func composedRoute(cityState: String, address: String) -> String {
        let cs = cityState.trimmingCharacters(in: .whitespaces)
        let ad = address.trimmingCharacters(in: .whitespaces)
        if cs.isEmpty { return ad }
        if ad.isEmpty { return cs }
        return "\(ad), \(cs)"
    }
}

// =============================================================================
// MARK: - ScanSafety
// -----------------------------------------------------------------------------
// Centralized flags that decide whether a save should be allowed to write to
// the live production Supabase account. The intent is conservative-by-default
// in DEBUG simulator builds so test scans CANNOT pollute real load history.
// =============================================================================
fileprivate enum ScanSafety {
    /// True when this build is running on a simulator. Detected at compile
    /// time via the `targetEnvironment` directive — no runtime checks.
    static let isSimulator: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()

    /// Default value of the dry-run toggle on first appearance.
    ///
    /// • DEBUG simulator builds → `true`. Save to Supabase requires the user
    ///   to flip the toggle off first. This is the protection that keeps
    ///   test scans (mine or anyone's) out of the production account.
    /// • All other builds → `false`. Production users see no banner and
    ///   the normal save flow runs unchanged.
    static let defaultDryRun: Bool = {
        #if DEBUG
        return isSimulator
        #else
        return false
        #endif
    }()
}
