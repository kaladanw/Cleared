import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one HTTP seam for Cleared backend calls (auth, checks, history), so the
/// refresh/retry logic can be unit-tested with fakes instead of a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport. `timeout` is per request: ~240 s for checks (vision +
/// web search), short for auth so a refresh never holds the session lock long.
public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(requestTimeout: TimeInterval, resourceTimeout: TimeInterval? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout ?? requestTimeout
        // Tokens must never land in a shared on-disk cache.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// FastAPI error bodies are `{"detail": "<message>"}`; 422s may carry a list.
enum APIErrorDetail {
    static func message(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let text = object["detail"] as? String, !text.isEmpty {
            return text
        }
        if let list = object["detail"] as? [[String: Any]] {
            let messages = list.compactMap { $0["msg"] as? String }
            return messages.isEmpty ? nil : messages.joined(separator: "; ")
        }
        return nil
    }
}
