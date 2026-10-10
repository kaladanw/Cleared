import SwiftUI
import UIKit

/// State machine for the extension:
/// ingest → (fetch Depop listing) → compose → checking → report/failed.
///
/// Two inputs, one result:
/// - **Depop link** (Depop's Share button, Safari): fetch the listing on the
///   phone, then `POST /check-listing` (Bearer). Saved to history.
/// - **Screenshots** (Photos): `POST /check` (multipart), as before.
/// If the link path fails and screenshots were shared too, fall back to them;
/// if there are no screenshots, say so honestly and ask for them.
@MainActor
final class CheckSession: ObservableObject {
    enum Phase {
        case ingesting
        case fetchingListing
        case composing
        case checking
        case finished(CheckReport)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .ingesting
    @Published var userContext = ""
    @Published private(set) var images: [UIImage] = []
    /// The fetched Depop listing, when a link was shared and the fetch worked.
    @Published private(set) var listing: DepopListing?
    /// Why the listing couldn't be used, shown above the screenshot fallback.
    @Published private(set) var listingNotice: String?

    /// Canonical listing URL, known once a short link resolves; attached to a
    /// screenshot fallback so the report still lands on the right listing.
    private var canonicalListingURL: URL?

    private static let appGroup = "group.com.kaladanw.cleared"
    static let screenshotsAsk =
        "Take screenshots of the listing (photos, price, and description) and share them to Cleared instead."

    /// TODO(iOS auth PR): pass the shared-Keychain session provider here.
    /// Until then there is no Bearer token, so `/check-listing` reports
    /// `.signInRequired` and link shares fall back to screenshots.
    private let accessTokenProvider: AccessTokenProvider? = nil

    private lazy var fetcher = DepopListingFetcher(
        cacheDirectory: FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)
    )

    func ingest(from context: NSExtensionContext?) async {
        let payload = await ShareIngest.load(from: context)
        images = payload.images

        guard let link = payload.depopLink else {
            phase = images.isEmpty
                ? .failed("Nothing to check. Share a Depop listing from the Depop app, or share screenshots of it.")
                : .composing
            return
        }

        if case .product(let slug) = link {
            canonicalListingURL = DepopListingMapper.canonicalURL(slug: slug)
        }
        phase = .fetchingListing
        do {
            let fetched = try await fetcher.fetchListing(for: link)
            listing = fetched
            canonicalListingURL = fetched.canonicalURL
            phase = .composing
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if images.isEmpty {
                phase = .failed("\(reason)\n\n\(Self.screenshotsAsk)")
            } else {
                listingNotice = "\(reason) Using your screenshots instead."
                phase = .composing
            }
        }
    }

    func runCheck() async {
        guard let client = ClearedAPIClient.fromConfig(accessTokenProvider: accessTokenProvider) else {
            phase = .failed(ClearedAPIError.notConfigured.errorDescription ?? "Not configured.")
            return
        }
        phase = .checking
        let trimmed = userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = trimmed.isEmpty ? nil : trimmed

        if let listing {
            do {
                let report = try await client.checkListing(
                    listing.checkListingRequest(userContext: context)
                )
                finish(with: report)
                return
            } catch {
                let reason = message(for: error)
                guard !images.isEmpty else {
                    phase = .failed(
                        error as? ClearedAPIError == .signInRequired
                            ? "\(reason)\n\n\(Self.screenshotsAsk)"
                            : reason
                    )
                    return
                }
                // Fall through to the screenshot path with what the user shared.
                listingNotice = "\(reason) Used your screenshots instead."
            }
        }

        await runScreenshotCheck(client: client, userContext: context)
    }

    private func runScreenshotCheck(client: ClearedAPIClient, userContext: String?) async {
        let payloads = images.compactMap { $0.downscaledJPEG() }
        guard !payloads.isEmpty else {
            phase = .failed(images.isEmpty
                ? "No screenshots to check. \(Self.screenshotsAsk)"
                : "Couldn't read the shared images.")
            return
        }
        do {
            let report = try await client.check(
                images: payloads,
                userContext: userContext,
                listingURL: canonicalListingURL,
                marketplace: canonicalListingURL == nil ? nil : "depop"
            )
            finish(with: report)
        } catch {
            phase = .failed(message(for: error))
        }
    }

    private func finish(with report: CheckReport) {
        // A report is useful in the host app after the share sheet closes.
        // Persistence failure must never hide a valid result from the user.
        try? LastReportStore.save(report)
        phase = .finished(report)
    }

    private func message(for error: Error) -> String {
        if let apiError = error as? ClearedAPIError {
            return apiError.errorDescription ?? "Something went wrong."
        }
        return "Network problem: \(error.localizedDescription)"
    }
}
