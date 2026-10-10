import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why an auth call failed. Every message is safe to show as-is and says what
/// actually happened; a 503 is never presented as a credentials problem.
public enum AuthError: Error, Equatable, LocalizedError, Sendable {
    /// `/auth/login` 401.
    case invalidCredentials
    /// `/auth/signup` 403: not on the invite allowlist.
    case signupNotAllowed
    /// `/auth/signup` 400 (weak password, already registered, …) or 422.
    case rejected(String)
    /// `/auth/refresh` 401: token unknown, revoked, reused, or session timed out.
    case refreshTokenInvalid
    /// 503: Supabase Auth unreachable. Keep the session and retry.
    case serviceUnavailable
    /// Any other status.
    case unexpectedStatus(Int, String?)
    /// 200 with a body we couldn't use.
    case badResponse
    /// Offline, timeout, TLS, DNS…
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "That email and password don't match a Cleared account."
        case .signupNotAllowed:
            return "Cleared is invite-only right now, and this email isn't on the invite list."
        case .rejected(let message):
            return message
        case .refreshTokenInvalid:
            return "Your sign-in expired. Sign in again."
        case .serviceUnavailable:
            return "Cleared's sign-in service is temporarily unavailable. This isn't a problem with your password. Try again in a moment."
        case .unexpectedStatus(let status, let detail):
            return detail.map { "Sign-in failed (HTTP \(status)): \($0)" }
                ?? "Sign-in failed (HTTP \(status))."
        case .badResponse:
            return "Couldn't read the sign-in response from Cleared's server."
        case .network(let message):
            return "Couldn't reach Cleared: \(message)"
        }
    }

    /// Transient: keep the session, retry later.
    public var isTransient: Bool {
        switch self {
        case .serviceUnavailable, .network: return true
        default: return false
        }
    }
}

/// Signup either signs in straight away or needs email confirmation first
/// (contract §1: token fields come back null).
public enum SignupOutcome: Equatable, Sendable {
    case signedIn(ClearedSession)
    case confirmationRequired(email: String)
}

/// What `SessionManager` needs from the auth backend; faked in tests.
public protocol SessionRefreshing: Sendable {
    func refresh(refreshToken: String) async throws -> ClearedSession
}

/// `POST /auth/login`, `/auth/signup`, `/auth/refresh` against the Railway
/// backend (which proxies Supabase Auth; it never stores passwords).
public struct AuthClient: SessionRefreshing {
    let baseURL: URL
    let transport: HTTPTransport
    let now: @Sendable () -> Date

    public init(
        baseURL: URL,
        transport: HTTPTransport = URLSessionTransport(requestTimeout: 20),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.now = now
    }

    public func login(email: String, password: String) async throws -> ClearedSession {
        let payload = try await post("auth/login", body: ["email": email, "password": password]) { status, detail in
            switch status {
            case 401: return .invalidCredentials
            case 422: return .rejected(detail ?? "Enter a valid email and password.")
            default: return nil
            }
        }
        guard let session = payload.session(receivedAt: now()) else { throw AuthError.badResponse }
        return session
    }

    public func signup(email: String, password: String) async throws -> SignupOutcome {
        let payload = try await post("auth/signup", body: ["email": email, "password": password]) { status, detail in
            switch status {
            case 403: return .signupNotAllowed
            case 400, 422: return .rejected(detail ?? "Signup was rejected. Check the email and use a stronger password.")
            default: return nil
            }
        }
        if let session = payload.session(receivedAt: now()) {
            return .signedIn(session)
        }
        // No tokens: the project requires email confirmation first.
        guard payload.accessToken == nil, let user = payload.user else { throw AuthError.badResponse }
        return .confirmationRequired(email: user.email ?? email)
    }

    public func refresh(refreshToken: String) async throws -> ClearedSession {
        let payload = try await post("auth/refresh", body: ["refresh_token": refreshToken]) { status, _ in
            switch status {
            case 401: return .refreshTokenInvalid
            // 422 = empty/oversized token: unusable, same outcome as invalid.
            case 422: return .refreshTokenInvalid
            default: return nil
            }
        }
        guard let session = payload.session(receivedAt: now()) else { throw AuthError.badResponse }
        return session
    }

    // MARK: Request plumbing

    /// Internal so tests can assert the request shape without a network.
    func makeRequest(_ path: String, body: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private func post(
        _ path: String,
        body: [String: String],
        mapError: (Int, String?) -> AuthError?
    ) async throws -> AuthSessionPayload {
        let request = try makeRequest(path, body: body)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AuthError.network(error.localizedDescription)
        }
        let detail = APIErrorDetail.message(from: data)
        switch response.statusCode {
        case 200:
            do {
                return try AuthSessionPayload.decoder().decode(AuthSessionPayload.self, from: data)
            } catch {
                throw AuthError.badResponse
            }
        case 503:
            throw AuthError.serviceUnavailable
        case let status:
            throw mapError(status, detail) ?? AuthError.unexpectedStatus(status, detail)
        }
    }
}
