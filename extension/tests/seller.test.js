const assert = require("node:assert/strict");
const { describe, it } = require("node:test");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");

const {
  extractSellerFromHtml,
  extractListingFromDocument,
} = require("../src/extractor.js");

const fixture = (name) => readFileSync(join(__dirname, "fixtures", name), "utf8");

describe("extractSellerFromHtml (Depop fixtures)", () => {
  it("reads ld+json offers.seller and ignores the buyer's header profile link", () => {
    assert.deepEqual(extractSellerFromHtml(fixture("seller-ldjson.html")), {
      username: "vintage.finds",
      profile_url: "https://www.depop.com/vintage.finds/",
    });
  });

  it("falls back to __NEXT_DATA__ seller.username and lowercases it", () => {
    assert.deepEqual(extractSellerFromHtml(fixture("seller-nextdata.html")), {
      username: "retrorack",
      profile_url: "https://www.depop.com/retrorack/",
    });
  });

  it("falls back to a seller data-testid anchor, not the navigation profile link", () => {
    assert.deepEqual(extractSellerFromHtml(fixture("seller-anchor.html")), {
      username: "thrift_queen",
      profile_url: "https://www.depop.com/thrift_queen/",
    });
  });

  it("returns null when no seller source exists (buyer link alone is not a seller)", () => {
    assert.equal(extractSellerFromHtml(fixture("seller-none.html")), null);
  });

  it("rejects reserved paths and falls back to the anchor text", () => {
    const html = '<a data-testid="bio__username" href="/products/abc/">@Some.User</a>';
    assert.deepEqual(extractSellerFromHtml(html), {
      username: "some.user",
      profile_url: "https://www.depop.com/some.user/",
    });
  });

  it("is null-safe for empty, malformed, or non-string input", () => {
    assert.equal(extractSellerFromHtml(""), null);
    assert.equal(extractSellerFromHtml(null), null);
    assert.equal(
      extractSellerFromHtml('<script type="application/ld+json">{not json</script>'),
      null,
    );
    assert.equal(
      extractSellerFromHtml('<a data-testid="bio__username" href="/x/y/">has spaces in it</a>'),
      null,
    );
  });
});

describe("extractListingFromDocument seller wiring", () => {
  it("attaches seller to the listing using the document HTML", () => {
    const html = fixture("seller-ldjson.html");
    const ldText = /<script type="application\/ld\+json">([\s\S]*?)<\/script>/.exec(html)[1];
    const doc = {
      documentElement: { outerHTML: html },
      querySelector: (sel) =>
        sel === 'script[type="application/ld+json"]' ? { textContent: ldText } : null,
    };
    const listing = extractListingFromDocument(doc);
    assert.equal(listing.facts.brand, "Ralph Lauren");
    assert.deepEqual(listing.image_urls, ["https://media-photos.depop.com/b1/P0.jpg"]);
    assert.deepEqual(listing.seller, {
      username: "vintage.finds",
      profile_url: "https://www.depop.com/vintage.finds/",
    });
  });

  it("sets seller to null when the page has none", () => {
    const doc = { documentElement: { outerHTML: "<html></html>" }, querySelector: () => null };
    assert.equal(extractListingFromDocument(doc).seller, null);
  });
});
