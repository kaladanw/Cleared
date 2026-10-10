import Foundation

/// Persistence for the one shared session. Implementations must be safe to
/// call from any thread and from two processes (app + Share Extension); the
/// refresh lock (`FileLock`) serializes writers, the store only has to make
/// each `save` atomic.
public protocol SessionStore: Sendable {
    func load() throws -> ClearedSession?
    func save(_ session: ClearedSession) throws
    func clear() throws
}

/// Encoding shared by every store so the Keychain blob format is defined once.
enum SessionCoding {
    static func encode(_ session: ClearedSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(session)
    }

    static func decode(_ data: Data) throws -> ClearedSession {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(ClearedSession.self, from: data)
    }
}

/// In-memory store for previews and tests.
public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: ClearedSession?

    public init(_ session: ClearedSession? = nil) {
        self.session = session
    }

    public func load() throws -> ClearedSession? {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    public func save(_ session: ClearedSession) throws {
        lock.lock(); defer { lock.unlock() }
        self.session = session
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        session = nil
    }
}
