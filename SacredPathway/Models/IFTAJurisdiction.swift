import Foundation

// MARK: - IFTA Quarter

enum IFTAQuarter: Equatable, Hashable {
    case q1(year: Int)
    case q2(year: Int)
    case q3(year: Int)
    case q4(year: Int)

    var label: String {
        switch self {
        case .q1(let year): return "Q1 \(year)"
        case .q2(let year): return "Q2 \(year)"
        case .q3(let year): return "Q3 \(year)"
        case .q4(let year): return "Q4 \(year)"
        }
    }

    var year: Int {
        switch self {
        case .q1(let y), .q2(let y), .q3(let y), .q4(let y): return y
        }
    }

    var quarterNumber: Int {
        switch self {
        case .q1: return 1
        case .q2: return 2
        case .q3: return 3
        case .q4: return 4
        }
    }

    /// Date range for this quarter (inclusive)
    var dateRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        var startComponents = DateComponents(year: year, month: 1, day: 1)
        var endComponents = DateComponents(year: year, month: 12, day: 31)

        switch self {
        case .q1:
            startComponents.month = 1
            endComponents.month = 3
            endComponents.day = 31
        case .q2:
            startComponents.month = 4
            endComponents.month = 6
            endComponents.day = 30
        case .q3:
            startComponents.month = 7
            endComponents.month = 9
            endComponents.day = 30
        case .q4:
            startComponents.month = 10
            endComponents.month = 12
            endComponents.day = 31
        }

        let start = calendar.date(from: startComponents) ?? Date()
        let end = calendar.date(from: endComponents) ?? Date()
        return (start, end)
    }

    /// Check if a date falls within this quarter
    func contains(_ date: Date) -> Bool {
        let range = dateRange
        return date >= range.start && date <= range.end
    }

    /// Initialize from a date
    static func from(date: Date) -> IFTAQuarter {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.month, .year], from: date)
        let month = components.month ?? 1
        let year = components.year ?? 2026

        switch month {
        case 1...3: return .q1(year: year)
        case 4...6: return .q2(year: year)
        case 7...9: return .q3(year: year)
        default: return .q4(year: year)
        }
    }
}

// MARK: - IFTA Jurisdiction

struct IFTAJurisdiction: Identifiable, Hashable {
    let id: String  // 2-letter code
    let code: String
    let name: String
    let taxRatePerGallon: Double

    var displayName: String {
        "\(code) - \(name)"
    }
}

// MARK: - IFTA Jurisdictions List

let iftaJurisdictions: [IFTAJurisdiction] = [
    // US States
    IFTAJurisdiction(id: "AL", code: "AL", name: "Alabama", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "AZ", code: "AZ", name: "Arizona", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "AR", code: "AR", name: "Arkansas", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "CA", code: "CA", name: "California", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "CO", code: "CO", name: "Colorado", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "CT", code: "CT", name: "Connecticut", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "DE", code: "DE", name: "Delaware", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "FL", code: "FL", name: "Florida", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "GA", code: "GA", name: "Georgia", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "ID", code: "ID", name: "Idaho", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "IL", code: "IL", name: "Illinois", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "IN", code: "IN", name: "Indiana", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "IA", code: "IA", name: "Iowa", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "KS", code: "KS", name: "Kansas", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "KY", code: "KY", name: "Kentucky", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "LA", code: "LA", name: "Louisiana", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "ME", code: "ME", name: "Maine", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "MD", code: "MD", name: "Maryland", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "MA", code: "MA", name: "Massachusetts", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "MI", code: "MI", name: "Michigan", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "MN", code: "MN", name: "Minnesota", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "MS", code: "MS", name: "Mississippi", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "MO", code: "MO", name: "Missouri", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "MT", code: "MT", name: "Montana", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "NE", code: "NE", name: "Nebraska", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "NV", code: "NV", name: "Nevada", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "NH", code: "NH", name: "New Hampshire", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "NJ", code: "NJ", name: "New Jersey", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "NM", code: "NM", name: "New Mexico", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "NY", code: "NY", name: "New York", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "NC", code: "NC", name: "North Carolina", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "ND", code: "ND", name: "North Dakota", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "OH", code: "OH", name: "Ohio", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "OK", code: "OK", name: "Oklahoma", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "OR", code: "OR", name: "Oregon", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "PA", code: "PA", name: "Pennsylvania", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "RI", code: "RI", name: "Rhode Island", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "SC", code: "SC", name: "South Carolina", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "SD", code: "SD", name: "South Dakota", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "TN", code: "TN", name: "Tennessee", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "TX", code: "TX", name: "Texas", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "UT", code: "UT", name: "Utah", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "VT", code: "VT", name: "Vermont", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "VA", code: "VA", name: "Virginia", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "WA", code: "WA", name: "Washington", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "WV", code: "WV", name: "West Virginia", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "WI", code: "WI", name: "Wisconsin", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "WY", code: "WY", name: "Wyoming", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "DC", code: "DC", name: "District of Columbia", taxRatePerGallon: 0.0),

    // Canadian Provinces
    IFTAJurisdiction(id: "AB", code: "AB", name: "Alberta", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "BC", code: "BC", name: "British Columbia", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "MB", code: "MB", name: "Manitoba", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "NB", code: "NB", name: "New Brunswick", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "NL", code: "NL", name: "Newfoundland & Labrador", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "NS", code: "NS", name: "Nova Scotia", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "ON", code: "ON", name: "Ontario", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "PE", code: "PE", name: "Prince Edward Island", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "QC", code: "QC", name: "Quebec", taxRatePerGallon: 0.0),
    IFTAJurisdiction(id: "SK", code: "SK", name: "Saskatchewan", taxRatePerGallon: 0.0),
]

// Helper to find a jurisdiction by code
func jurisdictionForCode(_ code: String) -> IFTAJurisdiction? {
    iftaJurisdictions.first { $0.code == code.uppercased() }
}

// Helper to get available quarters from entries
func availableQuarters(from entries: [IFTAEntry]) -> [IFTAQuarter] {
    var quarters = Set<IFTAQuarter>()
    for entry in entries {
        quarters.insert(IFTAQuarter.from(date: entry.date))
    }

    var sorted = Array(quarters).sorted { q1, q2 in
        if q1.year != q2.year {
            return q1.year > q2.year
        }
        return q1.quarterNumber > q2.quarterNumber
    }

    // Add current quarter if not present
    let currentQuarter = IFTAQuarter.from(date: Date())
    if !sorted.contains(currentQuarter) {
        sorted.insert(currentQuarter, at: 0)
    }

    return sorted
}
