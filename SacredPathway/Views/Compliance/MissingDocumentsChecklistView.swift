import SwiftUI

struct MissingDocumentsChecklistView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var documents: [ComplianceDocument] = []
    @State private var isLoading = true

    let requiredByCategory: [String: [String]] = [
        "company": [
            "MC Authority Letter",
            "DOT Certificate of Registration",
            "Operating Authority",
            "UCR Registration",
            "SCAC Code"
        ],
        "truck": [
            "Registration",
            "Cab Card",
            "Insurance",
            "IFTA Sticker",
            "Annual DOT Inspection"
        ],
        "trailer": [
            "Registration",
            "Annual Inspection",
            "Insurance"
        ],
        "driver": [
            "CDL",
            "Medical Card (DOT Physical)",
            "MVR (Motor Vehicle Record)",
            "Drug Test Results",
            "PSP Report"
        ]
    ]

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(Color.spGold)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(["company", "truck", "trailer", "driver"], id: \.self) { category in
                            categorySection(for: category)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Missing Documents")
        .task { await loadDocuments() }
    }

    private func categorySection(for category: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let catEnum = ComplianceCategory(rawValue: category) {
                    Image(systemName: catEnum.iconName)
                        .foregroundStyle(Color.spGold)
                    Text(catEnum.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                }
            }

            VStack(spacing: 8) {
                ForEach(requiredByCategory[category] ?? [], id: \.self) { doc in
                    checklistItem(title: doc, category: category)
                }
            }
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func checklistItem(title: String, category: String) -> some View {
        let hasDoc = documents.contains { doc in
            doc.category == category && doc.title.lowercased().contains(title.lowercased())
        }

        return HStack(spacing: 12) {
            Image(systemName: hasDoc ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(hasDoc ? Color.spSuccess : Color.spTextSecondary)
                .font(.title3)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(hasDoc ? Color.spSuccess : Color.spTextPrimary)
                .strikethrough(hasDoc)

            Spacer()

            if hasDoc {
                Text("Added")
                    .font(.caption)
                    .foregroundStyle(Color.spSuccess)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.spBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        MissingDocumentsChecklistView().environmentObject(SupabaseService())
    }
}
