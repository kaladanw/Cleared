import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Cross-process exclusive lock built on `flock(2)` over a file in the App
/// Group container, so the app and the Share Extension (separate processes)
/// never refresh the session at the same time.
///
/// - Each `withLock` opens its own file descriptor. flock locks belong to the
///   open file description, so two callers in the SAME process also exclude
///   each other, not just two processes.
/// - The kernel drops the lock when the holder's descriptor closes, including
///   when the process is killed mid-refresh. No stale-lock cleanup needed.
/// - Acquisition polls with `LOCK_NB` + `Task.sleep` instead of a blocking
///   `LOCK_EX`, so a waiter never parks a Swift-concurrency thread.
/// - iOS terminates a *suspended* process that holds a lock on a shared-
///   container file (0xdead10cc). Hold it only around the short refresh
///   request; the app wraps that in a background task (see `SessionManager`).
public struct FileLock: Sendable {
    public enum LockError: Error, Equatable, LocalizedError {
        case cannotOpen(errno: Int32)
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let code):
                return "Couldn't open the session lock file (errno \(code))."
            case .timedOut:
                return "Another part of Cleared is still refreshing your sign-in. Try again in a moment."
            }
        }
    }

    public let url: URL
    public let timeout: TimeInterval
    let pollInterval: Duration

    public init(url: URL, timeout: TimeInterval = 30, pollInterval: Duration = .milliseconds(50)) {
        self.url = url
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    public func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        let fd = try await acquire()
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        return try await body()
    }

    /// Non-blocking single attempt; returns the held descriptor or nil.
    /// Exposed for tests that need to hold the lock from "another process".
    func tryAcquire() throws -> Int32? {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LockError.cannotOpen(errno: errno) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return fd
        }
        let code = errno
        close(fd)
        if code == EWOULDBLOCK || code == EINTR {
            return nil
        }
        throw LockError.cannotOpen(errno: code)
    }

    private func acquire() async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let fd = try tryAcquire() {
                return fd
            }
            if Date() >= deadline {
                throw LockError.timedOut
            }
            try await Task.sleep(for: pollInterval)
        }
    }
}

/// A held lock for tests: `release()` unlocks and closes.
struct HeldFileLock {
    let fd: Int32

    func release() {
        _ = flock(fd, LOCK_UN)
        close(fd)
    }
}
