import Foundation

/// Runs the lock-holding part of a refresh. The app wraps it in a UIKit
/// background task so iOS doesn't suspend it while it holds the shared-
/// container lock (0xdead10cc); the extension and tests run it as-is.
public protocol LockHoldingActivity: Sendable {
    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T
}

public struct ImmediateActivity: LockHoldingActivity {
    public init() {}
    public func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await work()
    }
}

/// The concrete `AccessTokenProvider`: one shared session for the app and the
/// Share Extension, refreshed safely across both processes.
///
/// Rules (docs/api-contract.md §1):
/// - Always reread the store; never trust an in-memory copy, since the other
///   process may have rotated the refresh token.
/// - Refresh when the access token expires within 2 minutes, and on demand
///   (`forceRefresh`) once after a 401.
/// - Refreshes are serialized by a `FileLock` in the App Group container.
///   After acquiring it, reread the store: if the refresh token changed while
///   we waited, another process already refreshed, so use its session and
///   don't spend (and thereby revoke) the old token.
/// - Persist the rotated session before releasing the lock.
/// - Refresh 401 → sign out (clear the one shared item). 503 / network →
///   keep the session, retry with backoff, then surface the error.
public actor SessionManager: AccessTokenProvider {
    enum Outcome: Sendable {
        case session(ClearedSession)
        case signedOut
    }

    let store: SessionStore
    let refresher: SessionRefreshing
    let lock: FileLock
    let activity: LockHoldingActivity
    let now: @Sendable () -> Date
    let transientRetryDelays: [Duration]

    private var inFlight: Task<Outcome, Error>?
    private var signedOutHandler: (@Sendable () -> Void)?

    public init(
        store: SessionStore,
        refresher: SessionRefreshing,
        lock: FileLock,
        activity: LockHoldingActivity = ImmediateActivity(),
        now: @escaping @Sendable () -> Date = Date.init,
        transientRetryDelays: [Duration] = [.milliseconds(500), .seconds(2)]
    ) {
        self.store = store
        self.refresher = refresher
        self.lock = lock
        self.activity = activity
        self.now = now
        self.transientRetryDelays = transientRetryDelays
    }

    /// Called (off the main actor) whenever the session is cleared because the
    /// server rejected it, so UI can drop to the sign-in screen.
    public func setSignedOutHandler(_ handler: (@Sendable () -> Void)?) {
        signedOutHandler = handler
    }

    // MARK: Reading

    public nonisolated func currentSession() -> ClearedSession? {
        try? store.load()
    }

    public func accessToken(forceRefresh: Bool) async throws -> String? {
        guard let snapshot = try store.load() else { return nil }
        if !forceRefresh && !snapshot.needsRefresh(now: now()) {
            return snapshot.accessToken
        }
        switch try await refresh(from: snapshot, force: forceRefresh) {
        case .session(let session): return session.accessToken
        case .signedOut: return nil
        }
    }

    /// The retry with a refreshed token also got 401: the contract says sign
    /// out. Only clears the store if it still holds the token that failed, so
    /// a sign-in that happened meanwhile in the other process survives.
    public func authenticationFailed(accessToken failed: String) async {
        let cleared = (try? await activity.run { [store, lock] in
            try await lock.withLock { () -> Bool in
                guard let current = try store.load(), current.accessToken == failed else { return false }
                try store.clear()
                return true
            }
        }) ?? false
        if cleared { signedOutHandler?() }
    }

    // MARK: Writing

    /// Persist a fresh session from sign-in / sign-up.
    public func signIn(_ session: ClearedSession) async throws {
        try await activity.run { [store, lock] in
            try await lock.withLock { try store.save(session) }
        }
    }

    /// Explicit sign-out. Under the lock so a concurrent refresh in the other
    /// process can't write the session back afterwards.
    public func signOut() async throws {
        try await activity.run { [store, lock] in
            try await lock.withLock { try store.clear() }
        }
    }

    // MARK: Refresh

    private func refresh(from snapshot: ClearedSession, force: Bool) async throws -> Outcome {
        // Coalesce concurrent callers in this process onto one refresh.
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await self.performLockedRefresh(from: snapshot, force: force) }
        inFlight = task
        defer { inFlight = nil }
        let outcome = try await task.value
        if case .signedOut = outcome { signedOutHandler?() }
        return outcome
    }

    nonisolated func performLockedRefresh(from snapshot: ClearedSession, force: Bool) async throws -> Outcome {
        try await activity.run { [self] in
            try await lock.withLock { try await self.refreshHoldingLock(from: snapshot, force: force) }
        }
    }

    private nonisolated func refreshHoldingLock(from snapshot: ClearedSession, force: Bool) async throws -> Outcome {
        // Reread: the other process may have refreshed or signed out while we waited.
        guard let current = try store.load() else { return .signedOut }
        if current.refreshToken != snapshot.refreshToken, !current.needsRefresh(now: now()) {
            return .session(current)
        }
        if !force, !current.needsRefresh(now: now()) {
            return .session(current)
        }

        do {
            let rotated = try await refreshWithRetry(refreshToken: current.refreshToken)
            // Save before the lock is released; the old refresh token is now spent.
            try store.save(rotated)
            return .session(rotated)
        } catch AuthError.refreshTokenInvalid {
            try store.clear()
            return .signedOut
        } catch let error as AuthError where error.isTransient {
            // Keep the session. A proactive refresh can still use a token that
            // hasn't expired yet; a forced one (after a 401) can't.
            if !force, !current.isExpired(now: now()) {
                return .session(current)
            }
            throw error
        }
    }

    private nonisolated func refreshWithRetry(refreshToken: String) async throws -> ClearedSession {
        var attempt = 0
        while true {
            do {
                return try await refresher.refresh(refreshToken: refreshToken)
            } catch let error as AuthError where error.isTransient && attempt < transientRetryDelays.count {
                try await Task.sleep(for: transientRetryDelays[attempt])
                attempt += 1
            }
        }
    }
}
