# Cleared — coding-agent guide

Read `AGENTS.md` first. It is the operational adapter for this repository; this
file remains the portable guide for agents that conventionally load `CLAUDE.md`.

The canonical current snapshot is `docs/current-state.md`. Phase briefs and
handoffs are now under `mds/`; they document decisions and implementation
history but may be superseded by the current-state snapshot.

## Non-negotiable product contract

- `CheckReport` in `backend/app/models.py` is the shared response and care-label
  UI contract: listing facts, price read, listing trust, brand-gated authenticity
  red flags, and verdict.
- iOS is screenshot-first: the Share Extension sends multipart images to
  `POST /check` with a development shared token.
- Web is extension-first: it sends browser-extracted facts plus CDN image URLs
  to JWT-protected `POST /check-listing`; web reports may persist per signed-in
  user when Supabase is configured.
- Both paths use the same backend Claude vision + `web_search` engine. Keep the
  AI key server-side, authenticity assist calibrated, and price evidence honest.

## Current references

- `mds/phase-0.md` — screenshot-input decision and backend skeleton.
- `mds/phase-1.md` — single Claude vision/report call.
- `mds/phase-web.md` — parallel browser-extension track.
- `mds/phase-3.md` — iOS Share Extension slices and deferred voice work.
- `ios/RELEASE.md` — distribution gates.
- `mds/NOTION_HANDOFF.md` — text-only handoff packet rules; never write Notion.

Do not use phase wording alone to claim something is current, shipped, deployed,
or ready for distribution. Verify against `docs/current-state.md`, current code,
and git history.
