import XCTest

final class DepopLinkTests: XCTestCase {
    /// Exactly what Depop's Share button produces (public posts, 2026).
    func testExtractsShortLinkFromDepopShareText() {
        let text = "Look what I just found on Depop 👀\n\nhttps://depop.app.link/MNiLzm4FDSb"
        XCTAssertEqual(
            DepopLink.firstLink(in: text),
            .shortLink(URL(string: "https://depop.app.link/MNiLzm4FDSb")!)
        )
    }

    func testShortLinkDropsQueryAndTrailingSlash() {
        XCTAssertEqual(
            DepopLink.from(url: URL(string: "https://depop.app.link/abc123/?foo=bar")!),
            .shortLink(URL(string: "https://depop.app.link/abc123")!)
        )
    }

    func testExtractsProductSlugFromWebURL() {
        let text = "https://www.depop.com/products/palomelos-rare-cobalt-blue-isabel-marant/?utm_source=share"
        XCTAssertEqual(
            DepopLink.firstLink(in: text),
            .product(slug: "palomelos-rare-cobalt-blue-isabel-marant")
        )
        XCTAssertEqual(
            DepopLink.from(url: URL(string: "http://depop.com/products/a_b.c-1")!),
            .product(slug: "a_b.c-1")
        )
    }

    func testSkipsNonDepopAndNonListingLinks() {
        let text = "see https://example.com/products/x and https://www.depop.com/someshop/ "
            + "then https://depop.app.link/Kvws6hSu36b."
        XCTAssertEqual(
            DepopLink.firstLink(in: text),
            .shortLink(URL(string: "https://depop.app.link/Kvws6hSu36b")!)
        )
    }

    func testRejectsShopHomeAndOtherSchemes() {
        XCTAssertNil(DepopLink.from(url: URL(string: "https://www.depop.com/")!))
        XCTAssertNil(DepopLink.from(url: URL(string: "https://www.depop.com/vintage.finds/")!))
        XCTAssertNil(DepopLink.from(url: URL(string: "https://www.depop.com/products/")!))
        XCTAssertNil(DepopLink.from(url: URL(string: "https://depop.app.link/")!))
        XCTAssertNil(DepopLink.from(url: URL(string: "depop://product/123")!))
        XCTAssertNil(DepopLink.from(url: URL(string: "file:///tmp/depop.app.link/x")!))
        XCTAssertNil(DepopLink.from(url: URL(string: "https://notdepop.com/products/x")!))
        XCTAssertNil(DepopLink.firstLink(in: "no links here 👀"))
    }

    func testURLItemsWinOverText() {
        let link = DepopLink.firstLink(
            urls: [URL(string: "file:///var/mobile/shot.png")!,
                   URL(string: "https://www.depop.com/products/from-url-item/")!],
            texts: ["https://depop.app.link/fromText"]
        )
        XCTAssertEqual(link, .product(slug: "from-url-item"))
        XCTAssertEqual(
            DepopLink.firstLink(urls: [], texts: ["hi", "https://depop.app.link/fromText"]),
            .shortLink(URL(string: "https://depop.app.link/fromText")!)
        )
    }

    /// The fallback scanner (used on Linux; NSDataDetector on device).
    func testRegexScannerTrimsPunctuationAndAddsScheme() {
        let urls = DepopLink.regexCandidateURLs(
            in: "(depop.app.link/AbC1), www.depop.com/products/x-y/!"
        )
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://depop.app.link/AbC1",
            "https://www.depop.com/products/x-y/",
        ])
    }
}
