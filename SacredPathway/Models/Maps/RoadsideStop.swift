import Foundation
import CoreLocation
import MapKit

enum SacredPathCategory: String, CaseIterable, Codable, Identifiable {
    case truckStops
    case restAreas
    case fuel
    case scales
    case weighStations
    case parking
    case repair
    case hotels

    var id: String { rawValue }

    var databaseValue: String {
        switch self {
        case .truckStops: return "truck_stops"
        case .restAreas: return "rest_areas"
        case .fuel: return "fuel"
        case .scales: return "scales"
        case .weighStations: return "weigh_stations"
        case .parking: return "parking"
        case .repair: return "repair"
        case .hotels: return "hotels"
        }
    }

    init?(databaseValue: String) {
        switch databaseValue {
        case "truck_stops": self = .truckStops
        case "rest_areas": self = .restAreas
        case "fuel": self = .fuel
        case "scales": self = .scales
        case "weigh_stations": self = .weighStations
        case "parking": self = .parking
        case "repair": self = .repair
        case "hotels": self = .hotels
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .truckStops: return "Truck Stops & Travel Centers"
        case .restAreas: return "Rest Areas"
        case .fuel: return "Fuel"
        case .scales: return "CAT Scales / Truck Scales"
        case .weighStations: return "Weigh Stations"
        case .parking: return "Parking"
        case .repair: return "Repair / Tire Shops"
        case .hotels: return "Hotels & Lodging"
        }
    }

    var shortTitle: String {
        switch self {
        case .truckStops: return "Truck Stops"
        case .restAreas: return "Rest"
        case .fuel: return "Fuel"
        case .scales: return "Scales"
        case .weighStations: return "Weigh"
        case .parking: return "Parking"
        case .repair: return "Repair"
        case .hotels: return "Hotels"
        }
    }

    var systemImage: String {
        switch self {
        case .truckStops: return "truck.box.fill"
        case .restAreas: return "parkingsign.circle.fill"
        case .fuel: return "fuelpump.fill"
        case .scales: return "scalemass.fill"
        case .weighStations: return "building.columns.fill"
        case .parking: return "parkingsign.square.fill"
        case .repair: return "wrench.and.screwdriver.fill"
        case .hotels: return "bed.double.fill"
        }
    }

    var searchQueries: [String] {
        switch self {
        case .truckStops:
            return ["truck stop", "travel center", "travel plaza"]
        case .restAreas:
            return ["rest area", "welcome center"]
        case .fuel:
            return ["diesel fuel", "truck fuel", "gas station"]
        case .scales:
            return ["truck scale", "CAT Scale"]
        case .weighStations:
            return ["weigh station"]
        case .parking:
            return ["truck parking", "overnight truck parking", "parking"]
        case .repair:
            return ["truck repair", "tire shop"]
        case .hotels:
            return ["truck parking hotel", "hotel", "motel"]
        }
    }
}

// =============================================================================
// MARK: - TruckStopBrand
// -----------------------------------------------------------------------------
// Identifies a major truck-stop / travel-center brand from a place name so the
// map marker can carry that brand's signature COLOR and a short text label.
//
// IMPORTANT (legal): we do NOT bundle or render any brand's trademarked logo
// artwork. Reproducing Love's / Pilot / etc. logos in a shipping App Store app
// is trademark infringement risk. Instead we use the brand NAME as text
// (nominative fair use — identifying the place) plus a recognizable brand color.
// Unknown brands fall back to a clean generic truck-stop icon.
// =============================================================================
enum TruckStopBrand: String, CaseIterable {
    case loves, pilot, flyingJ, ta, petro, speedway, roadRanger, caseys, kwikTrip

    /// Short label drawn on the marker (nominative use of the brand name).
    var label: String {
        switch self {
        case .loves:      return "Love's"
        case .pilot:      return "Pilot"
        case .flyingJ:    return "Flying J"
        case .ta:         return "TA"
        case .petro:      return "Petro"
        case .speedway:   return "Speedway"
        case .roadRanger: return "Road Ranger"
        case .caseys:     return "Casey's"
        case .kwikTrip:   return "Kwik Trip"
        }
    }

    /// Brand signature color (approximate, used only for identification).
    /// Returned as RGB so the view layer can build a SwiftUI Color without
    /// depending on asset catalog entries.
    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .loves:      return (0.85, 0.13, 0.14) // Love's red
        case .pilot:      return (0.84, 0.10, 0.13) // Pilot red
        case .flyingJ:    return (0.90, 0.49, 0.13) // Flying J orange
        case .ta:         return (0.13, 0.32, 0.62) // TravelCenters blue
        case .petro:      return (0.13, 0.45, 0.27) // Petro green
        case .speedway:   return (0.16, 0.30, 0.56) // Speedway blue
        case .roadRanger: return (0.90, 0.30, 0.10) // Road Ranger orange-red
        case .caseys:     return (0.78, 0.14, 0.18) // Casey's red
        case .kwikTrip:   return (0.86, 0.16, 0.20) // Kwik Trip red
        }
    }

    /// Detect a brand from a place name. Returns nil for generic stops.
    static func detect(from name: String) -> TruckStopBrand? {
        let n = name.lowercased()
        if n.contains("love's") || n.contains("loves travel") || n.contains("love’s") { return .loves }
        if n.contains("flying j") { return .flyingJ }
        if n.contains("pilot") { return .pilot } // after Flying J so "Pilot Flying J" -> Flying J
        if n.contains("petro") { return .petro }
        if n.contains("ta travel") || n.contains("travelcenters") || n.hasPrefix("ta ") || n == "ta" { return .ta }
        if n.contains("speedway") { return .speedway }
        if n.contains("road ranger") { return .roadRanger }
        if n.contains("casey") { return .caseys }
        if n.contains("kwik trip") || n.contains("kwik star") { return .kwikTrip }
        return nil
    }
}

// =============================================================================
// MARK: - SacredPathAmenityFilter
// -----------------------------------------------------------------------------
// Amenity-based filter chips that layer on top of the category filters. A stop
// matches when the amenity is present in its inferred `amenities` list (see
// SacredPathPlace.amenities(for:name:)). These are NOT separate POI searches —
// showers and DEF in particular are not reliably discoverable as standalone
// map points, so they are derived from brand + category + name and used to
// narrow the already-loaded stops.
// =============================================================================
enum SacredPathAmenityFilter: String, CaseIterable, Identifiable {
    case showers
    case def
    case food
    case overnightParking

    var id: String { rawValue }

    var title: String {
        switch self {
        case .showers: return "Showers"
        case .def: return "DEF"
        case .food: return "Food"
        case .overnightParking: return "Overnight Parking"
        }
    }

    var systemImage: String {
        switch self {
        case .showers: return "shower.fill"
        case .def: return "drop.fill"
        case .food: return "fork.knife"
        case .overnightParking: return "moon.zzz.fill"
        }
    }

    /// The amenity tag this filter matches against a stop's `amenities`.
    var amenityTag: String {
        switch self {
        case .showers: return "Showers"
        case .def: return "DEF"
        case .food: return "Food"
        case .overnightParking: return "Overnight parking"
        }
    }

    /// True when the stop carries this amenity.
    func matches(_ stop: SacredPathPlace) -> Bool {
        stop.amenities.contains { $0.caseInsensitiveCompare(amenityTag) == .orderedSame }
    }
}

enum ParkingReportStatus: String, CaseIterable, Codable, Identifiable {
    case available
    case limited
    case full
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .available: return "Plenty"
        case .limited: return "Some"
        case .full: return "Full"
        case .unknown: return "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .available: return "checkmark.circle.fill"
        case .limited: return "circle.lefthalf.filled"
        case .full: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "available", "plenty":
            self = .available
        case "limited", "some":
            self = .limited
        case "full":
            self = .full
        default:
            self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct SacredPathPlace: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let category: SacredPathCategory
    let latitude: Double
    let longitude: Double
    let address: String
    let phoneNumber: String?
    let urlString: String?
    let openStatus: String?
    let amenities: [String]
    let appleMapsPlaceID: String?
    let appleMapsPointOfInterestCategory: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var url: URL? {
        urlString.flatMap(URL.init(string:))
    }

    func distanceMiles(from location: CLLocation?) -> Double? {
        guard let location else { return nil }
        let stopLocation = CLLocation(latitude: latitude, longitude: longitude)
        return location.distance(from: stopLocation) / 1609.344
    }

    func mapItem() -> MKMapItem {
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = name
        item.phoneNumber = phoneNumber
        item.url = url
        return item
    }
}

struct SacredPathParkingReport: Codable, Equatable {
    let stopID: String
    var status: ParkingReportStatus
    var notes: String?
    var updatedAt: Date
}
