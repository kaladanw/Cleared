# Session handoff — live working state

> Snapshot for a fresh Claude Code instance picking up mid-flight. Read the root
> `CLAUDE.md` first (it auto-loads and imports `phase-1.md`) for the locked
> decisions and architecture — this file is only the *live state* on top of that.
> Keep this file in `claude.mds/` while it reflects live state; future agents
> should find the current handoff here without digging through artifacts.
> Historical snapshots belong in `artifacts/handoffs/` when this context is
> superseded.

## Where we are

Phase 1 (the Claude vision → `CheckReport` engine) is **built and validated live**.
The format + `web_search` single-call risk is **confirmed working** (memory:
`phase-1-validated`).

Live validation runs:

- **Brand gate ON** — Aelfric Eden polo, saved at
  `phase-1-tests/runs/run-0-12:58am/`.
- **Brand gate OFF** — Kenneth Cole leather jacket, saved at
  `phase-1-tests/runs/run-1-9:32am/`; confirms `auth_flag.applicable == false`
  with empty red flags / inspection list for a non-fakeable brand.

Follow-on backend/eval improvements are merged on `main`:

- **Honest error handling** — `claude_check.py :: _user_error_for()` maps Anthropic
  SDK exceptions to calibrated `CheckReport.error` messages; "try again" only for
  truly transient failures. Tests: `backend/tests/test_error_mapping.py`
  (`cd backend && ./.venv/bin/python -m unittest tests.test_error_mapping`).
- **Eval + search-trace tooling** — `backend/app/search_trace.py` extracts the
  `web_search` queries+results the report used to discard; `run_check_traced()`
  hands back the raw msg. Harness in `phase-1-tests/`: `capture_run.py` (live
  capture → per-run folder), `review_run.py` (no-call side-by-side),
  `rubric-template.md` (7-criterion reasoning scorecard, with an unbuilt
  Reddit/social seam). Test:
  `./backend/.venv/bin/python phase-1-tests/test_search_trace.py`.
- **Phase 2 listing-trust tightening** — PR #5 added more explicit prompt
  instructions for missing measurements, material/condition uncertainty, photo
  sufficiency, and send-ready seller questions. It also added no-API saved-run
  expectations: `phase-1-tests/check_expectations.py`,
  `phase-1-tests/expectations.json`, and `phase-1-tests/test_expectations.py`.
  Run:
  `./backend/.venv/bin/python phase-1-tests/check_expectations.py`.

The web port has started:

- **W1 backend seam** — `POST /check-listing` accepts extension-provided
  `ListingFacts` + image URLs, fetches CDN images server-side, and threads seeded
  facts through the existing traced Claude call. Optional `X-Cleared-Token`
  enforcement is controlled by `CLEARED_SHARED_TOKEN`.
- **W2 extension skeleton** — `extension/` is a plain Manifest V3 Chrome
  extension. It reads Depop `__NEXT_DATA__` on product pages and logs extracted
  facts + image URLs; it does not call the backend yet.
- **W3 branch in progress** — branch `claude/web-wire-extension` wires the
  extension to local `/check-listing`: injected button, optional buyer context,
  POST to `http://localhost:8000/check-listing`, and in-page `CheckReport`
  rendering.

## Immediate next step

The iOS/backend track is ready to move toward **Phase 3: iOS app + Share
Extension + voice context**. Before coding Phase 3, the next agent should read:

1. `CLAUDE.md`
2. all files in `claude.mds/`
3. `docs/superpowers/specs/2026-06-21-phase-2-listing-trust-design.md`
4. `docs/superpowers/plans/2026-06-21-phase-2-listing-trust.md`

For a quick backend confidence check before starting iOS work:

```sh
cd /Users/kaladanwuke/Developer/cleared
cd backend && ./.venv/bin/python -m unittest discover -v
cd ..
backend/.venv/bin/python phase-1-tests/test_search_trace.py
backend/.venv/bin/python phase-1-tests/test_expectations.py
backend/.venv/bin/python phase-1-tests/check_expectations.py
```

If the next task is another backend eval slice instead of iOS UI, keep it on a
PR branch and do not touch `extension/` unless explicitly working on the web
track.

## Open threads (not blocking)

- **Web-port live validation** — still needs a real current Depop product page:
  confirm `__NEXT_DATA__` field names, confirm CDN image URLs return bytes
  server-side, then click through the injected extension panel against the local
  backend.
- **Live Phase 2 eval** — the prompt/rubric/expectation harness is in place, but
  no new paid Phase 2 live run has been captured after the prompt change. If the
  next backend-focused agent has a fresh screenshot and Console credits, capture a
  new run and review it with the updated rubric.
- **`subagent-coding` skill** — global skill at `~/.claude/skills/subagent-coding/`
  (also a private GitHub repo `kaladanw/claude-skills`). It's the playbook for
  spinning up coding subagents on branches/PRs — read it before doing that again.
  It has a dated "Lessons log"; append to it when you learn something.

## Git state

- Branch `main`, synced with `origin/main` at `0f247c2` after merging PR #5
  (`claude/phase-2-listing-trust`).
- Both feature branches (`eval-system`, `billing-error-handling`) merged via PRs
  #1/#2 and deleted (local + remote). Web track branches may still exist while
  that work is active.
- Identity: `kaladanw`. Repo: `github.com/kaladanw/Cleared`.

## Env notes

- Python 3.13, venv at `backend/.venv`. Run backend from `backend/`.
- Key in `backend/.env.local` (gitignored; loaded by `app/main.py`). Never echo it.
- Local screenshots go in `test_shots/` (gitignored). Test outputs: `phase-1-tests/runs/`.
