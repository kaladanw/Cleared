# Cleared — a Depop buyer's preflight check

A two-tap second opinion before you offer on a Depop listing: is the price fair,
is the listing trustworthy, and (for fakeable brands) what should you inspect?

Buyer-side, iOS, personal tool. See `architecture.html` (open in a browser) for
the design and the locked decisions; the full plan lives in the Preflight
session's plan file.

## Status

- **Phase 0 (in progress)** — backend skeleton + Depop listing extraction.
- Phase 1 — the Claude price read. Phase 2 — listing trust. Phase 3 — iOS app.

## Backend (Phase 0)

```sh
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Boot the API
uvicorn app.main:app --reload --port 8000

# In another shell — verify extraction against a REAL listing you're looking at:
curl -s -X POST localhost:8000/check \
  -H 'content-type: application/json' \
  -d '{"url":"https://www.depop.com/products/<...>/"}' | python3 -m json.tool

# Or run the extractor directly (more verbose):
python scripts/try_extract.py "https://www.depop.com/products/<...>/"
```

Phase 0 is "done" when a real listing returns its photos + price + title.
The Depop page shape is the one fragile unknown — if extraction comes back
empty, paste a listing URL and we'll adjust `app/depop.py` to match the live JSON.
