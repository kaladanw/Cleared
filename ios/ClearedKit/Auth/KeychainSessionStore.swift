#if canImport(Security)
import Foundation
import Security

/// The session as ONE generic-password Keychain item in a keychain access
/// group shared by the app and the Share Extension (`keychain-access-groups`
/// in both entitlements; see project.yml). One item, one JSON blob, so the
/// access and refresh tokens can never be saved half-rotated.
///
/// Not compiled on Linux (Security is Apple-only); the refresh logic talks to
/// the `SessionStore` protocol and is tested with `InMemorySessionStore`.
public struct KeychainSessionStore: SessionStore {
    public enum StoreError: Error, LocalizedError, Equatable {
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(text)"
            }
        }
    }

    static let service = "com.kaladanw.cleared.session"
    static let account = "supabase"

    /// Full access group including the team prefix, e.g.
    /// `ABCDE12345.com.kaladanw.cleared.shared`. nil uses the process default
    /// (only for tests / unsigned simulator runs; app and extension would then
    /// NOT share the item).
    let accessGroup: String?

    public init(accessGroup: String?) {
        self.accessGroup = accessGroup
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            // Data-protection keychain semantics on macOS too (Catalyst/tests).
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func load() throws -> ClearedSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            // An undecodable blob (format change) is treated as signed out
            // rather than wedging every request on a decode error.
            return try? SessionCoding.decode(data)
        case errSecItemNotFound:
            return nil
        default:
            throw StoreError.keychain(status)
        }
    }

    public func save(_ session: ClearedSession) throws {
        let data = try SessionCoding.encode(session)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Readable by the extension while the phone is locked-after-first-
            // unlock; never migrated to another device via backup.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw StoreError.keychain(status)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }
}
#endif
