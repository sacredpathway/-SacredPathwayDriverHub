//
//  SettlementHTMLPDFService.swift  (v2 — proper WKWebView layout pipeline)
//  Sacred Pathway Driver Hub
//
//  Renders the canonical SPH settlement PDF using sph_template.html via
//  WKWebView → createPDF(). Output is byte-identical in design to the
//  WeasyPrint reference: SF Pro / Inter typography, route pills, navy NET PAY
//  callout, gold accents, true vector PDF.
//
//  v2 fixes vs v1:
//   - WKWebView is added to a hidden host window so iOS actually performs
//     layout (and applies CSS / loads fonts / decodes data-URI images).
//   - Waits for document.readyState === 'complete' AND document.fonts.status
//     === 'loaded' before snapshotting.
//   - Sets baseURL = Bundle.main.bundleURL so resource resolution works.
//   - Resizes the webview to the natural document height before createPDF,
//     so multi-page content doesn't get clipped.
//   - Drops the explicit `createPDF` rect (let WebKit use the layout box).
//

import UIKit
import WebKit
import CoreImage.CIFilterBuiltins
import PDFKit

@MainActor
final class SettlementHTMLPDFService {

    static func generate(
        calculation: SettlementCalculation,
        loads: [Load],
        expenses: [Expense],
        companyName: String,
        driverName: String,
        periodStart: Date,
        periodEnd: Date,
        logo: UIImage? = nil,
        primaryColor: UIColor? = nil,
        truckNumber: String? = nil,
        trailerNumber: String? = nil,
        dispatcherName: String? = nil,
        mcNumber: String? = nil,
        dotNumber: String? = nil,
        notes: [String] = [],
        theme: PaystubTheme = .defaultTheme,
        statementId: String? = nil,
        status: PaystubStatus? = nil,
        paymentMethod: String? = nil,
        ytd: YTDSummary? = nil,
        adjustments: [PaystubAdjustment] = [],
        escrowBalance: Double? = nil,
        showSignatureLines: Bool = true,
        driverAddress: String? = nil,
        driverEmail: String? = nil,
        driverPhone: String? = nil,
        paymentAccountSuffix: String? = nil
    ) async throws -> Data {

        let html = try buildHTML(
            calculation: calculation,
            loads: loads,
            expenses: expenses,
            companyName: companyName,
            driverName: driverName,
            periodStart: periodStart,
            periodEnd: periodEnd,
            logo: logo,
            mcNumber: mcNumber,
            dotNumber: dotNumber,
            truckNumber: truckNumber,
            trailerNumber: trailerNumber,
            statementId: statementId,
            status: status,
            paymentMethod: paymentMethod,
            driverAddress: driverAddress,
            driverEmail: driverEmail,
            driverPhone: driverPhone,
            paymentAccountSuffix: paymentAccountSuffix
        )
        return try await Renderer.render(html: html)
    }

    // MARK: - HTML construction

    private static func buildHTML(
        calculation: SettlementCalculation,
        loads: [Load],
        expenses: [Expense],
        companyName: String,
        driverName: String,
        periodStart: Date,
        periodEnd: Date,
        logo: UIImage?,
        mcNumber: String?,
        dotNumber: String?,
        truckNumber: String?,
        trailerNumber: String?,
        statementId: String?,
        status: PaystubStatus?,
        paymentMethod: String?,
        driverAddress: String?,
        driverEmail: String?,
        driverPhone: String?,
        paymentAccountSuffix: String?
    ) throws -> String {

        guard
            let url = Bundle.main.url(forResource: "sph_template", withExtension: "html"),
            var template = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw NSError(
                domain: "SettlementHTMLPDFService", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Bundle resource sph_template.html not found"]
            )
        }

        let dfPayDate = DateFormatter(); dfPayDate.dateFormat = "MMM d, yyyy"
        let dfStart   = DateFormatter(); dfStart.dateFormat   = "MMM d"
        let dfEnd     = DateFormatter(); dfEnd.dateFormat     = "d, yyyy"
        let dfStamp   = DateFormatter(); dfStamp.dateFormat   = "yyyyMMdd"

        let payDate    = dfPayDate.string(from: periodEnd)
        let payPeriod  = "\(dfStart.string(from: periodStart)) – \(dfEnd.string(from: periodEnd))"
        let dateStamp  = dfStamp.string(from: periodEnd)

        var logoHTML = ""
        if let logo = logo {
            // CSS template displays logo at 66pt height. We render at the
            // upscale function's max (12×) for a 792px tall PNG — sharp
            // through 800% zoom and 300dpi print. upscaleLogoForPDF
            // never downsamples a higher-res source.
            let cssHeight: CGFloat = 66
            let upscaled = upscaleLogoForPDF(logo, displayHeight: cssHeight, scale: 12.0)
            if let png = upscaled.pngData() {
                let b64 = png.base64EncodedString()
                logoHTML = "<img class=\"logo-img\" alt=\"\(escape(companyName))\" src=\"data:image/png;base64,\(b64)\">"
            }
        }

        var metaParts: [String] = []
        if let mc = mcNumber, !mc.isEmpty {
            metaParts.append("<span class=\"kv-tag\">MC#</span> \(escape(mc))")
        }
        if let dot = dotNumber, !dot.isEmpty {
            metaParts.append("<span class=\"kv-tag\">DOT#</span> \(escape(dot))")
        }
        if let truck = truckNumber, !truck.isEmpty {
            metaParts.append("<span class=\"kv-tag\">TRUCK</span> \(escape(truck))")
        }
        if let trailer = trailerNumber, !trailer.isEmpty {
            metaParts.append("<span class=\"kv-tag\">TRAILER</span> \(escape(trailer))")
        }
        let carrierMeta = metaParts.isEmpty
            ? "&nbsp;"
            : metaParts.joined(separator: "<span class=\"pipe\">|</span>")

        let payroll = (statementId?.isEmpty == false)
            ? statementId!
            : "PY\(String(dateStamp.suffix(5)))"

        let statusStr = (status?.label ?? "PAID").uppercased()

        let initials = driverName.split(separator: " ")
            .compactMap { $0.first.map { String($0) } }
            .joined()
            .uppercased()
        let refId = "SPH-\(payroll)-\(initials)-\(dateStamp)"

        let loadsRows = buildLoadsRows(loads: loads)

        // Aggregates: total miles, total revenue, average rate per mile
        let totalMiles = loads.reduce(0.0) { $0 + ($1.totalMiles ?? 0) }
        let totalLoadRevenue = loads.reduce(0.0) { $0 + ($1.totalRevenue ?? 0) }
        let milesFmt: NumberFormatter = {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 0
            f.usesGroupingSeparator = true
            return f
        }()
        let totalMilesStr = totalMiles > 0
            ? "\(milesFmt.string(from: NSNumber(value: totalMiles)) ?? "0") mi"
            : "—"
        let avgRateStr: String
        if totalMiles > 0, totalLoadRevenue > 0 {
            avgRateStr = String(format: "$%.2f/mi", totalLoadRevenue / totalMiles)
        } else {
            avgRateStr = "—"
        }
        let loadCountStr = "\(loads.count)"

        let displayedExpenseTotal = expenses.map { $0.amount }.reduce(0, +)
        let totalDeductions = displayedExpenseTotal
            + calculation.factoringFeeAmount
            + calculation.dispatcherFeeAmount
            + calculation.authorityFee
            + calculation.maintenanceReserve
        let deductionsRows = buildDeductionsRows(expenses: expenses, calculation: calculation)

        let verifyURL = "sacredpathway.app/v/\(payroll)"
        let qrB64 = generateQRBase64(payload: refId)

        let replacements: [String: String] = [
            "{{LOGO_BLOCK}}":         logoHTML,
            "{{carrier_name}}":       escape(companyName),
            "{{carrier_name_js}}":    escapeForJS(companyName),
            "{{payroll_no_js}}":      escapeForJS(payroll),
            "{{carrier_meta_html}}":  carrierMeta,
            "{{payroll_no}}":         escape(payroll),
            "{{pay_date}}":           escape(payDate),
            "{{pay_period}}":         escape(payPeriod),
            "{{status}}":             escape(statusStr),
            "{{driver_name}}":        escape(driverName),
            "{{driver_address}}":     escape(driverAddress ?? "—"),
            "{{driver_email}}":       escape(driverEmail ?? "—"),
            "{{driver_phone}}":       escape(driverPhone ?? "—"),
            "{{payment_method}}":     escape(paymentMethod ?? "Direct Deposit"),
            "{{payment_account}}":    paymentAccountSuffix.map { "Account ending •••• \(escape($0))  •  ACH Transfer" } ?? "ACH Transfer",
            "{{reference_id}}":       escape(refId),
            "{{LOADS_ROWS}}":         loadsRows,
            "{{gross_pay}}":          calculation.totalRevenue.asCurrency,
            "{{total_miles}}":        totalMilesStr,
            "{{avg_rate_per_mile}}":  avgRateStr,
            "{{load_count}}":         loadCountStr,
            "{{DEDUCTION_ROWS}}":     deductionsRows,
            "{{total_deductions}}":   totalDeductions.asCurrency,
            "{{net_pay_no_dollar}}":  formatPlainAmount(calculation.carrierNetPay),
            "{{verify_url_short}}":   escape(verifyURL),
            "{{QR_B64}}":             qrB64
        ]

        for (k, v) in replacements {
            template = template.replacingOccurrences(of: k, with: v)
        }
        return template
    }

    // MARK: - Row builders

    private static func buildLoadsRows(loads: [Load]) -> String {
        let f = DateFormatter(); f.dateFormat = "MM/dd/yy"
        var html = ""
        for load in loads {
            let originLabel = stateOrCity(load.origin)
            let destLabel   = stateOrCity(load.destination)
            let pickupStr   = load.pickupDate.map { f.string(from: $0) } ?? ""
            let deliveryStr = load.deliveryDate.map { f.string(from: $0) } ?? ""
            let revenue     = load.totalRevenue ?? 0
            let miles       = load.totalMiles ?? 0
            let amount      = revenue.asCurrency

            // RATE column: rate-per-mile when miles tracked, else "Flat".
            let rateLabel: String
            if miles > 0, revenue > 0 {
                rateLabel = String(format: "$%.2f/mi", revenue / miles)
            } else {
                rateLabel = "Flat"
            }

            // Date sub-line under route pills: PU 05/02 · DL 05/04
            var dateBits: [String] = []
            if !pickupStr.isEmpty {
                dateBits.append("<span class=\"dt-tag\">PU</span> \(escape(pickupStr))")
            }
            if !deliveryStr.isEmpty {
                dateBits.append("<span class=\"dt-tag\">DL</span> \(escape(deliveryStr))")
            }
            let dateLine = dateBits.isEmpty
                ? ""
                : "<div class=\"route-dates\">\(dateBits.joined(separator: " &nbsp;·&nbsp; "))</div>"

            html += """
              <tr>
                <td>
                  <span class="route">
                    <span class="from">\(escape(originLabel))</span>
                    <span class="arrow"></span>
                    <span class="to">\(escape(destLabel))</span>
                  </span>
                  \(dateLine)
                </td>
                <td class="num">1</td>
                <td class="num">\(rateLabel)</td>
                <td class="num">\(amount)</td>
              </tr>
            """
        }
        return html
    }

    private static func buildDeductionsRows(
        expenses: [Expense],
        calculation: SettlementCalculation
    ) -> String {
        let f = DateFormatter(); f.dateFormat = "MM/dd/yy"
        var html = ""
        for exp in expenses {
            let label = (exp.description?.isEmpty == false) ? exp.description! : exp.category.capitalized
            // Long descriptions get a smaller font + allowed to wrap so they
            // don't bust the row width and stay aligned with currency col.
            let labelClass = label.count > 24 ? "ded-label long" : "ded-label"
            let dateStr = exp.receiptDate.map { f.string(from: $0) }
            let sub = dateStr.map { " <span class=\"ded-sub\">\(escape($0))</span>" } ?? ""
            html += """
              <tr>
                <td><span class="\(labelClass)">\(escape(label))</span>\(sub)</td>
                <td class="num">\(exp.amount.asCurrency)</td>
              </tr>
            """
        }
        if calculation.factoringFeeAmount > 0 {
            html += deductionRow(label: "Factoring Fee", sub: "% of gross", amount: calculation.factoringFeeAmount)
        }
        if calculation.dispatcherFeeAmount > 0 {
            html += deductionRow(label: "Dispatcher Fee", sub: nil, amount: calculation.dispatcherFeeAmount)
        }
        if calculation.authorityFee > 0 {
            html += deductionRow(label: "Authority Lease", sub: "% of gross", amount: calculation.authorityFee)
        }
        if calculation.maintenanceReserve > 0 {
            html += deductionRow(label: "Maintenance Reserve", sub: nil, amount: calculation.maintenanceReserve)
        }
        return html
    }

    private static func deductionRow(label: String, sub: String?, amount: Double) -> String {
        let subSpan = sub.map { " <span class=\"ded-sub\">\(escape($0))</span>" } ?? ""
        return """
          <tr>
            <td><span class="ded-label">\(escape(label))</span>\(subSpan)</td>
            <td class="num">\(amount.asCurrency)</td>
          </tr>
        """
    }

    // MARK: - Utilities

    private static func stateOrCity(_ raw: String?) -> String {
        let s = (raw ?? "").trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "—" }
        if let comma = s.lastIndex(of: ",") {
            let tail = s[s.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if tail.count == 2 { return tail.uppercased() }
        }
        if s.count <= 3 { return s.uppercased() }
        return String(s.prefix(12)).uppercased()
    }

    private static func formatPlainAmount(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = true
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: v)) ?? "0.00"
    }

    private static func generateQRBase64(payload: String) -> String {
        let context = CIContext()
        let filter  = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "Q"
        guard let out = filter.outputImage else { return "" }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return "" }
        return UIImage(cgImage: cg).pngData()?.base64EncodedString() ?? ""
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&",  with: "&amp;")
         .replacingOccurrences(of: "<",  with: "&lt;")
         .replacingOccurrences(of: ">",  with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Escapes a string for safe embedding inside a single-quoted JS
    /// literal in the inline `<script>` block of the template.
    private static func escapeForJS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'",  with: "\\'")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "")
         .replacingOccurrences(of: "<",  with: "\\u003C")
         .replacingOccurrences(of: ">",  with: "\\u003E")
    }

    /// Renders a logo at print-grade scale so the embedded PNG bitmap stays
    /// sharp under print AND deep zoom. Preserves aspect ratio and alpha.
    /// Uses up to 12× render scale (was 8×) to match the deep-zoom
    /// expectations of a vector-quality lender-grade settlement.
    private static func upscaleLogoForPDF(
        _ image: UIImage,
        displayHeight: CGFloat,
        scale: CGFloat
    ) -> UIImage {
        guard image.size.height > 0 else { return image }
        let aspect = image.size.width / image.size.height
        let displaySize = CGSize(width: displayHeight * aspect, height: displayHeight)
        // Use the source image's native scale relative to display size as a
        // floor — never downsample a high-res asset just to fit our minimum.
        let sourceNativeScale = (image.size.height * image.scale) / max(1, displayHeight)
        // Target 6× the display size at minimum, capped at 12× to balance
        // memory + sharpness. Print-quality is roughly 4× display.
        let renderScale = min(max(scale, sourceNativeScale, 6.0), 12.0)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = renderScale
        format.opaque = false
        format.preferredRange = .extended
        let renderer = UIGraphicsImageRenderer(size: displaySize, format: format)
        return renderer.image { ctx in
            ctx.cgContext.interpolationQuality = .high
            ctx.cgContext.setShouldAntialias(true)
            ctx.cgContext.setAllowsAntialiasing(true)
            image.draw(in: CGRect(origin: .zero, size: displaySize))
        }
    }

    // MARK: - Renderer (proper WKWebView layout pipeline)

    @MainActor
    private final class Renderer: NSObject, WKNavigationDelegate {

        // Strong refs so renderers + the host window survive until createPDF resumes
        private static var liveRenderers: [Renderer] = []
        private static var hostWindow: UIWindow?

        // US Letter at 72 DPI = 612 × 792pt. Constants are class-level so
        // both `run()` and `snapshotWhenReady()` can reference them.
        static let pageWidth: CGFloat = 612
        static let pageHeight: CGFloat = 792

        static func render(html: String) async throws -> Data {
            let r = Renderer()
            liveRenderers.append(r)
            defer { liveRenderers.removeAll { $0 === r } }
            return try await r.run(html: html)
        }

        private var continuation: CheckedContinuation<Data, Error>?
        private var webView: WKWebView!

        private func run(html: String) async throws -> Data {

            // Create / reuse a hidden host window so iOS actually performs layout
            // (off-screen WKWebViews skip layout, which is why CSS appeared "missing").
            if Self.hostWindow == nil {
                let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
                let win: UIWindow = (scene != nil) ? UIWindow(windowScene: scene!) : UIWindow(frame: .zero)
                win.windowLevel = .alert + 1
                win.rootViewController = UIViewController()
                win.alpha = 0.001          // effectively invisible
                win.frame = CGRect(x: -2000, y: -2000, width: 612, height: 1100)
                win.isHidden = false       // must be visible (off-screen) for layout
                Self.hostWindow = win
            }

            // US Letter constants live on Renderer (Renderer.pageWidth /
            // .pageHeight). Initial webview height is generous so layout
            // settles before we measure.
            let pageWidth: CGFloat = Renderer.pageWidth
            let initialHeight: CGFloat = 1500
            let cfg = WKWebViewConfiguration()
            cfg.suppressesIncrementalRendering = false

            webView = WKWebView(
                frame: CGRect(x: 0, y: 0, width: pageWidth, height: initialHeight),
                configuration: cfg
            )
            webView.isOpaque = true
            webView.backgroundColor = .white
            webView.scrollView.backgroundColor = .white
            webView.navigationDelegate = self
            Self.hostWindow?.rootViewController?.view.addSubview(webView)

            return try await withCheckedThrowingContinuation { cont in
                continuation = cont
                // baseURL = Bundle.main.bundleURL so resource resolution + remote
                // origin permissions behave correctly.
                webView.loadHTMLString(html, baseURL: Bundle.main.bundleURL)
            }
        }

        // MARK: - WKNavigationDelegate

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                await self.snapshotWhenReady()
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                self.continuation?.resume(throwing: error)
                self.continuation = nil
                self.cleanup()
            }
        }

        nonisolated func webView(_ webView: WKWebView,
                                 didFailProvisionalNavigation navigation: WKNavigation!,
                                 withError error: Error) {
            Task { @MainActor in
                self.continuation?.resume(throwing: error)
                self.continuation = nil
                self.cleanup()
            }
        }

        // MARK: - Snapshot pipeline

        @MainActor
        private func snapshotWhenReady() async {
            // 1. Wait until DOM is parsed AND fonts are loaded (poll up to ~3s)
            for _ in 0..<30 {
                let readyJS = """
                  (document.readyState === 'complete') &&
                  (!document.fonts || document.fonts.status === 'loaded')
                """
                let ready = (try? await webView.evaluateJavaScript(readyJS)) as? Bool ?? false
                if ready { break }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            // 2. Measure the natural content height. WebKit's createPDF
            //    will not paginate on its own when given a tall content
            //    rect — it just produces one page sized to the rect. So
            //    we measure here, then call createPDF *once per Letter
            //    slice* below.
            let measureJS = """
              (function () {
                document.documentElement.style.margin = '0';
                document.body.style.margin = '0';
                return Math.max(
                  document.documentElement.scrollHeight,
                  document.body.scrollHeight
                );
              })();
            """
            let h = (try? await webView.evaluateJavaScript(measureJS)) as? CGFloat ?? Renderer.pageHeight
            let contentHeight = max(Renderer.pageHeight, ceil(h))

            // 3. Resize webview to fit the full natural content height.
            //    Each createPDF call will then snip a 612×792 slice.
            webView.frame = CGRect(x: 0, y: 0, width: Renderer.pageWidth, height: contentHeight)
            webView.setNeedsLayout()
            webView.layoutIfNeeded()

            // 4. Final layout-settle delay.
            try? await Task.sleep(nanoseconds: 150_000_000)

            // 5. Multi-rect createPDF: one Letter page per slice. Vector
            //    quality is preserved because each slice is rendered by
            //    WebKit's vector pipeline. PDFKit then merges into a
            //    single multi-page PDF.
            do {
                let merged = try await Self.renderPaginated(
                    webView: webView,
                    contentHeight: contentHeight
                )
                self.continuation?.resume(returning: merged)
            } catch {
                self.continuation?.resume(throwing: error)
            }
            self.continuation = nil
            self.cleanup()
        }

        @MainActor
        private static func renderPaginated(
            webView: WKWebView,
            contentHeight: CGFloat
        ) async throws -> Data {
            // Drop a near-empty trailing page if the last slice has
            // < 100pt of real content. The injected page-frames add
            // ~792pt to scrollHeight per page, so even a small overshoot
            // beyond N*792 creates an empty page (N+1) that's just
            // padding-bottom bleed. 100pt is comfortably below the
            // height of any real content block.
            var pageCount = max(1, Int(ceil(contentHeight / Renderer.pageHeight)))
            if pageCount > 1 {
                let lastSlice = contentHeight - CGFloat(pageCount - 1) * Renderer.pageHeight
                if lastSlice < 100 { pageCount -= 1 }
            }

            // Render each Letter slice as its own single-page PDF.
            var pageDatas: [Data] = []
            for i in 0..<pageCount {
                let yOffset = CGFloat(i) * Renderer.pageHeight
                let sliceHeight = min(Renderer.pageHeight, contentHeight - yOffset)
                let cfg = WKPDFConfiguration()
                cfg.rect = CGRect(x: 0, y: yOffset,
                                  width: Renderer.pageWidth,
                                  height: sliceHeight)
                let data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                    webView.createPDF(configuration: cfg) { result in
                        switch result {
                        case .success(let d): cont.resume(returning: d)
                        case .failure(let e): cont.resume(throwing: e)
                        }
                    }
                }
                pageDatas.append(data)
            }

            // Single page: skip the merge.
            if pageDatas.count == 1, let only = pageDatas.first {
                return only
            }

            // Merge into one multi-page PDF using PDFKit. Pages from each
            // single-page createPDF are appended in order, preserving
            // vector glyphs + embedded fonts.
            let merged = PDFDocument()
            for data in pageDatas {
                if let doc = PDFDocument(data: data),
                   let page = doc.page(at: 0) {
                    merged.insert(page, at: merged.pageCount)
                }
            }

            return merged.dataRepresentation() ?? pageDatas.first ?? Data()
        }

        @MainActor
        private func cleanup() {
            webView?.removeFromSuperview()
            webView?.navigationDelegate = nil
            webView = nil
        }
    }
}

