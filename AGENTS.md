# Cleared — coding-agent guide

Cleared is a buyer-side second opinion for Depop listings. It is a personal,
invite-oriented tool with two deliberately separate client paths feeding one
backend and one `CheckReport` contract. Read [docs/current-state.md](docs/current-state.md)
before making status or infrastructure claims.

## Read order

1. `README.md` and `docs/current-state.md` for the current, canonical snapshot.
2. `mds/NOTION_HANDOFF.md` for the human-operated handoff workflow. Do not call
   or write Notion; emit a compact handoff packet only when appropriate.
3. The relevant historical implementation brief in `mds/`.
4. `ios/RELEASE.md`, `web/README.md`, or `extension/README.md` when working on
   that surface.

`mds/` holds phase briefs and historical handoffs. It is useful context, not
the canonical live-status source.

## Architecture that must stay true

- `backend/app/models.py` owns `CheckReport`: `listingFacts`, `priceRead`,
  `listingTrust`, brand-gated `authFlag`, and `verdict`.
- **iOS:** screenshot(s) -> multipart `POST /check` -> report. The Share
  Extension uses a development shared token from an ignored xcconfig; it is not
  suitable for distributed builds.
- **Web:** extension-extracted listing facts + CDN image URLs -> JWT
  `POST /check-listing` -> report. Web checks can persist per-user reports when
  Supabase is configured.
- Both paths converge on the same Claude vision + `web_search` engine. The API
  key never ships in either client.
- Authenticity output is judgment-assist red flags only, never a verdict.
  Retail/used prices must remain honestly nullable when evidence is insufficient.

## Working constraints

- Do not reintroduce server-side Depop product-page fetching: it was empirically
  blocked. The iOS input is images; the browser extension reads page data in the
  buyer's browser and the backend fetches only supplied CDN images.
- Keep secrets out of tracked files, logs, documents, and chat. In particular,
  do not expose development shared tokens, service keys, or API keys.
- `flags/` is gitignored for strictly human actions (account setup, DNS, domain
  choices). Do not place engineering tasks there or attempt human-only actions.
- Treat phase briefs and handoffs as historical records when they conflict with
  `docs/current-state.md`; correct current claims in canonical docs rather than
  rewriting history.

## Useful validation

```sh
# Backend, where its Python 3.13 environment is available
backend/.venv/bin/python -m pytest backend/tests -q
backend/.venv/bin/python phase-1-tests/test_search_trace.py

# Browser extension
node --test extension/tests/*.test.js

# Vite onboarding site
cd web && npm test && npm run build
```

The current-state snapshot records the last known successful runs and any
worktree-local dependency limitations. Never infer deployment or distribution
status solely from a local build.
