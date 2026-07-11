import XCTest

final class MultipartBodyTests: XCTestCase {
    func testBodyShapeWithImagesAndContext() throws {
        var body = MultipartBody(boundary: "test-boundary")
        body.appendFile(
            name: "images", filename: "shot-0.jpg",
            contentType: "image/jpeg", data: Data([0xFF, 0xD8])
        )
        body.appendFile(
            name: "images", filename: "shot-1.jpg",
            contentType: "image/jpeg", data: Data([0xFF, 0xD8])
        )
        body.appendField(name: "user_context", value: "it's a gift")
        let rendered = try XCTUnwrap(
            String(data: body.finalized(), encoding: .isoLatin1)
        )

        // Two image parts under the SAME field name — FastAPI's list[UploadFile].
        XCTAssertEqual(
            rendered.components(
                separatedBy: "Content-Disposition: form-data; name=\"images\""
            ).count - 1,
            2
        )
        XCTAssertTrue(rendered.contains("filename=\"shot-0.jpg\""))
        XCTAssertTrue(rendered.contains("filename=\"shot-1.jpg\""))
        XCTAssertTrue(rendered.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(rendered.contains("name=\"user_context\"\r\n\r\nit's a gift\r\n"))
        XCTAssertTrue(rendered.hasSuffix("--test-boundary--\r\n"))
        XCTAssertEqual(body.contentType, "multipart/form-data; boundary=test-boundary")
    }

    func testRequestCarriesTokenHeaderAndLongTimeout() throws {
        let client = ClearedAPIClient(
            baseURL: URL(string: "https://example.com")!, token: "tok-123"
        )
        let request = client.makeCheckRequest(
            images: [Data([0xFF])], userContext: nil
        )

        XCTAssertEqual(request.url?.path(), "/check")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Cleared-Token"), "tok-123")
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Content-Type")?
                .hasPrefix("multipart/form-data; boundary=") ?? false
        )
        // No user_context part when nil.
        let rendered = String(data: request.httpBody ?? Data(), encoding: .isoLatin1) ?? ""
        XCTAssertFalse(rendered.contains("user_context"))
        XCTAssertEqual(client.session.configuration.timeoutIntervalForRequest, 240)
    }
}
