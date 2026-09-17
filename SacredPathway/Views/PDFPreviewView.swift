//
//  PDFPreviewView.swift
//  Sacred Pathway Driver Hub
//
//  In-app PDF preview sheet. Renders the EXACT bytes we'll export — no
//  separate layout. Provides Share / Save / Done from the preview itself.
//

import SwiftUI
import PDFKit
import UIKit

struct PDFPreviewView: View {
    let data: Data
    var title: String = "Settlement Preview"
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false

    var body: some View {
        NavigationStack {
            PDFKitContainer(data: data)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") {
                            onClose?()
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share PDF")
                    }
                }
                .sheet(isPresented: $showShareSheet) {
                    PDFActivityShareSheet(items: [pdfTempURL ?? data])
                }
        }
    }

    /// Write the PDF to a temp file with a friendly name so the share sheet
    /// shows a real document title (better than "octet-stream" blob).
    private var pdfTempURL: URL? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Settlement-\(Int(Date().timeIntervalSince1970)).pdf")
        do {
            try data.write(to: tmp, options: .atomic)
            return tmp
        } catch {
            return nil
        }
    }
}

// MARK: - PDFKit wrapper

private struct PDFKitContainer: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemGroupedBackground
        view.usePageViewController(false, withViewOptions: nil)
        // Allow generous pinch-zoom on top of the fit-to-page baseline.
        view.maxScaleFactor = 6.0
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        // Avoid reloading if the data is unchanged — prevents the user's
        // zoom level from being reset every time the parent re-renders.
        let isSameDoc = uiView.document?.dataRepresentation() == data
        if !isSameDoc {
            uiView.document = PDFDocument(data: data)
            // Land on page 1 so multi-page PDFs always open at the top.
            if let firstPage = uiView.document?.page(at: 0) {
                uiView.go(to: PDFDestination(page: firstPage, at: .zero))
            }
            // Defer the fit-scale calc until after PDFView completes its
            // initial layout — `scaleFactorForSizeToFit` reads the view's
            // bounds, which are still settling on first render.
            DispatchQueue.main.async {
                let fit = uiView.scaleFactorForSizeToFit
                uiView.minScaleFactor = fit
                uiView.scaleFactor    = fit
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let fit = uiView.scaleFactorForSizeToFit
                uiView.minScaleFactor = fit
                uiView.scaleFactor    = fit
            }
        }
    }
}

// MARK: - Activity share sheet (named to avoid colliding with project's own ShareSheet)

private struct PDFActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
