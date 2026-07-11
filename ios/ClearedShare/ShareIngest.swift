import UIKit
import UniformTypeIdentifiers

/// Pulls shared images out of the extension context. Caps at 4 to match the
/// activation rule (NSExtensionActivationSupportsImageWithMaxCount).
/// MainActor-bound: NSExtensionContext/NSItemProvider aren't Sendable; the
/// actual byte loading still happens off-main inside the provider callback.
@MainActor
enum ShareIngest {
    static let maxImages = 4

    static func loadImages(from context: NSExtensionContext?) async -> [UIImage] {
        guard let items = context?.inputItems as? [NSExtensionItem] else { return [] }

        var images: [UIImage] = []
        for item in items {
            for provider in item.attachments ?? [] {
                guard images.count < maxImages else { return images }
                if let image = try? await loadImage(from: provider) {
                    images.append(image)
                }
            }
        }
        return images
    }

    private static func loadImage(from provider: NSItemProvider) async throws -> UIImage? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(for: .image) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data.flatMap(UIImage.init(data:)))
                }
            }
        }
    }
}
