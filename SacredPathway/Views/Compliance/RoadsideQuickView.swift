import SwiftUI
import UIKit

struct RoadsideQuickView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) var dismiss
    let documents: [ComplianceDocument]

    var criticalDocuments: [ComplianceDocument] {
        documents
            .filter { ["truck", "driver", "trailer"].contains($0.category) }
            .sorted { d1, d2 in
                let status1 = d1.status()
                let status2 = d2.status()

                let statusOrder: [ComplianceStatus] = [.expired, .expiringSoon, .valid, .noExpiration]
                let idx1 = statusOrder.firstIndex { $0 == status1 } ?? 999
                let idx2 = statusOrder.firstIndex { $0 == status2 } ?? 999

                return idx1 < idx2
            }
    }

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with close button
                HStack {
                    Text("Critical Docs")
                        .font(.headline)
                        .foregroundStyle(Color.spTextPrimary)

                    Spacer()

                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.spGold)
                    }
                }
                .padding()
                .background(Color.spCardBg)

                if criticalDocuments.isEmpty {
                    VStack {
                        Text("No truck, driver, or trailer documents")
                            .foregroundStyle(Color.spTextSecondary)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(criticalDocuments) { doc in
                                roadsideDocCard(doc)
                            }
                        }
                        .padding()
                    }
                }
            }
        }
    }

    private func roadsideDocCard(_ doc: ComplianceDocument) -> some View {
        Button(action: { openDocument(doc) }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if let category = ComplianceCategory(rawValue: doc.category) {
                        Image(systemName: category.iconName)
                            .font(.title)
                            .foregroundStyle(Color.spGold)
                            .frame(width: 50)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(doc.title)
                            .font(.headline)
                            .foregroundStyle(Color.spTextPrimary)
                        if let expDate = doc.expirationDate {
                            Text("Expires: \(expDate, style: .date)")
                                .font(.caption)
                                .foregroundStyle(Color.spTextSecondary)
                        }
                    }

                    Spacer()

                    let status = doc.status()
                    Text(status.label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(status.color)
                        .clipShape(Capsule())
                }

                if doc.storagePath != nil {
                    HStack {
                        Image(systemName: "eye.fill")
                            .font(.caption)
                        Text("Tap to view")
                            .font(.caption)
                    }
                    .foregroundStyle(Color.spGold)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    /// Generate a short-lived signed URL for the document's file and open it
    /// in Safari. If the doc has no file attached, silently no-op — the user
    /// can still read the title/expiration info on the card.
    private func openDocument(_ doc: ComplianceDocument) {
        guard let path = doc.storagePath, !path.isEmpty else { return }
        Task {
            do {
                let url = try await supabase.signedURLForCompliance(path)
                await MainActor.run { UIApplication.shared.open(url) }
            } catch {
                #if DEBUG
                print("[RoadsideQuickView] signed URL failed: \(error)")
                #endif
            }
        }
    }
}

#Preview {
    RoadsideQuickView(documents: [])
        .environmentObject(SupabaseService())
}
