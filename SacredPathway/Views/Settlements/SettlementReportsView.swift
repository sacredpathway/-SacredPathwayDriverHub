import SwiftUI

// =============================================================================
//  SettlementReportsView — driver earnings, history, revenue, expenses,
//  advances, lease operator reports with PDF and CSV export
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). Report rows come from SettlementInsights; the
//  PDF uses the same HTML renderer as the statement.
// =============================================================================

struct SettlementReportsView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var repo = SettlementRepository.shared
    @ObservedObject private var payWeek = PayWeekService.shared

    @State private var kind: SettlementReportKind = .driverEarnings
    @State private var preset: SettlementDateRangePreset = .thisMonth
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var driverId: UUID?
    @State private var expenses: [Expense] = []
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var alert: SettlementAlert?

    private var range: SettlementDateRange {
        SettlementDateRange.preset(
            preset, firstWeekday: payWeek.firstWeekday,
            custom: SettlementDateRange(start: min(customStart, customEnd), end: max(customStart, customEnd)))
    }

    private var report: SettlementReport {
        SettlementInsights.report(
            kind,
            ledger: SettlementPermissions.scopedLedger(repo.ledger, viewer: repo.viewer),
            range: range,
            driverNames: repo.driverNames,
            expenses: expenses,
            driverId: driverId)
    }

    private var fileStem: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "\(kind.displayName.replacingOccurrences(of: " ", with: "-"))-\(f.string(from: range.start))-to-\(f.string(from: range.end))"
    }

    var body: some View {
        let current = report
        List {
            Section {
                Picker("Report", selection: $kind) {
                    ForEach(SettlementReportKind.allCases) { k in
                        Label(k.displayName, systemImage: k.systemImage).tag(k)
                    }
                }
                Picker("Date range", selection: $preset) {
                    ForEach(SettlementDateRangePreset.allCases) { Text($0.displayName).tag($0) }
                }
                if preset == .custom {
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date)
                }
                Picker("Driver", selection: $driverId) {
                    Text("All Drivers").tag(UUID?.none)
                    ForEach(repo.drivers, id: \.id) { Text($0.name).tag($0.id) }
                }
            } footer: {
                Text(current.subtitle)
            }
            .listRowBackground(Color.spCardBg)

            Section {
                if repo.viewer.can(.export) {
                    Button {
                        Task { await exportPDF(current) }
                    } label: {
                        Label(isExporting ? "Preparing…" : "Export PDF", systemImage: "doc.richtext")
                    }
                    .disabled(isExporting)
                    Button {
                        exportCSV(current)
                    } label: {
                        Label("Export CSV", systemImage: "tablecells")
                    }
                } else {
                    Text("Your role can view but not export reports.")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
            }
            .listRowBackground(Color.spCardBg)

            Section {
                if current.rows.isEmpty {
                    Text("No records in this range.")
                        .foregroundStyle(Color.spTextSecondary)
                }
                ForEach(Array(current.rows.enumerated()), id: \.offset) { pair in
                    ReportRowView(columns: current.columns, cells: pair.element,
                                  numeric: current.numericColumns)
                }
                if let totals = current.totals, !current.rows.isEmpty {
                    ReportRowView(columns: current.columns, cells: totals,
                                  numeric: current.numericColumns, isTotal: true)
                }
            } header: {
                Text("\(current.rows.count) row\(current.rows.count == 1 ? "" : "s")")
            }
            .listRowBackground(Color.spCardBg)
        }
        .scrollContentBackground(.hidden)
        .background(Color.spBackground)
        .navigationTitle("Reports")
        .sheet(item: Binding(
            get: { exportURL.map { IdentifiedURL(url: $0) } },
            set: { exportURL = $0?.url })
        ) { item in
            ReportExportSheet(url: item.url)
        }
        .alert(item: $alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
        .task {
            repo.attach(supabase)
            expenses = await repo.expenses()
        }
        .onDisappear { SettlementPDFExporter.cleanupTemporaryFiles() }
    }

    private func exportPDF(_ report: SettlementReport) async {
        isExporting = true
        defer { isExporting = false }
        do {
            let data = try await SettlementPDFExporter.reportPDF(report, company: repo.company)
            exportURL = try SettlementPDFExporter.temporaryFile(data, named: "\(fileStem).pdf")
        } catch {
            alert = SettlementAlert(error: error)
        }
    }

    private func exportCSV(_ report: SettlementReport) {
        do {
            let data = Data(SettlementInsights.csv(report).utf8)
            exportURL = try SettlementPDFExporter.temporaryFile(data, named: "\(fileStem).csv")
        } catch {
            alert = SettlementAlert(error: error)
        }
    }
}

private struct ReportRowView: View {
    let columns: [String]
    let cells: [String]
    let numeric: Set<Int>
    var isTotal: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cells.first ?? "")
                .font(isTotal ? .subheadline.weight(.heavy) : .subheadline.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
            ForEach(Array(cells.enumerated().dropFirst()), id: \.offset) { pair in
                let index = pair.offset
                let cell = pair.element
                if !cell.isEmpty {
                    HStack {
                        Text(index < columns.count ? columns[index] : "")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                        Spacer()
                        Text(cell)
                            .font(numeric.contains(index)
                                  ? .system(.caption, design: .monospaced).weight(.semibold)
                                  : .caption)
                            .foregroundStyle(Color.spTextPrimary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ReportExportSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: url.pathExtension == "csv" ? "tablecells" : "doc.richtext")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.spGold)
                Text(url.lastPathComponent)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                ShareLink(item: url) {
                    Label("Share / Save to Files", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.spGold)
                        .foregroundStyle(Color.spBlack)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if url.pathExtension == "pdf", let data = try? Data(contentsOf: url) {
                    Button {
                        SettlementPDFExporter.print(data, jobName: url.lastPathComponent)
                    } label: {
                        Label("Print", systemImage: "printer")
                    }
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}
