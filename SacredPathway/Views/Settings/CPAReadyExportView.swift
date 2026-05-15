import SwiftUI
import UIKit

// =============================================================================
// MARK: - CPAReadyExportView
// =============================================================================
//
// Premium SwiftUI screen for the "CPA Ready Tax Package" feature. Lives
// under Settings → Financial. The view orchestrates:
//   1. Date-range preset selection + optional custom range
//   2. Per-section toggles
//   3. Generate action that calls CPAExportService.buildPackage(...)
//   4. Share-sheet hand-off of the resulting PDF / CSV / ZIP
//
// Style notes — matches the rest of Driver Hub:
//   • Color.spBackground / spCardBg / spGold / spTextPrimary / spTextSecondary
//   • Hero card with gold accent + system "doc.badge.gearshape" glyph
//   • Section cards with rounded 12pt corners and 16pt padding
// =============================================================================

struct CPAReadyExportView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss

    @State private var preset: CPADateRangePreset = .yearToDate
    @State private var customStart: Date = {
        let cal = Calendar.iso8601US
        let y = cal.component(.year, from: Date())
        return cal.date(from: DateComponents(year: y, month: 1, day: 1)) ?? Date()
    }()
    @State private var customEnd: Date = Date()

    @State private var toggles: CPAExportToggles = .allOn
    @State private var format: CPAExportFormat = .zip

    @State private var isGenerating: Bool = false
    @State private var errorMessage: String?
    @State private var shareItem: CPAShareItem?

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    heroCard
                    dateRangeCard
                    toggleCard
                    formatCard
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(Color.spDanger)
                            .padding(.horizontal)
                    }
                    generateButton
                    disclaimerCard
                }
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("CPA Ready Tax Package")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.spBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(item: $shareItem) { item in
            CPAShareSheet(items: item.items)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - Hero card

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.spGold.opacity(0.18))
                        .frame(width: 64, height: 64)
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Color.spGold)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("CPA Ready Tax Package")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.spTextPrimary)
                    Text("Generate organized write-off reports for your accountant.")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                }
                Spacer(minLength: 0)
            }

            // Document-style illustration: stylized stacked pages with gold accent.
            documentIllustration
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            Text("Tax season • Audits • Bookkeeping • Quarterly taxes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.spGoldLight)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.spGold.opacity(0.14))
                .clipShape(Capsule())
        }
        .padding(16)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private var documentIllustration: some View {
        ZStack {
            // back page
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.spCardBgLight)
                .frame(width: 110, height: 140)
                .offset(x: 10, y: 6)
                .rotationEffect(.degrees(-4))
            // mid page
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.spCardBgLight)
                .frame(width: 110, height: 140)
                .offset(x: 4, y: 3)
                .rotationEffect(.degrees(-2))
            // top page
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Circle().fill(Color.spGold).frame(width: 6, height: 6)
                    Rectangle().fill(Color.spTextPrimary.opacity(0.5))
                        .frame(width: 50, height: 4)
                }
                Rectangle().fill(Color.spTextPrimary.opacity(0.25))
                    .frame(width: 80, height: 3)
                Rectangle().fill(Color.spTextPrimary.opacity(0.25))
                    .frame(width: 70, height: 3)
                Spacer().frame(height: 6)
                ForEach(0..<5, id: \.self) { i in
                    HStack(spacing: 6) {
                        Rectangle().fill(Color.spTextPrimary.opacity(0.5))
                            .frame(width: 38, height: 3)
                        Spacer()
                        Rectangle().fill(Color.spGold.opacity(i == 0 ? 1 : 0.5))
                            .frame(width: 22, height: 3)
                    }
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 110, height: 140, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.95))
            )
        }
        .frame(height: 150)
    }

    // MARK: - Date range card

    private var dateRangeCard: some View {
        sectionCard("Date Range") {
            VStack(spacing: 10) {
                ForEach(CPADateRangePreset.allCases) { p in
                    rangeRow(preset: p)
                }
                if preset == .custom {
                    Divider().background(Color.spCardBgLight).padding(.vertical, 4)
                    DatePicker("Start",
                               selection: $customStart,
                               displayedComponents: .date)
                        .foregroundStyle(Color.spTextPrimary)
                        .colorScheme(.dark)
                    DatePicker("End",
                               selection: $customEnd,
                               displayedComponents: .date)
                        .foregroundStyle(Color.spTextPrimary)
                        .colorScheme(.dark)
                }
            }
        }
    }

    private func rangeRow(preset p: CPADateRangePreset) -> some View {
        let selected = preset == p
        return Button {
            preset = p
        } label: {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.spGold : Color.spTextSecondary)
                Text(p.displayName)
                    .foregroundStyle(Color.spTextPrimary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toggle card

    private var toggleCard: some View {
        sectionCard("Include in Export") {
            VStack(spacing: 10) {
                toggleRow("Settlements",      isOn: $toggles.settlements)
                toggleRow("Expenses",         isOn: $toggles.expenses)
                toggleRow("Fuel",             isOn: $toggles.fuel)
                toggleRow("Maintenance",      isOn: $toggles.maintenance)
                toggleRow("Tolls",            isOn: $toggles.tolls)
                toggleRow("Mileage Summary",  isOn: $toggles.mileageSummary)
                toggleRow("Broker Payments",  isOn: $toggles.brokerPayments)
                toggleRow("Receipts Metadata", isOn: $toggles.receiptsMetadata)
            }
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label).foregroundStyle(Color.spTextPrimary)
        }
        .tint(Color.spGold)
    }

    // MARK: - Format card

    private var formatCard: some View {
        sectionCard("Export Format") {
            VStack(spacing: 10) {
                ForEach(CPAExportFormat.allCases) { f in
                    Button {
                        format = f
                    } label: {
                        HStack {
                            Image(systemName: format == f
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(format == f
                                                 ? Color.spGold : Color.spTextSecondary)
                            Text(f.displayName)
                                .foregroundStyle(Color.spTextPrimary)
                            Spacer()
                            Text(formatHint(f))
                                .font(.caption2)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func formatHint(_ f: CPAExportFormat) -> String {
        switch f {
        case .pdf: return "Single PDF"
        case .csv: return "Spreadsheet"
        case .zip: return "PDF + CSV + manifest"
        }
    }

    // MARK: - Generate button

    private var generateButton: some View {
        Button { Task { await generate() } } label: {
            HStack {
                if isGenerating {
                    ProgressView().tint(Color.spBlack)
                } else {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                Text(isGenerating ? "Generating…" : "Generate Tax Package")
                    .fontWeight(.bold)
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .foregroundStyle(Color.spBlack)
            .background(toggles.hasAnyEnabled ? Color.spGold
                                              : Color.spCardBgLight)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(isGenerating || !toggles.hasAnyEnabled)
        .padding(.horizontal)
    }

    // MARK: - Disclaimer

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Informational only — not tax advice",
                  systemImage: "exclamationmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.spTextSecondary)
            Text("Generated reports help you organize records. " +
                 "Final filings should be reviewed by a licensed CPA.")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
        }
        .padding(14)
        .background(Color.spCardBg.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    // MARK: - Section card primitive

    @ViewBuilder
    private func sectionCard<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.spGold)
                .padding(.horizontal, 4)
            VStack(spacing: 14) { content() }
                .padding(16)
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal)
    }

    // MARK: - Action

    private func generate() async {
        guard !isGenerating else { return }
        errorMessage = nil
        isGenerating = true

        let range: ClosedRange<Date>
        if preset == .custom {
            // Guard against inverted range.
            let lo = min(customStart, customEnd)
            let hi = max(customStart, customEnd)
            range = lo...hi
        } else {
            range = preset.dateRange()
        }

        do {
            let result = try await CPAExportService.buildPackage(
                supabase: supabase,
                preset: preset,
                range: range,
                toggles: toggles,
                format: format
            )
            await MainActor.run {
                isGenerating = false
                shareItem = makeCPAShareItem(from: result, format: format)
            }
        } catch {
            await MainActor.run {
                isGenerating = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func makeCPAShareItem(from result: CPAExportResult,
                               format: CPAExportFormat) -> CPAShareItem {
        let stem = result.package.suggestedFilenameStem
        let tmp = FileManager.default.temporaryDirectory

        switch format {
        case .pdf:
            let url = tmp.appendingPathComponent("\(stem).pdf")
            try? result.pdfData.write(to: url)
            return CPAShareItem(items: [url])
        case .csv:
            let url = tmp.appendingPathComponent("\(stem).csv")
            try? result.csvData.write(to: url)
            return CPAShareItem(items: [url])
        case .zip:
            if let z = result.zipURL {
                return CPAShareItem(items: [z])
            }
            // Fallback — share the PDF if the ZIP step failed silently.
            let url = tmp.appendingPathComponent("\(stem).pdf")
            try? result.pdfData.write(to: url)
            return CPAShareItem(items: [url])
        }
    }
}

// MARK: - Share-sheet wrapper

private struct CPAShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct CPAShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                context: Context) {}
}

// MARK: - Preview
//
// (Intentionally omitted — SupabaseService is constructed at app launch
// and does not expose a `.shared` singleton, so a stub-free preview would
// require a mock environment object. Run on the simulator instead.)
