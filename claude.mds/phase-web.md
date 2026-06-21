# Phase Web — Cleared on the web (browser-extension-first)

> Per-phase brief for the implementation sub-agent. Read the root `CLAUDE.md`
> first (locked decisions + the `CheckReport` contract), then `phase-0.md` (why
> server-side fetch is dead) and `phase-1.md` (the one Claude call). This brief
> is the web track; it runs **parallel** to the numbered iOS roadmap, not after it.

## Goal

Deliver the same Cleared value — a two-tap "is this fair / trustworthy / legit?"
read on a Depop listing — on the **web**, where the constraints that forced the
iOS screenshot model don't all apply. Same `CheckReport` contract, same engine,
new front door.

## The load-bearing web finding (verified live 2026-06-21)

The iOS pivot to screenshots was forced by two walls: Depop's 403 edge block on
server-side fetches, and the unusable Branch deep-link from the iOS share sheet.
On web, **one of those walls has a door in it.** Live probe from this datacenter:

| Target | Result | Meaning |
|---|---|---|
| Product **HTML** page (`www.depop.com/products/...`) | `403`, 24KB block | server-side fetch still dead |
| **API** host (`webapi.depop.com`) | `403` | also edge-blocked |
| **Image CDN** (`media-photos.depop.com`) | `404` at root, **not 403** | host serves; real image URLs are almost certainly fetchable server-side |

So the 403 is on the **HTML/API**, not the **image CDN**. That unlocks a path
the iOS app never could take:

> A **browser extension** reads the listing's structured data **client-side, in
> the user's own browser session** (residential IP, real cookies — the exact
> thing the iOS sandbox forbade and the datacenter 403 blocks). It hands the
> backend clean **facts + image URLs**. The backend fetches the **real images**
> from the CDN (not edge-blocked) and runs the existing Claude call.

This beats OCR-ing a screenshot on every axis: exact price/brand/condition/
description text (no vision guesswork), full-resolution real photos for the
authenticity pass, and one click instead of "screenshot → share → wait."

**Why not a plain web page instead of an extension?** Same-origin policy. A page
served from our origin cannot `fetch()` or read the DOM of `depop.com`
cross-origin — the browser blocks it. Only an extension with host permissions
on `depop.com` can read the page. This is a hard rule, not a tuning knob.

## Architecture (extension-first)

```
  depop.com/products/<id>  ──(user is browsing)
        │
        ▼
  [ Cleared extension content script ]
   • reads <script id="__NEXT_DATA__"> → product object (facts + image URLs)
   • injects a "Check this listing" button / panel on the page
        │  POST { facts, image_urls, user_context }   (+ shared-secret header)
        ▼
  [ Cleared backend  POST /check-listing ]   ← NEW endpoint
   • fetches image_urls from the CDN (server-side; CDN is not 403-blocked)
   • runs the existing Claude call: real images + seeded facts + web_search
   • returns CheckReport (the unchanged contract)
        │
        ▼
  [ extension renders CheckReport as the "care label" panel, in-page ]
```

The engine (`claude_check.py`) and the contract (`CheckReport`) **do not
change shape.** We are adding a cleaner input path, not a new product.

## Repo structure (decided)

**Monorepo.** All *product* code stays in this repo:

```
Cleared/
  backend/        # the engine — shared, mostly unchanged
  extension/      # NEW — Manifest V3 browser extension (the web front door)
  web/            # OPTIONAL later — paste-a-screenshot fallback page
  docs/ios-to-web/  # NEW — the publishable "how we ported iOS→web" methodology
  claude.mds/     # phase briefs (this file lives here)
```

**Why monorepo:** single-user personal tool; one git history tells the whole
iOS→web porting story; no cross-repo auth/submodule ceremony; the backend stays
one shared engine.

**The open-source angle (the *process*, not the product).** The user may
open-source the *methodology* of porting an iOS app to web with an agent — not
the Depop agent itself. That artifact is documentation, and it constantly
references the real diffs, so it belongs in this repo's history. Keep it
**extract-ready** in `docs/ios-to-web/`: written to stand alone, no secrets, so
it can later be `git subtree split` / copied into a public repo without dragging
private product code along. As you implement, drop notes there (the live probe
above, decisions, before/after diffs) so the write-up assembles itself.

## Backend changes

Keep `POST /check` (multipart screenshots) exactly as is — it's the fallback and
the future `web/` page uses it. Add:

1. **`POST /check-listing`** — JSON body `{ facts, image_urls, user_context }`.
   - Reuse the `ListingFacts` model for `facts`; `image_urls: list[str]`.
2. **A CDN image fetcher** — download each `image_url` server-side (httpx,
   browser-ish headers, sane timeout + per-image size cap, cap N images ~6–8).
   Reuse the recoverable `depop.py` networking shape. **LIVE-VALIDATE** that the
   CDN actually returns image bytes for a real product image URL (the root
   probe was 404, which only proves the host isn't flat-blocked).
3. **`run_check` seam** — let it accept pre-fetched image bytes **plus** seeded
   `ListingFacts`, so Claude *refines/verifies* the extracted facts against the
   photos instead of reading them from scratch. Minimal change: same call, the
   user-text block now includes the structured facts as ground truth ("here are
   the listing's stated facts; correct them only if the photos contradict").
4. **A shared-secret header** (e.g. `X-Cleared-Token`) so the deployed backend
   isn't an open Claude proxy. CORS is already `*`; tighten `allow_origins` to
   the extension origin + localhost once the extension ID is known.

The risk flagged in `phase-1.md` (structured output + `web_search` in one call)
is **resolved** — validated 2026-06-21 against a real Aelfric Eden screenshot,
so the single-call shape carries over to `/check-listing` as-is.

## Extension (Manifest V3, Chrome first)

- **Manifest:** `host_permissions: ["*://*.depop.com/products/*"]`, a content
  script matched on product pages, an action popup for status/result, and the
  backend origin in `host_permissions` so the content script can POST to it.
- **Extraction:** port `_find_product_object` from the recoverable
  `git show f66d0d9^:backend/app/depop.py` — it locates the product object **by
  shape** (a dict carrying pictures + price) inside `__NEXT_DATA__`, with an
  OpenGraph fallback. That defensive-by-shape approach is the whole point; the
  Python → JS port is mechanical. **LIVE-VALIDATE the field names** against a
  real current product page's `__NEXT_DATA__` (price, pictures/image URLs, size,
  condition, description, brand) — Depop can change the shape any time.
- **UI:** inject a single "Check this listing" button near the price; on click,
  POST facts + image URLs, show a loading state, render the returned
  `CheckReport` as the care-label panel (mirror `architecture.html`'s styling so
  iOS and web look like one product). Optional voice context via a text field
  (full mic/Web Speech API can come later — it's the iOS "mic" analog).
- **Dev loading:** unpacked extension + backend on `localhost:8000`. No store
  submission needed for personal use.

## Build order (slices for the sub-agent)

- **W1 — Backend seam.** Add `/check-listing`, the CDN fetcher, the seeded-facts
  path in `run_check`, and the shared-secret header. Unit-testable with a fake
  facts payload + a couple of real image URLs. *Validates the CDN-fetch finding.*
- **W2 — Extension skeleton.** Manifest V3, content script that extracts
  `__NEXT_DATA__` and `console.log`s the parsed facts + image URLs on a real
  product page. *Validates the `__NEXT_DATA__` shape.*
- **W3 — Wire them.** Button → POST → render `CheckReport` in-page. First real
  end-to-end web verdict.
- **W4 — Polish + gate both ways.** Style to match `architecture.html`; confirm
  the brand gate (Uniqlo OFF, Ralph Lauren / Aelfric Eden ON) on live listings;
  tighten CORS to the real extension ID; write the `docs/ios-to-web/` narrative.
- **W5 (optional) — `web/` fallback page.** A drag-a-screenshot page hitting the
  unchanged `/check`, for non-extension/mobile-web use.

**Done when:** browsing a real Depop product page, one click returns a sane
`CheckReport` (retail anchor + fairness + offer range, useful questions,
correctly gated auth flag, defensible verdict) rendered in-page — using
extracted facts + real CDN images, no screenshot.

## Live-validation checklist (the project's "verify, don't assume" ethos)

1. CDN image URLs fetch real bytes server-side (not just non-403 at root).
2. `__NEXT_DATA__` field names for price / images / size / condition / brand /
   description on a current product page.
3. ~~Structured output + `web_search` in one call~~ — already validated in
   phase-1 (Aelfric Eden run); carries over unchanged.
4. Brand gate fires correctly on live listings, both directions.

## How this gets executed (sub-agent + branch structure)

This brief is written to be handed to one implementation sub-agent. Recommended
hand-off when the user is ready:

- Spawn an implementation agent with **`isolation: "worktree"`** so it works on
  an isolated checkout, on a new branch off this one, e.g.
  `claude/depop-web-app-impl`. The worktree keeps the plan branch clean and is
  auto-cleaned if nothing changes.
- Point it at this file as its spec. It owns W1→W4 (W5 optional), commits per
  slice, and surfaces the four live-validation results (a live `ANTHROPIC_API_KEY`
  and a real Depop session in the browser are its external dependencies).
- Monorepo means no cross-repo wiring: it adds `extension/`, edits `backend/`,
  and writes `docs/ios-to-web/` all in one tree.
