import XCTest

/// api.depop.com/api/v1/products/<slug>/ responses (trimmed, saved live) →
/// the /check-listing seed facts.
final class DepopMappingTests: XCTestCase {
    private func product(_ name: String) throws -> DepopProduct {
        try DepopProduct.decoder().decode(DepopProduct.self, from: FixtureLoader.data(name, "json"))
    }

    private func sizes() throws -> DepopSizeTable {
        try DepopSizeTable.parse(categoriesJSON: FixtureLoader.data("depop-categories-v2-subset", "json"))
    }

    func testSizeTableParsesVariantSets() throws {
        let table = try sizes()
        XCTAssertEqual(table.label(set: 60, variant: 15), "32\"")
        XCTAssertEqual(table.label(set: 60, variant: 12), "29\"")
        XCTAssertEqual(table.label(set: 22, variant: 19), "28\"")
        XCTAssertNil(table.label(set: 999, variant: 1))
    }

    func testMapsJeansListing() throws {
        let listing = try XCTUnwrap(
            DepopListingMapper.listing(from: product("depop-product-levis-505"), sizes: sizes())
        )
        XCTAssertEqual(listing.slug, "daviduared-like-new-levis-505-regular-189c")
        XCTAssertEqual(listing.productID, 935226197)
        XCTAssertEqual(
            listing.canonicalURL.absoluteString,
            "https://www.depop.com/products/daviduared-like-new-levis-505-regular-189c/"
        )
        XCTAssertEqual(listing.facts.brand, "Levi's")
        XCTAssertEqual(listing.facts.modelOrName, "Like New Levi’s 505 Regular Fit Straight Leg Jeans W29 L32")
        XCTAssertEqual(listing.facts.category, "jeans")
        XCTAssertEqual(listing.facts.size, "29\"")
        XCTAssertEqual(listing.facts.listedCondition, "Like new")
        XCTAssertEqual(listing.facts.askingPrice, 29.99)
        XCTAssertEqual(listing.facts.currency, "USD")
        XCTAssertEqual(listing.facts.photoObservations, [])
        XCTAssertEqual(listing.imageURLs.count, 5)
        XCTAssertTrue(listing.imageURLs.allSatisfy {
            $0.host == "media-photos.depop.com" && $0.lastPathComponent == "P0.jpg"
        })
        XCTAssertEqual(listing.seller, .init(username: "davidjared", profileUrl: "https://www.depop.com/davidjared/"))
        XCTAssertFalse(listing.isSold)
    }

    func testMapsListingWithoutSizeOrSizeTable() throws {
        let sega = try product("depop-product-sega-no-size")
        let listing = try XCTUnwrap(DepopListingMapper.listing(from: sega, sizes: nil))
        XCTAssertNil(listing.facts.size)
        XCTAssertEqual(listing.facts.brand, "Sega")
        XCTAssertEqual(listing.facts.category, "puzzles games")
        XCTAssertEqual(listing.facts.listedCondition, "Used - Good")
        XCTAssertEqual(listing.facts.askingPrice, 30.35)
        XCTAssertEqual(listing.imageURLs.count, 4)
        XCTAssertEqual(listing.facts.modelOrName, "Sega Genesis Jurassic Park Video Game Complete 1993 CIB w/ Manual NTSC-U/C")
    }

    func testSoldOutAndInactiveListingsAreFlagged() throws {
        var sold = try product("depop-product-levis-505")
        sold.quantity = 0
        XCTAssertTrue(try XCTUnwrap(DepopListingMapper.listing(from: sold, sizes: nil)).isSold)
        var inactive = try product("depop-product-levis-505")
        inactive.activeStatus = "sold"
        XCTAssertTrue(try XCTUnwrap(DepopListingMapper.listing(from: inactive, sizes: nil)).isSold)
    }

    func testDiscountedCurrentPriceWins() throws {
        var discounted = try product("depop-product-levis-505")
        discounted.prices = .init(originalPrice: .init(price: "29.99"), currentPrice: .init(price: "20.00"))
        XCTAssertEqual(DepopListingMapper.listing(from: discounted, sizes: nil)?.facts.askingPrice, 20.0)
    }

    func testCapsImagesAtEight() throws {
        var many = try product("depop-product-levis-505")
        many.picturesData = Array(repeating: many.picturesData![0], count: 12)
        XCTAssertEqual(DepopListingMapper.listing(from: many, sizes: nil)?.imageURLs.count, 8)
    }

    func testMissingSlugIsUnmappable() throws {
        var broken = try product("depop-product-levis-505")
        broken.slug = nil
        XCTAssertNil(DepopListingMapper.listing(from: broken, sizes: nil))
    }

    func testBrandNamesAndConditions() {
        XCTAssertEqual(DepopListingMapper.brandName("levi-s"), "Levi's")
        XCTAssertEqual(DepopListingMapper.brandName("ralph-lauren"), "Ralph Lauren")
        XCTAssertEqual(DepopListingMapper.brandName("Carhartt WIP"), "Carhartt WIP")
        XCTAssertNil(DepopListingMapper.brandName(" "))
        XCTAssertEqual(DepopListingMapper.conditionLabel("brand_new"), "Brand new")
        XCTAssertEqual(DepopListingMapper.conditionLabel("used_fair"), "Used - Fair")
        XCTAssertEqual(DepopListingMapper.conditionLabel("used_excellent"), "Used - Excellent")
        XCTAssertEqual(DepopListingMapper.conditionLabel("something_new"), "something new")
    }

    func testTitleIsFirstNonEmptyLineCapped() {
        XCTAssertEqual(DepopListingMapper.title(from: "\n  Barbour Beaufort  \nMore"), "Barbour Beaufort")
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(DepopListingMapper.title(from: long)?.count, 120)
        XCTAssertNil(DepopListingMapper.title(from: "\n \n"))
    }
}
