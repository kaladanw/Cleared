import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

/// Request shapes and error mapping for /auth/* (docs/api-contract.md §1).
final class AuthClientTests: XCTestCase {
    private let base = URL(string: "https://api.example.com")!

    private func client(_ replies: [FakeTransport.Reply]) -> (AuthClient, FakeTransport) {
        let transport = FakeTransport(replies)
        return (AuthClient(baseURL: base, transport: transport, now: { AuthFixtures.t0 }), transport)
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
    }

    func testLoginRequestShapeAndSession() async throws {
        let (auth, transport) = client([.status(200, AuthFixtures.sessionJSON(1))])
        let session = try await auth.login(email: "kalada@example.com", password: " p@ss word ")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/auth/login")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(try jsonBody(request), ["email": "kalada@example.com", "password": " p@ss word "],
                       "password is sent verbatim, never trimmed")

        XCTAssertEqual(session.accessToken, "access-1")
        XCTAssertEqual(session.refreshToken, "refresh-1")
        XCTAssertEqual(session.expiresAt, Date(timeIntervalSince1970: 1_791_233_600))
        XCTAssertEqual(session.user, .init(id: "user-1", email: "kalada@example.com"))
    }

    func testSignupRequestShape() async throws {
        let (auth, transport) = client([.status(200, AuthFixtures.sessionJSON(2))])
        let outcome = try await auth.signup(email: "a@b.com", password: "secret123")
        XCTAssertEqual(transport.requests.first?.url?.path, "/auth/signup")
        XCTAssertEqual(try jsonBody(XCTUnwrap(transport.requests.first)), ["email": "a@b.com", "password": "secret123"])
        guard case .signedIn(let session) = outcome else { return XCTFail("expected signedIn, got \(outcome)") }
        XCTAssertEqual(session.accessToken, "access-2")
    }

    func testSignupWithNullTokensNeedsEmailConfirmation() async throws {
        let body = """
        {"access_token":null,"refresh_token":null,"expires_in":null,"expires_at":null,\
        "token_type":null,"user":{"id":"u-9","email":"new@b.com"}}
        """
        let (auth, _) = client([.status(200, body)])
        let outcome = try await auth.signup(email: "New@B.com", password: "secret123")
        XCTAssertEqual(outcome, .confirmationRequired(email: "new@b.com"))
    }

    func testRefreshRequestShape() async throws {
        let (auth, transport) = client([.status(200, AuthFixtures.sessionJSON(3))])
        let session = try await auth.refresh(refreshToken: "refresh-2")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/auth/refresh")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(try jsonBody(request), ["refresh_token": "refresh-2"])
        XCTAssertEqual(session.refreshToken, "refresh-3", "the rotated token is what gets stored")
    }

    func testExpiresInFallbackWhenExpiresAtMissing() async throws {
        let body = """
        {"access_token":"a","refresh_token":"r","expires_in":600,"token_type":"bearer","user":{"id":"u","email":null}}
        """
        let (auth, _) = client([.status(200, body)])
        let session = try await auth.refresh(refreshToken: "r0")
        XCTAssertEqual(session.expiresAt, AuthFixtures.t0.addingTimeInterval(600))
        XCTAssertNil(session.user.email)
    }

    func testErrorMapping() async throws {
        func loginError(_ status: Int, _ body: String = "{}") async -> Error? {
            let (auth, _) = client([.status(status, body)])
            do { _ = try await auth.login(email: "a@b.com", password: "x"); return nil } catch { return error }
        }
        let invalid = await loginError(401, #"{"detail":"Invalid email or password."}"#)
        XCTAssertEqual(invalid as? AuthError, .invalidCredentials)
        let unavailable = await loginError(503, #"{"detail":"Auth service unavailable"}"#)
        XCTAssertEqual(unavailable as? AuthError, .serviceUnavailable)
        XCTAssertEqual((unavailable as? AuthError)?.isTransient, true)
        XCTAssertTrue((unavailable as? AuthError)?.errorDescription?.contains("isn't a problem with your password") ?? false,
                      "a 503 must not read like a wrong password")
        let other = await loginError(500, #"{"detail":"boom"}"#)
        XCTAssertEqual(other as? AuthError, .unexpectedStatus(500, "boom"))

        let (signupAuth, _) = client([.status(403, #"{"detail":"Signup is not open for this email address."}"#)])
        do { _ = try await signupAuth.signup(email: "x@y.com", password: "p"); XCTFail() } catch {
            XCTAssertEqual(error as? AuthError, .signupNotAllowed)
        }
        let (weak, _) = client([.status(400, #"{"detail":"Password should be at least 6 characters."}"#)])
        do { _ = try await weak.signup(email: "x@y.com", password: "p"); XCTFail() } catch {
            XCTAssertEqual(error as? AuthError, .rejected("Password should be at least 6 characters."),
                           "the server's own reason is shown")
        }
        let (validation, _) = client([.status(422, #"{"detail":[{"msg":"field required"},{"msg":"bad email"}]}"#)])
        do { _ = try await validation.signup(email: "", password: ""); XCTFail() } catch {
            XCTAssertEqual(error as? AuthError, .rejected("field required; bad email"))
        }

        let (refresh401, _) = client([.status(401, #"{"detail":"Invalid or expired refresh token."}"#)])
        do { _ = try await refresh401.refresh(refreshToken: "old"); XCTFail() } catch {
            XCTAssertEqual(error as? AuthError, .refreshTokenInvalid)
        }
        let (offline, _) = client([.failure(URLError(.notConnectedToInternet))])
        do { _ = try await offline.refresh(refreshToken: "r"); XCTFail() } catch {
            guard case .network = error as? AuthError else { return XCTFail("expected network, got \(error)") }
            XCTAssertEqual((error as? AuthError)?.isTransient, true)
        }
    }

    func testLoginWith200ButNoTokensIsBadResponse() async throws {
        let (auth, _) = client([.status(200, #"{"access_token":null,"user":{"id":"u"}}"#)])
        do { _ = try await auth.login(email: "a@b.com", password: "x"); XCTFail() } catch {
            XCTAssertEqual(error as? AuthError, .badResponse)
        }
    }

    func testNeedsRefreshUsesTwoMinuteLeeway() {
        let now = AuthFixtures.t0
        XCTAssertFalse(AuthFixtures.session(1, expiresIn: 121).needsRefresh(now: now))
        XCTAssertTrue(AuthFixtures.session(1, expiresIn: 119).needsRefresh(now: now))
        XCTAssertTrue(AuthFixtures.session(1, expiresIn: -5).isExpired(now: now))
    }
}
