import SwiftUI
import UIKit

struct ComplianceDocumentDetailView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) var dismiss
    @State var document: ComplianceDocument
    @State private var isDeleting = false
    @State private var showDeleteConfirm = false

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    // Header card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            if let category = ComplianceCategory(rawValue: document.category) {
                                Image(systemName: category.iconName)
                                    .font(.title2)
                                    .foregroundStyle(Color.spGold)
                                    .frame(width: 40)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(document.title)
                                    .font(.headline)
                                    .foregroundStyle(Color.spTextPrimary)
                                if let category = ComplianceCategory(rawValue: document.category) {
                                    Text(category.displayName)
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                }
                            }

                            Spacer()

                            let status = document.status()
                            VStack(spacing: 4) {
                                Text(status.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(status.color)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding()
                        .background(Color.spCardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)

                    // Details section
                    VStack(alignment: .leading, spacing: 16) {
                        detailRow("Category", value: ComplianceCategory(rawValue: document.category)?.displayName ?? document.category)

                        if let issueDate = document.issueDate {
                            detailRow("Issue Date", value: issueDate, style: .date)
                        }

                        if let expDate = document.expirationDate {
                            detailRow("Expiration Date", value: expDate, style: .date)
                        }

                        if let notes = document.notes, !notes.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Notes")
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextSecondary)
                                Text(notes)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.spTextPrimary)
                            }
                        }

                        if let fileSize = document.fileSize {
                            detailRow("File Size", value: formatBytes(fileSize))
                        }
                    }
                    .padding()
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                    // Action buttons
                    if document.storagePath != nil {
                        Button(action: viewFile) {
                            HStack {
                                Image(systemName: "eye.fill")
                                Text("View File")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.spGold)
                            .foregroundStyle(Color.spBlack)
                            .font(.headline)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .padding(.horizontal)
                    }

                    Button(role: .destructive, action: { showDeleteConfirm = true }) {
                        HStack {
                            Image(systemName: "trash.fill")
                            Text("Delete Document")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.spDanger.opacity(0.2))
                        .foregroundStyle(Color.spDanger)
                        .font(.headline)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(.horizontal)

                    Spacer()
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("Document")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete this document?",
            isPresented: $showDeleteConfirm,
            actions: {
                Button("Delete", role: .destructive) {
                    performDelete()
                }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text("This action cannot be undone.")
            }
        )
    }

    private func detailRow(_ label: String, value: Date, style: Text.DateStyle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
            Text(value, style: style)
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
        }
    }

    private func viewFile() {
        guard let path = document.storagePath else { return }
        Task {
            do {
                let url = try await supabase.signedURLForCompliance(path)
                DispatchQueue.main.async {
                    UIApplication.shared.open(url)
                }
            } catch {
                print("Error generating signed URL: \(error)")
            }
        }
    }

    private func performDelete() {
        guard let docId = document.id else { return }
        isDeleting = true

        Task {
            do {
                try await supabase.deleteComplianceDocument(id: docId)
                dismiss()
            } catch {
                print("Error deleting document: \(error)")
                isDeleting = false
            }
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

#Preview {
    NavigationStack {
        ComplianceDocumentDetailView(
            document: ComplianceDocument(
                profileId: UUID(),
                category: "truck",
                title: "Annual DOT Inspection"
            )
        )
        .environmentObject(SupabaseService())
    }
}
