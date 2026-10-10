import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

/// Scripted HTTP: returns queued responses in order and records every request.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case status(Int, String)
        case failure(Error)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requestsStorage: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requestsStorage
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = {
            lock.lock(); defer { lock.unlock() }
            requestsStorage.append(request)
            return replies.isEmpty ? .status(599, "{\"detail\":\"no scripted reply\"}") : replies.removeFirst()
        }()
        switch reply {
        case .failure(let error):
            throw error
        case .status(let code, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }
}

/// Scripted `/auth/refresh`: counts calls, optional delay to widen races.
final class FakeRefresher: SessionRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<ClearedSession, Error>]
    private var tokensSeen: [String] = []
    let delay: Duration

    init(_ results: [Result<ClearedSession, Error>], delay: Duration = .zero) {
        self.results = results
        self.delay = delay
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return tokensSeen.count }
    var refreshTokensSeen: [String] { lock.lock(); defer { lock.unlock() }; return tokensSeen }

    func refresh(refreshToken: String) async throws -> ClearedSession {
        let result: Result<ClearedSession, Error> = {
            lock.lock(); defer { lock.unlock() }
            tokensSeen.append(refreshToken)
            return results.isEmpty ? .failure(AuthError.unexpectedStatus(599, "unscripted")) : results.removeFirst()
        }()
        if delay > .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}

/// `InMemorySessionStore` that counts loads, so a test can wait until a
/// refresher has taken its snapshot before mutating the store.
final class CountingSessionStore: SessionStore, @unchecked Sendable {
    private let inner: InMemorySessionStore
    private let lock = NSLock()
    private var loadCount = 0
    private var saveCount = 0

    init(_ session: ClearedSession?) {
        inner = InMemorySessionStore(session)
    }

    var loads: Int { lock.lock(); defer { lock.unlock() }; return loadCount }
    var saves: Int { lock.lock(); defer { lock.unlock() }; return saveCount }

    func load() throws -> ClearedSession? {
        lock.lock(); loadCount += 1; lock.unlock()
        return try inner.load()
    }

    func save(_ session: ClearedSession) throws {
        lock.lock(); saveCount += 1; lock.unlock()
        try inner.save(session)
    }

    func clear() throws { try inner.clear() }
}

/// Settable clock.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

enum AuthFixtures {
    static let t0 = Date(timeIntervalSince1970: 1_791_230_000)
    static let user = ClearedSession.User(id: "user-1", email: "kalada@example.com")

    static func session(_ n: Int, expiresIn: TimeInterval = 3600, from now: Date = t0) -> ClearedSession {
        ClearedSession(
            accessToken: "access-\(n)", refreshToken: "refresh-\(n)",
            expiresAt: now.addingTimeInterval(expiresIn), user: user
        )
    }

    static func tempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cleared-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func sessionJSON(_ n: Int, expiresAt: Int = 1_791_233_600) -> String {
        """
        {"access_token":"access-\(n)","refresh_token":"refresh-\(n)","expires_in":3600,\
        "expires_at":\(expiresAt),"token_type":"bearer","user":{"id":"user-1","email":"kalada@example.com"}}
        """
    }
}

/// Polls until `condition` holds or fails the test after `timeout`.
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("timed out waiting", file: file, line: line)
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
