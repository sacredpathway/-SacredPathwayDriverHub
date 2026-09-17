import XCTest

@MainActor
final class ReleaseWorkflowUITests: XCTestCase {
    private let app = XCUIApplication()

    func testValidationLoadLifecycle() throws {
        prepareApp()
        openLoadsTab()
        let addLoad = app.buttons["loads.add.empty"]
        guard addLoad.waitForExistence(timeout: 10) else {
            attachFailureState(named: "loads-empty-add-control")
            XCTFail("Loads did not expose the empty-state Add Load control")
            return
        }
        addLoad.tap()
        let manualEntry = app.buttons["loads.add.manual"]
        guard manualEntry.waitForExistence(timeout: 10) else {
            attachFailureState(named: "loads-manual-entry-control")
            XCTFail("Load source chooser did not expose manual entry")
            return
        }
        openManualEntry(manualEntry)

        replace(app.textFields["load.form.loadNumber"], with: "VALIDATION LOAD")
        replace(app.textFields["load.form.broker"], with: "VALIDATION BROKER")
        replace(app.textFields["load.form.origin"], with: "Test City, TX")
        replace(app.textFields["load.form.destination"], with: "Test City, OK")
        replace(app.textFields["load.form.miles"], with: "100")
        replace(app.textFields["load.form.lineHaul"], with: "100.00")

        app.buttons["load.form.save"].tap()
        if app.alerts["Add this broker to contacts?"].waitForExistence(timeout: 3) {
            app.alerts.buttons["Skip"].tap()
        }
        let savedOK = app.buttons["OK"]
        guard savedOK.waitForExistence(timeout: 5) else {
            attachFailureState(named: "load-save-confirmation")
            XCTFail("Save completed but the confirmation control was not exposed")
            return
        }
        savedOK.tap()

        let savedLoad = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "load.row.")
        ).firstMatch
        XCTAssertTrue(savedLoad.waitForExistence(timeout: 5))
        let persistedRecordIdentifier = savedLoad.identifier
        XCTAssertNotEqual(persistedRecordIdentifier, "load.row.unsaved")
        XCTAssertTrue(savedLoad.label.contains("VALIDATION LOAD"))
        XCTAssertTrue(savedLoad.label.contains("Test City, TX → Test City, OK"))

        launchPreservingLocalData()
        openLoadsTab()
        let relaunchedLoad = app.buttons[persistedRecordIdentifier]
        XCTAssertTrue(relaunchedLoad.waitForExistence(timeout: 5))
        XCTAssertTrue(relaunchedLoad.label.contains("Test City, TX → Test City, OK"))
        relaunchedLoad.tap()

        XCTAssertTrue(app.buttons["load.detail.menu"].waitForExistence(timeout: 5))
        app.buttons["load.detail.menu"].tap()
        XCTAssertTrue(app.buttons["Edit Load"].waitForExistence(timeout: 5))
        app.buttons["Edit Load"].tap()
        assertExactValue("VALIDATION LOAD", in: app.textFields["load.form.loadNumber"])
        assertExactValue("VALIDATION BROKER", in: app.textFields["load.form.broker"])
        assertExactValue("Test City, TX", in: app.textFields["load.form.origin"])
        let destination = app.textFields["load.form.destination"]
        assertExactValue("Test City, OK", in: destination)
        assertExactValue("100", in: app.textFields["load.form.miles"])
        assertExactValue("100.00", in: app.textFields["load.form.lineHaul"])

        replace(destination, with: "Edited City, OK")
        replace(app.textFields["load.form.miles"], with: "225")
        replace(app.textFields["load.form.lineHaul"], with: "725.50")
        replace(app.textFields["load.form.broker"], with: "EDITED BROKER")
        app.buttons["load.form.saveChanges"].tap()

        if app.buttons["OK"].waitForExistence(timeout: 3) {
            app.buttons["OK"].tap()
        }
        app.terminate()
        launchPreservingLocalData()
        openLoadsTab()

        let persisted = app.buttons[persistedRecordIdentifier]
        XCTAssertTrue(persisted.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "identifier == %@", persistedRecordIdentifier)
        ).count, 1, "Relaunch produced a duplicate row for the persisted load identifier")
        XCTAssertTrue(persisted.label.contains("Test City, TX → Edited City, OK"))
        XCTAssertFalse(persisted.label.contains("Test City, OKEdited City, OK"))
        persisted.tap()
        let route = app.staticTexts["load.detail.route"]
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        XCTAssertEqual(route.value as? String, "Test City, TX → Edited City, OK")
        app.buttons["load.detail.menu"].tap()
        app.buttons["Edit Load"].tap()
        assertExactValue("EDITED BROKER", in: app.textFields["load.form.broker"])
        assertExactValue("Edited City, OK", in: app.textFields["load.form.destination"])
        assertExactValue("225", in: app.textFields["load.form.miles"])
        assertExactValue("725.50", in: app.textFields["load.form.lineHaul"])
        app.buttons["load.form.cancel"].tap()
        app.buttons["load.detail.menu"].tap()
        app.buttons["Delete Load"].tap()
        XCTAssertTrue(app.sheets.buttons["Delete Load"].waitForExistence(timeout: 3)
                      || app.alerts.buttons["Delete Load"].waitForExistence(timeout: 3))
        if app.sheets.buttons["Delete Load"].exists {
            app.sheets.buttons["Delete Load"].tap()
        } else {
            app.alerts.buttons["Delete Load"].tap()
        }
        XCTAssertFalse(app.buttons[persistedRecordIdentifier].waitForExistence(timeout: 5))

        // A navigation dismissal is not proof of deletion. Relaunch against
        // the same application container and assert the UUID-backed row is
        // still absent after LocalLoadsRepository reloads from loads.json.
        launchPreservingLocalData()
        openLoadsTab()
        XCTAssertFalse(app.buttons[persistedRecordIdentifier].waitForExistence(timeout: 5))
    }

    private func prepareApp() {
        continueAfterFailure = false
        app.launchArguments = ["-DriverHubUITest"]
        app.launchEnvironment["DRIVER_HUB_UI_TEST_RESET"] = "1"
        app.launch()
        guard app.buttons["dashboard.addLoad"].waitForExistence(timeout: 15) else {
            attachFailureState(named: "dashboard-precondition")
            XCTFail("Dashboard did not expose the Add Load control (identifier: dashboard.addLoad)")
            return
        }
    }

    private func attachFailureState(named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name)-screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-accessibility-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func openLoadsTab() {
        let loadsTab = app.tabBars.buttons["Loads"]
        guard loadsTab.waitForExistence(timeout: 10) else {
            attachFailureState(named: "loads-tab-missing")
            XCTFail("Loads tab was not available")
            return
        }
        for _ in 0..<3 {
            loadsTab.tap()
            if loadsTab.waitForSelectedState(timeout: 2) {
                selectAllLoads()
                return
            }

            // XCTest occasionally resolves the native tab item correctly but
            // drops its synthesized accessibility tap. A center-coordinate tap
            // targets the same visible control and still requires selected-state
            // confirmation before the workflow may continue.
            loadsTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if loadsTab.waitForSelectedState(timeout: 2) {
                selectAllLoads()
                return
            }
        }
        attachFailureState(named: "loads-tab-not-selected")
        XCTFail("Loads tab never entered its selected state")
    }

    private func selectAllLoads() {
        let allLoads = app.buttons["loads.filter.all"]
        if app.buttons["loads.add.empty"].exists {
            return
        }
        guard allLoads.waitForExistence(timeout: 5) else {
            attachFailureState(named: "loads-all-filter-missing")
            XCTFail("Loads did not expose the All Loads filter")
            return
        }
        if !allLoads.isSelected {
            allLoads.tap()
        }
        XCTAssertTrue(allLoads.waitForSelectedState(timeout: 3),
                      "All Loads filter never entered its selected state")
    }

    private func launchPreservingLocalData() {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "DRIVER_HUB_UI_TEST_RESET")
        XCTAssertFalse(app.launchEnvironment.keys.contains("DRIVER_HUB_UI_TEST_RESET"))
        app.launch()
        XCTAssertTrue(app.buttons["dashboard.addLoad"].waitForExistence(timeout: 15))
    }

    private func openManualEntry(_ button: XCUIElement) {
        let loadNumber = app.textFields["load.form.loadNumber"]
        for _ in 0..<3 {
            button.tap()
            if loadNumber.waitForExistence(timeout: 2) {
                return
            }

            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if loadNumber.waitForExistence(timeout: 2) {
                return
            }
        }
        attachFailureState(named: "manual-entry-navigation-failed")
        XCTFail("Manual-entry control never opened the Load form")
    }

    private func replace(_ field: XCUIElement, with value: String) {
        guard field.waitForExistence(timeout: 10) else {
            attachFailureState(named: "form-field-missing")
            XCTFail("Expected form field did not become available")
            return
        }

        for _ in 0..<3 {
            field.tap()
            if !field.waitForKeyboardFocus(timeout: 1) {
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            guard field.waitForKeyboardFocus(timeout: 2) else {
                continue
            }

            field.typeKey("a", modifierFlags: .command)
            field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
            field.typeText(value)
            if field.value as? String == value {
                return
            }
        }
        attachFailureState(named: "form-field-\(field.identifier)-value-mismatch")
        XCTFail("Field \(field.identifier) did not accept exact value \(value); actual: \(String(describing: field.value))")
    }

    private func assertExactValue(_ expected: String, in field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "Expected field \(field.identifier) did not exist")
        XCTAssertEqual(field.value as? String, expected,
                       "Field \(field.identifier) did not contain the exact persisted value")
    }
}

private extension XCUIElement {
    func waitForSelectedState(timeout: TimeInterval) -> Bool {
        let selected = NSPredicate(format: "isSelected == true")
        let expectation = XCTNSPredicateExpectation(predicate: selected, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForKeyboardFocus(timeout: TimeInterval) -> Bool {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        let expectation = XCTNSPredicateExpectation(predicate: focused, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
