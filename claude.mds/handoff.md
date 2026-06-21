# Session handoff — live working state

> Snapshot for a fresh Claude Code instance picking up mid-flight. Read the root
> `CLAUDE.md` first (it auto-loads and imports `phase-1.md`) for the locked
> decisions and architecture — this file is only the *live state* on top of that.
> Keep this file in `claude.mds/` while it reflects live state; future agents
> should find the current handoff here without digging through artifacts.
> Historical snapshots belong in `artifacts/handoffs/` when this context is
> superseded.

## Where we are

Phase 1 (the Claude vision → `CheckReport` engine) is **built and validated live**
(2026-06-21, Aelfric Eden polo — see `phase-1-tests/runs/run-0-12:58am/`). The
format + `web_search` single-call risk is **confirmed working** (memory:
`phase-1-validated`). Two follow-on improvements just landed on `main` via PRs:

- **Honest error handling** — `claude_check.py :: _user_error_for()` maps Anthropic
  SDK exceptions to calibrated `CheckReport.error` messages; "try again" only for
  truly transient failures. Tests: `backend/tests/test_error_mapping.py`
  (`cd backend && ./.venv/bin/python -m unittest tests.test_error_mapping`).
- **Eval + search-trace tooling** — `backend/app/search_trace.py` extracts the
  `web_search` queries+results the report used to discard; `run_check_traced()`
  hands back the raw msg. Harness in `phase-1-tests/`: `capture_run.py` (live
  capture → per-run folder), `review_run.py` (no-call side-by-side),
  `rubric-template.md` (7-criterion reasoning scorecard, with an unbuilt
  Reddit/social seam). Test: `./backend/.venv/bin/python phase-1-tests/test_search_trace.py`.

The web port has started:

- **W1 backend seam** — `POST /check-listing` accepts extension-provided
  `ListingFacts` + image URLs, fetches CDN images server-side, and threads seeded
  facts through the existing traced Claude call. Optional `X-Cleared-Token`
  enforcement is controlled by `CLEARED_SHARED_TOKEN`.
- **W2 extension skeleton** — `extension/` is a plain Manifest V3 Chrome
  extension. It reads Depop `__NEXT_DATA__` on product pages and logs extracted
  facts + image URLs; it does not call the backend yet.

## Immediate next step — the one Phase 1 loose end

Confirm the brand gate in the **OFF** direction. Drop a **non-fakeable-brand**
screenshot (e.g. Uniqlo) into `test_shots/`, then capture a real run and check
`auth_flag.applicable == false`:

```sh
cd backend && ./.venv/bin/uvicorn app.main:app --port 8000   # shell 1
# shell 2 — or use phase-1-tests/capture_run.py to also save the search trace:
./backend/.venv/bin/python phase-1-tests/capture_run.py --name run-1-uniqlo \
  --context "..." test_shots/<shot>.png
```

Needs `ANTHROPIC_API_KEY` in `backend/.env.local` AND **Console credits** (API
billing is separate from the claude.ai Pro plan — a real run costs pennies). The
brand gate ON direction is already proven (Aelfric Eden run-0). After this:
Phase 2 (tighten listing-trust / measurement detection), then Phase 3 (iOS app).

## Open threads (not blocking)

- **Web-port live validation** — still needs a real current Depop product page:
  confirm `__NEXT_DATA__` field names, confirm CDN image URLs return bytes
  server-side, then wire the extension button to `/check-listing`.
- **`subagent-coding` skill** — global skill at `~/.claude/skills/subagent-coding/`
  (also a private GitHub repo `kaladanw/claude-skills`). It's the playbook for
  spinning up coding subagents on branches/PRs — read it before doing that again.
  It has a dated "Lessons log"; append to it when you learn something.

## Git state

- Branch `main`; local work has moved past the older handoff commits with the web
  backend seam and extension skeleton.
- Both feature branches (`eval-system`, `billing-error-handling`) merged via PRs
  #1/#2 and deleted (local + remote). Only `main` + the web-plan branch remain.
- Identity: `kaladanw`. Repo: `github.com/kaladanw/Cleared`.

## Env notes

- Python 3.13, venv at `backend/.venv`. Run backend from `backend/`.
- Key in `backend/.env.local` (gitignored; loaded by `app/main.py`). Never echo it.
- Local screenshots go in `test_shots/` (gitignored). Test outputs: `phase-1-tests/runs/`.
