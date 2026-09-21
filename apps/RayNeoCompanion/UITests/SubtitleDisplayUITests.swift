import XCTest

final class SubtitleDisplayUITests: XCTestCase {
    func testIndependentSubtitleTabNeedsDeviceAndCannotStartMicrophoneInPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-scope", UUID().uuidString, "--ui-tab", "4"]
        app.launch()
        XCTAssertTrue(app.staticTexts["subtitle-display-status"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["tab-4"].exists)
        XCTAssertFalse(app.buttons["subtitle-display-open"].isEnabled)
        let confirmation = app.switches["subtitle-display-idle-confirmation"]
        XCTAssertEqual(confirmation.value as? String, "0")
        // SwiftUI exposes the whole labelled row as a Switch. Tap the trailing
        // control instead of the label's centre, and verify the actual state.
        confirmation.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(confirmation.value as? String, "1")
        XCTAssertFalse(app.buttons["subtitle-display-open"].isEnabled)
        XCTAssertTrue(app.staticTexts["subtitle-display-count"].label.contains("0 帧"))
        XCTAssertFalse(app.buttons["subtitle-display-play"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "subtitle-display-tab"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
