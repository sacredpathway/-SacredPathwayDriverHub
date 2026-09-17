import SwiftUI
import UIKit
import QuickLook

struct LoadDetailView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss
    let load: Load
    @State private var expenses: [Expense] = []

    // Edit / delete state
    @State private var showingEditSheet = false
    @State private var showingDeleteConfirm = false
    @State private var deleteError: String?
    @State private var isDeleting = false

    // Broker contact info loaded lazily so "Share Load Summary" can include
    // phone, extension, email, and last-known MC# without slowing the
    // initial detail render.
    @State private var brokerContact: BrokerContact?
    @State private var weeklyRevenueTotal: Double?

    // Route weather risk along origin → destination. Loaded best-effort in
    // .task; the section hides silently whenever this stays nil (missing API
    // key, geocode failure, offline, etc.). Role-agnostic — works for both
    // Owner-Operator and Carrier since LoadDetailView itself isn't gated.
    @State private var routeRisk: RouteWeatherRisk?

    var totalExpenses: Double { expenses.reduce(0) { $0 + $1.amount } }
    var profit: Double { (load.totalRevenue ?? 0) - totalExpenses }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        if let broker = load.brokerName {
                            Text(broker)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundStyle(Color.spGold)
                        }
                        if let mc = load.brokerMcNumber {
                            Text("MC# \(mc)")
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                        if let dispatchDisplay {
                            Text("Dispatch: \(dispatchDisplay)")
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                    }

                    // Route
                    if let origin = load.origin, let dest = load.destination {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ROUTE")
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                            Text("\(origin) → \(dest)")
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextPrimary)
                                .accessibilityIdentifier("load.detail.route")
                                .accessibilityValue("\(origin) → \(dest)")
                            if let miles = load.totalMiles {
                                Text("\(Int(miles)) miles")
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextSecondary)
                            }
                            if let weight = load.weightDisplay {
                                Text("Weight: \(weight)")
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextSecondary)
                            }
                        }
                    }

                    Divider()
                        .background(Color.spCardBgLight)

                    // Revenue
                    VStack(alignment: .leading, spacing: 8) {
                        Text("REVENUE")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                        detailRow("Line haul", value: load.lineHaulRate)
                        detailRow("Fuel surcharge", value: load.fuelSurcharge)
                        detailRow("Accessorials", value: load.accessorialCharges)
                        Divider()
                            .background(Color.spCardBgLight)
                        HStack {
                            Text("Total Revenue")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.spTextPrimary)
                            Spacer()
                            Text((load.totalRevenue ?? 0).asCurrency)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.spDarkGreen)
                        }
                    }

                    Divider()
                        .background(Color.spCardBgLight)

                    // Expenses
                    VStack(alignment: .leading, spacing: 8) {
                        Text("EXPENSES")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                        if expenses.isEmpty {
                            Text("No expenses recorded")
                                .font(.subheadline)
                                .foregroundStyle(Color.spTextSecondary)
                        } else {
                            ForEach(expenses) { expense in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(expense.category.capitalized)
                                            .foregroundStyle(Color.spTextPrimary)
                                        if let vendor = expense.vendorName {
                                            Text(vendor)
                                                .font(.caption)
                                                .foregroundStyle(Color.spTextSecondary)
                                        }
                                    }
                                    Spacer()
                                    Text(expense.amount.asCurrency)
                                        .foregroundStyle(Color.spDanger)
                                }
                            }
                            Divider()
                                .background(Color.spCardBgLight)
                            HStack {
                                Text("Total Expenses")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.spTextPrimary)
                                Spacer()
                                Text(totalExpenses.asCurrency)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.spDanger)
                            }
                        }
                    }

                    Divider()
                        .background(Color.spCardBgLight)

                    // Profit
                    VStack(spacing: 8) {
                        HStack {
                            Text("PROFIT")
                                .font(.headline)
                                .foregroundStyle(Color.spGold)
                            Spacer()
                            Text(profit.asCurrency)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundStyle(profit >= 0 ? Color.spDarkGreen : Color.spDanger)
                        }
                        if let miles = load.totalMiles, miles > 0 {
                            HStack {
                                Text("Rate/mile")
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextSecondary)
                                Spacer()
                                Text(((load.totalRevenue ?? 0) / miles).asCurrency)
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextPrimary)
                            }
                        }
                    }
                    .padding()
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Route Weather — forecast-driven risk for loads that have
                    // both an origin and a destination. Hidden until data lands.
                    if let risk = routeRisk {
                        routeWeatherSection(risk)
                    }

                    Divider()
                        .background(Color.spCardBgLight)

                    // Paperwork — permanent per-load document vault. Rate cons,
                    // BOL, POD, lumper/fuel/scale receipts, detention, broker docs.
                    if let loadId = load.id {
                        NavigationLink {
                            LoadPaperworkView(loadId: loadId, loadNumber: load.loadNumber)
                                .environmentObject(supabase)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.on.doc.fill")
                                    .foregroundStyle(Color.spGold)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Paperwork")
                                        .font(.headline)
                                        .foregroundStyle(Color.spTextPrimary)
                                    Text("Rate con, BOL, POD, receipts, scale tickets…")
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextSecondary)
                            }
                            .padding()
                            .background(Color.spCardBg)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }

                    // The rate con this load was imported from (on this device), if any.
                    SmartImportedDocumentSection(recordType: .load, recordID: load.id)
                }
                .padding()
            }
            .navigationTitle("Load #\(load.loadNumber ?? "—")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Native iOS share sheet — plain-text load summary. Cleanest
                // placement: dedicated toolbar slot so it works without
                // opening the "..." menu. Long-press still lets the user copy.
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: loadSummaryText()) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(Color.spGold)
                    }
                    .accessibilityLabel("Share Load Summary")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingEditSheet = true
                        } label: {
                            Label("Edit Load", systemImage: "pencil")
                        }
                        ShareLink(item: loadSummaryText()) {
                            Label("Share Load Summary", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label("Delete Load", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Color.spGold)
                    }
                    .accessibilityIdentifier("load.detail.menu")
                    .disabled(isDeleting)
                }
            }
            .sheet(isPresented: $showingEditSheet) {
                ManualLoadEntryView(existingLoad: load)
                    .environmentObject(supabase)
            }
            .confirmationDialog(
                "Delete this load?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Load", role: .destructive) {
                    performDelete()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will permanently remove Load \(load.loadNumber ?? "—") and any expenses or documents attached to it. This cannot be undone.")
            }
            .alert("Couldn't delete load",
                   isPresented: Binding(
                       get: { deleteError != nil },
                       set: { if !$0 { deleteError = nil } }
                   )) {
                Button("OK") { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
            .task {
                if let loadId = load.id {
                    if AppMode.shared.isLocal {
                        expenses = await LocalExpensesRepository.shared.fetch(forLoad: loadId)
                    } else {
                        do { expenses = try await supabase.fetchExpenses(forLoad: loadId) }
                        catch { print("Error loading expenses: \(error)") }
                    }
                }
                await loadBrokerContactIfAvailable()
                await loadWeeklyRevenueTotal()
                await loadRouteWeather()
            }
        }
    }

    // MARK: - Route Weather

    /// Best-effort route-weather assessment for the load's lane. Silent on any
    /// failure (missing OpenWeather key, geocode miss, offline) — the section
    /// simply never appears, matching the app's graceful-degrade pattern.
    private func loadRouteWeather() async {
        guard let origin = load.origin, !origin.isEmpty,
              let destination = load.destination, !destination.isEmpty else { return }
        routeRisk = await RouteWeatherService.shared.assessRoute(fromPlace: origin,
                                                                 toPlace: destination)
    }

    private func routeWeatherSection(_ risk: RouteWeatherRisk) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ROUTE WEATHER")
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                Spacer()
                // Color-coded risk pill: score + level.
                HStack(spacing: 5) {
                    Circle()
                        .fill(riskColor(risk.level))
                        .frame(width: 8, height: 8)
                    Text("\(risk.level.label) · \(risk.score)")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(riskColor(risk.level))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(riskColor(risk.level).opacity(0.12), in: Capsule())
            }

            Text(risk.worstSummary)
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)

            if !risk.roadConditions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(risk.roadConditions) { condition in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: condition.systemImage)
                                .font(.caption)
                                .foregroundStyle(condition.severity.color)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(condition.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.spTextPrimary)
                                Text(condition.driverMessage)
                                    .font(.caption2)
                                    .foregroundStyle(Color.spTextSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func riskColor(_ level: RouteRiskLevel) -> Color {
        switch level {
        case .low:            return .spSuccess
        case .moderate:       return .spWarning
        case .high, .severe:  return .spDanger
        }
    }

    // MARK: - Share Load Summary

    /// Look up the broker's latest contact (phone / email / extension) so
    /// the share text has the info the user actually wants to forward.
    /// Best-effort — failures are silent, summary just omits those lines.
    private func loadBrokerContactIfAvailable() async {
        guard let brokerName = load.brokerName,
              !brokerName.isEmpty else { return }
        do {
            let brokers = try await supabase.fetchBrokers()
            let target = Broker.normalize(brokerName)
            guard let broker = brokers.first(where: {
                ($0.normalizedName ?? Broker.normalize($0.brokerName)) == target
            }), let brokerId = broker.id else { return }
            let contacts = try await supabase.fetchContacts(forBroker: brokerId)
            brokerContact = contacts.first
        } catch {
            // Non-fatal — the summary will fall back to whatever lives on
            // the Load row.
        }
    }

    /// Compute this pay-week's total revenue (across ALL loads, not just
    /// this load). Surfaced at the bottom of the share text as a quick
    /// "for context" footer per the user spec. PICKUP DATE only — single
    /// source of truth per the weekly-grouping spec (2026-05-24).
    private func loadWeeklyRevenueTotal() async {
        do {
            let all = try await supabase.fetchLoads()
            let week = PayWeekService.shared.weekInterval()
            let total = all.reduce(0.0) { acc, l in
                guard PayWeekService.pickupFalls(in: week, pickupDate: l.pickupDate) else { return acc }
                return acc + (l.totalRevenue ?? 0)
            }
            weeklyRevenueTotal = total
        } catch {
            // Non-fatal.
        }
    }

    /// Build the plain-text load summary the share sheet sends. Kept simple
    /// per the user's spec — copy/paste-friendly into Messages, Mail, Slack,
    /// etc. Every section is skipped if its data is missing so the body
    /// stays clean.
    private func loadSummaryText() -> String {
        var lines: [String] = []

        let header = "Load Summary"
        lines.append(header)
        lines.append(String(repeating: "─", count: header.count))

        if let n = load.loadNumber, !n.isEmpty {
            lines.append("Load #: \(n)")
        }
        if let s = load.status, !s.isEmpty {
            lines.append("Status: \(load.loadStatus.displayName)")
        }
        if let broker = load.brokerName, !broker.isEmpty {
            lines.append("Broker: \(broker)")
        }
        if let dispatchDisplay {
            lines.append("Dispatch: \(dispatchDisplay)")
        }
        if let mc = load.brokerMcNumber, !mc.isEmpty {
            lines.append("Broker MC#: \(mc)")
        }
        if let phone = brokerContact?.phone, !phone.isEmpty {
            // Phone may already contain " x4421" extension suffix written by
            // SmartScanReviewView. Render verbatim so the extension is
            // preserved without us splitting + re-joining.
            lines.append("Broker phone: \(phone)")
        }
        if let email = brokerContact?.email, !email.isEmpty {
            lines.append("Broker email: \(email)")
        }

        lines.append("")  // blank line before route block

        if let o = load.origin, !o.isEmpty {
            lines.append("Pickup: \(o)" +
                         (load.pickupDate.map { " · \(formattedDate($0))" } ?? ""))
        }
        if let d = load.destination, !d.isEmpty {
            lines.append("Delivery: \(d)" +
                         (load.deliveryDate.map { " · \(formattedDate($0))" } ?? ""))
        }
        if let miles = load.totalMiles, miles > 0 {
            lines.append("Total miles: \(Int(miles))")
        }
        if let weight = load.weightDisplay {
            lines.append("Weight: \(weight)")
        }

        lines.append("")

        if let rate = load.totalRevenue, rate > 0 {
            lines.append("Rate / Load amount: \(rate.asCurrency)")
        } else if let line = load.lineHaulRate, line > 0 {
            lines.append("Line haul: \(line.asCurrency)")
        }
        if let fsc = load.fuelSurcharge, fsc > 0 {
            lines.append("FSC: \(fsc.asCurrency)")
        }
        if let acc = load.accessorialCharges, acc > 0 {
            lines.append("Accessorials: \(acc.asCurrency)")
        }

        if !expenses.isEmpty {
            lines.append("")
            lines.append("Expenses: \(totalExpenses.asCurrency)")
            lines.append("Profit: \(profit.asCurrency)")
        }

        if let weekly = weeklyRevenueTotal, weekly > 0 {
            lines.append("")
            let weekStart = PayWeekService.shared.weekInterval().start
            lines.append("Pay-week revenue (week of \(formattedDate(weekStart))): \(weekly.asCurrency)")
        }

        lines.append("")
        lines.append("— Sent from Sacred Pathway Driver Hub")

        return lines.joined(separator: "\n")
    }

    private func formattedDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df.string(from: date)
    }

    private var dispatchDisplay: String? {
        let parts = [load.dispatcherName, load.dispatcherCompany]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: " / ")
    }

    private func performDelete() {
        guard let loadId = load.id else { return }
        isDeleting = true
        // Free Local Mode: delete from the on-device store (no cloud round-trip,
        // can't fail on auth/network). LocalLoadsRepository.delete tombstones so
        // the Dashboard Revenue total drops immediately.
        if AppMode.shared.isLocal {
            if LocalLoadsRepository.shared.delete(id: loadId) {
                dismiss()
            } else {
                deleteError = "The load could not be removed from local storage. Your data was left unchanged."
                isDeleting = false
            }
            return
        }
        Task {
            do {
                try await supabase.deleteLoad(id: loadId)
                dismiss()
            } catch {
                deleteError = "Delete failed: \(error.localizedDescription)"
                isDeleting = false
            }
        }
    }

    private func detailRow(_ label: String, value: Double?) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
            Spacer()
            Text((value ?? 0).asCurrency)
                .font(.subheadline)
                .foregroundStyle(Color.spGoldLight)
        }
    }
}

#Preview {
    NavigationStack {
        LoadDetailView(load: Load(
            id: UUID(), profileId: UUID(), loadNumber: "2841",
            brokerName: "XPO Logistics", origin: "Dallas, TX",
            destination: "Houston, TX", totalMiles: 239,
            lineHaulRate: 1650, fuelSurcharge: 150,
            accessorialCharges: 50, totalRevenue: 1850, status: "delivered"
        ))
        .environmentObject(SupabaseService())
    }
}

// =============================================================================
// MARK: - Load Paperwork Vault
// =============================================================================
// Per-load permanent document store. Local-first (works offline + in Free Local
// Mode immediately); cloud sync to the `load_documents` table + `load-documents`
// bucket is a follow-up wired to SUPABASE_DEPLOYMENT.md. Documents persist with
// the load forever — completing/archiving a load never removes them.

enum LoadDocumentType: String, CaseIterable, Identifiable {
    case rateConfirmation = "rate_confirmation"
    case billOfLading     = "bill_of_lading"
    case proofOfDelivery  = "proof_of_delivery"
    case lumperReceipt    = "lumper_receipt"
    case fuelReceipt      = "fuel_receipt"
    case scaleTicket      = "scale_ticket"
    case detention
    case brokerDocument   = "broker_document"
    case other
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .rateConfirmation: return "Rate Confirmation"
        case .billOfLading:     return "Bill of Lading"
        case .proofOfDelivery:  return "Proof of Delivery"
        case .lumperReceipt:    return "Lumper Receipt"
        case .fuelReceipt:      return "Fuel Receipt"
        case .scaleTicket:      return "Scale Ticket"
        case .detention:        return "Detention"
        case .brokerDocument:   return "Broker Document"
        case .other:            return "Other"
        }
    }
    var icon: String {
        switch self {
        case .rateConfirmation: return "doc.text.fill"
        case .billOfLading:     return "shippingbox.fill"
        case .proofOfDelivery:  return "checkmark.seal.fill"
        case .lumperReceipt:    return "person.2.fill"
        case .fuelReceipt:      return "fuelpump.fill"
        case .scaleTicket:      return "scalemass.fill"
        case .detention:        return "clock.badge.exclamationmark.fill"
        case .brokerDocument:   return "envelope.fill"
        case .other:            return "doc.fill"
        }
    }
    static func from(_ raw: String) -> LoadDocumentType { LoadDocumentType(rawValue: raw) ?? .other }
}

struct LoadVaultDocument: Identifiable, Codable {
    let id: UUID
    var fileName: String        // display name
    var storedFileName: String  // on-disk filename
    var documentType: String
    var uploadedAt: Date
}

/// Local on-device vault. Files live under
/// Documents/DriverHub/LoadDocs/<loadId>/, indexed by index.json.
enum LoadDocumentVault {
    private static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("DriverHub/LoadDocs", isDirectory: true)
    }
    private static func dir(_ loadId: UUID) -> URL {
        root.appendingPathComponent(loadId.uuidString, isDirectory: true)
    }
    private static func indexURL(_ loadId: UUID) -> URL {
        dir(loadId).appendingPathComponent("index.json")
    }

    static func documents(for loadId: UUID) -> [LoadVaultDocument] {
        guard let data = try? Data(contentsOf: indexURL(loadId)),
              let list = try? JSONDecoder.sp.decode([LoadVaultDocument].self, from: data) else { return [] }
        return list.sorted { $0.uploadedAt > $1.uploadedAt }
    }

    @discardableResult
    static func add(loadId: UUID, data: Data, fileName: String, type: LoadDocumentType) throws -> LoadVaultDocument {
        let d = dir(loadId)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let id = UUID()
        let rawExt = (fileName as NSString).pathExtension
        let ext = rawExt.isEmpty ? "dat" : rawExt
        let stored = "\(id.uuidString).\(ext)"
        try data.write(to: d.appendingPathComponent(stored), options: .atomic)
        var list = documents(for: loadId)
        let doc = LoadVaultDocument(id: id, fileName: fileName, storedFileName: stored,
                                    documentType: type.rawValue, uploadedAt: Date())
        list.insert(doc, at: 0)
        try JSONEncoder.sp.encode(list).write(to: indexURL(loadId), options: .atomic)
        return doc
    }

    static func fileURL(loadId: UUID, doc: LoadVaultDocument) -> URL {
        dir(loadId).appendingPathComponent(doc.storedFileName)
    }

    static func delete(loadId: UUID, id: UUID) {
        var list = documents(for: loadId)
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: fileURL(loadId: loadId, doc: list[idx]))
        list.remove(at: idx)
        try? JSONEncoder.sp.encode(list).write(to: indexURL(loadId), options: .atomic)
    }
}

private extension JSONEncoder {
    static let sp: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}
private extension JSONDecoder {
    static let sp: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

private struct IdentifiableURL: Identifiable { let id = UUID(); let url: URL }

struct LoadPaperworkView: View {
    @EnvironmentObject var supabase: SupabaseService
    let loadId: UUID
    var loadNumber: String?

    @State private var docs: [LoadVaultDocument] = []
    @State private var selectedType: LoadDocumentType = .rateConfirmation
    @State private var showSource = false
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var preview: IdentifiableURL?
    @State private var share: IdentifiableURL?

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                Section("Add Paperwork") {
                    Picker("Type", selection: $selectedType) {
                        ForEach(LoadDocumentType.allCases) { t in
                            Label(t.displayName, systemImage: t.icon).tag(t)
                        }
                    }
                    .tint(Color.spGold)
                    Button { showSource = true } label: {
                        Label("Add Document", systemImage: "plus.circle.fill")
                            .foregroundStyle(Color.spGold)
                    }
                }
                .listRowBackground(Color.spCardBg)

                Section("Documents (\(docs.count))") {
                    if docs.isEmpty {
                        Text("No paperwork yet. Add a rate con, BOL, POD, or a receipt — it stays with this load forever.")
                            .font(.subheadline)
                            .foregroundStyle(Color.spTextSecondary)
                    } else {
                        ForEach(docs) { doc in
                            Button { preview = IdentifiableURL(url: LoadDocumentVault.fileURL(loadId: loadId, doc: doc)) } label: {
                                docRow(doc)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    LoadDocumentVault.delete(loadId: loadId, id: doc.id); reload()
                                } label: { Label("Delete", systemImage: "trash") }
                                Button {
                                    share = IdentifiableURL(url: LoadDocumentVault.fileURL(loadId: loadId, doc: doc))
                                } label: { Label("Share", systemImage: "square.and.arrow.up") }
                                .tint(Color.spGold)
                            }
                        }
                    }
                }
                .listRowBackground(Color.spCardBg)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Paperwork")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .confirmationDialog("Add a document", isPresented: $showSource, titleVisibility: .visible) {
            Button("Camera") { showCamera = true }
            Button("Photo Library") { showPhotos = true }
            Button("Files (PDF / image)") { showFiles = true }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showCamera) {
            DocumentCameraView(onScan: { imgs in if let i = imgs.first { addImage(i) } }, onCancel: {})
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showPhotos) {
            PhotoPickerView(onPick: { addImage($0) }, onCancel: {})
        }
        .sheet(isPresented: $showFiles) {
            FilePickerView(onPick: { addFile($0) }, onCancel: {})
        }
        .sheet(item: $preview) { item in QuickLookView(url: item.url) }
        .sheet(item: $share) { item in PaperworkShareSheet(items: [item.url]) }
    }

    private func docRow(_ doc: LoadVaultDocument) -> some View {
        let type = LoadDocumentType.from(doc.documentType)
        return HStack(spacing: 12) {
            Image(systemName: type.icon).foregroundStyle(Color.spGold).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.fileName).foregroundStyle(Color.spTextPrimary).lineLimit(1)
                Text("\(type.displayName) · \(doc.uploadedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(Color.spTextSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.spTextSecondary)
        }
    }

    private func reload() { docs = LoadDocumentVault.documents(for: loadId) }

    private func timestampName(ext: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(selectedType.displayName.replacingOccurrences(of: " ", with: ""))-\(f.string(from: Date())).\(ext)"
    }

    private func addImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        _ = try? LoadDocumentVault.add(loadId: loadId, data: data, fileName: timestampName(ext: "jpg"), type: selectedType)
        reload()
    }

    private func addFile(_ picked: PickedDocument) {
        if let data = picked.originalData {
            let ext = (picked.mimeType?.contains("pdf") ?? false) ? "pdf" : "dat"
            _ = try? LoadDocumentVault.add(loadId: loadId, data: data, fileName: timestampName(ext: ext), type: selectedType)
        } else if let data = picked.image.jpegData(compressionQuality: 0.85) {
            _ = try? LoadDocumentVault.add(loadId: loadId, data: data, fileName: timestampName(ext: "jpg"), type: selectedType)
        }
        reload()
    }
}

// QuickLook preview for any stored file (PDF, image, etc.).
private struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController(); c.dataSource = context.coordinator; return c
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

private struct PaperworkShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
