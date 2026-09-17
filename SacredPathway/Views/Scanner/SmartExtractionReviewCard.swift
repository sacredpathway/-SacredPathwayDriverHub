import SwiftUI
import UIKit

// =============================================================================
// MARK: - SmartExtractionReviewCard
// -----------------------------------------------------------------------------
// Shown above the editable form after a document import. Lists what was read,
// how sure the reader is, what needs attention, possible duplicates, and any
// value the user typed that differs from the document. Nothing here saves or
// overwrites anything by itself — every change is an explicit tap.
// =============================================================================

struct SmartConfidenceBadge: View {
    let confidence: ExtractionConfidence

    private var color: Color {
        switch confidence {
        case .high: return Color.spGreenAccent
        case .medium: return Color.spGold
        case .low: return Color.spWarning
        case .missing: return Color.spTextSecondary
        }
    }

    private var icon: String {
        switch confidence {
        case .high: return "checkmark.circle.fill"
        case .medium: return "eye.fill"
        case .low: return "exclamationmark.triangle.fill"
        case .missing: return "questionmark.circle"
        }
    }

    var body: some View {
        Label(confidence.label, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
            .accessibilityLabel("Confidence: \(confidence.label)")
    }
}

/// Inline hint under an auto-filled field that needs a look.
struct SmartFieldHint: View {
    let confidence: ExtractionConfidence?

    var body: some View {
        if let confidence, confidence.needsReview {
            HStack(spacing: 4) {
                Image(systemName: confidence == .low ? "exclamationmark.triangle.fill" : "eye.fill")
                Text(confidence == .low ? "Hard to read on the document — check this value." : "Filled from the document — review it.")
            }
            .font(.caption2)
            .foregroundStyle(confidence == .low ? Color.spWarning : Color.spTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

struct SmartExtractionReviewCard: View {
    let result: SmartExtractionResult
    var selectableKinds: [SmartDocumentKind] = []
    var familyMismatchMessage: String? = nil
    var conflicts: [MergeConflict] = []
    var extraNotes: [ExtractionIssue] = []
    var sourceData: Data? = nil
    var sourceMimeType: String? = nil
    var sourceImages: [UIImage] = []
    var onChooseKind: ((SmartDocumentKind) -> Void)? = nil
    var onUseDocumentValue: ((MergeConflict) -> Void)? = nil

    @State private var showDetails = false
    @State private var showItems = false
    @State private var showStops = false
    @State private var showOriginal = false

    private var rows: [ReviewField] { result.reviewFields }
    private var attention: Int { result.attentionCount }

    private var sourceSummary: String {
        let pages = "\(result.pageCount) page\(result.pageCount == 1 ? "" : "s")"
        let sources = Set(result.textSources)
        let how: String
        if sources == [.pdfText] { how = "PDF text" }
        else if sources.contains(.ocrEnhanced) { how = "scan, enhanced" }
        else if sources.contains(.pdfText) { how = "PDF text + scan" }
        else { how = "scan" }
        return "\(pages) · \(how) · read on this device"
    }

    private var visibleIssues: [ExtractionIssue] {
        let base = result.issues.filter { !(($0.field == "kind") && onChooseKind != nil) }
        var seen = Set<String>()
        return (base + extraNotes).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let familyMismatchMessage {
                noteRow(ExtractionIssue.warning("family", familyMismatchMessage))
            }

            if result.needsKindChoice, let onChooseKind {
                kindChooser(onChooseKind)
            }

            ForEach(visibleIssues) { issue in
                noteRow(issue)
            }

            if !conflicts.isEmpty {
                conflictList
            }

            if !rows.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(spacing: 8) {
                        ForEach(rows) { row in
                            fieldRow(row)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("What was read (\(rows.filter { $0.confidence != .missing }.count) of \(rows.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                }
                .tint(Color.spGold)
                .accessibilityIdentifier("smartImport.details")
            }

            if let r = result.rateConfirmation, !r.stops.isEmpty {
                DisclosureGroup(isExpanded: $showStops) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(r.stops) { stop in
                            stopRow(stop)
                        }
                        if !r.charges.isEmpty {
                            Divider()
                            ForEach(r.charges) { charge in
                                HStack {
                                    Text(charge.kind.title + (charge.conditional ? " (terms)" : ""))
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                    Spacer()
                                    Text(SmartText.money(charge.amount))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(charge.conditional ? Color.spTextSecondary : Color.spTextPrimary)
                                    SmartConfidenceBadge(confidence: charge.confidence)
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Stops & charges (\(r.stops.count) stop\(r.stops.count == 1 ? "" : "s"))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                }
                .tint(Color.spGold)
            }

            if !result.lineItems.isEmpty {
                DisclosureGroup(isExpanded: $showItems) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(result.lineItems) { item in
                            HStack(alignment: .top) {
                                Text(item.summary)
                                    .font(.caption)
                                    .foregroundStyle(Color.spTextPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 6)
                                SmartConfidenceBadge(confidence: item.confidence)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Line items (\(result.lineItems.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                }
                .tint(Color.spGold)
            }

            if sourceData != nil || !sourceImages.isEmpty {
                Button {
                    showOriginal = true
                } label: {
                    Label("View original document", systemImage: "doc.viewfinder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.spGold)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("smartImport.viewOriginal")
            }

            Text("Nothing is saved until you tap Save. Fields marked “Check this” were hard to read.")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
        }
        .padding(14)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(attention > 0 || !conflicts.isEmpty ? Color.spWarning.opacity(0.6) : Color.spGold.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("smartImport.card")
        .sheet(isPresented: $showOriginal) {
            SmartSourceDocumentView(data: sourceData, mimeType: sourceMimeType, images: sourceImages)
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.kind.systemImage)
                .font(.title3)
                .foregroundStyle(Color.spGold)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.kind == .unknown ? "Document imported" : "Read as \(result.kind.displayName)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Text(sourceSummary)
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
            }
            Spacer()
            if attention > 0 {
                Text("\(attention) to check")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(Color.spWarning)
                    .background(Color.spWarning.opacity(0.14), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func kindChooser(_ choose: @escaping (SmartDocumentKind) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What kind of document is this?")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.spTextPrimary)
            let kinds = selectableKinds.isEmpty ? SmartDocumentKind.allCases.filter { $0 != .unknown } : selectableKinds
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(kinds) { kind in
                    Button {
                        choose(kind)
                    } label: {
                        Label(kind.displayName, systemImage: kind.systemImage)
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .foregroundStyle(Color.spTextPrimary)
                            .background(Color.spCardBgLight, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("smartImport.kind.\(kind.rawValue)")
                }
            }
        }
    }

    private func noteRow(_ issue: ExtractionIssue) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(issue.severity == .warning ? Color.spWarning : Color.spTextSecondary)
            Text(issue.message)
                .font(.caption)
                .foregroundStyle(Color.spTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var conflictList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your entries differ from the document")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.spWarning)
            ForEach(conflicts) { c in
                VStack(alignment: .leading, spacing: 4) {
                    Text(SmartImportCoordinator.label(for: c.key))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.spTextPrimary)
                    Text("You entered: \(c.currentValue)")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                    HStack {
                        Text("Document shows: \(c.suggestedValue)")
                            .font(.caption)
                            .foregroundStyle(Color.spTextSecondary)
                        SmartConfidenceBadge(confidence: c.confidence)
                        Spacer()
                        if let onUseDocumentValue {
                            Button("Use this") { onUseDocumentValue(c) }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.spGold)
                                .frame(minHeight: 44)
                        }
                    }
                }
                .padding(8)
                .background(Color.spCardBgLight, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func fieldRow(_ row: ReviewField) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(row.label)
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
                .frame(width: 110, alignment: .leading)
            Text(row.value.isEmpty ? "—" : row.value)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.spTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            SmartConfidenceBadge(confidence: row.confidence)
        }
        .accessibilityElement(children: .combine)
    }

    private func stopRow(_ stop: ExtractedStop) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(stop.id). \(stop.label)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.spGold)
                Spacer()
                SmartConfidenceBadge(confidence: stop.confidence)
            }
            if let f = stop.facility.value {
                Text(f).font(.caption).foregroundStyle(Color.spTextPrimary)
            }
            if let a = stop.fullAddress {
                Text(a).font(.caption).foregroundStyle(Color.spTextSecondary)
            }
            let when = [stop.date.value?.usDisplay, stop.appointment.value].compactMap { $0 }.joined(separator: " ")
            if !when.isEmpty {
                Text(when).font(.caption).foregroundStyle(Color.spTextSecondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.spCardBgLight, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The original document as imported (PDF pages or scanned images).
struct SmartSourceDocumentView: View {
    let data: Data?
    let mimeType: String?
    let images: [UIImage]
    @Environment(\.dismiss) private var dismiss

    private var isPDF: Bool {
        mimeType == "application/pdf" || data.map { $0.starts(with: Array("%PDF".utf8)) } == true
    }

    var body: some View {
        if let data, isPDF {
            PDFPreviewView(data: data, title: "Original Document")
        } else {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 12) {
                        if let data, let image = UIImage(data: data) {
                            pageImage(image)
                        } else {
                            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                                pageImage(image)
                            }
                        }
                    }
                    .padding()
                }
                .background(Color.spBackground)
                .navigationTitle("Original Document")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
    }

    private func pageImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Document page")
    }
}

/// "Imported document" entry for saved records (load detail / expense edit).
struct SmartImportedDocumentSection: View {
    let recordType: DuplicateProbe.RecordType
    let recordID: UUID?
    @State private var record: SmartDocumentRecord?
    @State private var sourceData: Data?

    var body: some View {
        Group {
            if let record {
                SmartExtractionReviewCard(
                    result: record.result,
                    extraNotes: editedNotes(record),
                    sourceData: sourceData,
                    sourceMimeType: record.sourceMimeType
                )
            }
        }
        .task(id: recordID) {
            await loadRecord()
        }
    }

    private func editedNotes(_ record: SmartDocumentRecord) -> [ExtractionIssue] {
        guard !record.userEditedKeys.isEmpty else { return [] }
        let names = record.userEditedKeys.map { SmartImportCoordinator.label(for: $0) }.joined(separator: ", ")
        return [ExtractionIssue.info("edited", "Edited before saving: \(names).")]
    }

    private func loadRecord() async {
        guard let recordID,
              var found = SmartDocumentStore.shared.record(type: recordType, id: recordID.uuidString) else { return }
        // Duplicate warnings belonged to the moment of import.
        found.result.duplicates = []
        sourceData = SmartDocumentStore.shared.sourceData(filename: found.sourceFilename)
        record = found
    }
}
