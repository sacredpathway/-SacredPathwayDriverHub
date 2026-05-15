import UIKit
import TPPDF

/// Generates a professional, branded quarterly IFTA worksheet PDF.
///
/// If state-by-state tax rates are present in IFTACalculator's jurisdiction
/// table, the PDF includes a Tax Owed column. If rates are missing for any
/// jurisdiction (the calculator falls back to 0.0), the PDF labels itself
/// "IFTA WORKSHEET" rather than "IFTA RETURN" to make clear it's a draft
/// the user finalizes against the official quarterly form.
class IFTAPDFService {

    static func generateQuarterlyReport(
        summary: IFTASummary,
        companyName: String,
        mcNumber: String?,
        dotNumber: String?,
        truckNumber: String?,
        driverName: String?,
        notes: String?,
        logo: UIImage? = nil,
        primaryColor: UIColor = UIColor(red: 0.80, green: 0.68, blue: 0.26, alpha: 1.0)
    ) throws -> Data {

        let document = PDFDocument(format: .usLetter)
        let brand = primaryColor

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium

        let title: String = summary.statesummaries.allSatisfy { $0.taxRate > 0 }
            ? "IFTA QUARTERLY RETURN"
            : "IFTA WORKSHEET"

        // MARK: - Header
        if let logo = logo {
            let resized = resizeImage(logo, maxWidth: 60)
            let imageElement = PDFImage(image: resized, size: CGSize(width: 60, height: 60))
            document.add(.contentLeft, image: imageElement)
        }

        document.add(.contentLeft, textObject: PDFSimpleText(
            text: companyName,
            style: PDFTextStyle(name: "companyName", font: .boldSystemFont(ofSize: 22), color: brand)
        ))
        document.add(space: 4)
        document.add(.contentLeft, textObject: PDFSimpleText(
            text: title,
            style: PDFTextStyle(name: "title", font: .boldSystemFont(ofSize: 14), color: .darkGray)
        ))

        var headerLine: [String] = []
        if let mc = mcNumber, !mc.isEmpty { headerLine.append("MC# \(mc)") }
        if let dot = dotNumber, !dot.isEmpty { headerLine.append("DOT# \(dot)") }
        if !headerLine.isEmpty {
            document.add(space: 2)
            document.add(.contentLeft, textObject: PDFSimpleText(
                text: headerLine.joined(separator: "  ·  "),
                style: PDFTextStyle(name: "ids", font: .systemFont(ofSize: 10), color: .gray)
            ))
        }

        document.add(.contentRight, textObject: PDFSimpleText(
            text: "Quarter: \(summary.quarter.label)",
            style: PDFTextStyle(name: "quarter", font: .boldSystemFont(ofSize: 12), color: .darkGray)
        ))

        if let truck = truckNumber, !truck.isEmpty {
            document.add(.contentRight, textObject: PDFSimpleText(
                text: "Truck/Unit: \(truck)",
                style: PDFTextStyle(name: "truck", font: .systemFont(ofSize: 11), color: .gray)
            ))
        }
        if let driver = driverName, !driver.isEmpty {
            document.add(.contentRight, textObject: PDFSimpleText(
                text: "Driver: \(driver)",
                style: PDFTextStyle(name: "driver", font: .systemFont(ofSize: 11), color: .gray)
            ))
        }

        document.add(space: 12)
        document.addLineSeparator(style: PDFLineStyle(type: .full, color: brand, width: 2))
        document.add(space: 12)

        // MARK: - Top-line totals
        document.add(.contentLeft, textObject: PDFSimpleText(
            text: "QUARTER TOTALS",
            style: PDFTextStyle(name: "sectionTitle", font: .boldSystemFont(ofSize: 13), color: brand)
        ))
        document.add(space: 6)

        let totalsRows: [[String]] = [
            ["Total Miles", "Total Gallons", "Avg MPG"],
            [
                String(format: "%.0f", summary.totalMiles),
                String(format: "%.1f", summary.totalGallons),
                String(format: "%.2f", summary.averageMPG)
            ]
        ]
        let totalsTable = PDFTable(rows: totalsRows.count, columns: 3)
        totalsTable.widths = [0.34, 0.33, 0.33]
        for (row, rowData) in totalsRows.enumerated() {
            for (col, text) in rowData.enumerated() {
                let cell = totalsTable[row, col]
                cell.content = try PDFTableContent(content: text)
                cell.style = PDFTableCellStyle(
                    colors: (
                        text: row == 0 ? .white : .darkGray,
                        fill: row == 0 ? brand : UIColor.systemGray6
                    ),
                    font: row == 0 ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 12)
                )
                cell.alignment = .center
            }
        }
        document.add(table: totalsTable)

        document.add(space: 16)

        // MARK: - State-by-state breakdown
        document.add(.contentLeft, textObject: PDFSimpleText(
            text: "BY JURISDICTION",
            style: PDFTextStyle(name: "sectionTitle", font: .boldSystemFont(ofSize: 13), color: brand)
        ))
        document.add(space: 6)

        let hasTaxData = summary.statesummaries.contains { $0.taxRate > 0 }
        let header: [String] = hasTaxData
            ? ["State", "Miles", "Gallons", "MPG", "Taxable Gal", "Rate", "Tax Owed"]
            : ["State", "Miles", "Gallons", "MPG", "Notes"]
        var stateRows: [[String]] = [header]

        for state in summary.statesummaries {
            if hasTaxData {
                stateRows.append([
                    "\(state.stateCode) — \(state.stateName)",
                    String(format: "%.0f", state.miles),
                    String(format: "%.1f", state.gallons),
                    String(format: "%.2f", state.mpg),
                    String(format: "%.2f", state.taxableGallons),
                    String(format: "$%.4f", state.taxRate),
                    String(format: "$%.2f", state.taxOwed)
                ])
            } else {
                stateRows.append([
                    "\(state.stateCode) — \(state.stateName)",
                    String(format: "%.0f", state.miles),
                    String(format: "%.1f", state.gallons),
                    String(format: "%.2f", state.mpg),
                    "Enter rate manually"
                ])
            }
        }

        let stateTable = PDFTable(rows: stateRows.count, columns: header.count)
        if hasTaxData {
            stateTable.widths = [0.22, 0.10, 0.11, 0.09, 0.14, 0.16, 0.18]
        } else {
            stateTable.widths = [0.30, 0.14, 0.14, 0.12, 0.30]
        }

        for (row, rowData) in stateRows.enumerated() {
            for (col, text) in rowData.enumerated() {
                let cell = stateTable[row, col]
                cell.content = try PDFTableContent(content: text)
                cell.style = PDFTableCellStyle(
                    colors: (
                        text: row == 0 ? .white : .darkGray,
                        fill: row == 0 ? brand : (row % 2 == 0 ? UIColor.systemGray6 : .white)
                    ),
                    font: row == 0 ? .boldSystemFont(ofSize: 10) : .systemFont(ofSize: 10)
                )
                // First column (state name) left-aligned; numeric columns right-aligned.
                cell.alignment = col == 0 ? .left : .right
            }
        }
        document.add(table: stateTable)

        // MARK: - Tax owed total
        if hasTaxData {
            document.add(space: 12)
            document.addLineSeparator(style: PDFLineStyle(type: .dashed, color: .lightGray, width: 0.5))
            document.add(space: 6)
            document.add(.contentRight, textObject: PDFSimpleText(
                text: String(format: "TOTAL TAX OWED: $%.2f", summary.totalTaxOwed),
                style: PDFTextStyle(name: "totalTax", font: .boldSystemFont(ofSize: 13), color: brand)
            ))
        }

        // MARK: - Notes
        if let notes = notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.add(space: 16)
            document.add(.contentLeft, textObject: PDFSimpleText(
                text: "NOTES",
                style: PDFTextStyle(name: "notesTitle", font: .boldSystemFont(ofSize: 12), color: brand)
            ))
            document.add(space: 4)
            document.add(.contentLeft, textObject: PDFSimpleText(
                text: notes,
                style: PDFTextStyle(name: "notesBody", font: .systemFont(ofSize: 10), color: .darkGray)
            ))
        }

        // MARK: - Footer
        document.add(space: 24)
        document.addLineSeparator(style: PDFLineStyle(type: .full, color: .lightGray, width: 0.5))
        document.add(space: 4)
        document.add(.contentLeft, textObject: PDFSimpleText(
            text: "Generated \(dateFormatter.string(from: Date())) by Sacred Pathway Driver Hub",
            style: PDFTextStyle(name: "footer", font: .systemFont(ofSize: 8), color: .lightGray)
        ))
        if !hasTaxData {
            document.add(.contentLeft, textObject: PDFSimpleText(
                text: "This is a worksheet, not a filed return. Verify state tax rates against your official IFTA quarterly form before submission.",
                style: PDFTextStyle(name: "disclaimer", font: .italicSystemFont(ofSize: 8), color: .gray)
            ))
        }

        let generator = PDFGenerator(document: document)
        return try generator.generateData()
    }

    // MARK: - Helpers

    private static func resizeImage(_ image: UIImage, maxWidth: CGFloat) -> UIImage {
        let aspect = image.size.height / image.size.width
        let size = CGSize(width: maxWidth, height: maxWidth * aspect)
        UIGraphicsBeginImageContextWithOptions(size, false, image.scale)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }
}
