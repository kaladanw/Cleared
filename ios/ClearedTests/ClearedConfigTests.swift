import XCTest

final class ClearedConfigTests: XCTestCase {
    /// The test bundle has no ClearedBackendURL Info.plist key, so the config
    /// must report unconfigured rather than inventing a URL.
    func testUnconfiguredBundleReportsNotConfigured() {
        XCTAssertNil(ClearedConfig.backendURL)
        XCTAssertNil(ClearedConfig.sharedToken)
        XCTAssertFalse(ClearedConfig.isConfigured)
        // No team-prefixed group either: the auth wiring must refuse rather
        // than write an app-private Keychain item the extension can't read.
        XCTAssertNil(ClearedConfig.keychainAccessGroup)
    }
}
