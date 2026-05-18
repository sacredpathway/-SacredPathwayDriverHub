import Foundation
import Contacts

/// Thin wrapper around the system Contacts framework so the rest of the app
/// can import broker reps from / save broker reps to the user's iPhone
/// address book. Permission handling is built in — if the user denies the
/// prompt, every call returns a clean error and the app continues to work
/// off its internal Broker Contacts store.
///
/// All public APIs are `async` so callers can chain authorization + work
/// without nested completion handlers.
enum ContactsBridge {

    // MARK: - Errors

    enum BridgeError: LocalizedError {
        case notAuthorized
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Sacred Pathway doesn't have permission to use iPhone Contacts. Enable it in Settings → Privacy → Contacts."
            case .underlying(let e):
                return e.localizedDescription
            }
        }
    }

    // MARK: - Authorization

    /// Authorization status for contacts. Wraps `CNContactStore.authorizationStatus`.
    /// Returns one of: .notDetermined, .restricted, .denied, .authorized.
    static var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    /// Request authorization. Returns true if granted, false if denied. Safe
    /// to call multiple times — if already granted/denied the system returns
    /// the cached answer.
    static func requestAccess() async -> Bool {
        let status = authorizationStatus
        if status == .authorized { return true }
        if status == .denied || status == .restricted { return false }
        let store = CNContactStore()
        return await withCheckedContinuation { cont in
            store.requestAccess(for: .contacts) { granted, _ in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - Public surface

    /// Search the user's contacts for entries matching `query` (name, email,
    /// phone). Returns up to 25 lightweight rows. Throws `.notAuthorized`
    /// if the user hasn't granted Contacts permission.
    static func search(_ query: String) async throws -> [ImportedContact] {
        guard await requestAccess() else { throw BridgeError.notAuthorized }
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let predicate = CNContact.predicateForContacts(matchingName: trimmed)
        let cnContacts: [CNContact]
        do {
            cnContacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        } catch {
            throw BridgeError.underlying(error)
        }

        return cnContacts.prefix(25).map { ImportedContact(cn: $0) }
    }

    /// Insert a new contact card into the user's iPhone Contacts. Returns the
    /// inserted identifier. Throws `.notAuthorized` if permission is missing.
    @discardableResult
    static func save(
        firstName: String,
        lastName: String?,
        organization: String?,
        phone: String?,
        phoneExtension: String?,
        email: String?
    ) async throws -> String {
        guard await requestAccess() else { throw BridgeError.notAuthorized }
        let store = CNContactStore()

        let new = CNMutableContact()
        new.givenName = firstName
        if let lastName, !lastName.isEmpty { new.familyName = lastName }
        if let organization, !organization.isEmpty { new.organizationName = organization }

        if let phone, !phone.isEmpty {
            // Append extension in the standard "phone;ext=..." CNPhoneNumber
            // form so contacts.app shows it correctly.
            let composed: String = {
                if let ext = phoneExtension, !ext.isEmpty {
                    return "\(phone);ext=\(ext)"
                }
                return phone
            }()
            new.phoneNumbers = [
                CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: composed))
            ]
        }
        if let email, !email.isEmpty {
            new.emailAddresses = [
                CNLabeledValue(label: CNLabelWork, value: email as NSString)
            ]
        }

        let req = CNSaveRequest()
        req.add(new, toContainerWithIdentifier: nil)
        do {
            try store.execute(req)
        } catch {
            throw BridgeError.underlying(error)
        }
        return new.identifier
    }

    /// Convenience: save a `BrokerContact` (with the optional company name)
    /// directly to iPhone Contacts.
    @discardableResult
    static func save(contact: BrokerContact, company: String?) async throws -> String {
        // Split contact name into first/last (best effort — anything beyond
        // two tokens is treated as middle/given for simplicity).
        let parts = contact.contactName
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let first = parts.first ?? contact.contactName
        let last = parts.count > 1 ? parts.dropFirst().joined(separator: " ") : nil

        return try await save(
            firstName: first,
            lastName: last,
            organization: company,
            phone: contact.phone,
            phoneExtension: contact.phoneExtension,
            email: contact.email
        )
    }
}

/// Lightweight value object Sacred Pathway uses to ferry contacts pulled
/// out of the system address book — keeps the rest of the app free of any
/// CNContact / Contacts framework types.
struct ImportedContact: Identifiable, Hashable {
    let id: String
    var displayName: String
    var organization: String?
    var phone: String?
    var phoneExtension: String?
    var email: String?

    init(cn: CNContact) {
        self.id = cn.identifier
        let full = [cn.givenName, cn.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        self.displayName = full.isEmpty
            ? (cn.organizationName.isEmpty ? "(Unnamed)" : cn.organizationName)
            : full
        self.organization = cn.organizationName.isEmpty ? nil : cn.organizationName

        // Phone — strip extension into a separate field if present.
        if let first = cn.phoneNumbers.first?.value.stringValue {
            let (raw, ext) = ImportedContact.splitExtension(first)
            self.phone = raw
            self.phoneExtension = ext
        }

        // Email
        if let first = cn.emailAddresses.first?.value as String? {
            self.email = first
        }
    }

    /// Split "8005803101;ext=54136" into ("8005803101", "54136"). Tolerates
    /// various separators used in real iOS contact cards.
    static func splitExtension(_ raw: String) -> (String, String?) {
        for sep in [";ext=", ";ext:", " ext ", " ext.", "x", "X"] {
            if let range = raw.range(of: sep) {
                let phone = String(raw[..<range.lowerBound])
                let ext = String(raw[range.upperBound...])
                    .filter(\.isNumber)
                return (phone.trimmingCharacters(in: .whitespaces),
                        ext.isEmpty ? nil : ext)
            }
        }
        return (raw, nil)
    }
}
