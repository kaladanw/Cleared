import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

private struct FixedTokenProvider: AccessTokenProvider {
    let token: String?
    func accessToken(forceRefresh: Bool) async throws -> String? { token }
}

/// The /check-listing body must match backend/app/models.py CheckListingRequest
/// (docs/api-contract.md §2) — the same JSON the Chrome extension sends.
final class CheckListingRequestTests: XCTestCase {
    private func levisListing() throws -> DepopListing {
        let product = try DepopProduct.decoder().decode(
            DepopProduct.self, from: FixtureLoader.data("depop-product-levis-505", "json")
        )
        let sizes = try DepopSizeTable.parse(
            categoriesJSON: FixtureLoader.data("depop-categories-v2-subset", "json")
        )
        return try XCTUnwrap(DepopListingMapper.listing(from: product, sizes: sizes))
    }

    func testBodyMatchesBackendContract() throws {
        let body = try levisListing().checkListingRequest(userContext: "it's a gift")
        let data = try CheckListingRequest.encoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(json.keys), ["facts", "image_urls", "user_context", "listing_url", "marketplace", "seller"])
        XCTAssertEqual(json["listing_url"] as? String,
                       "https://www.depop.com/products/daviduared-like-new-levis-505-regular-189c/")
        XCTAssertEqual(json["marketplace"] as? String, "depop")
        XCTAssertEqual(json["user_context"] as? String, "it's a gift")
        XCTAssertEqual((json["image_urls"] as? [String])?.count, 5)

        let facts = try XCTUnwrap(json["facts"] as? [String: Any])
        XCTAssertEqual(Set(facts.keys), [
            "brand", "model_or_name", "category", "size", "listed_condition",
            "asking_price", "currency", "photo_observations",
        ])
        XCTAssertEqual(facts["asking_price"] as? Double, 29.99)
        XCTAssertEqual(facts["listed_condition"] as? String, "Like new")
        XCTAssertEqual(facts["size"] as? String, "29\"")

        let seller = try XCTUnwrap(json["seller"] as? [String: Any])
        XCTAssertEqual(seller["username"] as? String, "davidjared")
        XCTAssertEqual(seller["profile_url"] as? String, "https://www.depop.com/davidjared/")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\\/"), "slashes must not be escaped")
    }

    func testNilFieldsAreOmittedSoBackendDefaultsApply() throws {
        let body = CheckListingRequest(
            facts: .init(), imageUrls: ["https://media-photos.depop.com/x/P0.jpg"],
            userContext: nil, listingUrl: nil, seller: nil
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: CheckListingRequest.encoder().encode(body)) as? [String: Any]
        )
        XCTAssertNil(json["user_context"])
        XCTAssertNil(json["listing_url"])
        XCTAssertNil(json["seller"])
        XCTAssertEqual((json["facts"] as? [String: Any])?.keys.sorted(), ["currency", "photo_observations"])
    }

    func testCheckListingRequestIsBearerJSON() throws {
        let client = ClearedAPIClient(baseURL: URL(string: "https://example.com")!, token: "shared-secret")
        let request = client.makeCheckListingRequest(body: Data("{}".utf8), auth: .bearer("jwt-abc"))
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/check-listing")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-abc")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Cleared-Token"), "send one credential, never both")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
    }

    /// /check-listing is Bearer-only; without a session it must fail before any
    /// network call so the share flow can fall back to screenshots.
    func testCheckListingWithoutSessionIsSignInRequired() async throws {
        let body = try levisListing().checkListingRequest(userContext: nil)
        for provider in [nil, FixedTokenProvider(token: nil)] as [AccessTokenProvider?] {
            let client = ClearedAPIClient(
                baseURL: URL(string: "https://example.invalid")!, token: "shared-secret",
                accessTokenProvider: provider
            )
            do {
                _ = try await client.checkListing(body)
                XCTFail("expected signInRequired")
            } catch {
                XCTAssertEqual(error as? ClearedAPIError, .signInRequired)
            }
        }
    }

    func testAuthResolution() async throws {
        let shared = ClearedAPIClient(baseURL: URL(string: "https://example.com")!, token: "s")
        let sharedAuth = try await shared.resolveAuth(bearerRequired: false, forceRefresh: false)
        XCTAssertEqual(sharedAuth, .sharedToken("s"))
        XCTAssertFalse(shared.supportsAuthenticatedChecks)

        let signedIn = ClearedAPIClient(
            baseURL: URL(string: "https://example.com")!, token: "s",
            accessTokenProvider: FixedTokenProvider(token: "jwt")
        )
        let bearerAuth = try await signedIn.resolveAuth(bearerRequired: true, forceRefresh: false)
        XCTAssertEqual(bearerAuth, .bearer("jwt"))
    }

    /// Screenshot fallback after a resolved link keeps the listing attached.
    func testCheckRequestCarriesListingURLAndBearer() {
        let client = ClearedAPIClient(baseURL: URL(string: "https://example.com")!, token: "s")
        let request = client.makeCheckRequest(
            images: [Data([0xFF])], userContext: nil,
            listingURL: URL(string: "https://www.depop.com/products/a-b/"), marketplace: "depop",
            auth: .bearer("jwt")
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Cleared-Token"))
        let rendered = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(rendered.contains("name=\"listing_url\"\r\n\r\nhttps://www.depop.com/products/a-b/\r\n"))
        XCTAssertTrue(rendered.contains("name=\"marketplace\"\r\n\r\ndepop\r\n"))
    }
}
