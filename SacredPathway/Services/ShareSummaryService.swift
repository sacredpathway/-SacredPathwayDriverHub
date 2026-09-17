import Foundation
import UIKit
import PDFKit

/// Universal "Share Summary" generator. Produces a single PDF + a plain-text
/// digest for any date range, covering loads, revenue, broker contacts,
/// expenses, settlements, and paid/unpaid status.
///
/// Used by:
///   - Dashboard → Share Summary
///   - Loads list → toolbar Share button
///   - Settings → Operations → Share Summary
///
/// The PDF layout is intentionally simple (no WKWebView dependency) so it
/// runs synchronously on a background queue and is fast even on hundreds of
/// rows.
@MainActor
enum ShareSummaryService {

    // MARK: - Date-range presets

    enum DateRange: Hashable {
        case today
        case thisWeek
        case lastWeek
        case thisMonth
        case lastMonth
        case custom(Date, Date)

        var displayLabel: String {
            switch self {
            case .today: return "Today"
            case .thisWeek: return "This Week"
            case .lastWeek: return "Last Week"
            case .thisMonth: return "This Month"
            case .lastMonth: return "Last Month"
            case .custom(let s, let e):
                let f = DateFormatter()
                f.dateStyle = .medium
                return "\(f.string(from: s)) – \(f.string(from: e))"
            }
        }

        /// Resolve to a concrete (start, endExclusive) tuple in the user's
        /// locale. Week starts on Monday to match PayWeekService.
        var interval: (start: Date, end: Date) {
            var cal = Calendar(identifier: .iso8601)
            cal.firstWeekday = 2  // Monday
            let now = Date()
            switch self {
            case .today:
                let start = cal.startOfDay(for: now)
                let end = cal.date(byAdding: .day, value: 1, to: start) ?? now
                return (start, end)
            case .thisWeek:
                let interval = cal.dateInterval(of: .weekOfYear, for: now) ?? .init(start: now, duration: 0)
                return (interval.start, interval.end)
            case .lastWeek:
                let oneWeekAgo = cal.date(byAdding: .day, value: -7, to: now) ?? now
                let interval = cal.dateInterval(of: .weekOfYear, for: oneWeekAgo) ?? .init(start: now, duration: 0)
                return (interval.start, interval.end)
            case .thisMonth:
                let interval = cal.dateInterval(of: .month, for: now) ?? .init(start: now, duration: 0)
                return (interval.start, interval.end)
            case .lastMonth:
                let lastMonth = cal.date(byAdding: .month, value: -1, to: now) ?? now
                let interval = cal.dateInterval(of: .month, for: lastMonth) ?? .init(start: now, duration: 0)
                return (interval.start, interval.end)
            case .custom(let s, let e):
                let start = cal.startOfDay(for: s)
                let endExclusive = cal.date(byAdding: .day, value: 1,
                                            to: cal.startOfDay(for: e)) ?? e
                return (start, endExclusive)
            }
        }
    }

    // MARK: - Public payload

    /// Aggregated numbers that drive both the PDF and the copy-text view.
    struct Summary {
        let range: DateRange
        let companyName: String
        let loads: [Load]
        let expenses: [Expense]
        // Computed totals
        let totalRevenue: Double
        let totalExpenses: Double
        let netProfit: Double
        let paidCount: Int
        let unpaidCount: Int
        let pendingCount: Int
        let totalMiles: Double
        let avgRatePerMile: Double
        /// (broker, contact, count, revenue) — top brokers by revenue.
        let brokerBreakdown: [BrokerSlice]

        struct BrokerSlice: Identifiable {
            var id: String { brokerName + "|" + (contactName ?? "") }
            let brokerName: String
            let contactName: String?
            let phone: String?
            let phoneExtension: String?
            let email: String?
            let loadCount: Int
            let revenue: Double
        }
    }

    // MARK: - Build

    /// Build a Summary from the raw loads + expenses for the requested range.
    /// Caller is responsible for fetching from Supabase first.
    static func buildSummary(
        range: DateRange,
        companyName: String,
        allLoads: [Load],
        allExpenses: [Expense]
    ) -> Summary {
        let (rangeStart, rangeEnd) = range.interval

        // Loads — keyed off PICKUP DATE only. Single source of truth per
        // the weekly-grouping spec (2026-05-24): no fallback to
        // deliveryDate or createdAt. Loads without a pickup date are
        // excluded from every range filter — they have no week to
        // belong to.
        func loadInRange(_ l: Load) -> Bool {
            guard let d = l.pickupDate else { return false }
            return d >= rangeStart && d < rangeEnd
        }
        let loads = allLoads.filter(loadInRange)
        let loadIds = Set(loads.compactMap { $0.id })

        // Expenses — match against load_id when populated, otherwise fall
        // back to expense created_at.
        let expenses: [Expense] = allExpenses.filter { e in
            if let lid = e.loadId, loadIds.contains(lid) { return true }
            if e.loadId == nil, let d = e.createdAt {
                return d >= rangeStart && d < rangeEnd
            }
            return false
        }

        // Totals
        let totalRevenue = loads.reduce(0) { $0 + ($1.totalRevenue ?? 0) }
        let totalExpenses = expenses.reduce(0) { $0 + $1.amount }
        let totalMiles = loads.reduce(0) { $0 + ($1.totalMiles ?? 0) }
        let avgRPM = totalMiles > 0 ? totalRevenue / totalMiles : 0

        // Paid / unpaid / pending
        // Heuristic: status == "settled" → paid; "ready_for_settlement" → pending;
        //            else → unpaid.
        var paid = 0, unpaid = 0, pending = 0
        for l in loads {
            switch l.loadStatus {
            case .settled: paid += 1
            case .readyForSettlement: pending += 1
            default: unpaid += 1
            }
        }

        // Broker breakdown — group by (brokerName, brokerContactName).
        var slicesMap: [String: Summary.BrokerSlice] = [:]
        for l in loads {
            let bname = l.brokerName?.trimmingCharacters(in: .whitespaces) ?? "Unassigned"
            let cname = l.brokerContactName?.trimmingCharacters(in: .whitespaces)
            let key = bname.lowercased() + "|" + (cname ?? "").lowercased()
            if let s = slicesMap[key] {
                slicesMap[key] = .init(
                    brokerName: s.brokerName,
                    contactName: s.contactName ?? cname,
                    phone: s.phone ?? l.brokerContactPhone,
                    phoneExtension: s.phoneExtension ?? l.brokerPhoneExtension,
                    email: s.email ?? l.brokerContactEmail,
                    loadCount: s.loadCount + 1,
                    revenue: s.revenue + (l.totalRevenue ?? 0)
                )
            } else {
                slicesMap[key] = .init(
                    brokerName: bname,
                    contactName: cname,
                    phone: l.brokerContactPhone,
                    phoneExtension: l.brokerPhoneExtension,
                    email: l.brokerContactEmail,
                    loadCount: 1,
                    revenue: l.totalRevenue ?? 0
                )
            }
        }
        let sortedSlices = slicesMap.values.sorted { $0.revenue > $1.revenue }

        return Summary(
            range: range,
            companyName: companyName,
            loads: loads,
            expenses: expenses,
            totalRevenue: totalRevenue,
            totalExpenses: totalExpenses,
            netProfit: totalRevenue - totalExpenses,
            paidCount: paid,
            unpaidCount: unpaid,
            pendingCount: pending,
            totalMiles: totalMiles,
            avgRatePerMile: avgRPM,
            brokerBreakdown: sortedSlices
        )
    }

    // MARK: - Plain-text export

    /// Plain-text digest suitable for "Copy summary text" or pasting into
    /// a Slack / Messages thread.
    static func textDigest(_ s: Summary) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = .current
        let money: (Double) -> String = { f.string(from: NSNumber(value: $0)) ?? "$0.00" }
        let intFmt = NumberFormatter()
        intFmt.numberStyle = .decimal
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .short

        var lines: [String] = []
        lines.append("\(s.companyName) — Share Summary")
        lines.append(s.range.displayLabel)
        lines.append(String(repeating: "─", count: 32))
        lines.append("Loads: \(s.loads.count)")
        lines.append("Revenue: \(money(s.totalRevenue))")
        lines.append("Expenses: \(money(s.totalExpenses))")
        lines.append("Net Profit: \(money(s.netProfit))")
        if s.totalMiles > 0 {
            lines.append("Miles: \(intFmt.string(from: NSNumber(value: s.totalMiles)) ?? "0")")
            lines.append("Avg Rate/Mile: \(String(format: "$%.2f", s.avgRatePerMile))")
        }
        lines.append("Paid: \(s.paidCount)  ·  Pending: \(s.pendingCount)  ·  Unpaid: \(s.unpaidCount)")
        if !s.brokerBreakdown.isEmpty {
            lines.append("")
            lines.append("Top Brokers")
            for slice in s.brokerBreakdown.prefix(5) {
                let rep = slice.contactName.map { " · \($0)" } ?? ""
                lines.append("• \(slice.brokerName)\(rep) — \(slice.loadCount) load\(slice.loadCount == 1 ? "" : "s") · \(money(slice.revenue))")
            }
        }

        // ---- Per-load detail block (v2.0.2 accuracy pass) ----
        // The user asked for the digest to include broker rep, phone+ext,
        // email, load amount, pickup/delivery, paid status, notes per load.
        if !s.loads.isEmpty {
            lines.append("")
            lines.append("Loads (\(s.loads.count))")
            for load in s.loads {
                let num = load.loadNumber ?? "—"
                let status: String = {
                    switch load.loadStatus {
                    case .settled:            return "[PAID]"
                    case .readyForSettlement: return "[PENDING]"
                    default:                  return "[UNPAID]"
                    }
                }()
                let amt = money(load.totalRevenue ?? 0)
                lines.append("• Load \(num)  \(status)  \(amt)")
                // Pickup / delivery
                let origin = load.origin ?? "—"
                let dest = load.destination ?? "—"
                let pickupStr = load.pickupDate.map { dateFmt.string(from: $0) } ?? "—"
                let deliveryStr = load.deliveryDate.map { dateFmt.string(from: $0) } ?? "—"
                lines.append("    Pickup: \(pickupStr)  ·  \(origin)")
                lines.append("    Delivery: \(deliveryStr)  ·  \(dest)")
                // Broker block — uses per-load snapshot fields so a renamed
                // contact later doesn't rewrite history.
                if let bname = load.brokerName, !bname.isEmpty {
                    var brokerLine = "    Broker: \(bname)"
                    if let mc = load.brokerMcNumber, !mc.isEmpty {
                        brokerLine += " · MC# \(mc)"
                    }
                    lines.append(brokerLine)
                }
                if let rep = load.brokerContactName, !rep.isEmpty {
                    lines.append("    Contact: \(rep)")
                }
                if let phone = load.brokerContactPhone, !phone.isEmpty {
                    if let ext = load.brokerPhoneExtension, !ext.isEmpty {
                        lines.append("    Phone: \(phone) ext \(ext)")
                    } else {
                        lines.append("    Phone: \(phone)")
                    }
                }
                if let email = load.brokerContactEmail, !email.isEmpty {
                    lines.append("    Email: \(email)")
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - PDF export

    /// Render a single-file branded PDF for the summary. Returns the URL on
    /// disk in the temp directory; the caller hands this to UIActivityViewController.
    static func renderPDF(_ s: Summary) throws -> URL {
        let pageWidth: CGFloat = 612    // US Letter @ 72dpi
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 40
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SP-Summary-\(Int(Date().timeIntervalSince1970)).pdf")

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        try renderer.writePDF(to: url) { ctx in
            var y: CGFloat = margin
            ctx.beginPage()

            // Header — gold accent strip + company / range
            let goldStrip = CGRect(x: 0, y: 0, width: pageWidth, height: 6)
            UIColor(red: 0.83, green: 0.66, blue: 0.20, alpha: 1).setFill()
            UIRectFill(goldStrip)

            let titleAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 22),
                .foregroundColor: UIColor.black,
            ]
            let subAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.darkGray,
            ]
            (s.companyName as NSString).draw(at: CGPoint(x: margin, y: y + 18), withAttributes: titleAttr)
            y += 48
            ("Share Summary · \(s.range.displayLabel)" as NSString)
                .draw(at: CGPoint(x: margin, y: y), withAttributes: subAttr)
            y += 24

            // Totals card
            let cardRect = CGRect(x: margin, y: y, width: pageWidth - margin * 2, height: 140)
            UIColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1).setFill()
            UIBezierPath(roundedRect: cardRect, cornerRadius: 10).fill()

            let f = NumberFormatter()
            f.numberStyle = .currency
            let money: (Double) -> String = { f.string(from: NSNumber(value: $0)) ?? "$0" }

            func drawStat(_ label: String, _ value: String, at: CGPoint, accent: Bool = false) {
                let lAttr: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: UIColor.gray,
                ]
                let vAttr: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 18),
                    .foregroundColor: accent
                        ? UIColor(red: 0.20, green: 0.55, blue: 0.30, alpha: 1)
                        : UIColor.black,
                ]
                (label as NSString).draw(at: at, withAttributes: lAttr)
                (value as NSString).draw(at: CGPoint(x: at.x, y: at.y + 14),
                                          withAttributes: vAttr)
            }
            drawStat("REVENUE", money(s.totalRevenue),
                     at: CGPoint(x: margin + 16, y: y + 14))
            drawStat("EXPENSES", money(s.totalExpenses),
                     at: CGPoint(x: margin + 170, y: y + 14))
            drawStat("NET PROFIT", money(s.netProfit),
                     at: CGPoint(x: margin + 330, y: y + 14), accent: true)
            drawStat("LOADS", "\(s.loads.count)",
                     at: CGPoint(x: margin + 16, y: y + 74))
            drawStat("MILES", String(format: "%.0f", s.totalMiles),
                     at: CGPoint(x: margin + 170, y: y + 74))
            drawStat("AVG RATE/MI", String(format: "$%.2f", s.avgRatePerMile),
                     at: CGPoint(x: margin + 330, y: y + 74))
            y += 160

            // Paid / Unpaid summary line
            let bodyAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.black,
            ]
            ("Paid: \(s.paidCount)   ·   Pending: \(s.pendingCount)   ·   Unpaid: \(s.unpaidCount)" as NSString)
                .draw(at: CGPoint(x: margin, y: y), withAttributes: bodyAttr)
            y += 26

            // Section: Top Brokers
            if !s.brokerBreakdown.isEmpty {
                let sectionAttr: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: UIColor.black,
                ]
                ("Brokers" as NSString)
                    .draw(at: CGPoint(x: margin, y: y), withAttributes: sectionAttr)
                y += 20

                for slice in s.brokerBreakdown.prefix(8) {
                    if y > pageHeight - 200 { ctx.beginPage(); y = margin }
                    let rep = slice.contactName.map { " · \($0)" } ?? ""
                    let title = "\(slice.brokerName)\(rep)"
                    (title as NSString)
                        .draw(at: CGPoint(x: margin, y: y),
                              withAttributes: [
                                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                                .foregroundColor: UIColor.black,
                              ])
                    let countText = "\(slice.loadCount) load\(slice.loadCount == 1 ? "" : "s")  ·  \(money(slice.revenue))"
                    let size = (countText as NSString).size(withAttributes: bodyAttr)
                    (countText as NSString)
                        .draw(at: CGPoint(x: pageWidth - margin - size.width, y: y),
                              withAttributes: bodyAttr)
                    y += 14
                    var detail = ""
                    if let phone = slice.phone, !phone.isEmpty {
                        detail += phone
                        if let ext = slice.phoneExtension, !ext.isEmpty {
                            detail += " · ext \(ext)"
                        }
                    }
                    if let email = slice.email, !email.isEmpty {
                        if !detail.isEmpty { detail += "   ·   " }
                        detail += email
                    }
                    if !detail.isEmpty {
                        (detail as NSString)
                            .draw(at: CGPoint(x: margin + 12, y: y),
                                  withAttributes: [
                                    .font: UIFont.systemFont(ofSize: 9),
                                    .foregroundColor: UIColor.darkGray,
                                  ])
                        y += 12
                    }
                    y += 6
                }
                y += 16
            }

            // Section: Loads
            if !s.loads.isEmpty {
                if y > pageHeight - 150 { ctx.beginPage(); y = margin }
                let sectionAttr: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: UIColor.black,
                ]
                ("Loads" as NSString)
                    .draw(at: CGPoint(x: margin, y: y), withAttributes: sectionAttr)
                y += 20

                let dateFmt = DateFormatter()
                dateFmt.dateStyle = .short

                let lineAttr: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 10),
                    .foregroundColor: UIColor.black,
                ]
                let lineBoldAttr: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: UIColor.black,
                ]
                let subAttr: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 9),
                    .foregroundColor: UIColor.darkGray,
                ]
                let statusAttr: (UIColor) -> [NSAttributedString.Key: Any] = { color in
                    [
                        .font: UIFont.systemFont(ofSize: 9, weight: .bold),
                        .foregroundColor: color,
                    ]
                }

                for load in s.loads.prefix(60) {
                    // Estimate per-load block height (header + up to 7 sub-lines).
                    if y > pageHeight - 110 { ctx.beginPage(); y = margin }

                    // ---- Header line: Load #   route   revenue ----
                    let lnum = load.loadNumber ?? "—"
                    let route = "\(load.origin ?? "—") → \(load.destination ?? "—")"
                    let rev = money(load.totalRevenue ?? 0)
                    ("Load \(lnum)" as NSString)
                        .draw(at: CGPoint(x: margin, y: y), withAttributes: lineBoldAttr)
                    let revSize = (rev as NSString).size(withAttributes: lineBoldAttr)
                    (rev as NSString)
                        .draw(at: CGPoint(x: pageWidth - margin - revSize.width, y: y),
                              withAttributes: lineBoldAttr)
                    // Status pill
                    let (statusLabel, statusColor): (String, UIColor) = {
                        switch load.loadStatus {
                        case .settled:            return ("PAID",    UIColor(red: 0.20, green: 0.55, blue: 0.30, alpha: 1))
                        case .readyForSettlement: return ("PENDING", UIColor.systemOrange)
                        default:                   return ("UNPAID",  UIColor.systemRed)
                        }
                    }()
                    let statusX = margin + 80
                    (statusLabel as NSString)
                        .draw(at: CGPoint(x: statusX, y: y + 1), withAttributes: statusAttr(statusColor))
                    y += 14

                    // Route + dates
                    let pickupStr   = load.pickupDate.map   { dateFmt.string(from: $0) } ?? "—"
                    let deliveryStr = load.deliveryDate.map { dateFmt.string(from: $0) } ?? "—"
                    ("Pickup \(pickupStr) → Delivery \(deliveryStr)" as NSString)
                        .draw(at: CGPoint(x: margin + 12, y: y), withAttributes: subAttr)
                    y += 11
                    (route as NSString)
                        .draw(at: CGPoint(x: margin + 12, y: y), withAttributes: subAttr)
                    y += 11

                    // Broker block — snapshot fields, so even if the broker_contact
                    // was later edited, this PDF reflects what was true on this load.
                    if let bname = load.brokerName, !bname.isEmpty {
                        var brokerLine = bname
                        if let mc = load.brokerMcNumber, !mc.isEmpty { brokerLine += " · MC# \(mc)" }
                        ("Broker: \(brokerLine)" as NSString)
                            .draw(at: CGPoint(x: margin + 12, y: y), withAttributes: subAttr)
                        y += 11
                    }
                    if let rep = load.brokerContactName, !rep.isEmpty {
                        var line = "Contact: \(rep)"
                        if let phone = load.brokerContactPhone, !phone.isEmpty {
                            line += "  ·  \(phone)"
                            if let ext = load.brokerPhoneExtension, !ext.isEmpty {
                                line += " ext \(ext)"
                            }
                        }
                        (line as NSString)
                            .draw(at: CGPoint(x: margin + 12, y: y), withAttributes: subAttr)
                        y += 11
                    }
                    if let email = load.brokerContactEmail, !email.isEmpty {
                        ("Email: \(email)" as NSString)
                            .draw(at: CGPoint(x: margin + 12, y: y), withAttributes: subAttr)
                        y += 11
                    }
                    y += 6
                    _ = lineAttr  // keep silence on unused warning
                }
            }

            // Footer
            let footerAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 8),
                .foregroundColor: UIColor.gray,
            ]
            let footer = "Generated by Sacred Pathway Driver Hub · \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))"
            (footer as NSString).draw(at: CGPoint(x: margin, y: pageHeight - 24),
                                       withAttributes: footerAttr)
        }
        return url
    }
}
