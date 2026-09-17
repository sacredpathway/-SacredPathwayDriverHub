import UIKit

// =============================================================================
//  SettlementPDFExporter — statement / report PDFs, temp files, printing
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). Thin UIKit layer: HTML comes from the pure
//  builders in SettlementStatementBuilder.swift, pixels come from the existing
//  SettlementHTMLPDFService renderer. Nothing here does settlement math.
// =============================================================================

@MainActor
enum SettlementPDFExporter {

    static func statementPDF(_ document: SettlementStatementDocument) async throws -> Data {
        let html = SettlementStatementHTML.render(document, logoDataURI: logoDataURI())
        return try await SettlementHTMLPDFService.renderHTML(html)
    }

    static func reportPDF(_ report: SettlementReport, company: SettlementCompanyInfo) async throws -> Data {
        try await SettlementHTMLPDFService.renderHTML(
            SettlementReportHTML.render(report, company: company))
    }

    /// Writes data to a uniquely named temp file (for ShareLink / Files).
    static func temporaryFile(_ data: Data, named fileName: String) throws -> URL {
        let safe = fileName.replacingOccurrences(of: "/", with: "-")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettlementExports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safe)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Removes exported files left in the temp folder (driver pay data should
    /// not linger on disk longer than needed).
    static func cleanupTemporaryFiles() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettlementExports", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    static func print(_ data: Data, jobName: String) {
        guard UIPrintInteractionController.canPrint(data) else { return }
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = jobName
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = data
        controller.present(animated: true, completionHandler: nil)
    }

    private static func logoDataURI() -> String? {
        let image = BrandingService.shared.logoImage ?? UIImage(named: "SacredPathwayLogo")
        guard let image else { return nil }
        let target: CGFloat = 138   // 46pt at 3×
        let scale = image.size.height > 0 ? target / image.size.height : 1
        let size = CGSize(width: image.size.width * scale, height: target)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let png = resized.pngData() else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
