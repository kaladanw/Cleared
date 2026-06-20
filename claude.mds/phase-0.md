# Phase 0 — Backend skeleton + listing ingestion (COMPLETE, with a pivot)

> Per-phase brief for coding agents. The root `CLAUDE.md` imports the active phase.

## Goal

Stand up the backend and prove we can get a Depop listing's photos + facts into
the system. De-risk the riskiest piece (ingestion) before building anything else.

## What was built

- `backend/` — FastAPI app, `POST /check`, returns `CheckReport`.
- `backend/app/models.py` — the full report contract as Pydantic models (the
  spine for every later phase). **Do not casually change this schema.**
- `backend/app/depop.py` — a defensive Depop page extractor (`__NEXT_DATA__` →
  product object by shape, OpenGraph fallback). **Since removed** — it never
  cleared the 403; see the decision below.
- Boots on Python 3.13, clean error path, verified imports.

## The load-bearing finding (this is why Phase 0 mattered)

**Direct server-side fetching of Depop is impossible.** Confirmed empirically on
three real product URLs, with both a basic UA and a full Chrome header set:

```
HTTP 403  ·  <title>Forbidden - Depop</title>  ·  ~24KB flat block page
```

It is a **flat edge block** (not a solvable CAPTCHA/JS challenge). Implications:
- Direct `httpx`/`curl` fetch: dead.
- Self-hosted headless browser: also dead (same datacenter IP → same 403).
- Only a residential-proxy **scraper API** could punch through (paid + arms race).

Separately: the iOS app's **Share Sheet link is a Branch deep-link**
(`depop.app.link/...`) that resolves to the Depop *homepage*, not the product —
the product mapping lives on Branch's servers and is not recoverable over HTTP.

## Decision (overturns the earlier "URL direct-fetch" plan)

**v1 input = screenshot(s), not a URL.** The user shares listing screenshot(s)
via the iOS Share Sheet; a vision model reads them. This sidesteps *both* walls
(the 403 and the Branch link), needs no scraping/paid service, and has zero
Depop dependency — so the engine is fully buildable and testable offline.

`backend/app/depop.py` (and its `scripts/try_extract.py` tester) were **removed** —
the URL-fetch path is dead, so the code is gone too; recoverable from git history.

## Status

Complete. The ingestion question is answered: images in, not URLs. Phase 1
builds the Claude vision call that turns those images into a `CheckReport`.
