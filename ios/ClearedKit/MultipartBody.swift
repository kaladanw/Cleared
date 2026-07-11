import Foundation

/// Builds the multipart/form-data body for POST /check. Kept as a pure value
/// type so tests can assert the exact body shape without touching the network.
public struct MultipartBody: Sendable {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "cleared-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public mutating func appendField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    public mutating func appendFile(
        name: String, filename: String, contentType: String, data: Data
    ) {
        append("--\(boundary)\r\n")
        append(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
        )
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    public func finalized() -> Data {
        var out = body
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}
