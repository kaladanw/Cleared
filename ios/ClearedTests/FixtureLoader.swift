import Foundation
import XCTest

/// Loads files from ClearedTests/Fixtures. In Xcode they're bundle resources of
/// the test target; in the SwiftPM harness used for Linux runs, `Bundle.module`.
enum FixtureLoader {
    private final class Token {}

    static func data(_ name: String, _ ext: String) throws -> Data {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Token.self)
        #endif
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: ext)
                ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "fixture \(name).\(ext) missing from test bundle"
        )
        return try Data(contentsOf: url)
    }

    static func string(_ name: String, _ ext: String) throws -> String {
        String(decoding: try data(name, ext), as: UTF8.self)
    }
}
