import UIKit
import TPPDF

/// Generates professional, branded PDF paystubs using TPPDF
class PaystubPDFService {

    static func generatePaystub(
        calculation: SettlementCalculation,
        loads: [Load],
        expenses: [Expense],
        companyName: String,
        driverName: String,
        periodStart: Date,
        periodEnd: Date,
        logo: UIImage? = nil,
        primaryColor: UIColor = UIColor(red: 0.80, green: 0.68, blue: 0.26, alpha: 1.0)
    ) throws -> Data {

        let document = PDFDocument(format: .usLetter)

        let brandColor = primaryColor
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium

        // MARK: - Header
        if let logo = logo {
            let resized = resizeImage(logo, maxWidth: 60)
            let imageElement = PDFImage(image: resized, size: CGSize(width: 60, height: 60))
            document.add(.contentLeft, image: imageElement)
        }

        document.add(.contentLeft, textObject: PDFSimpleText(
            text: companyName,
            style: PDFTextStyle(name: "companyName", font: .boldSystemFont(ofSize: 22), color: brandColor)
        ))
        document.add(space: 4)
        document.add(.contentLeft, textObject: PDFSimpleText(
            text: "DRIVER SETTLEMENT",
            style: PDFTextStyle(name: "title", font: .boldSystemFont(ofSize: 14), color: .darkGray)
        ))
        document.add(space: 4)
        document.add(.contentLeft, textObject: PDFSimpleText(
            text: "Period: \(dateFormatter.string(from: periodStart)) – \(dateFormatter.string(from: periodEnd))",
            style: PDFTextStyle(name: "period", font: .systemFont(ofSize: 11), color: .gray)
        ))
        document.add(.contentRight, textObject: PDFSimpleText(
            text: "Driver: \(driverName)",
            style: PDFTextStyle(name: "driver", font: .boldSystemFont(ofSize: 12), color: .darkGray)
        ))

        document.add(space: 12)
        document.addLineSeparator(style: PDFLineStyle(type: .full, color: brandColor, width: 2))
        document.add(space: 12)

        // MARK: - Load Summary Table
        document.add(.contentLeft, textObject: PDFSimpleText(
            text: "LOADS",
            style: PDFTextStyle(name: "sectionTitle", font: .boldSystemFont(ofSize: 13), color: brandColor)
        ))
        document.add(space: 6)

        var loadTableContent: [[String]] = [["Load #", "Broker", "Route", "Miles", "Revenue"]]
        for load in loads {
            loadTableContent.append([
                load.loadNumber ?? "—",
                load.brokerName ?? "—",
                "\(load.origin ?? "?") → \(load.destination ?? "?")",
                load.totalMiles.map { String(format: "%.0f", $0) } ?? "—",
                load.totalRevenue?.asCurrency ?? "$0.00"
            ])
        }

        let loadTable = PDFTable(rows: loadTableContent.count, columns: 5)
        loadTable.widths = [0.12, 0.20, 0.32, 0.12, 0.14]

        for (row, rowData) in loadTableContent.enumerated() {
            for (col, text) in rowData.enumerated() {
                let cell = loadTable[row, col]
                cell.content = try PDFTableContent(content: text)
                cell.style = PDFTableCellStyle(
                    colors: (text: row == 0 ? .white : .darkGray, fill: row == 0 ? brandColor : (row % 2 == 0 ? UIColor.systemGray6 : .white)),
                    font: row == 0 ? .boldSystemFont(ofSize: 9) : .systemFont(ofSize: 9)
                )
                cell.alignment = col >= 3 ? .right : .left
            }
        }
        document.add(table: loadTable)
        document.add(space: 12)

        // MARK: - Expense Summary
        if !expenses.isEmpty {
            document.add(.contentLeft, textObject: PDFSimpleText(
                text: "EXPENSES",
                style: PDFTextStyle(name: "sectionTitle2", font: .boldSystemFont(ofSize: 13), color: brandColor)
            ))
            document.add(space: 6)

            let grouped = Dictionary(grouping: expenses) { $0.category.capitalized }
            var expRows: [[String]] = [["Category", "Count", "Amount"]]
            for (cat, catExpenses) in grouped.sorted(by: { $0.key < $1.key }) {
                let total = catExpenses.reduce(0) { $0 + $1.amount }
                expRows.append([cat, "\(catExpenses.count)", total.asCurrency])
            }
            expRows.append(["TOTAL", "", calculation.totalExpenses.asCurrency])

            let expTable = PDFTable(rows: expRows.count, columns: 3)
            expTable.widths = [0.50, 0.15, 0.25]
            for (row, rowData) in expRows.enumerated() {
                let isHeader = row == 0
                let isFooter = row == expRows.count - 1
                for (col, text) in rowData.enumerated() {
                    let cell = expTable[row, col]
                    cell.content = try PDFTableContent(content: text)
                    cell.style = PDFTableCellStyle(
                        colors: (text: isHeader ? .white : .darkGray, fill: isHeader ? brandColor : (isFooter ? UIColor.systemGray5 : (row % 2 == 0 ? UIColor.systemGray6 : .white))),
                        font: (isHeader || isFooter) ? .boldSystemFont(ofSize: 9) : .systemFont(ofSize: 9)
                    )
                    cell.alignment = col >= 1 ? .right : .left
                }
            }
            document.add(table: expTable)
            document.add(space: 12)
        }

        // MARK: - Settlement Breakdown
        document.add(.contentLeft, textObject: PDFSimpleText(
            text: "SETTLEMENT BREAKDOWN",
            style: PDFTextStyle(name: "sectionTitle3", font: .boldSystemFont(ofSize: 13), color: brandColor)
        ))
        document.add(space: 6)

        let breakdownRows: [[String]] = [
            ["Description", "Rate", "Amount"],
            ["Gross Revenue", "", calculation.totalRevenue.asCurrency],
            ["Total Expenses", "", "(\(calculation.totalExpenses.asCurrency))"],
            ["Gross Profit", "", calculation.grossProfit.asCurrency],
            ["Driver Pay", "\(String(format: "%.0f", calculation.driverPayPercentage))%", calculation.driverPayAmount.asCurrency],
            ["Dispatcher Fee", "\(String(format: "%.0f", calculation.dispatcherFeePercentage))%", "(\(calculation.dispatcherFeeAmount.asCurrency))"],
            ["Factoring Fee", "\(String(format: "%.0f", calculation.factoringFeePercentage))%", "(\(calculation.factoringFeeAmount.asCurrency))"],
            ["Authority Fee", "Flat", "(\(calculation.authorityFee.asCurrency))"],
            ["Maintenance Reserve", "Flat", "(\(calculation.maintenanceReserve.asCurrency))"],
            ["NET PAY TO DRIVER", "", calculation.carrierNetPay.asCurrency]
        ]

        let breakdownTable = PDFTable(rows: breakdownRows.count, columns: 3)
        breakdownTable.widths = [0.50, 0.20, 0.25]
        for (row, rowData) in breakdownRows.enumerated() {
            let isHeader = row == 0
            let isFooter = row == breakdownRows.count - 1
            for (col, text) in rowData.enumerated() {
                let cell = breakdownTable[row, col]
                cell.content = try PDFTableContent(content: text)
                cell.style = PDFTableCellStyle(
                    colors: (text: isHeader ? .white : (isFooter ? brandColor : .darkGray), fill: isHeader ? brandColor : (isFooter ? UIColor.systemGray5 : (row % 2 == 0 ? UIColor.systemGray6 : .white))),
                    font: (isHeader || isFooter) ? .boldSystemFont(ofSize: isFooter ? 11 : 9) : .systemFont(ofSize: 9)
                )
                cell.alignment = col >= 1 ? .right : .left
            }
        }
        document.add(table: breakdownTable)
        document.add(space: 20)

        // MARK: - Footer
        document.addLineSeparator(style: PDFLineStyle(type: .full, color: .lightGray, width: 0.5))
        document.add(space: 6)
        document.add(.contentCenter, textObject: PDFSimpleText(
            text: "Generated by Sacred Pathway Driver Hub • \(dateFormatter.string(from: Date()))",
            style: PDFTextStyle(name: "footer", font: .systemFont(ofSize: 8), color: .lightGray)
        ))

        let generator = PDFGenerator(document: document)
        let data = try generator.generateData()
        return data
    }

    private static func resizeImage(_ image: UIImage, maxWidth: CGFloat) -> UIImage {
        let ratio = maxWidth / image.size.width
        let newSize = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
