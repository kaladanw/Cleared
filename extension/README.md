# Cleared extension

Manifest V3 Chrome extension for the web port.

On Depop product pages, the content script reads listing structured data
(ld+json / `__NEXT_DATA__`), injects a small Cleared panel, POSTs extracted
facts plus image URLs to the deployed Railway backend with
`marketplace: "depop"`, and renders the returned `CheckReport` in-page. Login,
checks, and cached-report reads share the same backend setting. Past checks
appear on the Cleared web hub after the same account signs in there.

## Adding another marketplace (e.g. Vinted)

The hub is marketplace-aware. To plug in a new site:

1. Add `host_permissions` + a `content_scripts` match for that origin in
   `manifest.json`.
2. Add or branch an extractor that returns the same `{ facts, image_urls }`
   shape as `src/extractor.js`.
3. Pass a new marketplace slug into `postCheckListing` (e.g.
   `marketplace: "vinted"`). The backend accepts lowercase slugs matching
   `^[a-z][a-z0-9_-]{0,31}$` and stores them on each report.

No Vinted extractor ships in this folder yet — Depop is the first marketplace.

## Seller capture

`extractListingFromDocument` also returns `seller: { username, profile_url }`
(or `null`), sent as `seller` on `POST /api/check-listing` so the hub can group
checks by seller. `extractSellerFromHtml` tries, in order: ld+json Product
`offers.seller` / `seller` (url → alternateName → name), `__NEXT_DATA__`
(`seller.username`, `seller.url`, `sellerUsername`), then seller-specific
`data-testid` anchors. Reserved Depop paths are rejected, usernames are
lowercased, and `profile_url` is canonicalized to `https://www.depop.com/{username}/`.
There is deliberately **no** generic profile-link fallback (the header links to
the signed-in buyer's own profile).

**Fragile:** Depop serves 403 to datacenter IPs, so these selectors are based on
fixtures (`tests/fixtures/seller-*.html`), not a live page. If Depop changes its
markup the extractor returns `null` and the check still succeeds without seller
data. Verify on a real Depop listing in Chrome and update the fixtures/selectors.

## Backend selection

The packaged extension defaults to:

`https://cleared-backend-production.up.railway.app`

Both that origin and localhost are declared in `host_permissions`. To use a
local backend, open a Depop product page, select the extension's content-script
context in DevTools, and run:

```js
chrome.storage.local.set({ cleared_backend_url: "http://localhost:8000" })
```

Reload the product page after changing it. Return to Railway with:

```js
chrome.storage.local.remove("cleared_backend_url")
```

Only localhost HTTP or an HTTPS origin is accepted. The override is deliberately
stored locally rather than exposed in the buyer-facing panel.

## Dev load

1. Open `chrome://extensions`.
2. Enable Developer mode.
3. Load unpacked extension from this `extension/` directory.
4. Set the localhost override above and run the backend on `http://localhost:8000`.
5. Open a Depop product page and click **Check this listing** in the injected
   panel.

## Tests

From the repo root:

```sh
node --test extension/tests/*.test.js
```
