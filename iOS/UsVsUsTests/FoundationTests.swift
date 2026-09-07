import XCTest
@testable import UsVsUs

final class FoundationTests: XCTestCase {
    func testCloudCapabilityPlist() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CKSharingSupported") as? Bool, true)
        XCTAssertTrue((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("remote-notification") == true)
        XCTAssertEqual(CloudConfiguration.containerIdentifier, "iCloud." + CloudConfiguration.bundleIdentifier)
    }
    func testApplicationBundleIdentifier() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.galbraiths.joseph1970.usvsus")
    }
}
