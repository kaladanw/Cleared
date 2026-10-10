import XCTest

/// Branch (depop.app.link) pages saved from live requests with UA "Cleared/1.0".
final class DepopBranchParsingTests: XCTestCase {
    func testProductPageYieldsSlugAndID() throws {
        let html = try FixtureLoader.string("depop-branch-product", "html")
        XCTAssertEqual(
            DepopListingFetcher.parseBranchTarget(location: nil, html: html),
            .product(slug: "palomelos-rare-cobalt-blue-isabel-marant", id: 539036929)
        )
    }

    func testShopPageIsRecognisedAsShop() throws {
        let html = try FixtureLoader.string("depop-branch-shop", "html")
        XCTAssertEqual(
            DepopListingFetcher.parseBranchTarget(location: nil, html: html),
            .shop(userID: 223859381)
        )
    }

    /// CFNetwork's default UA gets a 307 straight to www.depop.com instead.
    func testRedirectLocationAloneIsEnough() {
        let location = "https://www.depop.com/products/washpurnresales-famous-stars-and-straps-hoodie-b54c/"
            + "?utm_source=generic&utm_content=product&_branch_match_id=1637266595541929199"
        XCTAssertEqual(
            DepopListingFetcher.parseBranchTarget(location: location, html: ""),
            .product(slug: "washpurnresales-famous-stars-and-straps-hoodie-b54c", id: nil)
        )
    }

    func testDeeplinkIDOnly() {
        let html = #"<a class="action" href="nullproduct/931002818?_branch_referrer=H4s">Open</a>"#
        XCTAssertEqual(
            DepopListingFetcher.parseBranchTarget(location: nil, html: html),
            .product(slug: nil, id: 931002818)
        )
    }

    func testUnrelatedPageYieldsNil() {
        XCTAssertNil(DepopListingFetcher.parseBranchTarget(
            location: nil, html: "<html><body>Page not found. 404product/abc</body></html>"
        ))
    }
}
