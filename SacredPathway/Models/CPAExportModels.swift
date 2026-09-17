import Foundation

// =============================================================================
// MARK: - CPA Ready Tax Package — Data Models
// =============================================================================
//
// All data structures used by the CPA-export pipeline. Pure value types, no
// dependency on UIKit / SwiftUI so the same models can drive UI, PDF, CSV,
// and (future) cloud-export paths.
//
// Files in this feature:
//   • CPAExportModels.swift   — this file. Types + enums + pure aggregation.
//   • CPAExportService.swift  — fetches data, aggregates, builds CSV + ZIP.
//   • CPAPDFGenerator.swift   — renders the PDF.
//   • CPAReadyExportView.swift — SwiftUI screen.
//
// Design rule: everything in this file is `Codable` and side-effect-free so
// the entire export package can be archived and re-rendered later if needed.
// =============================================================================

// MARK: - Date Range

/// User-facing date-range presets shown on the export screen.
enum CPADateRangePreset: String, CaseIterable, Identifiable, Codable {
    case currentMonth
    case lastMonth
    case currentQuarter
    case yearToDate
    case lastYear
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .currentMonth:   return "Current Month"
        case .lastMonth:      return "Last Month"
        case .currentQuarter: return "Current Quarter"
        case .yearToDate:     return "Year to Date"
        case .lastYear:       return "Last Year"
        case .custom:         return "Custom Range"
        }
    }

    /// Resolve the preset to a concrete `[start, end]` interval anchored to
    /// `now`. `custom` falls back to a 1-year YTD range and expects the
    /// caller to override with user-picked dates.
    func dateRange(now: Date = Date(),
                   calendar: Calendar = Calendar.iso8601US) -> ClosedRange<Date> {
        switch self {
        case .currentMonth:
            return calendar.monthInterval(containing: now)
        case .lastMonth:
            let prev = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            return calendar.monthInterval(containing: prev)
        case .currentQuarter:
            return calendar.quarterInterval(containing: now)
        case .yearToDate:
            let startOfYear = calendar.date(
                from: calendar.dateComponents([.year], from: now)
            ) ?? now
            return startOfYear...now
        case .lastYear:
            let year = calendar.component(.year, from: now) - 1
            let start = calendar.date(from: DateComponents(year: year,
                                                           month: 1, day: 1)) ?? now
            let end = calendar.date(from: DateComponents(year: year,
                                                         month: 12, day: 31)) ?? now
            return start...end
        case .custom:
            // Sensible fallback for callers that don't override.
            let startOfYear = calendar.date(
                from: calendar.dateComponents([.year], from: now)
            ) ?? now
            return startOfYear...now
        }
    }
}

// MARK: - Export Toggles

/// Per-section inclusion flags. Defaults are all-on. Persisted with the
/// generated package so re-renders match what the user originally exported.
struct CPAExportToggles: Codable, Equatable {
    var settlements:       Bool = true
    var expenses:          Bool = true
    var fuel:              Bool = true
    var maintenance:       Bool = true
    var tolls:             Bool = true
    var mileageSummary:    Bool = true
    var brokerPayments:    Bool = true
    var receiptsMetadata:  Bool = true

    /// Convenience — true when at least one toggle is on. Used to disable
    /// the Generate button until the user has something to export.
    var hasAnyEnabled: Bool {
        settlements || expenses || fuel || maintenance || tolls ||
        mileageSummary || brokerPayments || receiptsMetadata
    }

    static let allOn = CPAExportToggles()
}

// MARK: - Expense Categories

/// Canonical expense-category list used by the export. Maps the free-text
/// `Expense.category` column into a normalized bucket for tax purposes.
///
/// Adding a new category here adds it to:
///   • PDF "Category Totals" table
///   • CSV grouping
///   • Smart Tax Features write-off summary
///
/// FUTURE — line items will be tagged with their IRS Schedule C line number
/// via `scheduleCLineNumber` so a single switch over `CPAExpenseCategory`
/// can render an audit-ready package.
enum CPAExpenseCategory: String, CaseIterable, Codable {
    case fuel
    case def
    case maintenance
    case repair
    case tolls
    case parking
    case meals
    case insurance
    case permits
    case lumper
    case subscriptions
    case office
    case miscellaneous

    /// Match the free-text Expense.category against the canonical bucket.
    /// Defaults to `.miscellaneous` so nothing is ever dropped from the totals.
    static func bucket(forRawCategory raw: String) -> CPAExpenseCategory {
        let l = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch l {
        case "fuel", "diesel", "gas":                            return .fuel
        case "def", "diesel exhaust fluid":                      return .def
        case "maintenance", "service", "scheduled maintenance":  return .maintenance
        case "repair", "repairs":                                return .repair
        case "toll", "tolls":                                    return .tolls
        case "parking":                                          return .parking
        case "meal", "meals", "food", "per diem", "perdiem":     return .meals
        case "insurance":                                        return .insurance
        case "permit", "permits", "permits & licenses":          return .permits
        case "lumper":                                           return .lumper
        case "subscription", "subscriptions", "software":        return .subscriptions
        case "office", "supplies", "office supplies":            return .office
        default:                                                 return .miscellaneous
        }
    }

    var displayName: String {
        switch self {
        case .fuel:          return "Fuel"
        case .def:           return "DEF"
        case .maintenance:   return "Maintenance"
        case .repair:        return "Repairs"
        case .tolls:         return "Tolls"
        case .parking:       return "Parking"
        case .meals:         return "Meals"
        case .insurance:     return "Insurance"
        case .permits:       return "Permits & Licenses"
        case .lumper:        return "Lumper Fees"
        case .subscriptions: return "Subscriptions"
        case .office:        return "Office Supplies"
        case .miscellaneous: return "Miscellaneous"
        }
    }

    /// IRS Schedule C line number (best-effort mapping for owner-operators).
    /// Surfaced in the PDF so the user's CPA has a starting point, NOT tax
    /// advice. Always reviewed by the user's tax professional.
    var scheduleCLineHint: String {
        switch self {
        case .fuel, .def:    return "L9  – Car & truck expenses"
        case .maintenance,
             .repair:        return "L21 – Repairs & maintenance"
        case .tolls,
             .parking:       return "L20a – Travel"
        case .meals:         return "L24b – Meals"
        case .insurance:     return "L15 – Insurance (other than health)"
        case .permits:       return "L23 – Taxes & licenses"
        case .lumper:        return "L11 – Contract labor"
        case .subscriptions,
             .office:        return "L22 – Supplies / L18 – Office expense"
        case .miscellaneous: return "L48 – Other expenses"
        }
    }
}

// MARK: - Aggregations

/// A single category's totals over the reporting period.
struct CPACategoryTotal: Codable, Identifiable {
    let category: CPAExpenseCategory
    let total: Double
    let count: Int
    var id: String { category.rawValue }
}

/// A single month's roll-up. Used for the Monthly Breakdown table.
struct CPAMonthlyTotal: Codable, Identifiable {
    let year: Int
    let month: Int       // 1...12
    let revenue: Double
    let expenses: Double
    var net: Double { revenue - expenses }
    var id: String { "\(year)-\(month)" }

    /// "May 2026" etc.
    var displayLabel: String {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = 1
        let date = Calendar.iso8601US.date(from: c) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}

// MARK: - Mileage / Fuel summaries

struct CPAMileageSummary: Codable {
    let loadedMiles: Double
    let deadheadMiles: Double
    var totalMiles: Double { loadedMiles + deadheadMiles }

    /// Standard 2025 IRS business-mileage rate (cents/mile). Used for the
    /// "Estimated Deductible Miles" hint on the PDF. The user's CPA should
    /// confirm the current-year rate.
    static let irsStandardRatePerMile: Double = 0.70

    var estimatedStandardDeduction: Double {
        totalMiles * Self.irsStandardRatePerMile
    }
}

struct CPAFuelSummary: Codable {
    let gallons: Double
    let totalCost: Double
    let defGallons: Double
    let defCost: Double

    var avgPricePerGallon: Double {
        gallons > 0 ? totalCost / gallons : 0
    }
}

// MARK: - Receipt metadata

/// Lightweight pointer to a receipt — name + date + amount + storage path.
/// Kept minimal so the export remains small even for 1,000+ rows. The
/// actual binary blobs (if any) live in Supabase storage; this struct only
/// records the metadata so the CPA can cross-reference.
struct CPAReceiptRef: Codable, Identifiable {
    let id: UUID
    let category: String
    let vendorName: String?
    let amount: Double
    let date: Date?
    let storagePath: String?
}

// MARK: - Top-level package

/// The full, render-ready CPA package. One struct that the PDF generator,
/// CSV writer, and ZIP builder all consume.
struct CPAExportPackage: Codable {
    let generatedAt: Date
    let dateRange: ClosedRange<Date>
    let preset: CPADateRangePreset
    let toggles: CPAExportToggles

    // Business info
    let companyName: String
    let mcNumber: String?
    let dotNumber: String?
    let driverName: String?

    // Aggregates
    let totalRevenue: Double
    let totalExpenses: Double
    let netRevenue: Double
    let categoryTotals: [CPACategoryTotal]
    let monthlyBreakdown: [CPAMonthlyTotal]
    let mileage: CPAMileageSummary
    let fuel: CPAFuelSummary
    let topCategories: [CPACategoryTotal]    // top 5 by total

    // Optional sections (driven by toggles)
    let settlementsCount: Int
    let brokerPayments: [CPABrokerPayment]
    let receipts: [CPAReceiptRef]
    let expenseRows: [CPAExpenseRow]           // flat, sorted by date desc

    /// "ytd_2026_05-15_arcadia.pdf" — sanitized for FS friendliness.
    var suggestedFilenameStem: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let datePart = f.string(from: generatedAt)
        let companyPart = companyName
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let presetPart = preset.rawValue
        return "cpa_\(presetPart)_\(datePart)_\(companyPart.isEmpty ? "carrier" : companyPart)"
    }
}

/// Broker payment row — derived from `Load.totalRevenue` grouped by broker.
struct CPABrokerPayment: Codable, Identifiable {
    let brokerName: String
    let loadCount: Int
    let totalPaid: Double
    var id: String { brokerName }
}

/// Flat expense row written into the CSV.
struct CPAExpenseRow: Codable, Identifiable {
    let id: UUID
    let date: Date?
    let category: CPAExpenseCategory
    let categoryRaw: String
    let vendor: String?
    let description: String?
    let amount: Double
    let gallons: Double?
    let pricePerGallon: Double?
}

// MARK: - Calendar helpers

extension Calendar {
    /// ISO-8601 calendar pinned to US POSIX locale for stable formatting.
    static let iso8601US: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// First-of-month → last-second-of-month range containing `date`.
    func monthInterval(containing date: Date) -> ClosedRange<Date> {
        let comps = dateComponents([.year, .month], from: date)
        let start = self.date(from: comps) ?? date
        // Last moment of the month.
        var endComps = DateComponents()
        endComps.month = 1
        endComps.second = -1
        let end = self.date(byAdding: endComps, to: start) ?? date
        return start...end
    }

    /// Quarter (3 calendar months) range containing `date`.
    func quarterInterval(containing date: Date) -> ClosedRange<Date> {
        let month = component(.month, from: date)
        let quarterStartMonth = ((month - 1) / 3) * 3 + 1  // 1, 4, 7, 10
        let year = component(.year, from: date)
        var sc = DateComponents()
        sc.year = year; sc.month = quarterStartMonth; sc.day = 1
        let start = self.date(from: sc) ?? date
        var addEnd = DateComponents()
        addEnd.month = 3
        addEnd.second = -1
        let end = self.date(byAdding: addEnd, to: start) ?? date
        return start...end
    }
}

// NOTE: ClosedRange<Bound> already conforms conditionally to Codable when
// Bound: Codable (Swift 5.9+), so we do NOT add a retroactive conformance
// here. Adding one would conflict with Swift's built-in conditional
// conformance and emit a compile-time warning.
