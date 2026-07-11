import Foundation

public enum ClearedAPIError: Error, LocalizedError {
    case notConfigured
    case unauthorized
    case serverError(status: Int)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Backend not configured — fill in ios/Secrets.xcconfig and rebuild."
        case .unauthorized:
            return "The backend rejected the token (401). Check CLEARED_SHARED_TOKEN in Secrets.xcconfig against Railway."
        case .serverError(let status):
            return "The backend returned an error (HTTP \(status)). Try again in a moment."
        case .badResponse:
            return "Couldn't read the backend's response."
        }
    }
}

/// The one network call: multipart POST /check with the shared token.
/// A check takes ~30–90 s (vision + web_search), hence the long timeout.
public struct ClearedAPIClient: Sendable {
    let baseURL: URL
    let token: String
    let session: URLSession

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 240
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    /// Reads Secrets.xcconfig-injected config; nil when not configured.
    public static func fromConfig() -> ClearedAPIClient? {
        guard let url = ClearedConfig.backendURL,
              let token = ClearedConfig.sharedToken else { return nil }
        return ClearedAPIClient(baseURL: url, token: token)
    }

    public func check(images: [Data], userContext: String?) async throws -> CheckReport {
        let request = makeCheckRequest(images: images, userContext: userContext)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClearedAPIError.badResponse
        }
        switch http.statusCode {
        case 200:
            return try CheckReport.decoder().decode(CheckReport.self, from: data)
        case 401:
            throw ClearedAPIError.unauthorized
        default:
            throw ClearedAPIError.serverError(status: http.statusCode)
        }
    }

    /// Split out (internal) so tests can assert the request shape without a network.
    func makeCheckRequest(images: [Data], userContext: String?) -> URLRequest {
        var multipart = MultipartBody()
        for (index, imageData) in images.enumerated() {
            multipart.appendFile(
                name: "images",
                filename: "shot-\(index).jpg",
                contentType: "image/jpeg",
                data: imageData
            )
        }
        if let userContext, !userContext.isEmpty {
            multipart.appendField(name: "user_context", value: userContext)
        }

        var request = URLRequest(url: baseURL.appending(path: "check"))
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Cleared-Token")
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.finalized()
        return request
    }
}
