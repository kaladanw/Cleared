# Cleared web

Static Vite site for Cleared's Vercel-hosted invite onboarding, marketplace hub,
extension setup, marketing, privacy, and support surfaces.

## Local development

```sh
cd web
npm install
npm run dev
```

Run `npm test` and `npm run build` before deploying.

## Vercel setup

Create a Vercel project from this repository with:

- Root Directory: `web`
- Framework Preset: Vite
- Build Command: `npm run build`
- Output Directory: `dist`
- Install Command: `npm install`

The site calls the existing Railway API directly. It defaults to
`https://cleared-backend-production.up.railway.app`; local or preview builds can
set `VITE_CLEARED_API_URL` at build time. `vercel.json` enables clean routes
(`/hub`, `/privacy`, `/support`) and baseline security headers.

## Invite authentication

The landing page uses the backend's public `POST /auth/signup` and
`POST /auth/login` JSON contract. Signup is gated by the backend's
`CLEARED_ALLOWED_EMAILS` configuration. The site maps allowlist, credential,
validation, network, and service errors to buyer-facing messages without
displaying raw provider errors.

After a successful signup or login, the site stores the bearer token in
`sessionStorage` (`cleared_web_session`) and navigates to `/hub`. Passwords and
form values are never stored. The website and Chrome extension have separate
browser storage, so the install instructions honestly ask the user to sign in
again inside the extension.

## Marketplace hub (`/hub`)

Authenticated users land on the hub, which lists past listing checks from
`GET /api/reports`. Filters: marketplace, verdict, hub status, text search (`q`),
and date from/to. Each card shows verdict, listing name/URL, marketplace badge,
status, deal/trust one-liner, and date; expand for price/trust detail, notes,
tags, **Open listing**, and **Recheck** (API recheck when `image_urls` were
stored; otherwise opens the listing for an extension recheck).

Statuses: watching / bought / skipped / sold_out (plus unset). Empty state
points users at the Chrome extension on Depop. Install steps stay on the page.

Depop is the first marketplace; filters are ready for Vinted later once an
extractor ships. Apply all Supabase migrations under `backend/supabase/migrations/`
(in filename order).

### Seller view

Checks made with an extension build that captures the seller show a clickable
`@username` chip. Clicking it sets the `seller` filter (`GET /api/reports?seller=`)
and shows a banner with the check count and verdict mix (buy / negotiate / skip)
for that seller, plus **Clear seller**. Older checks have no seller and show no
chip. Text search (`q`) also matches the seller username.

### CSV export

**Export CSV** downloads `GET /api/reports.csv` using the filters currently
applied to the list (including seller). The request carries the Bearer token, so
the hub fetches it and saves via an object URL. Columns, in order:
`checked_at, marketplace, listing_name, listing_url, verdict, one_line,
asking_price, currency, fairness, status, tags, notes` (tags joined with `; `).
Cells that start with `= + - @` (or tab/CR) are prefixed with `'` to neutralize
spreadsheet formula injection.

### Share a report (`/r/{token}`)

On an expanded card, **Share** mints a read-only link
(`POST /api/reports/{id}/share`, owner-only, idempotent) and copies
`https://<site>/r/{token}`; **Revoke link** (`DELETE /api/reports/{id}/share`)
nulls the token so the old link 404s. Sharing again mints a new token.

`/r/{token}` is rewritten by `vercel.json` to `share.html` (Vite dev mirrors the
rewrite; `share.html?t={token}` also works). The page needs no login and calls the
public `GET /api/shared/{token}`, which returns a sanitized report: listing
name/URL, marketplace, verdict, checked_at, seller username, and report highlights
(facts, price read, trust, auth flag, verdict). It never includes user id/email,
notes, tags, hub status, or the buyer's private `user_context`. The endpoint is
per-IP rate-limited (`CLEARED_SHARE_RATE_LIMIT`, default 60/min), sends
`Cache-Control: no-store` and `X-Robots-Tag: noindex`, and the page is `noindex`
with `no-referrer`. Tokens are 43-char `secrets.token_urlsafe(32)` values.

## Domain and launch requirements

1. Add the production domain to the Vercel project and make Vercel's requested DNS records authoritative. Keep the generated `*.vercel.app` URL as a preview/fallback.
2. Choose one canonical hostname (`cleared.app` or `www.cleared.app`) and configure the other to redirect to it in Vercel.
3. Provide invitees with the unpacked `extension/` folder through an approved
   channel; the website intentionally does not claim a public download exists.
4. Replace the support placeholder with a monitored address or form.
5. Finalize the privacy policy's report retention period and verify the production terms and retention settings for hosting, auth/database, and AI processors.
6. Lock backend CORS to the reviewed Vercel production/preview origins when those hostnames are final: set `CLEARED_WEB_ORIGINS` (comma-separated) on the Railway backend to the Vercel prod domain and/or preview domain — see `backend/.env.example`.
7. Apply the Supabase migrations in `backend/supabase/migrations/` in order (`20261006_add_marketplace.sql`, `20261006_hub_triage.sql`, `20261007_share_seller.sql`) so the hub, triage, share, and seller columns exist in production.
8. Verify signup → `/hub`, `/privacy`, and `/support` on the production domain, including mobile layout, TLS, metadata, keyboard navigation, and a real support/deletion request.

## Still deferred

Universal Links, Cleared-owned check-ID routing, shared login between web and
extension, iOS `/check` persistence into the hub, price monitors, share-link
expiry/analytics, seller backfill for older checks, and additional marketplace
extractors (Vinted) are out of scope for this slice.

## Extension/backend handoff

The browser extension is packaged against the existing Railway API at
`https://cleared-backend-production.up.railway.app`. Its manifest also permits
`http://localhost:8000` for development, but localhost is used only when the
developer explicitly stores the override documented in `extension/README.md`.
The Vercel site does not proxy API requests. The onboarding flow and hub use the
same Railway origin as the packaged extension.
