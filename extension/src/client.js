(function init(root) {
  const DEFAULT_BACKEND_URL = "http://localhost:8000/check-listing";

  function buildCheckListingRequest(listing, userContext) {
    return {
      facts: listing.facts || {},
      image_urls: listing.image_urls || [],
      user_context: userContext || null,
    };
  }

  async function postCheckListing(listing, options = {}) {
    const fetchImpl = options.fetchImpl || root.fetch;
    if (!fetchImpl) {
      throw new Error("Fetch is unavailable in this browser context.");
    }

    const headers = {
      "Content-Type": "application/json",
    };
    if (options.token) {
      headers["X-Cleared-Token"] = options.token;
    }

    const response = await fetchImpl(options.backendUrl || DEFAULT_BACKEND_URL, {
      method: "POST",
      headers,
      body: JSON.stringify(buildCheckListingRequest(listing, options.userContext)),
    });

    if (!response.ok) {
      const detail = response.text ? await response.text() : "";
      throw new Error(`Backend returned ${response.status}${detail ? `: ${detail}` : ""}`);
    }

    return response.json();
  }

  const api = {
    DEFAULT_BACKEND_URL,
    buildCheckListingRequest,
    postCheckListing,
  };

  root.ClearedClient = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : window);
