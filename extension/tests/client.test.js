const assert = require("node:assert/strict");
const { describe, it } = require("node:test");

const {
  DEFAULT_BACKEND,
  DEFAULT_MARKETPLACE,
  buildCheckListingRequest,
  postCheckListing,
  getCachedReport,
} = require("../src/client.js");

const RAILWAY_BACKEND = "https://cleared-backend-production.up.railway.app";

describe("client", () => {
  it("builds the /check-listing request body from listing, context, URL, and marketplace", () => {
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
      marketplace: "depop",
      seller: null,
    });
    assert.equal(DEFAULT_MARKETPLACE, "depop");
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
        marketplace: "depop",
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
        marketplace: "depop",
        seller: null,
      }),
    );
  });

  it("uses Railway by default and accepts a localhost base override", async () => {
    assert.equal(DEFAULT_BACKEND, RAILWAY_BACKEND);
    const calls = [];
    const fetchImpl = async (url) => {
      calls.push(url);
      return { ok: true, json: async () => ({}) };
    };

    await postCheckListing({ facts: {}, image_urls: [] }, { fetchImpl });
    await postCheckListing(
      { facts: {}, image_urls: [] },
      { backendUrl: "http://localhost:8000", fetchImpl },
    );

    assert.deepEqual(calls, [
      RAILWAY_BACKEND + "/check-listing",
      "http://localhost:8000/check-listing",
    ]);
  });

  it("forwards extracted seller identity in the request body", () => {
    const body = buildCheckListingRequest(
      {
        facts: {},
        image_urls: [],
        seller: { username: "vintage.finds", profile_url: "https://www.depop.com/vintage.finds/" },
      },
      null,
      "https://www.depop.com/products/x/",
    );
    assert.deepEqual(body.seller, {
      username: "vintage.finds",
      profile_url: "https://www.depop.com/vintage.finds/",
    });
  });

  it("sends the extracted description top-level, trimmed and capped", () => {
    const body = buildCheckListingRequest(
      { facts: { brand: "Levi's" }, image_urls: [], description: "  W29 L32. Small mark on knee.\n " },
      null,
      "https://www.depop.com/products/x/",
    );
    assert.equal(body.description, "W29 L32. Small mark on knee.");
    assert.equal(body.facts.description, undefined);
    assert.deepEqual(Object.keys(body), [
      "facts", "image_urls", "user_context", "listing_url", "marketplace", "seller", "description",
    ]);

    const long = buildCheckListingRequest({ facts: {}, image_urls: [], description: "x".repeat(9000) }, null, null);
    assert.equal(long.description.length, 5000);
  });

  it("omits description when blank or missing (backward compatible body)", () => {
    for (const description of [undefined, null, "", "   \n\t", 42]) {
      const body = buildCheckListingRequest({ facts: {}, image_urls: [], description }, null, null);
      assert.equal("description" in body, false, String(description));
    }
  });

  it("posts the description from an extracted listing", async () => {
    const { extractListingFromNextDataJson } = require("../src/extractor.js");
    const listing = extractListingFromNextDataJson(JSON.stringify({
      props: { pageProps: { product: {
        brandName: "Levi's",
        title: "Levi's 505",
        price: "40.00",
        currencyName: "USD",
        description: "Levi's 505 W29 L32. Pit to pit 21in.",
        pictures: [{ url: "https://media-photos.depop.com/b1/1/P0.jpg" }],
      } } },
    }));
    let sent;
    await postCheckListing(listing, {
      token: "jwt",
      fetchImpl: async (_url, options) => {
        sent = JSON.parse(options.body);
        return { ok: true, json: async () => ({}) };
      },
    });
    assert.equal(sent.description, "Levi's 505 W29 L32. Pit to pit 21in.");
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
      RAILWAY_BACKEND + "/reports?url=" +
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
