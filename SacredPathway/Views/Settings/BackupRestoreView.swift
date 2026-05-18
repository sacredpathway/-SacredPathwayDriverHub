import SwiftUI
import UniformTypeIdentifiers

// =============================================================================
//  BackupRestoreView — Free Local Mode export / import UI
// -----------------------------------------------------------------------------
//  Shown from Settings → Local Mode → Backup & Restore. Two flows:
//
//   Export
//     1. Tap "Export Backup"
//     2. BackupService writes a temp .driverhub-backup file
//     3. ShareLink presents the iOS share sheet (AirDrop, Save to Files,
//        Mail, iCloud Drive, …)
//
//   Import
//     1. Tap "Import Backup"
//     2. fileImporter pops the iOS file picker
//     3. We decode JUST the manifest and show a confirmation sheet with
//        timestamp / device / counts
//     4. User confirms → BackupService.importBackup() runs and replaces
//        every local repo. Errors surface as alerts.
//
//  No cloud calls. Visible only when AppMode.isLocal.
// =============================================================================

struct BackupRestoreView: View {

    @ObservedObject private var appMode = AppMode.shared
    @ObservedObject private var loads    = LocalLoadsRepository.shared
    @ObservedObject private var brokers  = LocalBrokersRepository.shared
    @ObservedObject private var contacts = LocalBrokerContactsRepository.shared
    @ObservedObject private var expenses = LocalExpensesRepository.shared

    // MARK: - State

    @State private var exportItem: ExportItem?
    @State private var showingImporter = false
    @State private var pendingImportURL: URL?
    @State private var pendingImportManifest: BackupService.Manifest?
    @State private var showImportConfirm = false
    @State private var alertItem: AlertItem?

    private struct ExportItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    private struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    overviewCard
                    exportCard
                    importCard
                    disclaimerCard
                }
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.spBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(item: $exportItem) { item in
            ShareSheetCompat(activityItems: [item.url]) {
                exportItem = nil
                // Clear the temp file once the share dismisses, win or lose.
                BackupService.cleanupTempExports()
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json, .data, .item],
            allowsMultipleSelection: false
        ) { result in
            handleImporterResult(result)
        }
        .confirmationDialog(
            "Replace local data with this backup?",
            isPresented: $showImportConfirm,
            titleVisibility: .visible,
            presenting: pendingImportManifest
        ) { manifest in
            Button("Replace Local Data", role: .destructive) {
                applyImport(manifest: manifest)
            }
            Button("Cancel", role: .cancel) {
                pendingImportURL = nil
                pendingImportManifest = nil
            }
        } message: { manifest in
            Text(importPreviewMessage(for: manifest))
        }
        .alert(item: $alertItem) { item in
            Alert(title: Text(item.title),
                  message: Text(item.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    // MARK: - Overview

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .foregroundStyle(Color.spGold)
                Text("Free Local Mode")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
            }
            Text("Data saved on this device only. A backup file gives you a copy you can move to another iPhone, store in iCloud Drive, or email yourself.")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().background(Color.spGold.opacity(0.2))

            HStack {
                statPill(label: "Loads",    value: loads.loads.count)
                statPill(label: "Brokers",  value: brokers.brokers.count)
                statPill(label: "Contacts", value: contacts.contacts.count)
                statPill(label: "Expenses", value: expenses.expenses.count)
            }
        }
        .padding(16)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func statPill(label: String, value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.spGold)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.spCardBgLight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Export

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Export Backup", systemImage: "square.and.arrow.up")
                .font(.headline)
                .foregroundStyle(Color.spTextPrimary)
            Text("Save a single `.driverhub-backup` file with every load, broker, contact, and expense on this iPhone, plus your preferences.")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
            Button(action: performExport) {
                Text("Export Backup")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.spGold)
                    .foregroundStyle(Color.spBlack)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func performExport() {
        do {
            let url = try BackupService.exportToTempFile()
            exportItem = ExportItem(url: url)
        } catch {
            alertItem = AlertItem(
                title: "Export Failed",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Import

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Import Backup", systemImage: "square.and.arrow.down")
                .font(.headline)
                .foregroundStyle(Color.spTextPrimary)
            Text("Pick a `.driverhub-backup` file from Files, iCloud Drive, or AirDrop. Your current local data will be replaced after you confirm.")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
            Button {
                showingImporter = true
            } label: {
                Text("Import Backup")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.spCardBgLight)
                    .foregroundStyle(Color.spGold)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.spGold, lineWidth: 1.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func handleImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            alertItem = AlertItem(
                title: "Couldn't Open File",
                message: err.localizedDescription
            )
        case .success(let urls):
            guard let url = urls.first else { return }
            // Copy the picked file into our own temp directory so the
            // security-scoped URL doesn't expire underneath us between
            // the manifest preview and the user's confirmation tap.
            do {
                let tempURL = try copyToLocalTemp(url)
                let manifest = try BackupService.validate(at: tempURL)
                pendingImportURL = tempURL
                pendingImportManifest = manifest
                showImportConfirm = true
            } catch {
                alertItem = AlertItem(
                    title: "Backup Couldn't Be Read",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func copyToLocalTemp(_ source: URL) throws -> URL {
        let scope = source.startAccessingSecurityScopedResource()
        defer { if scope { source.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-import-\(UUID().uuidString).\(BackupService.fileExtension)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    private func applyImport(manifest: BackupService.Manifest) {
        guard let url = pendingImportURL else {
            alertItem = AlertItem(
                title: "Import Failed",
                message: "The selected file is no longer available."
            )
            return
        }
        do {
            let restored = try BackupService.importBackup(from: url)
            try? FileManager.default.removeItem(at: url)
            pendingImportURL = nil
            pendingImportManifest = nil
            alertItem = AlertItem(
                title: "Backup Imported",
                message: importSuccessMessage(for: restored)
            )
        } catch {
            alertItem = AlertItem(
                title: "Import Failed",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Helpers

    private func importPreviewMessage(for m: BackupService.Manifest) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let ts = f.string(from: m.backupTimestamp)
        return """
        Backup taken \(ts) on \(m.deviceName).

        Will replace your current local data with:
        \(m.counts.loads) loads
        \(m.counts.brokers) brokers
        \(m.counts.brokerContacts) broker contacts
        \(m.counts.expenses) expenses

        This cannot be undone. Export your current data first if you want a safety copy.
        """
    }

    private func importSuccessMessage(for m: BackupService.Manifest) -> String {
        "Restored \(m.counts.loads) loads, \(m.counts.brokers) brokers, \(m.counts.brokerContacts) broker contacts, and \(m.counts.expenses) expenses."
    }

    // MARK: - Disclaimer

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Important", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.spGold)
            Text("If you delete Driver Hub from this iPhone without exporting a backup first, the local data is gone. iOS does not include app sandboxes in iCloud Backup by default.")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

// MARK: - ShareSheet bridge

/// UIKit bridge to UIActivityViewController. We use this instead of
/// SwiftUI's `ShareLink` so the sheet stays present long enough for the
/// user to pick AirDrop / Files / Mail without the parent view recomputing
/// the temp file URL. `onComplete` fires when the sheet is dismissed
/// regardless of outcome.
private struct ShareSheetCompat: UIViewControllerRepresentable {
    let activityItems: [Any]
    var onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: activityItems,
                                          applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                context: Context) {}
}

#Preview {
    NavigationStack { BackupRestoreView() }
}
