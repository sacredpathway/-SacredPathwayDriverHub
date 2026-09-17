import Foundation
import SwiftUI

// =============================================================================
// MARK: - Driver Alert Model
// -----------------------------------------------------------------------------
// The unit of output from the AlertEngine. Combines weather + location into a
// single actionable item that can render as a dashboard card, fire a local
// notification, and live in the Alert Center history.
// =============================================================================

enum DriverAlertCategory: String, Codable, CaseIterable, Hashable {
    case severeStorm
    case highWind
    case snowIce
    case heavyRain
    case extremeHeat
    case flood

    var title: String {
        switch self {
        case .severeStorm: return "Severe Storm"
        case .highWind:    return "High Wind"
        case .snowIce:     return "Snow / Ice"
        case .heavyRain:   return "Heavy Rain"
        case .extremeHeat: return "Extreme Heat"
        case .flood:       return "Flood Warning"
        }
    }

    var systemImage: String {
        switch self {
        case .severeStorm: return "cloud.bolt.rain.fill"
        case .highWind:    return "wind"
        case .snowIce:     return "snowflake"
        case .heavyRain:   return "cloud.heavyrain.fill"
        case .extremeHeat: return "thermometer.sun.fill"
        case .flood:       return "water.waves"
        }
    }
}

enum DriverAlertSeverity: Int, Codable, Comparable, Hashable {
    case advisory = 0   // informational
    case watch    = 1   // conditions possible
    case warning  = 2   // conditions occurring / imminent

    static func < (lhs: DriverAlertSeverity, rhs: DriverAlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .advisory: return "Advisory"
        case .watch:    return "Watch"
        case .warning:  return "Warning"
        }
    }

    /// Maps to brand status colors. Returned as a hint; views resolve the actual
    /// `Color` so this stays SwiftUI-free at the model layer where convenient.
    var colorName: String {
        switch self {
        case .advisory: return "warning"   // yellow
        case .watch:    return "warning"
        case .warning:  return "danger"    // red
        }
    }
}

struct DriverAlert: Codable, Identifiable, Hashable {
    let id: UUID
    let category: DriverAlertCategory
    let severity: DriverAlertSeverity
    let title: String
    let message: String
    /// Coordinate the alert was generated for (the truck's position at the time).
    let coordinate: CodableCoordinate
    let placeName: String?
    let createdAt: Date
    /// When true, this alert has already produced a local notification so the
    /// engine never double-notifies for the same condition window.
    var didNotify: Bool

    init(id: UUID = UUID(),
         category: DriverAlertCategory,
         severity: DriverAlertSeverity,
         title: String,
         message: String,
         coordinate: CodableCoordinate,
         placeName: String?,
         createdAt: Date = Date(),
         didNotify: Bool = false) {
        self.id = id
        self.category = category
        self.severity = severity
        self.title = title
        self.message = message
        self.coordinate = coordinate
        self.placeName = placeName
        self.createdAt = createdAt
        self.didNotify = didNotify
    }

    /// Stable de-duplication key: same category + severity + ~hour window +
    /// rounded location is treated as the same alert so we don't spam history.
    var dedupeKey: String {
        let hour = Int(createdAt.timeIntervalSince1970 / 3600)
        let lat = (coordinate.latitude * 10).rounded() / 10
        let lon = (coordinate.longitude * 10).rounded() / 10
        return "\(category.rawValue)|\(severity.rawValue)|\(hour)|\(lat),\(lon)"
    }
}

extension DriverAlertSeverity {
    /// SwiftUI color resolved from the brand status palette.
    var color: Color {
        switch self {
        case .advisory: return .spWarning
        case .watch:    return .spWarning
        case .warning:  return .spDanger
        }
    }
}
