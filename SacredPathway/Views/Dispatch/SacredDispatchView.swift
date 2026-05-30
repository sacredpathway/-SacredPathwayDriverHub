import SwiftUI

struct SacredDispatchDashboardView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared
    @ObservedObject private var appMode = AppMode.shared

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                if appMode.isLocal {
                    LocalModeBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                DispatchErrorBanner(message: dispatch.lastErrorMessage)

                Section {
                    let network = dispatch.networkSummary()
                    HStack(spacing: 10) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(Color.spGold)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dispatcher Mode")
                                .font(.headline)
                                .foregroundStyle(Color.spTextPrimary)
                            Text("Manage drivers, communication, loads, and dispatcher expenses.")
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                    }

                    HStack(spacing: 10) {
                        DispatchSummaryTile(title: "Active Drivers", value: "\(activeDriverCount)", systemImage: "person.3.fill")
                        DispatchSummaryTile(title: "Loads", value: "\(loadsBeingHandled)", systemImage: "shippingbox.fill")
                    }
                    HStack(spacing: 10) {
                        DispatchSummaryTile(title: "Unread", value: "\(dispatch.unreadCount())", systemImage: "message.badge.fill")
                        DispatchSummaryTile(title: "Monthly Revenue", value: network.monthlyEarnings.asCurrency, systemImage: "chart.line.uptrend.xyaxis")
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Drivers") {
                    NavigationLink {
                        DispatcherDriverContactsView()
                            .environmentObject(supabase)
                    } label: {
                        DispatchMenuRow(
                            title: "Driver Contact Book",
                            subtitle: "Assigned and connected drivers",
                            systemImage: "person.3.fill",
                            badge: activeDriverCount == 0 ? nil : "\(activeDriverCount)"
                        )
                    }

                    NavigationLink {
                        DispatchChatThreadsView()
                            .environmentObject(supabase)
                    } label: {
                        DispatchMenuRow(
                            title: "Driver Communication",
                            subtitle: "Role-scoped dispatch messages",
                            systemImage: "message.fill",
                            badge: dispatch.unreadCount() == 0 ? nil : "\(dispatch.unreadCount())"
                        )
                    }

                    NavigationLink {
                        DispatchLoadOffersView()
                            .environmentObject(supabase)
                    } label: {
                        DispatchMenuRow(
                            title: "Load Offers",
                            subtitle: "Send offers to connected drivers/carriers",
                            systemImage: "doc.text.magnifyingglass",
                            badge: pendingOffers.isEmpty ? nil : "\(pendingOffers.count)"
                        )
                    }

                    NavigationLink {
                        AcceptedDispatchLoadsView()
                            .environmentObject(supabase)
                    } label: {
                        DispatchMenuRow(
                            title: "Status Board",
                            subtitle: "Accepted dispatch loads being handled",
                            systemImage: "list.bullet.clipboard.fill",
                            badge: acceptedOffers.isEmpty ? nil : "\(acceptedOffers.count)"
                        )
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Dispatcher Expenses") {
                    NavigationLink {
                        DispatcherExpensesView()
                            .environmentObject(supabase)
                    } label: {
                        DispatchMenuRow(
                            title: "Expense Board",
                            subtitle: "Software, phone, office, marketing, driver support",
                            systemImage: "receipt.fill"
                        )
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Carrier Agreements & Revenue Tracking") {
                    NavigationLink {
                        DispatchServiceRequestsView()
                            .environmentObject(supabase)
                    } label: {
                        DispatchMenuRow(
                            title: "Service Requests",
                            subtitle: "Carrier requests that can become agreements",
                            systemImage: "envelope.badge.fill",
                            badge: dispatch.serviceRequests.isEmpty ? nil : "\(dispatch.serviceRequests.count)"
                        )
                    }

                    NavigationLink {
                        DispatchAgreementsView()
                            .environmentObject(supabase)
                    } label: {
                        DispatchMenuRow(
                            title: "Service Agreements",
                            subtitle: "Track percentage, flat, weekly, and monthly terms",
                            systemImage: "doc.text.fill",
                            badge: dispatch.activeAgreements().isEmpty ? nil : "\(dispatch.activeAgreements().count)"
                        )
                    }

                    NavigationLink {
                        DispatcherRevenueProtectionView()
                            .environmentObject(supabase)
                    } label: {
                        DispatchMenuRow(
                            title: "Revenue Protection",
                            subtitle: "Settlement verification, fee records, and balances",
                            systemImage: "shield.lefthalf.filled",
                            badge: unpaidPaymentCount == 0 ? nil : "\(unpaidPaymentCount)"
                        )
                    }

                    NavigationLink {
                        DispatcherNetworkInvoicesView()
                            .environmentObject(supabase)
                    } label: {
                        DispatchMenuRow(
                            title: "Invoice History",
                            subtitle: "Payment tracking only, no in-app payment collection",
                            systemImage: "doc.richtext.fill",
                            badge: dispatch.invoices.isEmpty ? nil : "\(dispatch.invoices.count)"
                        )
                    }

                    NavigationLink {
                        DispatcherPaymentsView()
                            .environmentObject(supabase)
                    } label: {
                        DispatchMenuRow(
                            title: "Payment Tracking",
                            subtitle: "Track owed, pending, and paid status only",
                            systemImage: "creditcard.fill",
                            badge: legacyUnpaidPaymentCount == 0 ? nil : "\(legacyUnpaidPaymentCount)"
                        )
                    }
                }
                .listRowBackground(Color.spCardBg)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Sacred DISPATCH")
        .onAppear {
            if supabase.currentProfile?.accountRole == .dispatcher {
                dispatch.activeRole = .dispatcher
            }
        }
        .task { await dispatch.reload(supabase: supabase) }
        .refreshable { await dispatch.reload(supabase: supabase) }
    }

    private var pendingOffers: [DispatchLoadOffer] {
        dispatch.offers.filter { $0.status == .pending }
    }

    private var acceptedOffers: [DispatchLoadOffer] {
        dispatch.offers.filter { $0.status == .accepted }
    }

    private var unpaidPaymentCount: Int {
        dispatch.feeRecords.filter { $0.paymentStatus != .paid }.count
    }

    private var legacyUnpaidPaymentCount: Int {
        dispatch.payments.filter { $0.paymentStatus != .paid }.count
    }

    private var activeDriverCount: Int {
        Set(dispatch.participants.filter { $0.role == .driver && $0.isActive }.map(\.profileId)).count
    }

    private var loadsBeingHandled: Int {
        dispatch.offers.filter { $0.status == .accepted || $0.status == .pending }.count
    }
}

struct DispatcherDriverContactsView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared

    private var contacts: [DriverContact] {
        var byProfileId: [UUID: DriverContact] = [:]

        for participant in dispatch.participants where participant.role == .driver && participant.isActive {
            byProfileId[participant.profileId] = makeContact(
                profileId: participant.profileId,
                displayName: participant.displayName ?? "Driver",
                participant: participant
            )
        }

        for offer in dispatch.offers {
            guard let profileId = offer.driverProfileId else { continue }
            if byProfileId[profileId] == nil {
                byProfileId[profileId] = makeContact(
                    profileId: profileId,
                    displayName: offer.driverProfileId == supabase.currentProfile?.id ? "You" : "Driver"
                )
            }
        }

        for thread in dispatch.threads {
            guard let profileId = thread.driverProfileId else { continue }
            if byProfileId[profileId] == nil {
                byProfileId[profileId] = makeContact(
                    profileId: profileId,
                    displayName: "Driver"
                )
            }
        }

        return byProfileId.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                DispatchErrorBanner(message: dispatch.lastErrorMessage)

                if contacts.isEmpty {
                    Text("No connected drivers yet. Drivers appear here after a dispatch thread, participant record, or load offer connects them to this dispatcher account.")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                        .listRowBackground(Color.spCardBg)
                } else {
                    ForEach(contacts) { contact in
                        NavigationLink {
                            DispatcherDriverDetailView(contact: contact)
                                .environmentObject(supabase)
                        } label: {
                            DriverContactRow(contact: contact)
                        }
                        .listRowBackground(Color.spCardBg)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Driver Contacts")
        .onAppear { dispatch.activeRole = .dispatcher }
        .task { await dispatch.reload(supabase: supabase) }
        .refreshable { await dispatch.reload(supabase: supabase) }
    }

    private func makeContact(profileId: UUID, displayName: String, participant: DispatchParticipant? = nil) -> DriverContact {
        let currentLoads = dispatch.offers.filter { offer in
            offer.driverProfileId == profileId &&
            (offer.status == .accepted || offer.status == .pending)
        }
        let thread = dispatch.threads.first { thread in
            thread.driverProfileId == profileId ||
            dispatch.participants.contains {
                $0.threadId == thread.id &&
                $0.profileId == profileId &&
                $0.role == .driver
            }
        }
        let status: String = {
            if let currentStatus = participant?.currentStatus, !currentStatus.isEmpty { return currentStatus }
            if currentLoads.contains(where: { $0.status == .accepted }) { return "Handling Load" }
            if currentLoads.contains(where: { $0.status == .pending }) { return "Offer Pending" }
            return "Available"
        }()
        return DriverContact(
            id: profileId,
            profileId: profileId,
            displayName: displayName,
            phone: participant?.phone,
            email: participant?.email,
            truckNumber: participant?.truckNumber,
            trailerNumber: participant?.trailerNumber,
            currentStatus: status,
            notes: participant?.notes,
            thread: thread,
            currentLoads: currentLoads
        )
    }
}

struct DispatcherDriverDetailView: View {
    @EnvironmentObject var supabase: SupabaseService
    let contact: DriverContact

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                Section("Contact Info") {
                    DispatchInfoRow("Driver", value: contact.displayName)
                    DispatchInfoRow("Phone", value: contact.phone ?? "Not on file")
                    DispatchInfoRow("Email", value: contact.email ?? "Not on file")
                    DispatchInfoRow("Truck #", value: contact.truckNumber ?? "Not on file")
                    DispatchInfoRow("Trailer #", value: contact.trailerNumber ?? "Not on file")
                    DispatchInfoRow("Status", value: contact.currentStatus)
                }
                .listRowBackground(Color.spCardBg)

                Section("Communication") {
                    if let thread = contact.thread {
                        NavigationLink {
                            DispatchChatThreadView(thread: thread)
                                .environmentObject(supabase)
                        } label: {
                            DispatchMenuRow(
                                title: "Message Driver",
                                subtitle: thread.lastMessagePreview ?? "Open dispatch thread",
                                systemImage: "message.fill",
                                badge: thread.unreadCount(for: .dispatcher) == 0 ? nil : "\(thread.unreadCount(for: .dispatcher))"
                            )
                        }
                    } else {
                        Text("No active message thread for this driver yet.")
                            .font(.subheadline)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Current Loads") {
                    if contact.currentLoads.isEmpty {
                        Text("No current dispatch loads for this driver.")
                            .font(.subheadline)
                            .foregroundStyle(Color.spTextSecondary)
                    } else {
                        ForEach(contact.currentLoads) { offer in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(offer.loadNumber.map { "Load #\($0)" } ?? offer.brokerName ?? "Dispatch Load")
                                    .font(.headline)
                                    .foregroundStyle(Color.spTextPrimary)
                                Text("\(offer.origin ?? "Pickup") → \(offer.destination ?? "Delivery")")
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextSecondary)
                                DispatchInfoRow("Status", value: offer.status.displayName)
                                DispatchInfoRow("Gross", value: offer.grossAmountForCalculations.asCurrency)
                            }
                        }
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Notes") {
                    Text(contact.notes ?? "No dispatcher notes saved for this driver.")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                }
                .listRowBackground(Color.spCardBg)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(contact.displayName)
    }
}

struct DispatcherExpensesView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var appMode = AppMode.shared
    @ObservedObject private var localExpenses = LocalExpensesRepository.shared
    @State private var expenses: [Expense] = []
    @State private var isLoading = true
    @State private var showingExpenseEntry = false

    private var sourceExpenses: [Expense] {
        appMode.isLocal ? localExpenses.expenses : expenses
    }

    private var dispatcherExpenses: [Expense] {
        sourceExpenses.filter { expense in
            DispatcherExpenseCategory(rawValue: expense.category) != nil
        }
    }

    private var weekTotal: Double {
        DriverModeMath.weeklyExpenses(dispatcherExpenses).reduce(0) { $0 + $1.amount }
    }

    private var monthTotal: Double {
        let interval = Calendar.current.dateInterval(of: .month, for: Date())
        return dispatcherExpenses.filter { expense in
            guard let interval, let date = expense.receiptDate ?? expense.createdAt else { return false }
            return interval.contains(date)
        }
        .reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                if appMode.isLocal {
                    LocalModeBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("Summary") {
                    HStack(spacing: 10) {
                        DispatchSummaryTile(title: "This Week", value: weekTotal.asCurrency, systemImage: "calendar")
                        DispatchSummaryTile(title: "This Month", value: monthTotal.asCurrency, systemImage: "calendar.badge.clock")
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Expenses") {
                    if isLoading {
                        ProgressView().tint(Color.spGold)
                    } else if dispatcherExpenses.isEmpty {
                        Text("No dispatcher expenses yet.")
                            .font(.subheadline)
                            .foregroundStyle(Color.spTextSecondary)
                    } else {
                        ForEach(dispatcherExpenses.sorted { ($0.receiptDate ?? .distantPast) > ($1.receiptDate ?? .distantPast) }) { expense in
                            DispatcherExpenseRow(expense: expense)
                        }
                    }
                }
                .listRowBackground(Color.spCardBg)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Dispatcher Expenses")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingExpenseEntry = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.spGold)
                }
                .accessibilityLabel("Add Dispatcher Expense")
            }
        }
        .task { await loadData() }
        .refreshable { await loadData() }
        .sheet(isPresented: $showingExpenseEntry, onDismiss: reload) {
            DispatcherExpenseEntryView()
                .environmentObject(supabase)
        }
        .onReceive(NotificationCenter.default.publisher(for: .expensesDidChange)) { _ in reload() }
    }

    private func loadData() async {
        if appMode.isLocal {
            localExpenses.reload()
            isLoading = false
            return
        }
        do {
            expenses = try await supabase.fetchAllExpenses()
        } catch {
            #if DEBUG
            print("[SacredDispatch] dispatcher expenses load failed: \(error)")
            #endif
        }
        isLoading = false
    }

    private func reload() {
        Task { await loadData() }
    }
}

struct DispatcherExpenseEntryView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appMode = AppMode.shared
    @State private var category: DispatcherExpenseCategory = .software
    @State private var amount = ""
    @State private var date = Date()
    @State private var note = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        DriverEntryCard("Dispatcher Expense") {
                            Picker("Category", selection: $category) {
                                ForEach(DispatcherExpenseCategory.allCases) { category in
                                    Label(category.displayName, systemImage: category.systemImage).tag(category)
                                }
                            }
                            DriverTextField("Amount", text: $amount, placeholder: "0.00", keyboard: .decimalPad, prefix: "$")
                            DatePicker("Date", selection: $date, displayedComponents: .date)
                                .foregroundStyle(Color.spTextPrimary)
                            TextField("Note", text: $note, axis: .vertical)
                                .lineLimit(2...4)
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextPrimary)
                                .padding(12)
                                .background(Color.spCardBgLight)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(Color.spDanger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                        }

                        Button {
                            Task { await saveExpense() }
                        } label: {
                            if isSaving {
                                ProgressView().tint(Color.spBlack)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                            } else {
                                Label("Save Expense", systemImage: "checkmark.circle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                            }
                        }
                        .background(Color.spGold)
                        .foregroundStyle(Color.spBlack)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .disabled(isSaving)
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 14)
                }
            }
            .navigationTitle("Add Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.spGold)
                }
            }
        }
    }

    private func saveExpense() async {
        errorMessage = nil
        guard let amountValue = Double(amount), amountValue > 0 else {
            errorMessage = "Enter a valid expense amount."
            return
        }

        let profileId: UUID
        if appMode.isLocal {
            profileId = appMode.localInstallId
        } else if let id = supabase.currentProfile?.id ?? supabase.client.auth.currentUser?.id {
            profileId = id
        } else {
            errorMessage = "Sign in before saving this expense."
            return
        }

        isSaving = true
        defer { isSaving = false }

        let expense = Expense(
            profileId: profileId,
            category: category.rawValue,
            amount: amountValue,
            description: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note,
            receiptDate: date
        )

        if appMode.isLocal {
            _ = LocalExpensesRepository.shared.create(expense)
            NotificationCenter.default.post(name: .expensesDidChange, object: nil)
            dismiss()
            return
        }

        do {
            _ = try await supabase.createExpense(expense)
            dismiss()
        } catch {
            errorMessage = "Couldn't save this dispatcher expense: \(error.localizedDescription)"
        }
    }
}

struct DriverContactRow: View {
    let contact: DriverContact

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.spGold)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text(contact.currentStatus)
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
            Spacer()
            if !contact.currentLoads.isEmpty {
                Text("\(contact.currentLoads.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.spBlack)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.spGold)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

struct DispatcherExpenseRow: View {
    let expense: Expense

    var body: some View {
        HStack(spacing: 12) {
            let category = DispatcherExpenseCategory(rawValue: expense.category)
            Image(systemName: category?.systemImage ?? "receipt.fill")
                .foregroundStyle(Color.spGold)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(category?.displayName ?? expense.category.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text(expense.description ?? expense.receiptDate?.formatted(date: .abbreviated, time: .omitted) ?? "Dispatcher expense")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(expense.amount.asCurrency)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.spDanger)
        }
        .padding(.vertical, 4)
    }
}

struct DispatchLoadOffersView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared
    @State private var showingNewOffer = false

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                DispatchErrorBanner(message: dispatch.lastErrorMessage)
                if dispatch.offers.isEmpty {
                    Text("No dispatch load offers yet.")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                        .listRowBackground(Color.spCardBg)
                } else {
                    ForEach(dispatch.offers) { offer in
                        NavigationLink {
                            DispatchOfferDetailView(offer: offer)
                                .environmentObject(supabase)
                        } label: {
                            DispatchOfferRow(offer: offer)
                        }
                        .listRowBackground(Color.spCardBg)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Load Offers")
        .toolbar {
            if dispatch.activeRole == .dispatcher {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewOffer = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.spGold)
                    }
                    .accessibilityLabel("New Dispatch Offer")
                }
            }
        }
        .sheet(isPresented: $showingNewOffer) {
            NavigationStack {
                DispatchOfferEditorView()
                    .environmentObject(supabase)
            }
        }
        .task { await dispatch.reload(supabase: supabase) }
        .refreshable { await dispatch.reload(supabase: supabase) }
    }
}

struct DispatchOfferDetailView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dispatch = DispatchService.shared
    let offer: DispatchLoadOffer

    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(offer.loadNumber.map { "Load #\($0)" } ?? "Dispatch Offer")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Color.spGold)
                            Text(offer.dispatcherCompany ?? offer.dispatcherName ?? "Dispatcher")
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                        Spacer()
                        DispatchStatusPill(status: offer.status)
                    }

                    DispatchDetailCard(title: "Load Details") {
                        DispatchInfoRow("Broker", value: offer.brokerName)
                        DispatchInfoRow("MC Number", value: offer.brokerMcNumber)
                        DispatchInfoRow("Route", value: routeText)
                        DispatchInfoRow("Pickup", value: DispatchFormatters.date(offer.pickupDate))
                        DispatchInfoRow("Delivery", value: DispatchFormatters.date(offer.deliveryDate))
                        DispatchInfoRow("Miles", value: offer.totalMiles.map { String(format: "%.0f", $0) })
                        DispatchInfoRow("Gross", value: offer.grossAmountForCalculations.asCurrency)
                    }

                    DispatchDetailCard(title: "Dispatcher Fee") {
                        DispatchInfoRow("Fee Type", value: offer.feeType.displayName)
                        DispatchInfoRow("Fee", value: offer.feeDisplay)
                        DispatchInfoRow("Invoice", value: offer.invoiceCadence.displayName)
                        DispatchInfoRow("Due Date", value: DispatchFormatters.date(offer.dueDate))
                        DispatchInfoRow("Calculated Fee", value: offer.calculatedDispatchFee.asCurrency)
                    }

                    if let notes = offer.notes, !notes.isEmpty {
                        DispatchDetailCard(title: "Notes") {
                            Text(notes)
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextPrimary)
                        }
                    }

                    if offer.status == .pending && dispatch.activeRole != .dispatcher {
                        HStack(spacing: 12) {
                            Button {
                                decline()
                            } label: {
                                Label("Decline", systemImage: "xmark.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(Color.spDanger)
                            .disabled(isWorking)

                            Button {
                                accept()
                            } label: {
                                Label(isWorking ? "Saving" : "Accept", systemImage: "checkmark.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.spGold)
                            .disabled(isWorking)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.spDanger)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Offer")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Dispatch action failed",
               isPresented: Binding(
                   get: { errorMessage != nil },
                   set: { if !$0 { errorMessage = nil } }
               )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var routeText: String? {
        guard let origin = offer.origin, let destination = offer.destination else { return nil }
        return "\(origin) to \(destination)"
    }

    private func accept() {
        isWorking = true
        Task {
            do {
                try await dispatch.acceptOffer(offer, supabase: supabase)
                isWorking = false
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func decline() {
        isWorking = true
        Task {
            do {
                try await dispatch.declineOffer(offer, supabase: supabase)
                isWorking = false
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
            }
        }
    }
}

struct DispatchOfferEditorView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dispatch = DispatchService.shared

    @State private var dispatcherName = ""
    @State private var dispatcherCompany = ""
    @State private var loadNumber = ""
    @State private var brokerName = ""
    @State private var brokerMcNumber = ""
    @State private var brokerPhone = ""
    @State private var brokerEmail = ""
    @State private var selectedRecipientId: UUID?
    @State private var origin = ""
    @State private var destination = ""
    @State private var pickupDate = Date()
    @State private var deliveryDate = Date()
    @State private var miles = ""
    @State private var gross = ""
    @State private var fuelSurcharge = ""
    @State private var accessorials = ""
    @State private var feeType: DispatchFeeType = .percentageGross
    @State private var feeAmount = ""
    @State private var feePercentage = ""
    @State private var invoiceCadence: DispatchInvoiceCadence = .weekly
    @State private var dueDate = Date()
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Recipient") {
                let recipients = dispatch.offerRecipients(supabase: supabase)
                if recipients.isEmpty {
                    Text("Create a dispatch service request or agreement before sending offers as a dispatcher.")
                        .font(.footnote)
                        .foregroundStyle(Color.spDanger)
                } else {
                    Picker("Carrier / Driver", selection: $selectedRecipientId) {
                        ForEach(recipients) { recipient in
                            Text("\(recipient.displayName) (\(recipient.role.displayName))")
                                .tag(Optional(recipient.profileId))
                        }
                    }
                }
            }

            Section("Dispatcher") {
                TextField("Name", text: $dispatcherName)
                TextField("Company", text: $dispatcherCompany)
            }

            Section("Load") {
                TextField("Load Number", text: $loadNumber)
                TextField("Broker", text: $brokerName)
                TextField("MC Number", text: $brokerMcNumber)
                TextField("Phone", text: $brokerPhone)
                    .keyboardType(.phonePad)
                TextField("Email", text: $brokerEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                TextField("Pickup", text: $origin)
                TextField("Delivery", text: $destination)
                DatePicker("Pickup Date", selection: $pickupDate, displayedComponents: .date)
                DatePicker("Delivery Date", selection: $deliveryDate, displayedComponents: .date)
                TextField("Miles", text: $miles)
                    .keyboardType(.decimalPad)
                TextField("Gross Amount", text: $gross)
                    .keyboardType(.decimalPad)
                TextField("Fuel Surcharge", text: $fuelSurcharge)
                    .keyboardType(.decimalPad)
                TextField("Accessorials", text: $accessorials)
                    .keyboardType(.decimalPad)
            }

            Section("Dispatcher Payment") {
                Picker("Fee Type", selection: $feeType) {
                    ForEach(DispatchFeeType.loadOfferCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                if feeType.usesPercentage {
                    TextField("Percentage", text: $feePercentage)
                        .keyboardType(.decimalPad)
                } else {
                    TextField("Fee Amount", text: $feeAmount)
                        .keyboardType(.decimalPad)
                }

                Picker("Invoice", selection: $invoiceCadence) {
                    ForEach(DispatchInvoiceCadence.allCases) { cadence in
                        Text(cadence.displayName).tag(cadence)
                    }
                }
                DatePicker("Due Date", selection: $dueDate, displayedComponents: .date)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(3...5)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.spDanger)
            }
        }
        .navigationTitle("New Offer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSaving ? "Saving" : "Save") {
                    saveOffer()
                }
                .disabled(isSaving)
            }
        }
        .onAppear {
            selectedRecipientId = selectedRecipientId ?? dispatch.offerRecipients(supabase: supabase).first?.profileId
            if dispatcherCompany.isEmpty {
                dispatcherCompany = supabase.currentProfile?.companyName ?? ""
            }
            if dispatcherName.isEmpty {
                dispatcherName = supabase.currentProfile?.companyName ?? ""
            }
        }
        .alert("Offer save failed",
               isPresented: Binding(
                   get: { errorMessage != nil },
                   set: { if !$0 { errorMessage = nil } }
               )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func saveOffer() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                guard let recipient = dispatch.offerRecipients(supabase: supabase).first(where: { $0.profileId == selectedRecipientId }) else {
                    throw DispatchServiceError.missingOfferRecipient
                }
                let companyId = AppMode.shared.isLocal
                    ? AppMode.shared.localInstallId
                    : (dispatch.activeAgreements().first { $0.id == recipient.agreementId }?.companyId ?? supabase.currentProfile?.id ?? supabase.client.auth.currentUser?.id ?? UUID())
                let grossValue = DispatchFormatters.number(gross)
                let draft = DispatchLoadOffer(
                    companyId: companyId,
                    driverProfileId: recipient.profileId,
                    agreementId: recipient.agreementId,
                    dispatcherName: DispatchFormatters.clean(dispatcherName),
                    dispatcherCompany: DispatchFormatters.clean(dispatcherCompany),
                    loadNumber: DispatchFormatters.clean(loadNumber),
                    brokerName: DispatchFormatters.clean(brokerName),
                    brokerMcNumber: DispatchFormatters.clean(brokerMcNumber),
                    brokerPhone: DispatchFormatters.clean(brokerPhone),
                    brokerEmail: DispatchFormatters.clean(brokerEmail),
                    pickupDate: pickupDate,
                    deliveryDate: deliveryDate,
                    origin: DispatchFormatters.clean(origin),
                    destination: DispatchFormatters.clean(destination),
                    totalMiles: DispatchFormatters.number(miles),
                    lineHaulRate: grossValue,
                    fuelSurcharge: DispatchFormatters.number(fuelSurcharge),
                    accessorialCharges: DispatchFormatters.number(accessorials),
                    loadGrossAmount: grossValue,
                    feeType: feeType,
                    feeAmount: feeType.requiresAmount ? DispatchFormatters.number(feeAmount) : nil,
                    feePercentage: feeType.usesPercentage ? DispatchFormatters.number(feePercentage) : nil,
                    invoiceCadence: invoiceCadence,
                    dueDate: dueDate,
                    notes: DispatchFormatters.clean(notes)
                )
                _ = try await dispatch.createOffer(draft, supabase: supabase)
                isSaving = false
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

struct DispatchChatThreadsView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                DispatchErrorBanner(message: dispatch.lastErrorMessage)
                if dispatch.threads.isEmpty {
                    Text("No dispatch chat threads yet.")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                        .listRowBackground(Color.spCardBg)
                } else {
                    ForEach(dispatch.threads) { thread in
                        NavigationLink {
                            DispatchChatThreadView(thread: thread)
                                .environmentObject(supabase)
                        } label: {
                            DispatchThreadRow(thread: thread)
                        }
                        .listRowBackground(Color.spCardBg)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Dispatch Chat")
        .task { await dispatch.reload(supabase: supabase) }
        .refreshable { await dispatch.reload(supabase: supabase) }
    }
}

struct DispatchChatThreadView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared
    let thread: DispatchThread

    @State private var draft = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(dispatch.messages(for: thread)) { message in
                        DispatchMessageBubble(message: message)
                    }
                }
                .padding()
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button {
                    send()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.spGold)
                .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(Color.spCardBg)
        }
        .background(Color.spBackground.ignoresSafeArea())
        .navigationTitle(thread.subject ?? "Dispatch Thread")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await dispatch.markThreadRead(thread, supabase: supabase)
        }
        .alert("Message failed",
               isPresented: Binding(
                   get: { errorMessage != nil },
                   set: { if !$0 { errorMessage = nil } }
               )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func send() {
        isSending = true
        let body = draft
        Task {
            do {
                try await dispatch.sendMessage(thread: thread, body: body, supabase: supabase)
                draft = ""
                isSending = false
            } catch {
                errorMessage = error.localizedDescription
                isSending = false
            }
        }
    }
}

struct AcceptedDispatchLoadsView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var loads: [Load] = []
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                if loads.isEmpty {
                    Text("No accepted dispatch loads yet.")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                        .listRowBackground(Color.spCardBg)
                } else {
                    ForEach(loads) { load in
                        NavigationLink {
                            LoadDetailView(load: load)
                                .environmentObject(supabase)
                        } label: {
                            LoadRowView(load: load)
                        }
                        .listRowBackground(Color.clear)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.spDanger)
                        .listRowBackground(Color.spCardBg)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Accepted Loads")
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        do {
            let allLoads = AppMode.shared.isLocal
                ? LocalLoadsRepository.shared.loads
                : try await supabase.fetchLoads()
            loads = allLoads.filter { $0.dispatchLoadOfferId != nil || $0.dispatchThreadId != nil }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DispatcherPaymentsView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                DispatchErrorBanner(message: dispatch.lastErrorMessage)
                Text("Payment tracking only. Sacred DISPATCH does not process cards, ACH, or real payments in this release.")
                    .font(.footnote)
                    .foregroundStyle(Color.spTextSecondary)
                    .listRowBackground(Color.spCardBg)
                if dispatch.payments.isEmpty {
                    Text("No dispatcher payment records yet.")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                        .listRowBackground(Color.spCardBg)
                } else {
                    ForEach(dispatch.payments) { payment in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(payment.loadNumber.map { "Load #\($0)" } ?? "Dispatch Load")
                                        .font(.headline)
                                        .foregroundStyle(Color.spGold)
                                    Text(payment.dispatcherCompany ?? payment.dispatcherName ?? "Dispatcher")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                }
                                Spacer()
                                Text(payment.calculatedDispatchFee.asCurrency)
                                    .font(.headline)
                                    .foregroundStyle(Color.spDarkGreen)
                            }
                            DispatchInfoRow("Gross", value: payment.loadGrossAmount.asCurrency)
                            DispatchInfoRow("Fee", value: feeText(payment))
                            DispatchInfoRow("Due", value: DispatchFormatters.date(payment.dueDate))

                            Picker("Status", selection: statusBinding(for: payment)) {
                                ForEach(DispatchPaymentStatus.allCases) { status in
                                    Text(status.displayName).tag(status)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.vertical, 6)
                        .listRowBackground(Color.spCardBg)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.spDanger)
                        .listRowBackground(Color.spCardBg)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Payment Tracking")
        .task { await dispatch.reload(supabase: supabase) }
        .refreshable { await dispatch.reload(supabase: supabase) }
    }

    private func statusBinding(for payment: DispatcherPaymentRecord) -> Binding<DispatchPaymentStatus> {
        Binding(
            get: { payment.paymentStatus },
            set: { newValue in
                Task {
                    do {
                        try await dispatch.updatePaymentStatus(payment, status: newValue, supabase: supabase)
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        )
    }

    private func feeText(_ payment: DispatcherPaymentRecord) -> String {
        switch payment.feeType {
        case .flat, .flatPerLoad, .weeklyFixed, .monthlyFixed:
            return payment.feeAmount.map { $0.asCurrency } ?? "Flat"
        case .percentage, .percentageGross:
            return String(format: "%.2f%%", payment.feePercentage ?? 0)
        }
    }
}

struct DispatcherInvoiceSummaryView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared
    @State private var cadence: DispatchInvoiceCadence = .weekly

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                DispatchErrorBanner(message: dispatch.lastErrorMessage)
                Picker("Cadence", selection: $cadence) {
                    ForEach(DispatchInvoiceCadence.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.spCardBg)

                let summaries = dispatch.invoiceSummaries(for: cadence)
                if summaries.isEmpty {
                    Text("No \(cadence.displayName.lowercased()) invoice records yet.")
                        .font(.subheadline)
                        .foregroundStyle(Color.spTextSecondary)
                        .listRowBackground(Color.spCardBg)
                } else {
                    ForEach(summaries) { summary in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(DispatchFormatters.date(summary.periodStart) ?? "") - \(DispatchFormatters.date(summary.periodEnd) ?? "")")
                                .font(.headline)
                                .foregroundStyle(Color.spGold)
                            DispatchInfoRow("Total Owed", value: summary.totalOwed.asCurrency)
                            DispatchInfoRow("Unpaid", value: summary.unpaidTotal.asCurrency)
                            DispatchInfoRow("Pending", value: summary.pendingTotal.asCurrency)
                            DispatchInfoRow("Paid", value: summary.paidTotal.asCurrency)
                            Text("\(summary.records.count) record\(summary.records.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                        .padding(.vertical, 6)
                        .listRowBackground(Color.spCardBg)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Invoice Summary")
        .task { await dispatch.reload(supabase: supabase) }
        .refreshable { await dispatch.reload(supabase: supabase) }
    }
}

struct DispatcherDirectoryView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared
    @State private var searchText = ""
    @State private var region = ""
    @State private var equipment: DispatchEquipmentType?
    @State private var showingEditor = false

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                DispatchErrorBanner(message: dispatch.lastErrorMessage)
                Section {
                    TextField("Search dispatchers", text: $searchText)
                    Picker("Equipment", selection: $equipment) {
                        Text("Any").tag(DispatchEquipmentType?.none)
                        ForEach(DispatchEquipmentType.allCases) { type in
                            Text(type.displayName).tag(Optional(type))
                        }
                    }
                    TextField("State or region", text: $region)
                }
                .listRowBackground(Color.spCardBg)

                Section("Dispatcher Directory") {
                    let profiles = dispatch.filteredDispatcherProfiles(
                        searchText: searchText,
                        equipment: equipment,
                        region: region
                    )
                    if profiles.isEmpty {
                        Text("No matching dispatchers yet.")
                            .font(.subheadline)
                            .foregroundStyle(Color.spTextSecondary)
                    } else {
                        ForEach(profiles) { profile in
                            NavigationLink {
                                DispatcherProfileDetailView(profile: profile)
                                    .environmentObject(supabase)
                            } label: {
                                DispatcherProfileRow(profile: profile)
                            }
                        }
                    }
                }
                .listRowBackground(Color.spCardBg)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Directory")
        .toolbar {
            if dispatch.activeRole == .dispatcher {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingEditor = true
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .foregroundStyle(Color.spGold)
                    }
                    .accessibilityLabel("Create Dispatcher Profile")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                DispatcherProfileEditorView()
                    .environmentObject(supabase)
            }
        }
        .task { await dispatch.reload(supabase: supabase) }
        .refreshable { await dispatch.reload(supabase: supabase) }
    }
}

struct DispatcherProfileDetailView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared
    let profile: DispatcherProfile

    @State private var notes = ""
    @State private var isRequesting = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DispatchDetailCard(title: "Dispatcher Profile") {
                        DispatchInfoRow("Company", value: profile.companyName)
                        DispatchInfoRow("Dispatcher", value: profile.displayName)
                        DispatchInfoRow("Experience", value: profile.yearsExperience.map { "\($0) years" })
                        DispatchInfoRow("Rating", value: ratingText)
                        DispatchInfoRow("Equipment", value: equipmentText)
                        DispatchInfoRow("Regions", value: profile.serviceRegions?.joined(separator: ", "))
                        DispatchInfoRow("Languages", value: profile.languagesSpoken?.joined(separator: ", "))
                        DispatchInfoRow("Services", value: profile.servicesOffered?.joined(separator: ", "))
                        DispatchInfoRow("Contact", value: profile.contactInfo ?? profile.email ?? profile.phone)
                    }

                    if dispatch.activeRole != .dispatcher {
                        DispatchDetailCard(title: "Request Service") {
                            TextEditor(text: $notes)
                                .frame(minHeight: 110)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(Color.spBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(Color.spDanger)
                            }

                            Button {
                                Task { await submitRequest() }
                            } label: {
                                Label(isRequesting ? "Sending..." : "Send Service Request", systemImage: "paperplane.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.spGold)
                            .disabled(isRequesting)
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle(profile.companyName ?? "Dispatcher")
    }

    private var ratingText: String? {
        guard let average = profile.ratingAverage, (profile.ratingCount ?? 0) > 0 else { return "No reviews yet" }
        return String(format: "%.1f (%d)", average, profile.ratingCount ?? 0)
    }

    private var equipmentText: String? {
        profile.equipmentTypes?
            .compactMap { DispatchEquipmentType(rawValue: $0)?.displayName ?? $0 }
            .joined(separator: ", ")
    }

    private func submitRequest() async {
        isRequesting = true
        errorMessage = nil
        do {
            _ = try await dispatch.requestDispatchService(
                dispatcher: profile,
                notes: notes,
                supabase: supabase
            )
            notes = ""
        } catch {
            errorMessage = error.localizedDescription
        }
        isRequesting = false
    }
}

struct DispatcherProfileEditorView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dispatch = DispatchService.shared

    @State private var companyName = ""
    @State private var dispatcherName = ""
    @State private var yearsExperience = ""
    @State private var selectedEquipment = Set<DispatchEquipmentType>()
    @State private var regions = ""
    @State private var languages = "English"
    @State private var services = ""
    @State private var contactInfo = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Company Name", text: $companyName)
                TextField("Dispatcher Name", text: $dispatcherName)
                TextField("Years Experience", text: $yearsExperience)
                    .keyboardType(.numberPad)
            }

            Section("Equipment") {
                ForEach(DispatchEquipmentType.allCases) { type in
                    Toggle(type.displayName, isOn: binding(for: type))
                }
            }

            Section("Service Area") {
                TextField("States/Regions Served", text: $regions)
                TextField("Languages Spoken", text: $languages)
                TextField("Services Offered", text: $services)
            }

            Section("Contact") {
                TextField("Contact Information", text: $contactInfo)
                TextField("Phone", text: $phone)
                    .keyboardType(.phonePad)
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(Color.spDanger)
                }
            }
        }
        .navigationTitle("Dispatcher Profile")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving..." : "Save") {
                    Task { await save() }
                }
                .disabled(isSaving)
            }
        }
    }

    private func binding(for type: DispatchEquipmentType) -> Binding<Bool> {
        Binding {
            selectedEquipment.contains(type)
        } set: { enabled in
            if enabled {
                selectedEquipment.insert(type)
            } else {
                selectedEquipment.remove(type)
            }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        do {
            let profile = DispatcherProfile(
                id: nil,
                companyId: nil,
                userId: nil,
                displayName: DispatchFormatters.clean(dispatcherName),
                companyName: DispatchFormatters.clean(companyName),
                yearsExperience: Int(yearsExperience),
                equipmentTypes: selectedEquipment.map(\.rawValue),
                serviceRegions: splitList(regions),
                languagesSpoken: splitList(languages),
                servicesOffered: splitList(services),
                phone: DispatchFormatters.clean(phone),
                email: DispatchFormatters.clean(email),
                contactInfo: DispatchFormatters.clean(contactInfo),
                isActive: true,
                isTrusted: false,
                platformFeePercentage: nil,
                ratingAverage: 0,
                ratingCount: 0,
                createdAt: nil,
                updatedAt: nil
            )
            _ = try await dispatch.saveDispatcherProfile(profile, supabase: supabase)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func splitList(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct DispatchServiceRequestsView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared
    @State private var requestForAgreement: DispatchServiceRequest?

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                DispatchErrorBanner(message: dispatch.lastErrorMessage)
                if dispatch.serviceRequests.isEmpty {
                    Text("No service requests yet.")
                        .foregroundStyle(Color.spTextSecondary)
                        .listRowBackground(Color.spCardBg)
                } else {
                    ForEach(dispatch.serviceRequests) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(request.carrierName ?? "Carrier")
                                        .font(.headline)
                                        .foregroundStyle(Color.spGold)
                                    Text(request.serviceNotes ?? "No notes")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                DispatchTextPill(text: request.status.displayName, color: request.status == .accepted ? Color.spSuccess : Color.spGold)
                            }
                            if request.status != .accepted && dispatch.activeRole == .dispatcher {
                                Button {
                                    requestForAgreement = request
                                } label: {
                                    Label("Create Agreement", systemImage: "doc.badge.plus")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Color.spGold)
                            }
                        }
                        .padding(.vertical, 6)
                        .listRowBackground(Color.spCardBg)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Requests")
        .sheet(item: $requestForAgreement) { request in
            NavigationStack {
                DispatchAgreementEditorView(request: request)
                    .environmentObject(supabase)
            }
        }
        .task { await dispatch.reload(supabase: supabase) }
        .refreshable { await dispatch.reload(supabase: supabase) }
    }
}

struct DispatchAgreementEditorView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dispatch = DispatchService.shared

    let request: DispatchServiceRequest
    @State private var feeType: DispatchFeeType = .percentageGross
    @State private var feePercentage = "5"
    @State private var feeAmount = "75"
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Agreement") {
                Picker("Fee Type", selection: $feeType) {
                    ForEach(DispatchFeeType.agreementCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                TextField("Fee Percentage", text: $feePercentage)
                    .keyboardType(.decimalPad)
                    .disabled(!feeType.usesPercentage)
                TextField("Fee Amount", text: $feeAmount)
                    .keyboardType(.decimalPad)
                    .disabled(feeType.usesPercentage)
                TextField("Notes", text: $notes, axis: .vertical)
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(Color.spDanger)
                }
            }
        }
        .navigationTitle("Create Agreement")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving..." : "Activate") {
                    Task { await save() }
                }
                .disabled(isSaving)
            }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        do {
            _ = try await dispatch.createAgreement(
                from: request,
                feeType: feeType,
                feePercentage: feeType.usesPercentage ? DispatchFormatters.number(feePercentage) : nil,
                feeAmount: feeType.requiresAmount ? DispatchFormatters.number(feeAmount) : nil,
                notes: notes,
                supabase: supabase
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

struct DispatchAgreementsView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                DispatchErrorBanner(message: dispatch.lastErrorMessage)
                if dispatch.agreements.isEmpty {
                    Text("No dispatch agreements yet.")
                        .foregroundStyle(Color.spTextSecondary)
                        .listRowBackground(Color.spCardBg)
                } else {
                    ForEach(dispatch.agreements) { agreement in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(agreement.dispatcherCompany ?? agreement.dispatcherName ?? "Dispatcher")
                                        .font(.headline)
                                        .foregroundStyle(Color.spGold)
                                    Text(agreement.carrierName ?? "Carrier")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                }
                                Spacer()
                                DispatchTextPill(text: agreement.status.displayName, color: agreement.status == .active ? Color.spSuccess : Color.spGold)
                            }
                            DispatchInfoRow("Effective", value: DispatchFormatters.date(agreement.effectiveDate))
                            DispatchInfoRow("Fee", value: agreement.feeDisplay)
                            DispatchInfoRow("Notes", value: agreement.notes)
                        }
                        .padding(.vertical, 6)
                        .listRowBackground(Color.spCardBg)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Agreements")
        .task { await dispatch.reload(supabase: supabase) }
        .refreshable { await dispatch.reload(supabase: supabase) }
    }
}

struct DispatcherRevenueProtectionView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared
    @State private var showingSettlementEntry = false

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                DispatchErrorBanner(message: dispatch.lastErrorMessage)
                let summary = dispatch.networkSummary()
                Section {
                    HStack(spacing: 10) {
                        DispatchSummaryTile(title: "Gross", value: summary.grossRevenueManaged.asCurrency, systemImage: "chart.bar.fill")
                        DispatchSummaryTile(title: "Owed", value: summary.feesOwed.asCurrency, systemImage: "dollarsign.circle.fill")
                    }
                    HStack(spacing: 10) {
                        DispatchSummaryTile(title: "Paid", value: summary.feesPaid.asCurrency, systemImage: "checkmark.seal.fill")
                        DispatchSummaryTile(title: "Overdue", value: summary.overduePayments.asCurrency, systemImage: "clock.badge.exclamationmark.fill")
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Fee Records") {
                    if dispatch.feeRecords.isEmpty {
                        Text("No settlement-backed fee records yet.")
                            .foregroundStyle(Color.spTextSecondary)
                    } else {
                        ForEach(dispatch.feeRecords) { record in
                            DispatcherFeeRecordRow(record: record)
                        }
                    }
                }
                .listRowBackground(Color.spCardBg)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Revenue Protection")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettlementEntry = true
                } label: {
                    Image(systemName: "doc.text.viewfinder")
                        .foregroundStyle(Color.spGold)
                }
                .disabled(dispatch.activeAgreements().isEmpty)
                .accessibilityLabel("Add Settlement Fee Record")
            }
        }
        .sheet(isPresented: $showingSettlementEntry) {
            NavigationStack {
                SettlementFeeRecordEditorView()
                    .environmentObject(supabase)
            }
        }
        .task { await dispatch.reload(supabase: supabase) }
        .refreshable { await dispatch.reload(supabase: supabase) }
    }
}

struct SettlementFeeRecordEditorView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dispatch = DispatchService.shared

    @State private var agreementId: UUID?
    @State private var loadNumber = ""
    @State private var brokerName = ""
    @State private var grossRevenue = ""
    @State private var paymentAmount = ""
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Agreement") {
                Picker("Active Agreement", selection: $agreementId) {
                    ForEach(dispatch.activeAgreements()) { agreement in
                        Text(agreement.dispatcherCompany ?? agreement.dispatcherName ?? "Dispatcher")
                            .tag(agreement.id)
                    }
                }
            }

            Section("Settlement OCR Result") {
                TextField("Load Number", text: $loadNumber)
                TextField("Broker", text: $brokerName)
                TextField("Gross Revenue", text: $grossRevenue)
                    .keyboardType(.decimalPad)
                TextField("Payment Amount", text: $paymentAmount)
                    .keyboardType(.decimalPad)
                TextField("Notes", text: $notes, axis: .vertical)
            }

            if let agreement = selectedAgreement {
                Section("Calculated Fee") {
                    DispatchInfoRow("Agreement", value: agreement.feeDisplay)
                    DispatchInfoRow("Fee Due", value: agreement.fee(for: DispatchFormatters.number(grossRevenue) ?? 0).asCurrency)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(Color.spDanger)
                }
            }
        }
        .navigationTitle("Settlement Fee")
        .onAppear {
            agreementId = agreementId ?? dispatch.activeAgreements().first?.id
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving..." : "Save") {
                    Task { await save() }
                }
                .disabled(isSaving || selectedAgreement == nil)
            }
        }
    }

    private var selectedAgreement: DispatchAgreement? {
        dispatch.activeAgreements().first { $0.id == agreementId }
    }

    private func save() async {
        guard let selectedAgreement else { return }
        isSaving = true
        errorMessage = nil
        do {
            _ = try await dispatch.recordSettlement(
                agreement: selectedAgreement,
                loadNumber: loadNumber,
                brokerName: brokerName,
                grossRevenue: DispatchFormatters.number(grossRevenue) ?? 0,
                paymentAmount: DispatchFormatters.number(paymentAmount),
                sourceType: "settlement_manual_or_ocr",
                ocrConfidence: nil,
                notes: notes,
                supabase: supabase
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

struct DispatcherNetworkInvoicesView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                DispatchErrorBanner(message: dispatch.lastErrorMessage)
                if dispatch.invoices.isEmpty {
                    Text("No dispatcher invoices yet.")
                        .foregroundStyle(Color.spTextSecondary)
                        .listRowBackground(Color.spCardBg)
                } else {
                    ForEach(dispatch.invoices) { invoice in
                        DispatcherInvoiceRow(invoice: invoice)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Invoices")
        .task { await dispatch.reload(supabase: supabase) }
        .refreshable { await dispatch.reload(supabase: supabase) }
    }
}

private struct DispatcherProfileRow: View {
    let profile: DispatcherProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.companyName ?? profile.displayName ?? "Dispatcher")
                        .font(.headline)
                        .foregroundStyle(Color.spGold)
                    Text(profile.displayName ?? profile.email ?? "No contact listed")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                Spacer()
                if profile.isActive ?? true {
                    DispatchTextPill(text: "Active", color: Color.spSuccess)
                }
            }
            DispatchInfoRow("Equipment", value: equipmentText)
            DispatchInfoRow("Regions", value: profile.serviceRegions?.joined(separator: ", "))
            DispatchInfoRow("Rating", value: ratingText)
        }
        .padding(.vertical, 6)
    }

    private var equipmentText: String? {
        profile.equipmentTypes?
            .compactMap { DispatchEquipmentType(rawValue: $0)?.displayName ?? $0 }
            .joined(separator: ", ")
    }

    private var ratingText: String? {
        guard let average = profile.ratingAverage, (profile.ratingCount ?? 0) > 0 else { return "No reviews" }
        return String(format: "%.1f / 5 (%d)", average, profile.ratingCount ?? 0)
    }
}

private struct DispatcherFeeRecordRow: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared
    let record: DispatcherFeeRecord
    @State private var selectedStatus: DispatchPaymentStatus
    @State private var errorMessage: String?

    init(record: DispatcherFeeRecord) {
        self.record = record
        _selectedStatus = State(initialValue: record.paymentStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.loadNumber.map { "Load #\($0)" } ?? "Settlement Fee")
                        .font(.headline)
                        .foregroundStyle(Color.spGold)
                    Text(record.brokerName ?? record.sourceType ?? "Settlement")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                Spacer()
                DispatchTextPill(text: selectedStatus.displayName, color: statusColor)
            }
            DispatchInfoRow("Gross Revenue", value: record.grossRevenue.asCurrency)
            DispatchInfoRow("Dispatch Fee", value: record.calculatedDispatchFee.asCurrency)
            DispatchInfoRow("Due", value: DispatchFormatters.date(record.dueDate))
            Picker("Status", selection: $selectedStatus) {
                ForEach(DispatchPaymentStatus.allCases) { status in
                    Text(status.displayName).tag(status)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedStatus) { _, newValue in
                Task { await updateStatus(newValue) }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.spDanger)
            }
        }
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        switch selectedStatus {
        case .paid: return Color.spSuccess
        case .pending: return Color.spGold
        case .overdue: return Color.spDanger
        case .unpaid: return Color.spTextSecondary
        }
    }

    private func updateStatus(_ status: DispatchPaymentStatus) async {
        do {
            try await dispatch.updateFeeRecordPaymentStatus(record, status: status, supabase: supabase)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DispatcherInvoiceRow: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var dispatch = DispatchService.shared
    let invoice: DispatcherInvoice
    @State private var selectedStatus: DispatchPaymentStatus
    @State private var errorMessage: String?

    init(invoice: DispatcherInvoice) {
        self.invoice = invoice
        _selectedStatus = State(initialValue: invoice.paymentStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(invoice.invoiceNumber ?? "Dispatcher Invoice")
                        .font(.headline)
                        .foregroundStyle(Color.spGold)
                    Text(periodText)
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                Spacer()
                DispatchTextPill(text: selectedStatus.displayName, color: statusColor)
            }
            DispatchInfoRow("Gross Managed", value: invoice.totalGrossRevenue.asCurrency)
            DispatchInfoRow("Fees Due", value: invoice.totalFeesDue.asCurrency)
            DispatchInfoRow("Due Date", value: DispatchFormatters.date(invoice.dueDate))
            Picker("Status", selection: $selectedStatus) {
                ForEach(DispatchPaymentStatus.allCases) { status in
                    Text(status.displayName).tag(status)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedStatus) { _, newValue in
                Task { await updateStatus(newValue) }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.spDanger)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.spCardBg)
    }

    private var periodText: String {
        let start = DispatchFormatters.date(invoice.periodStart) ?? "Start"
        let end = DispatchFormatters.date(invoice.periodEnd) ?? "End"
        return "\(start) - \(end)"
    }

    private var statusColor: Color {
        switch selectedStatus {
        case .paid: return Color.spSuccess
        case .pending: return Color.spGold
        case .overdue: return Color.spDanger
        case .unpaid: return Color.spTextSecondary
        }
    }

    private func updateStatus(_ status: DispatchPaymentStatus) async {
        do {
            try await dispatch.updateInvoicePaymentStatus(invoice, status: status, supabase: supabase)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DispatchTextPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

private struct DispatchErrorBanner: View {
    let message: String?

    var body: some View {
        if let message, !message.isEmpty {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Color.spDanger)
                .padding(.vertical, 4)
                .listRowBackground(Color.spCardBg)
        }
    }
}

private struct DispatchSummaryTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.spGold)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.spTextPrimary)
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.spCardBgLight.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct DispatchMenuRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var badge: String? = nil

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(Color.spGold)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Color.spTextPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
            }
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.spGold.opacity(0.2))
                    .foregroundStyle(Color.spGold)
                    .clipShape(Capsule())
            }
        }
    }
}

private struct DispatchOfferRow: View {
    let offer: DispatchLoadOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(offer.loadNumber.map { "Load #\($0)" } ?? "Dispatch Offer")
                        .font(.headline)
                        .foregroundStyle(Color.spGold)
                    Text(offer.brokerName ?? offer.dispatcherCompany ?? "No broker listed")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                Spacer()
                DispatchStatusPill(status: offer.status)
            }
            DispatchInfoRow("Route", value: routeText)
            DispatchInfoRow("Gross", value: offer.grossAmountForCalculations.asCurrency)
            DispatchInfoRow("Dispatch Fee", value: offer.calculatedDispatchFee.asCurrency)
        }
        .padding(.vertical, 6)
    }

    private var routeText: String? {
        guard let origin = offer.origin, let destination = offer.destination else { return nil }
        return "\(origin) to \(destination)"
    }
}

private struct DispatchThreadRow: View {
    @ObservedObject private var dispatch = DispatchService.shared
    let thread: DispatchThread

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(thread.subject ?? thread.loadNumber.map { "Load #\($0)" } ?? "Dispatch Thread")
                    .font(.headline)
                    .foregroundStyle(Color.spGold)
                Text(thread.lastMessagePreview ?? "No messages yet")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .lineLimit(1)
                if let date = thread.lastMessageAt {
                    Text(DispatchFormatters.dateTime(date))
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary)
                }
            }
            Spacer()
            let unread = thread.unreadCount(for: dispatch.activeRole)
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption2.weight(.bold))
                    .padding(7)
                    .background(Color.spDanger)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DispatchMessageBubble: View {
    let message: DispatchMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.senderName ?? message.senderRole.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.spGold)
                Text(message.senderRole.displayName)
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
                Spacer()
                if let createdAt = message.createdAt {
                    Text(DispatchFormatters.dateTime(createdAt))
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary)
                }
            }
            Text(message.body)
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct DispatchStatusPill: View {
    let status: DispatchOfferStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .pending: return Color.spGoldLight
        case .accepted: return Color.spSuccess
        case .declined: return Color.spDanger
        case .cancelled: return Color.spTextSecondary
        }
    }
}

private struct DispatchDetailCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.spTextSecondary)
            content
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct DispatchInfoRow: View {
    let title: String
    let value: String?

    init(_ title: String, value: String?) {
        self.title = title
        self.value = value
    }

    var body: some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                Spacer(minLength: 12)
                Text(value)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.spTextPrimary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

private enum DispatchFormatters {
    static func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func number(_ value: String) -> Double? {
        let filtered = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filtered.isEmpty ? nil : Double(filtered)
    }

    static func date(_ value: Date?) -> String? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: value)
    }

    static func dateTime(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: value)
    }
}
