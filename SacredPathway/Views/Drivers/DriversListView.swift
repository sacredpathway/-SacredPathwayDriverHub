import SwiftUI

struct DriversListView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var drivers: [Driver] = []
    @State private var isLoading = true
    @State private var showingAddDriver = false

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            NavigationStack {
                VStack(spacing: 0) {
                    if isLoading {
                        Spacer()
                        ProgressView().tint(Color.spGold)
                        Spacer()
                    } else if drivers.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "person.3.fill").font(.system(size: 48)).foregroundStyle(Color.spTextSecondary)
                            Text("No drivers yet").font(.headline).foregroundStyle(Color.spTextSecondary)
                            Text("Add drivers to assign loads and generate individual settlements")
                                .font(.subheadline).foregroundStyle(Color.spTextSecondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                            Button {
                                showingAddDriver = true
                            } label: {
                                Label("Add First Driver", systemImage: "person.badge.plus")
                                    .font(.headline).padding(.vertical, 12).padding(.horizontal, 24)
                                    .background(Color.spGold).foregroundStyle(Color.spBlack)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        Spacer()
                    } else {
                        List {
                            ForEach(drivers) { driver in
                                driverRow(driver)
                                    .listRowBackground(Color.spCardBg)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
                .navigationTitle("Drivers")
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingAddDriver = true } label: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(Color.spGold).font(.title3)
                        }
                    }
                }
                .sheet(isPresented: $showingAddDriver) {
                    AddDriverView { newDriver in
                        drivers.append(newDriver)
                    }
                    .environmentObject(supabase)
                }
                .task { await loadDrivers() }
            }
        }
    }

    private func driverRow(_ driver: Driver) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.spGold.opacity(0.15)).frame(width: 48, height: 48)
                Image(systemName: "person.fill").foregroundStyle(Color.spGold).font(.title3)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(driver.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.spTextPrimary)
                HStack(spacing: 12) {
                    if let truck = driver.truckNumber {
                        Label(truck, systemImage: "truck.box.fill").font(.caption).foregroundStyle(Color.spTextSecondary)
                    }
                    if let pct = driver.payPercentage {
                        Label("\(Int(pct))%", systemImage: "percent").font(.caption).foregroundStyle(Color.spGold)
                    }
                }
            }
            Spacer()
            if driver.active == true {
                Text("Active").font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.spSuccess.opacity(0.2)).foregroundStyle(Color.spSuccess).clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    private func loadDrivers() async {
        do { drivers = try await supabase.fetchDrivers() } catch { print("Error: \(error)") }
        isLoading = false
    }
}

struct AddDriverView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    let onSave: (Driver) -> Void

    @State private var name = ""
    @State private var truckNumber = ""
    @State private var payPercentage = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        field("Driver Name", text: $name, icon: "person.fill")
                        field("Truck Number", text: $truckNumber, icon: "truck.box.fill")
                        field("Pay Percentage", text: $payPercentage, icon: "percent", keyboard: .decimalPad)
                        field("Phone", text: $phone, icon: "phone.fill", keyboard: .phonePad)
                        field("Email", text: $email, icon: "envelope.fill", keyboard: .emailAddress)

                        if let error = errorMessage {
                            Text(error).font(.caption).foregroundStyle(Color.spDanger)
                        }

                        Button {
                            Task { await save() }
                        } label: {
                            HStack {
                                if isSaving { ProgressView().tint(Color.spBlack) }
                                Text(isSaving ? "Saving..." : "Add Driver")
                            }
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.spGold).foregroundStyle(Color.spBlack)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(name.isEmpty || isSaving)
                    }
                    .padding()
                }
            }
            .navigationTitle("Add Driver")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Color.spGold)
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, icon: String, keyboard: UIKeyboardType = .default) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.spGold).frame(width: 24)
            TextField(label, text: text).keyboardType(keyboard).foregroundStyle(Color.spTextPrimary)
        }
        .padding(12).background(Color.spCardBg).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func save() async {
        guard let profileId = supabase.currentProfile?.id else { errorMessage = "Not signed in"; return }
        isSaving = true
        let driver = Driver(profileId: profileId, name: name, truckNumber: truckNumber.isEmpty ? nil : truckNumber,
                           payPercentage: Double(payPercentage), phone: phone.isEmpty ? nil : phone,
                           email: email.isEmpty ? nil : email, active: true)
        do {
            let created = try await supabase.createDriver(driver)
            onSave(created)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
        isSaving = false
    }
}
