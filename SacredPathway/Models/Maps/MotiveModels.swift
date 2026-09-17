import Foundation
import CoreLocation

// =============================================================================
// MARK: - Motive data models (READ-ONLY)
// -----------------------------------------------------------------------------
// Plain data the app DISPLAYS from a driver's authorized Motive account. Sacred
// Path Driver Hub only ever READS these — there are no initializers or methods
// anywhere that write back to Motive. Motive stays the official ELD / log of
// record; this app is a planning + visibility aid and is NOT an FMCSA-certified
// ELD.
//
// All fields are optional/lenient so the models survive Motive API version
// drift and partial authorizations (a driver may grant some scopes but not
// others — missing data simply renders as "Not authorized / unavailable").
// =============================================================================

// MARK: Driver identity

struct MotiveDriver: Codable, Identifiable, Hashable {
    var id: String
    var firstName: String?
    var lastName: String?
    var email: String?
    var phone: String?
    var role: String?              // e.g. "driver", "fleet_admin"
    var companyName: String?

    var displayName: String {
        let parts = [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? (email ?? "Driver") : parts.joined(separator: " ")
    }
}

// MARK: Vehicle / truck

struct MotiveVehicle: Codable, Identifiable, Hashable {
    var id: String
    var number: String?
    var make: String?
    var model: String?
    var year: Int?
    var vin: String?
    var licensePlate: String?
    var fuelType: String?

    var displayName: String {
        if let number, !number.isEmpty { return "Unit \(number)" }
        let mm = [make, model].compactMap { $0 }.joined(separator: " ")
        return mm.isEmpty ? "Vehicle \(id)" : mm
    }

    var subtitle: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        let mm = [make, model].compactMap { $0 }.joined(separator: " ")
        if !mm.isEmpty { parts.append(mm) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Current vehicle location

struct MotiveVehicleLocation: Codable, Hashable {
    var vehicleId: String
    var latitude: Double
    var longitude: Double
    var bearing: Double?
    var speedMph: Double?
    var fuelPercent: Double?       // engine fuel level if the ECM reports it
    var odometerMiles: Double?
    var description: String?       // Motive's reverse-geocoded label
    var locatedAt: Date?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: Hours of Service / ELD status

struct MotiveHOSSummary: Codable, Hashable {
    var driverId: String
    var dutyStatus: String?                 // "driving", "on_duty", "sleeper", "off_duty"
    var driveTimeLeftMinutes: Double?       // 11-hr remaining
    var shiftTimeLeftMinutes: Double?       // 14-hr remaining
    var cycleTimeLeftMinutes: Double?       // 60/70-hr remaining
    var breakTimeLeftMinutes: Double?       // until the 30-min break is required
    var updatedAt: Date?

    var dutyStatusDisplay: String {
        switch dutyStatus {
        case "driving":  return "Driving"
        case "on_duty":  return "On Duty"
        case "sleeper":  return "Sleeper"
        case "off_duty": return "Off Duty"
        default:         return dutyStatus?.capitalized ?? "Unknown"
        }
    }

    /// Bridges Motive's HOS into the Trip Planner's manual `HOSStatus`.
    /// Read-only: this maps Motive data into the planner; it never sends data
    /// back to Motive.
    func asHOSStatus() -> HOSStatus {
        func hrs(_ minutes: Double?, default fallback: Double) -> Double {
            guard let minutes else { return fallback }
            return max(0, minutes / 60.0)
        }
        let breakLeft = hrs(breakTimeLeftMinutes, default: 8)
        return HOSStatus(
            driveTimeLeftHours: hrs(driveTimeLeftMinutes, default: 11),
            shiftTimeLeftHours: hrs(shiftTimeLeftMinutes, default: 14),
            cycleTimeLeftHours: hrs(cycleTimeLeftMinutes, default: 70),
            hoursDrivenSinceBreak: max(0, 8 - breakLeft)
        )
    }
}

// MARK: Trip history / mileage (driving periods)

struct MotiveTrip: Codable, Identifiable, Hashable {
    var id: String
    var driverId: String?
    var vehicleId: String?
    var startTime: Date?
    var endTime: Date?
    var startLabel: String?
    var endLabel: String?
    var distanceMiles: Double?

    var dateText: String {
        guard let startTime else { return "—" }
        return startTime.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: HOS violations (read-only context)

enum MotiveViolationKind: String, Codable {
    case driving11Hour = "11_hour_driving"
    case shift14Hour = "14_hour_shift"
    case cycle70Hour = "70_hour_cycle"
    case break30Minute = "30_minute_break"
    case formAndManner = "form_and_manner"
    case other

    init(fromAPI raw: String) { self = MotiveViolationKind(rawValue: raw) ?? .other }

    var title: String {
        switch self {
        case .driving11Hour: return "11-Hour Driving"
        case .shift14Hour:   return "14-Hour Shift"
        case .cycle70Hour:   return "70-Hour Cycle"
        case .break30Minute: return "30-Minute Break"
        case .formAndManner: return "Form & Manner"
        case .other:         return "HOS Violation"
        }
    }
}

struct MotiveViolation: Codable, Identifiable, Hashable {
    var id: String
    var driverId: String?
    var kindRaw: String
    var occurredAt: Date?
    var detail: String?

    var kind: MotiveViolationKind { MotiveViolationKind(fromAPI: kindRaw) }
}

// MARK: DVIR / inspection status

struct MotiveDVIR: Codable, Identifiable, Hashable {
    var id: String
    var vehicleId: String?
    var driverId: String?
    var inspectionType: String?    // "pre_trip", "post_trip"
    var status: String?            // "satisfactory", "defects_corrected", "defects"
    var hasDefects: Bool?
    var inspectedAt: Date?
    var location: String?

    var statusDisplay: String {
        switch status {
        case "satisfactory":       return "Satisfactory"
        case "defects_corrected":  return "Defects Corrected"
        case "defects":            return "Defects Found"
        default:                   return status?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Unknown"
        }
    }

    var isSafe: Bool {
        if let hasDefects { return !hasDefects }
        return status == "satisfactory" || status == "defects_corrected"
    }
}

// MARK: Fuel / IFTA-related data

struct MotiveFuelEntry: Codable, Identifiable, Hashable {
    var id: String
    var vehicleId: String?
    var date: Date?
    var gallons: Double?
    var totalCost: Double?
    var jurisdiction: String?      // state/province code for IFTA
    var odometerMiles: Double?

    var pricePerGallon: Double? {
        guard let totalCost, let gallons, gallons > 0 else { return nil }
        return totalCost / gallons
    }
}

/// IFTA mileage rollup by jurisdiction (read-only summary).
struct MotiveIFTAJurisdiction: Codable, Identifiable, Hashable {
    var id: String { jurisdiction }
    var jurisdiction: String
    var miles: Double
    var gallons: Double?
}

// MARK: - Aggregated read-only snapshot

/// One bundle the UI binds to. Every field is optional so partial
/// authorizations and offline-cache scenarios render gracefully.
struct MotiveSnapshot: Codable, Equatable {
    var driver: MotiveDriver?
    var vehicle: MotiveVehicle?
    var location: MotiveVehicleLocation?
    var hos: MotiveHOSSummary?
    var trips: [MotiveTrip] = []
    var violations: [MotiveViolation] = []
    var dvirs: [MotiveDVIR] = []
    var fuelEntries: [MotiveFuelEntry] = []
    var iftaByJurisdiction: [MotiveIFTAJurisdiction] = []
    var fleetVehicles: [MotiveVehicle] = []   // carrier-only, if authorized

    static let empty = MotiveSnapshot()

    var isEmpty: Bool {
        driver == nil && vehicle == nil && location == nil && hos == nil &&
        trips.isEmpty && violations.isEmpty && dvirs.isEmpty &&
        fuelEntries.isEmpty && fleetVehicles.isEmpty
    }
}
