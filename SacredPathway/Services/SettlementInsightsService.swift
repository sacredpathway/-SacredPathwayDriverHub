import Foundation

// =============================================================================
//  SettlementInsightsService — history search, YTD, dashboard, estimates,
//  reports and CSV
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). Pure Foundation. Read-only views over a
//  `SettlementLedger` plus the operational loads / expenses.
//
//  Separation rule: an ESTIMATE never enters history, YTD, dashboard paid /
//  unpaid totals or any report. Estimates are built on demand and never saved.
// =============================================================================

// MARK: - Date ranges

enum SettlementDateRangePreset: String, CaseIterable, Identifiable {
    case thisWeek, lastWeek, thisMonth, lastMonth, yearToDate, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thisWeek:   return "This Week"
        case .lastWeek:   return "Last Week"
        case .thisMonth:  return "This Month"
        case .lastMonth:  return "Last Month"
        case .yearToDate: return "Year to Date"
        case .custom:     return "Custom"
        }
    }
}

/// Inclusive day range.
struct SettlementDateRange: Hashable {
    var start: Date
    var end: Date

    /// `firstWeekday` follows PayWeekService (1 = Sunday … 7 = Saturday).
    static func preset(
        _ preset: SettlementDateRangePreset,
        now: Date = Date(),
        firstWeekday: Int = 2,
        custom: SettlementDateRange? = nil,
        calendar base: Calendar = Calendar(identifier: .gregorian)
    ) -> SettlementDateRange {
        var cal = base
        cal.firstWeekday = firstWeekday
        let today = cal.startOfDay(for: now)
        func week(containing d: Date) -> SettlementDateRange {
            let interval = cal.dateInterval(of: .weekOfYear, for: d)
                ?? DateInterval(start: today, duration: 7 * 86_400)
            let last = cal.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            return SettlementDateRange(start: interval.start, end: cal.startOfDay(for: last))
        }
        func month(containing d: Date) -> SettlementDateRange {
            let interval = cal.dateInterval(of: .month, for: d)
                ?? DateInterval(start: today, duration: 30 * 86_400)
            let last = cal.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            return SettlementDateRange(start: interval.start, end: cal.startOfDay(for: last))
        }
        switch preset {
        case .thisWeek:
            return week(containing: today)
        case .lastWeek:
            return week(containing: cal.date(byAdding: .day, value: -7, to: today) ?? today)
        case .thisMonth:
            return month(containing: today)
        case .lastMonth:
            return month(containing: cal.date(byAdding: .month, value: -1, to: today) ?? today)
        case .yearToDate:
            let start = cal.date(from: cal.dateComponents([.year], from: today)) ?? today
            return SettlementDateRange(start: start, end: today)
        case .custom:
            return custom ?? week(containing: today)
        }
    }

    func contains(_ date: Date?, calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        guard let date else { return false }
        return date >= calendar.startOfDay(for: start)
            && date <= SettlementWorkflowService.endOfDay(end, calendar: calendar)
    }

    var description: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }
}

// MARK: - History filter

enum SettlementPaidFilter: String, CaseIterable, Identifiable {
    case all, paid, unpaid
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: return "All"
        case .paid: return "Paid"
        case .unpaid: return "Unpaid"
        }
    }
}

struct SettlementHistoryFilter {
    var driverId: UUID?
    var truckNumber: String?
    /// Free text: settlement number, load number or broker.
    var query: String
    var statuses: Set<SettlementStatus>
    var paid: SettlementPaidFilter
    var dateRange: SettlementDateRange?

    init(
        driverId: UUID? = nil,
        truckNumber: String? = nil,
        query: String = "",
        statuses: Set<SettlementStatus> = [],
        paid: SettlementPaidFilter = .all,
        dateRange: SettlementDateRange? = nil
    ) {
        self.driverId = driverId
        self.truckNumber = truckNumber
        self.query = query
        self.statuses = statuses
        self.paid = paid
        self.dateRange = dateRange
    }
}

struct SettlementYTDTotals: Hashable {
    var year: Int
    var settlementCount: Int
    var driverEarnings: Money
    var additions: Money
    var deductions: Money
    var netPay: Money
}

struct SettlementDashboardMetrics: Hashable {
    var range: SettlementDateRange
    var grossRevenue: Money
    var completedLoads: Int
    var pendingLoads: Int
    var driverPay: Money
    var fuel: Money
    var otherExpenses: Money
    var companyRetained: Money
    /// Gross revenue − driver pay − expenses. Always labelled "Estimated".
    var estimatedProfit: Money
    var unpaidCount: Int
    var unpaidAmount: Money
    var draftCount: Int
    var paidCount: Int
    var paidAmount: Money
}

// MARK: - Reports

enum SettlementReportKind: String, CaseIterable, Identifiable {
    case driverEarnings
    case settlementHistory
    case companyRevenue
    case expenses
    case driverAdvances
    case leaseOperator

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .driverEarnings:    return "Driver Earnings"
        case .settlementHistory: return "Settlement History"
        case .companyRevenue:    return "Company Revenue"
        case .expenses:          return "Expense Report"
        case .driverAdvances:    return "Driver Advances"
        case .leaseOperator:     return "Lease Operator Report"
        }
    }

    var systemImage: String {
        switch self {
        case .driverEarnings:    return "person.text.rectangle"
        case .settlementHistory: return "list.bullet.rectangle"
        case .companyRevenue:    return "building.columns"
        case .expenses:          return "creditcard"
        case .driverAdvances:    return "banknote"
        case .leaseOperator:     return "truck.box"
        }
    }
}

struct SettlementReport {
    var kind: SettlementReportKind
    var title: String
    var subtitle: String
    var columns: [String]
    /// Columns whose cells are currency (right-aligned in the PDF).
    var numericColumns: Set<Int>
    var rows: [[String]]
    var totals: [String]?
    var generatedAt: Date
}

enum SettlementInsights {

    // MARK: History

    static func filter(
        _ ledger: SettlementLedger,
        _ filter: SettlementHistoryFilter,
        driverNames: [UUID: String] = [:],
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [Settlement] {
        let q = filter.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ledger.settlements
            .filter { !$0.isEstimateRecord }
            .filter { s in
                if let d = filter.driverId, s.driverId != d { return false }
                if let t = filter.truckNumber?.trimmingCharacters(in: .whitespaces), !t.isEmpty,
                   (s.truckNumber ?? "").caseInsensitiveCompare(t) != .orderedSame { return false }
                if !filter.statuses.isEmpty, !filter.statuses.contains(s.settlementStatus) { return false }
                switch filter.paid {
                case .all: break
                case .paid: if s.settlementStatus != .paid { return false }
                case .unpaid:
                    if s.settlementStatus == .paid || s.settlementStatus == .voided { return false }
                }
                if let range = filter.dateRange {
                    let overlaps = (s.settlementPeriodStart.map { $0 <= SettlementWorkflowService.endOfDay(range.end, calendar: calendar) } ?? false)
                        && (s.settlementPeriodEnd.map { $0 >= calendar.startOfDay(for: range.start) } ?? false)
                    if !overlaps { return false }
                }
                guard !q.isEmpty else { return true }
                if (s.settlementNumber ?? "").lowercased().contains(q) { return true }
                if let d = s.driverId, (driverNames[d] ?? "").lowercased().contains(q) { return true }
                if (s.truckNumber ?? "").lowercased().contains(q) { return true }
                guard let sid = s.id else { return false }
                return ledger.loadLines.contains { line in
                    line.settlementId == sid && (
                        (line.loadNumber ?? "").lowercased().contains(q)
                        || (line.brokerName ?? "").lowercased().contains(q)
                        || (line.brokerMcNumber ?? "").lowercased().contains(q))
                }
            }
            .sorted { lhs, rhs in
                let l = lhs.settlementPeriodEnd ?? lhs.createdAt ?? .distantPast
                let r = rhs.settlementPeriodEnd ?? rhs.createdAt ?? .distantPast
                if l != r { return l > r }
                return (lhs.settlementNumber ?? "") > (rhs.settlementNumber ?? "")
            }
    }

    // MARK: YTD

    /// Year-to-date totals from PAID settlements only (money that actually
    /// went out). Returns nil when there is no paid history — the statement
    /// then omits the YTD block rather than printing a misleading $0.00.
    static func ytd(
        _ ledger: SettlementLedger,
        driverId: UUID,
        year: Int,
        throughPeriodEnd: Date? = nil,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> SettlementYTDTotals? {
        let rows = ledger.settlements.filter { s in
            guard s.driverId == driverId, s.settlementStatus == .paid, !s.isEstimateRecord,
                  let end = s.settlementPeriodEnd,
                  calendar.component(.year, from: end) == year else { return false }
            if let cutoff = throughPeriodEnd, end > cutoff { return false }
            return true
        }
        guard !rows.isEmpty else { return nil }
        return SettlementYTDTotals(
            year: year,
            settlementCount: rows.count,
            driverEarnings: Money.sum(rows.map { $0.totalDriverEarnings ?? Money(double: $0.driverPayAmount ?? 0) }),
            additions: Money.sum(rows.map { $0.totalAdditions ?? .zero }),
            deductions: Money.sum(rows.map { $0.totalDeductions ?? .zero }),
            netPay: Money.sum(rows.map(\.netPayMoney))
        )
    }

    static func lastSettlement(_ ledger: SettlementLedger, driverId: UUID) -> Settlement? {
        ledger.settlements
            .filter { $0.driverId == driverId && !$0.isEstimateRecord && $0.settlementStatus != .voided }
            .max { ($0.settlementPeriodEnd ?? .distantPast) < ($1.settlementPeriodEnd ?? .distantPast) }
    }

    // MARK: Estimate

    /// A live, unsaved projection for the current period. Includes booked and
    /// in-progress loads; never numbered, never saved, flagged `isEstimate`.
    static func estimate(
        driver: Driver,
        paySettings: DriverPaySettings,
        profileId: UUID,
        loads: [Load],
        ledger: SettlementLedger,
        range: SettlementDateRange,
        companyFees: CompanyFeeSettings,
        includeUnassigned: Bool = false,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> SettlementBundle? {
        guard let driverId = driver.id else { return nil }
        let eligible = SettlementWorkflowService.eligibleLoads(
            from: loads, driverId: driverId,
            periodStart: range.start, periodEnd: range.end,
            ledger: ledger, includeUnassigned: includeUnassigned,
            includeInProgress: true, now: now, calendar: calendar
        ).filter { $0.isSelectable && !$0.legacySettled }
        let options = SettlementDraftOptions(
            profileId: profileId, driver: driver, paySettings: paySettings,
            periodStart: range.start, periodEnd: range.end,
            companyFees: companyFees,
            applyRecurringDeductions: true,
            advancePolicy: .manual,
            isEstimate: true,
            actor: .unknown, now: now, calendar: calendar)
        var bundle = SettlementWorkflowService.makeDraft(
            options: options, loads: eligible.map(\.load), ledger: ledger)
        bundle.auditEvents = []
        return bundle
    }

    // MARK: Dashboard

    static func dashboard(
        ledger: SettlementLedger,
        loads: [Load],
        expenses: [Expense],
        range: SettlementDateRange,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> SettlementDashboardMetrics {
        var seen: Set<UUID> = []
        let periodLoads = loads.filter { load in
            guard let id = load.id, !seen.contains(id) else { return false }
            seen.insert(id)
            return range.contains(load.pickupDate, calendar: calendar)
        }
        let gross = Money.sum(periodLoads.map { Money(double: $0.totalRevenue ?? 0).rounded })
        let completed = periodLoads.filter {
            SettlementWorkflowService.isCompleted($0, now: now, calendar: calendar)
        }.count

        let periodExpenses = expenses.filter {
            range.contains($0.receiptDate ?? $0.createdAt, calendar: calendar)
        }
        let fuel = Money.sum(periodExpenses
            .filter { $0.category.lowercased() == "fuel" }
            .map { Money(double: $0.amount).rounded })
        let other = Money.sum(periodExpenses
            .filter { $0.category.lowercased() != "fuel" }
            .map { Money(double: $0.amount).rounded })

        let inRange = ledger.settlements.filter {
            !$0.isEstimateRecord && range.contains($0.settlementPeriodEnd, calendar: calendar)
        }
        let financial = inRange.filter { $0.settlementStatus.isFinancialRecord }
        let driverPay = Money.sum(financial.map {
            ($0.totalDriverEarnings ?? .zero) + ($0.totalAdditions ?? .zero)
        })
        let retained = Money.sum(financial.map { $0.companyRetained ?? .zero })

        let unpaid = ledger.settlements.filter {
            !$0.isEstimateRecord && $0.settlementStatus == .approved
        }
        let drafts = ledger.settlements.filter {
            !$0.isEstimateRecord
                && ($0.settlementStatus == .draft || $0.settlementStatus == .readyForReview)
        }
        let paid = ledger.settlements.filter {
            !$0.isEstimateRecord && $0.settlementStatus == .paid
                && range.contains($0.paidAt ?? $0.settlementPeriodEnd, calendar: calendar)
        }

        return SettlementDashboardMetrics(
            range: range,
            grossRevenue: gross,
            completedLoads: completed,
            pendingLoads: periodLoads.count - completed,
            driverPay: driverPay,
            fuel: fuel,
            otherExpenses: other,
            companyRetained: retained,
            estimatedProfit: (gross - driverPay - fuel - other).rounded,
            unpaidCount: unpaid.count,
            unpaidAmount: Money.sum(unpaid.map(\.netPayMoney)),
            draftCount: drafts.count,
            paidCount: paid.count,
            paidAmount: Money.sum(paid.map(\.netPayMoney))
        )
    }

    // MARK: Reports

    static func report(
        _ kind: SettlementReportKind,
        ledger: SettlementLedger,
        range: SettlementDateRange,
        driverNames: [UUID: String],
        expenses: [Expense] = [],
        driverId: UUID? = nil,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> SettlementReport {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MM/dd/yyyy"
        func d(_ date: Date?) -> String { date.map { df.string(from: $0) } ?? "" }
        func name(_ id: UUID?) -> String { id.flatMap { driverNames[$0] } ?? "Unknown driver" }

        let settlements = ledger.settlements.filter { s in
            !s.isEstimateRecord
                && range.contains(s.settlementPeriodEnd, calendar: calendar)
                && (driverId == nil || s.driverId == driverId)
        }.sorted { ($0.settlementPeriodEnd ?? .distantPast) < ($1.settlementPeriodEnd ?? .distantPast) }
        let financial = settlements.filter { $0.settlementStatus.isFinancialRecord }

        var report = SettlementReport(
            kind: kind, title: kind.displayName, subtitle: range.description,
            columns: [], numericColumns: [], rows: [], totals: nil, generatedAt: now)

        switch kind {
        case .driverEarnings:
            report.subtitle += " · approved & paid settlements"
            report.columns = ["Driver", "Settlements", "Loads", "Miles", "Gross Revenue",
                              "Driver Earnings", "Additions", "Deductions", "Net Pay"]
            report.numericColumns = [4, 5, 6, 7, 8]
            let byDriver = Dictionary(grouping: financial) { $0.driverId }
            var tGross = Money.zero, tEarn = Money.zero, tAdd = Money.zero, tDed = Money.zero, tNet = Money.zero
            var tLoads = 0, tCount = 0
            var tMiles = Decimal(0)
            for (driver, rows) in byDriver.sorted(by: { name($0.key) < name($1.key) }) {
                let ids = Set(rows.compactMap(\.id))
                let loads = ledger.loadLines.filter { $0.settlementId.map(ids.contains) ?? false }.count
                let miles = rows.reduce(Decimal(0)) { $0 + ($1.totalMilesValue ?? 0) }
                let gross = Money.sum(rows.map(\.grossLoadRevenueMoney))
                let earn = Money.sum(rows.map { $0.totalDriverEarnings ?? .zero })
                let add = Money.sum(rows.map { $0.totalAdditions ?? .zero })
                let ded = Money.sum(rows.map { $0.totalDeductions ?? .zero })
                let net = Money.sum(rows.map(\.netPayMoney))
                report.rows.append([name(driver), "\(rows.count)", "\(loads)", milesString(miles),
                                    gross.formatted, earn.formatted, add.formatted, ded.formatted, net.formatted])
                tGross += gross; tEarn += earn; tAdd += add; tDed += ded; tNet += net
                tLoads += loads; tCount += rows.count; tMiles += miles
            }
            report.totals = ["Total", "\(tCount)", "\(tLoads)", milesString(tMiles), tGross.formatted,
                             tEarn.formatted, tAdd.formatted, tDed.formatted, tNet.formatted]

        case .settlementHistory:
            report.columns = ["Number", "Driver", "Period", "Status", "Truck",
                              "Gross", "Net Pay", "Paid On", "Reference"]
            report.numericColumns = [5, 6]
            for s in settlements {
                report.rows.append([s.displayNumber, name(s.driverId), s.periodDescription,
                                    s.settlementStatus.displayName, s.truckNumber ?? "",
                                    s.grossLoadRevenueMoney.formatted, s.netPayMoney.formatted,
                                    d(s.paidAt), s.paymentReference ?? ""])
            }
            report.totals = ["Total", "", "", "\(settlements.count) settlements", "",
                             Money.sum(financial.map(\.grossLoadRevenueMoney)).formatted,
                             Money.sum(financial.map(\.netPayMoney)).formatted, "", ""]
            report.subtitle += " · totals exclude drafts and voided"

        case .companyRevenue:
            report.columns = ["Period End", "Number", "Driver", "Gross Revenue",
                              "Driver Pay", "Company Expenses", "Company Retained"]
            report.numericColumns = [3, 4, 5, 6]
            for s in financial {
                let pay = (s.totalDriverEarnings ?? .zero) + (s.totalAdditions ?? .zero)
                report.rows.append([d(s.settlementPeriodEnd), s.displayNumber, name(s.driverId),
                                    s.grossLoadRevenueMoney.formatted, pay.formatted,
                                    (s.companyExpenses ?? .zero).formatted,
                                    (s.companyRetained ?? .zero).formatted])
            }
            report.totals = ["Total", "", "",
                             Money.sum(financial.map(\.grossLoadRevenueMoney)).formatted,
                             Money.sum(financial.map { ($0.totalDriverEarnings ?? .zero) + ($0.totalAdditions ?? .zero) }).formatted,
                             Money.sum(financial.map { $0.companyExpenses ?? .zero }).formatted,
                             Money.sum(financial.map { $0.companyRetained ?? .zero }).formatted]

        case .expenses:
            report.columns = ["Date", "Category", "Description", "Settlement", "Driver Pays", "Company Pays"]
            report.numericColumns = [4, 5]
            let ids = Set(financial.compactMap(\.id))
            let numbers = ledger.settlementNumbersById
            let rows = ledger.deductions.filter { $0.settlementId.map(ids.contains) ?? false }
                .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            for x in rows {
                report.rows.append([d(x.date), x.category.displayName, x.descriptionText,
                                    x.settlementId.flatMap { numbers[$0] } ?? "",
                                    x.driverAmount.formatted, x.companyAmount.formatted])
            }
            // Company expenses entered in the Expenses tab that were NOT carried
            // on a settlement — listed separately so nothing is counted twice.
            let linked = Set(ledger.deductions.compactMap(\.relatedExpenseId))
            let loose = expenses.filter {
                guard let id = $0.id else { return false }
                return !linked.contains(id) && range.contains($0.receiptDate ?? $0.createdAt, calendar: calendar)
            }
            for e in loose {
                report.rows.append([d(e.receiptDate ?? e.createdAt), e.category.capitalized,
                                    e.description ?? e.vendorName ?? "", "Not on a settlement",
                                    Money.zero.formatted, Money(double: e.amount).formatted])
            }
            report.totals = ["Total", "", "", "",
                             Money.sum(rows.map(\.driverAmount)).formatted,
                             (Money.sum(rows.map(\.companyAmount))
                              + Money.sum(loose.map { Money(double: $0.amount).rounded })).formatted]

        case .driverAdvances:
            report.subtitle = "Balances as of \(d(now))"
            report.columns = ["Driver", "Date", "Type", "Description", "Amount", "Recovered", "Outstanding", "Status"]
            report.numericColumns = [4, 5, 6]
            let rows = ledger.advances
                .filter { driverId == nil || $0.driverId == driverId }
                .map { DriverAdvanceService.reconciled(advance: $0, repayments: ledger.advanceRepayments) }
                .sorted { ($0.date, name($0.driverId)) < ($1.date, name($1.driverId)) }
            for a in rows {
                report.rows.append([name(a.driverId), d(a.date), a.type.displayName, a.descriptionText,
                                    a.amount.formatted, a.recoveredAmount.formatted,
                                    a.outstandingBalance.formatted,
                                    a.isFullyRecovered ? "Recovered" : "Open"])
            }
            report.totals = ["Total", "", "", "",
                             Money.sum(rows.map(\.amount)).formatted,
                             Money.sum(rows.map(\.recoveredAmount)).formatted,
                             Money.sum(rows.map(\.outstandingBalance)).formatted, ""]

        case .leaseOperator:
            report.subtitle += " · lease operator settlements"
            report.columns = ["Number", "Driver", "Period", "Gross", "Driver Earnings",
                              "Driver-Paid Costs", "Company-Paid Costs", "Net Pay", "Company Retained"]
            report.numericColumns = [3, 4, 5, 6, 7, 8]
            let lease = financial.filter { $0.effectiveSettlementType == .leaseOperator }
            for s in lease {
                report.rows.append([s.displayNumber, name(s.driverId), s.periodDescription,
                                    s.grossLoadRevenueMoney.formatted,
                                    (s.totalDriverEarnings ?? .zero).formatted,
                                    (s.totalDeductions ?? .zero).formatted,
                                    (s.companyExpenses ?? .zero).formatted,
                                    s.netPayMoney.formatted,
                                    (s.companyRetained ?? .zero).formatted])
            }
            report.totals = ["Total", "", "",
                             Money.sum(lease.map(\.grossLoadRevenueMoney)).formatted,
                             Money.sum(lease.map { $0.totalDriverEarnings ?? .zero }).formatted,
                             Money.sum(lease.map { $0.totalDeductions ?? .zero }).formatted,
                             Money.sum(lease.map { $0.companyExpenses ?? .zero }).formatted,
                             Money.sum(lease.map(\.netPayMoney)).formatted,
                             Money.sum(lease.map { $0.companyRetained ?? .zero }).formatted]
        }
        return report
    }

    // MARK: CSV

    /// RFC 4180 CSV. Currency cells are written as plain decimals ("1595.00")
    /// so a spreadsheet treats them as numbers. Cells that begin with a
    /// formula trigger are prefixed so a malicious description can't execute
    /// in Excel / Numbers.
    static func csv(_ report: SettlementReport) -> String {
        func plain(_ cell: String, numeric: Bool) -> String {
            guard numeric, let m = Money(input: cell) else { return cell }
            return NSDecimalNumber(decimal: m.rounded.amount).stringValue.withTwoDecimals
        }
        func escape(_ raw: String) -> String {
            var s = raw
            if let first = s.first, "=+-@\t\r".contains(first), Money(input: s) == nil {
                s = "'" + s
            }
            if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
                s = "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return s
        }
        var lines: [String] = [report.columns.map(escape).joined(separator: ",")]
        for row in report.rows + (report.totals.map { [$0] } ?? []) {
            let cells = row.enumerated().map { idx, cell in
                escape(plain(cell, numeric: report.numericColumns.contains(idx)))
            }
            lines.append(cells.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func milesString(_ miles: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSDecimalNumber(decimal: miles)) ?? "0"
    }
}

private extension String {
    /// "1595" → "1595.00", "12.5" → "12.50"
    var withTwoDecimals: String {
        guard let dot = firstIndex(of: ".") else { return self + ".00" }
        let decimals = distance(from: dot, to: endIndex) - 1
        if decimals >= 2 { return self }
        return self + String(repeating: "0", count: 2 - decimals)
    }
}
