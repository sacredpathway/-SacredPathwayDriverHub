import Foundation

// MARK: - IFTA Summary

struct IFTASummary {
    let quarter: IFTAQuarter
    let entries: [IFTAEntry]

    var totalMiles: Double {
        entries.reduce(0) { $0 + $1.milesDriven }
    }

    var totalGallons: Double {
        entries.reduce(0) { $0 + $1.fuelGallons }
    }

    var averageMPG: Double {
        guard totalGallons > 0 else { return 0 }
        return totalMiles / totalGallons
    }

    var statesummaries: [StateIFTASummary] {
        let groupedByState = Dictionary(grouping: entries, by: { $0.stateCode })

        return groupedByState.map { code, stateEntries in
            let miles = stateEntries.reduce(0) { $0 + $1.milesDriven }
            let gallons = stateEntries.reduce(0) { $0 + $1.fuelGallons }
            let mpg = gallons > 0 ? miles / gallons : 0
            let taxableGallons = miles / max(averageMPG, 5.0)  // Fallback to 5 MPG minimum
            let jurisdiction = jurisdictionForCode(code) ?? IFTAJurisdiction(
                id: code,
                code: code,
                name: code,
                taxRatePerGallon: 0.0
            )
            let taxOwed = taxableGallons * jurisdiction.taxRatePerGallon

            return StateIFTASummary(
                stateCode: code,
                stateName: jurisdiction.name,
                miles: miles,
                gallons: gallons,
                mpg: mpg,
                taxableGallons: taxableGallons,
                taxRate: jurisdiction.taxRatePerGallon,
                taxOwed: taxOwed
            )
        }
        .sorted { $0.stateCode < $1.stateCode }
    }

    var totalTaxOwed: Double {
        statesummaries.reduce(0) { $0 + $1.taxOwed }
    }
}

struct StateIFTASummary {
    let stateCode: String
    let stateName: String
    let miles: Double
    let gallons: Double
    let mpg: Double
    let taxableGallons: Double
    let taxRate: Double
    let taxOwed: Double
}

// MARK: - IFTA Calculator

struct IFTACalculator {
    static func summarize(entries: [IFTAEntry], forQuarter quarter: IFTAQuarter) -> IFTASummary {
        let quarterEntries = entries.filter { quarter.contains($0.date) }
        return IFTASummary(quarter: quarter, entries: quarterEntries)
    }

    static func summarize(entries: [IFTAEntry]) -> IFTASummary? {
        guard !entries.isEmpty else { return nil }

        // Group by quarter and use the most recent
        let byQuarter = Dictionary(grouping: entries, by: { IFTAQuarter.from(date: $0.date) })
        let mostRecentQuarter = byQuarter.keys.sorted { q1, q2 in
            if q1.year != q2.year {
                return q1.year > q2.year
            }
            return q1.quarterNumber > q2.quarterNumber
        }.first

        guard let quarter = mostRecentQuarter else { return nil }
        return summarize(entries: entries, forQuarter: quarter)
    }
}
