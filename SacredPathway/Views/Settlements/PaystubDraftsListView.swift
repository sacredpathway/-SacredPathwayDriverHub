import SwiftUI

struct PaystubDraftsListView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var drafts: [PaystubDraft] = []
    @State private var selectedDraft: PaystubDraft?
    @State private var showingEditor = false
    @State private var showingDeleteAlert = false
    @State private var draftToDelete: PaystubDraft?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            if drafts.isEmpty {
                emptyState
            } else {
                draftsList
            }
        }
        .navigationTitle("Payroll Drafts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    selectedDraft = nil
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.spGold)
                }
            }
        }
        .onAppear { refreshDrafts() }
        .sheet(isPresented: $showingEditor, onDismiss: { refreshDrafts() }) {
            ManualPaystubView(existingDraft: selectedDraft)
                .environmentObject(supabase)
        }
        .alert("Delete Draft?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let draft = draftToDelete {
                    try? DraftStorageService.shared.deleteDraft(id: draft.id)
                    refreshDrafts()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This draft will be permanently removed.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 50))
                .foregroundStyle(Color.spGold.opacity(0.5))
            Text("No Drafts")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
            Text("Start a paystub and save it as a draft to come back later.")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                selectedDraft = nil
                showingEditor = true
            } label: {
                Label("Create New Paystub", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 24)
                    .background(Color.spGold)
                    .foregroundStyle(Color.spBlack)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 8)
        }
    }

    private var draftsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(drafts) { draft in
                    draftCard(draft)
                }
            }
            .padding()
        }
    }

    private func draftCard(_ draft: PaystubDraft) -> some View {
        Button {
            selectedDraft = draft
            showingEditor = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(Color.spGold)
                    Text(draft.name)
                        .font(.headline)
                        .foregroundStyle(Color.spTextPrimary)
                    Spacer()

                    Button {
                        draftToDelete = draft
                        showingDeleteAlert = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(Color.spDanger.opacity(0.7))
                    }
                }

                HStack(spacing: 16) {
                    if !draft.driverName.isEmpty {
                        Label(draft.driverName, systemImage: "person.fill")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                    }
                    Text(draft.summary)
                        .font(.caption)
                        .foregroundStyle(Color.spGold)
                }

                HStack {
                    Text("Last edited: \(dateFormatter.string(from: draft.updatedAt))")
                        .font(.caption2)
                        .foregroundStyle(Color.spTextSecondary.opacity(0.7))
                    Spacer()
                    Text("DRAFT")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.spGold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.spGold.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding()
            .background(Color.spCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func refreshDrafts() {
        drafts = DraftStorageService.shared.loadAllDrafts()
    }
}
