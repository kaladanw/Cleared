# Cleared — current state

> Canonical snapshot for this repository, updated 2026-07-12. This is a
> local documentation artifact, not a launch announcement. For the visual
> companion, open [`current-state.html`](current-state.html) locally. For the
> function-and-contract reading guide, open [`code-map.html`](code-map.html).

## Status legend

| Label | Meaning |
|---|---|
| **Shipped in code** | Present on `main`; it may still need live, device, or launch validation. |
| **Validated** | A test, simulator run, recorded live check, or dated endpoint observation supports the claim. |
| **Deferred** | Deliberately out of the current implementation/release scope. |
| **User-only validation** | Requires the owner's browser, device, account, dashboard, domain, or release action. |

The status labels are intentionally not interchangeable. A local build is not a
deployment; a simulator pass is not physical-device or store readiness; a
configuration file is not evidence of a launched domain.

## What exists now

Cleared is a buyer-side, judgment-assist second opinion for Depop listings. Its
single output contract is [`CheckReport`](../backend/app/models.py): listing
facts, a retail-anchored price read, listing-trust concerns and questions,
brand-gated authenticity red flags, and a buy / negotiate / skip verdict.
Authenticity is never a verdict, and price estimates remain nullable when the
evidence is insufficient.

### Shared engine, separate front doors

| Surface | Input and endpoint | Access / persistence | Current status |
|---|---|---|---|
| **iOS host app + Share Extension** | Buyer shares up to four listing screenshots; multipart `POST /check` | Development `X-Cleared-Token`; latest report persists in the shared app-group container | **Shipped in code**; simulator and recorded live-report flow **validated**; not distribution-ready |
| **Browser extension** | On a Depop product page, extracts listing facts in-browser and sends facts + CDN image URLs to JSON `POST /check-listing` | JWT bearer auth; when Supabase is configured, web checks save/report history per signed-in user | **Shipped in code**; unit coverage and recorded live path **validated**; browser/user flow remains a user validation gate |
| **Vite onboarding site** | Invite sign-up/login and install/support/privacy surfaces call the Railway API directly | Browser session storage; separate from extension storage | **Shipped in code** and build-tested; no deployed Vercel domain or public launch is evidenced |

Both clients converge on the FastAPI backend and one Claude vision + `web_search`
call. The model key stays server-side. The web route has cleaner source facts and
full CDN photos; the iOS route deliberately stays screenshot-first because the
iOS share-link/Depop server-fetch path was not dependable.

```text
iOS screenshots ──> POST /check (development shared token) ──┐
                                                             ├─> Claude vision + web_search ─> CheckReport
Web facts + CDN URLs ─> POST /check-listing (JWT) ───────────┘                                  │
          └─> CDN image fetch; web report persistence when Supabase is configured                ├─> iOS care label
                                                                                                   └─> extension care label
```

## Evidence-backed status

### Shipped in code

- **Shared backend:** FastAPI exposes `/health`, screenshot `/check`, JWT web
  `/check-listing`, auth routes, cached-report/history routes, and the shared
  `CheckReport` schema. The web route fetches supplied CDN image URLs and
  best-effort persists a report when its configured Supabase client is available.
- **Web product:** Manifest V3 extension, login/JWT storage, in-page care-label
  rendering, cached revisit behavior, and a Vite onboarding site are in `main`.
- **iOS product:** XcodeGen project, host app, Share Extension, shared Swift
  `CheckReport` mirror/client/views, screenshot ingest/downscale, request state,
  care-label rendering, and last-report app-group persistence are merged through
  S5.
- **Release preparation:** `ios/RELEASE.md` contains the signing, privacy,
  metadata, TestFlight, and App Store runbook. It is a checklist, not evidence
  that those actions happened.

### Validated

- **Main-checkout audit (2026-07-11):** backend suite **25 pytest passed**, and
  the search-trace verification passed. Browser-extension unit tests **16/16
  passed**. Web tests **9 passed** and `vite build` succeeded.
- **iOS recorded validation:** all **8** iOS unit tests were green; the iPhone
  17 Pro Simulator built, installed, and launched. Recorded live reports covered
  a brand-gate-on Aelfric Eden case, a gate-off Kenneth Cole case, invalid-token
  401 handling, and saved-report readback/rendering in the host app.
- **Railway observation (2026-07-11):**
  `https://cleared-backend-production.up.railway.app/health` and `/history`
  returned HTTP 200 during the audit. This verifies those public responses at
  that time only; it does not reveal or prove private service configuration.
- **Recorded handoffs:** document a live web auth/check/persistence path and
  Supabase-backed web report history. Treat that as recorded validation, not an
  assertion that every current browser/account configuration is still live.

The isolated documentation worktree may not contain the backend virtualenv or
web dependencies. That is a local tooling limitation, not a regression of the
recorded main-checkout validation above.

### Deferred

- **iOS voice input (S6):** speech-to-`user_context` is intentionally later.
- **Universal Links and Cleared-owned check IDs:** require an authenticated,
  authorized cross-surface report model and associated-domain work; they are not
  implied by the current history implementation.
- **Public distribution:** Chrome Web Store publication, real iOS auth/rate and
  spend limits, TestFlight, and App Store release are not shipped.
- **Public web launch:** Vercel configuration/source exists, but no deployed
  domain, final support channel, or public launch is evidenced.

### User-only validation gates

| Owner / environment | Gate |
|---|---|
| **Browser + Depop session** | Load the unpacked extension against current Depop markup; confirm extraction, sign-in, check, cached revisit/history, and brand-gate behavior on real listings. |
| **Domain / dashboards** | Create or verify the Vercel project/domain, DNS, final support and privacy URLs, and production CORS only when the intended hostnames are known. |
| **Physical iPhone + Apple account** | Run Photos -> Share -> Cleared with production signing; then complete release runbook actions and TestFlight/App Store review steps. |
| **Release/security design** | Replace the iOS app-embedded shared development token with real authentication, authorization, and per-user/device rate/spend controls before distribution. |

## Why the phases mattered

| Track | Why it mattered | Status today |
|---|---|---|
| **Phase 0 — ingestion** | Proved server-side Depop page fetching was blocked and the iOS share link was unusable; made screenshots the reliable iOS input. | Decision retained; backend skeleton shipped. |
| **Phase 1 — vision/report call** | Proved one structured Claude vision call can use `web_search` and return `CheckReport` without inventing a second orchestration layer. | Shipped and live-validated in recorded runs. |
| **Phase 2 — listing trust** | Tightened the report's concerns, questions, and expectation checks so the output is useful rather than merely plausible. | Shipped in the shared engine/eval tooling. |
| **Parallel web track** | Identified the browser extension as the way to read listing facts client-side while the backend fetches only CDN photos. | Shipped in code; browser/account validation remains. |
| **Phase 3 — iOS S1–S5** | Built the Share Extension, care-label panel, client, persistence, and simulator/live-report validation. | Merged in `main`; device and distribution gates remain. |

Historical phase briefs and handoffs live in [`../mds/`](../mds/). They preserve
the implementation trail; this page resolves their older “current” wording.

## Services and deployment facts

| Service | Evidence-backed fact | Do not infer |
|---|---|---|
| **Railway** | The backend public `/health` and `/history` endpoints returned HTTP 200 on 2026-07-11. | Environment variables, service internals, continued uptime, or release readiness. |
| **Supabase** | The code contains JWT/auth and per-user web report persistence; recorded handoffs describe a live path. | That the iOS path shares this persistence or that every current account/configuration works. |
| **Vercel** | Vite source/config and deployment instructions exist; the site build passed in the main-checkout audit. | A deployed domain, public availability, or launch approval. |
| **Apple distribution** | A release runbook and simulator-validated app exist. | TestFlight enrollment, App Store review, or a safe distributed authentication model. |

## Resume safely

1. Start with this page, then read the relevant surface runbook and inspect the
   current branch/history before trusting an older handoff.
2. For an engineering change, preserve the two-front-door separation and
   `CheckReport` schema; do not collapse routes merely because their outputs
   match.
3. For a launch decision, complete the corresponding user/device gate above
   rather than promoting a recorded or simulator validation to “live.”
