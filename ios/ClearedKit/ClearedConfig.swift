import Foundation

/// Backend URL + shared token, injected at build time via Secrets.xcconfig →
/// build settings → Info.plist. Nil/empty means the xcconfig wasn't filled in —
/// callers should surface that honestly, never fall back to a guessed URL.
public enum ClearedConfig {
    public static var backendURL: URL? {
        guard let raw = infoString("ClearedBackendURL"), !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    public static var sharedToken: String? {
        guard let raw = infoString("ClearedSharedToken"), !raw.isEmpty else { return nil }
        return raw
    }

    /// Backend reachable. Since the auth PR a shared token is optional
    /// (signed-in users use Bearer); it only matters for legacy `/check`.
    public static var isConfigured: Bool {
        backendURL != nil
    }

    /// App Group shared by the app and the Share Extension (history cache,
    /// session refresh lock, Depop size-table cache).
    public static let appGroup = "group.com.kaladanw.cleared"

    public static var appGroupContainer: URL? {
        #if canImport(Darwin)
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        #else
        nil // Linux test harness: App Groups don't exist.
        #endif
    }

    /// The flock file that serializes session refreshes across processes.
    public static var sessionLockURL: URL? {
        appGroupContainer?.appending(path: "session-refresh.lock")
    }

    /// Shared keychain access group with the team prefix, injected via
    /// Info.plist `ClearedKeychainAccessGroup` =
    /// `$(AppIdentifierPrefix)com.kaladanw.cleared.shared`. nil if the build
    /// setting didn't expand (unsigned build), so callers fail loudly rather
    /// than silently writing an app-private item the extension can't read.
    public static var keychainAccessGroup: String? {
        guard let raw = infoString("ClearedKeychainAccessGroup"),
              !raw.isEmpty, !raw.contains("$("), !raw.hasPrefix(".")
        else { return nil }
        return raw
    }

    private static func infoString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
