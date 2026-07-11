import XCTest

final class ClearedConfigTests: XCTestCase {
    /// The test bundle has no ClearedBackendURL Info.plist key, so the config
    /// must report unconfigured rather than inventing a URL.
    func testUnconfiguredBundleReportsNotConfigured() {
        XCTAssertNil(ClearedConfig.backendURL)
        XCTAssertNil(ClearedConfig.sharedToken)
        XCTAssertFalse(ClearedConfig.isConfigured)
    }
}
