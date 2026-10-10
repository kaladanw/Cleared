import Foundation
import XCTest

/// The refresh rules from docs/api-contract.md §1, against fakes and a real
/// flock(2) lock file in a temp directory.
final class SessionManagerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try AuthFixtures.tempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var lockURL: URL { directory.appending(path: "session-refresh.lock") }

    private func manager(
        store: SessionStore, refresher: SessionRefreshing, clock: TestClock = TestClock(AuthFixtures.t0)
    ) -> SessionManager {
        SessionManager(
            store: store, refresher: refresher, lock: FileLock(url: lockURL, pollInterval: .milliseconds(5)),
            now: { clock.now }, transientRetryDelays: [.zero, .zero]
        )
    }

    func testSignedOutReturnsNil() async throws {
        let refresher = FakeRefresher([])
        let token = try await manager(store: InMemorySessionStore(), refresher: refresher).accessToken(forceRefresh: false)
        XCTAssertNil(token)
        XCTAssertEqual(refresher.calls, 0)
    }

    func testFreshTokenIsReturnedWithoutRefreshing() async throws {
        let refresher = FakeRefresher([])
        let sut = manager(store: InMemorySessionStore(AuthFixtures.session(1, expiresIn: 600)), refresher: refresher)
        let token = try await sut.accessToken(forceRefresh: false)
        XCTAssertEqual(token, "access-1")
        XCTAssertEqual(refresher.calls, 0)
    }

    func testRefreshesWhenExpiringWithinTwoMinutesAndPersistsRotatedToken() async throws {
        let store = InMemorySessionStore(AuthFixtures.session(1, expiresIn: 90))
        let refresher = FakeRefresher([.success(AuthFixtures.session(2))])
        let token = try await manager(store: store, refresher: refresher).accessToken(forceRefresh: false)
        XCTAssertEqual(token, "access-2")
        XCTAssertEqual(refresher.refreshTokensSeen, ["refresh-1"])
        XCTAssertEqual(try store.load()?.refreshToken, "refresh-2", "the new refresh token must be saved")
    }

    func testForceRefreshRefreshesEvenWhenNotExpiring() async throws {
        let store = InMemorySessionStore(AuthFixtures.session(1, expiresIn: 3000))
        let refresher = FakeRefresher([.success(AuthFixtures.session(2))])
        let token = try await manager(store: store, refresher: refresher).accessToken(forceRefresh: true)
        XCTAssertEqual(token, "access-2")
        XCTAssertEqual(refresher.calls, 1)
    }

    /// The core cross-process rule: while we waited for the lock, the other
    /// process refreshed. After acquiring, we must reread and NOT spend the
    /// old refresh token (that would revoke the whole session).
    func testRereadsAfterLockAndSkipsRefreshIfAnotherProcessRefreshed() async throws {
        let store = CountingSessionStore(AuthFixtures.session(1, expiresIn: 30))
        let refresher = FakeRefresher([.success(AuthFixtures.session(99))])
        let sut = manager(store: store, refresher: refresher)

        // "The extension" holds the lock, as if mid-refresh.
        let held = try XCTUnwrap(FileLock(url: lockURL).tryAcquire())
        let pending = Task { try await sut.accessToken(forceRefresh: false) }
        try await waitUntil { store.loads >= 1 }          // app took its snapshot…
        try await Task.sleep(for: .milliseconds(30))       // …and is now waiting on the lock
        try store.save(AuthFixtures.session(2))            // extension saves its rotated session
        HeldFileLock(fd: held).release()

        let token = try await pending.value
        XCTAssertEqual(token, "access-2", "uses the session the other process saved")
        XCTAssertEqual(refresher.calls, 0, "must not reuse refresh-1 after it was rotated")
    }

    /// Same, for the forced refresh after a 401.
    func testForceRefreshSkipsIfAnotherProcessAlreadyRotated() async throws {
        let store = CountingSessionStore(AuthFixtures.session(1, expiresIn: 3000))
        let refresher = FakeRefresher([.success(AuthFixtures.session(99))])
        let sut = manager(store: store, refresher: refresher)
        let held = try XCTUnwrap(FileLock(url: lockURL).tryAcquire())
        let pending = Task { try await sut.accessToken(forceRefresh: true) }
        try await waitUntil { store.loads >= 1 }
        try await Task.sleep(for: .milliseconds(30))
        try store.save(AuthFixtures.session(2))
        HeldFileLock(fd: held).release()
        let token = try await pending.value
        XCTAssertEqual(token, "access-2")
        XCTAssertEqual(refresher.calls, 0)
    }

    /// Two managers on one store and one lock file = app + extension. Both
    /// need a refresh at once; exactly one network refresh may happen.
    func testTwoProcessesRefreshingAtOnceSpendTheTokenOnce() async throws {
        let store = InMemorySessionStore(AuthFixtures.session(1, expiresIn: 10))
        let refresher = FakeRefresher([.success(AuthFixtures.session(2)), .success(AuthFixtures.session(3))],
                                      delay: .milliseconds(100))
        let app = manager(store: store, refresher: refresher)
        let ext = manager(store: store, refresher: refresher)

        async let a = app.accessToken(forceRefresh: false)
        async let b = ext.accessToken(forceRefresh: false)
        let tokens = try await [a, b]

        XCTAssertEqual(refresher.calls, 1, "the second waiter must reread and skip")
        XCTAssertEqual(tokens, ["access-2", "access-2"])
        XCTAssertEqual(refresher.refreshTokensSeen, ["refresh-1"])
    }

    func testConcurrentCallersInOneProcessShareOneRefresh() async throws {
        let store = InMemorySessionStore(AuthFixtures.session(1, expiresIn: 10))
        let refresher = FakeRefresher([.success(AuthFixtures.session(2))], delay: .milliseconds(50))
        let sut = manager(store: store, refresher: refresher)
        let tokens = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<5 { group.addTask { try await sut.accessToken(forceRefresh: false) } }
            return try await group.reduce(into: [String?]()) { $0.append($1) }
        }
        XCTAssertEqual(refresher.calls, 1)
        XCTAssertEqual(Set(tokens.compactMap { $0 }), ["access-2"])
    }

    func testRefresh401SignsOutAndNotifies() async throws {
        let store = InMemorySessionStore(AuthFixtures.session(1, expiresIn: 10))
        let sut = manager(store: store, refresher: FakeRefresher([.failure(AuthError.refreshTokenInvalid)]))
        let notified = expectation(description: "signed-out handler")
        await sut.setSignedOutHandler { notified.fulfill() }
        let token = try await sut.accessToken(forceRefresh: false)
        XCTAssertNil(token)
        XCTAssertNil(try store.load(), "the shared Keychain item is cleared")
        await fulfillment(of: [notified], timeout: 1)
    }

    func testRefresh503KeepsSessionRetriesThenUsesStillValidToken() async throws {
        let store = InMemorySessionStore(AuthFixtures.session(1, expiresIn: 60))
        let refresher = FakeRefresher(Array(repeating: .failure(AuthError.serviceUnavailable), count: 3))
        let token = try await manager(store: store, refresher: refresher).accessToken(forceRefresh: false)
        XCTAssertEqual(refresher.calls, 3, "1 try + 2 backoff retries")
        XCTAssertEqual(token, "access-1", "not yet expired, so it's still usable")
        XCTAssertEqual(try store.load()?.refreshToken, "refresh-1", "session kept on 503")
    }

    func testRefresh503OnExpiredTokenThrowsButKeepsSession() async throws {
        let store = InMemorySessionStore(AuthFixtures.session(1, expiresIn: -10))
        let refresher = FakeRefresher([.failure(AuthError.serviceUnavailable), .failure(AuthError.network("offline")),
                                       .failure(AuthError.serviceUnavailable)])
        do {
            _ = try await manager(store: store, refresher: refresher).accessToken(forceRefresh: false)
            XCTFail("expected serviceUnavailable")
        } catch {
            XCTAssertEqual(error as? AuthError, .serviceUnavailable)
        }
        XCTAssertNotNil(try store.load(), "never sign out on a transient failure")
    }

    func testTransientRetrySucceeds() async throws {
        let store = InMemorySessionStore(AuthFixtures.session(1, expiresIn: -10))
        let refresher = FakeRefresher([.failure(AuthError.serviceUnavailable), .success(AuthFixtures.session(2))])
        let token = try await manager(store: store, refresher: refresher).accessToken(forceRefresh: false)
        XCTAssertEqual(token, "access-2")
        XCTAssertEqual(refresher.refreshTokensSeen, ["refresh-1", "refresh-1"])
    }

    func testAuthenticationFailedSignsOutOnlyTheFailingSession() async throws {
        let store = InMemorySessionStore(AuthFixtures.session(2))
        let sut = manager(store: store, refresher: FakeRefresher([]))
        await sut.authenticationFailed(accessToken: "access-1")
        XCTAssertNotNil(try store.load(), "a newer session (signed in meanwhile) survives")
        await sut.authenticationFailed(accessToken: "access-2")
        XCTAssertNil(try store.load())
    }

    func testSignInAndSignOut() async throws {
        let store = InMemorySessionStore()
        let sut = manager(store: store, refresher: FakeRefresher([]))
        try await sut.signIn(AuthFixtures.session(5))
        XCTAssertEqual(sut.currentSession()?.accessToken, "access-5")
        try await sut.signOut()
        XCTAssertNil(sut.currentSession())
    }

    func testSignedOutElsewhereWhileWaitingReturnsNil() async throws {
        let store = CountingSessionStore(AuthFixtures.session(1, expiresIn: 10))
        let refresher = FakeRefresher([.success(AuthFixtures.session(2))])
        let sut = manager(store: store, refresher: refresher)
        let held = try XCTUnwrap(FileLock(url: lockURL).tryAcquire())
        let pending = Task { try await sut.accessToken(forceRefresh: false) }
        try await waitUntil { store.loads >= 1 }
        try await Task.sleep(for: .milliseconds(30))
        try store.clear()
        HeldFileLock(fd: held).release()
        let token = try await pending.value
        XCTAssertNil(token)
        XCTAssertEqual(refresher.calls, 0)
    }
}

final class FileLockTests: XCTestCase {
    func testExcludesSecondDescriptorInSameProcessAndReleases() throws {
        let directory = try AuthFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = FileLock(url: directory.appending(path: "x.lock"))
        let first = try XCTUnwrap(lock.tryAcquire())
        XCTAssertNil(try lock.tryAcquire(), "flock is per open file description")
        HeldFileLock(fd: first).release()
        let again = try XCTUnwrap(lock.tryAcquire())
        HeldFileLock(fd: again).release()
    }

    func testTimesOutWhileHeld() async throws {
        let directory = try AuthFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "x.lock")
        let held = try XCTUnwrap(FileLock(url: url).tryAcquire())
        defer { HeldFileLock(fd: held).release() }
        do {
            _ = try await FileLock(url: url, timeout: 0.1, pollInterval: .milliseconds(10)).withLock { 1 }
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? FileLock.LockError, .timedOut)
        }
    }

    #if os(Linux) || os(macOS)
    /// True while someone else holds the lock (probing never keeps it).
    private static func isHeldElsewhere(_ lock: FileLock) -> Bool {
        guard let fd = try? lock.tryAcquire() else { return true }
        HeldFileLock(fd: fd).release()
        return false
    }

    /// A REAL second process holding flock(2) on `url` for `seconds`. One
    /// process (python3), not flock(1), because flock(1)'s forked child
    /// inherits the descriptor and would keep the lock after a kill.
    private static func holder(_ url: URL, seconds: Double) throws -> Process {
        let python = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python else { throw XCTSkip("python3 not installed") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", """
            import fcntl, sys, time
            f = open(sys.argv[1], "a")
            fcntl.flock(f, fcntl.LOCK_EX)
            time.sleep(float(sys.argv[2]))
            """, url.path, String(seconds)]
        try process.run()
        return process
    }

    /// Another process holds the lock: we wait, and acquire once it exits.
    func testWaitsForAnotherProcessAndAcquiresWhenItExits() async throws {
        let directory = try AuthFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "x.lock")
        let other = try Self.holder(url, seconds: 0.6)
        defer { if other.isRunning { other.terminate() } }

        let lock = FileLock(url: url, timeout: 5, pollInterval: .milliseconds(10))
        try await waitUntil { Self.isHeldElsewhere(lock) }
        let started = Date()
        let value = try await lock.withLock { 42 }
        XCTAssertEqual(value, 42)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.2, "had to wait for the other process")
    }

    /// "Kill the app mid-refresh": the kernel drops the dead holder's lock
    /// immediately; no stale lock file blocks the extension.
    func testKilledHolderReleasesLockImmediately() async throws {
        let directory = try AuthFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "x.lock")
        let other = try Self.holder(url, seconds: 30)
        let lock = FileLock(url: url, timeout: 2, pollInterval: .milliseconds(10))
        try await waitUntil { Self.isHeldElsewhere(lock) }

        kill(other.processIdentifier, SIGKILL)
        other.waitUntilExit()
        let started = Date()
        let value = try await lock.withLock { "acquired" }
        XCTAssertEqual(value, "acquired")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
    #endif
}
