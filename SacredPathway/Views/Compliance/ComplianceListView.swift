import SwiftUI

struct ComplianceListView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var documents: [ComplianceDocument] = []
    @State private var selectedCategory: String? = nil
    @State private var isLoading = true

    private let categories = ["company", "truck", "trailer", "driver"]

    var filteredDocuments: [ComplianceDocument] {
        if let cat = selectedCategory {
            return documents.filter { $0.category == cat }
        }
        return documents
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Category filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        categoryChip("All", category: nil)
                        ForEach(categories, id: \.self) { cat in
                            if let catEnum = ComplianceCategory(rawValue: cat) {
                                categoryChip(catEnum.displayName, category: cat)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }

                if isLoading {
                    Spacer()
                    ProgressView()
                        .tint(Color.spGold)
                    Spacer()
                } else if filteredDocuments.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.spTextSecondary)
                        Text("No documents")
                            .font(.headline)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(filteredDocuments) { doc in
                            NavigationLink(destination: ComplianceDocumentDetailView(document: doc)) {
                                documentRow(doc)
                            }
                            .listRowBackground(Color.spCardBg)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Documents")
            .task { await loadDocuments() }
        }
    }

    private func categoryChip(_ title: String, category: String?) -> some View {
        Button {
            withAnimation { selectedCategory = category }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selectedCategory == category ? Color.spGold : Color.spCardBg)
                .foregroundStyle(selectedCategory == category ? Color.spBlack : Color.spTextPrimary)
                .clipShape(Capsule())
        }
    }

    private func documentRow(_ doc: ComplianceDocument) -> some View {
        HStack(spacing: 12) {
            if let category = ComplianceCategory(rawValue: doc.category) {
                Image(systemName: category.iconName)
                    .font(.title3)
                    .foregroundStyle(Color.spGold)
                    .frame(width: 40)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(doc.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                HStack(spacing: 8) {
                    if let cat = ComplianceCategory(rawValue: doc.category) {
                        Text(cat.displayName)
                            .font(.caption)
                            .foregroundStyle(Color.spGold)
                    }
                    if let expDate = doc.expirationDate {
                        Text(expDate, style: .date)
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                }
            }

            Spacer()

            let status = doc.status()
            VStack(alignment: .trailing, spacing: 4) {
                Text(status.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(status.color)
            }
        }
        .padding(.vertical, 4)
    }

    private func loadDocuments() async {
        do {
            documents = try await supabase.fetchComplianceDocuments()
        } catch {
            print("Error loading documents: \(error)")
        }
        isLoading = false
    }
}

#Preview {
    NavigationStack {
        ComplianceListView().environmentObject(SupabaseService())
    }
}
