import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

/// Serves canned responses by URL and records every request. No network.
private final class StubLoader: DepopHTTPLoading, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }
    private let lock = NSLock()
    private var replies: [String: Result<Reply, URLError>]
    private var _requests: [URLRequest] = []

    init(_ replies: [String: Result<Reply, URLError>]) { self.replies = replies }

    var requests: [URLRequest] { lock.withLock { _requests } }
    func count(_ url: String) -> Int { requests.filter { $0.url?.absoluteString == url }.count }

    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let reply = lock.withLock { () -> Result<Reply, URLError>? in
            _requests.append(request)
            return replies[url.absoluteString]
        }
        switch reply {
        case .success(let r)?:
            let response = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/2", headerFields: r.headers)!
            return (r.body, response)
        case .failure(let error)?:
            throw error
        case nil:
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/2", headerFields: [:])!
            return (Data("null".utf8), response)
        }
    }
}

final class DepopListingFetcherTests: XCTestCase {
    static let shortLink = "https://depop.app.link/MNiLzm4FDSb"
    static let isabelAPI = "https://api.depop.com/api/v1/products/palomelos-rare-cobalt-blue-isabel-marant/"
    static let levisSlug = "daviduared-like-new-levis-505-regular-189c"
    static let levisAPI = "https://api.depop.com/api/v1/products/\(levisSlug)/"
    static let categoriesAPI = "https://api.depop.com/api/v2/categories/"

    private func ok(_ name: String, _ ext: String) throws -> Result<StubLoader.Reply, URLError> {
        .success(.init(status: 200, body: try FixtureLoader.data(name, ext)))
    }

    func testShortLinkResolvesFetchesAndMaps() async throws {
        let loader = StubLoader([
            Self.shortLink: try ok("depop-branch-product", "html"),
            // The Branch fixture points at a different listing; reuse the Levi's JSON body.
            Self.isabelAPI: try ok("depop-product-levis-505", "json"),
            Self.categoriesAPI: try ok("depop-categories-v2-subset", "json"),
        ])
        let fetcher = DepopListingFetcher(loader: loader)
        let listing = try await fetcher.fetchListing(for: .shortLink(URL(string: Self.shortLink)!))

        XCTAssertEqual(listing.facts.size, "29\"")
        XCTAssertEqual(listing.canonicalURL.absoluteString, "https://www.depop.com/products/\(Self.levisSlug)/")
        XCTAssertEqual(loader.requests.map { $0.url!.absoluteString },
                       [Self.shortLink, Self.isabelAPI, Self.categoriesAPI])
        for request in loader.requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Cleared/1.0")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testRedirectLocationResolves() async throws {
        let loader = StubLoader([
            Self.shortLink: .success(.init(
                status: 307, body: Data(),
                headers: ["Location": "https://www.depop.com/products/\(Self.levisSlug)/?utm_source=generic"]
            )),
            Self.levisAPI: try ok("depop-product-levis-505", "json"),
        ])
        let slug = try await DepopListingFetcher(loader: loader).resolveShortLink(URL(string: Self.shortLink)!)
        XCTAssertEqual(slug, Self.levisSlug)
    }

    func testProductLinkSkipsBranchAndSizeFailureIsNonFatal() async throws {
        let loader = StubLoader([
            Self.levisAPI: try ok("depop-product-levis-505", "json"),
            Self.categoriesAPI: .success(.init(status: 403, body: Data("Forbidden".utf8))),
        ])
        let listing = try await DepopListingFetcher(loader: loader)
            .fetchListing(for: .product(slug: Self.levisSlug))
        XCTAssertNil(listing.facts.size)
        XCTAssertEqual(listing.facts.brand, "Levi's")
        XCTAssertEqual(loader.count(Self.shortLink), 0)
    }

    func testSizeTableIsCachedInMemoryAndOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let replies: [String: Result<StubLoader.Reply, URLError>] = [
            Self.levisAPI: try ok("depop-product-levis-505", "json"),
            Self.categoriesAPI: try ok("depop-categories-v2-subset", "json"),
        ]

        let first = StubLoader(replies)
        let fetcher = DepopListingFetcher(loader: first, cacheDirectory: dir)
        _ = try await fetcher.fetchListing(for: .product(slug: Self.levisSlug))
        _ = try await fetcher.fetchListing(for: .product(slug: Self.levisSlug))
        XCTAssertEqual(first.count(Self.categoriesAPI), 1)

        // A new process (the next share) reads the disk cache…
        let second = StubLoader(replies)
        let listing = try await DepopListingFetcher(loader: second, cacheDirectory: dir)
            .fetchListing(for: .product(slug: Self.levisSlug))
        XCTAssertEqual(listing.facts.size, "29\"")
        XCTAssertEqual(second.count(Self.categoriesAPI), 0)

        // …until it is a week old.
        let third = StubLoader(replies)
        _ = try await DepopListingFetcher(
            loader: third, cacheDirectory: dir,
            now: { Date().addingTimeInterval(8 * 24 * 60 * 60) }
        ).fetchListing(for: .product(slug: Self.levisSlug))
        XCTAssertEqual(third.count(Self.categoriesAPI), 1)
    }

    func testTypedErrors() async throws {
        func error(for replies: [String: Result<StubLoader.Reply, URLError>], link: DepopLink) async -> DepopFetchError? {
            do {
                _ = try await DepopListingFetcher(loader: StubLoader(replies)).fetchListing(for: link)
                return nil
            } catch {
                return error as? DepopFetchError
            }
        }
        let product = DepopLink.product(slug: Self.levisSlug)
        let short = DepopLink.shortLink(URL(string: Self.shortLink)!)

        let notFound = await error(for: [:], link: product)
        XCTAssertEqual(notFound, .listingNotFound)

        let blocked = await error(for: [Self.levisAPI: .success(.init(status: 403, body: Data()))], link: product)
        XCTAssertEqual(blocked, .blocked(status: 403))

        let shop = await error(for: [Self.shortLink: try ok("depop-branch-shop", "html")], link: short)
        XCTAssertEqual(shop, .shopLinkNotListing)

        let unresolvable = await error(for: [Self.shortLink: .success(.init(status: 200, body: Data("<html/>".utf8)))], link: short)
        XCTAssertEqual(unresolvable, .unresolvableLink)

        let garbage = await error(for: [Self.levisAPI: .success(.init(status: 200, body: Data("<html>".utf8)))], link: product)
        XCTAssertEqual(garbage, .unreadableListing)

        let offline = await error(for: [Self.shortLink: .failure(URLError(.notConnectedToInternet))], link: short)
        guard case .network = offline else { return XCTFail("expected .network, got \(String(describing: offline))") }

        var noPhotos = try JSONSerialization.jsonObject(with: FixtureLoader.data("depop-product-levis-505", "json")) as! [String: Any]
        noPhotos["pictures_data"] = []
        let empty = await error(for: [Self.levisAPI: .success(.init(status: 200, body: try JSONSerialization.data(withJSONObject: noPhotos)))], link: product)
        XCTAssertEqual(empty, .noPhotos)
    }
}
