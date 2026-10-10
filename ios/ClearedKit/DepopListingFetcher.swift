import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a shared Depop link couldn't become a listing. Each case has a message
/// the share sheet can show as-is.
public enum DepopFetchError: Error, Equatable, LocalizedError, Sendable {
    /// The short link resolved to a shop/profile, not a single listing.
    case shopLinkNotListing
    /// The Branch page didn't contain a product slug or id we recognise.
    case unresolvableLink
    /// 404 from the product API: deleted, or the slug is wrong.
    case listingNotFound
    /// 401/403/429: Depop's bot protection or rate limit refused the request.
    case blocked(status: Int)
    /// Any other non-200 status.
    case unexpectedStatus(Int)
    /// The response wasn't the JSON we expect (Depop changed the API).
    case unreadableListing
    /// The listing has no usable photos, so there is nothing to check.
    case noPhotos
    /// Offline, timed out, TLS, DNS…
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .shopLinkNotListing:
            return "That's a link to a Depop shop, not a single listing. Share an item instead."
        case .unresolvableLink:
            return "Couldn't work out which listing that Depop link points to."
        case .listingNotFound:
            return "Depop says this listing doesn't exist anymore."
        case .blocked(let status):
            return "Depop refused the request (HTTP \(status))."
        case .unexpectedStatus(let status):
            return "Depop returned an unexpected response (HTTP \(status))."
        case .unreadableListing:
            return "Couldn't read the listing data Depop returned."
        case .noPhotos:
            return "This listing has no photos to check."
        case .network(let message):
            return "Couldn't reach Depop: \(message)"
        }
    }
}

/// The minimal HTTP surface the fetcher needs, so tests can stub Depop.
/// Implementations must NOT follow redirects (the Branch short link's
/// redirect `Location` is itself the answer, and following it lands on
/// www.depop.com, which Cloudflare blocks).
public protocol DepopHTTPLoading: Sendable {
    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// What a Depop short link points to, read from Branch's page.
public enum DepopLinkTarget: Equatable, Sendable {
    case product(slug: String?, id: Int?)
    case shop(userID: Int)
}

/// Turns a shared Depop link into a `DepopListing`, entirely on the device:
///
/// 1. `depop.app.link/<code>` → GET with a non-browser UA. Branch answers with
///    an HTML page (or a redirect) containing `depop.com/products/<slug>/` and
///    the app deeplink `product/<id>`.
/// 2. `GET https://api.depop.com/api/v1/products/<slug-or-id>/` → product JSON.
/// 3. Size labels from `GET https://api.depop.com/api/v2/categories/`
///    (cached in memory and, when given a directory, on disk for a week).
///
/// Runs on the phone on purpose: api.depop.com fingerprints clients and 403s
/// the backend's Python HTTP stacks; an iOS URLSession is an ordinary client.
public actor DepopListingFetcher {
    public static let userAgent = "Cleared/1.0"
    static let apiBase = URL(string: "https://api.depop.com/api/")!
    static let sizeTableTTL: TimeInterval = 7 * 24 * 60 * 60
    static let sizeCacheFilename = "depop-size-table.json"

    private let loader: DepopHTTPLoading
    private let cacheDirectory: URL?
    private let now: @Sendable () -> Date
    private var sizeTable: DepopSizeTable?

    public init(
        loader: DepopHTTPLoading = URLSessionDepopLoader(),
        cacheDirectory: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.loader = loader
        self.cacheDirectory = cacheDirectory
        self.now = now
    }

    // MARK: Public API

    public func fetchListing(for link: DepopLink) async throws -> DepopListing {
        let reference: String
        switch link {
        case .product(let slug):
            reference = slug
        case .shortLink(let url):
            reference = try await resolveShortLink(url)
        }

        let product = try await fetchProduct(reference: reference)
        // Sizes are a nicety; never fail the listing over the size chart.
        let sizes = try? await loadSizeTable()
        guard let listing = DepopListingMapper.listing(from: product, sizes: sizes) else {
            throw DepopFetchError.unreadableListing
        }
        guard !listing.imageURLs.isEmpty else { throw DepopFetchError.noPhotos }
        return listing
    }

    /// Short link → product slug (preferred, it's what the canonical URL uses)
    /// or numeric id (the API accepts either).
    public func resolveShortLink(_ url: URL) async throws -> String {
        let (data, response) = try await send(Self.request(url, accept: "text/html,*/*"))
        let location = response.value(forHTTPHeaderField: "Location")
        let html = String(decoding: data, as: UTF8.self)

        switch response.statusCode {
        case 200, 301, 302, 303, 307, 308:
            break
        case 404:
            throw DepopFetchError.unresolvableLink
        case 401, 403, 429:
            throw DepopFetchError.blocked(status: response.statusCode)
        default:
            throw DepopFetchError.unexpectedStatus(response.statusCode)
        }

        switch Self.parseBranchTarget(location: location, html: html) {
        case .product(let slug?, _):
            return slug
        case .product(nil, let id?):
            return String(id)
        case .shop:
            throw DepopFetchError.shopLinkNotListing
        case .product(nil, nil), nil:
            throw DepopFetchError.unresolvableLink
        }
    }

    public func fetchProduct(reference: String) async throws -> DepopProduct {
        guard let encoded = reference.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_."))),
              let url = URL(string: "v1/products/\(encoded)/", relativeTo: Self.apiBase)?.absoluteURL
        else { throw DepopFetchError.unresolvableLink }

        let (data, response) = try await send(Self.request(url, accept: "application/json"))
        try Self.checkAPIStatus(response.statusCode)
        do {
            return try DepopProduct.decoder().decode(DepopProduct.self, from: data)
        } catch {
            throw DepopFetchError.unreadableListing
        }
    }

    /// Memory → disk (≤ 7 days old) → network.
    public func loadSizeTable() async throws -> DepopSizeTable {
        if let sizeTable { return sizeTable }
        if let cached = readCachedSizeTable() {
            sizeTable = cached
            return cached
        }
        let url = URL(string: "v2/categories/", relativeTo: Self.apiBase)!.absoluteURL
        let (data, response) = try await send(Self.request(url, accept: "application/json"))
        try Self.checkAPIStatus(response.statusCode)
        let table: DepopSizeTable
        do {
            table = try DepopSizeTable.parse(categoriesJSON: data)
        } catch {
            throw DepopFetchError.unreadableListing
        }
        sizeTable = table
        writeCachedSizeTable(table)
        return table
    }

    // MARK: Parsing (static + pure, unit-tested against saved Branch pages)

    /// Reads the Branch page (or redirect `Location`). Product links carry
    /// `depop.com/products/<slug>/` and the deeplink `product/<id>`; shop links
    /// carry `user/<id>`.
    public static func parseBranchTarget(location: String?, html: String) -> DepopLinkTarget? {
        let haystack = [location ?? "", html].joined(separator: "\n")
        let slug = firstMatch(#"depop\.com/products/(\#(DepopLink.slugPattern))"#, in: haystack)
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .flatMap { DepopLink.isValidSlug($0) ? $0 : nil }
        let id = firstMatch(#"(?:^|[^A-Za-z0-9_])(?:null|depop://)?product/([0-9]{1,15})(?![0-9])"#, in: haystack)
            .flatMap(Int.init)
        if slug != nil || id != nil { return .product(slug: slug, id: id) }
        if let user = firstMatch(#"(?:^|[^A-Za-z0-9_])(?:null|depop://)?user/([0-9]{1,15})(?![0-9])"#, in: haystack)
            .flatMap(Int.init) {
            return .shop(userID: user)
        }
        return nil
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    static func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        // Branch serves its HTML page to non-browser UAs (and a redirect to
        // www.depop.com to CFNetwork's default UA); api.depop.com accepts it.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    static func checkAPIStatus(_ status: Int) throws {
        switch status {
        case 200: return
        case 404: throw DepopFetchError.listingNotFound
        case 401, 403, 429: throw DepopFetchError.blocked(status: status)
        default: throw DepopFetchError.unexpectedStatus(status)
        }
    }

    // MARK: Private

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await loader.load(request)
        } catch let error as DepopFetchError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DepopFetchError.network(error.localizedDescription)
        }
    }

    private struct CachedSizeTable: Codable {
        var savedAt: Date
        var table: DepopSizeTable
    }

    private var sizeCacheURL: URL? {
        cacheDirectory?.appendingPathComponent(Self.sizeCacheFilename)
    }

    private func readCachedSizeTable() -> DepopSizeTable? {
        guard let url = sizeCacheURL, let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedSizeTable.self, from: data),
              now().timeIntervalSince(cached.savedAt) < Self.sizeTableTTL
        else { return nil }
        return cached.table
    }

    private func writeCachedSizeTable(_ table: DepopSizeTable) {
        guard let url = sizeCacheURL,
              let data = try? JSONEncoder().encode(CachedSizeTable(savedAt: now(), table: table))
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// URLSession-backed loader that refuses redirects (see `DepopHTTPLoading`).
/// No cookies are stored and nothing is cached by URLSession.
public final class URLSessionDepopLoader: NSObject, DepopHTTPLoading, @unchecked Sendable {
    // @unchecked: `session` is immutable after init; URLSession is thread-safe.
    private let session: URLSession

    public override init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let delegate = NoRedirectDelegate()
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        super.init()
    }

    deinit {
        // A delegate-backed session retains its delegate until invalidated.
        session.finishTasksAndInvalidate()
    }

    public func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DepopFetchError.unreadableListing
        }
        return (data, http)
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
