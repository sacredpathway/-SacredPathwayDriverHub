import SwiftUI
import MapKit

// =============================================================================
// MARK: - Motive Data (READ-ONLY display)
// -----------------------------------------------------------------------------
// Shows the authorized Motive data Sacred Path has synced. Pure display — no
// control, edit, or write affordances anywhere. Role scoping:
//   * driver / owner-operator → their own authorized data
//   * carrier → also a fleet-vehicles section, only when Motive authorizes it
// Any data type Motive did not authorize simply renders as unavailable.
// =============================================================================

struct MotiveDataView: View {
    var role: AccountRole = .ownerOperator

    @ObservedObject private var motive = MotiveIntegrationService.shared
    @ObservedObject private var store = MotiveSyncStore.shared

    private var snap: MotiveSnapshot { store.snapshot }

    var body: some View {
        List {
            if snap.isEmpty {
                emptyState
            } else {
                if let driver = snap.driver { driverCard(driver) }
                if let vehicle = snap.vehicle { vehicleCard(vehicle) }
                if let location = snap.location { locationCard(location) }
                if let hos = snap.hos { hosCard(hos) }
                if !snap.dvirs.isEmpty { dvirSection }
                if !snap.trips.isEmpty { tripsSection }
                if !snap.fuelEntries.isEmpty || !snap.iftaByJurisdiction.isEmpty { fuelSection }
                if role == .carrier { fleetSection }
            }
            footer
        }
        .scrollContentBackground(.hidden)
        .background(Color.spBackground)
        .navigationTitle("Motive Data")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.spGold)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await motive.syncNow(role: role) }
                } label: {
                    if motive.isSyncing { ProgressView().tint(Color.spGold) }
                    else { Image(systemName: "arrow.clockwise").foregroundStyle(Color.spGold) }
                }
                .disabled(motive.isSyncing)
            }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(Color.spTextSecondary)
                Text("No Motive data yet")
                    .font(.headline)
                    .foregroundStyle(Color.spTextPrimary)
                Text("Tap the refresh icon to sync your authorized Motive data.")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Cards

    private func driverCard(_ d: MotiveDriver) -> some View {
        Section("Driver") {
            infoRow("Name", d.displayName, "person.fill")
            if let email = d.email { infoRow("Email", email, "envelope.fill") }
            if let phone = d.phone { infoRow("Phone", phone, "phone.fill") }
            if let company = d.companyName { infoRow("Company", company, "building.2.fill") }
        }
    }

    private func vehicleCard(_ v: MotiveVehicle) -> some View {
        Section("Vehicle") {
            infoRow("Unit", v.displayName, "truck.box.fill")
            if !v.subtitle.isEmpty { infoRow("Details", v.subtitle, "info.circle.fill") }
            if let plate = v.licensePlate { infoRow("Plate", plate, "rectangle.fill") }
            if let fuel = v.fuelType { infoRow("Fuel", fuel.capitalized, "fuelpump.fill") }
        }
    }

    private func locationCard(_ loc: MotiveVehicleLocation) -> some View {
        Section("Current Location") {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: loc.coordinate,
                latitudinalMeters: 8000, longitudinalMeters: 8000
            ))) {
                Marker(snap.vehicle?.displayName ?? "Vehicle", coordinate: loc.coordinate)
                    .tint(Color.spGold)
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(false)
            .listRowBackground(Color.spCardBg)

            if let desc = loc.description { infoRow("Near", desc, "mappin.circle.fill") }
            if let speed = loc.speedMph { infoRow("Speed", "\(Int(speed.rounded())) mph", "speedometer") }
            if let fuel = loc.fuelPercent { infoRow("Fuel level", "\(Int(fuel.rounded()))%", "fuelpump.fill") }
            if let odo = loc.odometerMiles { infoRow("Odometer", "\(Int(odo.rounded())) mi", "gauge.with.dots.needle.bottom.50percent") }
            if let at = loc.locatedAt { infoRow("As of", at.formatted(date: .omitted, time: .shortened), "clock.fill") }
        }
    }

    private func hosCard(_ hos: MotiveHOSSummary) -> some View {
        Section("Hours of Service") {
            infoRow("Duty status", hos.dutyStatusDisplay, "person.badge.clock.fill")
            hosRow("Drive left (11h)", minutes: hos.driveTimeLeftMinutes)
            hosRow("Shift left (14h)", minutes: hos.shiftTimeLeftMinutes)
            hosRow("Cycle left (70h)", minutes: hos.cycleTimeLeftMinutes)
            hosRow("Until break", minutes: hos.breakTimeLeftMinutes)
        }
    }

    private var dvirSection: some View {
        Section("DVIR / Inspection") {
            ForEach(snap.dvirs) { dvir in
                HStack(spacing: 12) {
                    Image(systemName: dvir.isSafe ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(dvir.isSafe ? Color.spGreenAccent : Color.spWarning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dvir.statusDisplay)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.spTextPrimary)
                        Text([dvir.inspectionType?.replacingOccurrences(of: "_", with: "-").capitalized,
                              dvir.inspectedAt?.formatted(date: .abbreviated, time: .shortened)]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    Spacer()
                }
                .listRowBackground(Color.spCardBg)
            }
        }
    }

    private var tripsSection: some View {
        Section("Trip History") {
            ForEach(snap.trips) { trip in
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.swap")
                        .foregroundStyle(Color.spGold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(trip.startLabel ?? "Start") → \(trip.endLabel ?? "End")")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.spTextPrimary)
                            .lineLimit(1)
                        Text(trip.dateText)
                            .font(.caption2)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    Spacer()
                    if let miles = trip.distanceMiles {
                        Text("\(Int(miles.rounded())) mi")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.spGold)
                    }
                }
                .listRowBackground(Color.spCardBg)
            }
        }
    }

    private var fuelSection: some View {
        Section("Fuel / IFTA") {
            ForEach(snap.fuelEntries) { entry in
                HStack {
                    Image(systemName: "fuelpump.fill").foregroundStyle(Color.spGold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.gallons.map { String(format: "%.1f gal", $0) } ?? "—") · \(entry.jurisdiction ?? "—")")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.spTextPrimary)
                        Text(entry.date?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                            .font(.caption2)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    Spacer()
                    if let cost = entry.totalCost {
                        Text(String(format: "$%.0f", cost))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.spTextPrimary)
                    }
                }
                .listRowBackground(Color.spCardBg)
            }
            ForEach(snap.iftaByJurisdiction) { j in
                HStack {
                    Text(j.jurisdiction).font(.subheadline.weight(.bold)).foregroundStyle(Color.spGold)
                    Spacer()
                    Text("\(Int(j.miles.rounded())) mi\(j.gallons.map { " · \(Int($0.rounded())) gal" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                .listRowBackground(Color.spCardBg)
            }
        }
    }

    @ViewBuilder
    private var fleetSection: some View {
        if snap.fleetVehicles.isEmpty {
            Section("Fleet") {
                Text("No fleet vehicles authorized for your Motive account, or fleet access isn't granted.")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .listRowBackground(Color.spCardBg)
            }
        } else {
            Section("Fleet Vehicles") {
                ForEach(snap.fleetVehicles) { v in
                    HStack {
                        Image(systemName: "truck.box.fill").foregroundStyle(Color.spGold)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(Color.spTextPrimary)
                            if !v.subtitle.isEmpty {
                                Text(v.subtitle).font(.caption2).foregroundStyle(Color.spTextSecondary)
                            }
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.spCardBg)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        Section {
            Text("Read-only view. Sacred Path displays Motive data but never controls or changes anything in Motive. Motive remains your official ELD.")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
                .listRowBackground(Color.clear)
        }
    }

    // MARK: Rows

    private func infoRow(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol).foregroundStyle(Color.spTextSecondary)
            Spacer()
            Text(value).foregroundStyle(Color.spTextPrimary).lineLimit(1).truncationMode(.middle)
        }
        .listRowBackground(Color.spCardBg)
    }

    private func hosRow(_ title: String, minutes: Double?) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.spTextSecondary)
            Spacer()
            Text(minutes.map { TripTime.duration(hours: $0 / 60.0) } ?? "Not authorized")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(minutes == nil ? Color.spTextSecondary : Color.spTextPrimary)
        }
        .listRowBackground(Color.spCardBg)
    }
}

#Preview {
    NavigationStack {
        MotiveDataView()
    }
}
