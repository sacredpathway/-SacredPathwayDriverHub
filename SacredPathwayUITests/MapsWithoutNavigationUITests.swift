import XCTest

// =============================================================================
//  MapsWithoutNavigationUITests (2026-09-17)
// -----------------------------------------------------------------------------
//  In-app turn-by-turn navigation was removed. Smoke check (Free Local Mode,
//  same launch contract as SettlementsNavigationUITests): the Near Me cards,
//  Maps, current-location control and Sacred Path search/planning remain, and
//  no control that starts navigation is shown. Lines starting with
//  "NAV_REPORT" are copied into the CI summary.
// =============================================================================

@MainActor
final class MapsWithoutNavigationUITests: XCTestCase {
    private let app = XCUIApplication()

    private let navigationLabels = ["Start Navigation", "Start In-App Navigation", "Start In-App Trip",
                                    "Get Directions", "Preview Trip & Get Directions", "Map Diagnostics"]

    func testMapsRemainWithoutNavigationControls() throws {
        continueAfterFailure = false
        app.launchArguments = ["-DriverHubUITest"]
        app.launchEnvironment["DRIVER_HUB_UI_TEST_RESET"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["dashboard.addLoad"].waitForExistence(timeout: 15), "Dashboard did not load")
        handleLocationPrompt("dashboard")

        // Near Me cards stay on the Owner-Operator / Carrier dashboard.
        XCTAssertTrue(findByLabel("Weather Near Me", scrolling: app.scrollViews.firstMatch), "Weather Near Me card missing")
        XCTAssertTrue(findByLabel("Rate Near Me", scrolling: app.scrollViews.firstMatch), "Rate Near Me card missing")
        report("dashboard Near Me cards present")

        // Maps opens (tab bar or More) with the current-location control.
        let via = open("Maps")
        XCTAssertTrue(app.navigationBars["Maps"].waitForExistence(timeout: 10), "Maps did not open")
        handleLocationPrompt("maps")
        let locationControl = app.buttons["Change Location"].exists || app.buttons["Use Current Location"].exists
            || app.buttons["Change Location"].waitForExistence(timeout: 5)
        XCTAssertTrue(locationControl, "current-location control missing on Maps")
        report("Maps via \(via); navigation bars on screen = \(app.navigationBars.count) (\(app.navigationBars.allElementsBoundByIndex.map(\.identifier).joined(separator: ", ")))")
        snapshot("maps")
        assertNoNavigationControls("Maps")

        // Sacred Path search / planning hub stays; no navigation start controls.
        var segment = app.segmentedControls.buttons["Sacred Path"]
        if !segment.waitForExistence(timeout: 5) {
            segment = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sacred Path")).firstMatch
        }
        XCTAssertTrue(segment.waitForExistence(timeout: 3), "Sacred Path mode missing")
        segment.tap()
        XCTAssertTrue(findByLabel("Route Planning", scrolling: nil), "Sacred Path route planning missing")
        snapshot("sacred-path")
        assertNoNavigationControls("Sacred Path")
        for card in ["AI Trip Planner", "Nearby Truck Parking & Rest Areas", "Truck Profile"] {
            report("Sacred Path card '\(card)' present = \(findByLabel(card, scrolling: app.scrollViews.firstMatch))")
        }
        assertNoNavigationControls("Sacred Path (scrolled)")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: Helpers

    /// Answers the system location prompt if it is showing and reports its
    /// choices (When-In-Use only is expected; there is no Always request).
    private func handleLocationPrompt(_ context: String) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 4) else {
            report("\(context): no location prompt showing")
            return
        }
        let labels = alert.buttons.allElementsBoundByIndex.map(\.label)
        report("\(context): location prompt buttons = \(labels.joined(separator: " | "))")
        XCTAssertFalse(labels.contains { $0.localizedCaseInsensitiveContains("always") },
                       "location prompt offers Always")
        for label in ["Allow While Using App", "Allow Once", "OK"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return
        }
    }

    private func assertNoNavigationControls(_ screen: String) {
        for label in navigationLabels {
            let match = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
            XCTAssertFalse(match.exists, "\(screen) still shows '\(label)'")
        }
    }

    private func findByLabel(_ text: String, scrolling: XCUIElement?) -> Bool {
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        if query.waitForExistence(timeout: 3) { return true }
        guard let scrolling, scrolling.exists else { return false }
        for _ in 0..<6 {
            scrolling.swipeUp()
            if query.exists { return true }
        }
        return false
    }

    private func open(_ name: String) -> String {
        let direct = app.tabBars.firstMatch.buttons[name]
        if direct.exists {
            direct.tap()
            return "tab bar"
        }
        let more = app.tabBars.firstMatch.buttons["More"]
        guard more.exists else {
            XCTFail("\(name) is neither a tab nor under More")
            return "missing"
        }
        more.tap()
        let moreBack = app.navigationBars.buttons["More"]
        if moreBack.waitForExistence(timeout: 1) { moreBack.tap() }
        let row = app.cells.staticTexts[name].firstMatch
        guard row.waitForExistence(timeout: 5) else {
            XCTFail("\(name) is not listed under More")
            return "missing"
        }
        row.tap()
        return "More"
    }

    private func report(_ line: String) {
        print("NAV_REPORT: \(line)")
        let a = XCTAttachment(string: line)
        a.lifetime = .keepAlways
        add(a)
    }

    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "maps-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
