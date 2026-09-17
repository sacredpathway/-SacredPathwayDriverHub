import Foundation
import SwiftUI
import UserNotifications

// MARK: - Compliance Category

enum ComplianceCategory: String, CaseIterable, Codable {
    case company
    case truck
    case trailer
    case driver

    var displayName: String {
        switch self {
        case .company: return "Company"
        case .truck: return "Truck"
        case .trailer: return "Trailer"
        case .driver: return "Driver"
        }
    }

    var iconName: String {
        switch self {
        case .company: return "building.2.fill"
        case .truck: return "truck.box.fill"
        case .trailer: return "cube.box.fill"
        case .driver: return "person.crop.circle.fill"
        }
    }
}

// MARK: - Expiration reminders

enum ComplianceReminderPlanner {
    static let intervals = [30, 14, 7, 1]

    static func identifier(documentID: UUID, daysBefore: Int) -> String {
        "com.sacredpathway.compliance.\(documentID.uuidString.lowercased()).\(daysBefore)"
    }

    static func identifiers(documentID: UUID) -> [String] {
        intervals.map { identifier(documentID: documentID, daysBefore: $0) }
    }

    static func reminders(
        documentID: UUID,
        expirationDate: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [(identifier: String, date: Date)] {
        guard let expirationDate else { return [] }
        return intervals.compactMap { days in
            guard let day = calendar.date(byAdding: .day, value: -days,
                                          to: calendar.startOfDay(for: expirationDate)),
                  let fireDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                  fireDate > now else { return nil }
            return (identifier(documentID: documentID, daysBefore: days), fireDate)
        }
    }
}

@MainActor
final class ComplianceReminderService {
    static let shared = ComplianceReminderService()
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func reconcile(documentID: UUID, expirationDate: Date?) async {
        center.removePendingNotificationRequests(
            withIdentifiers: ComplianceReminderPlanner.identifiers(documentID: documentID)
        )
        let reminders = ComplianceReminderPlanner.reminders(
            documentID: documentID, expirationDate: expirationDate
        )
        guard !reminders.isEmpty else { return }

        let settings = await center.notificationSettings()
        var authorized = settings.authorizationStatus == .authorized ||
            settings.authorizationStatus == .provisional
        if settings.authorizationStatus == .notDetermined {
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        }
        guard authorized else { return }

        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = "Compliance reminder"
            content.body = "A compliance item is approaching its expiration date. Open Sacred Pathway Driver Hub to review it."
            content.sound = .default
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: reminder.date
            )
            let request = UNNotificationRequest(
                identifier: reminder.identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }

    func cancel(documentID: UUID) {
        center.removePendingNotificationRequests(
            withIdentifiers: ComplianceReminderPlanner.identifiers(documentID: documentID)
        )
    }
}

// MARK: - Compliance Status

enum ComplianceStatus {
    case expired
    case expiringSoon
    case valid
    case noExpiration

    var color: Color {
        switch self {
        case .expired: return Color.spDanger
        case .expiringSoon: return Color.spWarning
        case .valid: return Color.spSuccess
        case .noExpiration: return Color.spTextSecondary
        }
    }

    var label: String {
        switch self {
        case .expired: return "Expired"
        case .expiringSoon: return "Expiring Soon"
        case .valid: return "Valid"
        case .noExpiration: return "No Expiration"
        }
    }
}

// MARK: - ComplianceDocument Model

struct ComplianceDocument: Codable, Identifiable {
    var id: UUID?
    let profileId: UUID
    var category: String
    var title: String
    var storagePath: String?
    var issueDate: Date?           // Postgres DATE
    var expirationDate: Date?      // Postgres DATE
    var notes: String?
    var fileMimeType: String?
    var fileSize: Int?
    var createdAt: Date?           // Postgres TIMESTAMPTZ
    var updatedAt: Date?           // Postgres TIMESTAMPTZ

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case category, title
        case storagePath = "storage_path"
        case issueDate = "issue_date"
        case expirationDate = "expiration_date"
        case notes
        case fileMimeType = "file_mime_type"
        case fileSize = "file_size"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: UUID? = nil,
        profileId: UUID,
        category: String,
        title: String,
        storagePath: String? = nil,
        issueDate: Date? = nil,
        expirationDate: Date? = nil,
        notes: String? = nil,
        fileMimeType: String? = nil,
        fileSize: Int? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.category = category
        self.title = title
        self.storagePath = storagePath
        self.issueDate = issueDate
        self.expirationDate = expirationDate
        self.notes = notes
        self.fileMimeType = fileMimeType
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Custom Codable

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        profileId = try c.decode(UUID.self, forKey: .profileId)
        category = try c.decode(String.self, forKey: .category)
        title = try c.decode(String.self, forKey: .title)
        storagePath = try c.decodeIfPresent(String.self, forKey: .storagePath)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        fileMimeType = try c.decodeIfPresent(String.self, forKey: .fileMimeType)
        fileSize = try c.decodeIfPresent(Int.self, forKey: .fileSize)
        issueDate = try SPDate.decode(c, forKey: .issueDate)
        expirationDate = try SPDate.decode(c, forKey: .expirationDate)
        createdAt = try SPDate.decode(c, forKey: .createdAt)
        updatedAt = try SPDate.decode(c, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(profileId, forKey: .profileId)
        try c.encode(category, forKey: .category)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(storagePath, forKey: .storagePath)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(fileMimeType, forKey: .fileMimeType)
        try c.encodeIfPresent(fileSize, forKey: .fileSize)
        try SPDate.encodeDateOnly(issueDate, into: &c, forKey: .issueDate)
        try SPDate.encodeDateOnly(expirationDate, into: &c, forKey: .expirationDate)
        try SPDate.encodeISO(createdAt, into: &c, forKey: .createdAt)
        try SPDate.encodeISO(updatedAt, into: &c, forKey: .updatedAt)
    }

    // MARK: - Computed Properties

    func status() -> ComplianceStatus {
        guard let expDate = expirationDate else {
            return .noExpiration
        }

        let today = Calendar.current.startOfDay(for: Date())
        let thirtyDaysFromNow = Calendar.current.date(byAdding: .day, value: 30, to: today) ?? today

        if expDate < today {
            return .expired
        } else if expDate <= thirtyDaysFromNow {
            return .expiringSoon
        } else {
            return .valid
        }
    }
}
