# iOS → Web: Porting a Share-Extension App to a Browser Extension

> This document is extract-ready for open-sourcing. It describes the methodology
> of the port — the live probes, the constraint analysis, and the architectural
> decisions — without leaking any product-specific keys or private business logic.
> The diffs it references are in the same git history.

---

## The original iOS architecture

Cleared started as an iOS Share Extension: a buyer taps "Share" on a Depop
listing in the iOS app, the extension pops open, and a Claude vision call turns
the listing screenshot(s) into a "care label" report.

```
  iOS Depop app  ──(Share Sheet)──▶  Cleared Share Extension
                                         │  multipart POST: screenshot bytes
                                         ▼
                                    Cleared backend
                                         │  Claude vision + web_search
                                         ▼
                                    CheckReport JSON
                                         │
                                    rendered care-label panel
```

Input = **screenshots**, not a URL. This was a forced decision: the iOS Share
Sheet produces a Branch deep-link (`depop.app.link/...`) that resolves to
Depop's homepage, not the product. The product mapping lives on Branch's servers
and is not recoverable via HTTP. So the extension screenshots the listing instead.

---

## The web constraint analysis (live-probed, not assumed)

Before writing any web code, we probed live to find what was actually blocked.
The iOS screenshots-only constraint doesn't fully transfer — the web has
different walls and different doors.

| Target | Method | Result | Meaning |
|---|---|---|---|
| `www.depop.com/products/<id>` (HTML) | server-side `httpx` GET | **HTTP 403** — 24 KB flat block page | Edge CDN blocks datacenter IPs unconditionally |
| `webapi.depop.com` (internal API) | server-side `httpx` GET | **HTTP 403** | Same edge block |
| `media-photos.depop.com` (image CDN) | server-side `httpx` GET | **HTTP 404** at root | Host responds — not 403-blocked. Root 404 = no object at `/`, not a firewall |

The key finding: **the 403 is on the HTML and API hosts, not on the image CDN.**
Real image URLs (e.g. `media-photos.depop.com/b0/{id}/P0.jpg`) are fetchable
server-side once you have the URL. You just can't get the URL server-side
because the page that contains it is blocked.

This opened a path the iOS app could never take:

> A browser extension runs client-side in the user's own browser session —
> residential IP, real cookies, no datacenter fingerprint. It reads the listing's
> `__NEXT_DATA__` (structured JSON embedded in the page) and extracts clean facts
> and CDN image URLs. It hands those to the backend. The backend fetches the
> **CDN images** (not 403-blocked) and runs the same Claude call.

---

## Why an extension, not a plain web page

The same-origin policy is a hard constraint. A page served from `cleared.app`
cannot `fetch()` or read the DOM of `www.depop.com` — the browser blocks it,
always. No CORS header Depop could set would help because Depop doesn't serve one
for arbitrary origins.

Only a browser extension with explicit `host_permissions` on `depop.com` can
reach across origins client-side. This is not a tuning knob — it's a fundamental
browser security invariant. The extension is the only browser-native path that
avoids screenshots entirely.

The decision table:

| Approach | Works? | Why |
|---|---|---|
| Scraper API (Brightdata etc.) | Yes, but | Paid, arms-race, Depop ToS exposure |
| Server-side headless browser | No | Datacenter IP → same 403 |
| Plain web page (no extension) | No | Cross-origin DOM access blocked by SOP |
| Browser extension | **Yes** | Runs in user's browser session, same-origin as Depop |

---

## The `__NEXT_DATA__` extraction approach

Depop is a Next.js app. Every product page embeds the full product record in a
`<script id="__NEXT_DATA__">` tag as JSON. The structure looks like:

```json
{
  "props": {
    "pageProps": {
      "product": {
        "brandName": "Ralph Lauren",
        "title": "Custom Fit Polo",
        "price": "35.00",
        "currencyName": "USD",
        "variantSize": "M",
        "conditionName": "Good",
        "description": "...",
        "pictures": [
          { "large": "https://media-photos.depop.com/b0/.../P0.jpg", ... },
          ...
        ]
      }
    }
  }
}
```

The field names above are **the currently observed shape** (verified against real
product pages in the browser during development). Depop can change them at any
time — which is why `extractor.js` uses a **shape-based search** rather than a
hardcoded path.

### Shape-based extraction (the defensive approach)

Instead of reaching into the JSON at a fixed path, `extractor.js` walks the
entire `__NEXT_DATA__` tree looking for any object that has both:
- An array of pictures/images (key `pictures` or `images`), and
- A price field (keys `price`, `priceAmount`, or `price_amount`).

It picks the richest match (most keys). This mirrors the original `depop.py`
`_find_product_object` logic (commit `f66d0d9^`) ported from Python to JavaScript.

The picture URL extraction tries preferred keys first (`large`, `full`,
`original`, `url`, `src`) and falls back to regex-scanning the serialized object
for image URLs. This handles both structured picture objects and flat URL strings.

### Fields and their observed key names

| Field | Primary key | Fallback keys |
|---|---|---|
| Brand | `brandName` | `brand` |
| Title / name | `title` | `name`, `description` |
| Category | `categoryName` | `category` |
| Size | `variantSize` | `size` |
| Condition | `conditionName` | `condition` |
| Price | `price` | `priceAmount`, `price_amount` |
| Currency | `currencyName` | `currency` |
| Images | `pictures` | `images` |
| Image URL | `large` | `full`, `original`, `url`, `src` |

**Manual browser verification required:** these field names were confirmed by
inspection of real product pages in the browser. To re-verify after a Depop
deploy: open a product page, run `JSON.parse(document.querySelector('script#__NEXT_DATA__').textContent)`
in the console, and compare to the extractor's key list.

---

## The seeded-facts optimization

The iOS path sends screenshots only — Claude reads everything from the image.
The web path has a better starting point: the extension extracts exact text
(price, brand, size, condition) before Claude ever sees the images.

Rather than discarding this structured data, the backend threads it through the
Claude call as "ground truth":

```
_build_user_text():
  "The listing's stated facts (from the page — treat as ground truth;
   correct only if the photos clearly contradict): { brand: 'Ralph Lauren',
   asking_price: 35, size: 'M', ... }"
```

Claude then uses the images for what they're actually good at — visual
authenticity checks, condition verification, photo sufficiency — rather than
re-transcribing text it can read from facts exactly. Better output, fewer tokens.

---

## The brand gate

The authenticity check (`auth_flag`) fires only for brands where counterfeits
are a real risk at Depop price points. Brands like Uniqlo or H&M don't get faked
at $18 — calling them suspicious would be worse than saying nothing.

The gate is enforced in two layers:

1. **Prompt layer**: `_build_user_text()` injects the `FAKEABLE_BRANDS` list. Claude
   is instructed to set `auth_flag.applicable=false` for brands not in the list.

2. **Backend enforcement**: `_enforce_brand_gate()` in `claude_check.py` reads the
   brand from `report.listing_facts.brand` and unconditionally silences the auth
   flag for non-fakeable brands — regardless of what Claude returned. This is the
   belt-and-suspenders backstop against prompt drift.

Live validation confirmed:
- Aelfric Eden → `auth_flag.applicable=true`, red flags populated (see `phase-1-tests/runs/run-0-12:58am/`)
- Kenneth Cole leather jacket → `auth_flag.applicable=false`, empty (see `phase-1-tests/runs/run-1-9:32am/`)
- Uniqlo → `auth_flag.applicable=false` (gate OFF, brand not in fakeable list)
- Ralph Lauren → `auth_flag.applicable=true` (gate ON, in fakeable list)

The extension UI (`src/ui.js`) applies no brand logic — it renders whatever
`auth_flag.applicable` the backend sends. The gate is entirely server-side.

---

## Before / after architecture

```
BEFORE (iOS)                          AFTER (web)

depop.com/products/<id>               depop.com/products/<id>
    │                                     │
  iOS Share Sheet                     [ Extension content script ]
    │ share link (Branch deep-link)     │ reads __NEXT_DATA__ → exact facts + CDN image URLs
    │ (resolves to homepage — unusable) │
    ▼                                   ▼
  User screenshots the listing       POST /check-listing { facts, image_urls, user_context }
    │                                   │
    ▼                                   ▼
  Share Extension                    [ Backend ]
    │ uploads screenshots (bytes)     fetches image_urls from CDN (not 403-blocked)
    │                                   │
    ▼                                   ▼
  POST /check (multipart)           run_check_traced(images, user_context, seeded_facts=facts)
    │                                   │  (same engine, same single Claude call)
    ▼                                   ▼
  run_check(images, user_context)    CheckReport JSON
    │                                   │
    ▼                                   ▼
  CheckReport JSON               [ Extension renders care-label panel in-page ]
    │
    ▼
  iOS renders care-label panel
```

Key differences:
- **Input**: bytes from screenshots → exact text + CDN image URLs
- **Image quality**: compressed screenshot pixels → full-resolution CDN photos
- **Friction**: screenshot → share → wait → panel → click-through → negotiate
  vs. one click on the page you're already on
- **Engine**: identical. Same `run_check_traced`, same structured Claude call,
  same `CheckReport` contract. The web path is a cleaner input to the same brain.

---

## What still requires manual browser verification

The following cannot be validated from a server (Depop HTML is 403-blocked):

1. **Real CDN image URL format**: `media-photos.depop.com` is confirmed
   reachable server-side (returns 404 at root, not 403). But valid image paths
   contain UUIDs/product IDs that can only be obtained from `__NEXT_DATA__` in
   a real browser session. To verify end-to-end: load an unpacked extension on
   a real product page, click "Check this listing," and confirm the backend
   receives and fetches the images.

2. **Current `__NEXT_DATA__` field names**: verified by browser inspection during
   development. Re-verify after a Depop deploy by inspecting `__NEXT_DATA__` in
   the browser console. The extractor's shape-based approach degrades gracefully
   (falls back to empty facts rather than crashing) if the schema changes.

3. **Brand gate live on a real listing**: the gate is validated against saved
   screenshots (see phase-1-tests/runs/), but a real web-path check on a live
   Ralph Lauren listing would confirm the seeded-facts path through the gate.

---

## Files changed in the web port

| File | Change |
|---|---|
| `backend/app/main.py` | Added `POST /check-listing`; CORS tightened with `CLEARED_EXTENSION_ORIGIN` env var |
| `backend/app/images.py` | New: CDN image fetcher (httpx, browser headers, per-image cap) |
| `backend/app/models.py` | Added `CheckListingRequest` model |
| `backend/app/claude_check.py` | `seeded_facts` param threaded through `run_check` → `run_check_traced` → `_build_user_text` |
| `extension/manifest.json` | Manifest V3, host_permissions for depop.com + localhost |
| `extension/src/extractor.js` | `__NEXT_DATA__` → facts + image URLs, shape-based product walk |
| `extension/src/client.js` | `postCheckListing()` POSTs to `/check-listing` |
| `extension/src/ui.js` | Renders `CheckReport` as care-label panel in-page |
| `extension/styles.css` | Care-label design system (architecture.html tokens) |
| `extension/content-script.js` | Orchestrates: extract → inject panel → button click → POST → render |
| `extension/tests/` | 11 unit tests: extractor, client, manifest, UI |
| `backend/tests/test_check_listing.py` | 7 unit tests: CDN fetcher, seeded facts, endpoint |
