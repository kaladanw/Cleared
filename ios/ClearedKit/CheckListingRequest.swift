import Foundation

/// Body of `POST /check-listing` (JSON). Mirrors `CheckListingRequest` /
/// `ListingFacts` / `SellerInfo` in `backend/app/models.py`; see
/// `docs/api-contract.md` §2. Encode with `CheckListingRequest.encoder()`
/// (snake_case keys; nil fields are omitted so the backend defaults apply).
public struct CheckListingRequest: Encodable, Equatable, Sendable {
    /// Seed facts read off the listing. The backend tells the model to treat
    /// these as ground truth unless the photos clearly contradict them.
    public struct Facts: Encodable, Equatable, Sendable {
        public var brand: String?
        public var modelOrName: String?
        public var category: String?
        public var size: String?
        public var listedCondition: String?
        public var askingPrice: Double?
        public var currency: String
        public var photoObservations: [String]

        public init(
            brand: String? = nil, modelOrName: String? = nil, category: String? = nil,
            size: String? = nil, listedCondition: String? = nil, askingPrice: Double? = nil,
            currency: String = "USD", photoObservations: [String] = []
        ) {
            self.brand = brand
            self.modelOrName = modelOrName
            self.category = category
            self.size = size
            self.listedCondition = listedCondition
            self.askingPrice = askingPrice
            self.currency = currency
            self.photoObservations = photoObservations
        }
    }

    public struct Seller: Encodable, Equatable, Sendable {
        public var username: String
        public var profileUrl: String?

        public init(username: String, profileUrl: String?) {
            self.username = username
            self.profileUrl = profileUrl
        }
    }

    public var facts: Facts
    /// Listing photo URLs; the backend downloads at most 8.
    public var imageUrls: [String]
    public var userContext: String?
    /// Canonical `https://www.depop.com/products/<slug>/` so iOS and extension
    /// checks of the same listing match in the hub.
    public var listingUrl: String?
    public var marketplace: String
    public var seller: Seller?
    /// The seller's full listing description (measurements, flaws, …), trimmed
    /// and capped at `maxDescriptionLength`. Optional; the backend caps it too.
    public var description: String?

    public static let maxDescriptionLength = 5_000

    public init(
        facts: Facts, imageUrls: [String], userContext: String?,
        listingUrl: String?, marketplace: String = "depop", seller: Seller?,
        description: String? = nil
    ) {
        self.facts = facts
        self.imageUrls = imageUrls
        self.userContext = userContext
        self.listingUrl = listingUrl
        self.marketplace = marketplace
        self.seller = seller
        self.description = Self.cappedDescription(description)
    }

    static func cappedDescription(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxDescriptionLength))
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
