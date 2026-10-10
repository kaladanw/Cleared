import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ClearedAPIError: Error, Equatable, LocalizedError {
    case notConfigured
    case unauthorized
    /// The endpoint needs a signed-in Cleared account (Bearer) and there is none.
    case signInRequired
    case serverError(status: Int)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Backend not configured — fill in ios/Secrets.xcconfig and rebuild."
        case .unauthorized:
            return "The backend rejected the credentials (401). Sign in again, or check CLEARED_SHARED_TOKEN in Secrets.xcconfig against Railway."
        case .signInRequired:
            return "You're not signed in to Cleared. Open the Cleared app and sign in, then share again."
        case .serverError(let status):
            return "The backend returned an error (HTTP \(status)). Try again in a moment."
        case .badResponse:
            return "Couldn't read the backend's response."
        }
    }
}

/// Supplies the signed-in user's Supabase access token.
///
/// The real implementation is `SessionManager` (shared Keychain session +
/// cross-process refresh lock between the app and the Share Extension).
/// Contract (`docs/api-contract.md` §1): return a token that is valid for at
/// least the next 2 minutes, refreshing first if needed; `forceRefresh: true`
/// is called once after a 401. Return nil when signed out.
public protocol AccessTokenProvider: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String?
    /// The retry after a forced refresh got 401 too: sign out (contract §1).
    func authenticationFailed(accessToken: String) async
}

extension AccessTokenProvider {
    public func authenticationFailed(accessToken: String) async {}
}

/// How a request authenticates. Only one header is ever sent: the contract
/// says Bearer wins, and a bad Bearer is a hard 401, never a fallback.
enum RequestAuth: Equatable {
    case bearer(String)
    case sharedToken(String)
    case none
}

/// Calls the Railway backend. A check takes ~30–90 s (vision + web_search),
/// hence the long timeout.
///
/// - `POST /check` (screenshots, multipart): Bearer when an access token is
///   available (saved to history), otherwise the legacy `X-Cleared-Token`.
/// - `POST /check-listing` (Depop link, JSON): **Bearer only** per the contract.
public struct ClearedAPIClient: Sendable {
    let baseURL: URL
    let token: String?
    let accessTokenProvider: AccessTokenProvider?
    let transport: HTTPTransport
    /// Backoff before the single retry of an idempotent GET that got 503.
    let unavailableRetryDelay: Duration

    public init(baseURL: URL, token: String?, accessTokenProvider: AccessTokenProvider? = nil) {
        self.init(
            baseURL: baseURL, token: token, accessTokenProvider: accessTokenProvider,
            transport: URLSessionTransport(requestTimeout: 240, resourceTimeout: 300)
        )
    }

    init(
        baseURL: URL,
        token: String?,
        accessTokenProvider: AccessTokenProvider?,
        transport: HTTPTransport,
        unavailableRetryDelay: Duration = .seconds(1)
    ) {
        self.baseURL = baseURL
        self.token = token
        self.accessTokenProvider = accessTokenProvider
        self.transport = transport
        self.unavailableRetryDelay = unavailableRetryDelay
    }

    /// Reads Secrets.xcconfig-injected config; nil when there's no backend URL,
    /// or no way to authenticate at all.
    public static func fromConfig(accessTokenProvider: AccessTokenProvider? = nil) -> ClearedAPIClient? {
        guard let url = ClearedConfig.backendURL else { return nil }
        let token = ClearedConfig.sharedToken
        guard token != nil || accessTokenProvider != nil else { return nil }
        return ClearedAPIClient(baseURL: url, token: token, accessTokenProvider: accessTokenProvider)
    }

    /// Whether `/check-listing` can be attempted (an auth provider is wired in).
    /// A provider can still return nil (signed out) → `.signInRequired`.
    public var supportsAuthenticatedChecks: Bool { accessTokenProvider != nil }

    // MARK: POST /check (screenshots)

    public func check(
        images: [Data],
        userContext: String?,
        listingURL: URL? = nil,
        marketplace: String? = nil
    ) async throws -> CheckReport {
        try await sendWithAuth(bearerRequired: false, decode: Self.decodeReport) { auth in
            makeCheckRequest(
                images: images, userContext: userContext,
                listingURL: listingURL, marketplace: marketplace, auth: auth
            )
        }
    }

    /// Split out (internal) so tests can assert the request shape without a network.
    func makeCheckRequest(
        images: [Data],
        userContext: String?,
        listingURL: URL? = nil,
        marketplace: String? = nil,
        auth: RequestAuth? = nil
    ) -> URLRequest {
        var multipart = MultipartBody()
        for (index, imageData) in images.enumerated() {
            multipart.appendFile(
                name: "images",
                filename: "shot-\(index).jpg",
                contentType: "image/jpeg",
                data: imageData
            )
        }
        if let userContext, !userContext.isEmpty {
            multipart.appendField(name: "user_context", value: userContext)
        }
        if let listingURL {
            multipart.appendField(name: "listing_url", value: listingURL.absoluteString)
        }
        if let marketplace, !marketplace.isEmpty {
            multipart.appendField(name: "marketplace", value: marketplace)
        }

        var request = URLRequest(url: baseURL.appending(path: "check"))
        request.httpMethod = "POST"
        apply(auth ?? token.map(RequestAuth.sharedToken) ?? .none, to: &request)
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.finalized()
        return request
    }

    // MARK: POST /check-listing (Depop link → listing JSON)

    public func checkListing(_ body: CheckListingRequest) async throws -> CheckReport {
        let payload = try CheckListingRequest.encoder().encode(body)
        return try await sendWithAuth(bearerRequired: true, decode: Self.decodeReport) { auth in
            makeCheckListingRequest(body: payload, auth: auth)
        }
    }

    // MARK: GET /api/reports (history, source of truth)

    /// The signed-in user's saved checks, newest first (contract §3).
    /// Bearer only. A 503 is retried once; if it persists the caller keeps
    /// its cache (the server never answers an outage with an empty list).
    public func fetchReports() async throws -> [ReportRow] {
        let decode: @Sendable (Data) throws -> [ReportRow] = { data in
            try ReportRow.decoder().decode([ReportRow].self, from: data)
        }
        do {
            return try await sendWithAuth(bearerRequired: true, decode: decode, makeRequest: makeReportsRequest)
        } catch ClearedAPIError.serverError(status: 503) {
            try await Task.sleep(for: unavailableRetryDelay)
            return try await sendWithAuth(bearerRequired: true, decode: decode, makeRequest: makeReportsRequest)
        }
    }

    func makeReportsRequest(auth: RequestAuth) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "api/reports"))
        request.httpMethod = "GET"
        apply(auth, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func makeCheckListingRequest(body: Data, auth: RequestAuth) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "check-listing"))
        request.httpMethod = "POST"
        apply(auth, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    // MARK: Auth plumbing

    /// Resolves auth, sends, and on a Bearer 401 refreshes once and retries
    /// once (contract §1). A second 401 tells the provider to sign out and
    /// surfaces as `.signInRequired`.
    private func sendWithAuth<T>(
        bearerRequired: Bool,
        decode: (Data) throws -> T,
        makeRequest: (RequestAuth) -> URLRequest
    ) async throws -> T {
        let auth = try await resolveAuth(bearerRequired: bearerRequired, forceRefresh: false)
        do {
            return try await send(makeRequest(auth), decode: decode)
        } catch ClearedAPIError.unauthorized {
            guard case .bearer = auth else { throw ClearedAPIError.unauthorized }
            // Refresh once. A refresh 401 has already signed out (nil token →
            // .signInRequired); a 503 propagates and keeps the session.
            let retryAuth = try await resolveAuth(bearerRequired: true, forceRefresh: true)
            guard case .bearer(let retryToken) = retryAuth else { throw ClearedAPIError.signInRequired }
            do {
                return try await send(makeRequest(retryAuth), decode: decode)
            } catch ClearedAPIError.unauthorized {
                await accessTokenProvider?.authenticationFailed(accessToken: retryToken)
                throw ClearedAPIError.signInRequired
            }
        }
    }

    func resolveAuth(bearerRequired: Bool, forceRefresh: Bool) async throws -> RequestAuth {
        if let provider = accessTokenProvider,
           let access = try await provider.accessToken(forceRefresh: forceRefresh),
           !access.isEmpty {
            return .bearer(access)
        }
        if bearerRequired { throw ClearedAPIError.signInRequired }
        return token.map(RequestAuth.sharedToken) ?? .none
    }

    private func apply(_ auth: RequestAuth, to request: inout URLRequest) {
        switch auth {
        case .bearer(let access):
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        case .sharedToken(let shared):
            request.setValue(shared, forHTTPHeaderField: "X-Cleared-Token")
        case .none:
            break
        }
    }

    private func send<T>(_ request: URLRequest, decode: (Data) throws -> T) async throws -> T {
        let (data, http) = try await transport.send(request)
        switch http.statusCode {
        case 200:
            do {
                return try decode(data)
            } catch {
                throw ClearedAPIError.badResponse
            }
        case 401:
            throw ClearedAPIError.unauthorized
        default:
            throw ClearedAPIError.serverError(status: http.statusCode)
        }
    }

    private static func decodeReport(_ data: Data) throws -> CheckReport {
        try CheckReport.decoder().decode(CheckReport.self, from: data)
    }
}
