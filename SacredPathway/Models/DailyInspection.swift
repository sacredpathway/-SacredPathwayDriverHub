import Foundation
import SwiftUI

// MARK: - Inspection Type

enum InspectionType: String, CaseIterable, Codable {
    case preTrip = "pre_trip"
    case postTrip = "post_trip"

    var displayName: String {
        switch self {
        case .preTrip:  return "Pre-Trip"
        case .postTrip: return "Post-Trip"
        }
    }
}

// MARK: - Inspection Status

enum InspectionStatus: String, CaseIterable, Codable {
    case noDefects = "no_defects"
    case defectsFound = "defects_found"
    case repaired
    case needsRepair = "needs_repair"

    var displayName: String {
        switch self {
        case .noDefects:    return "No Defects"
        case .defectsFound: return "Defects Found"
        case .repaired:     return "Repaired"
        case .needsRepair:  return "Needs Repair"
        }
    }

    var color: Color {
        switch self {
        case .noDefects:    return .spSuccess
        case .defectsFound: return .spWarning
        case .repaired:     return .spGoldLight
        case .needsRepair:  return .spDanger
        }
    }

    var iconName: String {
        switch self {
        case .noDefects:    return "checkmark.circle.fill"
        case .defectsFound: return "exclamationmark.triangle.fill"
        case .repaired:     return "wrench.adjustable.fill"
        case .needsRepair:  return "xmark.octagon.fill"
        }
    }
}

// MARK: - DailyInspection Model

struct DailyInspection: Codable, Identifiable {
    var id: UUID?
    let profileId: UUID
    var inspectionDate: Date          // Postgres DATE
    var driverName: String?
    var truckNumber: String?
    var trailerNumber: String?
    var odometer: Int?
    var inspectionType: String        // InspectionType.rawValue
    var hasDefects: Bool
    var defectNotes: String?
    var status: String                // InspectionStatus.rawValue
    var signatureName: String?
    var signedAt: Date?               // Postgres TIMESTAMPTZ
    var photoPaths: [String]?         // Postgres text[] — storage paths in 'inspection-photos' bucket
    var createdAt: Date?              // TIMESTAMPTZ
    var updatedAt: Date?              // TIMESTAMPTZ

    // Convenience type-safe accessors so views don't juggle raw strings.
    var typeEnum: InspectionType {
        InspectionType(rawValue: inspectionType) ?? .preTrip
    }

    var statusEnum: InspectionStatus {
        InspectionStatus(rawValue: status) ?? .noDefects
    }

    enum CodingKeys: String, CodingKey {
        case id
        case profileId        = "profile_id"
        case inspectionDate   = "inspection_date"
        case driverName       = "driver_name"
        case truckNumber      = "truck_number"
        case trailerNumber    = "trailer_number"
        case odometer
        case inspectionType   = "inspection_type"
        case hasDefects       = "has_defects"
        case defectNotes      = "defect_notes"
        case status
        case signatureName    = "signature_name"
        case signedAt         = "signed_at"
        case photoPaths       = "photo_paths"
        case createdAt        = "created_at"
        case updatedAt        = "updated_at"
    }

    // MARK: - Init (memberwise with defaults)

    init(
        id: UUID? = nil,
        profileId: UUID,
        inspectionDate: Date,
        driverName: String? = nil,
        truckNumber: String? = nil,
        trailerNumber: String? = nil,
        odometer: Int? = nil,
        inspectionType: String = InspectionType.preTrip.rawValue,
        hasDefects: Bool = false,
        defectNotes: String? = nil,
        status: String = InspectionStatus.noDefects.rawValue,
        signatureName: String? = nil,
        signedAt: Date? = nil,
        photoPaths: [String]? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.inspectionDate = inspectionDate
        self.driverName = driverName
        self.truckNumber = truckNumber
        self.trailerNumber = trailerNumber
        self.odometer = odometer
        self.inspectionType = inspectionType
        self.hasDefects = hasDefects
        self.defectNotes = defectNotes
        self.status = status
        self.signatureName = signatureName
        self.signedAt = signedAt
        self.photoPaths = photoPaths
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Custom Codable (SPDate handles DATE + TIMESTAMPTZ)

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decodeIfPresent(UUID.self,   forKey: .id)
        profileId      = try c.decode(UUID.self,            forKey: .profileId)
        driverName     = try c.decodeIfPresent(String.self, forKey: .driverName)
        truckNumber    = try c.decodeIfPresent(String.self, forKey: .truckNumber)
        trailerNumber  = try c.decodeIfPresent(String.self, forKey: .trailerNumber)
        odometer       = try c.decodeIfPresent(Int.self,    forKey: .odometer)
        inspectionType = try c.decodeIfPresent(String.self, forKey: .inspectionType) ?? InspectionType.preTrip.rawValue
        hasDefects     = try c.decodeIfPresent(Bool.self,   forKey: .hasDefects) ?? false
        defectNotes    = try c.decodeIfPresent(String.self, forKey: .defectNotes)
        status         = try c.decodeIfPresent(String.self, forKey: .status) ?? InspectionStatus.noDefects.rawValue
        signatureName  = try c.decodeIfPresent(String.self, forKey: .signatureName)
        photoPaths     = try c.decodeIfPresent([String].self, forKey: .photoPaths)

        // DATE — required
        if let d = try SPDate.decode(c, forKey: .inspectionDate) {
            inspectionDate = d
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: c.codingPath,
                    debugDescription: "inspection_date is required but missing"
                )
            )
        }

        // TIMESTAMPTZ fields — optional
        signedAt  = try SPDate.decode(c, forKey: .signedAt)
        createdAt = try SPDate.decode(c, forKey: .createdAt)
        updatedAt = try SPDate.decode(c, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id,             forKey: .id)
        try c.encode(profileId,               forKey: .profileId)
        try SPDate.encodeDateOnly(inspectionDate, into: &c, forKey: .inspectionDate)
        try c.encodeIfPresent(driverName,     forKey: .driverName)
        try c.encodeIfPresent(truckNumber,    forKey: .truckNumber)
        try c.encodeIfPresent(trailerNumber,  forKey: .trailerNumber)
        try c.encodeIfPresent(odometer,       forKey: .odometer)
        try c.encode(inspectionType,          forKey: .inspectionType)
        try c.encode(hasDefects,              forKey: .hasDefects)
        try c.encodeIfPresent(defectNotes,    forKey: .defectNotes)
        try c.encode(status,                  forKey: .status)
        try c.encodeIfPresent(signatureName,  forKey: .signatureName)
        try SPDate.encodeISO(signedAt, into: &c, forKey: .signedAt)
        try c.encodeIfPresent(photoPaths,     forKey: .photoPaths)
        try SPDate.encodeISO(createdAt, into: &c, forKey: .createdAt)
        try SPDate.encodeISO(updatedAt, into: &c, forKey: .updatedAt)
    }
}
