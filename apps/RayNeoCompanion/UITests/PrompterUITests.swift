import XCTest

final class PrompterUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testDeveloperWorkbenchIsAvailableWithoutManuscriptAndPersistsTuning() {
        let app = launch()
        app.buttons["prompter-tuning-entry"].tap()
        let similarity = app.sliders["prompter-tuning-similarity"]
        reveal(similarity, in: app)
        XCTAssertTrue(similarity.exists)
        similarity.adjust(toNormalizedSliderPosition: 0.1)
        let value = similarity.value as? String
        capture(app, "prompter-workbench-matching")
        app.buttons["prompter-tuning-done"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["prompter-tuning-entry"].waitForExistence(timeout: 5))
        app.buttons["prompter-tuning-entry"].tap()
        reveal(similarity, in: app)
        XCTAssertEqual(similarity.value as? String, value)
        let nativeWidth = app.steppers["prompter-tuning-native-width"]
        reveal(nativeWidth, in: app)
        XCTAssertTrue(nativeWidth.exists)
        capture(app, "prompter-workbench-native-layout")
        let reset = app.buttons["prompter-tuning-reset"]
        reveal(reset, in: app); reset.tap()
        reveal(similarity, in: app)
        XCTAssertNotEqual(similarity.value as? String, value)
        app.buttons["prompter-tuning-done"].tap()
    }

    func testMultipleManuscriptsSelectionAndPositionSurviveRelaunch() {
        let app = launch()
        create("Opening remarks", text: "Welcome everyone to our meeting.\nToday we will introduce the project.\nOur first point is improving delivery.\nThank you for listening.", in: app)
        create("Closing remarks", text: "Thank you everyone.\nWe will meet again next month.", in: app)
        XCTAssertEqual(app.staticTexts["prompter-selected-title"].label, "Closing remarks")
        let opening = manuscript("Opening remarks", in: app)
        reveal(opening, in: app); opening.tap()
        reveal(app.staticTexts["prompter-selected-title"], in: app)
        XCTAssertEqual(app.staticTexts["prompter-selected-title"].label, "Opening remarks")
        reveal(app.buttons["prompter-open-session"], in: app); app.buttons["prompter-open-session"].tap()
        XCTAssertTrue(app.buttons["prompter-start-follow"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["prompter-start-follow"].isEnabled, "No microphone or recognition session starts without setup")
        app.buttons["辅助向后"].tap()
        capture(app, "prompter-reader-preview")
        app.buttons["prompter-end-session"].tap()
        app.terminate(); app.launch()
        XCTAssertEqual(app.staticTexts["prompter-selected-title"].label, "Opening remarks")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已保存阅读位置")).firstMatch.exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "prompter-manuscript-")).count, 2)
        capture(app, "prompter-library-restored-position")
    }

    func testDraftCannotBeDismissedWithoutSaveOrExplicitDiscard() {
        let app = launch()
        app.buttons["prompter-new"].tap()
        let title = app.textFields["prompter-editor-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Unfinished draft")
        app.buttons["prompter-editor-cancel"].tap()
        XCTAssertTrue(app.alerts.buttons["继续编辑"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.buttons["放弃修改"].firstMatch.exists)
        app.alerts.buttons["继续编辑"].firstMatch.tap()
        XCTAssertEqual(title.value as? String, "Unfinished draft")
        app.buttons["prompter-save"].tap()
        XCTAssertEqual(app.staticTexts["prompter-selected-title"].label, "Unfinished draft")
        XCTAssertFalse(app.buttons["prompter-open-session"].isEnabled)
        capture(app, "prompter-empty-draft-preserved")
        app.buttons["prompter-new"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Discard this draft")
        app.buttons["prompter-editor-cancel"].tap()
        XCTAssertTrue(app.alerts.buttons["放弃修改"].firstMatch.waitForExistence(timeout: 3))
        app.alerts.buttons["放弃修改"].firstMatch.tap()
        XCTAssertTrue(app.buttons["prompter-new"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["prompter-selected-title"].label, "Unfinished draft")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "prompter-manuscript-")).count, 1)
    }

    func testSearchDuplicateAndDeleteRequireExplicitChoice() {
        let app = launch()
        create("First speech", text: "This is the first speech.", in: app)
        create("Second speech", text: "This is the second speech.", in: app)
        let search = app.textFields["prompter-search"]
        reveal(search, in: app); search.tap(); search.typeText("First")
        let row = manuscript("First speech", in: app)
        reveal(row, in: app); row.press(forDuration: 1)
        app.buttons["复制稿件"].tap()
        reveal(app.staticTexts["prompter-selected-title"], in: app)
        XCTAssertTrue(app.staticTexts["prompter-selected-title"].label.contains("First speech"))
        // Clear search through its keyboard shortcut to show the newly created copy.
        search.tap(); search.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 2) { selectAll.tap(); search.typeText(XCUIKeyboardKey.delete.rawValue) }
        else { search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5)) }
        let copyTitle = app.staticTexts["prompter-selected-title"].label
        let copy = manuscript(copyTitle, in: app)
        reveal(copy, in: app); copy.press(forDuration: 1); app.buttons["删除"].tap()
        XCTAssertTrue(app.alerts.buttons["删除稿件"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.buttons["保留稿件"].firstMatch.exists)
        app.alerts.buttons["保留稿件"].firstMatch.tap()
        XCTAssertTrue(copy.exists)
        copy.press(forDuration: 1); app.buttons["删除"].tap()
        XCTAssertTrue(app.alerts.buttons["删除稿件"].firstMatch.waitForExistence(timeout: 3))
        app.alerts.buttons["删除稿件"].firstMatch.tap()
        XCTAssertFalse(manuscript(copyTitle, in: app).exists)
        capture(app, "prompter-library-delete-confirmed")
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-scope", UUID().uuidString, "--ui-tab", "5"]
        app.launch()
        XCTAssertTrue(app.buttons["prompter-new"].waitForExistence(timeout: 8))
        return app
    }
    private func create(_ title: String, text: String, in app: XCUIApplication) {
        reveal(app.buttons["prompter-new"], in: app); app.buttons["prompter-new"].tap()
        let titleField = app.textFields["prompter-editor-title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5)); titleField.tap(); titleField.typeText(title)
        let editor = app.textViews["prompter-input"]; editor.tap(); editor.typeText(text)
        app.buttons["prompter-save"].tap()
        XCTAssertTrue(app.staticTexts["prompter-selected-title"].waitForExistence(timeout: 5))
    }
    private func manuscript(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "prompter-manuscript-", title)).firstMatch
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 { if element.isHittable { return }; app.swipeUp() }
        for _ in 0..<8 { if element.isHittable { return }; app.swipeDown() }
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
