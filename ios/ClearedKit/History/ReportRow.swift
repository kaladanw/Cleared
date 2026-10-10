import Foundation

/// One saved check from `GET /api/reports` (contract §3, owner view).
/// Decoding is lenient: unknown fields are ignored (additive-only contract)
/// and a `report_json` that no longer matches `CheckReport` doesn't drop the
/// whole row, it just can't be opened.
public struct ReportRow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var listingURL: String
    public var listingName: String?
    public var marketplace: String
    public var verdict: Recommendation?
    /// ISO 8601 from the server, e.g. `2026-10-07T16:24:00.123456+00:00`.
    public var checkedAt: String
    public var report: CheckReport?
    public var hubStatus: String?
    public var notes: String
    public var tags: [String]
    public var sellerUsername: String?
    public var shareToken: String?
    public var canRecheck: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case listingURL = "listingUrl"
        case listingName, marketplace, verdict, checkedAt
        case report = "reportJson"
        case hubStatus, notes, tags, sellerUsername, shareToken, canRecheck
    }

    public init(
        id: String, listingURL: String = "", listingName: String? = nil, marketplace: String = "depop",
        verdict: Recommendation? = nil, checkedAt: String, report: CheckReport? = nil,
        hubStatus: String? = nil, notes: String = "", tags: [String] = [],
        sellerUsername: String? = nil, shareToken: String? = nil, canRecheck: Bool = false
    ) {
        self.id = id
        self.listingURL = listingURL
        self.listingName = listingName
        self.marketplace = marketplace
        self.verdict = verdict
        self.checkedAt = checkedAt
        self.report = report
        self.hubStatus = hubStatus
        self.notes = notes
        self.tags = tags
        self.sellerUsername = sellerUsername
        self.shareToken = shareToken
        self.canRecheck = canRecheck
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        listingURL = (try? c.decodeIfPresent(String.self, forKey: .listingURL)) ?? ""
        listingName = try? c.decodeIfPresent(String.self, forKey: .listingName)
        marketplace = (try? c.decodeIfPresent(String.self, forKey: .marketplace)) ?? "depop"
        verdict = try? c.decodeIfPresent(Recommendation.self, forKey: .verdict)
        checkedAt = (try? c.decodeIfPresent(String.self, forKey: .checkedAt)) ?? ""
        report = try? c.decodeIfPresent(CheckReport.self, forKey: .report)
        hubStatus = try? c.decodeIfPresent(String.self, forKey: .hubStatus)
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        sellerUsername = try? c.decodeIfPresent(String.self, forKey: .sellerUsername)
        shareToken = try? c.decodeIfPresent(String.self, forKey: .shareToken)
        canRecheck = (try? c.decodeIfPresent(Bool.self, forKey: .canRecheck)) ?? false
    }

    public var checkedDate: Date? { ISO8601Parsing.date(from: checkedAt) }

    /// Title for a list row: listing name, then the report's own read.
    public var displayTitle: String {
        if let listingName, !listingName.isEmpty { return listingName }
        if let name = report?.listingFacts.modelOrName, !name.isEmpty { return name }
        if let brand = report?.listingFacts.brand, !brand.isEmpty { return brand }
        return "Listing check"
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// Server timestamps carry microseconds (`.123456`), which
/// `ISO8601DateFormatter` can't parse with or without fractional seconds, so
/// trim the fraction to milliseconds first.
enum ISO8601Parsing {
    static func date(from raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        if let date = plain.date(from: raw) ?? withFraction.date(from: raw) { return date }
        // 2026-10-07T16:24:00.123456+00:00 → 2026-10-07T16:24:00.123+00:00
        guard let dot = raw.firstIndex(of: ".") else { return nil }
        let afterDot = raw[raw.index(after: dot)...]
        let digits = afterDot.prefix { $0.isNumber }
        let rest = afterDot.dropFirst(digits.count)
        let millis = String(String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0))
        let trimmed = String(raw[..<dot]) + "." + millis + String(rest)
        return withFraction.date(from: String(trimmed))
    }
}
