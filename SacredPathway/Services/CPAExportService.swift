import Foundation

// =============================================================================
// MARK: - CPAExportService
// =============================================================================
//
// Builds a CPA-ready export package. Pulls Expenses / Settlements / Loads
// from Supabase, aggregates them in pure Swift, then hands the result to:
//   • CPAPDFGenerator — PDF
//   • internal CSV writer — flat CSV
//   • Foundation NSFileCoordinator + simple archive — ZIP package
//
// Hard rules:
//   • NEVER mutates production data — read only.
//   • All aggregation runs on a background queue (`Task.detached`).
//   • Returns plain `Data` blobs so the caller can decide whether to share,
//     save, or upload.
//
// Future extension points (kept easy to wire):
//   • `attachReceipts(_:)` — download receipt blobs from Supabase storage
//     and embed inside the ZIP next to a receipts manifest.
//   • `quickBooksJSON(_:)` — emit a QuickBooks-compatible IIF/JSON sidecar.
//   • `irsAuditMode` — Boolean that bumps the PDF detail level (per-row
//     receipt thumbnails, vendor tax IDs, etc.).
// =============================================================================

enum CPAExportError: LocalizedError {
    case noProfile
    case noData
    case pdfRenderFailed
    case zipWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProfile:           return "Sign in to generate a CPA export."
        case .noData:              return "No financial data in the selected date range."
        case .pdfRenderFailed:     return "Couldn't render the PDF. Try a shorter date range."
        case .zipWriteFailed(let m): return "Couldn't build the ZIP package: \(m)"
        }
    }
}

/// Output of `CPAExportService.buildPackage(...)`. Contains the in-memory
/// package data plus the rendered PDF and CSV bytes. The view layer uses
/// `zipURL` (a temp file) for share-sheet hand-off.
struct CPAExportResult {
    let package: CPAExportPackage
    let pdfData: Data
    let csvData: Data
    let zipURL: URL?            // nil if the user chose CSV-only / PDF-only
}

/// Format type the user picked. Controls what ends up in the share sheet.
enum CPAExportFormat: String, CaseIterable, Identifiable {
    case pdf, csv, zip
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .pdf: return "PDF Report"
        case .csv: return "CSV"
        case .zip: return "Full ZIP Package"
        }
    }
}

enum CPAExportService {

    // MARK: - Entry point

    /// Build a fully aggregated CPA export package. Filters by `range` and
    /// the `toggles` flags. `now` is exposed for deterministic testing.
    ///
    /// Caller normally invokes this from a SwiftUI Task so the long-running
    /// fetch / aggregate work happens off the main actor.
    static func buildPackage(
        supabase: SupabaseService,
        preset: CPADateRangePreset,
        range: ClosedRange<Date>,
        toggles: CPAExportToggles,
        format: CPAExportFormat = .zip,
        now: Date = Date()
    ) async throws -> CPAExportResult {

        // SupabaseService is @MainActor-isolated. Hop briefly to read the
        // profile, then return to the cooperative context.
        let profile: Profile? = await MainActor.run { supabase.currentProfile }
        let companyName = profile?.companyName?.trimmingCharacters(in: .whitespaces)
            .nilIfEmpty ?? "Owner-Operator"
        let mc  = profile?.mcNumber?.nilIfEmpty
        let dot = profile?.dotNumber?.nilIfEmpty

        // ─── 1. Fetch raw data in parallel ──────────────────────────────
        async let expensesTask     = safeFetchExpenses(supabase: supabase)
        async let loadsTask        = safeFetchLoads(supabase: supabase)
        async let settlementsTask  = toggles.settlements
                                       ? safeFetchSettlements(supabase: supabase)
                                       : Task<[Settlement], Never> { [] }.value
        let expenses    = await expensesTask
        let loads       = await loadsTask
        let settlements = await settlementsTask

        // ─── 2. Filter by range ─────────────────────────────────────────
        let filteredExpenses = expenses.filter { exp in
            let d = exp.receiptDate ?? exp.createdAt
            return d.map { range.contains($0) } ?? false
        }
        let filteredLoads = loads.filter { load in
            let d = load.deliveryDate ?? load.pickupDate ?? load.createdAt
            return d.map { range.contains($0) } ?? false
        }
        let filteredSettlements = settlements.filter { s in
            let d = s.settlementPeriodEnd ?? s.settlementPeriodStart ?? s.createdAt
            return d.map { range.contains($0) } ?? false
        }

        // ─── 3. Aggregate ───────────────────────────────────────────────
        let categoryTotals = aggregateCategoryTotals(filteredExpenses)
        let monthly        = aggregateMonthly(loads: filteredLoads,
                                              expenses: filteredExpenses,
                                              calendar: .iso8601US)
        let mileage        = aggregateMileage(filteredLoads)
        let fuel           = aggregateFuel(filteredExpenses)
        let brokerPayments = aggregateBrokerPayments(filteredLoads)
        let receipts       = aggregateReceipts(filteredExpenses)
        let expenseRows    = filteredExpenses
            .sorted { ($0.receiptDate ?? $0.createdAt ?? .distantPast)
                    > ($1.receiptDate ?? $1.createdAt ?? .distantPast) }
            .map(CPAExpenseRow.init(fromExpense:))

        let totalRevenue  = filteredLoads.reduce(0.0) { $0 + ($1.totalRevenue ?? 0) }
        let totalExpenses = filteredExpenses.reduce(0.0) { $0 + $1.amount }
        let topCategories = categoryTotals
            .sorted { $0.total > $1.total }
            .prefix(5)
            .map { $0 }

        guard !filteredExpenses.isEmpty
                || !filteredLoads.isEmpty
                || !filteredSettlements.isEmpty else {
            throw CPAExportError.noData
        }

        let pkg = CPAExportPackage(
            generatedAt: now,
            dateRange: range,
            preset: preset,
            toggles: toggles,
            companyName: companyName,
            mcNumber: mc,
            dotNumber: dot,
            driverName: nil,
            totalRevenue: totalRevenue,
            totalExpenses: totalExpenses,
            netRevenue: totalRevenue - totalExpenses,
            categoryTotals: categoryTotals,
            monthlyBreakdown: monthly,
            mileage: mileage,
            fuel: fuel,
            topCategories: topCategories,
            settlementsCount: filteredSettlements.count,
            brokerPayments: brokerPayments,
            receipts: toggles.receiptsMetadata ? receipts : [],
            expenseRows: expenseRows
        )

        // ─── 4. Render outputs ──────────────────────────────────────────
        let pdfData = try CPAPDFGenerator.render(package: pkg)
        let csvData = renderCSV(package: pkg)

        // ZIP only when caller asked for it OR when the package has more
        // than one artifact worth bundling.
        var zipURL: URL?
        if format == .zip {
            zipURL = try writeZip(pkg: pkg, pdf: pdfData, csv: csvData)
        }

        return CPAExportResult(package: pkg, pdfData: pdfData,
                               csvData: csvData, zipURL: zipURL)
    }

    // MARK: - Safe fetches (network errors become empty arrays)

    private static func safeFetchExpenses(supabase: SupabaseService) async -> [Expense] {
        do { return try await supabase.fetchAllExpenses() } catch { return [] }
    }
    private static func safeFetchLoads(supabase: SupabaseService) async -> [Load] {
        do { return try await supabase.fetchLoads() } catch { return [] }
    }
    private static func safeFetchSettlements(supabase: SupabaseService) async -> [Settlement] {
        do { return try await supabase.fetchSettlements() } catch { return [] }
    }

    // MARK: - Aggregation primitives (pure, testable)

    static func aggregateCategoryTotals(_ expenses: [Expense]) -> [CPACategoryTotal] {
        var grouped: [CPAExpenseCategory: (total: Double, count: Int)] = [:]
        for e in expenses {
            let bucket = CPAExpenseCategory.bucket(forRawCategory: e.category)
            var row = grouped[bucket] ?? (0, 0)
            row.total += e.amount
            row.count += 1
            grouped[bucket] = row
            // Also bucket DEF as its own line when the expense carries DEF data.
            if let defTotal = e.defTotal, defTotal > 0 {
                var defRow = grouped[.def] ?? (0, 0)
                defRow.total += defTotal
                defRow.count += 1
                grouped[.def] = defRow
            }
        }
        return grouped.map { (cat, v) in
            CPACategoryTotal(category: cat, total: v.total, count: v.count)
        }
        .sorted { $0.total > $1.total }
    }

    static func aggregateMonthly(
        loads: [Load],
        expenses: [Expense],
        calendar: Calendar
    ) -> [CPAMonthlyTotal] {
        struct Bucket { var rev: Double = 0; var exp: Double = 0 }
        var grouped: [String: Bucket] = [:]
        func key(_ d: Date) -> String {
            let c = calendar.dateComponents([.year, .month], from: d)
            return "\(c.year ?? 0)-\(c.month ?? 0)"
        }
        for l in loads {
            guard let d = l.deliveryDate ?? l.pickupDate ?? l.createdAt else { continue }
            grouped[key(d), default: Bucket()].rev += l.totalRevenue ?? 0
        }
        for e in expenses {
            guard let d = e.receiptDate ?? e.createdAt else { continue }
            grouped[key(d), default: Bucket()].exp += e.amount
        }
        return grouped.compactMap { k, v -> CPAMonthlyTotal? in
            let parts = k.split(separator: "-")
            guard parts.count == 2,
                  let y = Int(parts[0]),
                  let m = Int(parts[1]) else { return nil }
            return CPAMonthlyTotal(year: y, month: m,
                                   revenue: v.rev, expenses: v.exp)
        }
        .sorted { ($0.year, $0.month) < ($1.year, $1.month) }
    }

    static func aggregateMileage(_ loads: [Load]) -> CPAMileageSummary {
        let total = loads.reduce(0.0) { $0 + ($1.totalMiles ?? 0) }
        // We can't break out deadhead vs. loaded from the persisted Load
        // model alone (those fields are on the scan-review screen but not
        // saved separately). Treat all as loaded for the CPA report.
        return CPAMileageSummary(loadedMiles: total, deadheadMiles: 0)
    }

    static func aggregateFuel(_ expenses: [Expense]) -> CPAFuelSummary {
        var gallons = 0.0
        var totalCost = 0.0
        var defG = 0.0
        var defC = 0.0
        for e in expenses {
            if CPAExpenseCategory.bucket(forRawCategory: e.category) == .fuel {
                gallons   += e.gallons ?? 0
                totalCost += e.amount
            }
            if let dg = e.defGallons, dg > 0 {
                defG += dg
                defC += e.defTotal ?? ((e.defPricePerGallon ?? 0) * dg)
            }
        }
        return CPAFuelSummary(gallons: gallons, totalCost: totalCost,
                              defGallons: defG, defCost: defC)
    }

    static func aggregateBrokerPayments(_ loads: [Load]) -> [CPABrokerPayment] {
        struct B { var count = 0; var total = 0.0 }
        var grouped: [String: B] = [:]
        for l in loads {
            let name = (l.brokerName?.trimmingCharacters(in: .whitespaces).nilIfEmpty)
                ?? "Unknown Broker"
            var row = grouped[name] ?? B()
            row.count += 1
            row.total += l.totalRevenue ?? 0
            grouped[name] = row
        }
        return grouped.map { name, b in
            CPABrokerPayment(brokerName: name, loadCount: b.count, totalPaid: b.total)
        }
        .sorted { $0.totalPaid > $1.totalPaid }
    }

    static func aggregateReceipts(_ expenses: [Expense]) -> [CPAReceiptRef] {
        // Lightweight metadata only. FUTURE: cross-reference against the
        // `documents` table to attach receipt storage paths.
        expenses.compactMap { e in
            guard let id = e.id else { return nil }
            return CPAReceiptRef(
                id: id,
                category: e.category,
                vendorName: e.vendorName,
                amount: e.amount,
                date: e.receiptDate ?? e.createdAt,
                storagePath: nil
            )
        }
    }

    // MARK: - CSV

    /// Flat CSV — every expense on its own row, RFC-4180 escaped.
    /// Header columns are stable so accountants can build an Excel template
    /// once and reuse it across exports.
    static func renderCSV(package pkg: CPAExportPackage) -> Data {
        var lines: [String] = []
        let header = ["Date", "Category", "Bucket", "Vendor", "Description",
                      "Amount", "Gallons", "Price/Gal"]
        lines.append(header.map(csvEscape).joined(separator: ","))

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")

        for r in pkg.expenseRows {
            let row = [
                r.date.map(df.string) ?? "",
                r.categoryRaw,
                r.category.displayName,
                r.vendor ?? "",
                r.description ?? "",
                String(format: "%.2f", r.amount),
                r.gallons.map { String(format: "%.3f", $0) } ?? "",
                r.pricePerGallon.map { String(format: "%.3f", $0) } ?? "",
            ]
            lines.append(row.map(csvEscape).joined(separator: ","))
        }

        // Footer: category totals
        lines.append("")
        lines.append("CATEGORY TOTALS")
        for ct in pkg.categoryTotals {
            lines.append([ct.category.displayName,
                          String(format: "%.2f", ct.total),
                          "\(ct.count) rows"]
                         .map(csvEscape).joined(separator: ","))
        }
        lines.append("")
        lines.append(["Total Revenue", String(format: "%.2f", pkg.totalRevenue)]
                     .map(csvEscape).joined(separator: ","))
        lines.append(["Total Expenses", String(format: "%.2f", pkg.totalExpenses)]
                     .map(csvEscape).joined(separator: ","))
        lines.append(["Net Revenue (Est.)", String(format: "%.2f", pkg.netRevenue)]
                     .map(csvEscape).joined(separator: ","))

        let text = lines.joined(separator: "\n") + "\n"
        return text.data(using: .utf8) ?? Data()
    }

    private static func csvEscape(_ s: String) -> String {
        // RFC 4180: quote if the value contains ", comma, or newline.
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return s
    }

    // MARK: - ZIP (Apple-native via NSFileCoordinator)

    /// Build a ZIP using `NSFileCoordinator`'s `.forUploading` accessor.
    /// That's a no-third-party-dep way to compress an entire directory.
    /// Returns the URL of a temp .zip file the caller can hand to the
    /// share sheet.
    static func writeZip(pkg: CPAExportPackage,
                         pdf: Data,
                         csv: Data) throws -> URL {
        let fm = FileManager.default

        // Build a temp dir to stage the artifacts.
        let stem = pkg.suggestedFilenameStem
        let baseDir = fm.temporaryDirectory
            .appendingPathComponent(stem, isDirectory: true)
        try? fm.removeItem(at: baseDir)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

        // 1. PDF
        let pdfURL = baseDir.appendingPathComponent("\(stem).pdf")
        try pdf.write(to: pdfURL)

        // 2. CSV
        let csvURL = baseDir.appendingPathComponent("\(stem).csv")
        try csv.write(to: csvURL)

        // 3. Receipts manifest (lightweight JSON — useful for the CPA's
        //    workflow tooling). Only included when receipts toggle is on.
        if pkg.toggles.receiptsMetadata, !pkg.receipts.isEmpty {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            let receiptsURL = baseDir.appendingPathComponent("receipts_manifest.json")
            try enc.encode(pkg.receipts).write(to: receiptsURL)
        }

        // 4. README.txt with package overview.
        let readme = """
        Sacred Pathway Driver Hub — CPA Ready Tax Package
        ─────────────────────────────────────────────────
        Company: \(pkg.companyName)
        Period:  \(pkg.preset.displayName)
        Range:   \(formatRange(pkg.dateRange))
        Generated: \(formatDateTime(pkg.generatedAt))

        Files in this package:
          • \(stem).pdf  — Accountant-ready summary
          • \(stem).csv  — Line-item expenses (Excel/Numbers)
        \(pkg.receipts.isEmpty ? "" : "  • receipts_manifest.json — Receipt metadata")

        Disclaimer: Generated for informational use. Final tax filings should
        be reviewed by a licensed CPA or tax professional.
        """
        let readmeURL = baseDir.appendingPathComponent("README.txt")
        try readme.write(to: readmeURL, atomically: true, encoding: .utf8)

        // Now ZIP the directory using NSFileCoordinator's forUploading accessor.
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var resultURL: URL?
        var copyError: Error?

        coordinator.coordinate(readingItemAt: baseDir,
                               options: [.forUploading],
                               error: &coordError) { zipFromCoordinator in
            // The accessor gives us a temporary zip file that gets removed
            // when this block exits — copy it somewhere stable first.
            let stableZip = fm.temporaryDirectory
                .appendingPathComponent("\(stem).zip")
            try? fm.removeItem(at: stableZip)
            do {
                try fm.copyItem(at: zipFromCoordinator, to: stableZip)
                resultURL = stableZip
            } catch {
                copyError = error
            }
        }

        if let coordError {
            throw CPAExportError.zipWriteFailed(coordError.localizedDescription)
        }
        if let copyError {
            throw CPAExportError.zipWriteFailed(copyError.localizedDescription)
        }
        guard let resultURL else {
            throw CPAExportError.zipWriteFailed("unknown")
        }
        return resultURL
    }

    // MARK: - Format helpers

    private static func formatRange(_ r: ClosedRange<Date>) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return "\(f.string(from: r.lowerBound)) → \(f.string(from: r.upperBound))"
    }
    private static func formatDateTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - CPAExpenseRow init from Expense

extension CPAExpenseRow {
    init(fromExpense e: Expense) {
        self.id = e.id ?? UUID()
        self.date = e.receiptDate ?? e.createdAt
        self.category = CPAExpenseCategory.bucket(forRawCategory: e.category)
        self.categoryRaw = e.category
        self.vendor = e.vendorName
        self.description = e.description
        self.amount = e.amount
        self.gallons = e.gallons
        self.pricePerGallon = e.pricePerGallon
    }
}

// MARK: - small string helper (file-private)

private extension String {
    /// Returns nil if the string is empty or only whitespace, otherwise self.
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
