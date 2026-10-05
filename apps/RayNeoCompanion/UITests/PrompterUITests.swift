import XCTest

final class PrompterUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testDeveloperWorkbenchIsAvailableWithoutManuscriptAndPersistsTuning() {
        let app = launch()
        app.buttons["prompter-tuning-entry"].tap()
        let uniformAssistance = app.switches["prompter-tuning-uniform-assist"]
        reveal(uniformAssistance, in: app)
        XCTAssertTrue(uniformAssistance.exists)
        let advanced = app.buttons["prompter-tuning-advanced"]
        reveal(advanced, in: app); advanced.tap()
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
        reveal(advanced, in: app); advanced.tap()
        reveal(similarity, in: app)
        XCTAssertEqual(similarity.value as? String, value)
        let hold = app.sliders["prompter-tuning-uniform-hold"]
        reveal(hold, in: app); XCTAssertTrue(hold.exists)
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

    func testUniformPhoneStartIsVisibleWithoutSpeechRecognitionSetup() {
        let app = launch()
        let script = "Welcome everyone.\nThank you for listening."
        create("Fixed pace speech", text: script, in: app)
        let uniform = app.buttons["prompter-open-uniform"]
        reveal(uniform, in: app); uniform.tap()
        let output = app.segmentedControls["prompter-uniform-output"]
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        output.buttons["手机提词"].tap()
        let start = app.buttons["prompter-phone-uniform-start"]
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(start.isEnabled, "Fixed pace reading has no ASR credential requirement")
        XCTAssertFalse(app.buttons["prompter-start-follow"].exists)
        start.tap()
        XCTAssertTrue(start.label.contains("暂停匀速滚动"))
        let progress = app.staticTexts["prompter-uniform-progress"]
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "0%"), object: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 6), .completed)
        capture(app, "prompter-uniform-phone-running")
        start.tap()
        XCTAssertTrue(start.label.contains("开始手机匀速滚动"))
        app.buttons["prompter-end-session"].tap()
    }

    func testDebugModeShowsOriginalCursorWithoutStartingMicrophone() {
        let app = launch()
        create("Debug speech", text: "Welcome everyone to our meeting.\nToday we introduce our project.\nThe next part explains the plan.\nThank you for listening.", in: app)
        let entry = app.buttons["prompter-tuning-entry"]
        reveal(entry, in: app); entry.tap()
        let debug = app.switches["prompter-tuning-debug-mode"]
        reveal(debug, in: app)
        debug.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: debug)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
        app.buttons["prompter-tuning-done"].tap()
        reveal(entry, in: app); entry.tap()
        reveal(debug, in: app)
        XCTAssertEqual(debug.value as? String, "1", "Debug mode remains enabled after reopening its settings")
        app.buttons["prompter-tuning-done"].tap()
        let open = app.buttons["prompter-open-session"]
        reveal(open, in: app); open.tap()
        XCTAssertTrue(app.otherElements["prompter-debug-panel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["prompter-debug-recognition"].label.contains("等待语音识别"))
        let debugShortcut = app.buttons["prompter-debug-toggle"]
        XCTAssertEqual(debugShortcut.label, "关闭调试")
        debugShortcut.tap()
        XCTAssertTrue(app.otherElements["prompter-debug-panel"].waitForNonExistence(timeout: 3))
        debugShortcut.tap()
        XCTAssertTrue(app.otherElements["prompter-debug-panel"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["prompter-start-follow"].isEnabled)
        let displayed = app.staticTexts["prompter-debug-displayed"]
        let before = displayed.label
        app.buttons["辅助向后"].tap()
        XCTAssertNotEqual(displayed.label, before)
        let reader = app.textViews["prompter-reader"]
        XCTAssertTrue((reader.value as? String)?.contains("调试高亮") == true)
        capture(app, "prompter-debug-original-cursor")
        app.buttons["prompter-end-session"].tap()
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
        reveal(search, in: app); search.tap(); search.typeText("First\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        let row = manuscript("First speech", in: app)
        reveal(row, in: app); row.press(forDuration: 1)
        app.buttons["复制稿件"].tap()
        reveal(app.staticTexts["prompter-selected-title"], in: app)
        XCTAssertTrue(app.staticTexts["prompter-selected-title"].label.contains("First speech"))
        // Clear search through its keyboard shortcut to show the newly created copy.
        reveal(search, in: app); search.tap(); search.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 2) { selectAll.tap(); search.typeText(XCUIKeyboardKey.delete.rawValue) }
        else { search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5)) }
        search.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
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
        // Lazy Form controls do not have an accessibility snapshot until they
        // enter the viewport. Check existence before reading any attributes.
        let scroll = app.scrollViews.firstMatch
        let collection = app.collectionViews.firstMatch
        let container = scroll.exists ? scroll : (collection.exists ? collection : app)
        var manuscript = false
        for attempt in 0..<16 {
            if element.exists {
                manuscript = element.identifier.hasPrefix("prompter-manuscript-")
                let isSwitch = element.elementType == .switch
                if !manuscript && !isSwitch && element.isHittable { return }
                if manuscript || isSwitch {
                    // Complete rows must clear native chrome, the keyboard, and
                    // custom tabs; a partially clipped switch can report hittable.
                    let tab = app.buttons["tab-5"]
                    let keyboard = app.keyboards.firstMatch
                    let navigation = app.navigationBars.firstMatch
                    var bottom = isSwitch ? min(app.frame.maxY - 44, container.frame.maxY) : app.frame.maxY
                    if tab.exists && tab.isHittable { bottom = min(bottom, tab.frame.minY) }
                    if keyboard.exists { bottom = min(bottom, keyboard.frame.minY) }
                    let top = isSwitch && navigation.exists ? navigation.frame.maxY + 8 : app.frame.minY + 60
                    let viewport = CGRect(x: app.frame.minX, y: top,
                                          width: app.frame.width, height: max(0, bottom - top - 8))
                    if element.isHittable && viewport.contains(element.frame) { return }
                    if element.frame.minY < viewport.minY { container.swipeDown() }
                    else { container.swipeUp() }
                    continue
                }
            }
            if attempt < 7 { container.swipeUp() }
            else { container.swipeDown() }
        }
        XCTFail(manuscript ? "Manuscript card could not be brought fully into the visible reader area" : "Requested control could not be brought into view")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
