import SwiftUI
import UIKit

/// "Share Summary" picker — lets the user pick a date range, then generates
/// a PDF + plain-text digest of loads / revenue / broker contacts / expenses
/// / settlements and hands it to UIActivityViewController for AirDrop, Mail,
/// Messages, Files, or Copy.
///
/// Wired in from:
///   - Dashboard top-right toolbar
///   - Loads list toolbar
///   - Settings → Operations → Share Summary
struct ShareSummaryView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedRange: RangeChoice = .thisWeek
    @State private var customStart: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEnd: Date = Date()
    @State private var isGenerating = false
    @State private var lastPDF: URL?
    @State private var lastText: String = ""
    @State private var errorMessage: String?
    @State private var allLoads: [Load] = []
    @State private var allExpenses: [Expense] = []
    @State private var companyName: String = ""

    enum RangeChoice: String, CaseIterable, Identifiable {
        case today      = "Today"
        case thisWeek   = "This Week"
        case lastWeek   = "Last Week"
        case thisMonth  = "This Month"
        case lastMonth  = "Last Month"
        case custom     = "Custom"

        var id: String { rawValue }

        func toServiceRange(start: Date, end: Date) -> ShareSummaryService.DateRange {
            switch self {
            case .today:      return .today
            case .thisWeek:   return .thisWeek
            case .lastWeek:   return .lastWeek
            case .thisMonth:  return .thisMonth
            case .lastMonth:  return .lastMonth
            case .custom:     return .custom(start, end)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        rangePickerCard
                        if selectedRange == .custom { customRangeCard }
                        previewCard
                        actionsCard
                        if let err = errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Share Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await loadInitialData() }
        }
    }

    private var rangePickerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Range").font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.spGold)
            Picker("Range", selection: $selectedRange) {
                ForEach(RangeChoice.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var customRangeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("Start", selection: $customStart, displayedComponents: .date)
            DatePicker("End",   selection: $customEnd,   displayedComponents: .date)
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var previewCard: some View {
        let summary = currentSummary()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(summary.range.displayLabel)
                    .font(.headline)
                    .foregroundStyle(Color.spGold)
                Spacer()
                Text("\(summary.loads.count) load\(summary.loads.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
            statRow("Revenue", money(summary.totalRevenue))
            statRow("Expenses", money(summary.totalExpenses))
            statRow("Net Profit", money(summary.netProfit), accent: true)
            if summary.totalMiles > 0 {
                statRow("Miles", "\(Int(summary.totalMiles))")
                statRow("Avg $/mi", String(format: "$%.2f", summary.avgRatePerMile))
            }
            statRow("Paid / Pending / Unpaid",
                    "\(summary.paidCount) · \(summary.pendingCount) · \(summary.unpaidCount)")
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statRow(_ label: String, _ value: String, accent: Bool = false) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Color.spTextSecondary)
            Spacer()
            Text(value).font(.subheadline.weight(.semibold))
                .foregroundStyle(accent ? Color.spSuccess : Color.spTextPrimary)
        }
    }

    private var actionsCard: some View {
        VStack(spacing: 10) {
            Button {
                Task { await sharePDF() }
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text(isGenerating ? "Building…" : "Share PDF + Text")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity).padding()
                .background(Color.spGold).foregroundStyle(Color.spBlack)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(isGenerating)

            Button {
                copyTextOnly()
            } label: {
                HStack {
                    Image(systemName: "doc.on.doc")
                    Text("Copy Summary Text")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity).padding()
                .background(Color.spCardBgLight)
                .foregroundStyle(Color.spTextPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Actions

    private func currentSummary() -> ShareSummaryService.Summary {
        let range = selectedRange.toServiceRange(start: customStart, end: customEnd)
        return ShareSummaryService.buildSummary(
            range: range,
            companyName: companyName.isEmpty ? "Sacred Pathway" : companyName,
            allLoads: allLoads,
            allExpenses: allExpenses
        )
    }

    private func sharePDF() async {
        isGenerating = true
        defer { isGenerating = false }
        let summary = currentSummary()
        do {
            let url = try ShareSummaryService.renderPDF(summary)
            lastPDF = url
            lastText = ShareSummaryService.textDigest(summary)
            presentShareSheet(items: [url, lastText])
        } catch {
            errorMessage = "Failed to build PDF: \(error.localizedDescription)"
        }
    }

    private func copyTextOnly() {
        let summary = currentSummary()
        let text = ShareSummaryService.textDigest(summary)
        UIPasteboard.general.string = text
    }

    private func presentShareSheet(items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return }
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // Find the top-most presented controller so we don't try to present
        // on top of a controller that's already presenting.
        var top = root
        while let presented = top.presentedViewController { top = presented }
        // iPad popover anchor
        if let pop = av.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY,
                                    width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(av, animated: true)
    }

    // MARK: - Data

    private func loadInitialData() async {
        do {
            // Fetch loads + expenses + company name in parallel.
            async let loadsAsync = supabase.fetchLoads()
            async let expensesAsync = supabase.fetchAllExpenses()
            allLoads = (try? await loadsAsync) ?? []
            allExpenses = (try? await expensesAsync) ?? []
            // Company name comes from the cached profile if available —
            // fall back to Sacred Pathway otherwise.
            if supabase.currentProfile == nil {
                await supabase.fetchProfile()
            }
            if let profile = supabase.currentProfile {
                companyName = profile.companyName ?? "Sacred Pathway"
            } else {
                companyName = "Sacred Pathway"
            }
        }
    }

    private func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f.string(from: NSNumber(value: v)) ?? "$0"
    }
}

#Preview {
    ShareSummaryView().environmentObject(SupabaseService())
}
