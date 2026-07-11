import UIKit
import XCTest

final class ImageDownscaleTests: XCTestCase {
    private func solidImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format
        ).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testOversizedImageIsCappedAt1600() throws {
        let data = try XCTUnwrap(
            solidImage(width: 4000, height: 2000).downscaledJPEG()
        )
        let decoded = try XCTUnwrap(UIImage(data: data))

        XCTAssertEqual(max(decoded.size.width, decoded.size.height) * decoded.scale,
                       1600, accuracy: 2)
        // JPEG magic bytes, not PNG.
        XCTAssertEqual(data.prefix(2), Data([0xFF, 0xD8]))
    }

    func testSmallImageIsNotUpscaled() throws {
        let data = try XCTUnwrap(
            solidImage(width: 800, height: 600).downscaledJPEG()
        )
        let decoded = try XCTUnwrap(UIImage(data: data))

        XCTAssertEqual(decoded.size.width * decoded.scale, 800, accuracy: 2)
        XCTAssertEqual(decoded.size.height * decoded.scale, 600, accuracy: 2)
    }
}
