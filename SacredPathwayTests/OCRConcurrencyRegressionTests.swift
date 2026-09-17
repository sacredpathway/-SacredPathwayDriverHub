import XCTest
import UIKit
@testable import SacredPathway

@MainActor
final class OCRConcurrencyRegressionTests: XCTestCase {

    nonisolated fileprivate static let deterministicText = """
    LOAD: SP-PHYS-4301
    BROKER: RELEASE AUDIT
    ORIGIN: DALLAS, TX
    DESTINATION: TULSA, OK
    MILES: 257
    RATE: $1,234.56
    """

    func testVisionPipelineCompletesWhenInvokedFromDetachedTask() async {
        let recognizedExpectedContent = await Task.detached(priority: .userInitiated) {
            let image = makeDeterministicOCRImage()
            let parsed = await LocalDocumentParser.parseSinglePageForTesting(image: image)
            let text = await parsed.rawText.uppercased()
            return text.contains("SP-PHYS-4301")
                || (text.contains("RELEASE") && text.contains("AUDIT"))
        }.value

        XCTAssertTrue(
            recognizedExpectedContent,
            "Real Vision OCR completed but did not recognize the deterministic document."
        )
    }

    func testDeterministicTextMapsAllReleaseFieldsExactly() {
        let parsed = LocalDocumentParser.parseText(Self.deterministicText)

        XCTAssertEqual(parsed.loadNumber, "SP-PHYS-4301")
        XCTAssertEqual(parsed.brokerName, "RELEASE AUDIT")
        XCTAssertEqual(parsed.pickupCityState, "DALLAS, TX")
        XCTAssertEqual(parsed.deliveryCityState, "TULSA, OK")
        XCTAssertEqual(parsed.loadedMiles, 257)
        XCTAssertNotNil(parsed.rate)
        XCTAssertEqual(parsed.rate ?? 0, 1_234.56, accuracy: 0.001)
    }

    func testParserPreservesCurrencyAndCityStateUnderBenignOCRVariation() {
        let parsed = LocalDocumentParser.parseText(
            """
              load:   SP-PHYS-4301
            BROKER: release audit
            ORIGIN: DALLAS, TX
            DESTINATION: TULSA, OK
            MILES: 257
            RATE: $ 1,234.56
            """
        )

        XCTAssertEqual(parsed.loadNumber?.uppercased(), "SP-PHYS-4301")
        XCTAssertEqual(parsed.brokerName?.uppercased(), "RELEASE AUDIT")
        XCTAssertEqual(parsed.pickupCityState?.uppercased(), "DALLAS, TX")
        XCTAssertEqual(parsed.deliveryCityState?.uppercased(), "TULSA, OK")
        XCTAssertEqual(parsed.loadedMiles, 257)
        XCTAssertNotNil(parsed.rate)
        XCTAssertEqual(parsed.rate ?? 0, 1_234.56, accuracy: 0.001)
    }

    func testRepeatedVisionExecutionDoesNotLeakStateAcrossRuns() async {
        var results: [Bool] = []

        for _ in 0..<3 {
            let completed = await Task.detached(priority: .userInitiated) {
                let image = makeDeterministicOCRImage()
                let parsed = await LocalDocumentParser.parseSinglePageForTesting(image: image)
                let rawText = await parsed.rawText
                return !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.value
            results.append(completed)
        }

        XCTAssertEqual(results, [true, true, true])
    }

    func testEmptyAndInvalidImagesReturnEmptyResults() async {
        let empty = LocalDocumentParser.parseText("")
        XCTAssertTrue(empty.rawText.isEmpty)
        XCTAssertNil(empty.loadNumber)
        XCTAssertNil(empty.brokerName)

        let invalid = UIImage()
        let parsed = await LocalDocumentParser.parseSinglePageForTesting(image: invalid)
        XCTAssertTrue(parsed.rawText.isEmpty)
        XCTAssertNil(parsed.loadNumber)
        XCTAssertNil(parsed.brokerName)
    }

    func testCancellationDoesNotCrashOrPublishStaleState() async {
        let task = Task {
            await LocalDocumentParser.parseSinglePageForTesting(
                image: makeDeterministicOCRImage()
            )
        }
        task.cancel()
        let parsed = await task.value

        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(parsed.rawText.isEmpty || parsed.loadNumber == "SP-PHYS-4301")
    }
}

private nonisolated func makeDeterministicOCRImage() -> UIImage {
    let size = CGSize(width: 1_600, height: 1_050)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1

    return UIGraphicsImageRenderer(size: size, format: format).image { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: size))

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 18
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 58, weight: .semibold),
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]
        OCRConcurrencyRegressionTests.deterministicText.draw(
            in: CGRect(x: 80, y: 80, width: 1_440, height: 890),
            withAttributes: attributes
        )
    }
}
