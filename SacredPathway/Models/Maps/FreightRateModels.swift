import Foundation
import CoreLocation

// =============================================================================
// MARK: - Freight Rate Models
// -----------------------------------------------------------------------------
// Pure value types describing live freight-market data for the Rate Map. These
// are deliberately provider-agnostic: the same structs are produced whether the
// data comes from the bundled mock provider or a future DAT / Truckstop / SONAR
// integration. The UI binds only to these models, so swapping providers never
// touches a single view.
// =============================================================================

/// Equipment type used both as a market dimension and as the Rate Map filter.
enum EquipmentType: String, CaseIterable, Identifiable, Codable, Hashable {
    case dryVan  = "dry_van"
    case reefer  = "reefer"
    case flatbed = "flatbed"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dryVan:  return "Dry Van"
        case .reefer:  return "Reefer"
        case .flatbed: return "Flatbed"
        }
    }

    var shortName: String {
        switch self {
        case .dryVan:  return "Van"
        case .reefer:  return "Reefer"
        case .flatbed: return "Flat"
        }
    }

    var systemImage: String {
        switch self {
        case .dryVan:  return "shippingbox.fill"
        case .reefer:  return "thermometer.snowflake"
        case .flatbed: return "rectangle.stack.fill"
        }
    }
}

/// Directional movement of a market's rate versus the prior reporting period.
enum MarketTrend: String, Codable, Hashable {
    case up
    case flat
    case down

    var systemImage: String {
        switch self {
        case .up:   return "arrow.up.right"
        case .flat: return "arrow.right"
        case .down: return "arrow.down.right"
        }
    }

    var displayName: String {
        switch self {
        case .up:   return "Rising"
        case .flat: return "Steady"
        case .down: return "Falling"
        }
    }
}

/// Coarse rate-strength bucket that drives the green / yellow / red color code.
enum RateStrength: String, Codable, Hashable {
    case strong   // green
    case average  // yellow
    case weak     // red

    var displayName: String {
        switch self {
        case .strong:  return "Strong"
        case .average: return "Average"
        case .weak:    return "Weak"
        }
    }

    /// Classify a market's headline RPM against rolling national bands. The
    /// thresholds live here so every provider classifies identically and the
    /// legend stays consistent. Bands are intentionally conservative and can be
    /// recalibrated centrally without touching the UI.
    static func classify(rpm: Double, equipment: EquipmentType) -> RateStrength {
        let (strong, weak): (Double, Double)
        switch equipment {
        case .dryVan:  (strong, weak) = (2.10, 1.70)
        case .reefer:  (strong, weak) = (2.50, 2.05)
        case .flatbed: (strong, weak) = (2.65, 2.15)
        }
        if rpm >= strong { return .strong }
        if rpm <= weak   { return .weak }
        return .average
    }
}

/// Per-equipment rate detail inside a market.
struct EquipmentRate: Codable, Hashable {
    let equipment: EquipmentType
    /// All-in average rate per mile in USD.
    let ratePerMile: Double
    /// DAT-style load-to-truck ratio (loads posted ÷ trucks posted).
    let loadToTruckRatio: Double
    let trend: MarketTrend

    var strength: RateStrength {
        RateStrength.classify(rpm: ratePerMile, equipment: equipment)
    }
}

/// A single freight market (typically a metro / DAT market area) with its
/// coordinate and a rate breakdown for every equipment type.
struct FreightMarket: Codable, Identifiable, Hashable {
    let id: String           // stable market id, e.g. "ATL"
    let city: String
    let state: String
    let latitude: Double
    let longitude: Double
    /// Keyed by equipment so the filter can pull the right slice in O(1).
    let rates: [EquipmentType: EquipmentRate]

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var title: String { "\(city), \(state)" }

    func rate(for equipment: EquipmentType) -> EquipmentRate? {
        rates[equipment]
    }

    /// Headline RPM for the currently selected equipment (falls back to dry van).
    func ratePerMile(for equipment: EquipmentType) -> Double {
        rate(for: equipment)?.ratePerMile
            ?? rate(for: .dryVan)?.ratePerMile
            ?? 0
    }

    func strength(for equipment: EquipmentType) -> RateStrength {
        rate(for: equipment)?.strength ?? .average
    }
}

/// A full snapshot of the freight market returned by any provider. Carries the
/// markets plus national averages and the capture timestamp used for the
/// "updated X ago" label and cache staleness checks.
struct FreightRateSnapshot: Codable, Hashable {
    let markets: [FreightMarket]
    let nationalAverages: [EquipmentType: Double]
    let capturedAt: Date

    static let empty = FreightRateSnapshot(
        markets: [],
        nationalAverages: [:],
        capturedAt: .distantPast
    )

    func nationalAverage(for equipment: EquipmentType) -> Double {
        nationalAverages[equipment] ?? 0
    }

    /// Nearest market to a coordinate — powers "Rate Near Me" and the dashboard
    /// card. Returns nil when the snapshot has no markets.
    func nearestMarket(to coordinate: CLLocationCoordinate2D) -> FreightMarket? {
        guard !markets.isEmpty else { return nil }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return markets.min { a, b in
            let da = CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: here)
            let db = CLLocation(latitude: b.latitude, longitude: b.longitude).distance(from: here)
            return da < db
        }
    }
}

// Codable conformance for dictionaries keyed by an enum with a String rawValue
// works out of the box because EquipmentType is RawRepresentable<String>.
