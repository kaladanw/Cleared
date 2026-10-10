import Foundation

/// The subset of `GET https://api.depop.com/api/v1/products/<slug-or-id>/`
/// that Cleared uses. This is Depop's internal mobile API (unauthenticated,
/// undocumented, and its ToS forbid third-party use; Kalada accepted that
/// risk). Every field is optional so a schema drift degrades the seed facts
/// instead of failing the check: the photos are what matter.
public struct DepopProduct: Decodable, Sendable {
    public struct Picture: Decodable, Sendable {
        public struct Format: Decodable, Sendable {
            public var url: String?
            public var width: Int?
            public var height: Int?
        }
        public var id: Int?
        public var formats: [String: Format]?
    }

    public struct UserData: Decodable, Sendable {
        public var id: Int?
        public var username: String?
    }

    public struct Prices: Decodable, Sendable {
        public struct Price: Decodable, Sendable {
            public var price: String?
        }
        public var originalPrice: Price?
        public var currentPrice: Price?
    }

    public var id: Int?
    public var slug: String?
    public var description: String?
    public var priceAmount: String?
    public var priceCurrency: String?
    public var prices: Prices?
    /// A brand *slug* such as `levi-s`; see `DepopListingMapper.brandName`.
    public var brand: String?
    /// e.g. `brand_new`, `used_like_new`, `used_excellent`, `used_good`, `used_fair`.
    public var condition: String?
    /// Size-chart id; resolve with the v2 categories `variantSet` list.
    public var variantSet: Int?
    /// `{ "<variantId>": <quantity> }`.
    public var variants: [String: Int]?
    public var group: String?
    public var productType: String?
    public var quantity: Int?
    public var activeStatus: String?
    public var status: String?
    public var picturesData: [Picture]?
    public var userData: UserData?

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// `GET https://api.depop.com/api/v2/categories/` → `variantSet[].variant[]`,
/// reduced to `[setId: [variantId: label]]` (e.g. set 60 / id 15 → `32"`).
public struct DepopSizeTable: Codable, Equatable, Sendable {
    public var labels: [Int: [Int: String]]

    public init(labels: [Int: [Int: String]]) {
        self.labels = labels
    }

    public func label(set: Int, variant: Int) -> String? {
        labels[set]?[variant]
    }

    /// Parses the raw v2 categories response.
    public static func parse(categoriesJSON data: Data) throws -> DepopSizeTable {
        struct Response: Decodable {
            struct VariantSet: Decodable {
                struct Variant: Decodable {
                    var variantId: Int
                    var text: String
                }
                var id: Int
                var variant: [Variant]?
            }
            var variantSet: [VariantSet]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        var labels: [Int: [Int: String]] = [:]
        for set in response.variantSet {
            var map: [Int: String] = [:]
            for variant in set.variant ?? [] { map[variant.variantId] = variant.text }
            labels[set.id] = map
        }
        return DepopSizeTable(labels: labels)
    }
}

/// A Depop listing ready to send to `/check-listing`.
public struct DepopListing: Equatable, Sendable {
    public var productID: Int?
    public var slug: String
    /// `https://www.depop.com/products/<slug>/`
    public var canonicalURL: URL
    public var facts: CheckListingRequest.Facts
    /// P0 (1280px) photo URLs, at most `DepopListingMapper.maxImages`.
    public var imageURLs: [URL]
    public var seller: CheckListingRequest.Seller?
    /// quantity 0 or not active: the buyer should know before they offer.
    public var isSold: Bool
    /// Full Depop description; sent as `description` (capped client-side).
    public var description: String? = nil

    public func checkListingRequest(userContext: String?) -> CheckListingRequest {
        CheckListingRequest(
            facts: facts,
            imageUrls: imageURLs.map(\.absoluteString),
            userContext: userContext,
            listingUrl: canonicalURL.absoluteString,
            marketplace: "depop",
            seller: seller,
            description: description
        )
    }
}

/// Pure mapping from the Depop product JSON to Cleared's seed facts.
public enum DepopListingMapper {
    /// `/check-listing` fetches at most 8 image URLs.
    public static let maxImages = 8
    static let titleMaxLength = 120

    public static func canonicalURL(slug: String) -> URL? {
        guard DepopLink.isValidSlug(slug) else { return nil }
        return URL(string: "https://www.depop.com/products/\(slug)/")
    }

    public static func listing(from product: DepopProduct, sizes: DepopSizeTable?) -> DepopListing? {
        guard let slug = product.slug, let canonical = canonicalURL(slug: slug) else { return nil }

        let price = (product.prices?.currentPrice?.price ?? product.priceAmount)
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }

        let facts = CheckListingRequest.Facts(
            brand: product.brand.flatMap(brandName),
            modelOrName: title(from: product.description),
            category: category(group: product.group, productType: product.productType),
            size: sizeLabel(product: product, sizes: sizes),
            listedCondition: product.condition.flatMap(conditionLabel),
            askingPrice: price,
            currency: product.priceCurrency?.uppercased() ?? "USD",
            photoObservations: []
        )

        let images = (product.picturesData ?? [])
            .compactMap { $0.formats?["P0"]?.url ?? $0.formats?["P8"]?.url }
            .compactMap(URL.init(string:))
            .filter { $0.scheme == "https" }
        let seller = product.userData?.username.flatMap { name -> CheckListingRequest.Seller? in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
            return .init(username: trimmed, profileUrl: "https://www.depop.com/\(encoded)/")
        }
        let isSold = product.quantity == 0
            || (product.activeStatus.map { $0.lowercased() != "active" } ?? false)

        return DepopListing(
            productID: product.id,
            slug: slug,
            canonicalURL: canonical,
            facts: facts,
            imageURLs: Array(images.prefix(maxImages)),
            seller: seller,
            isSold: isSold,
            description: product.description
        )
    }

    /// Depop has no title field; sellers put one on the first line of the
    /// description (the website and the Chrome extension do the same).
    static func title(from description: String?) -> String? {
        guard let description else { return nil }
        let firstLine = description
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let firstLine else { return nil }
        if firstLine.count <= titleMaxLength { return firstLine }
        return String(firstLine.prefix(titleMaxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The listing labels Depop shows in the app and on the web.
    static func conditionLabel(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "brand_new": return "Brand new"
        case "used_like_new": return "Like new"
        case "used_excellent": return "Used - Excellent"
        case "used_good": return "Used - Good"
        case "used_fair": return "Used - Fair"
        case "": return nil
        default: return humanize(raw)
        }
    }

    /// Brand slugs → display names: `levi-s` → `Levi's`, `ralph-lauren` →
    /// `Ralph Lauren`, `sega` → `Sega`. A best-effort seed only; the model
    /// corrects it from the photos and the description's first line.
    static func brandName(_ slug: String) -> String? {
        let trimmed = slug.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed == trimmed.lowercased(), !trimmed.contains(" ") else { return trimmed }
        let possessive = trimmed.replacingOccurrences(
            of: "-s(?=-|$)", with: "'s", options: .regularExpression
        )
        return possessive.split(separator: "-").map { word -> String in
            guard let first = word.first else { return "" }
            return first.uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    /// `product_type` (`jeans`, `puzzles-games`) is the specific category;
    /// `group` (`bottoms`, `toys`) is the fallback.
    static func category(group: String?, productType: String?) -> String? {
        for raw in [productType, group] {
            if let raw, let value = humanize(raw) { return value }
        }
        return nil
    }

    /// Size labels for every in-listing variant, e.g. `32"` or `S, M`.
    static func sizeLabel(product: DepopProduct, sizes: DepopSizeTable?) -> String? {
        guard let set = product.variantSet, let sizes, let variants = product.variants,
              !variants.isEmpty else { return nil }
        let labels = variants.keys
            .compactMap(Int.init)
            .sorted()
            .compactMap { sizes.label(set: set, variant: $0) }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    static func humanize(_ raw: String) -> String? {
        let words = raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? nil : words
    }
}
