import XCTest

/// Decodes the saved live-run fixtures (copies of phase-1-tests/runs/*-output.json)
/// — the same saved-run-as-regression-guard trick the backend eval uses. If the
/// Swift models drift from backend/app/models.py, these fail.
final class CheckReportDecodingTests: XCTestCase {
    private func loadFixture(_ name: String) throws -> CheckReport {
        let bundle = Bundle(for: CheckReportDecodingTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "json"),
            "fixture \(name).json missing from test bundle"
        )
        return try CheckReport.decoder().decode(CheckReport.self, from: Data(contentsOf: url))
    }

    /// run-0: Aelfric Eden polo — the brand gate fires (fakeable brand).
    func testDecodesGateOnRun() throws {
        let report = try loadFixture("run-0-output")

        XCTAssertEqual(report.listingFacts.brand, "Aelfric Eden")
        XCTAssertEqual(report.listingFacts.askingPrice, 28.0)
        XCTAssertEqual(report.priceRead.fairness, .fair)
        XCTAssertEqual(report.priceRead.retailEstimate, 72.0)
        XCTAssertEqual(report.verdict.recommendation, .negotiate)
        XCTAssertTrue(report.authFlag.applicable)
        XCTAssertFalse(report.authFlag.redFlags.isEmpty)
        XCTAssertFalse(report.listingTrust.questionsToAsk.isEmpty)
        XCTAssertNil(report.error)
    }

    /// run-1: Kenneth Cole jacket — non-fakeable brand, gate stays silent.
    func testDecodesGateOffRun() throws {
        let report = try loadFixture("run-1-output")

        XCTAssertEqual(report.listingFacts.brand, "Kenneth Cole")
        XCTAssertEqual(report.priceRead.fairness, .steal)
        XCTAssertEqual(report.verdict.recommendation, .buy)
        XCTAssertFalse(report.authFlag.applicable)
        XCTAssertTrue(report.authFlag.redFlags.isEmpty)
        XCTAssertTrue(report.authFlag.whatToInspect.isEmpty)
    }

    /// Error reports carry the calibrated message; nothing else should render.
    func testDecodesErrorReport() throws {
        let json = """
        {
          "listing_facts": {"brand": null, "model_or_name": null, "category": null,
            "size": null, "listed_condition": null, "asking_price": null,
            "currency": "USD", "photo_observations": []},
          "price_read": {"retail_estimate": null, "used_estimate_low": null,
            "used_estimate_high": null, "fairness": null, "suggested_offer_low": null,
            "suggested_offer_high": null, "reasoning": ""},
          "listing_trust": {"missing_info": [], "concerns": [], "questions_to_ask": []},
          "auth_flag": {"applicable": false, "red_flags": [], "what_to_inspect": [],
            "confidence": null},
          "verdict": {"recommendation": null, "one_line": "", "user_context": null},
          "error": "No screenshots received — share the listing photos to analyze."
        }
        """
        let report = try CheckReport.decoder().decode(CheckReport.self, from: Data(json.utf8))
        XCTAssertNotNil(report.error)
        XCTAssertNil(report.listingFacts.askingPrice)
        XCTAssertNil(report.priceRead.fairness)
    }
}
