import Foundation

/// Automatically detects, creates, and links brokers and contacts from scanned document data.
/// This is the core AI CRM engine that transforms every scanned document into structured relationship data.
@MainActor
class BrokerIntelligenceService {

    static let shared = BrokerIntelligenceService()

    /// Process extracted document data to detect and link broker + contact info.
    /// Called after every successful document scan.
    func processExtractedData(
        _ data: ExtractedData,
        loadRevenue: Double?,
        supabase: SupabaseService
    ) async throws -> BrokerLinkResult {

        guard let brokerName = data.brokerName, !brokerName.isEmpty else {
            return BrokerLinkResult(broker: nil, contact: nil, action: .noBrokerDetected)
        }

        let normalizedName = Broker.normalize(brokerName)
        guard let profileId = supabase.client.auth.currentUser?.id else {
            return BrokerLinkResult(broker: nil, contact: nil, action: .noBrokerDetected)
        }

        // Step 1: Try to find existing broker by normalized name
        var broker = try await supabase.findBrokerByNormalizedName(normalizedName)
        var action: BrokerLinkAction

        if var existingBroker = broker {
            // Broker exists — update stats
            existingBroker.totalLoads = (existingBroker.totalLoads ?? 0) + 1
            existingBroker.totalRevenue = (existingBroker.totalRevenue ?? 0) + (loadRevenue ?? 0)
            existingBroker.updatedAt = Date()
            try await supabase.updateBroker(existingBroker)
            broker = existingBroker
            action = .existingBrokerUpdated
        } else {
            // Create new broker
            let newBroker = Broker(
                profileId: profileId,
                brokerName: brokerName,
                normalizedName: normalizedName,
                mcNumber: data.brokerMcNumber,
                totalLoads: 1,
                totalRevenue: loadRevenue ?? 0
            )
            broker = try await supabase.createBroker(newBroker)
            action = .newBrokerCreated
        }

        guard let linkedBroker = broker, let brokerId = linkedBroker.id else {
            return BrokerLinkResult(broker: broker, contact: nil, action: action)
        }

        // Step 2: Process contact if detected
        // Contact name could come from the document — check for common fields
        var contact: BrokerContact?
        let contactName = extractContactName(from: data)

        if let name = contactName, !name.isEmpty {
            let existingContact = try await supabase.findContact(brokerId: brokerId, name: name)

            if var existing = existingContact {
                // Contact exists — update last interaction
                existing.lastInteractionAt = Date()
                // Update email/phone if we have new data and existing is nil
                if existing.email == nil, let email = extractEmail(from: data) {
                    existing.email = email
                }
                if existing.phone == nil, let phone = extractPhone(from: data) {
                    existing.phone = phone
                }
                try await supabase.updateContact(existing)
                contact = existing
            } else {
                // Create new contact
                let newContact = BrokerContact(
                    brokerId: brokerId,
                    contactName: name,
                    email: extractEmail(from: data),
                    phone: extractPhone(from: data),
                    lastInteractionAt: Date()
                )
                contact = try await supabase.createContact(newContact)
            }
        }

        return BrokerLinkResult(broker: broker, contact: contact, action: action)
    }

    /// Suggest potential duplicate brokers that might need merging
    func findPotentialDuplicates(brokers: [Broker]) -> [(Broker, Broker)] {
        var duplicates: [(Broker, Broker)] = []
        for i in 0..<brokers.count {
            for j in (i+1)..<brokers.count {
                let name1 = brokers[i].normalizedName ?? Broker.normalize(brokers[i].brokerName)
                let name2 = brokers[j].normalizedName ?? Broker.normalize(brokers[j].brokerName)
                if levenshteinSimilarity(name1, name2) > 0.8 {
                    duplicates.append((brokers[i], brokers[j]))
                }
            }
        }
        return duplicates
    }

    // MARK: - Private Helpers

    private func extractContactName(from data: ExtractedData) -> String? {
        // The contact name might be in the notes or vendor_name for certain doc types
        // For rate confirmations, the broker contact is often embedded
        return data.notes // Placeholder — in production this would be a dedicated field
    }

    private func extractEmail(from data: ExtractedData) -> String? {
        // Scan notes for email patterns
        guard let notes = data.notes else { return nil }
        let emailPattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        if let range = notes.range(of: emailPattern, options: .regularExpression) {
            return String(notes[range])
        }
        return nil
    }

    private func extractPhone(from data: ExtractedData) -> String? {
        guard let notes = data.notes else { return nil }
        let phonePattern = "\\(?\\d{3}\\)?[-.\\s]?\\d{3}[-.\\s]?\\d{4}"
        if let range = notes.range(of: phonePattern, options: .regularExpression) {
            return String(notes[range])
        }
        return nil
    }

    /// Simple Levenshtein distance similarity (0.0 to 1.0)
    private func levenshteinSimilarity(_ s1: String, _ s2: String) -> Double {
        let s1Chars = Array(s1)
        let s2Chars = Array(s2)
        let m = s1Chars.count
        let n = s2Chars.count
        if m == 0 && n == 0 { return 1.0 }
        if m == 0 || n == 0 { return 0.0 }

        var matrix = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { matrix[i][0] = i }
        for j in 0...n { matrix[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = s1Chars[i-1] == s2Chars[j-1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i-1][j] + 1,
                    matrix[i][j-1] + 1,
                    matrix[i-1][j-1] + cost
                )
            }
        }

        let distance = Double(matrix[m][n])
        let maxLen = Double(max(m, n))
        return 1.0 - (distance / maxLen)
    }
}

// MARK: - Result Types

struct BrokerLinkResult {
    let broker: Broker?
    let contact: BrokerContact?
    let action: BrokerLinkAction
}

enum BrokerLinkAction {
    case noBrokerDetected
    case newBrokerCreated
    case existingBrokerUpdated
}
