import Foundation

/// The signed-in Supabase session, shared by the app and the Share Extension
/// through ONE Keychain item (see `KeychainSessionStore`). Never cached in
/// memory across calls: always reread from the store, because the other
/// process may have rotated the refresh token since.
public struct ClearedSession: Codable, Equatable, Sendable {
    public struct User: Codable, Equatable, Sendable {
        public var id: String
        public var email: String?

        public init(id: String, email: String?) {
            self.id = id
            self.email = email
        }
    }

    public var accessToken: String
    /// Single-use: Supabase rotates it on every refresh (contract §1).
    public var refreshToken: String
    public var expiresAt: Date
    public var tokenType: String
    public var user: User

    public init(accessToken: String, refreshToken: String, expiresAt: Date, tokenType: String = "bearer", user: User) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.user = user
    }

    /// Contract §1: refresh proactively when `expires_at - now < 120 s`.
    public static let refreshLeeway: TimeInterval = 120

    public func needsRefresh(now: Date, leeway: TimeInterval = ClearedSession.refreshLeeway) -> Bool {
        expiresAt.timeIntervalSince(now) < leeway
    }

    public func isExpired(now: Date) -> Bool {
        expiresAt <= now
    }
}

/// Wire shape of `/auth/login`, `/auth/signup`, `/auth/refresh` (contract §1).
/// Every token field is optional because signup with email confirmation
/// returns them all as null with only `user` set.
struct AuthSessionPayload: Decodable, Sendable {
    struct User: Decodable, Sendable {
        var id: String
        var email: String?
    }

    var accessToken: String?
    var refreshToken: String?
    var expiresIn: Double?
    var expiresAt: Double?
    var tokenType: String?
    var user: User?

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// nil when there is no usable session (confirmation pending, or a
    /// malformed payload). `expires_at` wins; `expires_in` is the fallback.
    func session(receivedAt now: Date) -> ClearedSession? {
        guard let accessToken, !accessToken.isEmpty,
              let refreshToken, !refreshToken.isEmpty,
              let user
        else { return nil }
        let expiry: Date
        if let expiresAt {
            expiry = Date(timeIntervalSince1970: expiresAt)
        } else if let expiresIn {
            expiry = now.addingTimeInterval(expiresIn)
        } else {
            // No expiry info: treat as already due so the next call refreshes.
            expiry = now
        }
        return ClearedSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiry,
            tokenType: tokenType ?? "bearer",
            user: .init(id: user.id, email: user.email)
        )
    }
}
