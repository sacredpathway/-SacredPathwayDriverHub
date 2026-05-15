import SwiftUI

/// Read-only detail for a saved inspection. Status is front-and-center so
/// a roadside inspector / auditor can see the outcome immediately.
struct DailyInspectionDetailView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss

    let inspection: DailyInspection

    @State private var showingDeleteConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header
                    rigCard
                    defectsCard
                    detailsCard
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color.spDanger)
                    }
                    deleteButton
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("Inspection")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this inspection?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteInspection() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text(inspection.typeEnum.displayName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.spTextPrimary)
                Spacer()
                statusBadge
            }
            HStack {
                Image(systemName: "calendar").foregroundStyle(Color.spTextSecondary)
                Text(inspection.inspectionDate, style: .date)
                    .font(.subheadline).foregroundStyle(Color.spTextSecondary)
                Spacer()
            }
        }
        .padding(14)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: inspection.statusEnum.iconName)
                .font(.caption)
            Text(inspection.statusEnum.displayName)
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(inspection.statusEnum.color)
        .clipShape(Capsule())
    }

    private var rigCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Rig", icon: "truck.box.fill")
            if let truck = inspection.truckNumber, !truck.isEmpty {
                detailRow(label: "Truck #", value: truck)
            }
            if let trailer = inspection.trailerNumber, !trailer.isEmpty {
                detailRow(label: "Trailer #", value: trailer)
            }
            if let odometer = inspection.odometer {
                detailRow(label: "Odometer", value: "\(odometer) mi")
            }
            if inspection.truckNumber == nil && inspection.trailerNumber == nil && inspection.odometer == nil {
                Text("No rig details recorded.")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var defectsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Defects", icon: inspection.hasDefects ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            if inspection.hasDefects {
                detailRow(label: "Status", value: inspection.statusEnum.displayName)
                if let notes = inspection.defectNotes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes")
                            .font(.caption).foregroundStyle(Color.spTextSecondary)
                        Text(notes)
                            .font(.subheadline).foregroundStyle(Color.spTextPrimary)
                    }
                }
                if let photos = inspection.photoPaths, !photos.isEmpty {
                    detailRow(label: "Photos", value: "\(photos.count) attached")
                }
            } else {
                Text("No defects reported.")
                    .font(.subheadline).foregroundStyle(Color.spTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Driver", icon: "person.crop.circle.fill")
            if let driver = inspection.driverName, !driver.isEmpty {
                detailRow(label: "Name", value: driver)
            }
            if let signature = inspection.signatureName, !signature.isEmpty {
                detailRow(label: "Signed By", value: signature)
                if let signedAt = inspection.signedAt {
                    detailRow(label: "Signed At", value: signedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if let createdAt = inspection.createdAt {
                detailRow(label: "Logged At", value: createdAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showingDeleteConfirm = true
        } label: {
            HStack {
                if isDeleting {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "trash.fill")
                }
                Text("Delete Inspection").font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.spDanger.opacity(0.15))
            .foregroundStyle(Color.spDanger)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isDeleting)
        .padding(.horizontal)
    }

    // MARK: - Primitives

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(Color.spGold)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption).foregroundStyle(Color.spTextSecondary)
            Spacer()
            Text(value)
                .font(.subheadline).foregroundStyle(Color.spTextPrimary)
        }
    }

    // MARK: - Actions

    private func deleteInspection() async {
        guard let id = inspection.id else { return }
        isDeleting = true
        do {
            try await supabase.deleteDailyInspection(id: id)
            dismiss()
        } catch {
            errorMessage = "Failed to delete: \(error.localizedDescription)"
            #if DEBUG
            print("[DailyInspectionDetailView] delete failed: \(error)")
            #endif
            isDeleting = false
        }
    }
}

#Preview {
    NavigationStack {
        DailyInspectionDetailView(inspection: DailyInspection(
            profileId: UUID(),
            inspectionDate: Date(),
            driverName: "Demarquis",
            truckNumber: "204",
            trailerNumber: "T-33",
            odometer: 184_521,
            inspectionType: InspectionType.preTrip.rawValue,
            hasDefects: false,
            status: InspectionStatus.noDefects.rawValue
        ))
        .environmentObject(SupabaseService())
    }
}
