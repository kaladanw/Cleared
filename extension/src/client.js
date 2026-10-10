(function init(root) {
  const DEFAULT_BACKEND = "https://cleared-backend-production.up.railway.app";
  const DEFAULT_BACKEND_URL = DEFAULT_BACKEND + "/check-listing";
  // Current marketplace for this content-script host. New marketplaces need their
  // own content_scripts match + extractor + marketplace id (see extension/README.md).
  const DEFAULT_MARKETPLACE = "depop";

  const DESCRIPTION_MAX = 5000;

  /** Trim and cap the seller's description; null when blank (then omitted). */
  function normalizeDescription(value) {
    if (typeof value !== "string") return null;
    const text = value.trim();
    if (!text) return null;
    return text.slice(0, DESCRIPTION_MAX).trimEnd();
  }

  function buildCheckListingRequest(listing, userContext, listingUrl, marketplace) {
    const body = {
      facts: listing.facts || {},
      image_urls: listing.image_urls || [],
      user_context: userContext || null,
      listing_url: listingUrl || null,
      marketplace: marketplace || DEFAULT_MARKETPLACE,
      // Best-effort { username, profile_url } from the extractor; null if unknown.
      seller: listing.seller || null,
    };
    // Top-level (not inside facts), same as iOS; omitted when blank.
    const description = normalizeDescription(listing.description);
    if (description) body.description = description;
    return body;
  }

  /**
   * POST /check-listing — fetch CDN images + run the Claude check.
   *
   * options:
   *   token       {string}  — JWT (Authorization: Bearer). Required.
   *   userContext {string}  — buyer's free-text context.
   *   listingUrl  {string}  — window.location.href, used for history storage.
   *   marketplace {string}  — marketplace slug (default "depop").
   *   backendUrl  {string}  — override backend URL (defaults to DEFAULT_BACKEND_URL).
   *   fetchImpl   {function} — injectable fetch for tests.
   */
  async function postCheckListing(listing, options = {}) {
    const fetchImpl = options.fetchImpl || root.fetch;
    if (!fetchImpl) {
      throw new Error("Fetch is unavailable in this browser context.");
    }

    const headers = { "Content-Type": "application/json" };
    if (options.token) {
      headers["Authorization"] = "Bearer " + options.token;
    }

    const body = buildCheckListingRequest(
      listing,
      options.userContext,
      options.listingUrl,
      options.marketplace || DEFAULT_MARKETPLACE,
    );

    const backend = options.backendUrl || DEFAULT_BACKEND;
    const endpoint = backend.endsWith("/check-listing")
      ? backend
      : backend.replace(/\/$/, "") + "/check-listing";
    const response = await fetchImpl(endpoint, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });

    if (!response.ok) {
      const detail = response.text ? await response.text() : "";
      throw new Error(`Backend returned ${response.status}${detail ? `: ${detail}` : ""}`);
    }

    return response.json();
  }

  /**
   * GET /reports?url=<listingUrl> — retrieve the most recent cached report.
   *
   * Returns the report row (containing .report_json) or null if none.
   */
  async function getCachedReport(listingUrl, options = {}) {
    const fetchImpl = options.fetchImpl || root.fetch;
    const base = options.backendUrl || DEFAULT_BACKEND;
    const token = options.token;
    if (!token) return null;

    try {
      const resp = await fetchImpl(
        base + "/reports?url=" + encodeURIComponent(listingUrl),
        { headers: { "Authorization": "Bearer " + token } },
      );
      if (!resp.ok) return null;
      return resp.json();
    } catch {
      return null;
    }
  }

  const api = {
    DEFAULT_BACKEND,
    DEFAULT_BACKEND_URL,
    DEFAULT_MARKETPLACE,
    buildCheckListingRequest,
    postCheckListing,
    getCachedReport,
  };

  root.ClearedClient = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : window);
