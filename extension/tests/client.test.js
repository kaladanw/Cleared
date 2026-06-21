const assert = require("node:assert/strict");
const { describe, it } = require("node:test");

const {
  buildCheckListingRequest,
  postCheckListing,
} = require("../src/client.js");

describe("client", () => {
  it("builds the /check-listing request body from listing and context", () => {
    const body = buildCheckListingRequest(
      {
        facts: { brand: "Uniqlo", asking_price: 18 },
        image_urls: ["https://media-photos.depop.com/item.jpg"],
      },
      "gift",
    );

    assert.deepEqual(body, {
      facts: { brand: "Uniqlo", asking_price: 18 },
      image_urls: ["https://media-photos.depop.com/item.jpg"],
      user_context: "gift",
    });
  });

  it("posts JSON to the backend and includes the shared token when provided", async () => {
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
        token: "secret",
        userContext: "gift",
        fetchImpl: fakeFetch,
      },
    );

    assert.deepEqual(report, { verdict: { recommendation: "buy" } });
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "http://localhost:8000/check-listing");
    assert.equal(calls[0].options.method, "POST");
    assert.equal(calls[0].options.headers["Content-Type"], "application/json");
    assert.equal(calls[0].options.headers["X-Cleared-Token"], "secret");
    assert.equal(
      calls[0].options.body,
      JSON.stringify({
        facts: { brand: "Uniqlo" },
        image_urls: ["https://media-photos.depop.com/item.jpg"],
        user_context: "gift",
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
});
