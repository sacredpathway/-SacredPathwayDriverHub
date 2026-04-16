import Foundation

// MARK: - Draft Models
struct DraftLoadItem: Codable, Identifiable {
    var id: UUID = UUID()
    var loadNumber: String = ""
    var broker: String = ""
    var origin: String = ""
    var destination: String = ""
    var miles: String = ""
    var revenue: String = ""
}

struct DraftExpenseItem: Codable, Identifiable {
    var id: UUID = UUID()
    var category: String = "Fuel"
    var description: String = ""
    var amount: String = ""
}

struct PaystubDraft: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var companyName: String
    var driverName: String
    var periodStart: Date
    var periodEnd: Date
    var loads: [DraftLoadItem]
    var expenses: [DraftExpenseItem]
    var driverPayPct: String
    var dispatcherFeePct: String
    var factoringFeePct: String
    var authorityFee: String
    var maintenanceReserve: String
    var createdAt: Date
    var updatedAt: Date

    var totalRevenue: Double {
        loads.reduce(0) { $0 + (Double($1.revenue) ?? 0) }
    }

    var loadCount: Int { loads.filter { !(Double($0.revenue) ?? 0).isZero }.count }

    var summary: String {
        let rev = totalRevenue
        if rev > 0 {
            return "\(loadCount) load\(loadCount == 1 ? "" : "s") • $\(String(format: "%.2f", rev))"
        }
        return "No loads yet"
    }
}

// MARK: - Storage Service
class DraftStorageService {
    static let shared = DraftStorageService()

    private let fileManager = FileManager.default

    private var draftsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("PaystubDrafts", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Save
    func saveDraft(_ draft: PaystubDraft) throws {
        var updated = draft
        updated.updatedAt = Date()
        let data = try encoder.encode(updated)
        let file = draftsDirectory.appendingPathComponent("\(draft.id.uuidString).json")
        try data.write(to: file)
    }

    // MARK: - Load All
    func loadAllDrafts() -> [PaystubDraft] {
        guard let files = try? fileManager.contentsOfDirectory(at: draftsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> PaystubDraft? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(PaystubDraft.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Load Single
    func loadDraft(id: UUID) -> PaystubDraft? {
        let file = draftsDirectory.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(PaystubDraft.self, from: data)
    }

    // MARK: - Delete
    func deleteDraft(id: UUID) throws {
        let file = draftsDirectory.appendingPathComponent("\(id.uuidString).json")
        if fileManager.fileExists(atPath: file.path) {
            try fileManager.removeItem(at: file)
        }
    }
}
