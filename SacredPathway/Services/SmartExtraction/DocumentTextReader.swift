import Foundation
import UIKit
import PDFKit
import CoreImage

// =============================================================================
// MARK: - DocumentTextReader (on-device text for the smart-extraction pipeline)
// -----------------------------------------------------------------------------
//  • Digital PDFs: use the embedded text when it is real text (not a scan).
//  • Scanned PDFs, camera scans, photos: Apple Vision OCR through the existing
//    LocalDocumentParser.recognizeText (it already retries rotated pages).
//  • Poor scans: one extra pass on a grayscale, contrast-boosted, sharpened copy.
//  • The original images / bytes are never modified.
//  No network calls. Nothing leaves the device.
// =============================================================================

/// What the user scanned, picked, or imported.
struct ImportedDocument {
    /// One image per page (camera pages, a photo, or rendered PDF pages).
    var images: [UIImage]
    /// The file exactly as imported (PDF or image), when there is one.
    var originalData: Data?
    var mimeType: String?

    var isPDF: Bool {
        mimeType == "application/pdf" || originalData.map { $0.starts(with: Array("%PDF".utf8)) } == true
    }

    /// SHA-256 of the original file, or nil for camera scans.
    var fileFingerprint: String? {
        originalData.map(DocumentFingerprint.sha256Hex)
    }
}

struct DocumentReading {
    /// Best text per page (PDF text where reliable, otherwise OCR).
    var document: DocumentText
    /// OCR lines for every page, in the exact shape the legacy rate-con
    /// parser has always received (page markers in DEBUG builds only).
    var legacyOCRLines: [String]
}

enum DocumentTextReader {

    /// Minimum amount of real characters for a PDF page's embedded text to be trusted.
    static let minimumEmbeddedCharacters = 40

    static func read(_ imported: ImportedDocument) async -> DocumentReading {
        var pages: [DocumentTextPage] = []
        var legacy: [String] = []

        var pdfPages: [PDFPage] = []
        if imported.isPDF, let data = imported.originalData, let pdf = PDFDocument(data: data) {
            pdfPages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }
        }
        let pageCount = max(imported.images.count, pdfPages.count)

        for index in 0..<pageCount {
            var image: UIImage? = index < imported.images.count ? imported.images[index] : nil
            if image == nil, index < pdfPages.count {
                image = render(pdfPages[index])
            }

            // Legacy parser input: OCR of the page image (unchanged behavior).
            var ocrLines: [String] = []
            if let image {
                ocrLines = await LocalDocumentParser.recognizeText(in: image)
            }
            #if DEBUG
            legacy.append("=== OCR PAGE \(index + 1) ===")
            #endif
            legacy.append(contentsOf: ocrLines)

            // Best text for the smart pipeline.
            if index < pdfPages.count, let embedded = embeddedLines(pdfPages[index]) {
                pages.append(DocumentTextPage(number: index + 1, lines: embedded, source: .pdfText))
                continue
            }
            var source: TextSource = .ocr
            if let image, needsEnhancement(ocrLines), let better = enhanced(image) {
                let retry = await LocalDocumentParser.recognizeText(in: better)
                if quality(retry) > quality(ocrLines) {
                    ocrLines = retry
                    source = .ocrEnhanced
                }
            }
            pages.append(DocumentTextPage(number: index + 1, lines: ocrLines, source: source))
        }
        if pages.isEmpty {
            pages = [DocumentTextPage(number: 1, lines: [], source: .ocr)]
        }
        return DocumentReading(document: DocumentText(pages: pages), legacyOCRLines: legacy)
    }

    // MARK: PDF text

    /// Embedded text lines when the page carries real text; nil for scans.
    static func embeddedLines(_ page: PDFPage) -> [String]? {
        guard let raw = page.string else { return nil }
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return isReliableEmbeddedText(lines) ? lines : nil
    }

    static func isReliableEmbeddedText(_ lines: [String]) -> Bool {
        let joined = lines.joined(separator: " ")
        let meaningful = joined.filter { $0.isLetter || $0.isNumber }.count
        guard meaningful >= minimumEmbeddedCharacters else { return false }
        // Broken font maps produce replacement characters or symbol soup.
        let replacement = joined.filter { $0 == "\u{FFFD}" }.count
        guard Double(replacement) / Double(max(joined.count, 1)) < 0.02 else { return false }
        return SmartText.textQuality(lines) >= 0.35
    }

    static func render(_ page: PDFPage, scale: CGFloat = 2) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let size = CGSize(width: max(bounds.width, 1) * scale, height: max(bounds.height, 1) * scale)
        return page.thumbnail(of: size, for: .mediaBox)
    }

    // MARK: Poor scans

    static func quality(_ lines: [String]) -> Double {
        SmartText.textQuality(lines) * Double(min(lines.count, 40))
    }

    static func needsEnhancement(_ lines: [String]) -> Bool {
        lines.count < 6 || SmartText.textQuality(lines) < 0.45
    }

    /// Grayscale + contrast + sharpen copy for a second OCR pass. The input
    /// image is not changed.
    static func enhanced(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        guard let controls = CIFilter(name: "CIColorControls") else { return nil }
        controls.setValue(input, forKey: kCIInputImageKey)
        controls.setValue(0.0, forKey: kCIInputSaturationKey)
        controls.setValue(1.6, forKey: kCIInputContrastKey)
        controls.setValue(0.05, forKey: kCIInputBrightnessKey)
        var output = controls.outputImage
        if let sharpen = CIFilter(name: "CISharpenLuminance"), let o = output {
            sharpen.setValue(o, forKey: kCIInputImageKey)
            sharpen.setValue(0.6, forKey: kCIInputSharpnessKey)
            output = sharpen.outputImage
        }
        guard let result = output else { return nil }
        let context = CIContext(options: nil)
        guard let rendered = context.createCGImage(result, from: input.extent) else { return nil }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
    }
}
