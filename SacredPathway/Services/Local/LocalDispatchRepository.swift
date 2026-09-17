import Foundation

@MainActor
final class LocalDispatchRepository: ObservableObject {
    static let shared = LocalDispatchRepository()

    private let threadsFile = "dispatch_threads.json"
    private let messagesFile = "dispatch_messages.json"
    private let participantsFile = "dispatch_participants.json"
    private let offersFile = "dispatch_load_offers.json"
    private let paymentsFile = "dispatcher_payment_records.json"
    private let profilesFile = "dispatcher_profiles.json"
    private let reviewsFile = "dispatcher_reviews.json"
    private let serviceRequestsFile = "dispatch_service_requests.json"
    private let agreementsFile = "dispatch_agreements.json"
    private let feeRecordsFile = "dispatcher_fee_records.json"
    private let invoicesFile = "dispatcher_invoices.json"

    @Published private(set) var threads: [DispatchThread] = []
    @Published private(set) var messages: [DispatchMessage] = []
    @Published private(set) var participants: [DispatchParticipant] = []
    @Published private(set) var offers: [DispatchLoadOffer] = []
    @Published private(set) var payments: [DispatcherPaymentRecord] = []
    @Published private(set) var profiles: [DispatcherProfile] = []
    @Published private(set) var reviews: [DispatcherReview] = []
    @Published private(set) var serviceRequests: [DispatchServiceRequest] = []
    @Published private(set) var agreements: [DispatchAgreement] = []
    @Published private(set) var feeRecords: [DispatcherFeeRecord] = []
    @Published private(set) var invoices: [DispatcherInvoice] = []

    private init() {
        reload()
    }

    func reload() {
        threads = newestThreads(LocalStore.loadArray(DispatchThread.self, fileName: threadsFile))
        messages = oldestMessages(LocalStore.loadArray(DispatchMessage.self, fileName: messagesFile))
        participants = newestParticipants(LocalStore.loadArray(DispatchParticipant.self, fileName: participantsFile))
        offers = newestOffers(LocalStore.loadArray(DispatchLoadOffer.self, fileName: offersFile))
        payments = newestPayments(LocalStore.loadArray(DispatcherPaymentRecord.self, fileName: paymentsFile))
        profiles = newestProfiles(LocalStore.loadArray(DispatcherProfile.self, fileName: profilesFile))
        reviews = newestReviews(LocalStore.loadArray(DispatcherReview.self, fileName: reviewsFile))
        serviceRequests = newestRequests(LocalStore.loadArray(DispatchServiceRequest.self, fileName: serviceRequestsFile))
        agreements = newestAgreements(LocalStore.loadArray(DispatchAgreement.self, fileName: agreementsFile))
        feeRecords = newestFeeRecords(LocalStore.loadArray(DispatcherFeeRecord.self, fileName: feeRecordsFile))
        invoices = newestInvoices(LocalStore.loadArray(DispatcherInvoice.self, fileName: invoicesFile))
    }

    func fetchThreads() -> [DispatchThread] { threads }
    func fetchMessages() -> [DispatchMessage] { messages }
    func fetchParticipants() -> [DispatchParticipant] { participants }
    func fetchOffers() -> [DispatchLoadOffer] { offers }
    func fetchPayments() -> [DispatcherPaymentRecord] { payments }
    func fetchProfiles() -> [DispatcherProfile] { profiles }
    func fetchReviews() -> [DispatcherReview] { reviews }
    func fetchServiceRequests() -> [DispatchServiceRequest] { serviceRequests }
    func fetchAgreements() -> [DispatchAgreement] { agreements }
    func fetchFeeRecords() -> [DispatcherFeeRecord] { feeRecords }
    func fetchInvoices() -> [DispatcherInvoice] { invoices }

    @discardableResult
    func upsertThread(_ thread: DispatchThread) -> DispatchThread {
        var copy = thread
        if copy.id == nil { copy.id = UUID() }
        if copy.createdAt == nil { copy.createdAt = Date() }
        copy.updatedAt = Date()
        if let id = copy.id, let index = threads.firstIndex(where: { $0.id == id }) {
            threads[index] = copy
        } else {
            threads.append(copy)
        }
        threads = newestThreads(threads)
        flushThreads()
        return copy
    }

    @discardableResult
    func upsertOffer(_ offer: DispatchLoadOffer) -> DispatchLoadOffer {
        var copy = offer
        if copy.id == nil { copy.id = UUID() }
        if copy.createdAt == nil { copy.createdAt = Date() }
        copy.updatedAt = Date()
        if let id = copy.id, let index = offers.firstIndex(where: { $0.id == id }) {
            offers[index] = copy
        } else {
            offers.append(copy)
        }
        offers = newestOffers(offers)
        flushOffers()
        return copy
    }

    @discardableResult
    func appendMessage(_ message: DispatchMessage) -> DispatchMessage {
        var copy = message
        if copy.id == nil { copy.id = UUID() }
        if copy.createdAt == nil { copy.createdAt = Date() }
        messages.append(copy)
        messages = oldestMessages(messages)
        flushMessages()
        return copy
    }

    @discardableResult
    func upsertParticipant(_ participant: DispatchParticipant) -> DispatchParticipant {
        var copy = participant
        if copy.id == nil { copy.id = UUID() }
        if copy.createdAt == nil { copy.createdAt = Date() }
        copy.updatedAt = Date()
        if let id = copy.id, let index = participants.firstIndex(where: { $0.id == id }) {
            participants[index] = copy
        } else if let index = participants.firstIndex(where: {
            $0.companyId == copy.companyId &&
            $0.profileId == copy.profileId &&
            $0.threadId == copy.threadId &&
            $0.role == copy.role
        }) {
            copy.id = participants[index].id ?? copy.id
            copy.createdAt = participants[index].createdAt ?? copy.createdAt
            participants[index] = copy
        } else {
            participants.append(copy)
        }
        participants = newestParticipants(participants)
        flushParticipants()
        return copy
    }

    @discardableResult
    func upsertPayment(_ payment: DispatcherPaymentRecord) -> DispatcherPaymentRecord {
        var copy = payment
        if copy.id == nil { copy.id = UUID() }
        if copy.createdAt == nil { copy.createdAt = Date() }
        copy.updatedAt = Date()
        if let offerId = copy.loadOfferId,
           let existing = payments.firstIndex(where: { $0.loadOfferId == offerId }) {
            copy.id = payments[existing].id ?? copy.id
            copy.createdAt = payments[existing].createdAt ?? copy.createdAt
            payments[existing] = copy
        } else if let id = copy.id, let index = payments.firstIndex(where: { $0.id == id }) {
            payments[index] = copy
        } else {
            payments.append(copy)
        }
        payments = newestPayments(payments)
        flushPayments()
        return copy
    }

    func markThreadRead(_ threadId: UUID, role: DispatchParticipantRole) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        switch role {
        case .driver:
            threads[index].driverUnreadCount = 0
        case .dispatcher:
            threads[index].dispatcherUnreadCount = 0
        case .carrier, .admin:
            threads[index].carrierUnreadCount = 0
        }
        threads[index].updatedAt = Date()
        flushThreads()
    }

    func messages(for threadId: UUID) -> [DispatchMessage] {
        messages.filter { $0.threadId == threadId }
    }

#if DEBUG
    func deleteRecords(containing tag: String) {
        threads.removeAll { [$0.subject, $0.loadNumber, $0.dispatcherCompany].containsTag(tag) }
        messages.removeAll { [$0.body, $0.senderName].containsTag(tag) }
        participants.removeAll { [$0.displayName].containsTag(tag) }
        offers.removeAll { [$0.loadNumber, $0.dispatcherCompany, $0.notes].containsTag(tag) }
        payments.removeAll { [$0.loadNumber, $0.dispatcherCompany, $0.notes].containsTag(tag) }
        profiles.removeAll { [$0.displayName, $0.companyName, $0.contactInfo].containsTag(tag) }
        reviews.removeAll { [$0.comment].containsTag(tag) }
        serviceRequests.removeAll { [$0.carrierName, $0.serviceNotes].containsTag(tag) }
        agreements.removeAll { [$0.carrierName, $0.dispatcherCompany, $0.notes].containsTag(tag) }
        feeRecords.removeAll { [$0.loadNumber, $0.brokerName, $0.notes, $0.sourceType].containsTag(tag) }
        invoices.removeAll { [$0.invoiceNumber, $0.notes].containsTag(tag) }
        flushThreads()
        flushMessages()
        flushParticipants()
        flushOffers()
        flushPayments()
        flushProfiles()
        flushReviews()
        flushServiceRequests()
        flushAgreements()
        flushFeeRecords()
        flushInvoices()
    }
#endif

    @discardableResult
    func upsertProfile(_ profile: DispatcherProfile) -> DispatcherProfile {
        var copy = profile
        if copy.id == nil { copy.id = UUID() }
        if copy.createdAt == nil { copy.createdAt = Date() }
        copy.updatedAt = Date()
        if let id = copy.id, let index = profiles.firstIndex(where: { $0.id == id }) {
            profiles[index] = copy
        } else {
            profiles.append(copy)
        }
        profiles = newestProfiles(profiles)
        flushProfiles()
        return copy
    }

    @discardableResult
    func upsertReview(_ review: DispatcherReview) -> DispatcherReview {
        var copy = review
        if copy.id == nil { copy.id = UUID() }
        if copy.createdAt == nil { copy.createdAt = Date() }
        copy.updatedAt = Date()
        if let id = copy.id, let index = reviews.firstIndex(where: { $0.id == id }) {
            reviews[index] = copy
        } else {
            reviews.append(copy)
        }
        reviews = newestReviews(reviews)
        flushReviews()
        return copy
    }

    @discardableResult
    func upsertServiceRequest(_ request: DispatchServiceRequest) -> DispatchServiceRequest {
        var copy = request
        if copy.id == nil { copy.id = UUID() }
        if copy.createdAt == nil { copy.createdAt = Date() }
        copy.updatedAt = Date()
        if let id = copy.id, let index = serviceRequests.firstIndex(where: { $0.id == id }) {
            serviceRequests[index] = copy
        } else {
            serviceRequests.append(copy)
        }
        serviceRequests = newestRequests(serviceRequests)
        flushServiceRequests()
        return copy
    }

    @discardableResult
    func upsertAgreement(_ agreement: DispatchAgreement) -> DispatchAgreement {
        var copy = agreement
        if copy.id == nil { copy.id = UUID() }
        if copy.createdAt == nil { copy.createdAt = Date() }
        copy.updatedAt = Date()
        if let id = copy.id, let index = agreements.firstIndex(where: { $0.id == id }) {
            agreements[index] = copy
        } else {
            agreements.append(copy)
        }
        agreements = newestAgreements(agreements)
        flushAgreements()
        return copy
    }

    @discardableResult
    func upsertFeeRecord(_ record: DispatcherFeeRecord) -> DispatcherFeeRecord {
        var copy = record
        if copy.id == nil { copy.id = UUID() }
        if copy.createdAt == nil { copy.createdAt = Date() }
        copy.updatedAt = Date()
        if let id = copy.id, let index = feeRecords.firstIndex(where: { $0.id == id }) {
            feeRecords[index] = copy
        } else if let agreementId = copy.agreementId,
                  let loadNumber = copy.loadNumber,
                  let existing = feeRecords.firstIndex(where: {
                      $0.agreementId == agreementId && $0.loadNumber == loadNumber
                  }) {
            copy.id = feeRecords[existing].id ?? copy.id
            copy.createdAt = feeRecords[existing].createdAt ?? copy.createdAt
            feeRecords[existing] = copy
        } else {
            feeRecords.append(copy)
        }
        feeRecords = newestFeeRecords(feeRecords)
        flushFeeRecords()
        return copy
    }

    @discardableResult
    func upsertInvoice(_ invoice: DispatcherInvoice) -> DispatcherInvoice {
        var copy = invoice
        if copy.id == nil { copy.id = UUID() }
        if copy.createdAt == nil { copy.createdAt = Date() }
        copy.updatedAt = Date()
        if let id = copy.id, let index = invoices.firstIndex(where: { $0.id == id }) {
            invoices[index] = copy
        } else {
            invoices.append(copy)
        }
        invoices = newestInvoices(invoices)
        flushInvoices()
        return copy
    }

    private func flushThreads() {
        LocalStore.saveArray(threads, fileName: threadsFile)
    }

    private func flushMessages() {
        LocalStore.saveArray(messages, fileName: messagesFile)
    }

    private func flushParticipants() {
        LocalStore.saveArray(participants, fileName: participantsFile)
    }

    private func flushOffers() {
        LocalStore.saveArray(offers, fileName: offersFile)
    }

    private func flushPayments() {
        LocalStore.saveArray(payments, fileName: paymentsFile)
    }

    private func flushProfiles() {
        LocalStore.saveArray(profiles, fileName: profilesFile)
    }

    private func flushReviews() {
        LocalStore.saveArray(reviews, fileName: reviewsFile)
    }

    private func flushServiceRequests() {
        LocalStore.saveArray(serviceRequests, fileName: serviceRequestsFile)
    }

    private func flushAgreements() {
        LocalStore.saveArray(agreements, fileName: agreementsFile)
    }

    private func flushFeeRecords() {
        LocalStore.saveArray(feeRecords, fileName: feeRecordsFile)
    }

    private func flushInvoices() {
        LocalStore.saveArray(invoices, fileName: invoicesFile)
    }

    private func newestThreads(_ values: [DispatchThread]) -> [DispatchThread] {
        values.sorted {
            ($0.lastMessageAt ?? $0.updatedAt ?? $0.createdAt ?? .distantPast) >
            ($1.lastMessageAt ?? $1.updatedAt ?? $1.createdAt ?? .distantPast)
        }
    }

    private func oldestMessages(_ values: [DispatchMessage]) -> [DispatchMessage] {
        values.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    private func newestParticipants(_ values: [DispatchParticipant]) -> [DispatchParticipant] {
        values.sorted { ($0.updatedAt ?? $0.createdAt ?? .distantPast) > ($1.updatedAt ?? $1.createdAt ?? .distantPast) }
    }

    private func newestOffers(_ values: [DispatchLoadOffer]) -> [DispatchLoadOffer] {
        values.sorted { ($0.createdAt ?? $0.updatedAt ?? .distantPast) > ($1.createdAt ?? $1.updatedAt ?? .distantPast) }
    }

    private func newestPayments(_ values: [DispatcherPaymentRecord]) -> [DispatcherPaymentRecord] {
        values.sorted { ($0.createdAt ?? $0.updatedAt ?? .distantPast) > ($1.createdAt ?? $1.updatedAt ?? .distantPast) }
    }

    private func newestProfiles(_ values: [DispatcherProfile]) -> [DispatcherProfile] {
        values.sorted { ($0.updatedAt ?? $0.createdAt ?? .distantPast) > ($1.updatedAt ?? $1.createdAt ?? .distantPast) }
    }

    private func newestReviews(_ values: [DispatcherReview]) -> [DispatcherReview] {
        values.sorted { ($0.createdAt ?? $0.updatedAt ?? .distantPast) > ($1.createdAt ?? $1.updatedAt ?? .distantPast) }
    }

    private func newestRequests(_ values: [DispatchServiceRequest]) -> [DispatchServiceRequest] {
        values.sorted { ($0.createdAt ?? $0.updatedAt ?? .distantPast) > ($1.createdAt ?? $1.updatedAt ?? .distantPast) }
    }

    private func newestAgreements(_ values: [DispatchAgreement]) -> [DispatchAgreement] {
        values.sorted { ($0.effectiveDate ?? $0.createdAt ?? .distantPast) > ($1.effectiveDate ?? $1.createdAt ?? .distantPast) }
    }

    private func newestFeeRecords(_ values: [DispatcherFeeRecord]) -> [DispatcherFeeRecord] {
        values.sorted { ($0.createdAt ?? $0.updatedAt ?? .distantPast) > ($1.createdAt ?? $1.updatedAt ?? .distantPast) }
    }

    private func newestInvoices(_ values: [DispatcherInvoice]) -> [DispatcherInvoice] {
        values.sorted { ($0.periodStart ?? $0.createdAt ?? .distantPast) > ($1.periodStart ?? $1.createdAt ?? .distantPast) }
    }
}

#if DEBUG
private extension Array where Element == String? {
    func containsTag(_ tag: String) -> Bool {
        contains { $0?.contains(tag) == true }
    }
}
#endif
