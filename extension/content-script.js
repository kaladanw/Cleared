(function initClearedContentScript() {
  const extractor = globalThis.ClearedExtractor;
  if (!extractor) {
    console.warn("[Cleared] extractor unavailable");
    return;
  }

  const listing = extractor.extractListingFromDocument(document);
  if (!listing.image_urls.length) {
    console.warn("[Cleared] no Depop product data found on this page");
    return;
  }

  console.log("[Cleared] extracted Depop listing", listing);
})();
