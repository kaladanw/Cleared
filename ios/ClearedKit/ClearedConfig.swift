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

    public static var isConfigured: Bool {
        backendURL != nil && sharedToken != nil
    }

    private static func infoString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
