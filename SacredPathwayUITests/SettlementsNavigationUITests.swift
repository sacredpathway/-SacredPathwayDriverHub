import XCTest

// =============================================================================
//  SettlementsNavigationUITests — 2.3.3 integration (2026-09-17)
// -----------------------------------------------------------------------------
//  The Settlements tab joins the Owner-Operator / Carrier tab bar. With Maps
//  enabled that is six tabs, and iOS moves the last ones under "More". This
//  smoke check (Free Local Mode, same launch contract as
//  ReleaseWorkflowUITests) proves every destination is still reachable and the
//  app stays running. It is NOT manual acceptance. Lines starting with
//  "NAV_REPORT" are copied into the CI summary.
// =============================================================================

@MainActor
final class SettlementsNavigationUITests: XCTestCase {
    private let app = XCUIApplication()

    func testEveryTabDestinationIsReachable() throws {
        continueAfterFailure = false
        app.launchArguments = ["-DriverHubUITest"]
        app.launchEnvironment["DRIVER_HUB_UI_TEST_RESET"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["dashboard.addLoad"].waitForExistence(timeout: 15),
                      "Dashboard did not load")

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        let tabs = tabBar.buttons.allElementsBoundByIndex.map(\.label)
        report("tab bar = \(tabs.joined(separator: " | "))")
        snapshot("home")

        for (name, title) in [("Settlements", "Settlements"), ("Loads", nil),
                              ("Expenses", nil), ("Maps", "Maps"), ("Settings", "Settings")] {
            let via = open(name)
            XCTAssertEqual(app.state, .runningForeground, "App stopped after opening \(name)")
            if let title {
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10),
                              "\(name) did not show its \(title) screen")
            }
            report("\(name) via \(via); navigation bars on screen = \(app.navigationBars.count)")
            snapshot(name)
        }

        // Local mode keeps settlements on the device, so the cloud
        // "database update" notice must not appear here.
        _ = open("Settlements")
        let backendNotice = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "database update")).firstMatch
        XCTAssertFalse(backendNotice.exists)
    }

    /// Opens a destination from the tab bar, or from the More list when iOS
    /// moved it there. Returns how it was reached.
    private func open(_ name: String) -> String {
        let direct = tabBarButton(name)
        if direct.exists {
            direct.tap()
            return "tab bar"
        }
        let more = tabBarButton("More")
        guard more.exists else {
            snapshot("missing-\(name)")
            XCTFail("\(name) is neither a tab nor under More")
            return "missing"
        }
        more.tap()
        // A destination opened earlier from More stays pushed; tapping More
        // again returns to the list, but go back explicitly if it did not.
        let moreBack = app.navigationBars.buttons["More"]
        if moreBack.waitForExistence(timeout: 1) { moreBack.tap() }
        let row = app.cells.staticTexts[name].firstMatch
        guard row.waitForExistence(timeout: 5) else {
            snapshot("more-list-without-\(name)")
            XCTFail("\(name) is not listed under More")
            return "missing"
        }
        row.tap()
        return "More"
    }

    private func tabBarButton(_ name: String) -> XCUIElement {
        app.tabBars.firstMatch.buttons[name]
    }

    private func report(_ line: String) {
        print("NAV_REPORT: \(line)")
        let a = XCTAttachment(string: line)
        a.lifetime = .keepAlways
        add(a)
    }

    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "nav-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
