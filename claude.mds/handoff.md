# Session handoff — live working state (2026-07-11)

> Snapshot for a fresh agent picking up mid-flight. Read the root `CLAUDE.md`
> first (locked decisions + `CheckReport` contract), then `phase-web.md` for the
> web track. This file is only the *live state* on top of those.

## Where we are

The **web track is built, merged to `main`, and live end-to-end**:

- **Extension (Manifest V3, tested in Arc)** — injects a care-label panel on
  Depop product pages, extracts listing facts from `application/ld+json`
  (Depop dropped `__NEXT_DATA__` in 2026 — extractor tries ld+json first,
  falls back to `__NEXT_DATA__`), login form → JWT in `chrome.storage.local`,
  posts to `/check-listing` with `Authorization: Bearer`, renders the report,
  drag-to-reposition + `resize: both`.
- **Supabase (project `wmqykginjawebegifspi`)** — Auth (email/password,
  invite-only via `CLEARED_ALLOWED_EMAILS`) + `reports` table (RLS on,
  keyed by `user_id` + `listing_url`). Every check saves a row; revisiting a
  listing renders the newest cached report with a Re-check button
  (`GET /reports?url=` returns `limit(1)` by design — all rows are kept).
- **History page** — `GET /history` serves a self-contained HTML page
  (login → list of past checks). Deployed but **not yet manually verified**.
- **Backend deployed on Railway** — project `cleared`, service
  `cleared-backend`, **live at
  `https://cleared-backend-production.up.railway.app`** with Supabase env vars
  set and `/health`, `/history`, `/auth/login` verified against production.
  Deploy: `cd backend && railway up --detach --service cleared-backend`
  (Dockerfile build, healthcheck `/health`).
- **Supabase MCP** wired in `.mcp.json` (token lives in the file locally — see
  Security notes). Full flow verified live: signup → login → authed
  `/check-listing` → row in Supabase → cached revisit in the extension.

Tests all green: 20 backend (`backend/.venv/bin/python -m pytest backend/tests`),
12 extension (`cd extension && node --test tests/*.test.js`), plus
`phase-1-tests/test_search_trace.py`.

## Decided (do not relitigate)

- **Deploy split: Vercel = website only, Railway = FastAPI API.** The Claude
  check call runs 1–3 min; Vercel serverless is a bad fit for it. The Cleared
  marketing/onboarding site goes on Vercel; the API stays on Railway.
- **Multi-user, invite-only** (user + girlfriend + friends). Supabase Auth,
  allowlist via `CLEARED_ALLOWED_EMAILS` env var.
- **Chrome Web Store ($5, unlisted)** is acceptable but deferred until closer
  to public readiness; unpacked install until then.

## Immediate next steps (in order)

1. **Point the extension at the Railway backend.** `extension/src/client.js`
   and `extension/src/auth.js` both hardcode `http://localhost:8000`. Make the
   backend URL configurable (e.g. `chrome.storage.local` key with the Railway
   URL as default and localhost override for dev), add
   `https://cleared-backend-production.up.railway.app/*` to
   `host_permissions` in `manifest.json`, update the client tests
   (`extension/tests/client.test.js` asserts the default URL). This was
   in-progress when the session ended — manifest was read, no edits made yet.
2. **Build the Cleared website → Vercel.** User's vision: (a) landing page,
   (b) sign up / create account (calls `POST /auth/signup` on the Railway
   API — allowlist gates it), (c) demo of how Cleared works, (d) extension
   download/install instructions, (e) then users go to Depop and use it.
   Match the care-label aesthetic (`artifacts/design/architecture.html`,
   `extension/styles.css` design tokens: calico/muslin/indigo/thread palette,
   Barlow Condensed + IBM Plex fonts).
3. **Verify the history page** at
   `https://cleared-backend-production.up.railway.app/history` (sign in, see
   past checks). Local reports exist under the user's account.
4. **Brand-gate live check on the web path** — Uniqlo listing (auth flag OFF)
   and Ralph Lauren (ON) via the extension, per phase-web checklist.
5. Later: "checked N× — see history" link in the panel; W5 screenshot-fallback
   page; Chrome Web Store listing + CORS lockdown to the store extension ID.

## Security notes (act on these)

- **Rotate the Supabase management token** at
  supabase.com/dashboard/account/tokens — it briefly entered git history
  (GitHub push protection blocked the push; the commit was amended, but
  treat it as burned). It currently sits in plaintext in the local
  `.mcp.json` (committed with placeholder `REPLACE_WITH_YOUR_TOKEN`; the
  user pasted the real one back in locally — don't commit that).
- `backend/.env.local` (gitignored) holds: `ANTHROPIC_API_KEY`,
  `CLEARED_MODEL`, `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`,
  `CLEARED_ALLOWED_EMAILS`, `SUPABASE_ACCESS_TOKEN`,
  `CLEARED_EXTENSION_ORIGIN` (unpacked dev ID
  `ebpjeilllcihcobaimedplbcbijfgcgh`), and a commented-out
  `CLEARED_SHARED_TOKEN` (legacy; only `/check` uses it now).
- Railway `cleared-backend` vars: `ANTHROPIC_API_KEY`, `CLEARED_MODEL`,
  `CLEARED_SHARED_TOKEN`, `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`,
  `CLEARED_ALLOWED_EMAILS`. **`CLEARED_EXTENSION_ORIGIN` is deliberately
  unset** → CORS falls back to `*`. Lock down once the extension ID is stable.
- Supabase email confirmations are **disabled** (invite-only tool).

## Gotchas learned this session

- The extension content script runs in the page context, so requests carry
  `Origin: https://www.depop.com` — that origin is in the CORS allowlist in
  `backend/app/main.py` when `CLEARED_EXTENSION_ORIGIN` is set.
- `backend/.venv` must be Python 3.13 (`/opt/homebrew/bin/python3.13`);
  a 3.9 venv fails on `str | None` annotations.
- Homebrew/node are NOT on the default PATH in Claude Code shells here — use
  `/opt/homebrew/bin/...` or export PATH first. Railway CLI installed via brew.
- uvicorn `--reload` does not re-read `.env.local`; restart it after env edits.
- `GET /reports?url=` only returns the newest report per listing (by design);
  the history page shows all rows.

## Git state

- `main` synced with `origin/main` at `27c3bc8`. Web track fully merged
  (`cleared-supabase` branch deleted local+remote).
- The **iOS track is active in parallel** — branch `worktree-phase-3-ios` +
  worktree `.claude/worktrees/railway-deploy` belong to another agent.
  Don't touch iOS files or that worktree.
- Identity: `kaladanw`. Repo: `github.com/kaladanw/Cleared`.

## Env quick-check before starting

```sh
cd /Users/kaladanwuke/Developer/Cleared
backend/.venv/bin/python -m pytest backend/tests -q
backend/.venv/bin/python phase-1-tests/test_search_trace.py
cd extension && /opt/homebrew/opt/node/bin/node --test tests/*.test.js
curl -s https://cleared-backend-production.up.railway.app/health
```
