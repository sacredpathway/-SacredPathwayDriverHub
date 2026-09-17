import SwiftUI

/// Daily Inspection log. Optimized for the "open app, log today's inspection,
/// get back to driving" flow:
///   • Two big gold buttons at the top — Start Today's Pre-Trip / Post-Trip
///   • "Duplicate Last" one-tap clone for drivers running the same rig
///   • Most-recent inspection surfaced prominently so yesterday's values
///     are visible and re-usable without digging through a list.
struct DailyInspectionListView: View {
    @EnvironmentObject var supabase: SupabaseService

    @State private var inspections: [DailyInspection] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    // Sheet state — we drive Add via an item binding so prefill state
    // is captured atomically rather than through a shared @State bag.
    @State private var addSeed: AddInspectionSeed?

    private var mostRecent: DailyInspection? { inspections.first }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            if isLoading {
                ProgressView().tint(Color.spGold)
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        quickActions
                        if let recent = mostRecent {
                            mostRecentCard(recent)
                        }
                        if inspections.isEmpty {
                            emptyState
                        } else {
                            historySection
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .navigationTitle("Daily Inspection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { startNew(type: .preTrip) } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.spGold)
                        .font(.title3)
                }
            }
        }
        .sheet(item: $addSeed, onDismiss: reload) { seed in
            AddDailyInspectionView(seed: seed)
                .environmentObject(supabase)
        }
        .task { await loadInspections() }
    }

    // MARK: - Quick actions (primary path)

    private var quickActions: some View {
        VStack(spacing: 10) {
            Button { startNew(type: .preTrip) } label: {
                quickActionLabel(title: "Start Today's Pre-Trip", icon: "sunrise.fill")
            }
            Button { startNew(type: .postTrip) } label: {
                quickActionLabel(title: "Start Today's Post-Trip", icon: "sunset.fill")
            }
            if let recent = mostRecent {
                Button { duplicate(recent) } label: {
                    HStack {
                        Image(systemName: "doc.on.doc.fill")
                        Text("Duplicate Last Inspection")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .background(Color.spCardBg)
                    .foregroundStyle(Color.spTextPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(.horizontal)
    }

    private func quickActionLabel(title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.headline)
            Spacer()
            Image(systemName: "arrow.right.circle.fill").font(.title3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .background(Color.spGold)
        .foregroundStyle(Color.spBlack)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Most recent card (fast visual recap)

    private func mostRecentCard(_ recent: DailyInspection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "clock.fill").foregroundStyle(Color.spGold)
                Text("Most Recent")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Spacer()
                statusBadge(recent.statusEnum)
            }

            NavigationLink(destination: DailyInspectionDetailView(inspection: recent)
                .environmentObject(supabase)
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(recent.typeEnum.displayName)
                            .font(.headline).foregroundStyle(Color.spTextPrimary)
                        Text("·")
                            .foregroundStyle(Color.spTextSecondary)
                        Text(recent.inspectionDate, style: .date)
                            .font(.subheadline).foregroundStyle(Color.spTextSecondary)
                    }
                    if let truck = recent.truckNumber, !truck.isEmpty {
                        Text("Truck #\(truck)\(recent.trailerNumber.flatMap { $0.isEmpty ? nil : "  ·  Trailer #\($0)" } ?? "")")
                            .font(.caption).foregroundStyle(Color.spTextSecondary)
                    }
                    if let driver = recent.driverName, !driver.isEmpty {
                        Text("Driver: \(driver)")
                            .font(.caption).foregroundStyle(Color.spTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    // MARK: - History list

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "list.bullet").foregroundStyle(Color.spGold)
                Text("History")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Spacer()
                Text("\(inspections.count)")
                    .font(.caption).foregroundStyle(Color.spTextSecondary)
            }
            .padding(.horizontal)

            VStack(spacing: 8) {
                ForEach(inspections) { inspection in
                    NavigationLink(destination: DailyInspectionDetailView(inspection: inspection)
                        .environmentObject(supabase)
                    ) {
                        historyRow(inspection)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func historyRow(_ inspection: DailyInspection) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(inspection.typeEnum.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text(inspection.inspectionDate, style: .date)
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
            Spacer()
            statusBadge(inspection.statusEnum)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func statusBadge(_ status: InspectionStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.iconName).font(.caption2)
            Text(status.displayName).font(.caption.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(status.color)
        .clipShape(Capsule())
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 44))
                .foregroundStyle(Color.spTextSecondary)
            Text("No Inspections Logged Yet")
                .font(.headline)
                .foregroundStyle(Color.spTextPrimary)
            Text("Tap a button above to log your first pre-trip or post-trip.")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 30)
    }

    // MARK: - Actions

    private func startNew(type: InspectionType) {
        addSeed = AddInspectionSeed(type: type, template: mostRecent, isDuplicate: false)
    }

    private func duplicate(_ inspection: DailyInspection) {
        addSeed = AddInspectionSeed(type: inspection.typeEnum, template: inspection, isDuplicate: true)
    }

    // MARK: - Data

    private func loadInspections() async {
        do {
            inspections = try await supabase.fetchDailyInspections()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            #if DEBUG
            print("[DailyInspectionListView] load failed: \(error)")
            #endif
        }
        isLoading = false
    }

    private func reload() {
        Task { await loadInspections() }
    }
}

/// Struct that seeds the Add form with defaults. Passing an Identifiable
/// item into `.sheet(item:)` lets SwiftUI present the sheet once the seed
/// is non-nil and dismiss it by setting it back to nil.
struct AddInspectionSeed: Identifiable {
    let id = UUID()
    let type: InspectionType
    let template: DailyInspection?
    let isDuplicate: Bool
}

#Preview {
    NavigationStack {
        DailyInspectionListView()
            .environmentObject(SupabaseService())
    }
}
