import Foundation

/// A Depop listing link pulled out of whatever the share sheet handed us.
///
/// Depop's own Share button sends text like
/// `"Look what I just found on Depop 👀\n\nhttps://depop.app.link/<code>"`
/// (a Branch short link). Safari/Chrome shares send the product page URL
/// directly. Both are accepted; anything else (shop links, other sites) is not.
public enum DepopLink: Equatable, Sendable {
    /// `https://depop.app.link/<code>`. Must be resolved (see `DepopListingFetcher`).
    case shortLink(URL)
    /// `https://(www.)depop.com/products/<slug>/`. The slug is already known.
    case product(slug: String)

    /// Hosts the Branch short links use. `depop.app.link` is what the app sends;
    /// the `-alternate` host is Branch's fallback domain for the same links.
    static let shortLinkHosts: Set<String> = ["depop.app.link", "depop-alternate.app.link"]
    static let productHosts: Set<String> = ["depop.com", "www.depop.com"]

    /// Depop slugs are lowercase words joined by `-`, with `_`/`.` allowed from
    /// the seller's username prefix. Kept permissive but path-safe.
    static let slugPattern = "[A-Za-z0-9][A-Za-z0-9._-]{0,199}"

    /// Classifies a single URL. Returns nil for anything that isn't a Depop
    /// listing (other hosts, shop pages, the Depop home page, non-http schemes).
    public static func from(url: URL) -> DepopLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }

        if shortLinkHosts.contains(host) {
            let code = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !code.isEmpty, !code.contains("/"),
                  code.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
            else { return nil }
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = "/" + code
            return components.url.map { .shortLink($0) }
        }

        if productHosts.contains(host) {
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 2, parts[0] == "products",
                  isValidSlug(parts[1]) else { return nil }
            return .product(slug: parts[1])
        }
        return nil
    }

    /// The first Depop listing link in free text (the share-sheet message).
    public static func firstLink(in text: String) -> DepopLink? {
        for url in candidateURLs(in: text) {
            if let link = from(url: url) { return link }
        }
        return nil
    }

    /// The first Depop listing link across everything shared: URL items first
    /// (they are exact), then text items.
    public static func firstLink(urls: [URL], texts: [String]) -> DepopLink? {
        for url in urls {
            if let link = from(url: url) { return link }
        }
        for text in texts {
            if let link = firstLink(in: text) { return link }
        }
        return nil
    }

    static func isValidSlug(_ slug: String) -> Bool {
        slug.range(of: "^\(slugPattern)$", options: .regularExpression) != nil
    }

    /// Every link in `text`, in order. On Apple platforms this is
    /// `NSDataDetector` (handles trailing punctuation, emoji, line breaks).
    /// swift-corelibs-foundation doesn't implement `NSDataDetector`, so the
    /// Linux build (used only to run these tests off-device) scans with a regex.
    static func candidateURLs(in text: String) -> [URL] {
        #if canImport(Darwin)
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range).compactMap { $0.url }
        #else
        return regexCandidateURLs(in: text)
        #endif
    }

    /// Fallback scanner: bare `host/path` and `http(s)://` links, with common
    /// trailing punctuation trimmed. Internal so tests can exercise it on Apple
    /// platforms too.
    static func regexCandidateURLs(in text: String) -> [URL] {
        let pattern = #"(?i)\b(?:https?://)?(?:www\.)?(?:depop(?:-alternate)?\.app\.link|depop\.com)/[^\s<>"'()\[\]{}]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            var raw = ns.substring(with: match.range)
            while let last = raw.last, ".,;:!?".contains(last) { raw.removeLast() }
            if !raw.lowercased().hasPrefix("http") { raw = "https://" + raw }
            return URL(string: raw)
        }
    }
}
