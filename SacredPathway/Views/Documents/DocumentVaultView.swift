import SwiftUI

struct DocumentVaultView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var documents: [TruckDocument] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var filterType: String? = nil

    private let docTypes = [
        "paystub",
        "ifta_report",
        "settlement",
        "rate_confirmation",
        "fuel_receipt",
        "lumper_fee",
        "toll",
        "repair",
        "bol",
        "invoice",
        "compliance"
    ]

    var filteredDocuments: [TruckDocument] {
        var result = documents
        if let filter = filterType {
            result = result.filter { $0.documentType?.lowercased() == filter }
        }
        if !searchText.isEmpty {
            result = result.filter { doc in
                let data = doc.extractedData
                let searchable = [
                    data?.brokerName,
                    data?.loadNumber,
                    data?.origin,
                    data?.destination,
                    data?.vendorName,
                    data?.notes, // saveDocumentRecord stores the title here
                    doc.documentType
                ].compactMap { $0 }.joined(separator: " ").lowercased()
                return searchable.contains(searchText.lowercased())
            }
        }
        return result
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            NavigationStack {
                VStack(spacing: 0) {
                    // Search bar
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color.spTextSecondary)
                        TextField("Search documents...", text: $searchText)
                            .foregroundStyle(Color.spTextPrimary)
                    }
                    .padding(10)
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                    .padding(.top, 8)

                    // Type filter
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterChip("All", type: nil)
                            ForEach(docTypes, id: \.self) { type in
                                filterChip(docTypeLabel(type), type: type)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }

                    if isLoading {
                        Spacer()
                        ProgressView().tint(Color.spGold)
                        Spacer()
                    } else if filteredDocuments.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 48)).foregroundStyle(Color.spTextSecondary)
                            Text("No documents").font(.headline).foregroundStyle(Color.spTextSecondary)
                            Text("Scanned and uploaded documents will appear here")
                                .font(.subheadline).foregroundStyle(Color.spTextSecondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                        }
                        Spacer()
                    } else {
                        List {
                            ForEach(filteredDocuments) { doc in
                                documentRow(doc).listRowBackground(Color.spCardBg)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
                .navigationTitle("Document Vault")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("\(filteredDocuments.count) docs")
                            .font(.caption).foregroundStyle(Color.spTextSecondary)
                    }
                }
                .task { await loadDocuments() }
            }
        }
    }

    private func documentRow(_ doc: TruckDocument) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(docTypeColor(doc.documentType ?? "").opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: docTypeIcon(doc.documentType ?? ""))
                    .foregroundStyle(docTypeColor(doc.documentType ?? ""))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(docTypeLabel(doc.documentType ?? "unknown"))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.spTextPrimary)
                // Generated PDFs (paystubs, IFTA reports) store their
                // human-readable title in extractedData.notes; show that
                // when there's no broker / load number to display.
                if let notes = doc.extractedData?.notes,
                   doc.extractedData?.brokerName == nil,
                   doc.extractedData?.loadNumber == nil {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let broker = doc.extractedData?.brokerName {
                        Text(broker).font(.caption).foregroundStyle(Color.spTextSecondary)
                    }
                    if let loadNum = doc.extractedData?.loadNumber {
                        Text("#\(loadNum)").font(.caption).foregroundStyle(Color.spGold)
                    }
                }
                if let date = doc.createdAt {
                    Text(date, style: .date).font(.caption2).foregroundStyle(Color.spTextSecondary)
                }
            }
            Spacer()
            if let conf = doc.confidence {
                Text(conf.capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(confidenceColor(conf).opacity(0.2))
                    .foregroundStyle(confidenceColor(conf))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    private func filterChip(_ title: String, type: String?) -> some View {
        Button {
            withAnimation { filterType = type }
        } label: {
            Text(title).font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(filterType == type ? Color.spGold : Color.spCardBg)
                .foregroundStyle(filterType == type ? Color.spBlack : Color.spTextPrimary)
                .clipShape(Capsule())
        }
    }

    private func loadDocuments() async {
        do { documents = try await supabase.fetchDocuments() } catch { print("Error: \(error)") }
        isLoading = false
    }

    private func docTypeLabel(_ type: String) -> String {
        switch type.lowercased() {
        case "paystub": return "Paystub"
        case "ifta_report": return "IFTA"
        case "settlement": return "Settlement"
        case "rate_confirmation": return "Rate Con"
        case "fuel_receipt": return "Fuel Receipt"
        case "lumper_fee": return "Lumper"
        case "toll": return "Toll"
        case "repair": return "Repair"
        case "bol": return "BOL"
        case "invoice": return "Invoice"
        case "compliance": return "Compliance"
        default: return type.capitalized
        }
    }

    private func docTypeIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "paystub": return "doc.text.fill"
        case "ifta_report": return "fuelpump.fill"
        case "settlement": return "creditcard.fill"
        case "rate_confirmation": return "doc.text.fill"
        case "fuel_receipt": return "fuelpump.fill"
        case "lumper_fee": return "person.2.fill"
        case "toll": return "road.lanes"
        case "repair": return "wrench.and.screwdriver.fill"
        case "bol": return "shippingbox.fill"
        case "invoice": return "doc.richtext.fill"
        case "compliance": return "checkmark.shield.fill"
        default: return "doc.fill"
        }
    }

    private func docTypeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "paystub": return .spGold
        case "ifta_report": return Color(red: 0.2, green: 0.7, blue: 0.4)
        case "settlement": return Color(red: 0.4, green: 0.8, blue: 0.6)
        case "rate_confirmation": return .spGold
        case "fuel_receipt": return Color(red: 0.2, green: 0.6, blue: 0.9)
        case "lumper_fee": return Color(red: 0.8, green: 0.5, blue: 0.2)
        case "toll": return Color(red: 0.6, green: 0.4, blue: 0.8)
        case "repair": return .spDanger
        case "compliance": return Color(red: 0.5, green: 0.7, blue: 0.9)
        default: return .spTextSecondary
        }
    }

    private func confidenceColor(_ conf: String) -> Color {
        switch conf.lowercased() {
        case "high": return .spSuccess
        case "medium": return .spWarning
        default: return .spDanger
        }
    }
}
