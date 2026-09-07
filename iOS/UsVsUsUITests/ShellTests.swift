import XCTest

final class ShellTests: XCTestCase {
    @MainActor
    func testNavigateAndRelaunchResetsFixtureChanges() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Set up your pair"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["setupHelp"].exists)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["iCloud is unavailable. You can still use this device."].exists)
        let toggle = app.switches["showSetupHelp"]
        XCTAssertEqual(toggle.value as? String, "1")
        // SwiftUI exposes the entire labeled row as the switch on iOS 27.
        // Tap the trailing control rather than the inert center of the label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["Home"].tap()
        XCTAssertFalse(app.staticTexts["setupHelp"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["setupHelp"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSeededAndEmptyRunsDoNotShareData() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--fixture-help-hidden"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Set up your pair"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["setupHelp"].exists)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["setupHelp"].waitForExistence(timeout: 10))
    }
}
