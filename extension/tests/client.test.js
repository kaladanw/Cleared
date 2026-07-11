const assert = require("node:assert/strict");
const { describe, it } = require("node:test");

const {
  buildCheckListingRequest,
  postCheckListing,
  getCachedReport,
} = require("../src/client.js");

describe("client", () => {
  it("builds the /check-listing request body from listing, context, and URL", () => {
    const body = buildCheckListingRequest(
      {
        facts: { brand: "Uniqlo", asking_price: 18 },
        image_urls: ["https://media-photos.depop.com/item.jpg"],
      },
      "gift",
      "https://www.depop.com/products/some-item/",
    );

    assert.deepEqual(body, {
      facts: { brand: "Uniqlo", asking_price: 18 },
      image_urls: ["https://media-photos.depop.com/item.jpg"],
      user_context: "gift",
      listing_url: "https://www.depop.com/products/some-item/",
    });
  });

  it("posts JSON to the backend with a Bearer token when provided", async () => {
    const calls = [];
    const fakeFetch = async (url, options) => {
      calls.push({ url, options });
      return {
        ok: true,
        json: async () => ({ verdict: { recommendation: "buy" } }),
      };
    };

    const report = await postCheckListing(
      {
        facts: { brand: "Uniqlo" },
        image_urls: ["https://media-photos.depop.com/item.jpg"],
      },
      {
        backendUrl: "http://localhost:8000/check-listing",
        token: "jwt-token",
        userContext: "gift",
        listingUrl: "https://www.depop.com/products/some-item/",
        fetchImpl: fakeFetch,
      },
    );

    assert.deepEqual(report, { verdict: { recommendation: "buy" } });
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "http://localhost:8000/check-listing");
    assert.equal(calls[0].options.method, "POST");
    assert.equal(calls[0].options.headers["Content-Type"], "application/json");
    assert.equal(calls[0].options.headers["Authorization"], "Bearer jwt-token");
    assert.equal(
      calls[0].options.body,
      JSON.stringify({
        facts: { brand: "Uniqlo" },
        image_urls: ["https://media-photos.depop.com/item.jpg"],
        user_context: "gift",
        listing_url: "https://www.depop.com/products/some-item/",
      }),
    );
  });

  it("throws a clear error when the backend returns a non-2xx response", async () => {
    const fakeFetch = async () => ({
      ok: false,
      status: 401,
      text: async () => "nope",
    });

    await assert.rejects(
      () => postCheckListing({ facts: {}, image_urls: [] }, { fetchImpl: fakeFetch }),
      /Backend returned 401/,
    );
  });

  it("fetches a cached report with the Bearer token, null without one", async () => {
    const calls = [];
    const fakeFetch = async (url, options) => {
      calls.push({ url, options });
      return {
        ok: true,
        json: async () => ({ report_json: { verdict: { recommendation: "skip" } } }),
      };
    };

    const row = await getCachedReport("https://www.depop.com/products/some-item/", {
      token: "jwt-token",
      fetchImpl: fakeFetch,
    });

    assert.equal(calls.length, 1);
    assert.equal(
      calls[0].url,
      "http://localhost:8000/reports?url=" +
        encodeURIComponent("https://www.depop.com/products/some-item/"),
    );
    assert.equal(calls[0].options.headers["Authorization"], "Bearer jwt-token");
    assert.deepEqual(row, { report_json: { verdict: { recommendation: "skip" } } });

    const noToken = await getCachedReport("https://www.depop.com/x/", {
      fetchImpl: fakeFetch,
    });
    assert.equal(noToken, null);
    assert.equal(calls.length, 1, "no request is made without a token");
  });
});
