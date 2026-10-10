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
///
/// Auth: the extension reuses the app's session from the shared Keychain item
/// (`SessionManager`); it never shows a login form. No session → "Open
/// Cleared to sign in", except a dev build with the legacy shared token can
/// still run an unsaved screenshot check.
@MainActor
final class CheckSession: ObservableObject {
    enum Phase {
        case ingesting
        case fetchingListing
        case composing
        case checking
        case finished(CheckReport)
        case failed(String)
        /// No shared session (never signed in, or the server ended it).
        case signInRequired
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

    static let screenshotsAsk =
        "Take screenshots of the listing (photos, price, and description) and share them to Cleared instead."

    /// The app's session, shared through the Keychain access group and
    /// refreshed under the App Group file lock. nil if this build can't share
    /// a session (missing entitlement or backend URL); see `setupError`.
    private let sessions: SessionManager?
    private let setupError: String?

    private lazy var fetcher = DepopListingFetcher(cacheDirectory: ClearedConfig.appGroupContainer)

    init() {
        do {
            sessions = try ClearedAuth.makeSessionManager()
            setupError = nil
        } catch {
            sessions = nil
            setupError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var isSignedIn: Bool { sessions?.currentSession() != nil }

    func ingest(from context: NSExtensionContext?) async {
        let payload = await ShareIngest.load(from: context)
        images = payload.images

        if !isSignedIn {
            // Legacy unsaved screenshot check, only in builds that still carry
            // the shared token. Link shares need Bearer (/check-listing).
            guard !images.isEmpty, ClearedConfig.sharedToken != nil else {
                // A build that can't share a session at all gets the real
                // reason, not a sign-in prompt the app couldn't satisfy.
                phase = setupError.map(Phase.failed) ?? .signInRequired
                return
            }
            listingNotice = "You're not signed in, so this check won't be saved to your history. Open Cleared to sign in."
            phase = .composing
            return
        }

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
        guard let client = ClearedAPIClient.fromConfig(accessTokenProvider: sessions) else {
            phase = .failed(setupError ?? ClearedAPIError.notConfigured.errorDescription ?? "Not configured.")
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
            } catch ClearedAPIError.signInRequired {
                // Signed out by the server mid-flow (refresh 401 / second 401).
                phase = .signInRequired
                return
            } catch {
                let reason = message(for: error)
                guard !images.isEmpty else {
                    phase = .failed(reason)
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
        } catch ClearedAPIError.signInRequired {
            phase = .signInRequired
        } catch {
            phase = .failed(message(for: error))
        }
    }

    private func finish(with report: CheckReport) {
        // A report is useful in the host app after the share sheet closes.
        // Persistence failure must never hide a valid result from the user.
        // The app replaces this from GET /api/reports next time it opens.
        try? ReportHistoryStore.shared()?.record(report, listingURL: canonicalListingURL)
        phase = .finished(report)
    }

    private func message(for error: Error) -> String {
        if let apiError = error as? ClearedAPIError {
            return apiError.errorDescription ?? "Something went wrong."
        }
        // AuthError (refresh 503 / offline) and FileLock errors carry their own text.
        if let described = (error as? LocalizedError)?.errorDescription {
            return described
        }
        return "Network problem: \(error.localizedDescription)"
    }
}
