import Foundation

/// Swift mirror of `backend/app/models.py` — that file is the source of truth.
/// JSON is snake_case; decode with `CheckReport.decoder()`. Nullable fields stay
/// optional here so the UI can render "couldn't verify" honestly, never 0.

public enum PriceFairness: String, Codable, Sendable {
    case steal, fair, high, overpriced
}

public enum Recommendation: String, Codable, Sendable {
    case buy, negotiate, skip
}

public struct ListingFacts: Codable, Sendable {
    public var brand: String?
    public var modelOrName: String?
    public var category: String?
    public var size: String?
    public var listedCondition: String?
    public var askingPrice: Double?
    public var currency: String
    public var photoObservations: [String]
}

public struct PriceRead: Codable, Sendable {
    public var retailEstimate: Double?
    public var usedEstimateLow: Double?
    public var usedEstimateHigh: Double?
    public var fairness: PriceFairness?
    public var suggestedOfferLow: Double?
    public var suggestedOfferHigh: Double?
    public var reasoning: String
}

public struct ListingTrust: Codable, Sendable {
    public var missingInfo: [String]
    public var concerns: [String]
    public var questionsToAsk: [String]
}

public struct AuthFlag: Codable, Sendable {
    public var applicable: Bool
    public var redFlags: [String]
    public var whatToInspect: [String]
    public var confidence: String?
}

public struct Verdict: Codable, Sendable {
    public var recommendation: Recommendation?
    public var oneLine: String
    public var userContext: String?
}

public struct CheckReport: Codable, Sendable {
    public var listingFacts: ListingFacts
    public var priceRead: PriceRead
    public var listingTrust: ListingTrust
    public var authFlag: AuthFlag
    public var verdict: Verdict
    /// Set when the listing could not be read; render THIS and nothing else.
    public var error: String?

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
