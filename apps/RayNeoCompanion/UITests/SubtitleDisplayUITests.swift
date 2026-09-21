import XCTest

final class SubtitleDisplayUITests: XCTestCase {
    func testIndependentSubtitleTabNeedsDeviceAndCannotStartMicrophoneInPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-scope", UUID().uuidString, "--ui-tab", "4"]
        app.launch()
        XCTAssertTrue(app.staticTexts["subtitle-display-status"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["tab-4"].exists)
        XCTAssertFalse(app.buttons["subtitle-display-open"].isEnabled)
        app.switches["subtitle-display-idle-confirmation"].tap()
        XCTAssertFalse(app.buttons["subtitle-display-open"].isEnabled)
        XCTAssertTrue(app.staticTexts["subtitle-display-count"].label.contains("0 帧"))
        XCTAssertFalse(app.buttons["subtitle-display-play"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "subtitle-display-tab"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
