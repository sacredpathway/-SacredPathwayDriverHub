import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct AddComplianceDocumentView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) var dismiss

    @State private var category: String = "company"
    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var issueDate: Date? = nil
    @State private var expirationDate: Date? = nil
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedFileURL: URL? = nil
    @State private var showFileImporter = false
    @State private var useIssueDate = false
    @State private var useExpirationDate = false
    @State private var isSaving = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        categorySection
                        titleSection
                        notesSection
                        issueDateSection
                        expirationDateSection
                        attachmentSection
                        errorBanner
                        saveButton
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Add Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.spGold)
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf], onCompletion: handleFileSelection)
            .onChange(of: selectedPhotoItem) { _, item in
                Task {
                    if let item = item,
                       let data = try? await item.loadTransferable(type: Data.self) {
                        selectedFileURL = URL(fileURLWithPath: NSTemporaryDirectory() + UUID().uuidString + ".jpg")
                        try? data.write(to: selectedFileURL!)
                    }
                }
            }
        }
    }

    // MARK: - Sections (extracted to keep type-checker happy)

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Category", icon: "tag.fill")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(["company", "truck", "trailer", "driver"], id: \.self) { cat in
                        categoryChip(cat)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func categoryChip(_ cat: String) -> some View {
        Group {
            if let catEnum = ComplianceCategory(rawValue: cat) {
                Button {
                    withAnimation { category = cat }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: catEnum.iconName).font(.title3)
                        Text(catEnum.displayName).font(.caption2.weight(.semibold))
                    }
                    .frame(width: 70, height: 60)
                    .background(category == cat ? Color.spGold.opacity(0.2) : Color.spCardBg)
                    .foregroundStyle(category == cat ? Color.spGold : Color.spTextSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(category == cat ? Color.spGold : Color.clear, lineWidth: 1.5)
                    )
                }
            }
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Document Title", icon: "doc.text.fill")
            TextField("e.g., MC Authority Letter", text: $title)
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
                .padding(12)
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Notes", icon: "note.text")
            TextEditor(text: $notes)
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
                .scrollContentBackground(.hidden)
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(minHeight: 80)
                .padding(.horizontal)
        }
    }

    private var issueDateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $useIssueDate) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").foregroundStyle(Color.spGold)
                    Text("Issue Date")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                }
            }
            .tint(Color.spGold)
            .padding(.horizontal)

            if useIssueDate {
                DatePicker("Issue Date",
                    selection: Binding(get: { issueDate ?? Date() }, set: { issueDate = $0 }),
                    displayedComponents: .date
                )
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
                .padding(12)
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
            }
        }
    }

    private var expirationDateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $useExpirationDate) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .foregroundStyle(Color.spWarning)
                    Text("Expiration Date")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                }
            }
            .tint(Color.spGold)
            .padding(.horizontal)

            if useExpirationDate {
                DatePicker("Expiration Date",
                    selection: Binding(get: { expirationDate ?? Date() }, set: { expirationDate = $0 }),
                    displayedComponents: .date
                )
                .font(.subheadline)
                .foregroundStyle(Color.spTextPrimary)
                .padding(12)
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
            }
        }
    }

    private var attachmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Attachment (Optional)", icon: "paperclip")
            HStack(spacing: 10) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    attachmentButtonLabel(text: "Photo", icon: "photo.fill")
                }
                Button(action: { showFileImporter = true }) {
                    attachmentButtonLabel(text: "PDF", icon: "doc.fill")
                }
            }
            .padding(.horizontal)

            if selectedFileURL != nil || selectedPhotoItem != nil {
                Text("File selected")
                    .font(.caption)
                    .foregroundStyle(Color.spSuccess)
                    .padding(.horizontal)
            }
        }
    }

    private func attachmentButtonLabel(text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.spCardBg)
            .foregroundStyle(Color.spTextPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(Color.spDanger)
                .padding(.horizontal)
        }
    }

    private var saveButton: some View {
        Button {
            Task { await saveDocument() }
        } label: {
            saveButtonLabel
        }
        .background(Color.spGold)
        .foregroundStyle(Color.spBlack)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .disabled(isSaving || title.isEmpty)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var saveButtonLabel: some View {
        if isSaving {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        } else {
            Text("Add Document")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(Color.spGold)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
        }
        .padding(.horizontal)
    }

    private func handleFileSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let pickedURL):
            // Files picked from iCloud Drive / Files.app are security-scoped.
            // We must startAccessingSecurityScopedResource BEFORE reading, then
            // copy the bytes into our own sandbox so saveDocument() (which runs
            // later, after the scope has been released) can still read them.
            let didStart = pickedURL.startAccessingSecurityScopedResource()
            defer { if didStart { pickedURL.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: pickedURL)
                let ext = pickedURL.pathExtension.isEmpty ? "pdf" : pickedURL.pathExtension
                let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                try data.write(to: tempURL)
                selectedFileURL = tempURL
                errorMessage = nil
            } catch {
                errorMessage = "Couldn't read that file. Try saving it to On My iPhone and picking it again."
                #if DEBUG
                print("[AddComplianceDocumentView] file import failed: \(error)")
                #endif
            }

        case .failure(let error):
            #if DEBUG
            print("[AddComplianceDocumentView] file importer cancelled/failed: \(error)")
            #endif
        }
    }

    private func saveDocument() async {
        guard !title.isEmpty else {
            errorMessage = "Title is required"
            return
        }

        guard let profileId = supabase.currentProfile?.id else {
            errorMessage = "Not signed in"
            return
        }

        isSaving = true
        errorMessage = nil

        do {
            var doc = ComplianceDocument(
                profileId: profileId,
                category: category,
                title: title,
                issueDate: useIssueDate ? issueDate : nil,
                expirationDate: useExpirationDate ? expirationDate : nil,
                notes: notes.isEmpty ? nil : notes
            )

            // Upload file if selected
            if let fileURL = selectedFileURL {
                let fileData = try Data(contentsOf: fileURL)
                let mimeType = fileURL.pathExtension.lowercased() == "pdf" ? "application/pdf" : "image/jpeg"
                doc.fileMimeType = mimeType
                doc.fileSize = fileData.count
                doc.storagePath = try await supabase.uploadComplianceFile(fileData, mimeType: mimeType)
            }

            _ = try await supabase.createComplianceDocument(doc)
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(String(describing: error))"
            #if DEBUG
            print("[AddComplianceDocumentView] save failed: \(error)")
            #endif
        }

        isSaving = false
    }
}

#Preview {
    AddComplianceDocumentView().environmentObject(SupabaseService())
}
