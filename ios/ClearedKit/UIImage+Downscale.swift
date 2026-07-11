import UIKit

public extension UIImage {
    /// Screenshots arrive as full-res PNG; ~1600 px JPEG keeps the upload small
    /// and the vision tokens sane without hurting text legibility (phase-3.md).
    func downscaledJPEG(maxDimension: CGFloat = 1600, quality: CGFloat = 0.8) -> Data? {
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > 0 else { return nil }

        let ratio = min(1, maxDimension / longest)
        let target = CGSize(width: pixelWidth * ratio, height: pixelHeight * ratio)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1  // render at exactly `target` pixels
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
