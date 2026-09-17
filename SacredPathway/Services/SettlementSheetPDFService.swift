import UIKit

// =============================================================================
// MARK: - SettlementSheet — carrier-style owner settlement printout
// -----------------------------------------------------------------------------
// Black-and-white, monospace, multi-page settlement sheet modeled after the
// owner-operator settlement format used by major carriers (US Xpress style).
// Sacred Pathway branding only — the carrier name in the upper-left header
// is the user's own authority pulled from Profile.companyName, not any
// third-party brand.
//
// Layout reference:
//   • Top header repeats on every page (carrier address left, settlement
//     metadata right)
//   • Page 1 includes the owner mailing block + Tractor #
//   • Trip-by-trip blocks: Pro#, Tractor Origin, Origin/Destination, miles,
//     and a Revenue / Other two-column ledger of pay, taxes, fuel
//     surcharge, fuel purchases, and "Total Trip Net"
//   • Adjustments table  → "Total Adjustments"
//   • Repairs table      → "Total Repairs"
//   • Check / Direct Deposit line (the bold settlement amount)
//   • Tractor Summary    (Current vs YTD)
//   • Tractor Recap      (Taxable Wages / Advances / Adj/Expense / Total Due)
//   • Maintenance Reserve Recap
//   • Tire/Lease Reserve Recap
//   • Bond Balance Recap
//   • Fuel Savings Recap
//   • Footer line at bottom of every page
// =============================================================================

// MARK: - Trip line item

public struct SettlementTripLine {
    public enum Kind {
        case revenuePay        // shows in "Revenue" column
        case deduction         // shows in "Other" column with trailing "-"
        case fuelSurcharge     // shows in "Revenue" column
        case fuelPurchase      // multi-line fuel receipt block, "Other" column
    }
    public var kind: Kind
    public var label: String        // e.g. "Revenue Pay", "Maintenance Reserve"
    public var basis: String        // shown center, e.g. "$ 5136"
    public var rate: String         // shown center, e.g. ".67000 %"
    public var amount: Double       // signed-dollar value (negative for deductions)
    /// Optional second-line block for fuel-purchase rows (location, qty, etc.)
    public var detail: [String]

    public init(kind: Kind,
                label: String,
                basis: String = "",
                rate: String = "",
                amount: Double,
                detail: [String] = []) {
        self.kind = kind
        self.label = label
        self.basis = basis
        self.rate = rate
        self.amount = amount
        self.detail = detail
    }
}

// MARK: - Trip

public struct SettlementSheetTrip {
    public var proNumber: String
    public var dispatchDate: Date?
    public var tractorOrigin: String      // "CA, REDLANDS"
    public var origin: String             // "CA, ONTARIO"
    public var originMiles: Double        // 29
    public var destination: String        // "MO, GRAIN VLY"
    public var destinationMiles: Double   // 1554
    public var lines: [SettlementTripLine]

    public init(proNumber: String = "",
                dispatchDate: Date? = nil,
                tractorOrigin: String = "",
                origin: String = "",
                originMiles: Double = 0,
                destination: String = "",
                destinationMiles: Double = 0,
                lines: [SettlementTripLine] = []) {
        self.proNumber = proNumber
        self.dispatchDate = dispatchDate
        self.tractorOrigin = tractorOrigin
        self.origin = origin
        self.originMiles = originMiles
        self.destination = destination
        self.destinationMiles = destinationMiles
        self.lines = lines
    }

    public var tripNet: Double { lines.reduce(0) { $0 + $1.amount } }
}

// MARK: - Adjustments / Repairs / Recaps

public struct SettlementAdjustment {
    public var date: Date?
    public var transactionId: String
    public var driverId: String
    public var description: String
    public var weeklyInstall: Double      // signed; negative = deduction
    public var balance: Double            // running balance (0 if N/A)
    public var hasBalance: Bool

    public init(date: Date? = nil,
                transactionId: String = "",
                driverId: String = "",
                description: String = "",
                weeklyInstall: Double = 0,
                balance: Double = 0,
                hasBalance: Bool = false) {
        self.date = date
        self.transactionId = transactionId
        self.driverId = driverId
        self.description = description
        self.weeklyInstall = weeklyInstall
        self.balance = balance
        self.hasBalance = hasBalance
    }
}

public struct SettlementRepair {
    public var date: Date?
    public var transactionId: String
    public var roNumber: String
    public var description: String
    public var weeklyInstall: Double
    public var balance: Double
    public var hasBalance: Bool

    public init(date: Date? = nil,
                transactionId: String = "",
                roNumber: String = "",
                description: String = "",
                weeklyInstall: Double = 0,
                balance: Double = 0,
                hasBalance: Bool = false) {
        self.date = date
        self.transactionId = transactionId
        self.roNumber = roNumber
        self.description = description
        self.weeklyInstall = weeklyInstall
        self.balance = balance
        self.hasBalance = hasBalance
    }
}

public struct SettlementSummaryLine {
    public var label: String
    public var current: Double            // 0 = blank
    public var ytd: Double                // 0 = blank
    public var currentNegative: Bool
    public var ytdNegative: Bool

    public init(label: String,
                current: Double = 0,
                ytd: Double = 0,
                currentNegative: Bool = false,
                ytdNegative: Bool = false) {
        self.label = label
        self.current = current
        self.ytd = ytd
        self.currentNegative = currentNegative
        self.ytdNegative = ytdNegative
    }
}

public struct SettlementReserveRecap {
    public var title: String
    public var weeklyAdd: Double
    public var ytdAdd: Double
    public var weeklyDed: Double          // signed: negative = deduction
    public var ytdDed: Double
    public var balance: Double
    public var balanceLabel: String       // "Reserve Bal" / "Bond Bal"

    public init(title: String,
                weeklyAdd: Double = 0,
                ytdAdd: Double = 0,
                weeklyDed: Double = 0,
                ytdDed: Double = 0,
                balance: Double = 0,
                balanceLabel: String = "Reserve Bal") {
        self.title = title
        self.weeklyAdd = weeklyAdd
        self.ytdAdd = ytdAdd
        self.weeklyDed = weeklyDed
        self.ytdDed = ytdDed
        self.balance = balance
        self.balanceLabel = balanceLabel
    }
}

public struct SettlementFuelSavings {
    public var weekly: Double
    public var ytd: Double
    public init(weekly: Double = 0, ytd: Double = 0) {
        self.weekly = weekly
        self.ytd = ytd
    }
}

// MARK: - Top-level data

public struct SettlementSheetData {
    // Carrier (top-left header)
    public var carrierName: String
    public var carrierAddressLine1: String
    public var carrierAddressLine2: String
    public var carrierPhone: String

    // Settlement metadata (top-right)
    public var settlementDate: Date
    public var periodStart: Date
    public var periodEnd: Date
    public var leasedTo: String
    public var ownerNumber: String
    public var ownerNameHeader: String          // shown bold in top-right

    // Mailing block (page 1 only)
    public var ownerMailingName: String
    public var ownerMailingLine1: String
    public var ownerMailingLine2: String
    public var ownerMailingLine3: String

    // Tractor identifier
    public var tractorNumber: String            // "LP94588"

    // Body
    public var trips: [SettlementSheetTrip]
    public var adjustments: [SettlementAdjustment]
    public var repairs: [SettlementRepair]

    // Check / direct deposit
    public var checkNumber: String              // "D    557124"
    public var directDepositAmount: Double      // computed if 0

    // Tractor Summary (long Current/YTD list)
    public var tractorSummary: [SettlementSummaryLine]

    // Tractor Recap totals
    public var taxableWages: Double
    public var advances: Double
    public var adjExpense: Double               // signed; negative
    public var totalDue: Double                 // computed if 0

    // Reserve recaps
    public var maintenanceRecap: SettlementReserveRecap?
    public var tireRecap: SettlementReserveRecap?
    public var bondRecap: SettlementReserveRecap?
    public var fuelSavings: SettlementFuelSavings?

    // Footer
    public var deliveryMethod: String           // "Email driver@…"

    /// Optional carrier logo. Rendered at retina quality at the top-left of
    /// every page header alongside the carrier name. Pass `nil` for a
    /// text-only header.
    public var logo: UIImage?

    public init(
        carrierName: String = "Sacred Pathway",
        carrierAddressLine1: String = "",
        carrierAddressLine2: String = "",
        carrierPhone: String = "",
        settlementDate: Date = Date(),
        periodStart: Date = Date(),
        periodEnd: Date = Date(),
        leasedTo: String = "",
        ownerNumber: String = "",
        ownerNameHeader: String = "",
        ownerMailingName: String = "",
        ownerMailingLine1: String = "",
        ownerMailingLine2: String = "",
        ownerMailingLine3: String = "",
        tractorNumber: String = "",
        trips: [SettlementSheetTrip] = [],
        adjustments: [SettlementAdjustment] = [],
        repairs: [SettlementRepair] = [],
        checkNumber: String = "",
        directDepositAmount: Double = 0,
        tractorSummary: [SettlementSummaryLine] = [],
        taxableWages: Double = 0,
        advances: Double = 0,
        adjExpense: Double = 0,
        totalDue: Double = 0,
        maintenanceRecap: SettlementReserveRecap? = nil,
        tireRecap: SettlementReserveRecap? = nil,
        bondRecap: SettlementReserveRecap? = nil,
        fuelSavings: SettlementFuelSavings? = nil,
        deliveryMethod: String = "",
        logo: UIImage? = nil
    ) {
        self.carrierName = carrierName
        self.carrierAddressLine1 = carrierAddressLine1
        self.carrierAddressLine2 = carrierAddressLine2
        self.carrierPhone = carrierPhone
        self.settlementDate = settlementDate
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.leasedTo = leasedTo
        self.ownerNumber = ownerNumber
        self.ownerNameHeader = ownerNameHeader
        self.ownerMailingName = ownerMailingName
        self.ownerMailingLine1 = ownerMailingLine1
        self.ownerMailingLine2 = ownerMailingLine2
        self.ownerMailingLine3 = ownerMailingLine3
        self.tractorNumber = tractorNumber
        self.trips = trips
        self.adjustments = adjustments
        self.repairs = repairs
        self.checkNumber = checkNumber
        self.directDepositAmount = directDepositAmount
        self.tractorSummary = tractorSummary
        self.taxableWages = taxableWages
        self.advances = advances
        self.adjExpense = adjExpense
        self.totalDue = totalDue
        self.maintenanceRecap = maintenanceRecap
        self.tireRecap = tireRecap
        self.bondRecap = bondRecap
        self.fuelSavings = fuelSavings
        self.deliveryMethod = deliveryMethod
        self.logo = logo
    }

    // Computed totals
    public var totalAdjustments: Double {
        adjustments.reduce(0) { $0 + $1.weeklyInstall }
    }
    public var totalRepairs: Double {
        repairs.reduce(0) { $0 + $1.weeklyInstall }
    }
    public var totalTripsNet: Double {
        trips.reduce(0) { $0 + $1.tripNet }
    }
    public var resolvedTotalDue: Double {
        totalDue != 0 ? totalDue : totalTripsNet + totalAdjustments + totalRepairs
    }
    public var resolvedDirectDeposit: Double {
        directDepositAmount != 0 ? directDepositAmount : resolvedTotalDue
    }
}

// =============================================================================
// MARK: - Renderer
// =============================================================================

public final class SettlementSheetPDFService {
    public static func generate(_ data: SettlementSheetData) -> Data {
        let pageW: CGFloat = 612
        let pageH: CGFloat = 792
        let bounds = CGRect(x: 0, y: 0, width: pageW, height: pageH)

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "Sacred Pathway Driver Hub",
            kCGPDFContextAuthor  as String: data.carrierName,
            kCGPDFContextTitle   as String: "Owner Settlement \(SheetRenderer.dfShort.string(from: data.settlementDate))"
        ] as [String: Any]

        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        return renderer.pdfData { ctx in
            let r = SheetRenderer(context: ctx, bounds: bounds, data: data)
            r.run()
        }
    }
}

// =============================================================================
// MARK: - Renderer implementation
// =============================================================================

private final class SheetRenderer {
    let ctx: UIGraphicsPDFRendererContext
    let bounds: CGRect
    let data: SettlementSheetData

    // Geometry
    let margin: CGFloat = 36
    var cursorY: CGFloat = 0
    var pageNumber: Int = 0
    var totalPages: Int = 1

    // Fonts (monospace throughout for the printout look)
    let fontMono: UIFont
    let fontMonoBold: UIFont
    let fontMonoLarge: UIFont
    let fontMonoLargeBold: UIFont

    init(context: UIGraphicsPDFRendererContext, bounds: CGRect, data: SettlementSheetData) {
        self.ctx = context
        self.bounds = bounds
        self.data = data
        // Original compact carrier-printout sizing — dense ledger look.
        self.fontMono           = UIFont(name: "Menlo", size: 8.5)         ?? UIFont.monospacedSystemFont(ofSize: 8.5, weight: .regular)
        self.fontMonoBold       = UIFont(name: "Menlo-Bold", size: 8.5)    ?? UIFont.monospacedSystemFont(ofSize: 8.5, weight: .bold)
        self.fontMonoLarge      = UIFont(name: "Menlo", size: 11)          ?? UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        self.fontMonoLargeBold  = UIFont(name: "Menlo-Bold", size: 11)     ?? UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    }

    static let dfShort: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M/d/yyyy"; return f
    }()
    static let dfShort2: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM/dd/yyyy"; return f
    }()

    var contentLeft: CGFloat   { margin }
    var contentRight: CGFloat  { bounds.width - margin }
    var contentWidth: CGFloat  { contentRight - contentLeft }

    var bodyTop: CGFloat       { 150 }      // y where body starts (after header)
    var bodyBottom: CGFloat    { bounds.height - 56 }  // y where body must end (footer)

    // First pass: count pages (so headers can show "Page X of Y")
    func run() {
        // Two-pass: simulate to compute totalPages, then render.
        let counted = simulatePageCount()
        totalPages = max(counted, 1)
        renderActual()
    }

    private func simulatePageCount() -> Int {
        // Reuse drawing logic but in a "measure only" mode by routing through
        // a duplicate state with no actual drawing. The simplest reliable way
        // here is: render once to a throw-away context to count pages.
        let throwAway = UIGraphicsPDFRenderer(bounds: bounds)
        var count = 0
        _ = throwAway.pdfData { tctx in
            let r = SheetRenderer(context: tctx, bounds: bounds, data: data)
            r.totalPages = 99    // placeholder; not actually rendered to user
            r.renderActual()
            count = r.pageNumber
        }
        return count
    }

    private func renderActual() {
        pageNumber = 0
        cursorY = 0
        beginPage(isFirst: true)
        drawTractorLabel()
        drawAllTrips()
        drawAdjustments()
        drawRepairs()
        drawCheckLine()
        drawTractorSummary()
        drawTractorRecap()
        drawReserves()
        drawFooterLine()
    }

    // MARK: - Page lifecycle

    private func beginPage(isFirst: Bool) {
        pageNumber += 1
        ctx.beginPage()
        drawHeader(isFirstPage: isFirst)
        cursorY = bodyTop
        if isFirst { drawOwnerMailingBlock() }
    }

    private func ensureSpace(_ needed: CGFloat) {
        if cursorY + needed > bodyBottom {
            drawFooterLine()
            beginPage(isFirst: false)
        }
    }

    // MARK: - Header (every page)

    private func drawHeader(isFirstPage: Bool) {
        let topY: CGFloat = margin

        // ─── Optional logo (left of carrier name) ────────────────────
        // Drawn at high interpolation quality, aspect-fit, no stretching.
        var nameOriginX = contentLeft
        if let logo = data.logo {
            let logoMaxHeight: CGFloat = 38
            let aspect = (logo.size.height > 0)
                ? (logo.size.width / logo.size.height)
                : 1.0
            let logoWidth = logoMaxHeight * aspect
            let logoRect = CGRect(
                x: contentLeft,
                y: topY,
                width: logoWidth,
                height: logoMaxHeight
            )
            ctx.cgContext.saveGState()
            ctx.cgContext.interpolationQuality = .high
            ctx.cgContext.setShouldAntialias(true)
            logo.draw(in: logoRect)
            ctx.cgContext.restoreGState()
            nameOriginX = contentLeft + logoWidth + 10
        }

        // LEFT column — carrier name + address lines stay aligned to the
        // logo's right edge when one is present, falling back to the page
        // margin when there isn't.
        drawText(data.carrierName.uppercased(),
                 at: CGPoint(x: nameOriginX, y: topY),
                 font: fontMonoLargeBold, color: .black)
        var y = topY + fontMonoLargeBold.lineHeight + 1
        if !data.carrierAddressLine1.isEmpty {
            drawText(data.carrierAddressLine1,
                     at: CGPoint(x: nameOriginX, y: y),
                     font: fontMono, color: .black)
            y += fontMono.lineHeight
        }
        if !data.carrierAddressLine2.isEmpty {
            drawText(data.carrierAddressLine2,
                     at: CGPoint(x: nameOriginX, y: y),
                     font: fontMono, color: .black)
            y += fontMono.lineHeight
        }
        if !data.carrierPhone.isEmpty {
            drawText(data.carrierPhone,
                     at: CGPoint(x: nameOriginX, y: y),
                     font: fontMono, color: .black)
            y += fontMono.lineHeight
        }

        // RIGHT column (label/value pairs aligned with dotted leaders)
        let rightX = contentLeft + contentWidth * 0.55
        var ry = topY
        let rightLines: [String] = [
            "Owner Settlement Sheet         Page \(pageNumber)\(totalPages > 1 ? " of \(totalPages)" : "")",
            "Settlement Date.....: \(SheetRenderer.dfShort2.string(from: data.settlementDate))",
            "Period: \(SheetRenderer.dfShort2.string(from: data.periodStart)) to \(SheetRenderer.dfShort2.string(from: data.periodEnd))",
            "Leased To...: \(data.leasedTo.isEmpty ? data.carrierName : data.leasedTo)",
            "Owner: \(data.ownerNumber.isEmpty ? "—" : data.ownerNumber)"
        ]
        for line in rightLines {
            drawText(line,
                     at: CGPoint(x: rightX, y: ry),
                     font: fontMono, color: .black)
            ry += fontMono.lineHeight
        }
        if !data.ownerNameHeader.isEmpty {
            drawText(data.ownerNameHeader,
                     at: CGPoint(x: rightX, y: ry),
                     font: fontMonoBold, color: .black)
            ry += fontMonoBold.lineHeight
        }

        // Thin divider
        let dividerY: CGFloat = 110
        drawHLine(y: dividerY, lineWidth: 0.4)
    }

    private func drawOwnerMailingBlock() {
        // Mailing-window block, indented from left
        let blockX = contentLeft + 20
        var y = cursorY
        let mailingLines = [
            data.ownerMailingName,
            data.ownerMailingLine1,
            data.ownerMailingLine2,
            data.ownerMailingLine3
        ].filter { !$0.isEmpty }

        guard !mailingLines.isEmpty else { return }

        for line in mailingLines {
            drawText(line, at: CGPoint(x: blockX, y: y),
                     font: fontMonoBold, color: .black)
            y += fontMonoBold.lineHeight
        }
        cursorY = y + 18
    }

    // MARK: - Tractor label

    private func drawTractorLabel() {
        if data.tractorNumber.isEmpty { return }
        ensureSpace(20)
        drawText("Tractor#     \(data.tractorNumber)",
                 at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight + 6
    }

    // MARK: - Trips

    private func drawAllTrips() {
        for trip in data.trips {
            drawTrip(trip)
        }
    }

    private func drawTrip(_ trip: SettlementSheetTrip) {
        let approxHeight: CGFloat = CGFloat(8 + trip.lines.count * 1) * fontMono.lineHeight
        ensureSpace(approxHeight)

        // Pro# / Dispatch Date line
        let dispatch = trip.dispatchDate.map { SheetRenderer.dfShort2.string(from: $0) } ?? ""
        drawText("              Pro#     \(trip.proNumber)       Dispatch Date \(dispatch)",
                 at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight

        // Tractor Origin / Origin / Destination
        if !trip.tractorOrigin.isEmpty {
            drawText("  Tractor Origin            " + trip.tractorOrigin,
                     at: CGPoint(x: contentLeft, y: cursorY),
                     font: fontMono, color: .black)
            cursorY += fontMono.lineHeight
        }
        if !trip.origin.isEmpty {
            let milesStr = trip.originMiles > 0 ? String(format: "%4.0f", trip.originMiles) : ""
            let originText = "  Origin                    " +
                paddedRight(trip.origin, width: 25) + milesStr
            drawText(originText,
                     at: CGPoint(x: contentLeft, y: cursorY),
                     font: fontMono, color: .black)
            cursorY += fontMono.lineHeight
        }
        if !trip.destination.isEmpty {
            let milesStr = trip.destinationMiles > 0 ? String(format: "%4.0f", trip.destinationMiles) : ""
            let destText = "  Destination               " +
                paddedRight(trip.destination, width: 25) + milesStr
            drawText(destText,
                     at: CGPoint(x: contentLeft, y: cursorY),
                     font: fontMono, color: .black)
            cursorY += fontMono.lineHeight
        }

        // Revenue / Other column header line
        let headerLine = paddedRight("", width: 60)
            + paddedRight("Revenue", width: 14)
            + paddedRight("Other", width: 12)
        drawText(headerLine,
                 at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight

        // Each line
        for line in trip.lines {
            switch line.kind {
            case .revenuePay, .fuelSurcharge:
                drawTripValueLine(line, isRevenue: true)
            case .deduction:
                drawTripValueLine(line, isRevenue: false)
            case .fuelPurchase:
                drawFuelPurchaseLine(line)
            }
        }

        // Total Trip Net
        let net = trip.tripNet
        let netLine = " Total Trip Net"
            + paddedRight("", width: 60)
            + paddedLeft(fmtAmount(net), width: 12)
        drawText(netLine,
                 at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight + 4
    }

    private func drawTripValueLine(_ line: SettlementTripLine, isRevenue: Bool) {
        // Format:  "  <label 30c>  <basis 9c> @ <rate 9c>   <revenue 12c>  <other 12c>"
        let labelCell  = paddedRight("  " + line.label, width: 32)
        let basisCell  = paddedLeft(line.basis, width: 10)
        let rateCell   = paddedLeft(line.rate, width: 12)

        let amountStr: String
        if line.amount < 0 {
            amountStr = String(format: "%.2f-", abs(line.amount))
        } else {
            amountStr = String(format: "%.2f", line.amount)
        }

        let revenueCell: String
        let otherCell: String
        if isRevenue {
            revenueCell = paddedLeft(amountStr, width: 14)
            otherCell   = paddedLeft("", width: 12)
        } else {
            revenueCell = paddedLeft("", width: 14)
            otherCell   = paddedLeft(amountStr, width: 12)
        }
        let row = "\(labelCell) \(basisCell) @ \(rateCell)\(revenueCell)\(otherCell)"
        drawText(row, at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMono, color: .black)
        cursorY += fontMono.lineHeight
    }

    private func drawFuelPurchaseLine(_ line: SettlementTripLine) {
        // Header line: "<date> <label>  <vendor>                 <amount>-"
        let amtStr = String(format: "%.2f-", abs(line.amount))
        let header = "  " + paddedRight(line.label, width: 30)
            + paddedRight("", width: 40)
            + paddedLeft(amtStr, width: 12)
        drawText(header, at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMono, color: .black)
        cursorY += fontMono.lineHeight
        for d in line.detail {
            drawText("       " + d,
                     at: CGPoint(x: contentLeft, y: cursorY),
                     font: fontMono, color: .black)
            cursorY += fontMono.lineHeight
        }
    }

    // MARK: - Adjustments

    private func drawAdjustments() {
        guard !data.adjustments.isEmpty else { return }
        ensureSpace(60)
        drawText(" Adjustments",
                 at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight

        let header = "    " + paddedRight("Date", width: 10) + " "
            + paddedRight("Transaction #", width: 15) + " "
            + paddedRight("Driver ID", width: 9) + " "
            + paddedRight("----Description----", width: 22) + " "
            + paddedRight("Weekly Install", width: 15) + " "
            + paddedRight("Balance", width: 12)
        drawText(header,
                 at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMono, color: .black)
        cursorY += fontMono.lineHeight

        for a in data.adjustments {
            ensureSpace(fontMono.lineHeight + 2)
            let dateStr = a.date.map { SheetRenderer.dfShort2.string(from: $0) } ?? ""
            let weekly = fmtAmount(a.weeklyInstall)
            let balance = a.hasBalance ? fmtAmount(a.balance) : ""
            let row = "  " + paddedRight(dateStr, width: 10) + " "
                + paddedRight(a.transactionId, width: 15) + " "
                + paddedRight(a.driverId, width: 9) + " "
                + paddedRight(a.description, width: 22) + " "
                + paddedLeft(weekly, width: 15) + " "
                + paddedLeft(balance, width: 15)
            drawText(row,
                     at: CGPoint(x: contentLeft, y: cursorY),
                     font: fontMono, color: .black)
            cursorY += fontMono.lineHeight
        }
        ensureSpace(fontMonoBold.lineHeight + 4)
        let total = data.totalAdjustments
        let totalRow = " Total Adjustments"
            + paddedRight("", width: 60)
            + paddedLeft(fmtAmount(total), width: 12)
        drawText(totalRow,
                 at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight + 4
    }

    // MARK: - Repairs

    private func drawRepairs() {
        guard !data.repairs.isEmpty else { return }
        ensureSpace(60)
        drawText(" Repairs",
                 at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight

        let header = "    " + paddedRight("Date", width: 10) + " "
            + paddedRight("Transaction #", width: 15) + " "
            + paddedRight("---RO#---", width: 9) + " "
            + paddedRight("----Description----", width: 22) + " "
            + paddedRight("Weekly Install", width: 15) + " "
            + paddedRight("Balance", width: 12)
        drawText(header,
                 at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMono, color: .black)
        cursorY += fontMono.lineHeight

        for r in data.repairs {
            ensureSpace(fontMono.lineHeight + 2)
            let dateStr = r.date.map { SheetRenderer.dfShort2.string(from: $0) } ?? ""
            let weekly = r.weeklyInstall == 0 ? "" : fmtAmount(r.weeklyInstall)
            let balance = r.hasBalance ? fmtAmount(r.balance) : ""
            let row = "  " + paddedRight(dateStr, width: 10) + " "
                + paddedRight(r.transactionId, width: 15) + " "
                + paddedRight(r.roNumber, width: 9) + " "
                + paddedRight(r.description, width: 22) + " "
                + paddedLeft(weekly, width: 15) + " "
                + paddedLeft(balance, width: 15)
            drawText(row,
                     at: CGPoint(x: contentLeft, y: cursorY),
                     font: fontMono, color: .black)
            cursorY += fontMono.lineHeight
        }
        ensureSpace(fontMonoBold.lineHeight + 4)
        let total = data.totalRepairs
        let totalRow = " Total Repairs"
            + paddedRight("", width: 64)
            + paddedLeft(fmtAmount(total), width: 12)
        drawText(totalRow,
                 at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight + 4
    }

    // MARK: - Check / Direct Deposit

    private func drawCheckLine() {
        ensureSpace(40)
        let dd = data.resolvedDirectDeposit
        let amount = currencyString(dd)
        let line = "       Check # " + paddedRight(data.checkNumber, width: 12)
            + "                 Direct Deposit     $" + amount
        drawText(line,
                 at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight + 8
    }

    // MARK: - Tractor Summary

    private func drawTractorSummary() {
        guard !data.tractorSummary.isEmpty else { return }
        ensureSpace(40)
        // Title centered
        let title = "Tractor Summary for \(data.tractorNumber)"
        let titleWidth = (title as NSString).size(withAttributes: [.font: fontMonoBold]).width
        drawText(title,
                 at: CGPoint(x: (bounds.width - titleWidth) / 2, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight + 2

        // Header row
        let header = paddedRight("", width: 60)
            + paddedLeft("Current", width: 18)
            + paddedLeft("YTD", width: 22)
        drawText(header, at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMono, color: .black)
        cursorY += fontMono.lineHeight

        for line in data.tractorSummary {
            ensureSpace(fontMono.lineHeight + 2)
            let curStr = line.current == 0 ? "" :
                "$\(currencyString(line.current))\(line.currentNegative ? "-" : "")"
            let ytdStr = line.ytd == 0 ? "" :
                "$\(currencyString(line.ytd))\(line.ytdNegative ? "-" : "")"
            let row = " " + paddedRight(line.label, width: 58)
                + paddedLeft(curStr, width: 18)
                + paddedLeft(ytdStr, width: 22)
            drawText(row,
                     at: CGPoint(x: contentLeft, y: cursorY),
                     font: fontMono, color: .black)
            cursorY += fontMono.lineHeight
        }
        cursorY += 6
    }

    // MARK: - Tractor Recap

    private func drawTractorRecap() {
        ensureSpace(60)
        let title = "Tractor Recap"
        let titleWidth = (title as NSString).size(withAttributes: [.font: fontMonoBold]).width
        drawText(title,
                 at: CGPoint(x: (bounds.width - titleWidth) / 2, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight + 2

        let header = "  " + paddedRight("Tractor", width: 12) + " "
            + paddedLeft("Taxable Wages", width: 18) + " "
            + paddedLeft("Advances", width: 14) + " "
            + paddedLeft("Adj/Expense", width: 16) + " "
            + paddedLeft("Total Due", width: 14)
        drawText(header, at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMono, color: .black)
        cursorY += fontMono.lineHeight

        let row = "  " + paddedRight(data.tractorNumber, width: 12) + " "
            + paddedLeft("$" + currencyString(data.taxableWages), width: 18) + " "
            + paddedLeft("$" + currencyString(data.advances), width: 14) + " "
            + paddedLeft(fmtAmountDollar(data.adjExpense), width: 16) + " "
            + paddedLeft("$" + currencyString(data.resolvedTotalDue), width: 14)
        drawText(row, at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight + 8
    }

    // MARK: - Reserve recaps

    private func drawReserves() {
        if let r = data.maintenanceRecap { drawReserveRecap(r) }
        if let r = data.tireRecap        { drawReserveRecap(r) }
        if let r = data.bondRecap        { drawReserveRecap(r) }
        if let f = data.fuelSavings      { drawFuelSavings(f) }
    }

    private func drawReserveRecap(_ r: SettlementReserveRecap) {
        ensureSpace(60)
        let titleWidth = (r.title as NSString).size(withAttributes: [.font: fontMonoBold]).width
        drawText(r.title,
                 at: CGPoint(x: (bounds.width - titleWidth) / 2, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight + 2

        let header = "  " + paddedRight("Tractor", width: 12) + " "
            + paddedLeft("Weekly ADD", width: 14) + " "
            + paddedLeft("YTD ADD", width: 14) + " "
            + paddedLeft("Weekly DED", width: 14) + " "
            + paddedLeft("YTD DED", width: 14) + " "
            + paddedLeft(r.balanceLabel, width: 14)
        drawText(header, at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMono, color: .black)
        cursorY += fontMono.lineHeight

        let row = "  " + paddedRight(data.tractorNumber, width: 12) + " "
            + paddedLeft(fmtAmountDollar(r.weeklyAdd), width: 14) + " "
            + paddedLeft(fmtAmountDollar(r.ytdAdd), width: 14) + " "
            + paddedLeft(fmtAmountDollar(r.weeklyDed), width: 14) + " "
            + paddedLeft(fmtAmountDollar(r.ytdDed), width: 14) + " "
            + paddedLeft(fmtAmountDollar(r.balance), width: 14)
        drawText(row, at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight + 6
    }

    private func drawFuelSavings(_ f: SettlementFuelSavings) {
        ensureSpace(50)
        let title = "Fuel Savings Recap"
        let titleWidth = (title as NSString).size(withAttributes: [.font: fontMonoBold]).width
        drawText(title,
                 at: CGPoint(x: (bounds.width - titleWidth) / 2, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight + 2

        let header = "  " + paddedRight("Tractor", width: 30) + " "
            + paddedLeft("Weekly Savings", width: 18) + " "
            + paddedLeft("YTD Savings", width: 18)
        drawText(header, at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMono, color: .black)
        cursorY += fontMono.lineHeight

        let row = "  " + paddedRight(data.tractorNumber, width: 30) + " "
            + paddedLeft("$" + currencyString(f.weekly), width: 18) + " "
            + paddedLeft("$" + currencyString(f.ytd), width: 18)
        drawText(row, at: CGPoint(x: contentLeft, y: cursorY),
                 font: fontMonoBold, color: .black)
        cursorY += fontMonoBold.lineHeight + 6
    }

    // MARK: - Footer

    private func drawFooterLine() {
        let footerY = bounds.height - 40
        if !data.deliveryMethod.isEmpty {
            drawText("Delivery method: \(data.deliveryMethod)",
                     at: CGPoint(x: contentLeft, y: footerY),
                     font: fontMono, color: .black)
        }
        let stamp = "Generated by Sacred Pathway Driver Hub  •  \(SheetRenderer.dfShort2.string(from: Date()))"
        let w = (stamp as NSString).size(withAttributes: [.font: fontMono]).width
        drawText(stamp,
                 at: CGPoint(x: bounds.width - margin - w, y: footerY),
                 font: fontMono, color: .black)
    }

    // MARK: - Drawing primitives

    private func drawText(_ text: String, at point: CGPoint, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        text.draw(at: point, withAttributes: attrs)
    }

    private func drawHLine(y: CGFloat, lineWidth: CGFloat) {
        let cgctx = ctx.cgContext
        cgctx.saveGState()
        cgctx.setStrokeColor(UIColor.black.cgColor)
        cgctx.setLineWidth(lineWidth)
        cgctx.move(to: CGPoint(x: contentLeft, y: y))
        cgctx.addLine(to: CGPoint(x: contentRight, y: y))
        cgctx.strokePath()
        cgctx.restoreGState()
    }

    // MARK: - Formatting helpers

    /// "$1,234.56" or "$1,234.56-" format used in Tractor Summary / Recap
    private func fmtAmountDollar(_ v: Double) -> String {
        if v == 0 { return "$.00" }
        return "$\(currencyString(abs(v)))\(v < 0 ? "-" : "")"
    }

    /// "1234.56" or "1234.56-" used in trip lines
    private func fmtAmount(_ v: Double) -> String {
        if v == 0 { return "" }
        let s = String(format: "%.2f", abs(v))
        return v < 0 ? "\(s)-" : s
    }

    /// "1,234.56" — thousand-separated, two decimals
    private func currencyString(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        return f.string(from: NSNumber(value: abs(v))) ?? "0.00"
    }

    private func paddedRight(_ s: String, width: Int) -> String {
        if s.count >= width { return String(s.prefix(width)) }
        return s + String(repeating: " ", count: width - s.count)
    }

    private func paddedLeft(_ s: String, width: Int) -> String {
        if s.count >= width { return String(s.suffix(width)) }
        return String(repeating: " ", count: width - s.count) + s
    }
}
