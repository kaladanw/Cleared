#if canImport(Security)
import Foundation

/// Production wiring shared by the app and the Share Extension: the same
/// Keychain item, the same lock file, the same backend. Each process builds
/// its own `SessionManager`; they coordinate only through the Keychain and
/// the lock, never through memory.
public enum ClearedAuth {
    public enum SetupError: Error, LocalizedError, Equatable {
        case noBackend
        case noAppGroup
        case noKeychainGroup

        public var errorDescription: String? {
            switch self {
            case .noBackend:
                return "Backend not configured. Fill in ios/Secrets.xcconfig and rebuild."
            case .noAppGroup:
                return "This build is missing the App Group entitlement (group.com.kaladanw.cleared), so the app and the share sheet can't share your sign-in."
            case .noKeychainGroup:
                return "This build is missing the shared keychain group, so the app and the share sheet can't share your sign-in. Set a development team and rebuild."
            }
        }
    }

    public static func makeSessionManager(activity: LockHoldingActivity = ImmediateActivity()) throws -> SessionManager {
        guard let backend = ClearedConfig.backendURL else { throw SetupError.noBackend }
        guard let lockURL = ClearedConfig.sessionLockURL else { throw SetupError.noAppGroup }
        guard let group = ClearedConfig.keychainAccessGroup else { throw SetupError.noKeychainGroup }
        return SessionManager(
            store: KeychainSessionStore(accessGroup: group),
            refresher: AuthClient(baseURL: backend),
            lock: FileLock(url: lockURL),
            activity: activity
        )
    }
}
#endif
