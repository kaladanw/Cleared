import Foundation

/// What the history screen shows after a sync attempt.
public struct HistorySnapshot: Equatable, Sendable {
    public var entries: [HistoryEntry]
    /// Set when the server couldn't be read and these entries are the cache.
    public var staleReason: String?
    /// The server rejected the session for good; the UI should show sign-in.
    public var signedOut: Bool

    public init(entries: [HistoryEntry], staleReason: String? = nil, signedOut: Bool = false) {
        self.entries = entries
        self.staleReason = staleReason
        self.signedOut = signedOut
    }
}

/// `GET /api/reports` → cache, with the cache as the fallback (contract §3):
/// replace from the server on launch, pull-to-refresh, and after each check;
/// keep the cache on 401/503/offline.
public struct ReportHistoryService: Sendable {
    let api: ClearedAPIClient
    let store: ReportHistoryStore

    public init(api: ClearedAPIClient, store: ReportHistoryStore) {
        self.api = api
        self.store = store
    }

    public func cached(userID: String?) -> HistorySnapshot {
        HistorySnapshot(entries: store.entries(for: userID))
    }

    public func sync(userID: String) async -> HistorySnapshot {
        do {
            let rows = try await api.fetchReports()
            do {
                try store.replaceServerRows(rows, userID: userID)
            } catch {
                // Can't write the cache: still show what the server said.
                let local = store.entries(for: userID).filter(\.isLocalOnly)
                return HistorySnapshot(entries: rows.map(HistoryEntry.server) + local)
            }
            return HistorySnapshot(entries: store.entries(for: userID))
        } catch ClearedAPIError.signInRequired {
            return HistorySnapshot(entries: store.entries(for: nil), signedOut: true)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return HistorySnapshot(
                entries: store.entries(for: userID),
                staleReason: "Showing saved history. Couldn't refresh: \(reason)"
            )
        }
    }
}
