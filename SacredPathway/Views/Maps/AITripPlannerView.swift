import SwiftUI
import MapKit
import CoreLocation
import UIKit

// =============================================================================
// MARK: - AI Trip Planner
// -----------------------------------------------------------------------------
// The headline of the Maps tab. Drivers enter a trip (pickup → delivery, with
// appointment times), their fuel status, and their hours-of-service clocks; the
// planner returns a legal, on-time plan: fuel stops, the 30-minute break, and
// 10/34-hour resets, plus warnings if the load can't be made legally.
//
// This is a PLANNING tool and NOT an ELD. Drivers keep their official HOS log
// in Motive.
//
// Gating: reachable only from the Owner-Operator / Carrier Maps tab. `advanced`
// exposes cycle / 34-hour and Motive sync; a Driver-role simple planner can
// pass `advanced: false`.
// =============================================================================

struct AITripPlannerView: View {
    var advanced: Bool = true

    @StateObject private var vm = TripPlannerViewModel()
    @ObservedObject private var motive = MotiveIntegrationService.shared
    @ObservedObject private var planStore = TripPlanStore.shared
    @FocusState private var focusedField: Field?

    enum Field { case pickup, delivery, distance }

    var body: some View {
        List {
            disclaimerSection
            tripSection
            fuelSection
            brandsSection
            hoursSection
            generateSection
            if let plan = vm.plan {
                planSection(plan)
                handoffSection(plan)
            }
            if !planStore.saved.isEmpty {
                savedSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.spBackground)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("AI Trip Planner")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.spGold)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { focusedField = nil }
                    .tint(Color.spGold)
                    .opacity(focusedField == nil ? 0 : 1)
            }
        }
    }

    // MARK: Disclaimer

    private var disclaimerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color.spGold)
                Text("Planning aid only. Sacred Path helps you plan fuel and rest. It is not an ELD — your official hours of service stay in Motive.")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(Color.spCardBg)
        }
    }

    // MARK: Trip

    private var tripSection: some View {
        Section("Trip") {
            labeledField("Pickup", systemImage: "shippingbox.fill", tint: Color.spGold) {
                TextField("City, address, or business", text: $vm.pickupName)
                    .focused($focusedField, equals: .pickup)
                    .textInputAutocapitalization(.words)
                    .foregroundStyle(Color.spTextPrimary)
                    .onSubmit { Task { await vm.resolveRoute() } }
            }
            labeledField("Delivery", systemImage: "house.fill", tint: Color.spDanger) {
                TextField("City, address, or business", text: $vm.deliveryName)
                    .focused($focusedField, equals: .delivery)
                    .textInputAutocapitalization(.words)
                    .foregroundStyle(Color.spTextPrimary)
                    .onSubmit { Task { await vm.resolveRoute() } }
            }

            DatePicker(selection: $vm.pickupDate) {
                Label("Pickup time", systemImage: "calendar.badge.clock")
                    .foregroundStyle(Color.spTextSecondary)
            }
            .listRowBackground(Color.spCardBg)
            .tint(Color.spGold)

            DatePicker(selection: $vm.deliveryDate) {
                Label("Delivery time", systemImage: "calendar.badge.checkmark")
                    .foregroundStyle(Color.spTextSecondary)
            }
            .listRowBackground(Color.spCardBg)
            .tint(Color.spGold)

            HStack {
                Label("Distance (mi)", systemImage: "ruler.fill")
                    .foregroundStyle(Color.spTextSecondary)
                Spacer()
                if vm.isResolving {
                    ProgressView().tint(Color.spGold)
                } else {
                    Button {
                        Task { await vm.resolveRoute() }
                    } label: {
                        Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                            .foregroundStyle(Color.spGold)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Auto-fill distance from route")
                }
                TextField("0", value: $vm.distanceMiles, format: .number)
                    .focused($focusedField, equals: .distance)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .foregroundStyle(Color.spTextPrimary)
            }
            .listRowBackground(Color.spCardBg)

            if let note = vm.routeNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
                    .listRowBackground(Color.spCardBg)
            }
        }
    }

    // MARK: Fuel

    private var fuelSection: some View {
        Section("Fuel") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Current fuel", systemImage: "fuelpump.fill")
                        .foregroundStyle(Color.spTextSecondary)
                    Spacer()
                    Text("\(Int((vm.fuelLevel * 100).rounded()))%")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.spGold)
                }
                Slider(value: $vm.fuelLevel, in: 0...1, step: 0.05)
                    .tint(Color.spGold)
            }
            .listRowBackground(Color.spCardBg)

            stepperRow("Tank size (gal)", value: $vm.tankSize, range: 50...400, step: 10)
            decimalRow("Estimated MPG", value: $vm.mpg, range: 3...12, step: 0.1)
        }
    }

    // MARK: Preferred brands

    private var brandsSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TruckStopBrand.allCases, id: \.self) { brand in
                        let isOn = vm.preferredBrands.contains(brand)
                        Button {
                            if isOn { vm.preferredBrands.remove(brand) }
                            else { vm.preferredBrands.insert(brand) }
                        } label: {
                            Text(brand.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isOn ? .white : Color.spTextPrimary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(isOn ? brandColor(brand) : Color.spCardBg)
                                )
                                .overlay(Capsule().stroke(Color.spGold.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(Color.spCardBg)
        } header: {
            Text("Preferred Truck Stops")
        } footer: {
            Text("Fuel and rest recommendations will favor these brands when one is on your route.")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
        }
    }

    private func brandColor(_ brand: TruckStopBrand) -> Color {
        let c = brand.rgb
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    // MARK: Hours of service

    private var hoursSection: some View {
        Section {
            if advanced {
                Button {
                    Task { await vm.prefillFromMotive() }
                } label: {
                    HStack {
                        Image(systemName: motive.isConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(motive.isConnected ? Color.spGreenAccent : Color.spTextSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(motive.isConnected ? "Pull hours from Motive" : "Connect Motive to auto-fill hours")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.spTextPrimary)
                            Text(vm.motiveNote ?? (motive.isConnected ? "Reads your live HOS clocks" : "Settings → Connect Motive ELD"))
                                .font(.caption2)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                        Spacer()
                        if vm.isSyncing { ProgressView().tint(Color.spGold) }
                    }
                }
                .listRowBackground(Color.spCardBg)
                .disabled(vm.isSyncing)
            }

            decimalRow("Drive time left (11-hr)", value: $vm.driveLeft, range: 0...11, step: 0.25)
            decimalRow("Shift left (14-hr)", value: $vm.shiftLeft, range: 0...14, step: 0.25)
            if advanced {
                decimalRow("Cycle left (60/70-hr)", value: $vm.cycleLeft, range: 0...70, step: 0.5)
            }
            decimalRow("Driven since break", value: $vm.drivenSinceBreak, range: 0...8, step: 0.25)
        } header: {
            Text("Hours of Service")
        } footer: {
            Text("Enter your remaining clocks manually, or pull them from Motive. Sacred Path plans around them — Motive remains your log of record.")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
        }
    }

    // MARK: Generate

    private var generateSection: some View {
        Section {
            Button {
                focusedField = nil
                vm.generate(advanced: advanced)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Generate Trip Plan")
                        .font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(.white)
                .background(Color.spDarkGreen, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spGold.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(vm.distanceMiles <= 0)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        }
    }

    // MARK: Plan output

    private func planSection(_ plan: TripPlan) -> some View {
        Section("Your Plan") {
            // Headline metrics
            HStack(spacing: 0) {
                planMetric("\(Int(plan.distanceMiles.rounded()))", "miles")
                Divider().frame(height: 32).overlay(Color.spGold.opacity(0.2))
                planMetric(TripTime.duration(hours: plan.totalDriveHours), "driving")
                Divider().frame(height: 32).overlay(Color.spGold.opacity(0.2))
                planMetric("\(plan.fuelStopCount)", plan.fuelStopCount == 1 ? "fuel stop" : "fuel stops")
            }
            .listRowBackground(Color.spCardBg)

            // Warnings first — most important.
            ForEach(plan.warnings) { warning in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: warning.severity == .blocker ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(warning.severity == .blocker ? Color.spDanger : Color.spWarning)
                    Text(warning.message)
                        .font(.caption)
                        .foregroundStyle(Color.spTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(Color.spCardBg)
            }

            if plan.isFeasible && plan.warnings.isEmpty {
                Label("This trip can be made legally and on time.", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spGreenAccent)
                    .listRowBackground(Color.spCardBg)
            }

            // Timeline of events.
            ForEach(plan.events) { event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: event.kind.symbol)
                        .foregroundStyle(Color.spGold)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(event.kind.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.spTextPrimary)
                            Spacer()
                            Text(event.mileText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.spGold)
                        }
                        Text(shortClock(event.clockTime))
                            .font(.caption2)
                            .foregroundStyle(Color.spTextSecondary)
                        if !event.detail.isEmpty {
                            Text(event.detail)
                                .font(.caption2)
                                .foregroundStyle(Color.spTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        recommendedStopRow(event)
                    }
                }
                .listRowBackground(Color.spCardBg)
            }

            if vm.isEnriching {
                HStack(spacing: 8) {
                    ProgressView().tint(Color.spGold)
                    Text("Finding the best stops along your route…")
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary)
                }
                .listRowBackground(Color.spCardBg)
            }
        }
    }

    /// Concrete route-aware stop suggestion for a fuel/break/rest event.
    @ViewBuilder
    private func recommendedStopRow(_ event: TripPlanEvent) -> some View {
        if let name = event.recommendedStopName, event.recommendedCoordinate != nil {
            HStack(spacing: 6) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(Color.spGreenAccent)
                Text(event.recommendedStopBrand ?? name)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.spTextPrimary)
                    .lineLimit(1)
                if event.recommendedStopBrand != nil {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 3)
        }
    }

    // MARK: Copy + save

    private func handoffSection(_ plan: TripPlan) -> some View {
        Section("Save It") {
            handoffButton(vm.didCopy ? "Copied!" : "Copy Route Plan", systemImage: vm.didCopy ? "checkmark" : "doc.on.doc.fill") {
                vm.copyPlan(plan)
            }
            handoffButton(vm.didSave ? "Saved" : "Save Trip Plan", systemImage: vm.didSave ? "checkmark.circle.fill" : "tray.and.arrow.down.fill") {
                planStore.save(plan)
                vm.markSaved()
            }

            SacredPathDisclaimer(compact: true)
                .listRowBackground(Color.spCardBg)
        }
    }

    // MARK: Saved plans

    private var savedSection: some View {
        Section("Saved Trip Plans") {
            ForEach(planStore.saved) { plan in
                Button {
                    vm.plan = plan
                    vm.loadInputs(from: plan)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(plan.pickupName) → \(plan.deliveryName)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.spTextPrimary)
                                .lineLimit(1)
                            Text("\(Int(plan.distanceMiles.rounded())) mi · \(plan.events.count) stops")
                                .font(.caption2)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                        Spacer()
                        if !plan.isFeasible {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.spWarning)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.spTextSecondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { planStore.delete(plan) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .listRowBackground(Color.spCardBg)
            }
        }
    }

    // MARK: Reusable rows

    private func labeledField<Content: View>(_ title: String, systemImage: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
                content()
            }
        }
        .listRowBackground(Color.spCardBg)
    }

    private func stepperRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title).foregroundStyle(Color.spTextSecondary)
                Spacer()
                Text("\(Int(value.wrappedValue))")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.spTextPrimary)
            }
        }
        .listRowBackground(Color.spCardBg)
        .tint(Color.spGold)
    }

    private func decimalRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title).foregroundStyle(Color.spTextSecondary)
                Spacer()
                Text(String(format: "%.2g", value.wrappedValue))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.spTextPrimary)
            }
        }
        .listRowBackground(Color.spCardBg)
        .tint(Color.spGold)
    }

    private func planMetric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.spGold)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func handoffButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage).foregroundStyle(Color.spGold).frame(width: 24)
                Text(title).foregroundStyle(Color.spTextPrimary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.spTextSecondary)
            }
        }
        .listRowBackground(Color.spCardBg)
    }

    private func shortClock(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEE h:mm a"
        return df.string(from: date)
    }
}

// =============================================================================
// MARK: - View model
// =============================================================================

@MainActor
final class TripPlannerViewModel: ObservableObject {
    // Trip
    @Published var pickupName = ""
    @Published var deliveryName = ""
    @Published var pickupCoordinate: CLLocationCoordinate2D?
    @Published var deliveryCoordinate: CLLocationCoordinate2D?
    @Published var pickupDate = Date()
    @Published var deliveryDate = Date().addingTimeInterval(8 * 3600)
    @Published var distanceMiles: Double = 0

    /// Actual driving polyline from MKDirections; drives route-aware stop picks.
    @Published var routePolyline: [CLLocationCoordinate2D] = []
    /// Truck-stop brands the driver prefers; recommendations favor these.
    @Published var preferredBrands: Set<TruckStopBrand> = []
    /// True while route-corridor stop recommendations are being fetched.
    @Published var isEnriching = false

    // Fuel
    @Published var fuelLevel: Double = 0.5
    @Published var tankSize: Double = 200
    @Published var mpg: Double = 6.5

    // HOS
    @Published var driveLeft: Double = 11
    @Published var shiftLeft: Double = 14
    @Published var cycleLeft: Double = 70
    @Published var drivenSinceBreak: Double = 0

    // State
    @Published var isResolving = false
    @Published var isSyncing = false
    @Published var routeNote: String?
    @Published var motiveNote: String?
    @Published var plan: TripPlan?
    @Published var didCopy = false
    @Published var didSave = false

    // MARK: Route resolution (MKLocalSearch + MKDirections)

    func resolveRoute() async {
        let pickup = pickupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let delivery = deliveryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pickup.isEmpty, !delivery.isEmpty else {
            routeNote = "Enter both a pickup and a delivery to auto-fill distance, or type the miles in manually."
            return
        }
        isResolving = true
        routeNote = nil
        defer { isResolving = false }

        guard let p = await geocode(pickup), let d = await geocode(delivery) else {
            routeNote = "Couldn't find one of those locations. You can still type the trip distance in manually."
            return
        }
        pickupCoordinate = p
        deliveryCoordinate = d

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: p))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: d))
        request.transportType = .automobile
        if let route = try? await MKDirections(request: request).calculate(), let first = route.routes.first {
            distanceMiles = (first.distance / 1609.344).rounded()
            routePolyline = TripRouteService.coordinates(from: first.polyline)
            routeNote = "Distance auto-filled from the driving route. Adjust if your lane differs."
        } else {
            let a = CLLocation(latitude: p.latitude, longitude: p.longitude)
            let b = CLLocation(latitude: d.latitude, longitude: d.longitude)
            distanceMiles = (a.distance(from: b) / 1609.344).rounded()
            routePolyline = []
            routeNote = "Used straight-line distance (driving route unavailable). Adjust if needed."
        }
    }

    private func geocode(_ query: String) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return nil }
        return item.placemark.coordinate
    }

    // MARK: Motive prefill

    func prefillFromMotive() async {
        guard MotiveIntegrationService.shared.isConnected else {
            motiveNote = "Motive isn't connected. Add it in Settings → Connect Motive ELD."
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        if let hos = await MotiveIntegrationService.shared.prefillHOS() {
            driveLeft = hos.driveTimeLeftHours
            shiftLeft = hos.shiftTimeLeftHours
            cycleLeft = hos.cycleTimeLeftHours
            drivenSinceBreak = hos.hoursDrivenSinceBreak
            motiveNote = "Hours pulled from Motive."
        } else {
            motiveNote = "Couldn't reach Motive right now. Hours left as entered."
        }
    }

    // MARK: Generate

    func generate(advanced: Bool) {
        let hos = HOSStatus(
            driveTimeLeftHours: driveLeft,
            shiftTimeLeftHours: shiftLeft,
            cycleTimeLeftHours: advanced ? cycleLeft : max(cycleLeft, 70),
            hoursDrivenSinceBreak: drivenSinceBreak
        )
        let fuel = FuelStatus(level: fuelLevel, tankSizeGallons: tankSize, mpg: mpg)
        let req = TripPlanRequest(
            pickupName: pickupName,
            deliveryName: deliveryName,
            pickupCoordinate: pickupCoordinate,
            deliveryCoordinate: deliveryCoordinate,
            pickupDate: pickupDate,
            deliveryDate: deliveryDate,
            distanceMiles: distanceMiles,
            hos: hos,
            fuel: fuel
        )
        plan = TripPlannerEngine.plan(req)
        didCopy = false
        didSave = false

        // Route-aware step: if we have a real driving polyline, fill each fuel/
        // break/rest event with a concrete recommended stop (brand-preferred).
        guard !routePolyline.isEmpty else { return }
        let basePlan = plan
        let route = routePolyline
        let brands = preferredBrands
        isEnriching = true
        Task { [weak self] in
            let enriched = await TripRouteService.enrich(basePlan!, along: route, preferredBrands: brands)
            await MainActor.run {
                guard let self else { return }
                // Only apply if the user hasn't regenerated a different plan since.
                if self.plan?.id == basePlan?.id { self.plan = enriched }
                self.isEnriching = false
            }
        }
    }

    func loadInputs(from plan: TripPlan) {
        pickupName = plan.pickupName
        deliveryName = plan.deliveryName
        pickupDate = plan.pickupDate
        deliveryDate = plan.deliveryDate
        distanceMiles = plan.distanceMiles
    }

    func copyPlan(_ plan: TripPlan) {
        UIPasteboard.general.string = plan.summaryText()
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            didCopy = false
        }
    }

    func markSaved() {
        didSave = true
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            didSave = false
        }
    }
}

#Preview {
    NavigationStack {
        AITripPlannerView()
    }
}
