(function init(root) {
  const DEFAULT_BACKEND = "https://cleared-backend-production.up.railway.app";
  const DEFAULT_BACKEND_URL = DEFAULT_BACKEND + "/check-listing";

  function buildCheckListingRequest(listing, userContext, listingUrl) {
    return {
      facts: listing.facts || {},
      image_urls: listing.image_urls || [],
      user_context: userContext || null,
      listing_url: listingUrl || null,
    };
  }

  /**
   * POST /check-listing — fetch CDN images + run the Claude check.
   *
   * options:
   *   token       {string}  — JWT (Authorization: Bearer). Required.
   *   userContext {string}  — buyer's free-text context.
   *   listingUrl  {string}  — window.location.href, used for history storage.
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
    buildCheckListingRequest,
    postCheckListing,
    getCachedReport,
  };

  root.ClearedClient = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : window);
