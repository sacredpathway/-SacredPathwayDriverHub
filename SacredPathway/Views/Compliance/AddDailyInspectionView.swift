import SwiftUI

/// Speed-optimized inspection entry.
///
/// Flow for the common case (no defects):
///   1. Sheet opens pre-filled from yesterday's inspection + today's date.
///   2. Segmented control picks Pre / Post.
///   3. Defects toggle stays OFF.
///   4. Driver hits "Save" — done in 3–5 taps.
///
/// If defects are reported, the defect-notes and photo sections are
/// revealed. Signature is optional.
struct AddDailyInspectionView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss

    /// Seed passed in from the caller. Captures type + template inspection
    /// so defaults can be populated in one shot.
    let seed: AddInspectionSeed

    // Core fields
    @State private var inspectionDate: Date
    @State private var driverName: String
    @State private var truckNumber: String
    @State private var trailerNumber: String
    @State private var odometer: String
    @State private var inspectionType: InspectionType
    @State private var hasDefects: Bool
    @State private var defectNotes: String
    @State private var status: InspectionStatus
    @State private var signatureName: String

    @State private var isSaving = false
    @State private var errorMessage: String?

    init(seed: AddInspectionSeed) {
        self.seed = seed
        let t = seed.template

        // Defaults: date is ALWAYS today for a new inspection (even when
        // duplicating yesterday's rig info — the driver's logging TODAY).
        _inspectionDate = State(initialValue: Date())
        _driverName     = State(initialValue: t?.driverName ?? "")
        _truckNumber    = State(initialValue: t?.truckNumber ?? "")
        _trailerNumber  = State(initialValue: t?.trailerNumber ?? "")
        _odometer       = State(initialValue: "")     // odometer changes every trip; never prefill
        _inspectionType = State(initialValue: seed.type)
        _hasDefects     = State(initialValue: false)  // assume clean start; driver flips if needed
        _defectNotes    = State(initialValue: "")
        _status         = State(initialValue: .noDefects)
        _signatureName  = State(initialValue: t?.signatureName ?? "")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        typePicker
                        defectToggle
                        rigSection
                        if hasDefects {
                            defectsSection
                        }
                        detailsSection
                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Color.spDanger)
                                .padding(.horizontal)
                        }
                        saveButton
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle(seed.isDuplicate ? "Duplicate Inspection" : "New Inspection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.spGold)
                }
            }
        }
    }

    // MARK: - Sections

    private var typePicker: some View {
        Picker("Type", selection: $inspectionType) {
            ForEach(InspectionType.allCases, id: \.self) { type in
                Text(type.displayName).tag(type)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    /// Binary visual toggle. This is the single most important control on
    /// the screen — a large No-Defects / Defects-Found button pair so the
    /// driver can complete the form without fiddly switches.
    private var defectToggle: some View {
        HStack(spacing: 10) {
            defectChoiceButton(label: "No Defects", systemImage: "checkmark.circle.fill",
                               isSelected: !hasDefects, accent: Color.spSuccess) {
                hasDefects = false
                status = .noDefects
            }
            defectChoiceButton(label: "Defects Found", systemImage: "exclamationmark.triangle.fill",
                               isSelected: hasDefects, accent: Color.spDanger) {
                hasDefects = true
                if status == .noDefects { status = .defectsFound }
            }
        }
        .padding(.horizontal)
    }

    private func defectChoiceButton(label: String, systemImage: String, isSelected: Bool, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.title)
                Text(label).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isSelected ? accent : Color.spCardBg)
            .foregroundStyle(isSelected ? .white : Color.spTextSecondary)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? accent : Color.clear, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var rigSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Rig", icon: "truck.box.fill")
            VStack(spacing: 10) {
                labeledField("Truck #", placeholder: "e.g. 204", text: $truckNumber, keyboard: .default)
                labeledField("Trailer #", placeholder: "e.g. T-33", text: $trailerNumber, keyboard: .default)
                labeledField("Odometer", placeholder: "miles", text: $odometer, keyboard: .numberPad)
            }
            .padding(.horizontal)
        }
    }

    private var defectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Defects", icon: "exclamationmark.triangle.fill")

            // Status picker — only relevant when defects exist.
            Picker("Status", selection: $status) {
                ForEach([InspectionStatus.defectsFound, .repaired, .needsRepair], id: \.self) { s in
                    Text(s.displayName).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes (optional)")
                    .font(.caption).foregroundStyle(Color.spTextSecondary)
                TextEditor(text: $defectNotes)
                    .frame(minHeight: 90)
                    .padding(8)
                    .background(Color.spCardBg)
                    .foregroundStyle(Color.spTextPrimary)
                    .scrollContentBackground(.hidden)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal)
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Details", icon: "person.crop.circle.fill")
            VStack(spacing: 10) {
                labeledField("Driver Name", placeholder: "", text: $driverName, keyboard: .default)
                labeledField("Signature (optional)", placeholder: "Full name", text: $signatureName, keyboard: .default)
            }
            .padding(.horizontal)

            DatePicker("Inspection Date", selection: $inspectionDate, displayedComponents: .date)
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
                .padding(12)
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
        }
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            HStack {
                if isSaving {
                    ProgressView().tint(Color.spBlack)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                }
                Text(isSaving ? "Saving…" : "Save Inspection")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.spGold)
            .foregroundStyle(Color.spBlack)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(isSaving)
        .padding(.horizontal)
    }

    // MARK: - Form primitives

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(Color.spGold)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
        }
        .padding(.horizontal)
    }

    private func labeledField(_ label: String, placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
                .padding(12)
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Save

    private func save() async {
        guard let profileId = supabase.currentProfile?.id else {
            errorMessage = "Not signed in"
            return
        }

        isSaving = true
        errorMessage = nil

        let inspection = DailyInspection(
            profileId: profileId,
            inspectionDate: inspectionDate,
            driverName: driverName.isEmpty ? nil : driverName,
            truckNumber: truckNumber.isEmpty ? nil : truckNumber,
            trailerNumber: trailerNumber.isEmpty ? nil : trailerNumber,
            odometer: Int(odometer.trimmingCharacters(in: .whitespaces)),
            inspectionType: inspectionType.rawValue,
            hasDefects: hasDefects,
            defectNotes: (hasDefects && !defectNotes.isEmpty) ? defectNotes : nil,
            status: status.rawValue,
            signatureName: signatureName.isEmpty ? nil : signatureName,
            signedAt: signatureName.isEmpty ? nil : Date(),
            photoPaths: nil
        )

        do {
            _ = try await supabase.createDailyInspection(inspection)
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(String(describing: error))"
            #if DEBUG
            print("[AddDailyInspectionView] save failed: \(error)")
            #endif
        }

        isSaving = false
    }
}

#Preview {
    AddDailyInspectionView(seed: AddInspectionSeed(type: .preTrip, template: nil, isDuplicate: false))
        .environmentObject(SupabaseService())
}
