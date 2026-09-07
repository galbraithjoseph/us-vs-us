import XCTest

final class ShellTests: XCTestCase {
    @MainActor
    func testLaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Set up your pair"].waitForExistence(timeout: 10))
    }
}
