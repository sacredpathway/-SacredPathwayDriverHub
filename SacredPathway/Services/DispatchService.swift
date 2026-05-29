import Foundation
import UserNotifications

@MainActor
final class DispatchService: ObservableObject {
    static let shared = DispatchService()

    @Published private(set) var threads: [DispatchThread] = []
    @Published private(set) var messages: [DispatchMessage] = []
    @Published private(set) var offers: [DispatchLoadOffer] = []
    @Published private(set) var payments: [DispatcherPaymentRecord] = []
    @Published private(set) var dispatcherProfiles: [DispatcherProfile] = []
    @Published private(set) var dispatcherReviews: [DispatcherReview] = []
    @Published private(set) var serviceRequests: [DispatchServiceRequest] = []
    @Published private(set) var agreements: [DispatchAgreement] = []
    @Published private(set) var feeRecords: [DispatcherFeeRecord] = []
    @Published private(set) var invoices: [DispatcherInvoice] = []
    @Published var activeRole: DispatchParticipantRole = .driver

    private let local = LocalDispatchRepository.shared

    private init() {}

    func reload(supabase: SupabaseService) async {
        if AppMode.shared.isLocal {
            local.reload()
            publishLocal()
            return
        }

        do {
            let fetchedThreads: [DispatchThread] = try await supabase.client.from("dispatch_threads")
                .select()
                .order("last_message_at", ascending: false)
                .execute()
                .value
            let fetchedMessages: [DispatchMessage] = try await supabase.client.from("dispatch_messages")
                .select()
                .order("created_at", ascending: true)
                .execute()
                .value
            let fetchedOffers: [DispatchLoadOffer] = try await supabase.client.from("dispatch_load_offers")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
            let fetchedPayments: [DispatcherPaymentRecord] = try await supabase.client.from("dispatcher_payment_records")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
            let fetchedProfiles: [DispatcherProfile] = try await supabase.client.from("dispatcher_profiles")
                .select()
                .order("updated_at", ascending: false)
                .execute()
                .value
            let fetchedReviews: [DispatcherReview] = try await supabase.client.from("dispatcher_reviews")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
            let fetchedRequests: [DispatchServiceRequest] = try await supabase.client.from("dispatch_service_requests")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
            let fetchedAgreements: [DispatchAgreement] = try await supabase.client.from("dispatch_agreements")
                .select()
                .order("effective_date", ascending: false)
                .execute()
                .value
            let fetchedFeeRecords: [DispatcherFeeRecord] = try await supabase.client.from("dispatcher_fee_records")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
            let fetchedInvoices: [DispatcherInvoice] = try await supabase.client.from("dispatcher_invoices")
                .select()
                .order("period_start", ascending: false)
                .execute()
                .value

            threads = fetchedThreads
            messages = fetchedMessages
            offers = fetchedOffers
            payments = fetchedPayments
            dispatcherProfiles = fetchedProfiles
            dispatcherReviews = fetchedReviews
            serviceRequests = fetchedRequests
            agreements = fetchedAgreements
            feeRecords = fetchedFeeRecords
            invoices = fetchedInvoices
        } catch {
            #if DEBUG
            print("[SacredDispatch] reload failed: \(error)")
            #endif
        }
    }

    @discardableResult
    func createOffer(_ draft: DispatchLoadOffer, supabase: SupabaseService) async throws -> DispatchLoadOffer {
        let userId = try currentProfileId(supabase: supabase)
        let now = Date()
        let offerId = draft.id ?? UUID()
        let threadId = draft.threadId ?? UUID()
        let dispatcherName = clean(draft.dispatcherName) ?? supabase.currentProfile?.companyName ?? "Dispatcher"
        let dispatcherCompany = clean(draft.dispatcherCompany) ?? supabase.currentProfile?.companyName

        var offer = draft
        offer.id = offerId
        offer.threadId = threadId
        offer.dispatcherUserId = offer.dispatcherUserId ?? userId
        offer.driverProfileId = offer.driverProfileId ?? userId
        offer.dispatcherName = dispatcherName
        offer.dispatcherCompany = dispatcherCompany
        offer.loadGrossAmount = offer.grossAmountForCalculations
        offer.status = .pending
        offer.createdAt = offer.createdAt ?? now
        offer.updatedAt = now

        let subject = "Load \(offer.loadNumber?.isEmpty == false ? "#\(offer.loadNumber!)" : "Offer")"
        var thread = DispatchThread(
            id: threadId,
            companyId: offer.companyId,
            loadOfferId: offerId,
            acceptedLoadId: nil,
            loadNumber: offer.loadNumber,
            driverProfileId: offer.driverProfileId,
            dispatcherUserId: offer.dispatcherUserId,
            dispatcherName: dispatcherName,
            dispatcherCompany: dispatcherCompany,
            subject: subject,
            lastMessagePreview: "Load offer sent",
            driverUnreadCount: activeRole == .driver ? 0 : 1,
            dispatcherUnreadCount: activeRole == .dispatcher ? 0 : 1,
            carrierUnreadCount: activeRole == .carrier || activeRole == .admin ? 0 : 1,
            lastMessageAt: now,
            createdAt: now,
            updatedAt: now
        )

        let message = DispatchMessage(
            id: UUID(),
            companyId: offer.companyId,
            threadId: threadId,
            loadOfferId: offerId,
            senderProfileId: userId,
            senderRole: activeRole,
            senderName: senderName(supabase: supabase),
            body: "Load offer sent: \(offer.loadNumber.map { "#\($0)" } ?? "new load")",
            kind: .loadOffer,
            readAt: nil,
            createdAt: now
        )

        if AppMode.shared.isLocal {
            offer = local.upsertOffer(offer)
            thread = local.upsertThread(thread)
            _ = local.appendMessage(message)
            publishLocal()
        } else {
            offer = try await supabase.client.from("dispatch_load_offers")
                .insert(offer, returning: .representation)
                .select()
                .single()
                .execute()
                .value
            thread = try await supabase.client.from("dispatch_threads")
                .insert(thread, returning: .representation)
                .select()
                .single()
                .execute()
                .value
            let _: DispatchMessage = try await supabase.client.from("dispatch_messages")
                .insert(message, returning: .representation)
                .select()
                .single()
                .execute()
                .value
            await reload(supabase: supabase)
        }

        scheduleNotification(
            title: "New dispatch load offer",
            body: "\(dispatcherName) sent \(offer.loadNumber.map { "load #\($0)" } ?? "a load offer")."
        )
        return offer
    }

    func acceptOffer(_ offer: DispatchLoadOffer, supabase: SupabaseService) async throws {
        guard offer.status == .pending else { return }
        let userId = try currentProfileId(supabase: supabase)
        let now = Date()

        let load = Load(
            id: UUID(),
            profileId: userId,
            driverId: offer.driverId,
            loadNumber: offer.loadNumber,
            brokerName: offer.brokerName,
            brokerMcNumber: offer.brokerMcNumber,
            pickupDate: offer.pickupDate,
            deliveryDate: offer.deliveryDate,
            origin: offer.origin,
            destination: offer.destination,
            totalMiles: offer.totalMiles,
            lineHaulRate: offer.lineHaulRate,
            fuelSurcharge: offer.fuelSurcharge,
            accessorialCharges: offer.accessorialCharges,
            totalRevenue: offer.grossAmountForCalculations,
            dispatchThreadId: offer.threadId,
            dispatchLoadOfferId: offer.id,
            dispatcherName: offer.dispatcherName,
            dispatcherCompany: offer.dispatcherCompany,
            status: LoadStatus.assigned.rawValue,
            createdAt: now,
            updatedAt: now
        )

        let savedLoad: Load
        if AppMode.shared.isLocal {
            savedLoad = LocalLoadsRepository.shared.create(load)
            NotificationCenter.default.post(name: .loadsDidChange, object: savedLoad)
        } else {
            savedLoad = try await supabase.createLoad(load)
        }

        var updatedOffer = offer
        updatedOffer.status = .accepted
        updatedOffer.acceptedLoadId = savedLoad.id
        updatedOffer.acceptedAt = now
        updatedOffer.updatedAt = now

        var payment = DispatcherPaymentRecord(
            id: UUID(),
            companyId: offer.companyId,
            dispatcherProfileId: offer.dispatcherProfileId,
            dispatcherUserId: offer.dispatcherUserId,
            driverProfileId: offer.driverProfileId ?? userId,
            loadId: savedLoad.id,
            loadOfferId: offer.id,
            threadId: offer.threadId,
            dispatcherName: offer.dispatcherName,
            dispatcherCompany: offer.dispatcherCompany,
            loadNumber: offer.loadNumber,
            loadGrossAmount: offer.grossAmountForCalculations,
            feeType: offer.feeType,
            feeAmount: offer.feeAmount,
            feePercentage: offer.feePercentage,
            calculatedDispatchFee: offer.calculatedDispatchFee,
            invoiceCadence: offer.invoiceCadence,
            paymentStatus: .unpaid,
            dueDate: offer.dueDate ?? invoiceDueDate(for: offer.invoiceCadence, baseDate: now),
            notes: offer.notes,
            createdAt: now,
            updatedAt: now,
            paidAt: nil
        )

        if AppMode.shared.isLocal {
            updatedOffer = local.upsertOffer(updatedOffer)
            payment = local.upsertPayment(payment)
            if var thread = thread(for: offer.threadId) {
                thread.acceptedLoadId = savedLoad.id
                thread.lastMessagePreview = "Load accepted"
                thread.lastMessageAt = now
                thread.updatedAt = now
                _ = local.upsertThread(thread)
            }
            _ = local.appendMessage(statusMessage(
                companyId: offer.companyId,
                threadId: offer.threadId,
                offerId: offer.id,
                senderId: userId,
                body: "Load accepted",
                supabase: supabase,
                createdAt: now
            ))
            publishLocal()
        } else {
            guard let offerId = offer.id else { throw DispatchServiceError.missingOfferId }
            try await supabase.client.from("dispatch_load_offers")
                .update(updatedOffer)
                .eq("id", value: offerId)
                .execute()
            if var thread = thread(for: offer.threadId), let threadId = thread.id {
                thread.acceptedLoadId = savedLoad.id
                thread.lastMessagePreview = "Load accepted"
                thread.lastMessageAt = now
                thread.updatedAt = now
                try await supabase.client.from("dispatch_threads")
                    .update(thread)
                    .eq("id", value: threadId)
                    .execute()
            }
            payment = try await upsertCloudPayment(payment, supabase: supabase)
            let _: DispatchMessage = try await supabase.client.from("dispatch_messages")
                .insert(statusMessage(
                    companyId: offer.companyId,
                    threadId: offer.threadId,
                    offerId: offer.id,
                    senderId: userId,
                    body: "Load accepted",
                    supabase: supabase,
                    createdAt: now
                ), returning: .representation)
                .select()
                .single()
                .execute()
                .value
            await reload(supabase: supabase)
        }

        #if DEBUG
        print("[SacredDispatch] accepted offer=\(offer.id?.uuidString ?? "<nil>") load=\(savedLoad.id?.uuidString ?? "<nil>") payment=\(payment.id?.uuidString ?? "<nil>") fee=\(payment.calculatedDispatchFee)")
        #endif

        scheduleNotification(
            title: "Dispatch load accepted",
            body: "Load \(offer.loadNumber.map { "#\($0)" } ?? "") was added to the load list."
        )
    }

    func declineOffer(_ offer: DispatchLoadOffer, supabase: SupabaseService) async throws {
        guard offer.status == .pending else { return }
        let userId = try currentProfileId(supabase: supabase)
        let now = Date()
        var updated = offer
        updated.status = .declined
        updated.declinedAt = now
        updated.updatedAt = now

        if AppMode.shared.isLocal {
            _ = local.upsertOffer(updated)
            _ = local.appendMessage(statusMessage(
                companyId: offer.companyId,
                threadId: offer.threadId,
                offerId: offer.id,
                senderId: userId,
                body: "Load declined",
                supabase: supabase,
                createdAt: now
            ))
            publishLocal()
        } else {
            guard let offerId = offer.id else { throw DispatchServiceError.missingOfferId }
            try await supabase.client.from("dispatch_load_offers")
                .update(updated)
                .eq("id", value: offerId)
                .execute()
            let _: DispatchMessage = try await supabase.client.from("dispatch_messages")
                .insert(statusMessage(
                    companyId: offer.companyId,
                    threadId: offer.threadId,
                    offerId: offer.id,
                    senderId: userId,
                    body: "Load declined",
                    supabase: supabase,
                    createdAt: now
                ), returning: .representation)
                .select()
                .single()
                .execute()
                .value
            await reload(supabase: supabase)
        }
    }

    func filteredDispatcherProfiles(
        searchText: String = "",
        equipment: DispatchEquipmentType? = nil,
        region: String = ""
    ) -> [DispatcherProfile] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let regionFilter = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return dispatcherProfiles.filter { profile in
            guard profile.isActive ?? true else { return false }
            if let equipment,
               !(profile.equipmentTypes ?? []).contains(equipment.rawValue) {
                return false
            }
            if !regionFilter.isEmpty {
                let regions = (profile.serviceRegions ?? []).map { $0.lowercased() }
                guard regions.contains(where: { $0.contains(regionFilter) }) else { return false }
            }
            guard !search.isEmpty else { return true }
            let haystack = [
                profile.companyName,
                profile.displayName,
                profile.email,
                profile.phone,
                profile.contactInfo
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
            return haystack.contains(search)
        }
    }

    @discardableResult
    func saveDispatcherProfile(_ profile: DispatcherProfile, supabase: SupabaseService) async throws -> DispatcherProfile {
        let userId = try currentProfileId(supabase: supabase)
        let companyId = try currentCompanyId(supabase: supabase)
        var copy = profile
        copy.id = copy.id ?? UUID()
        copy.companyId = copy.companyId ?? companyId
        copy.userId = copy.userId ?? userId
        copy.isActive = copy.isActive ?? true
        copy.createdAt = copy.createdAt ?? Date()
        copy.updatedAt = Date()

        if AppMode.shared.isLocal {
            let saved = local.upsertProfile(copy)
            publishLocal()
            return saved
        }

        if let id = profile.id {
            try await supabase.client.from("dispatcher_profiles")
                .update(copy)
                .eq("id", value: id)
                .execute()
            await reload(supabase: supabase)
            return copy
        }

        let saved: DispatcherProfile = try await supabase.client.from("dispatcher_profiles")
            .insert(copy, returning: .representation)
            .select()
            .single()
            .execute()
            .value
        await reload(supabase: supabase)
        return saved
    }

    @discardableResult
    func requestDispatchService(dispatcher: DispatcherProfile, notes: String, supabase: SupabaseService) async throws -> DispatchServiceRequest {
        let profileId = try currentProfileId(supabase: supabase)
        let companyId = try currentCompanyId(supabase: supabase)
        let now = Date()
        var request = DispatchServiceRequest(
            id: UUID(),
            companyId: companyId,
            requestedByProfileId: profileId,
            dispatcherProfileId: dispatcher.id,
            dispatcherUserId: dispatcher.userId,
            carrierName: supabase.currentProfile?.companyName ?? "Carrier",
            serviceNotes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            status: .pending,
            createdAt: now,
            updatedAt: now
        )

        if AppMode.shared.isLocal {
            request = local.upsertServiceRequest(request)
            publishLocal()
        } else {
            request = try await supabase.client.from("dispatch_service_requests")
                .insert(request, returning: .representation)
                .select()
                .single()
                .execute()
                .value
            await reload(supabase: supabase)
        }

        scheduleNotification(
            title: "Dispatch service requested",
            body: "\(request.carrierName ?? "A carrier") requested dispatch service."
        )
        return request
    }

    @discardableResult
    func createAgreement(
        from request: DispatchServiceRequest,
        feeType: DispatchFeeType,
        feePercentage: Double?,
        feeAmount: Double?,
        notes: String,
        supabase: SupabaseService
    ) async throws -> DispatchAgreement {
        let companyId = try currentCompanyId(supabase: supabase)
        let carrierId = request.requestedByProfileId
        guard let dispatcherProfileId = request.dispatcherProfileId else {
            throw DispatchServiceError.missingDispatcherProfile
        }
        let dispatcher = dispatcherProfiles.first { $0.id == dispatcherProfileId }
        let now = Date()
        var agreement = DispatchAgreement(
            id: UUID(),
            companyId: companyId,
            carrierProfileId: carrierId,
            dispatcherProfileId: dispatcherProfileId,
            dispatcherUserId: request.dispatcherUserId ?? dispatcher?.userId,
            carrierName: request.carrierName,
            dispatcherName: dispatcher?.displayName,
            dispatcherCompany: dispatcher?.companyName,
            effectiveDate: now,
            feeType: feeType,
            feePercentage: feePercentage,
            feeAmount: feeAmount,
            status: .active,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            updatedAt: now
        )
        var updatedRequest = request
        updatedRequest.status = .accepted
        updatedRequest.updatedAt = now

        if AppMode.shared.isLocal {
            _ = local.upsertServiceRequest(updatedRequest)
            agreement = local.upsertAgreement(agreement)
            publishLocal()
        } else {
            if let requestId = request.id {
                try await supabase.client.from("dispatch_service_requests")
                    .update(updatedRequest)
                    .eq("id", value: requestId)
                    .execute()
            }
            agreement = try await supabase.client.from("dispatch_agreements")
                .insert(agreement, returning: .representation)
                .select()
                .single()
                .execute()
                .value
            await reload(supabase: supabase)
        }

        scheduleNotification(
            title: "Dispatch agreement active",
            body: "\(agreement.dispatcherCompany ?? agreement.dispatcherName ?? "Dispatcher") agreement is ready for fee tracking."
        )
        return agreement
    }

    @discardableResult
    func recordSettlement(
        agreement: DispatchAgreement,
        loadNumber: String?,
        brokerName: String?,
        grossRevenue: Double,
        paymentAmount: Double?,
        sourceType: String,
        ocrConfidence: Double?,
        notes: String,
        supabase: SupabaseService
    ) async throws -> DispatcherFeeRecord {
        let now = Date()
        let fee = agreement.fee(for: grossRevenue)
        var record = DispatcherFeeRecord(
            id: UUID(),
            companyId: agreement.companyId,
            agreementId: agreement.id,
            dispatcherProfileId: agreement.dispatcherProfileId,
            dispatcherUserId: agreement.dispatcherUserId,
            carrierProfileId: agreement.carrierProfileId,
            loadId: nil,
            settlementDocumentId: nil,
            invoiceId: nil,
            loadNumber: clean(loadNumber),
            brokerName: clean(brokerName),
            grossRevenue: max(0, grossRevenue),
            paymentAmount: paymentAmount,
            feeType: agreement.feeType,
            feePercentage: agreement.feePercentage,
            feeAmount: agreement.feeAmount,
            calculatedDispatchFee: fee,
            paymentStatus: dueStatus(for: nil),
            dueDate: invoiceDueDate(for: invoiceCadence(for: agreement), baseDate: now),
            paymentDate: nil,
            notes: clean(notes),
            sourceType: sourceType,
            ocrConfidence: ocrConfidence,
            createdAt: now,
            updatedAt: now
        )

        if AppMode.shared.isLocal {
            record = local.upsertFeeRecord(record)
            let invoice = local.upsertInvoice(invoice(for: agreement, including: record))
            record.invoiceId = invoice.id
            record = local.upsertFeeRecord(record)
            publishLocal()
        } else {
            record = try await supabase.client.from("dispatcher_fee_records")
                .insert(record, returning: .representation)
                .select()
                .single()
                .execute()
                .value
            let invoice = try await upsertCloudInvoice(for: agreement, including: record, supabase: supabase)
            record.invoiceId = invoice.id
            if let recordId = record.id {
                try await supabase.client.from("dispatcher_fee_records")
                    .update(record)
                    .eq("id", value: recordId)
                    .execute()
            }
            await reload(supabase: supabase)
        }

        #if DEBUG
        print("[SacredDispatch] settlement fee record load=\(record.loadNumber ?? "<nil>") gross=\(record.grossRevenue) fee=\(record.calculatedDispatchFee) source=\(sourceType) confidence=\(ocrConfidence ?? -1)")
        #endif
        return record
    }

    @discardableResult
    func recordSettlementExtraction(
        fields: ParsedLoadFields,
        agreement: DispatchAgreement,
        supabase: SupabaseService
    ) async throws -> DispatcherFeeRecord {
        let gross = fields.rate ?? 0
        return try await recordSettlement(
            agreement: agreement,
            loadNumber: fields.loadNumber,
            brokerName: fields.brokerName,
            grossRevenue: gross,
            paymentAmount: gross,
            sourceType: fields.documentType.rawValue,
            ocrConfidence: fields.confidence["rate"],
            notes: fields.notes ?? "Created from settlement OCR extraction",
            supabase: supabase
        )
    }

    func updateFeeRecordPaymentStatus(_ record: DispatcherFeeRecord, status: DispatchPaymentStatus, supabase: SupabaseService) async throws {
        var updated = record
        updated.paymentStatus = status
        updated.paymentDate = status == .paid ? Date() : updated.paymentDate
        updated.updatedAt = Date()

        if AppMode.shared.isLocal {
            _ = local.upsertFeeRecord(updated)
            publishLocal()
        } else {
            guard let id = record.id else { throw DispatchServiceError.missingFeeRecordId }
            try await supabase.client.from("dispatcher_fee_records")
                .update(updated)
                .eq("id", value: id)
                .execute()
            await reload(supabase: supabase)
        }
    }

    func updateInvoicePaymentStatus(_ invoice: DispatcherInvoice, status: DispatchPaymentStatus, supabase: SupabaseService) async throws {
        var updated = invoice
        updated.paymentStatus = status
        updated.paymentDate = status == .paid ? Date() : updated.paymentDate
        updated.updatedAt = Date()

        if AppMode.shared.isLocal {
            _ = local.upsertInvoice(updated)
            publishLocal()
        } else {
            guard let id = invoice.id else { throw DispatchServiceError.missingInvoiceId }
            try await supabase.client.from("dispatcher_invoices")
                .update(updated)
                .eq("id", value: id)
                .execute()
            await reload(supabase: supabase)
        }
    }

    func sendMessage(thread: DispatchThread, body: String, supabase: SupabaseService) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let threadId = thread.id else { return }
        let userId = try currentProfileId(supabase: supabase)
        let now = Date()

        let message = DispatchMessage(
            id: UUID(),
            companyId: thread.companyId,
            threadId: threadId,
            loadOfferId: thread.loadOfferId,
            senderProfileId: userId,
            senderRole: activeRole,
            senderName: senderName(supabase: supabase),
            body: trimmed,
            kind: .text,
            readAt: nil,
            createdAt: now
        )
        var updatedThread = thread
        updatedThread.lastMessagePreview = trimmed
        updatedThread.lastMessageAt = now
        updatedThread.updatedAt = now
        incrementUnreadCounts(on: &updatedThread, senderRole: activeRole)

        if AppMode.shared.isLocal {
            _ = local.appendMessage(message)
            _ = local.upsertThread(updatedThread)
            publishLocal()
        } else {
            let _: DispatchMessage = try await supabase.client.from("dispatch_messages")
                .insert(message, returning: .representation)
                .select()
                .single()
                .execute()
                .value
            try await supabase.client.from("dispatch_threads")
                .update(updatedThread)
                .eq("id", value: threadId)
                .execute()
            await reload(supabase: supabase)
        }

        scheduleNotification(title: "New dispatch message", body: trimmed)
    }

    func markThreadRead(_ thread: DispatchThread, supabase: SupabaseService) async {
        guard let id = thread.id else { return }
        var updated = thread
        switch activeRole {
        case .driver: updated.driverUnreadCount = 0
        case .dispatcher: updated.dispatcherUnreadCount = 0
        case .carrier, .admin: updated.carrierUnreadCount = 0
        }
        updated.updatedAt = Date()

        if AppMode.shared.isLocal {
            local.markThreadRead(id, role: activeRole)
            publishLocal()
        } else {
            do {
                try await supabase.client.from("dispatch_threads")
                    .update(updated)
                    .eq("id", value: id)
                    .execute()
                await reload(supabase: supabase)
            } catch {
                #if DEBUG
                print("[SacredDispatch] markThreadRead failed: \(error)")
                #endif
            }
        }
    }

    func updatePaymentStatus(_ payment: DispatcherPaymentRecord, status: DispatchPaymentStatus, supabase: SupabaseService) async throws {
        var updated = payment
        updated.paymentStatus = status
        updated.paidAt = status == .paid ? Date() : nil
        updated.updatedAt = Date()

        if AppMode.shared.isLocal {
            _ = local.upsertPayment(updated)
            publishLocal()
        } else {
            guard let paymentId = payment.id else { throw DispatchServiceError.missingPaymentId }
            try await supabase.client.from("dispatcher_payment_records")
                .update(updated)
                .eq("id", value: paymentId)
                .execute()
            await reload(supabase: supabase)
        }
    }

    func messages(for thread: DispatchThread) -> [DispatchMessage] {
        guard let threadId = thread.id else { return [] }
        return messages.filter { $0.threadId == threadId }
    }

    func unreadCount(for role: DispatchParticipantRole? = nil) -> Int {
        let target = role ?? activeRole
        return threads.reduce(0) { $0 + $1.unreadCount(for: target) }
    }

    func acceptedDispatchLoads() -> [Load] {
        let acceptedIds = Set(offers.compactMap { $0.acceptedLoadId })
        return LocalLoadsRepository.shared.loads.filter { load in
            guard let id = load.id else { return false }
            return acceptedIds.contains(id) || load.dispatchLoadOfferId != nil
        }
    }

    func invoiceSummaries(for cadence: DispatchInvoiceCadence) -> [DispatchInvoiceSummary] {
        let records = payments.filter { $0.invoiceCadence == cadence }
        let grouped = Dictionary(grouping: records) { payment in
            invoicePeriod(for: payment.dueDate ?? payment.createdAt ?? Date(), cadence: cadence).start
        }
        return grouped.map { start, records in
            let interval = invoicePeriod(for: start, cadence: cadence)
            return DispatchInvoiceSummary(
                id: "\(cadence.rawValue)-\(Int(start.timeIntervalSince1970))",
                cadence: cadence,
                periodStart: interval.start,
                periodEnd: interval.end,
                records: records.sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }
            )
        }
        .sorted { $0.periodStart > $1.periodStart }
    }

    func activeAgreements() -> [DispatchAgreement] {
        agreements.filter { $0.status == .active }
    }

    func networkSummary(referenceDate: Date = Date()) -> DispatchNetworkDashboardSummary {
        let active = activeAgreements()
        let activeAgreementIds = Set(active.compactMap(\.id))
        let activeRecords = feeRecords.filter { record in
            guard let agreementId = record.agreementId else { return false }
            return activeAgreementIds.contains(agreementId)
        }
        let month = Calendar.current.dateInterval(of: .month, for: referenceDate)
        let monthlyPaid = activeRecords.filter { record in
            guard record.paymentStatus == .paid else { return false }
            guard let paidAt = record.paymentDate ?? record.updatedAt else { return false }
            return month?.contains(paidAt) ?? false
        }
        let owedRecords = activeRecords.filter { $0.paymentStatus != .paid }
        let overdueRecords = activeRecords.filter { dueStatus(for: $0.dueDate) == .overdue && $0.paymentStatus != .paid }
        let activeLoads = Set(activeRecords.compactMap { $0.loadNumber?.trimmingCharacters(in: .whitespacesAndNewlines) })

        return DispatchNetworkDashboardSummary(
            activeCarriers: Set(active.map(\.carrierProfileId)).count,
            activeLoads: activeLoads.count,
            grossRevenueManaged: activeRecords.reduce(0) { $0 + $1.grossRevenue },
            feesOwed: owedRecords.reduce(0) { $0 + $1.calculatedDispatchFee },
            feesPaid: activeRecords.filter { $0.paymentStatus == .paid }.reduce(0) { $0 + $1.calculatedDispatchFee },
            overduePayments: overdueRecords.reduce(0) { $0 + $1.calculatedDispatchFee },
            monthlyEarnings: monthlyPaid.reduce(0) { $0 + $1.calculatedDispatchFee },
            invoiceCount: invoices.count,
            activeAgreementCount: active.count
        )
    }

    private func publishLocal() {
        threads = local.fetchThreads()
        messages = local.fetchMessages()
        offers = local.fetchOffers()
        payments = local.fetchPayments()
        dispatcherProfiles = local.fetchProfiles()
        dispatcherReviews = local.fetchReviews()
        serviceRequests = local.fetchServiceRequests()
        agreements = local.fetchAgreements()
        feeRecords = local.fetchFeeRecords()
        invoices = local.fetchInvoices()
    }

    private func upsertCloudPayment(_ payment: DispatcherPaymentRecord, supabase: SupabaseService) async throws -> DispatcherPaymentRecord {
        if let offerId = payment.loadOfferId,
           let existing = payments.first(where: { $0.loadOfferId == offerId }),
           let existingId = existing.id {
            var updated = payment
            updated.id = existingId
            updated.createdAt = existing.createdAt ?? payment.createdAt
            try await supabase.client.from("dispatcher_payment_records")
                .update(updated)
                .eq("id", value: existingId)
                .execute()
            return updated
        }

        return try await supabase.client.from("dispatcher_payment_records")
            .insert(payment, returning: .representation)
            .select()
            .single()
            .execute()
            .value
    }

    private func upsertCloudInvoice(
        for agreement: DispatchAgreement,
        including record: DispatcherFeeRecord,
        supabase: SupabaseService
    ) async throws -> DispatcherInvoice {
        let invoice = invoice(for: agreement, including: record)
        if let existingId = invoice.id {
            try await supabase.client.from("dispatcher_invoices")
                .update(invoice)
                .eq("id", value: existingId)
                .execute()
            return invoice
        }

        return try await supabase.client.from("dispatcher_invoices")
            .insert(invoice, returning: .representation)
            .select()
            .single()
            .execute()
            .value
    }

    private func invoice(for agreement: DispatchAgreement, including record: DispatcherFeeRecord) -> DispatcherInvoice {
        let cadence = invoiceCadence(for: agreement)
        let period = invoicePeriod(for: record.createdAt ?? Date(), cadence: cadence)
        let agreementId = agreement.id
        let existing = invoices.first {
            $0.agreementId == agreementId &&
            Calendar.current.isDate($0.periodStart ?? .distantPast, inSameDayAs: period.start)
        }
        var periodRecords = feeRecords.filter { candidate in
            candidate.agreementId == agreementId &&
            period.contains(candidate.createdAt ?? Date())
        }
        if !periodRecords.contains(where: { $0.id == record.id }) {
            periodRecords.append(record)
        }
        let totalGross = periodRecords.reduce(0) { $0 + $1.grossRevenue }
        let totalFees = periodRecords.reduce(0) { $0 + $1.calculatedDispatchFee }
        let now = Date()

        return DispatcherInvoice(
            id: existing?.id ?? UUID(),
            companyId: agreement.companyId,
            agreementId: agreement.id,
            dispatcherProfileId: agreement.dispatcherProfileId,
            dispatcherUserId: agreement.dispatcherUserId,
            carrierProfileId: agreement.carrierProfileId,
            invoiceNumber: existing?.invoiceNumber ?? invoiceNumber(for: period.start),
            periodStart: period.start,
            periodEnd: period.end,
            totalGrossRevenue: totalGross,
            totalFeesDue: totalFees,
            paymentStatus: existing?.paymentStatus ?? dueStatus(for: invoiceDueDate(for: cadence, baseDate: period.end)),
            dueDate: existing?.dueDate ?? invoiceDueDate(for: cadence, baseDate: period.end),
            paymentDate: existing?.paymentDate,
            notes: existing?.notes,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
    }

    private func invoiceCadence(for agreement: DispatchAgreement) -> DispatchInvoiceCadence {
        switch agreement.feeType {
        case .monthlyFixed:
            return .monthly
        default:
            return .weekly
        }
    }

    private func dueStatus(for dueDate: Date?) -> DispatchPaymentStatus {
        guard let dueDate else { return .unpaid }
        return dueDate < Calendar.current.startOfDay(for: Date()) ? .overdue : .unpaid
    }

    private func invoiceNumber(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return "SD-\(formatter.string(from: date))-\(Int.random(in: 100...999))"
    }

    private func currentProfileId(supabase: SupabaseService) throws -> UUID {
        if AppMode.shared.isLocal { return AppMode.shared.localInstallId }
        if let id = supabase.currentProfile?.id { return id }
        if let id = supabase.client.auth.currentUser?.id { return id }
        throw DispatchServiceError.missingAuthenticatedUser
    }

    private func currentCompanyId(supabase: SupabaseService) throws -> UUID {
        if AppMode.shared.isLocal { return AppMode.shared.localInstallId }
        if let id = supabase.currentProfile?.id { return id }
        if let id = supabase.client.auth.currentUser?.id { return id }
        throw DispatchServiceError.missingAuthenticatedUser
    }

    private func senderName(supabase: SupabaseService) -> String {
        switch activeRole {
        case .driver:
            return "Driver"
        case .dispatcher:
            return supabase.currentProfile?.companyName ?? "Dispatcher"
        case .carrier:
            return supabase.currentProfile?.companyName ?? "Carrier"
        case .admin:
            return "Admin"
        }
    }

    private func thread(for threadId: UUID?) -> DispatchThread? {
        guard let threadId else { return nil }
        return threads.first { $0.id == threadId } ?? local.fetchThreads().first { $0.id == threadId }
    }

    private func statusMessage(
        companyId: UUID,
        threadId: UUID?,
        offerId: UUID?,
        senderId: UUID,
        body: String,
        supabase: SupabaseService,
        createdAt: Date
    ) -> DispatchMessage {
        DispatchMessage(
            id: UUID(),
            companyId: companyId,
            threadId: threadId ?? UUID(),
            loadOfferId: offerId,
            senderProfileId: senderId,
            senderRole: activeRole,
            senderName: senderName(supabase: supabase),
            body: body,
            kind: .status,
            readAt: nil,
            createdAt: createdAt
        )
    }

    private func incrementUnreadCounts(on thread: inout DispatchThread, senderRole: DispatchParticipantRole) {
        switch senderRole {
        case .driver:
            thread.dispatcherUnreadCount += 1
            thread.carrierUnreadCount += 1
        case .dispatcher:
            thread.driverUnreadCount += 1
            thread.carrierUnreadCount += 1
        case .carrier, .admin:
            thread.driverUnreadCount += 1
            thread.dispatcherUnreadCount += 1
        }
    }

    private func invoiceDueDate(for cadence: DispatchInvoiceCadence, baseDate: Date) -> Date {
        switch cadence {
        case .weekly:
            return PayWeekService.shared.weekInterval(for: baseDate).end
        case .monthly:
            return Calendar.current.dateInterval(of: .month, for: baseDate)?.end ?? baseDate
        }
    }

    private func invoicePeriod(for date: Date, cadence: DispatchInvoiceCadence) -> DateInterval {
        switch cadence {
        case .weekly:
            return PayWeekService.shared.weekInterval(for: date)
        case .monthly:
            return Calendar.current.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 30 * 24 * 60 * 60)
        }
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func scheduleNotification(title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            let updated = await center.notificationSettings()
            guard updated.authorizationStatus == .authorized || updated.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "sacred-dispatch-\(UUID().uuidString)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            try? await center.add(request)
        }
    }
}

enum DispatchServiceError: LocalizedError {
    case missingAuthenticatedUser
    case missingOfferId
    case missingPaymentId
    case missingDispatcherProfile
    case missingFeeRecordId
    case missingInvoiceId

    var errorDescription: String? {
        switch self {
        case .missingAuthenticatedUser:
            return "Sign in or switch to Free Local Mode before using Sacred DISPATCH."
        case .missingOfferId:
            return "The dispatch offer is missing its saved ID. Refresh Sacred DISPATCH and try again."
        case .missingPaymentId:
            return "The dispatcher payment record is missing its saved ID. Refresh Sacred DISPATCH and try again."
        case .missingDispatcherProfile:
            return "Select a dispatcher profile before creating the dispatch agreement."
        case .missingFeeRecordId:
            return "The dispatcher fee record is missing its saved ID. Refresh Sacred DISPATCH and try again."
        case .missingInvoiceId:
            return "The dispatcher invoice is missing its saved ID. Refresh Sacred DISPATCH and try again."
        }
    }
}
