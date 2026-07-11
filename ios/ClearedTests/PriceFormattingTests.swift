import Foundation
import XCTest

final class PriceFormattingTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    func testMissingPricesRemainExplicitlyUnverified() {
        XCTAssertEqual(PriceFormatting.money(nil, currency: "USD", locale: locale), "Couldn't verify")
        XCTAssertEqual(PriceFormatting.range(nil, nil, currency: "USD", locale: locale), "Couldn't verify")
    }

    func testFormatsApproximateAndPartialRangesWithoutInventingBounds() {
        XCTAssertEqual(PriceFormatting.money(72, currency: "USD", approximate: true, locale: locale), "~$72")
        XCTAssertEqual(PriceFormatting.range(25, nil, currency: "USD", locale: locale), "From $25")
        XCTAssertEqual(PriceFormatting.range(nil, 40, currency: "USD", locale: locale), "Up to $40")
    }
}
