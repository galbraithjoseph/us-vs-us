import XCTest
@testable import UsVsUs

final class FoundationTests: XCTestCase {
    func testApplicationBundleIdentifier() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.galbraiths.joseph1970.usvsus")
    }
}
