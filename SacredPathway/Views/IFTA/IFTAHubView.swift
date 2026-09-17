import SwiftUI

struct IFTAHubView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var entries: [IFTAEntry] = []
    @State private var selectedQuarter: IFTAQuarter = .q1(year: 2026)
    @State private var quartersList: [IFTAQuarter] = []
    @State private var isLoading = true
    @State private var showingAddEntry = false

    // PDF export state
    @State private var pdfData: Data?
    @State private var showingShareSheet = false
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var truckNumber: String = ""
    @State private var notes: String = ""

    var summary: IFTASummary? {
        IFTACalculator.summarize(entries: entries, forQuarter: selectedQuarter)
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
                } else if entries.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            // Quarter picker
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Quarter")
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextSecondary)
                                    .padding(.horizontal)

                                Picker("Quarter", selection: $selectedQuarter) {
                                    ForEach(quartersList, id: \.self) { q in
                                        Text(q.label).tag(q)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .tint(Color.spGold)
                                .padding(.horizontal)
                            }

                            // Summary cards
                            if let summary = summary {
                                summaryCards(summary)

                                // State breakdown
                                stateBreakdown(summary)
                            }

                            // Add entry button
                            Button(action: { showingAddEntry = true }) {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Add Entry")
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                                .background(Color.spGold)
                                .foregroundStyle(Color.spBlack)
                                .font(.headline)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .padding(.horizontal)

                            // View Report button
                            NavigationLink(destination: IFTAReportView(summary: summary)) {
                                HStack {
                                    Image(systemName: "doc.text.fill")
                                    Text("View Report")
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                                .background(Color.spCardBg)
                                .foregroundStyle(Color.spTextPrimary)
                                .font(.headline)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .padding(.horizontal)

                            // Export PDF button — generates a quarterly
                            // worksheet, presents the share sheet, AND
                            // saves a copy to the Document Vault.
                            if let summary = summary {
                                Button {
                                    Task { await exportPDF(summary: summary) }
                                } label: {
                                    HStack {
                                        if isExporting {
                                            ProgressView().tint(Color.spBlack)
                                        } else {
                                            Image(systemName: "square.and.arrow.up.fill")
                                        }
                                        Text(isExporting ? "Generating PDF…" : "Export IFTA PDF")
                                        Spacer()
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 16)
                                    .background(Color.spGreenAccent)
                                    .foregroundStyle(.white)
                                    .font(.headline)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .disabled(isExporting)
                                .padding(.horizontal)

                                if let err = exportError {
                                    Text(err)
                                        .font(.caption)
                                        .foregroundStyle(Color.spDanger)
                                        .padding(.horizontal)
                                }
                            }
                        }
                        .padding(.vertical)
                    }
                }
                }
                .navigationTitle("IFTA Calculator")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingAddEntry = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.spGold)
                                .font(.title3)
                        }
                    }
                }
                .sheet(isPresented: $showingAddEntry, onDismiss: reload) {
                    AddIFTAEntryView()
                        .environmentObject(supabase)
                }
                .sheet(isPresented: $showingShareSheet) {
                    if let data = pdfData {
                        ShareSheet(items: [data])
                    }
                }
                .task { await loadEntries() }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "fuelpump.fill")
                .font(.system(size: 50))
                .foregroundStyle(Color.spTextSecondary)
            Text("No IFTA Entries Yet")
                .font(.headline)
                .foregroundStyle(Color.spTextPrimary)
            Text("Track your interstate miles and fuel purchases for IFTA reporting.")
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showingAddEntry = true
            } label: {
                Label("Add Entry", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 24)
                    .background(Color.spGold)
                    .foregroundStyle(Color.spBlack)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func summaryCards(_ summary: IFTASummary) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                summaryCard("Total Miles", value: String(format: "%.0f", summary.totalMiles), icon: "road.lanes")
                summaryCard("Total Gallons", value: String(format: "%.1f", summary.totalGallons), icon: "fuelpump.fill")
                summaryCard("Avg MPG", value: String(format: "%.1f", summary.averageMPG), icon: "speedometer")
            }
        }
        .padding(.horizontal)
    }

    private func summaryCard(_ label: String, value: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.spGold)
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(Color.spTextPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func stateBreakdown(_ summary: IFTASummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "map.fill")
                    .foregroundStyle(Color.spGold)
                Text("By State")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
            }
            .padding(.horizontal)

            VStack(spacing: 8) {
                ForEach(summary.statesummaries, id: \.stateCode) { state in
                    stateRow(state)
                }
            }
            .padding(.horizontal)
        }
    }

    private func stateRow(_ state: StateIFTASummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.stateCode)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text(state.stateName)
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.0f mi", state.miles))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text(String(format: "%.1f gal", state.gallons))
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func loadEntries() async {
        do {
            entries = try await supabase.fetchIFTAEntries()
            quartersList = availableQuarters(from: entries)
            if !quartersList.isEmpty {
                selectedQuarter = quartersList.first ?? .q1(year: 2026)
            }
        } catch {
            print("Error loading entries: \(error)")
        }
        isLoading = false
    }

    private func reload() {
        Task { await loadEntries() }
    }

    /// Generate an IFTA quarterly PDF for the currently-selected quarter,
    /// share it via the system share sheet, and save a copy to the
    /// Document Vault under documentType="ifta_report".
    @MainActor
    private func exportPDF(summary: IFTASummary) async {
        isExporting = true
        exportError = nil
        defer { isExporting = false }

        let profile = supabase.currentProfile
        let branding = BrandingService.shared

        do {
            let data = try IFTAPDFService.generateQuarterlyReport(
                summary: summary,
                companyName: profile?.companyName ?? "Sacred Pathway LLC",
                mcNumber: profile?.mcNumber,
                dotNumber: profile?.dotNumber,
                truckNumber: truckNumber.isEmpty ? nil : truckNumber,
                driverName: nil,
                notes: notes.isEmpty ? nil : notes,
                logo: branding.logoImage,
                primaryColor: UIColor(branding.primaryColor)
            )
            pdfData = data
            showingShareSheet = true

            // Save to vault — fire and forget; failure here doesn't
            // block the user from sharing the PDF they just generated.
            Task {
                let title = "IFTA \(summary.quarter.label)"
                _ = try? await supabase.saveDocumentRecord(
                    pdfData: data,
                    documentType: "ifta_report",
                    title: title,
                    loadId: nil
                )
            }
        } catch {
            exportError = "PDF error: \(error.localizedDescription)"
        }
    }
}

#Preview {
    IFTAHubView().environmentObject(SupabaseService())
}
