import SwiftUI
import UIKit

struct IFTAReportView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) var dismiss
    let summary: IFTASummary?

    /// Official quarterly tax-rate matrix. When unavailable, ALL tax-owed
    /// output is hidden (banner shown instead) — a $0.00 tax figure on a tax
    /// document is worse than none. See IFTARatesService for the runbook.
    @StateObject private var rates = IFTARatesService.shared

    @State private var isExportingPDF = false
    @State private var isExportingCSV = false

    private var ratesAvailable: Bool { rates.ratesAvailable }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            if let summary = summary {
                ScrollView {
                    VStack(spacing: 20) {
                        // Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text("IFTA Summary")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Color.spTextPrimary)
                            Text(summary.quarter.label)
                                .font(.headline)
                                .foregroundStyle(Color.spGold)
                            if let company = supabase.currentProfile?.companyName {
                                Text(company)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.spTextSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.spCardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()

                        // Official-rates status. Rates load remotely each
                        // quarter (IFTARatesService); until then tax owed is
                        // hidden rather than shown as a misleading $0.00.
                        if !ratesAvailable {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.spWarning)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Official IFTA tax rates not loaded")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.spTextPrimary)
                                    Text("Miles, gallons, and MPG below are complete. Tax owed is hidden until the current quarter's official rate table downloads — connect to the internet and reopen this report.")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.spWarning.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                        }

                        // Summary totals
                        VStack(spacing: 12) {
                            summaryRow("Total Miles", String(format: "%.1f", summary.totalMiles))
                            summaryRow("Total Gallons", String(format: "%.1f", summary.totalGallons))
                            summaryRow("Average MPG", String(format: "%.2f", summary.averageMPG))
                            if ratesAvailable {
                                summaryRow("Tax Owed (est.)", summary.totalTaxOwed.asCurrency)
                                if let quarter = rates.quarterLabel {
                                    HStack {
                                        Text("Rates: \(quarter) official IFTA matrix")
                                            .font(.caption2)
                                            .foregroundStyle(Color.spTextSecondary)
                                        Spacer()
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color.spCardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()

                        // State breakdown table
                        VStack(alignment: .leading, spacing: 12) {
                            Text("By State/Province")
                                .font(.headline)
                                .foregroundStyle(Color.spTextPrimary)
                                .padding(.horizontal)

                            VStack(spacing: 0) {
                                // Header row
                                HStack(spacing: 10) {
                                    Text("State")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color.spTextSecondary)
                                        .frame(width: 50, alignment: .leading)
                                    Text("Miles")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color.spTextSecondary)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                    Text("Gallons")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color.spTextSecondary)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                    Text("MPG")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color.spTextSecondary)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 12)
                                .background(Color.spBackground)

                                Divider()
                                    .background(Color.spCardBg)

                                // Data rows
                                ForEach(summary.statesummaries, id: \.stateCode) { state in
                                    HStack(spacing: 10) {
                                        Text(state.stateCode)
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextPrimary)
                                            .frame(width: 50, alignment: .leading)
                                        Text(String(format: "%.0f", state.miles))
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextPrimary)
                                            .frame(maxWidth: .infinity, alignment: .trailing)
                                        Text(String(format: "%.1f", state.gallons))
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextPrimary)
                                            .frame(maxWidth: .infinity, alignment: .trailing)
                                        Text(String(format: "%.2f", state.mpg))
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextPrimary)
                                            .frame(maxWidth: .infinity, alignment: .trailing)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                                    .background(Color.spCardBg)

                                    Divider()
                                        .background(Color.spBackground)
                                }
                            }
                            .background(Color.spCardBg)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal)
                        }

                        // Export buttons
                        HStack(spacing: 12) {
                            Button(action: { exportAsCSV() }) {
                                HStack {
                                    Image(systemName: "tablecells")
                                    Text("CSV")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.spCardBg)
                                .foregroundStyle(Color.spGold)
                                .font(.headline)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }

                            Button(action: { exportAsPDF() }) {
                                HStack {
                                    Image(systemName: "doc.fill")
                                    Text("PDF")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.spGold)
                                .foregroundStyle(Color.spBlack)
                                .font(.headline)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .padding()
                    }
                    .padding(.vertical)
                }
            } else {
                VStack {
                    Text("No data available")
                        .foregroundStyle(Color.spTextSecondary)
                }
            }
        }
        .navigationTitle("IFTA Report")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await rates.loadIfNeeded()
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Color.spTextSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
        }
    }

    private func exportAsCSV() {
        guard let summary = summary else { return }

        // Tax columns are only written when the official rate matrix is
        // loaded. Previously this exported "0.0000, 0.00" for every state —
        // a CPA-facing file must never claim $0 tax owed when the truth is
        // "rates unknown".
        var csv: String
        if ratesAvailable {
            csv = "State,Miles,Gallons,MPG,Tax Rate,Tax Owed\n"
            for state in summary.statesummaries {
                csv += "\(state.stateCode),\(String(format: "%.1f", state.miles)),\(String(format: "%.1f", state.gallons)),\(String(format: "%.2f", state.mpg)),\(String(format: "%.4f", state.taxRate)),\(String(format: "%.2f", state.taxOwed))\n"
            }
            csv += "\nTotal Tax Owed (est.),\(String(format: "%.2f", summary.totalTaxOwed))\n"
            if let quarter = rates.quarterLabel {
                csv += "Rates,\(quarter) official IFTA matrix\n"
            }
        } else {
            csv = "State,Miles,Gallons,MPG\n"
            for state in summary.statesummaries {
                csv += "\(state.stateCode),\(String(format: "%.1f", state.miles)),\(String(format: "%.1f", state.gallons)),\(String(format: "%.2f", state.mpg))\n"
            }
            csv += "\nNote,Official IFTA tax rates were not loaded — tax columns omitted\n"
        }

        let filename = "IFTA_\(summary.quarter.label.replacingOccurrences(of: " ", with: "_")).csv"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        try? csv.write(to: temp, atomically: true, encoding: .utf8)

        let vc = UIActivityViewController(activityItems: [temp], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first?
            .rootViewController?
            .present(vc, animated: true)
    }

    private func exportAsPDF() {
        guard let summary = summary else { return }

        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))

        let data = pdfRenderer.pdfData { context in
            context.beginPage()

            var yPosition: CGFloat = 20

            let title = NSAttributedString(
                string: "IFTA Summary - \(summary.quarter.label)",
                attributes: [.font: UIFont.boldSystemFont(ofSize: 16)]
            )
            title.draw(at: CGPoint(x: 20, y: yPosition))
            yPosition += 30

            let subheader = NSAttributedString(
                string: supabase.currentProfile?.companyName ?? "Company",
                attributes: [.font: UIFont.systemFont(ofSize: 12)]
            )
            subheader.draw(at: CGPoint(x: 20, y: yPosition))
            yPosition += 20

            // Summary section — tax figure only when official rates are
            // loaded (never print $0.00 from the sentinel zero-rate table).
            var summaryLine = "Total Miles: \(String(format: "%.1f", summary.totalMiles)) | Total Gallons: \(String(format: "%.1f", summary.totalGallons)) | Avg MPG: \(String(format: "%.2f", summary.averageMPG))"
            if ratesAvailable {
                summaryLine += " | Tax Owed (est.): $\(String(format: "%.2f", summary.totalTaxOwed))"
                if let quarter = rates.quarterLabel {
                    summaryLine += " (\(quarter) rates)"
                }
            } else {
                summaryLine += " | Tax owed: rates not loaded"
            }
            let summaryText = NSAttributedString(
                string: summaryLine,
                attributes: [.font: UIFont.systemFont(ofSize: 11)]
            )
            summaryText.draw(at: CGPoint(x: 20, y: yPosition))
            yPosition += 30

            // Table header
            let headerFont = UIFont.boldSystemFont(ofSize: 10)
            let dataFont = UIFont.systemFont(ofSize: 10)

            let headers = ["State", "Miles", "Gallons", "MPG"]
            let xPositions: [CGFloat] = [20, 100, 150, 200]

            for (i, header) in headers.enumerated() {
                NSAttributedString(string: header, attributes: [.font: headerFont])
                    .draw(at: CGPoint(x: xPositions[i], y: yPosition))
            }
            yPosition += 15

            // Table rows
            for state in summary.statesummaries {
                let data = [
                    state.stateCode,
                    String(format: "%.0f", state.miles),
                    String(format: "%.1f", state.gallons),
                    String(format: "%.2f", state.mpg)
                ]
                for (i, value) in data.enumerated() {
                    NSAttributedString(string: value, attributes: [.font: dataFont])
                        .draw(at: CGPoint(x: xPositions[i], y: yPosition))
                }
                yPosition += 12
            }
        }

        let filename = "IFTA_\(summary.quarter.label.replacingOccurrences(of: " ", with: "_")).pdf"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: temp)

        let vc = UIActivityViewController(activityItems: [temp], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first?
            .rootViewController?
            .present(vc, animated: true)
    }
}

#Preview {
    NavigationStack {
        IFTAReportView(summary: nil).environmentObject(SupabaseService())
    }
}
