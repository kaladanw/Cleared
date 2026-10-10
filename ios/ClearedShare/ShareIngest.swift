import UIKit
import UniformTypeIdentifiers

/// Everything useful the share sheet handed the extension.
struct SharedPayload {
    var images: [UIImage]
    /// The first Depop listing link found in shared URLs or text, if any.
    var depopLink: DepopLink?
}

/// Pulls shared images, URLs, and text out of the extension context.
///
/// - Photos/Screenshots shares images (capped at 4 to match the activation rule).
/// - Depop's Share button sends text like "Look what I just found on Depop 👀
///   https://depop.app.link/<code>" (and/or a URL item).
/// - Safari/Chrome send the product page URL.
///
/// MainActor-bound: NSExtensionContext/NSItemProvider aren't Sendable; the
/// actual loading still happens off-main inside the provider callbacks.
@MainActor
enum ShareIngest {
    static let maxImages = 4

    static func load(from context: NSExtensionContext?) async -> SharedPayload {
        guard let items = context?.inputItems as? [NSExtensionItem] else {
            return SharedPayload(images: [], depopLink: nil)
        }

        var images: [UIImage] = []
        var urls: [URL] = []
        var texts: [String] = []
        for item in items {
            // Some apps put the message in the item's text, not an attachment.
            if let text = item.attributedContentText?.string, !text.isEmpty {
                texts.append(text)
            }
            for provider in item.attachments ?? [] {
                // Images first: a Photos share can also conform to public.url
                // (a file URL), and that's not a listing link.
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if images.count < maxImages, let image = try? await loadImage(from: provider) {
                        images.append(image)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = try? await loadObject(URL.self, from: provider) {
                        urls.append(url)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let text = try? await loadObject(String.self, from: provider) {
                        texts.append(text)
                    }
                }
            }
        }
        return SharedPayload(
            images: images,
            depopLink: DepopLink.firstLink(urls: urls, texts: texts)
        )
    }

    private static func loadImage(from provider: NSItemProvider) async throws -> UIImage? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(for: .image) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data.flatMap(UIImage.init(data:)))
                }
            }
        }
    }

    private static func loadObject<T: _ObjectiveCBridgeable & Sendable>(
        _ type: T.Type, from provider: NSItemProvider
    ) async throws -> T? where T._ObjectiveCType: NSItemProviderReading {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: object)
                }
            }
        }
    }
}
