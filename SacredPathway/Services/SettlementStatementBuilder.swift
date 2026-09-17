import Foundation

// =============================================================================
//  SettlementStatementBuilder — the driver settlement statement
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). Pure Foundation.
//
//  `SettlementStatementDocument` is the ONE view model behind both the
//  on-screen review and the PDF. It is built from the stored settlement plus a
//  fresh engine run, and `make` refuses to disagree with itself: if the
//  stored net pay and the engine's net pay differ, the document carries a
//  `reconciliationWarning` that the UI shows and the PDF prints.
//
//  `SettlementStatementHTML` renders the document as self-contained HTML
//  (inline CSS, no JavaScript, no network). `SettlementHTMLPDFService`
//  turns that HTML into a paginated vector PDF with the renderer that already
//  produces the existing paystub — no second PDF engine.
//
//  Not a tax document. The footer says so on every statement.
// =============================================================================

struct SettlementCompanyInfo: Hashable {
    var name: String
    var mcNumber: String?
    var dotNumber: String?
    var phone: String?
    var email: String?
    var address: String?

    init(name: String, mcNumber: String? = nil, dotNumber: String? = nil,
         phone: String? = nil, email: String? = nil, address: String? = nil) {
        self.name = name
        self.mcNumber = mcNumber
        self.dotNumber = dotNumber
        self.phone = phone
        self.email = email
        self.address = address
    }

    static let sacredPathwayDefault = SettlementCompanyInfo(name: "Sacred Pathway LLC")
}

struct SettlementStatementDocument {

    struct LoadRow: Hashable, Identifiable {
        var id: UUID
        var loadNumber: String
        var broker: String
        var pickup: String
        var delivery: String
        var origin: String
        var destination: String
        var miles: String
        var gross: Money
        var driverEarnings: Money
        var basis: String
        var isAdjustment: Bool
    }

    struct AmountRow: Hashable, Identifiable {
        var id: UUID
        var label: String
        var detail: String
        var date: String
        var amount: Money
    }

    var company: SettlementCompanyInfo
    var settlementNumber: String
    var periodDescription: String
    var status: SettlementStatus
    var isEstimate: Bool
    var settlementType: SettlementType
    var driverName: String
    var driverReference: String?
    var truckNumber: String?
    var payMethod: String
    var paymentReference: String?
    var paidOn: String?

    var loads: [LoadRow]
    var settlementEarnings: [AmountRow]
    var additions: [AmountRow]
    var deductions: [AmountRow]

    var grossRevenue: Money
    var driverEarnings: Money
    var totalAdditions: Money
    var totalDeductions: Money
    var netPay: Money

    var totalLoads: Int
    var totalMiles: String

    var ytd: SettlementYTDTotals?
    var generatedAt: Date
    var generatedOn: String
    var reconciliationWarning: String?

    static let disclaimer = "This settlement statement summarizes pay for the period shown. It is not a tax document (such as a W-2 or 1099) and is not a substitute for one."

    /// Builds the statement. `result` is computed here from the stored lines,
    /// never passed in, so the statement cannot drift from the engine.
    static func make(
        bundle: SettlementBundle,
        driverName: String,
        company: SettlementCompanyInfo,
        ytd: SettlementYTDTotals?,
        generatedAt: Date = Date(),
        timeZone: TimeZone = .current,
        frozenLoadEarnings: Bool? = nil
    ) -> SettlementStatementDocument {
        let result = bundle.calculate(frozenLoadEarnings: frozenLoadEarnings ?? bundle.settlement.isLocked)
        let s = bundle.settlement

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = timeZone
        df.dateFormat = "MM/dd/yy"
        func d(_ date: Date?) -> String { date.map { df.string(from: $0) } ?? "—" }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = timeZone
        stamp.dateFormat = "MMM d, yyyy 'at' h:mm a"

        let loads = bundle.loadLines.sorted { $0.sortOrder < $1.sortOrder }.map { line in
            LoadRow(
                id: line.id,
                loadNumber: line.loadNumber ?? "—",
                broker: [line.brokerName, line.brokerMcNumber.map { "MC \($0)" }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                pickup: d(line.pickupDate),
                delivery: d(line.deliveryDate),
                origin: line.origin ?? "—",
                destination: line.destination ?? "—",
                miles: SettlementInsights.milesString(line.totalMiles),
                gross: line.grossRate.rounded,
                driverEarnings: result.loadEarnings[line.id] ?? .zero,
                basis: result.loadPayBasis[line.id] ?? "",
                isAdjustment: line.isAdjustment
            )
        }

        let earnings = result.lineItems.filter { $0.kind == .settlementEarning }.map {
            AmountRow(id: $0.id, label: $0.label, detail: $0.basis, date: "", amount: $0.amount)
        }
        let additionsById = Dictionary(bundle.additions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let additions = result.additionLines.map { item in
            AmountRow(id: item.id, label: item.label, detail: item.basis,
                      date: d(additionsById[item.id]?.date), amount: item.amount)
        }
        let deductionsById = Dictionary(bundle.deductions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let deductions = result.driverDeductionLines.map { item in
            AmountRow(id: item.id, label: item.label, detail: item.basis,
                      date: d(deductionsById[item.id]?.date), amount: item.amount)
        }

        var warning: String? = nil
        if !result.reconciles {
            warning = "Statement lines do not add up to net pay. Recalculate before sending."
        } else if s.netPay != nil, s.netPayMoney.rounded != result.netDriverPay.rounded {
            warning = "Stored net pay \(s.netPayMoney.formatted) differs from the recalculated \(result.netDriverPay.formatted). Recalculate before sending."
        }

        return SettlementStatementDocument(
            company: company,
            settlementNumber: s.settlementNumber ?? (s.isEstimateRecord ? "ESTIMATE" : "DRAFT"),
            periodDescription: s.periodDescription,
            status: s.settlementStatus,
            isEstimate: s.isEstimateRecord,
            settlementType: s.effectiveSettlementType,
            driverName: driverName,
            driverReference: s.driverId.map { "DRV-" + String($0.uuidString.prefix(8)).uppercased() },
            truckNumber: s.truckNumber,
            payMethod: s.effectivePayRule.summary,
            paymentReference: s.paymentReference,
            paidOn: s.paidAt.map { d($0) },
            loads: loads,
            settlementEarnings: earnings,
            additions: additions,
            deductions: deductions,
            grossRevenue: result.grossLoadRevenue,
            driverEarnings: result.driverBaseEarnings,
            totalAdditions: result.totalAdditions,
            totalDeductions: result.totalDriverDeductions,
            netPay: result.netDriverPay,
            totalLoads: result.totalLoads,
            totalMiles: SettlementInsights.milesString(result.totalMiles),
            ytd: ytd,
            generatedAt: generatedAt,
            generatedOn: stamp.string(from: generatedAt),
            reconciliationWarning: warning
        )
    }

    var statusLabel: String {
        isEstimate ? "ESTIMATED" : status.displayName.uppercased()
    }

    var fileName: String {
        let safeDriver = driverName.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        return "Settlement-\(settlementNumber)-\(safeDriver).pdf"
    }
}

// MARK: - HTML

enum SettlementStatementHTML {

    static func render(_ doc: SettlementStatementDocument, logoDataURI: String? = nil) -> String {
        let e = escape
        var metaBits: [String] = []
        if let mc = doc.company.mcNumber, !mc.isEmpty { metaBits.append("MC# \(e(mc))") }
        if let dot = doc.company.dotNumber, !dot.isEmpty { metaBits.append("DOT# \(e(dot))") }
        var contactBits: [String] = []
        if let a = doc.company.address, !a.isEmpty { contactBits.append(e(a)) }
        if let p = doc.company.phone, !p.isEmpty { contactBits.append(e(p)) }
        if let m = doc.company.email, !m.isEmpty { contactBits.append(e(m)) }

        let logo = logoDataURI.map { "<img class=\"logo\" alt=\"\" src=\"\($0)\">" } ?? ""
        let statusClass: String = {
            if doc.isEstimate { return "st-est" }
            switch doc.status {
            case .paid: return "st-paid"
            case .approved: return "st-ok"
            case .voided: return "st-void"
            case .draft, .readyForReview: return "st-draft"
            }
        }()

        var html = """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="UTF-8">
        <meta name="viewport" content="width=612">
        <title>\(e(doc.company.name)) — Settlement \(e(doc.settlementNumber))</title>
        <style>\(css)</style></head><body>
        """

        if doc.isEstimate {
            html += "<div class=\"banner est\">ESTIMATED — not a final settlement. Figures change as loads, deductions and advances are finalized.</div>"
        }
        if doc.status == .voided {
            html += "<div class=\"banner void\">VOIDED — this settlement was cancelled and is kept for history only.</div>"
        }
        if let w = doc.reconciliationWarning {
            html += "<div class=\"banner void\">\(e(w))</div>"
        }

        html += """
        <header class="hdr">
          <div class="brand">\(logo)<div>
            <div class="co">\(e(doc.company.name))</div>
            <div class="sub">\(metaBits.joined(separator: " &nbsp;|&nbsp; "))</div>
            <div class="sub">\(contactBits.joined(separator: " &nbsp;·&nbsp; "))</div>
          </div></div>
          <div class="title">
            <div class="tag">Driver Settlement Statement</div>
            <div class="num">\(e(doc.settlementNumber))</div>
            <span class="status \(statusClass)">\(e(doc.statusLabel))</span>
          </div>
        </header>
        <table class="kv">
          <tr><th>Driver</th><td>\(e(doc.driverName))</td><th>Settlement Period</th><td>\(e(doc.periodDescription))</td></tr>
          <tr><th>Driver ID</th><td>\(e(doc.driverReference ?? "—"))</td><th>Truck / Unit</th><td>\(e(doc.truckNumber ?? "—"))</td></tr>
          <tr><th>Pay Method</th><td>\(e(doc.payMethod))</td><th>Settlement Type</th><td>\(e(doc.settlementType.displayName))</td></tr>
        """
        if doc.status == .paid {
            html += "<tr><th>Paid On</th><td>\(e(doc.paidOn ?? "—"))</td><th>Payment Ref.</th><td>\(e(doc.paymentReference ?? "—"))</td></tr>"
        }
        html += "</table>"

        // Loads
        html += "<h2>Load Breakdown <span>\(doc.totalLoads) load\(doc.totalLoads == 1 ? "" : "s") · \(e(doc.totalMiles)) mi</span></h2>"
        if doc.loads.isEmpty {
            html += "<p class=\"empty\">No loads on this settlement.</p>"
        } else {
            html += """
            <table class="grid"><thead><tr>
              <th>Load #</th><th>Broker / Customer</th><th>Pickup</th><th>Delivery</th>
              <th>Origin → Destination</th><th class="r">Miles</th><th class="r">Gross</th><th class="r">Driver</th>
            </tr></thead><tbody>
            """
            for row in doc.loads {
                html += """
                <tr>
                  <td class="mono">\(e(row.loadNumber))\(row.isAdjustment ? " <span class=\"adj\">ADJ</span>" : "")</td>
                  <td>\(e(row.broker.isEmpty ? "—" : row.broker))</td>
                  <td>\(e(row.pickup))</td><td>\(e(row.delivery))</td>
                  <td>\(e(row.origin)) → \(e(row.destination))<div class="basis">\(e(row.basis))</div></td>
                  <td class="r">\(e(row.miles))</td>
                  <td class="r">\(row.gross.formatted)</td>
                  <td class="r">\(row.driverEarnings.formatted)</td>
                </tr>
                """
            }
            html += "<tr class=\"tot\"><td colspan=\"6\">Total</td><td class=\"r\">\(doc.grossRevenue.formatted)</td><td class=\"r\">\(Money.sum(doc.loads.map(\.driverEarnings)).formatted)</td></tr>"
            html += "</tbody></table>"
        }

        if !doc.settlementEarnings.isEmpty {
            html += section("Other Earnings", rows: doc.settlementEarnings, credit: true,
                            total: Money.sum(doc.settlementEarnings.map(\.amount)))
        }
        html += section("Additions", rows: doc.additions, credit: true, total: doc.totalAdditions)
        html += section("Deductions", rows: doc.deductions, credit: false, total: doc.totalDeductions)

        // Summary
        html += """
        <div class="summary">
          <table class="sum">
            <tr><th>Gross Revenue</th><td>\(doc.grossRevenue.formatted)</td></tr>
            <tr><th>Driver Earnings</th><td>\(doc.driverEarnings.formatted)</td></tr>
            <tr><th>Additions</th><td class="pos">\(doc.totalAdditions.formattedSigned(asCredit: true))</td></tr>
            <tr><th>Deductions</th><td class="neg">\(doc.totalDeductions.formattedSigned(asCredit: false))</td></tr>
          </table>
          <div class="net"><div class="lbl">\(doc.isEstimate ? "Estimated Net Pay" : "Net Pay")</div><div class="amt">\(doc.netPay.formatted)</div></div>
        </div>
        """

        if let ytd = doc.ytd {
            html += """
            <h2>Year to Date \(ytd.year) <span>\(ytd.settlementCount) paid settlement\(ytd.settlementCount == 1 ? "" : "s")</span></h2>
            <table class="kv ytd"><tr>
              <th>Earnings</th><td>\(ytd.driverEarnings.formatted)</td>
              <th>Additions</th><td>\(ytd.additions.formatted)</td>
              <th>Deductions</th><td>\(ytd.deductions.formatted)</td>
              <th>Net Pay</th><td>\(ytd.netPay.formatted)</td>
            </tr></table>
            """
        }

        html += """
        <footer>
          <div>Generated \(e(doc.generatedOn)) · Status: \(e(doc.statusLabel)) · \(e(doc.company.name))</div>
          <div class="disc">\(e(SettlementStatementDocument.disclaimer))</div>
        </footer>
        </body></html>
        """
        return html
    }

    private static func section(
        _ title: String,
        rows: [SettlementStatementDocument.AmountRow],
        credit: Bool,
        total: Money
    ) -> String {
        var h = "<h2>\(escape(title))</h2>"
        guard !rows.isEmpty else {
            return h + "<p class=\"empty\">None this period.</p>"
        }
        h += "<table class=\"grid\"><thead><tr><th>Description</th><th>Category</th><th>Date</th><th class=\"r\">Amount</th></tr></thead><tbody>"
        for r in rows {
            h += "<tr><td>\(escape(r.label))</td><td>\(escape(r.detail))</td><td>\(escape(r.date))</td>"
            h += "<td class=\"r \(credit ? "pos" : "neg")\">\(r.amount.formattedSigned(asCredit: credit))</td></tr>"
        }
        h += "<tr class=\"tot\"><td colspan=\"3\">Total \(escape(title))</td><td class=\"r\">\(total.formattedSigned(asCredit: credit))</td></tr>"
        h += "</tbody></table>"
        return h
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Ink + gold, matching the existing Sacred Pathway paystub template.
    static let css = """
    @page { size: Letter; margin: 0; }
    * { box-sizing: border-box; -webkit-print-color-adjust: exact; }
    body { margin: 0; padding: 26pt 28pt 40pt; color: #0a0e14;
      font-family: -apple-system, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
      font-size: 8.8pt; line-height: 1.38; font-feature-settings: "tnum" 1; }
    .banner { padding: 6pt 9pt; border-radius: 4pt; font-weight: 700; margin-bottom: 8pt; font-size: 8.5pt; }
    .banner.est { background: #fff7e0; border: 1pt solid #c9a96e; color: #7a5a14; }
    .banner.void { background: #fdecec; border: 1pt solid #cc3333; color: #8a1f1f; }
    .hdr { display: flex; justify-content: space-between; align-items: center;
      border-bottom: 2pt solid #0a0e14; padding-bottom: 8pt; margin-bottom: 3pt; }
    .hdr + table { margin-top: 10pt; }
    .brand { display: flex; align-items: center; gap: 10pt; }
    .logo { height: 46pt; width: auto; }
    .co { font-size: 14pt; font-weight: 800; letter-spacing: -0.2pt; }
    .sub { color: #5d6573; font-size: 7.6pt; }
    .title { text-align: right; }
    .tag { font-size: 7.5pt; letter-spacing: 1.8pt; text-transform: uppercase; color: #5d6573; font-weight: 700; }
    .num { font-size: 18pt; font-weight: 800; margin: 2pt 0 4pt; }
    .status { display: inline-block; font-size: 7.2pt; font-weight: 800; letter-spacing: 1.2pt;
      padding: 2pt 7pt; border-radius: 3pt; border: 1pt solid; }
    .st-paid { color: #0e7a3d; border-color: #0e7a3d; background: rgba(14,122,61,.08); }
    .st-ok { color: #a48650; border-color: #c9a96e; background: rgba(201,169,110,.12); }
    .st-draft { color: #5d6573; border-color: #9aa1ab; }
    .st-est { color: #7a5a14; border-color: #c9a96e; background: #fff7e0; }
    .st-void { color: #8a1f1f; border-color: #cc3333; background: #fdecec; }
    h2 { font-size: 9pt; letter-spacing: 1.4pt; text-transform: uppercase; margin: 14pt 0 5pt;
      padding-bottom: 3pt; border-bottom: 1pt solid #c9a96e; }
    h2 span { float: right; letter-spacing: 0; text-transform: none; color: #5d6573; font-weight: 600; }
    table { width: 100%; border-collapse: collapse; page-break-inside: auto; }
    tr { page-break-inside: avoid; }
    .kv th { text-align: left; color: #5d6573; font-weight: 700; font-size: 7.4pt;
      text-transform: uppercase; letter-spacing: .6pt; padding: 3pt 6pt 3pt 0; width: 17%; }
    .kv td { padding: 3pt 10pt 3pt 0; font-weight: 600; }
    .grid th { background: #f1f4f8; text-align: left; font-size: 7.2pt; text-transform: uppercase;
      letter-spacing: .5pt; color: #3a4252; padding: 4pt 5pt; border-bottom: 1pt solid #dee1e6; }
    .grid td { padding: 4pt 5pt; border-bottom: .6pt solid #ebedf0; vertical-align: top; }
    .grid .tot td { font-weight: 800; border-top: 1pt solid #0a0e14; border-bottom: none; }
    .r { text-align: right; white-space: nowrap; }
    .mono { font-family: "SF Mono", Menlo, monospace; font-size: 8pt; }
    .basis { color: #7d8390; font-size: 7pt; }
    .adj { color: #a48650; font-size: 6.5pt; font-weight: 800; border: .6pt solid #c9a96e; padding: 0 2pt; border-radius: 2pt; }
    .pos { color: #0e7a3d; }
    .neg { color: #a12626; }
    .empty { color: #7d8390; margin: 2pt 0; }
    .summary { display: flex; gap: 14pt; align-items: stretch; margin-top: 14pt; page-break-inside: avoid; }
    .sum { flex: 1; }
    .sum th { text-align: left; padding: 4pt 0; font-weight: 600; color: #3a4252; }
    .sum td { text-align: right; padding: 4pt 0; font-weight: 700; }
    .net { flex: 0 0 190pt; background: #0a0e14; color: #fff; border-radius: 6pt; padding: 12pt;
      border-bottom: 3pt solid #c9a96e; display: flex; flex-direction: column; justify-content: center; }
    .net .lbl { font-size: 7.6pt; letter-spacing: 1.8pt; text-transform: uppercase; color: #e8d7b0; font-weight: 700; }
    .net .amt { font-size: 24pt; font-weight: 800; letter-spacing: -.5pt; }
    .ytd th { width: auto; }
    footer { margin-top: 18pt; padding-top: 6pt; border-top: 1pt solid #dee1e6; color: #5d6573; font-size: 7pt; }
    footer .disc { margin-top: 3pt; font-style: italic; }
    """
}

// MARK: - Report HTML

enum SettlementReportHTML {

    static func render(_ report: SettlementReport, company: SettlementCompanyInfo) -> String {
        let e = SettlementStatementHTML.escape
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "MMM d, yyyy 'at' h:mm a"

        var h = """
        <!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
        <meta name="viewport" content="width=612">
        <title>\(e(company.name)) — \(e(report.title))</title>
        <style>\(SettlementStatementHTML.css)</style></head><body>
        <header class="hdr">
          <div class="brand"><div>
            <div class="co">\(e(company.name))</div>
            <div class="sub">\(e(report.subtitle))</div>
          </div></div>
          <div class="title"><div class="tag">Report</div><div class="num">\(e(report.title))</div></div>
        </header>
        """
        if report.rows.isEmpty {
            h += "<p class=\"empty\">No records in this date range.</p>"
        } else {
            h += "<table class=\"grid\"><thead><tr>"
            for (i, c) in report.columns.enumerated() {
                h += "<th\(report.numericColumns.contains(i) ? " class=\"r\"" : "")>\(e(c))</th>"
            }
            h += "</tr></thead><tbody>"
            for row in report.rows {
                h += "<tr>"
                for (i, cell) in row.enumerated() {
                    h += "<td\(report.numericColumns.contains(i) ? " class=\"r\"" : "")>\(e(cell))</td>"
                }
                h += "</tr>"
            }
            if let totals = report.totals {
                h += "<tr class=\"tot\">"
                for (i, cell) in totals.enumerated() {
                    h += "<td\(report.numericColumns.contains(i) ? " class=\"r\"" : "")>\(e(cell))</td>"
                }
                h += "</tr>"
            }
            h += "</tbody></table>"
        }
        h += """
        <footer><div>Generated \(e(stamp.string(from: report.generatedAt))) · \(report.rows.count) row\(report.rows.count == 1 ? "" : "s")</div>
        <div class="disc">Management report. Not a tax document.</div></footer>
        </body></html>
        """
        return h
    }
}
