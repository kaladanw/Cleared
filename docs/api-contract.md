# Cleared API contract (web · Chrome extension · iOS)

Source of truth for every client. Derived from `backend/app/main.py`,
`backend/app/auth.py`, `backend/app/models.py`, and `backend/app/check_images.py`.
If this file and the code disagree, the code wins. Fix this file in the same PR.

- **Base URL (prod):** `https://cleared-backend-production.up.railway.app`
- **Format:** JSON unless noted. Errors are FastAPI-style: `{"detail": "<message>"}`
  (422 validation errors may carry a list in `detail`).
- **Compatibility rule:** response changes are **additive only**. Clients must ignore
  unknown fields. Nothing is renamed or removed without a new contract version.

---

## 1. Auth

All accounts are Supabase Auth users, so one account works on web, extension, and iOS.
The backend proxies auth and never stores passwords.

### Session object (returned by signup, login, refresh)

```json
{
  "access_token": "eyJ…",          // Supabase JWT. Send as Authorization: Bearer <access_token>
  "refresh_token": "v1.abc…",      // single-use; replace your stored copy on every refresh
  "expires_in": 3600,              // seconds the access token lives (from issue)
  "expires_at": 1791234567,        // unix seconds when the access token expires
  "token_type": "bearer",
  "user": { "id": "<uuid>", "email": "a@b.com" }
}
```

`access_token` and `user` are the original fields. The others were added for iOS parity.
On signup, if the project requires email confirmation there is no session yet, so every
token field is `null` and only `user` is set.

### `POST /auth/signup`
Body `{ "email", "password" }` → Session.
- **403** `Signup is not open for this email address.`: invite allowlist
  (`CLEARED_ALLOWED_EMAILS`). The allowlist applies **only at signup**; login and refresh
  are not allowlist-gated, because accounts can only be created through allowlisted signup.
- **400** signup rejected by Supabase (weak password, already registered, …).
- **503** auth service unavailable. Retry.

### `POST /auth/login`
Body `{ "email", "password" }` → Session.
- **401** `Invalid email or password.`
- **503** auth service unavailable. Retry; this is not a credentials problem.

### `POST /auth/refresh`
Body `{ "refresh_token": "<string, 1–4096 chars>" }` → Session (new access **and** new refresh token).
- **401** `Invalid or expired refresh token.`: the token is unknown, revoked, already
  used, or the session timed out. **Sign the user out** and show login.
- **503** auth service unavailable. **Keep the session**, retry with backoff, and don't sign out.
- **422** missing or empty `refresh_token`.

### Bearer usage and token lifetimes
- Send `Authorization: Bearer <access_token>` on every user-scoped endpoint.
- Access token: Supabase default **1 hour** (`expires_in`), configurable in Supabase
  → Auth → Sessions.
- Refresh token: **no time expiry by default, but single-use.** Supabase rotates it on
  every refresh. Reusing an old token is allowed within a ~10 s reuse interval, and reusing
  the immediate parent returns the active token. Any other reuse **revokes the whole session**
  (reuse detection). Clients must therefore:
  1. store the new `refresh_token` atomically every time;
  2. serialize refreshes (one in flight per device; the iOS app and its Share Extension
     share one keychain item, so coordinate between them);
  3. refresh proactively when `expires_at - now < 120 s`, and always before starting a `/check`.
     A check runs 30–90 s, but the JWT is verified when the request arrives, so a token
     valid at send time is enough.
- On **401** from any user-scoped endpoint: refresh once, retry once, then sign out if it
  still fails.
- Optional Supabase project settings (Pro plan) such as time-boxed sessions, inactivity
  timeout, and single session per user are enforced at refresh time and surface as
  `/auth/refresh` 401.

### Common auth errors on user-scoped endpoints
| Status | Meaning |
|---|---|
| 401 `Missing Authorization header…` | no / non-Bearer `Authorization` header |
| 401 `Invalid or expired token.` | JWT rejected by Supabase → refresh |
| 503 `Supabase is not configured.` | backend misconfiguration |

---

## 2. Checks

### Report shape (`CheckReport`)
Returned by `/check`, `/check-listing`, and recheck, and stored as `report_json` on reports.

```json
{
  "listing_facts": {
    "brand": "Barbour", "model_or_name": "Beaufort jacket", "category": "jacket",
    "size": "M", "listed_condition": "Good", "asking_price": 120.0, "currency": "USD",
    "photo_observations": ["…"]
  },
  "price_read": {
    "retail_estimate": 400.0, "used_estimate_low": 90.0, "used_estimate_high": 150.0,
    "fairness": "steal|fair|high|overpriced|null",
    "suggested_offer_low": 80.0, "suggested_offer_high": 95.0, "reasoning": "…"
  },
  "listing_trust": { "missing_info": [], "concerns": [], "questions_to_ask": [] },
  "auth_flag": { "applicable": false, "red_flags": [], "what_to_inspect": [], "confidence": "low|medium|high|null" },
  "verdict": { "recommendation": "buy|negotiate|skip|null", "one_line": "…", "user_context": "…|null" },
  "error": null
}
```
When `error` is non-null the listing couldn't be read. Render the error and nothing else.
These are still **HTTP 200**.

### Check response (`CheckResponse`) = `CheckReport` + additive fields
| Field | Type | Meaning |
|---|---|---|
| `report_id` | `string\|null` | ID of the saved row (see `GET /api/reports`). `null` when not saved: shared-secret `/check`, `/check` error reports, `/check-listing` without `listing_url`, or a save failure. |
| `images_stored` | `int` | Photos copied into private storage for this report: screenshots from a Bearer `/check`, or CDN photos from a saved `/check-listing`. `> 0` means recheck no longer depends on the CDN. |

### `POST /check` (multipart/form-data, iOS Share Extension)
Auth: **one of**
- `Authorization: Bearer <access_token>` (**preferred**). The check is attributed to the
  user, **saved to `reports`**, and screenshots go to private storage. Returns `report_id`.
- `X-Cleared-Token: <shared secret>` (**legacy, rollout only**). Same as before: not
  user-scoped, **not saved**, `report_id: null`. Enforced only when the backend sets
  `CLEARED_SHARED_TOKEN`.

If both headers are sent, **Bearer wins**. If an `Authorization` header is present but
invalid, expired, or not `Bearer`, the response is **401**, never a silent fallback to the
shared secret.

| Part | Required | Notes |
|---|---|---|
| `images` | yes (repeat per file) | 1–8 files; each ≤ 10 MB; JPEG / PNG / WebP / GIF, detected from the file bytes rather than the declared content type |
| `user_context` | no | free text (e.g. voice note) |
| `listing_url` | no | `http(s)://…`, ≤ 2048 chars; stored as `listing_url` (empty string when omitted) |
| `marketplace` | no | slug `^[a-z][a-z0-9_-]{0,31}$` (input is lowercased); default `depop` |
| `seller_username` | no | see [Seller usernames](#seller-usernames); invalid gives null and never fails the check. For `depop`, `seller_url` is derived as `https://www.depop.com/{username}/` |

Saving (Bearer only):
- The row is saved only when `error` is null. `listing_name` comes from the vision-read
  `model_or_name`, falling back to `brand`.
- Screenshots go to the private bucket at `{user_id}/{report_id}/{n}.{ext}` and are
  referenced by `image_paths`.
- Upload is best effort: if storage fails, the report is still saved with
  `image_paths: []` and `images_stored: 0`.

Errors: **400** more than 8 images · **413** image too large · **415** not an image ·
**422** bad `marketplace` / `listing_url` · **401** auth (above). No images at all gives
200 with `error: "No screenshots received…"`.

### `POST /check-listing` (JSON, Chrome extension + iOS link share, **Bearer only**)
`Authorization: Bearer <access_token>` is required. **`X-Cleared-Token` is not accepted
here** (401): shared-secret checks exist only on multipart `/check`, where they are
unsaved and not user-scoped.

```json
{
  "facts": { /* ListingFacts, optional seed */ },
  "description": "Levi's 505 W29 L32…\n\nPit to pit 21in. Small mark on left knee.",
  "image_urls": ["https://media-photos.depop.com/b1/…/P0.jpg"],
  "user_context": null,
  "listing_url": "https://www.depop.com/products/…",
  "marketplace": "depop",
  "seller": { "username": "davidjared", "profile_url": "https://www.depop.com/davidjared/" }
}
```

| Field | Required | Notes |
|---|---|---|
| `facts` | no | `ListingFacts` seed from the page; the model treats it as ground truth unless the photos contradict it |
| `description` | no | **Top level, next to `facts`, not inside it.** The seller's full description. The server trims it; blank, whitespace-only, or non-string values count as absent; anything over **5000 chars is truncated (never a 422)**. Sent to the model, fenced as untrusted seller text, so measurements and flaws are considered. Stored privately (`listing_description`) for recheck; **never** returned by `GET /api/reports` or `/api/shared`. Clients (iOS, extension) trim, cap at 5000, and omit it when blank |
| `image_urls` | yes (≥1 usable) | up to 8 used; each fetched server-side through the [image fetch guard](#image-fetch-guard); ≤ 10 MB each |
| `user_context` | no | buyer's free text |
| `listing_url` | no | when present the check is **saved** and photos are copied (below) |
| `marketplace` | no | slug, default `depop` |
| `seller` | no | `{username, profile_url}` (a bare string is read as `username`). See [Seller usernames](#seller-usernames). Invalid or garbage values become null and never fail the check |

→ `CheckResponse`. If no image can be fetched: 200 with `error: "Could not fetch listing photos…"`.

Saving (when `listing_url` is present):
- The row stores `image_urls` as sent.
- **Durable photos:** the photo bytes the server already downloaded for the check, re-verified
  as JPEG/PNG/WebP/GIF from their bytes, are copied best-effort to private storage at
  `{user_id}/{report_id}/{n}.{ext}` and recorded in `image_paths`.
  - The copy runs **concurrently with the model call**, so it normally adds ~0 s. The server
    waits at most `CLEARED_IMAGE_COPY_WAIT` (default 5 s) after the check finishes, then saves
    without images and deletes late uploads.
  - Copies are discarded when the check returns `error`.
  - A failed copy never fails the check (`images_stored: 0`).

#### Image fetch guard
Applies to `/check-listing` and to recheck's `image_urls` fallback. Each URL **and every
redirect hop** (max 3) must be:
- `http`/`https` with no userinfo, on port 80/443;
- on a host in the allowlist `CLEARED_IMAGE_HOSTS`, which defaults to `media-photos.depop.com`
  (comma-separated; `*.example.net` matches subdomains, e.g. `*.vinted.net` later);
- resolving only to public IPs (no private, loopback, link-local/metadata, CGNAT, multicast,
  reserved, or IPv4-mapped equivalents).

Bodies are streamed with a 10 MB cap. Timeouts: 5 s connect, 10 s per read. Anything that
fails a rule is skipped (logged), not fetched.

#### Seller usernames
Applied to `/check-listing` `seller.username` and `/check` `seller_username`:
1. Must be a string (numbers are stringified). Anything else gives null.
2. Trim surrounding whitespace, strip **all** leading `@`, trim again, then lowercase.
3. The result must match `^[a-z0-9._-]{1,64}$`. Otherwise the seller is **null** and the check
   still succeeds. Internal spaces, `/`, non-ASCII letters, empty, `@` alone, or more than
   64 chars all give null.
4. `seller.profile_url` is kept only if it is `http(s)://`, ≤ 300 chars, with no spaces,
   quotes, or angle brackets. It is dropped when the username is null.

Examples: `"@DavidJared"` → `davidjared` · `"  @Thrift_Queen \n"` → `thrift_queen` ·
`"@@vintage.finds"` → `vintage.finds` · `"david jared"` → null · `"émilie"` → null.

---

## 3. History (hub): `GET /api/reports` is the source of truth

**iOS:** treat `GET /api/reports` as the source of truth for history. Keep local history
only as an offline cache keyed by `id`: replace it from the server on launch, on
pull-to-refresh, and after each Bearer `/check`. A shared-secret check (no `report_id`)
exists only locally until it is re-run with Bearer. On error (401/503) keep the cache;
the server returns **503**, never an empty list, when it can't read history.

### Report row (owner view)
`GET /api/reports`, `PATCH /api/reports/{id}`
```json
{
  "id": "<uuid>",
  "listing_url": "https://www.depop.com/products/…",   // may be "" for iOS checks without a URL
  "listing_name": "Beaufort jacket",
  "marketplace": "depop",
  "verdict": "buy|negotiate|skip|null",
  "checked_at": "2026-10-07T16:24:00.123456+00:00",
  "report_json": { /* CheckReport */ },
  "hub_status": "watching|bought|skipped|sold_out|null",
  "notes": "",
  "tags": ["gift"],
  "image_urls": [],               // public CDN URLs (extension checks)
  "image_paths": [],              // private storage copies (/check, /check-listing); opaque, not fetchable
  "seller_username": "vintage.finds|null",
  "seller_url": "https://www.depop.com/vintage.finds/|null",
  "share_token": "<43 chars>|null",
  "shared_at": "<iso8601>|null",
  "can_recheck": true             // computed: image_urls or image_paths present
}
```
Rows without a seller (older checks) have `null` seller fields.

### `GET /api/reports` (Bearer)
Newest first. Every filter is optional and combined with AND:

| Param | Values |
|---|---|
| `marketplace` | slug (e.g. `depop`) |
| `verdict` | `buy` · `negotiate` · `skip` |
| `status` | `watching` · `bought` · `skipped` · `sold_out` · `none` (= unset) |
| `seller` | username (same normalization as above) |
| `q` | case-insensitive substring over listing_name, listing_url, notes, seller_username, tags, verdict one_line |
| `date_from`, `date_to` | `YYYY-MM-DD`, inclusive, compared to the UTC date of `checked_at` |

**422** invalid marketplace/verdict/status/seller · **503** history unavailable.

### `GET /api/reports.csv` (Bearer)
Same filters. `text/csv; charset=utf-8`, attachment `cleared-checks.csv`, CRLF line endings.
Columns in order: `checked_at, marketplace, listing_name, listing_url, verdict, one_line,
asking_price, currency, fairness, status, tags, notes`. Tags are joined with `; `, and cells
starting with `= + - @ \t \r` are prefixed with `'`.

### `PATCH /api/reports/{id}` (Bearer, owner only)
Body (each field optional; an omitted field stays unchanged):
`{ "status": "watching|bought|skipped|sold_out|none", "notes": "≤4000 chars", "tags": ["≤12 tags, ≤40 chars each, deduped case-insensitively"] }`
→ updated report row. **400** no fields · **404** not found / not yours · **422** bad status.

### `POST /api/reports/{id}/recheck` (Bearer, owner only)
Re-runs the check from stored images and saves the result as a **new** row, which keeps the
same listing, seller, and image references. Returns `CheckResponse` with the new `report_id`.
- Image source: `image_paths` (private copies, downloaded server-side) **first**. Otherwise
  `image_urls`, re-fetched through the [image fetch guard](#image-fetch-guard).
- The stored `description`, if any, is passed to the model again and carried to the new row.
- **409** neither present (older checks): open the listing and check again.
  **404** not found / not yours.
  200 with `error` set if the stored images can't be loaded.

### `GET /reports?url=<listing_url>` (Bearer, extension)
The latest saved row for that exact URL, or `null`.

---

## 4. Share links

| Endpoint | Auth | Result |
|---|---|---|
| `POST /api/reports/{id}/share` | Bearer, owner | `{ "token", "path": "/r/{token}", "shared_at" }`; idempotent (returns the existing token) |
| `DELETE /api/reports/{id}/share` | Bearer, owner | `{ "revoked": true }`; the token is cleared, so the old link 404s and sharing again mints a new token |
| `GET /api/shared/{token}` | **none** | sanitized report (below) |

Web link: `https://<web host>/r/{token}`.

Public payload (`GET /api/shared/{token}`):
```json
{
  "listing_name": "…", "listing_url": "…", "marketplace": "depop",
  "verdict": "negotiate", "checked_at": "…", "seller_username": "vintage.finds|null",
  "report": { "listing_facts": {}, "price_read": {}, "listing_trust": {}, "auth_flag": {},
              "verdict": { "recommendation": "…", "one_line": "…" } }
}
```
**Never** included: user id/email, notes, tags, hub_status, `image_urls`, `image_paths`,
the seller's `description` (`listing_description`), share metadata, or `verdict.user_context`.
**404** malformed/unknown/revoked token · **429** per-IP rate limit (default 60/min,
`Retry-After: 60`). Responses send `Cache-Control: no-store` and `X-Robots-Tag: noindex`.

---

## 5. Status code summary

| Code | Where | Client action |
|---|---|---|
| 200 + `error` | checks | show the error text |
| 400 | `/check` >8 images; PATCH with no fields; signup rejected | fix request |
| 401 | missing/invalid Bearer (including `X-Cleared-Token` alone on `/check-listing`); bad shared secret on `/check`; bad login; bad refresh token | refresh once, then sign in |
| 403 | signup not allowlisted | show invite message |
| 404 | report not yours / missing; share token unknown/revoked | remove from cache |
| 409 | recheck without stored images | offer "check again" |
| 413 / 415 | `/check` image too large / not an image | re-encode as JPEG ≤10 MB |
| 422 | validation (filters, marketplace, listing_url, refresh body) | fix request |
| 429 | public share endpoint | back off |
| 503 | auth service or history unavailable | retry; **do not** sign out or clear cache |

---

## 6. Storage (backend-internal, for reference)
- Private bucket `check-images` (env `CLEARED_IMAGE_BUCKET`), no public access and no
  storage policies. The backend uses the service role.
- Object path `{user_id}/{report_id}/{n}.{jpg|png|webp|gif}`, written by Bearer `/check`
  (screenshots) and saved `/check-listing` (CDN photo copies). Only the backend reads it;
  no signed or public URL is issued to clients. A recheck row references the same objects.
- Setup: `backend/supabase/migrations/20261008_ios_account_parity.sql` (bucket +
  `image_paths`) and `20261009_listing_description.sql` (private `listing_description`).
