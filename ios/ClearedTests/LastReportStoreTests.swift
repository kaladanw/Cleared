import Foundation
import XCTest

final class LastReportStoreTests: XCTestCase {
    func testSaveLoadRoundTripInIsolatedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "run-0-output", withExtension: "json"))
        let report = try CheckReport.decoder().decode(CheckReport.self, from: Data(contentsOf: fixture))

        XCTAssertNil(LastReportStore.load(from: directory))
        try LastReportStore.save(report, in: directory)
        let loaded = try XCTUnwrap(LastReportStore.load(from: directory))

        XCTAssertEqual(loaded.verdict.recommendation, report.verdict.recommendation)
        XCTAssertEqual(loaded.verdict.oneLine, report.verdict.oneLine)
        XCTAssertEqual(loaded.listingFacts.brand, report.listingFacts.brand)
        XCTAssertEqual(loaded.priceRead.retailEstimate, report.priceRead.retailEstimate)
        XCTAssertEqual(loaded.authFlag.applicable, report.authFlag.applicable)
        XCTAssertEqual(loaded.authFlag.redFlags, report.authFlag.redFlags)
    }
}
