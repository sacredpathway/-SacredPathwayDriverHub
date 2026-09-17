import SwiftUI

struct ComplianceHubView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var documents: [ComplianceDocument] = []
    @State private var recentInspection: DailyInspection?
    @State private var isLoading = true
    @State private var showingRoadsideMode = false
    @State private var showingAddDocument = false
    @State private var showingMissingChecklist = false

    var expiringCount: Int {
        documents.filter { $0.status() == .expiringSoon }.count
    }

    var expiredCount: Int {
        documents.filter { $0.status() == .expired }.count
    }

    var expiringDocuments: [ComplianceDocument] {
        documents
            .filter { $0.status() == .expiringSoon }
            .sorted { ($0.expirationDate ?? Date.distantFuture) < ($1.expirationDate ?? Date.distantFuture) }
    }

    var expiredDocuments: [ComplianceDocument] {
        documents
            .filter { $0.status() == .expired }
            .sorted { ($0.expirationDate ?? Date.distantPast) > ($1.expirationDate ?? Date.distantPast) }
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            NavigationStack {
                Group {
                if isLoading {
                    VStack {
                        ProgressView()
                            .tint(Color.spGold)
                    }
                } else if documents.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            // Daily Inspection quick entry — repeat-daily-use
                            // feature, kept at top for one-tap access.
                            dailyInspectionCard

                            // Roadside Mode button
                            Button(action: { showingRoadsideMode = true }) {
                                HStack {
                                    Image(systemName: "car.rear.fill")
                                        .font(.title3)
                                    Text("Roadside Mode")
                                        .font(.headline)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .padding(.horizontal, 16)
                                .background(Color.spGold)
                                .foregroundStyle(Color.spBlack)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .padding(.horizontal)
                            .padding(.top)

                            // Stats strip
                            statsStrip

                            // Expiring section
                            if !expiringDocuments.isEmpty {
                                expiringSection
                            }

                            // Expired section
                            if !expiredDocuments.isEmpty {
                                expiredSection
                            }

                            // All Documents button
                            NavigationLink(destination: ComplianceListView()) {
                                HStack {
                                    Image(systemName: "list.bullet")
                                    Text("All Documents")
                                    Spacer()
                                    Text("\(documents.count)")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                                .background(Color.spCardBg)
                                .foregroundStyle(Color.spTextPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .padding(.horizontal)

                            // Missing Documents checklist
                            NavigationLink(destination: MissingDocumentsChecklistView()) {
                                HStack {
                                    Image(systemName: "checklist")
                                    Text("Missing Documents")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                                .background(Color.spCardBg)
                                .foregroundStyle(Color.spTextPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .padding(.horizontal)
                        }
                        .padding(.vertical)
                    }
                }
                }
                .navigationTitle("Compliance Hub")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingAddDocument = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.spGold)
                                .font(.title3)
                        }
                    }
                }
                .sheet(isPresented: $showingAddDocument, onDismiss: reload) {
                    AddComplianceDocumentView()
                        .environmentObject(supabase)
                }
                .sheet(isPresented: $showingRoadsideMode) {
                    RoadsideQuickView(documents: documents)
                        .environmentObject(supabase)
                }
                .task { await loadDocuments() }
            }
        }
    }

    private var statsStrip: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Total Docs")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                Text("\(documents.count)")
                    .font(.headline)
                    .foregroundStyle(Color.spTextPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(spacing: 4) {
                Text("Expiring Soon")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                Text("\(expiringCount)")
                    .font(.headline)
                    .foregroundStyle(Color.spWarning)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(spacing: 4) {
                Text("Expired")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                Text("\(expiredCount)")
                    .font(.headline)
                    .foregroundStyle(Color.spDanger)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal)
    }

    private var expiringSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.spWarning)
                Text("Expiring Soon")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
            }
            .padding(.horizontal)

            VStack(spacing: 8) {
                ForEach(expiringDocuments) { doc in
                    NavigationLink(destination: ComplianceDocumentDetailView(document: doc)) {
                        complianceDocCard(doc)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var expiredSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.spDanger)
                Text("Expired")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
            }
            .padding(.horizontal)

            VStack(spacing: 8) {
                ForEach(expiredDocuments) { doc in
                    NavigationLink(destination: ComplianceDocumentDetailView(document: doc)) {
                        complianceDocCard(doc)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Even with no docs, the daily-inspection quick entry is
                // the most-used feature — keep it front and center.
                dailyInspectionCard
                    .padding(.top)

                VStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(Color.spTextSecondary)
                    Text("No Documents Yet")
                        .font(.headline)
                        .foregroundStyle(Color.spTextPrimary)
                    Text("Add your company, truck, trailer, and driver documents to track compliance requirements.")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button {
                        showingAddDocument = true
                    } label: {
                        Label("Add Document", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 24)
                            .background(Color.spGold)
                            .foregroundStyle(Color.spBlack)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.top, 24)
            }
        }
    }

    /// Navigation card that opens the Daily Inspection log. Summarizes the
    /// most recent inspection inline so the driver can see at a glance
    /// whether today's is already logged.
    private var dailyInspectionCard: some View {
        NavigationLink(destination: DailyInspectionListView()
            .environmentObject(supabase)
        ) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(Color.spBlack)
                    .frame(width: 44, height: 44)
                    .background(Color.spGold)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily Inspection")
                        .font(.headline)
                        .foregroundStyle(Color.spTextPrimary)
                    if let recent = recentInspection {
                        Text("Last: \(recent.typeEnum.displayName) · \(recent.inspectionDate.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                    } else {
                        Text("Log today's pre-trip or post-trip in seconds")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
            .padding(14)
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal)
    }

    private func complianceDocCard(_ doc: ComplianceDocument) -> some View {
        HStack(spacing: 12) {
            // Category icon
            if let category = ComplianceCategory(rawValue: doc.category) {
                Image(systemName: category.iconName)
                    .font(.title3)
                    .foregroundStyle(Color.spGold)
                    .frame(width: 40)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(doc.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                if let expDate = doc.expirationDate {
                    Text("Expires: \(expDate, style: .date)")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
            }

            Spacer()

            // Status badge
            let status = doc.status()
            Text(status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(status.color)
                .clipShape(Capsule())
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func loadDocuments() async {
        async let docsTask = supabase.fetchComplianceDocuments()
        async let recentTask = supabase.fetchMostRecentInspection()
        do {
            documents = try await docsTask
        } catch {
            print("Error loading documents: \(error)")
        }
        // Most-recent inspection is informational; failure shouldn't hide docs.
        recentInspection = (try? await recentTask) ?? nil
        isLoading = false
    }

    private func reload() {
        Task { await loadDocuments() }
    }
}

#Preview {
    ComplianceHubView().environmentObject(SupabaseService())
}
