import UIKit
import TPPDF

// =============================================================================
// MARK: - Theme
// -----------------------------------------------------------------------------
// User-selectable color palettes for the generated paystub. Pick a preset
// or supply a custom primary/accent pair. All section bars, hero bars,
// and totals rows are derived from `primary` and `accent` so the rest of
// the document stays visually consistent.
// =============================================================================

public enum PaystubTheme: Equatable {
    case navyGold
    case forestGold
    case blackSilver
    case blueGray
    case custom(primary: UIColor, accent: UIColor)

    /// Safe default used when nothing is supplied. Matches the reference design.
    public static let defaultTheme: PaystubTheme = .navyGold

    /// Resolve a theme from a profile-stored string. Unknown / nil → default.
    public static func from(name: String?) -> PaystubTheme {
        switch (name ?? "").lowercased().replacingOccurrences(of: "_", with: "") {
        case "navygold":      return .navyGold
        case "forestgold":    return .forestGold
        case "blacksilver":   return .blackSilver
        case "bluegray":      return .blueGray
        default:              return .defaultTheme
        }
    }

    public var primary: UIColor {
        switch self {
        case .navyGold:    return UIColor(red: 0.10, green: 0.15, blue: 0.25, alpha: 1.00)
        case .forestGold:  return UIColor(red: 0.11, green: 0.30, blue: 0.18, alpha: 1.00)
        case .blackSilver: return UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.00)
        case .blueGray:    return UIColor(red: 0.20, green: 0.34, blue: 0.50, alpha: 1.00)
        case .custom(let p, _): return p
        }
    }

    public var accent: UIColor {
        switch self {
        case .navyGold:    return UIColor(red: 0.80, green: 0.68, blue: 0.26, alpha: 1.00)
        case .forestGold:  return UIColor(red: 0.80, green: 0.68, blue: 0.26, alpha: 1.00)
        case .blackSilver: return UIColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1.00)
        case .blueGray:    return UIColor(red: 0.55, green: 0.60, blue: 0.65, alpha: 1.00)
        case .custom(_, let a): return a
        }
    }

    /// Light gray fill used for the driver-info bar and table headers
    /// (small variations not worth themed values).
    public var bandFill: UIColor {
        UIColor(red: 0.94, green: 0.94, blue: 0.94, alpha: 1.00)
    }

    /// Soft green for the "TOTAL GROSS" and "NET" rows.
    public var totalsRowFill: UIColor {
        UIColor(red: 0.86, green: 0.94, blue: 0.83, alpha: 1.00)
    }

    /// Soft red for the "TOTAL DEDUCTIONS" and adjustment-deduction rows.
    public var deductionRowFill: UIColor {
        UIColor(red: 0.99, green: 0.92, blue: 0.91, alpha: 1.00)
    }

    /// Bold green for net pay text and any positive emphasis.
    public var positiveText: UIColor {
        UIColor(red: 0.16, green: 0.65, blue: 0.27, alpha: 1.00)
    }

    /// Red used for deduction amounts (parens-formatted).
    public var negativeText: UIColor { .systemRed }
}

// =============================================================================
// MARK: - Status Badge
// -----------------------------------------------------------------------------
// Optional small chip rendered top-right indicating whether the settlement
// has been paid out yet.
// =============================================================================

public enum PaystubStatus {
    case paid
    case unpaid
    case pending

    public var label: String {
        switch self {
        case .paid:    return "PAID"
        case .unpaid:  return "UNPAID"
        case .pending: return "PENDING"
        }
    }

    public var fillColor: UIColor {
        switch self {
        case .paid:    return UIColor(red: 0.16, green: 0.65, blue: 0.27, alpha: 1.00)
        case .unpaid:  return .systemRed
        case .pending: return .systemOrange
        }
    }

    public var textColor: UIColor { .white }
}

// =============================================================================
// MARK: - Year-To-Date Summary
// -----------------------------------------------------------------------------
// Aggregate values across all settlements in the current calendar year.
// Computed by the caller (typically by querying past settlements + summing
// the relevant columns) and passed in as a single struct.
// =============================================================================

public struct YTDSummary {
    public var grossRevenue: Double
    public var driverPay: Double
    public var dispatcherFees: Double
    public var factoringFees: Double
    public var authorityFees: Double
    public var maintenanceReserve: Double
    public var totalDeductions: Double
    public var netSettlement: Double

    public init(
        grossRevenue: Double = 0,
        driverPay: Double = 0,
        dispatcherFees: Double = 0,
        factoringFees: Double = 0,
        authorityFees: Double = 0,
        maintenanceReserve: Double = 0,
        totalDeductions: Double = 0,
        netSettlement: Double = 0
    ) {
        self.grossRevenue = grossRevenue
        self.driverPay = driverPay
        self.dispatcherFees = dispatcherFees
        self.factoringFees = factoringFees
        self.authorityFees = authorityFees
        self.maintenanceReserve = maintenanceReserve
        self.totalDeductions = totalDeductions
        self.netSettlement = netSettlement
    }
}

// =============================================================================
// MARK: - Adjustment line
// -----------------------------------------------------------------------------
// Optional ad-hoc line item (fuel advance taken back, reimbursement, etc.).
// Use `isAddition = true` for credits to the driver, `false` for deductions.
// =============================================================================

public struct PaystubAdjustment {
    public let label: String
    public let amount: Double
    public let isAddition: Bool

    public init(label: String, amount: Double, isAddition: Bool) {
        self.label = label
        self.amount = amount
        self.isAddition = isAddition
    }
}

// =============================================================================
// MARK: - PaystubPDFService
// -----------------------------------------------------------------------------
// Generates professional, branded PDF paystubs using TPPDF. The function
// signature has only added optional parameters — every existing call site
// in the project compiles unchanged.
// =============================================================================

class PaystubPDFService {

    // swiftlint:disable:next function_body_length
    static func generatePaystub(
        // — Required, unchanged —
        calculation: SettlementCalculation,
        loads: [Load],
        expenses: [Expense],
        companyName: String,
        driverName: String,
        periodStart: Date,
        periodEnd: Date,
        // — Existing optional parameters —
        logo: UIImage? = nil,
        primaryColor: UIColor = UIColor(red: 0.80, green: 0.68, blue: 0.26, alpha: 1.0),
        truckNumber: String? = nil,
        dispatcherName: String? = nil,
        mcNumber: String? = nil,
        dotNumber: String? = nil,
        notes: [String] = [],
        // — New optional parameters (Phase 2) —
        theme: PaystubTheme = .defaultTheme,
        statementId: String? = nil,
        status: PaystubStatus? = nil,
        paymentMethod: String? = nil,
        ytd: YTDSummary? = nil,
        adjustments: [PaystubAdjustment] = [],
        escrowBalance: Double? = nil,
        showSignatureLines: Bool = true
    ) throws -> Data {

        let document = PDFDocument(format: .usLetter)

        // ─── Date formatters ─────────────────────────────────────────
        let longDate = DateFormatter()
        longDate.dateFormat = "MMMM d"
        let endLongDate = DateFormatter()
        endLongDate.dateFormat = "d, yyyy"

        let shortDate = DateFormatter()
        shortDate.dateFormat = "M/d"
        let shortDateYear = DateFormatter()
        shortDateYear.dateFormat = "M/d/yyyy"

        let generatedTimestamp = DateFormatter()
        generatedTimestamp.dateFormat = "MM/dd/yyyy h:mm a"

        // ─── 1. Logo + Status badge row (top decorations) ─────────────
        if let logo = logo {
            // Render the logo at retina (3x) for the target on-page height
            // so embedded bitmap is sharp on print AND zoom. We don't pass
            // the raw UIImage to TPPDF because the page coordinate space is
            // points (1:1 with print pixels at 72 DPI); a 50pt-tall logo
            // would otherwise be rasterized at 50px and look soft.
            let pageDisplayHeight: CGFloat = 50
            let crisp = renderCrispLogoForPDF(logo, displayHeight: pageDisplayHeight)
            let imageElement = PDFImage(
                image: crisp,
                size: CGSize(
                    width: pageDisplayHeight * (logo.size.width / max(1, logo.size.height)),
                    height: pageDisplayHeight
                )
            )
            document.add(.contentLeft, image: imageElement)
        }
        if let status = status {
            try addStatusBadge(document: document, status: status)
        }
        if logo != nil || status != nil {
            document.add(space: 4)
        }

        // ─── 2. Navy header banner ───────────────────────────────────
        let headerTable = PDFTable(rows: 3, columns: 1)
        headerTable.widths = [1.0]

        headerTable[0, 0].content = try PDFTableContent(content: companyName.uppercased())
        headerTable[0, 0].style = PDFTableCellStyle(
            colors: (text: .white, fill: theme.primary),
            font: .boldSystemFont(ofSize: 24)
        )
        headerTable[0, 0].alignment = .center

        headerTable[1, 0].content = try PDFTableContent(content: "Driver's Statement")
        headerTable[1, 0].style = PDFTableCellStyle(
            colors: (text: UIColor.white.withAlphaComponent(0.85), fill: theme.primary),
            font: .systemFont(ofSize: 11)
        )
        headerTable[1, 0].alignment = .center

        let periodLong = "\(longDate.string(from: periodStart)) – \(endLongDate.string(from: periodEnd))"
        headerTable[2, 0].content = try PDFTableContent(content: "Pay Period: \(periodLong)")
        headerTable[2, 0].style = PDFTableCellStyle(
            colors: (text: UIColor.white.withAlphaComponent(0.85), fill: theme.primary),
            font: .systemFont(ofSize: 11)
        )
        headerTable[2, 0].alignment = .center

        document.add(table: headerTable)

        // ─── 3. Statement metadata strip (right-aligned, small) ──────
        var metaParts: [String] = []
        if let sid = statementId, !sid.isEmpty {
            metaParts.append("Statement #\(sid)")
        }
        metaParts.append("Generated \(generatedTimestamp.string(from: Date()))")

        document.add(.contentRight, textObject: PDFSimpleText(
            text: metaParts.joined(separator: "  ·  "),
            style: PDFTextStyle(name: "metaStrip", font: .systemFont(ofSize: 9), color: .gray)
        ))
        document.add(space: 10)

        // ─── 4. Driver info bar ──────────────────────────────────────
        try addDriverInfoBar(
            document: document,
            theme: theme,
            driverName: driverName,
            truckNumber: truckNumber,
            dispatcherName: dispatcherName,
            periodShort: "\(shortDate.string(from: periodStart)) – \(shortDateYear.string(from: periodEnd))"
        )

        // Optional second info row — MC, DOT, Payment Method
        let hasSecondaryInfo = (mcNumber?.isEmpty == false)
            || (dotNumber?.isEmpty == false)
            || (paymentMethod?.isEmpty == false)
        if hasSecondaryInfo {
            try addSecondaryInfoBar(
                document: document,
                theme: theme,
                mcNumber: mcNumber,
                dotNumber: dotNumber,
                paymentMethod: paymentMethod,
                statementId: statementId
            )
        }
        document.add(space: 14)

        // ─── 5. LOADS section ────────────────────────────────────────
        try addLoadsSection(
            document: document,
            theme: theme,
            loads: loads,
            shortDate: shortDate
        )

        // ─── 6. EXPENSES & DEDUCTIONS section ────────────────────────
        let displayedExpenseTotal = try addExpensesSection(
            document: document,
            theme: theme,
            expenses: expenses,
            calculation: calculation,
            shortDate: shortDate
        )

        // ─── 7. SETTLEMENT BREAKDOWN section ─────────────────────────
        try addSettlementBreakdownSection(
            document: document,
            theme: theme,
            calculation: calculation
        )

        // ─── 8. Optional ADJUSTMENTS (fuel advance, reimbursements) ──
        if !adjustments.isEmpty {
            try addAdjustmentsSection(
                document: document,
                theme: theme,
                adjustments: adjustments
            )
        }

        // ─── 9. Optional ESCROW running balance ──────────────────────
        if let escrow = escrowBalance {
            try addEscrowSection(document: document, theme: theme, balance: escrow)
        }

        // ─── 10. Optional YEAR TO DATE ───────────────────────────────
        if let ytd = ytd {
            try addYTDSection(document: document, theme: theme, ytd: ytd)
        }

        // ─── 11. Settlement summary block — TOTAL GROSS / TOTAL DEDUCTIONS / NET ───
        // Real total deductions = sum of every deduction-row amount visible
        // in the body. This fixes the prior bug where the summary used only
        // expenses and showed $0.00 when only fees were present.
        let realTotalDeductions =
            displayedExpenseTotal
            + calculation.dispatcherFeeAmount
            + calculation.factoringFeeAmount
            + calculation.authorityFee
            + calculation.maintenanceReserve
            + adjustments.filter { !$0.isAddition }.map(\.amount).reduce(0, +)
            - adjustments.filter { $0.isAddition }.map(\.amount).reduce(0, +)

        try addSummaryBlock(
            document: document,
            theme: theme,
            grossRevenue: calculation.totalRevenue,
            totalDeductions: max(0, realTotalDeductions),
            netSettlement: calculation.carrierNetPay
        )

        // ─── 12. Optional NOTES section ──────────────────────────────
        if !notes.isEmpty {
            document.add(space: 6)
            try addSectionTitleBar(document: document, theme: theme, title: "NOTES")
            document.add(space: 4)
            for note in notes {
                document.add(.contentLeft, textObject: PDFSimpleText(
                    text: "•  \(note)",
                    style: PDFTextStyle(
                        name: "note",
                        font: .italicSystemFont(ofSize: 10),
                        color: .darkGray
                    )
                ))
                document.add(space: 2)
            }
        }

        // ─── 13. Signature block ─────────────────────────────────────
        if showSignatureLines {
            document.add(space: 24)
            try addSignatureBlock(document: document, theme: theme)
        }

        // ─── 14. Footer (every page) ─────────────────────────────────
        document.add(space: 18)
        document.addLineSeparator(style: PDFLineStyle(type: .full, color: .lightGray, width: 0.5))
        document.add(space: 6)

        var footerParts: [String] = [companyName]
        if let mc = mcNumber, !mc.isEmpty { footerParts.append("MC# \(mc)") }
        if let dot = dotNumber, !dot.isEmpty { footerParts.append("DOT# \(dot)") }
        footerParts.append("Generated \(generatedTimestamp.string(from: Date()))")

        document.add(.contentCenter, textObject: PDFSimpleText(
            text: footerParts.joined(separator: " | "),
            style: PDFTextStyle(name: "footerLine", font: .italicSystemFont(ofSize: 9), color: .gray)
        ))
        document.add(.contentCenter, textObject: PDFSimpleText(
            text: "For business recordkeeping purposes only.",
            style: PDFTextStyle(name: "disclaimer", font: .italicSystemFont(ofSize: 8), color: .lightGray)
        ))

        // Add a subtle page-number line in the footer container of every
        // page TPPDF emits. Static text — works on every TPPDF version.
        document.add(.footerCenter, textObject: PDFSimpleText(
            text: companyName,
            style: PDFTextStyle(name: "pageFooter", font: .italicSystemFont(ofSize: 8), color: .lightGray)
        ))

        let generator = PDFGenerator(document: document)
        return try generator.generateData()
    }

    // =========================================================================
    // MARK: - Section helpers
    // =========================================================================

    private static func addStatusBadge(document: PDFDocument, status: PaystubStatus) throws {
        let badge = PDFTable(rows: 1, columns: 1)
        badge.widths = [0.20]
        badge[0, 0].content = try PDFTableContent(content: status.label)
        badge[0, 0].style = PDFTableCellStyle(
            colors: (text: status.textColor, fill: status.fillColor),
            font: .boldSystemFont(ofSize: 10)
        )
        badge[0, 0].alignment = .center
        document.add(table: badge)
    }

    private static func addDriverInfoBar(
        document: PDFDocument,
        theme: PaystubTheme,
        driverName: String,
        truckNumber: String?,
        dispatcherName: String?,
        periodShort: String
    ) throws {
        let info = PDFTable(rows: 2, columns: 4)
        info.widths = [0.25, 0.25, 0.25, 0.25]

        let headers = ["DRIVER", "TRUCK #", "DISPATCHER", "PERIOD"]
        for (col, label) in headers.enumerated() {
            let cell = info[0, col]
            cell.content = try PDFTableContent(content: label)
            cell.style = PDFTableCellStyle(
                colors: (text: .darkGray, fill: theme.bandFill),
                font: .systemFont(ofSize: 9)
            )
            cell.alignment = .left
        }
        let values = [driverName, truckNumber ?? "—", dispatcherName ?? "—", periodShort]
        for (col, value) in values.enumerated() {
            let cell = info[1, col]
            cell.content = try PDFTableContent(content: value)
            cell.style = PDFTableCellStyle(
                colors: (text: .darkGray, fill: theme.bandFill),
                font: .boldSystemFont(ofSize: 11)
            )
            cell.alignment = .left
        }
        document.add(table: info)
    }

    private static func addSecondaryInfoBar(
        document: PDFDocument,
        theme: PaystubTheme,
        mcNumber: String?,
        dotNumber: String?,
        paymentMethod: String?,
        statementId: String?
    ) throws {
        let row = PDFTable(rows: 2, columns: 4)
        row.widths = [0.25, 0.25, 0.25, 0.25]

        let headers = ["MC #", "DOT #", "PAYMENT METHOD", "STATEMENT ID"]
        for (col, label) in headers.enumerated() {
            let cell = row[0, col]
            cell.content = try PDFTableContent(content: label)
            cell.style = PDFTableCellStyle(
                colors: (text: .darkGray, fill: theme.bandFill.withAlphaComponent(0.55)),
                font: .systemFont(ofSize: 8)
            )
            cell.alignment = .left
        }
        let values = [
            mcNumber ?? "—",
            dotNumber ?? "—",
            paymentMethod ?? "—",
            statementId ?? "—"
        ]
        for (col, value) in values.enumerated() {
            let cell = row[1, col]
            cell.content = try PDFTableContent(content: value)
            cell.style = PDFTableCellStyle(
                colors: (text: .darkGray, fill: theme.bandFill.withAlphaComponent(0.55)),
                font: .systemFont(ofSize: 10)
            )
            cell.alignment = .left
        }
        document.add(table: row)
    }

    private static func addLoadsSection(
        document: PDFDocument,
        theme: PaystubTheme,
        loads: [Load],
        shortDate: DateFormatter
    ) throws {
        try addSectionTitleBar(document: document, theme: theme, title: "LOADS")
        document.add(space: 4)

        let headers = ["LOAD", "ROUTE", "PICKUP", "DELIVERY", "WEIGHT", "BROKER", "GROSS"]
        var rows: [[String]] = [headers]
        var totalRevenue: Double = 0
        var totalMiles: Double = 0
        for (idx, load) in loads.enumerated() {
            let pickup  = load.pickupDate.map { shortDate.string(from: $0) } ?? "—"
            let delivery = load.deliveryDate.map { shortDate.string(from: $0) } ?? "—"
            rows.append([
                "\(idx + 1)",
                "\(load.origin ?? "?") → \(load.destination ?? "?")",
                pickup,
                delivery,
                "—",
                load.brokerName ?? "—",
                load.totalRevenue?.asCurrency ?? "$0.00"
            ])
            totalRevenue += load.totalRevenue ?? 0
            totalMiles += load.totalMiles ?? 0
        }
        if !loads.isEmpty {
            rows.append(["", "", "", "", "", "TOTAL GROSS", totalRevenue.asCurrency])
        }

        let table = PDFTable(rows: rows.count, columns: 7)
        table.widths = [0.07, 0.22, 0.10, 0.10, 0.11, 0.20, 0.20]
        for (row, rowData) in rows.enumerated() {
            let isHeader = row == 0
            let isTotal = !loads.isEmpty && row == rows.count - 1
            for (col, text) in rowData.enumerated() {
                let cell = table[row, col]
                cell.content = try PDFTableContent(content: text)
                cell.style = PDFTableCellStyle(
                    colors: (
                        text: isHeader ? .darkGray : (isTotal ? .black : .darkGray),
                        fill: isHeader ? theme.bandFill : (isTotal ? theme.totalsRowFill : .white)
                    ),
                    font: (isHeader || isTotal || col == 6)
                        ? .boldSystemFont(ofSize: 9)
                        : .systemFont(ofSize: 9)
                )
                cell.alignment = col == 6 ? .right : .left
            }
        }
        document.add(table: table)

        // Per-load summary line (count + miles + avg rate) when we have data.
        if !loads.isEmpty {
            let summaryParts = loadSummaryParts(
                count: loads.count,
                totalRevenue: totalRevenue,
                totalMiles: totalMiles
            )
            document.add(.contentRight, textObject: PDFSimpleText(
                text: summaryParts.joined(separator: "  ·  "),
                style: PDFTextStyle(name: "loadSummary", font: .systemFont(ofSize: 9), color: .gray)
            ))
        }
        document.add(space: 12)
    }

    private static func loadSummaryParts(
        count: Int,
        totalRevenue: Double,
        totalMiles: Double
    ) -> [String] {
        var parts: [String] = ["\(count) load\(count == 1 ? "" : "s")"]
        if totalMiles > 0 {
            parts.append("\(Int(totalMiles)) mi")
            let rpm = totalRevenue / totalMiles
            parts.append(String(format: "$%.2f / mi", rpm))
        }
        return parts
    }

    /// Renders the EXPENSES & DEDUCTIONS table and returns the displayed
    /// total so the caller can roll it into the summary block.
    private static func addExpensesSection(
        document: PDFDocument,
        theme: PaystubTheme,
        expenses: [Expense],
        calculation: SettlementCalculation,
        shortDate: DateFormatter
    ) throws -> Double {
        guard !expenses.isEmpty else { return calculation.totalExpenses }

        try addSectionTitleBar(document: document, theme: theme, title: "EXPENSES & DEDUCTIONS")
        document.add(space: 4)

        let headers = ["DESCRIPTION", "VENDOR", "DATE", "CATEGORY", "AMOUNT"]
        var rows: [[String]] = [headers]
        var sum: Double = 0
        for exp in expenses {
            let dateStr = exp.receiptDate.map { shortDate.string(from: $0) } ?? "—"
            rows.append([
                exp.description ?? exp.category.capitalized,
                exp.vendorName ?? "—",
                dateStr,
                exp.category.capitalized,
                "(\(exp.amount.asCurrency))"
            ])
            sum += exp.amount
        }
        let displayTotal = calculation.totalExpenses > 0 ? calculation.totalExpenses : sum
        rows.append(["", "", "", "TOTAL EXPENSES", "(\(displayTotal.asCurrency))"])

        let table = PDFTable(rows: rows.count, columns: 5)
        table.widths = [0.28, 0.24, 0.10, 0.18, 0.20]
        for (row, rowData) in rows.enumerated() {
            let isHeader = row == 0
            let isTotal = row == rows.count - 1
            for (col, text) in rowData.enumerated() {
                let cell = table[row, col]
                cell.content = try PDFTableContent(content: text)
                let isAmountCol = col == 4
                cell.style = PDFTableCellStyle(
                    colors: (
                        text: isHeader
                            ? .darkGray
                            : (isAmountCol ? theme.negativeText : .darkGray),
                        fill: isHeader ? theme.bandFill : (isTotal ? theme.deductionRowFill : .white)
                    ),
                    font: (isHeader || isTotal || isAmountCol)
                        ? .boldSystemFont(ofSize: 10)
                        : .systemFont(ofSize: 10)
                )
                cell.alignment = isAmountCol ? .right : .left
            }
        }
        document.add(table: table)
        document.add(space: 12)
        return displayTotal
    }

    private static func addSettlementBreakdownSection(
        document: PDFDocument,
        theme: PaystubTheme,
        calculation: SettlementCalculation
    ) throws {
        try addSectionTitleBar(document: document, theme: theme, title: "SETTLEMENT BREAKDOWN")
        document.add(space: 4)

        let grossString = calculation.totalRevenue.asCurrency
        let rows: [[String]] = [
            ["DESCRIPTION", "BASIS", "RATE", "AMOUNT"],
            ["Driver Pay (Earnings)",
             "\(grossString) gross",
             "\(String(format: "%.1f", calculation.driverPayPercentage))%",
             calculation.driverPayAmount.asCurrency],
            ["Dispatcher Fee",
             "\(grossString) gross",
             "\(String(format: "%.1f", calculation.dispatcherFeePercentage))%",
             "(\(calculation.dispatcherFeeAmount.asCurrency))"],
            ["Factoring Fee",
             "\(grossString) gross",
             "\(String(format: "%.1f", calculation.factoringFeePercentage))%",
             "(\(calculation.factoringFeeAmount.asCurrency))"],
            ["Authority Fee", "Flat", "—", "(\(calculation.authorityFee.asCurrency))"],
            ["Maintenance Reserve", "Flat", "—", "(\(calculation.maintenanceReserve.asCurrency))"]
        ]

        let table = PDFTable(rows: rows.count, columns: 4)
        table.widths = [0.42, 0.22, 0.14, 0.22]
        for (row, rowData) in rows.enumerated() {
            let isHeader = row == 0
            for (col, text) in rowData.enumerated() {
                let cell = table[row, col]
                cell.content = try PDFTableContent(content: text)
                let isAmountCol = col == 3
                let isDeduction = isAmountCol && text.hasPrefix("(")
                cell.style = PDFTableCellStyle(
                    colors: (
                        text: isHeader
                            ? .darkGray
                            : (isDeduction
                                ? theme.negativeText
                                : (isAmountCol ? .black : .darkGray)),
                        fill: isHeader ? theme.bandFill : .white
                    ),
                    font: (isHeader || isAmountCol)
                        ? .boldSystemFont(ofSize: 10)
                        : .systemFont(ofSize: 10)
                )
                cell.alignment = (col == 0) ? .left : ((col == 3) ? .right : .left)
            }
        }
        document.add(table: table)
        document.add(space: 12)
    }

    private static func addAdjustmentsSection(
        document: PDFDocument,
        theme: PaystubTheme,
        adjustments: [PaystubAdjustment]
    ) throws {
        try addSectionTitleBar(document: document, theme: theme, title: "ADJUSTMENTS")
        document.add(space: 4)

        var rows: [[String]] = [["DESCRIPTION", "TYPE", "AMOUNT"]]
        var net: Double = 0
        for adj in adjustments {
            let typeLabel = adj.isAddition ? "Earning" : "Deduction"
            let amount = adj.isAddition
                ? adj.amount.asCurrency
                : "(\(adj.amount.asCurrency))"
            rows.append([adj.label, typeLabel, amount])
            net += adj.isAddition ? adj.amount : -adj.amount
        }
        let netString = net >= 0
            ? net.asCurrency
            : "(\(abs(net).asCurrency))"
        rows.append(["", "NET ADJUSTMENTS", netString])

        let table = PDFTable(rows: rows.count, columns: 3)
        table.widths = [0.55, 0.20, 0.25]
        for (row, rowData) in rows.enumerated() {
            let isHeader = row == 0
            let isTotal = row == rows.count - 1
            for (col, text) in rowData.enumerated() {
                let cell = table[row, col]
                cell.content = try PDFTableContent(content: text)
                let isAmountCol = col == 2
                let isDeduction = isAmountCol && text.hasPrefix("(")
                let amountColor: UIColor
                if isHeader {
                    amountColor = .darkGray
                } else if isDeduction {
                    amountColor = theme.negativeText
                } else if isAmountCol {
                    amountColor = theme.positiveText
                } else {
                    amountColor = .darkGray
                }
                cell.style = PDFTableCellStyle(
                    colors: (
                        text: amountColor,
                        fill: isHeader
                            ? theme.bandFill
                            : (isTotal ? theme.bandFill : .white)
                    ),
                    font: (isHeader || isTotal || isAmountCol)
                        ? .boldSystemFont(ofSize: 10)
                        : .systemFont(ofSize: 10)
                )
                cell.alignment = isAmountCol ? .right : .left
            }
        }
        document.add(table: table)
        document.add(space: 12)
    }

    private static func addEscrowSection(
        document: PDFDocument,
        theme: PaystubTheme,
        balance: Double
    ) throws {
        try addSectionTitleBar(
            document: document,
            theme: theme,
            title: "MAINTENANCE / ESCROW BALANCE"
        )
        document.add(space: 4)

        let table = PDFTable(rows: 1, columns: 2)
        table.widths = [0.65, 0.35]
        table[0, 0].content = try PDFTableContent(content: "Running balance through this period")
        table[0, 0].style = PDFTableCellStyle(
            colors: (text: .darkGray, fill: theme.bandFill),
            font: .systemFont(ofSize: 11)
        )
        table[0, 0].alignment = .left
        table[0, 1].content = try PDFTableContent(content: balance.asCurrency)
        table[0, 1].style = PDFTableCellStyle(
            colors: (text: theme.positiveText, fill: theme.bandFill),
            font: .boldSystemFont(ofSize: 12)
        )
        table[0, 1].alignment = .right
        document.add(table: table)
        document.add(space: 12)
    }

    private static func addYTDSection(
        document: PDFDocument,
        theme: PaystubTheme,
        ytd: YTDSummary
    ) throws {
        try addSectionTitleBar(document: document, theme: theme, title: "YEAR TO DATE")
        document.add(space: 4)

        let rows: [[String]] = [
            ["DESCRIPTION", "AMOUNT"],
            ["YTD Gross Revenue", ytd.grossRevenue.asCurrency],
            ["YTD Driver Pay", ytd.driverPay.asCurrency],
            ["YTD Dispatcher Fees", "(\(ytd.dispatcherFees.asCurrency))"],
            ["YTD Factoring Fees", "(\(ytd.factoringFees.asCurrency))"],
            ["YTD Authority Fees", "(\(ytd.authorityFees.asCurrency))"],
            ["YTD Maintenance Reserve", "(\(ytd.maintenanceReserve.asCurrency))"],
            ["YTD Total Deductions", "(\(ytd.totalDeductions.asCurrency))"],
            ["YTD Net Settlement", ytd.netSettlement.asCurrency]
        ]

        let table = PDFTable(rows: rows.count, columns: 2)
        table.widths = [0.65, 0.35]
        for (row, rowData) in rows.enumerated() {
            let isHeader = row == 0
            let isFinal = row == rows.count - 1
            for (col, text) in rowData.enumerated() {
                let cell = table[row, col]
                cell.content = try PDFTableContent(content: text)
                let isAmountCol = col == 1
                let isDeduction = isAmountCol && text.hasPrefix("(")
                let amountColor: UIColor
                if isHeader {
                    amountColor = .darkGray
                } else if isFinal && isAmountCol {
                    amountColor = theme.positiveText
                } else if isDeduction {
                    amountColor = theme.negativeText
                } else {
                    amountColor = .darkGray
                }
                cell.style = PDFTableCellStyle(
                    colors: (
                        text: amountColor,
                        fill: isHeader
                            ? theme.bandFill
                            : (isFinal ? theme.totalsRowFill : .white)
                    ),
                    font: (isHeader || isFinal || isAmountCol)
                        ? .boldSystemFont(ofSize: 11)
                        : .systemFont(ofSize: 11)
                )
                cell.alignment = isAmountCol ? .right : .left
            }
        }
        document.add(table: table)
        document.add(space: 12)
    }

    private static func addSummaryBlock(
        document: PDFDocument,
        theme: PaystubTheme,
        grossRevenue: Double,
        totalDeductions: Double,
        netSettlement: Double
    ) throws {
        let rows: [[String]] = [
            ["TOTAL GROSS REVENUE", grossRevenue.asCurrency],
            ["TOTAL DEDUCTIONS", "(\(totalDeductions.asCurrency))"],
            ["NET SETTLEMENT", netSettlement.asCurrency]
        ]
        let table = PDFTable(rows: rows.count, columns: 2)
        table.widths = [0.65, 0.35]
        for (row, rowData) in rows.enumerated() {
            let isNet = row == 2
            let isDeduction = row == 1
            for (col, text) in rowData.enumerated() {
                let cell = table[row, col]
                cell.content = try PDFTableContent(content: text)
                let textColor: UIColor
                let fill: UIColor
                if isNet {
                    textColor = theme.positiveText
                    fill = theme.totalsRowFill
                } else if isDeduction {
                    textColor = theme.negativeText
                    fill = theme.deductionRowFill
                } else {
                    textColor = .black
                    fill = theme.bandFill
                }
                cell.style = PDFTableCellStyle(
                    colors: (text: textColor, fill: fill),
                    font: isNet
                        ? .boldSystemFont(ofSize: 18)
                        : .boldSystemFont(ofSize: 13)
                )
                cell.alignment = col == 0 ? .left : .right
            }
        }
        document.add(table: table)
    }

    private static func addSignatureBlock(
        document: PDFDocument,
        theme: PaystubTheme
    ) throws {
        let table = PDFTable(rows: 2, columns: 2)
        table.widths = [0.50, 0.50]

        // Row 0: blank space (where ink lands) — set fill to white and a
        // tall-ish font so the visible band is sufficient for a real
        // signature.
        for col in 0...1 {
            let cell = table[0, col]
            cell.content = try PDFTableContent(content: " ")
            cell.style = PDFTableCellStyle(
                colors: (text: .clear, fill: .white),
                font: .systemFont(ofSize: 18)
            )
        }
        // Row 1: labels
        let labels = ["X _____________________________   Date __________",
                      "X _____________________________   Date __________"]
        for (col, text) in labels.enumerated() {
            let cell = table[1, col]
            cell.content = try PDFTableContent(content: text)
            cell.style = PDFTableCellStyle(
                colors: (text: .darkGray, fill: .white),
                font: .systemFont(ofSize: 9)
            )
            cell.alignment = .left
        }
        document.add(table: table)
        document.add(space: 4)

        let captionTable = PDFTable(rows: 1, columns: 2)
        captionTable.widths = [0.50, 0.50]
        captionTable[0, 0].content = try PDFTableContent(content: "Driver Signature")
        captionTable[0, 0].style = PDFTableCellStyle(
            colors: (text: theme.primary, fill: .white),
            font: .boldSystemFont(ofSize: 9)
        )
        captionTable[0, 0].alignment = .left
        captionTable[0, 1].content = try PDFTableContent(content: "Authorized Carrier Signature")
        captionTable[0, 1].style = PDFTableCellStyle(
            colors: (text: theme.primary, fill: .white),
            font: .boldSystemFont(ofSize: 9)
        )
        captionTable[0, 1].alignment = .left
        document.add(table: captionTable)
    }

    private static func addSectionTitleBar(
        document: PDFDocument,
        theme: PaystubTheme,
        title: String
    ) throws {
        let bar = PDFTable(rows: 1, columns: 1)
        bar.widths = [1.0]
        bar[0, 0].content = try PDFTableContent(content: title)
        bar[0, 0].style = PDFTableCellStyle(
            colors: (text: .white, fill: theme.primary),
            font: .boldSystemFont(ofSize: 12)
        )
        bar[0, 0].alignment = .center
        document.add(table: bar)
    }

    private static func resizeImage(_ image: UIImage, maxHeight: CGFloat) -> UIImage {
        // Retained for API compatibility — calls into the high-quality path.
        return renderCrispLogoForPDF(image, displayHeight: maxHeight)
    }

    /// Renders a logo at print-grade DPI (~360+) so the embedded bitmap stays
    /// sharp under print AND zoom. Adaptive: respects the source image's
    /// native pixel resolution if it's already higher than the target.
    /// Preserves alpha (transparent PNGs render cleanly) and uses high-quality
    /// interpolation. The output's scale is set so TPPDF reads its `size`
    /// correctly in points (1pt = 1/72in).
    private static func renderCrispLogoForPDF(
        _ image: UIImage,
        displayHeight: CGFloat
    ) -> UIImage {
        guard image.size.height > 0 else { return image }
        let aspect = image.size.width / image.size.height
        let displaySize = CGSize(
            width: displayHeight * aspect,
            height: displayHeight
        )

        // Target: 5x = ~360 effective DPI in the embedded bitmap. If the
        // source image's native resolution is already higher, use that.
        // Cap at 8x to avoid runaway memory on very large source images.
        let targetPrintScale: CGFloat   = 5.0
        let sourcePixelHeight: CGFloat  = image.size.height * image.scale
        let sourceNativeScale: CGFloat  = sourcePixelHeight / max(1, displayHeight)
        let renderScale: CGFloat        = min(max(targetPrintScale, sourceNativeScale), 8.0)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale          = renderScale         // 5x–8x — print-grade
        format.opaque         = false               // preserve transparency
        format.preferredRange = .extended           // wide color (P3) when supported

        let renderer = UIGraphicsImageRenderer(size: displaySize, format: format)
        return renderer.image { ctx in
            ctx.cgContext.interpolationQuality   = .high
            ctx.cgContext.setShouldAntialias(true)
            ctx.cgContext.setAllowsAntialiasing(true)
            // High-precision draw — uses the cgImage path when available so
            // colorspaces don't get squashed during composition.
            image.draw(in: CGRect(origin: .zero, size: displaySize))
        }
    }
}
