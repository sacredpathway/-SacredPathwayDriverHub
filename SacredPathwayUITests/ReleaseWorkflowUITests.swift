import XCTest

@MainActor
final class ReleaseWorkflowUITests: XCTestCase {
    private let app = XCUIApplication()
    private var loadNumber = ""
    private var persistedRecordIdentifier = ""

    func testValidationLoadLifecycle() {
        continueAfterFailure = false
        loadNumber = "UI-\(UUID().uuidString.prefix(8))"

        prepareControlledLaunch()
        openLoads()
        openManualEntry()

        replace(app.textFields["load.form.loadNumber"], with: loadNumber, stage: "create-load-number")
        replace(app.textFields["load.form.broker"], with: "VALIDATION BROKER", stage: "create-broker")
        replace(app.textFields["load.form.origin"], with: "Test City, TX", stage: "create-origin")
        replace(app.textFields["load.form.destination"], with: "Test City, OK", stage: "create-destination")
        replace(app.textFields["load.form.miles"], with: "100", stage: "create-miles")
        replace(app.textFields["load.form.lineHaul"], with: "100.00", stage: "create-line-haul")

        tap(app.buttons["load.form.save"], stage: "save-created-load")
        let brokerPrompt = app.alerts["Add this broker to contacts?"]
        if brokerPrompt.waitForExistence(timeout: 3) {
            tap(brokerPrompt.buttons["Skip"], stage: "skip-broker-contact")
        }
        dismissRequiredAlert(title: "Load Saved!", stage: "confirm-created-load")

        let createdSummary = rowSummary(
            broker: "VALIDATION BROKER",
            destination: "Test City, OK",
            miles: "100",
            lineHaul: "100.00"
        )
        let createdRow = requireSingleLogicalRow(summary: createdSummary, stage: "created-row")
        persistedRecordIdentifier = createdRow.identifier
        guard persistedRecordIdentifier.hasPrefix("load.row."),
              persistedRecordIdentifier != "load.row.unsaved" else {
            fail(stage: "created-row-identifier",
                 expected: "persisted load.row.<uuid>",
                 actual: persistedRecordIdentifier,
                 element: createdRow)
            return
        }

        relaunchPreservingData(stage: "first-relaunch")
        openLoads()
        let relaunchedRow = requireSingleLogicalRow(summary: createdSummary, stage: "created-row-after-relaunch")
        assertExact(persistedRecordIdentifier, actual: relaunchedRow.identifier,
                    stage: "created-row-uuid-after-relaunch", element: relaunchedRow)
        tap(relaunchedRow, stage: "open-created-load")

        openEditForm(stage: "open-first-edit")
        assertForm(
            broker: "VALIDATION BROKER",
            destination: "Test City, OK",
            miles: "100",
            lineHaul: "100.00",
            stage: "created-fields-after-relaunch"
        )
        replace(app.textFields["load.form.destination"], with: "Edited City, OK",
                clearingExistingValue: true, stage: "edit-destination")
        replace(app.textFields["load.form.miles"], with: "225",
                clearingExistingValue: true, stage: "edit-miles")
        replace(app.textFields["load.form.lineHaul"], with: "725.50",
                clearingExistingValue: true, stage: "edit-line-haul")
        replace(app.textFields["load.form.broker"], with: "EDITED BROKER",
                clearingExistingValue: true, stage: "edit-broker")
        tap(app.buttons["load.form.saveChanges"], stage: "save-edited-load")
        dismissRequiredAlert(title: "Changes Saved!", stage: "confirm-edited-load")

        relaunchPreservingData(stage: "second-relaunch")
        openLoads()
        let editedSummary = rowSummary(
            broker: "EDITED BROKER",
            destination: "Edited City, OK",
            miles: "225",
            lineHaul: "725.50"
        )
        let editedRow = requireSingleLogicalRow(summary: editedSummary, stage: "edited-row-after-relaunch")
        assertExact(persistedRecordIdentifier, actual: editedRow.identifier,
                    stage: "edited-row-uuid-after-relaunch", element: editedRow)
        tap(editedRow, stage: "open-edited-load")

        openEditForm(stage: "open-second-edit")
        assertForm(
            broker: "EDITED BROKER",
            destination: "Edited City, OK",
            miles: "225",
            lineHaul: "725.50",
            stage: "edited-fields-after-relaunch"
        )
        tap(app.buttons["load.form.cancel"], stage: "cancel-read-only-edit")
        require(app.buttons["load.detail.menu"], stage: "detail-return-after-cancel")

        // Exercise the previously risky lifecycle state before deletion:
        // persist the view graph through a full background/foreground cycle.
        XCUIDevice.shared.press(.home)
        app.activate()
        require(app.buttons["load.detail.menu"], stage: "detail-after-background-foreground")

        tap(app.buttons["load.detail.menu"], stage: "open-delete-menu")
        tap(app.buttons["Delete Load"], stage: "select-delete")
        let confirmation = app.sheets["Delete this load?"]
        guard confirmation.waitForExistence(timeout: 5) else {
            fail(stage: "delete-confirmation", expected: "Delete this load? sheet",
                 actual: app.debugDescription)
            return
        }
        tap(confirmation.buttons["Delete Load"], stage: "confirm-delete")
        assertDeleted(stage: "immediate-delete")

        relaunchPreservingData(stage: "post-delete-relaunch-one")
        openLoads()
        assertDeleted(stage: "post-delete-relaunch-one")

        XCUIDevice.shared.press(.home)
        app.activate()
        require(app.tabBars.buttons["Loads"], stage: "loads-after-post-delete-background")
        assertDeleted(stage: "post-delete-background-foreground")

        relaunchPreservingData(stage: "post-delete-relaunch-two")
        openLoads()
        assertDeleted(stage: "post-delete-relaunch-two")
        attachEvidence(stage: "lifecycle-success", expected: "deleted and not resurrected",
                       actual: "no logical row and no persisted UUID row")
    }

    private func prepareControlledLaunch() {
        app.launchArguments = ["-DriverHubUITest"]
        app.launchEnvironment["DRIVER_HUB_UI_TEST_RESET"] = "1"
        app.launch()
        require(app.tabBars.buttons["Loads"], stage: "controlled-launch")
    }

    private func relaunchPreservingData(stage: String) {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "DRIVER_HUB_UI_TEST_RESET")
        guard app.launchEnvironment["DRIVER_HUB_UI_TEST_RESET"] == nil else {
            fail(stage: stage, expected: "reset environment removed",
                 actual: "reset environment still present")
            return
        }
        app.launch()
        require(app.tabBars.buttons["Loads"], stage: stage)
    }

    private func openLoads() {
        let loads = app.tabBars.buttons["Loads"]
        require(loads, stage: "loads-tab")
        if !loads.isSelected {
            tap(loads, stage: "select-loads-tab")
            guard wait(loads, predicate: NSPredicate(format: "isSelected == true"), timeout: 5) else {
                fail(stage: "select-loads-tab", expected: "selected Loads tab",
                     actual: loads.debugDescription, element: loads)
                return
            }
        }

        if app.buttons["loads.add.empty"].exists {
            require(app.buttons["loads.add.empty"], stage: "empty-loads-state")
            return
        }

        let allLoads = app.buttons["loads.filter.all"]
        require(allLoads, stage: "all-loads-filter")
        if !allLoads.isSelected {
            tap(allLoads, stage: "select-all-loads")
            guard wait(allLoads, predicate: NSPredicate(format: "isSelected == true"), timeout: 5) else {
                fail(stage: "select-all-loads", expected: "selected All Loads filter",
                     actual: allLoads.debugDescription, element: allLoads)
                return
            }
        }
    }

    private func openManualEntry() {
        tap(app.buttons["loads.add.empty"], stage: "open-add-load-chooser")
        let manual = app.buttons["loads.add.manual"]
        require(manual, stage: "manual-entry-control")
        tap(manual, stage: "open-manual-entry")
        require(app.textFields["load.form.loadNumber"], stage: "manual-entry-form")
    }

    private func openEditForm(stage: String) {
        tap(app.buttons["load.detail.menu"], stage: "\(stage)-menu")
        tap(app.buttons["Edit Load"], stage: "\(stage)-action")
        require(app.textFields["load.form.loadNumber"], stage: "\(stage)-form")
    }

    private func replace(
        _ field: XCUIElement,
        with value: String,
        clearingExistingValue: Bool = false,
        stage: String
    ) {
        require(field, stage: stage)
        field.tap()
        guard wait(field, predicate: NSPredicate(format: "hasKeyboardFocus == true"), timeout: 3) else {
            fail(stage: stage, expected: "keyboard focus on \(field.identifier)",
                 actual: field.debugDescription, element: field)
            return
        }
        if clearingExistingValue {
            field.typeKey("a", modifierFlags: .command)
        }
        field.typeText(value)
        assertExact(value, actual: field.value as? String, stage: stage, element: field)
    }

    private func assertForm(
        broker: String,
        destination: String,
        miles: String,
        lineHaul: String,
        stage: String
    ) {
        assertField("load.form.loadNumber", equals: loadNumber, stage: stage)
        assertField("load.form.broker", equals: broker, stage: stage)
        assertField("load.form.origin", equals: "Test City, TX", stage: stage)
        assertField("load.form.destination", equals: destination, stage: stage)
        assertField("load.form.miles", equals: miles, stage: stage)
        assertField("load.form.lineHaul", equals: lineHaul, stage: stage)
    }

    private func assertField(_ identifier: String, equals expected: String, stage: String) {
        let field = app.textFields[identifier]
        require(field, stage: "\(stage)-\(identifier)")
        assertExact(expected, actual: field.value as? String,
                    stage: "\(stage)-\(identifier)", element: field)
    }

    private func rowSummary(
        broker: String,
        destination: String,
        miles: String,
        lineHaul: String
    ) -> String {
        "number=\(loadNumber);broker=\(broker);origin=Test City, TX;" +
        "destination=\(destination);miles=\(miles);lineHaul=\(lineHaul)"
    }

    private func requireSingleLogicalRow(summary: String, stage: String) -> XCUIElement {
        let businessKeyMatches = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "#\(loadNumber)")
        )
        guard businessKeyMatches.count == 1 else {
            fail(stage: stage, expected: "one logical row for \(loadNumber)",
                 actual: "\(businessKeyMatches.count) logical rows")
            return app.buttons["missing.\(stage)"]
        }

        let rows = app.buttons.matching(NSPredicate(format: "value == %@", summary))
        guard rows.count == 1 else {
            fail(stage: stage, expected: "one row with exact value \(summary)",
                 actual: "\(rows.count) exact rows")
            return app.buttons["missing.\(stage)"]
        }
        return rows.firstMatch
    }

    private func assertDeleted(stage: String) {
        let logicalCount = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "#\(loadNumber)")
        ).count
        let uuidExists = persistedRecordIdentifier.isEmpty
            ? false
            : app.buttons[persistedRecordIdentifier].exists
        guard logicalCount == 0, !uuidExists else {
            fail(stage: stage, expected: "zero logical rows and no persisted UUID row",
                 actual: "logicalRows=\(logicalCount), uuidExists=\(uuidExists)",
                 element: persistedRecordIdentifier.isEmpty ? nil : app.buttons[persistedRecordIdentifier])
            return
        }
    }

    private func dismissRequiredAlert(title: String, stage: String) {
        let alert = app.alerts[title]
        guard alert.waitForExistence(timeout: 5) else {
            fail(stage: stage, expected: "\(title) alert", actual: app.debugDescription)
            return
        }
        tap(alert.buttons["OK"], stage: stage)
        guard wait(alert, predicate: NSPredicate(format: "exists == false"), timeout: 5) else {
            fail(stage: stage, expected: "\(title) dismissed",
                 actual: alert.debugDescription, element: alert)
            return
        }
    }

    private func tap(_ element: XCUIElement, stage: String) {
        require(element, stage: stage)
        element.tap()
    }

    private func require(_ element: XCUIElement, stage: String) {
        let ready = NSPredicate(format: "exists == true AND hittable == true")
        guard wait(element, predicate: ready, timeout: 10) else {
            fail(stage: stage, expected: "existing, hittable \(element.identifier)",
                 actual: element.debugDescription, element: element)
            return
        }
    }

    private func assertExact(
        _ expected: String,
        actual: String?,
        stage: String,
        element: XCUIElement? = nil
    ) {
        guard actual == expected else {
            fail(stage: stage, expected: expected, actual: actual ?? "<nil>", element: element)
            return
        }
    }

    private func wait(
        _ element: XCUIElement,
        predicate: NSPredicate,
        timeout: TimeInterval
    ) -> Bool {
        XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: timeout
        ) == .completed
    }

    private func fail(
        stage: String,
        expected: String,
        actual: String,
        element: XCUIElement? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        attachEvidence(stage: stage, expected: expected, actual: actual, element: element)
        XCTFail("[\(stage)] expected \(expected); actual \(actual)", file: file, line: line)
    }

    private func attachEvidence(
        stage: String,
        expected: String,
        actual: String,
        element: XCUIElement? = nil
    ) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(stage)-screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(stage)-accessibility-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)

        let metadata = [
            "stage=\(stage)",
            "loadNumber=\(loadNumber)",
            "persistedIdentifier=\(persistedRecordIdentifier)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))",
            "screen=\(app.navigationBars.firstMatch.identifier)",
            "expected=\(expected)",
            "actual=\(actual)",
            "element=\(element?.debugDescription ?? "<none>")"
        ].joined(separator: "\n")
        let details = XCTAttachment(string: metadata)
        details.name = "\(stage)-evidence"
        details.lifetime = .keepAlways
        add(details)
    }
}
