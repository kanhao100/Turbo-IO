import XCTest

final class RealtimeSubtitlesUITests:XCTestCase {
    func testLiveHistoryAndSettingsWithoutCredentialsOrDevice() {
        let app=XCUIApplication();app.launchArguments=["--ui-test-scope",UUID().uuidString,"--ui-tab","4"];app.launch()
        XCTAssertTrue(app.staticTexts["realtime-status"].waitForExistence(timeout:8))
        capture(app,"realtime-subtitles-live")
        app.segmentedControls["realtime-pages"].buttons["历史记录"].tap()
        XCTAssertTrue(app.textFields["subtitle-history-search"].waitForExistence(timeout:3))
        capture(app,"realtime-subtitles-history")
        app.buttons["realtime-settings"].tap()
        XCTAssertTrue(app.secureTextFields["subtitle-api-key"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["subtitle-save-settings"].isEnabled)
        capture(app,"realtime-subtitles-settings")
    }
    private func capture(_ app:XCUIApplication,_ name:String) {
        let item=XCTAttachment(screenshot:app.screenshot());item.name=name;item.lifetime = .keepAlways;add(item)
    }
}
