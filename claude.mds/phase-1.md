# Phase 1 — The Claude vision call (the core value) — CURRENT

> Per-phase brief for coding agents. Imported by the root `CLAUDE.md`.

## Goal

Turn listing screenshot(s) into a real `CheckReport`: read the item, anchor the
price on retail via web search, and produce a buy / negotiate / skip read. This
is the heart of the product — if this is good, the rest is packaging.

## How it works (one call, no orchestration)

`backend/app/claude_check.py :: run_check(images, user_context)`:

1. Build the user message: the screenshot(s) as base64 `image` blocks + a short
   instruction (and the buyer's voice context, if any).
2. One `client.messages.parse(...)` call:
   - `model = claude-opus-4-8` (env `CLEARED_MODEL` overrides; sonnet = cost lever)
   - `thinking = {"type": "adaptive"}`
   - `tools = [web_search_20260209]` — server-side retail/used price lookup
   - `output_format = CheckReport` — structured output guarantees the shape
3. `_enforce_brand_gate()` silences the authenticity flag for non-fakeable brands
   as a belt-and-suspenders backstop to the prompt.

The endpoint is `POST /check` (multipart: `images[]` + optional `user_context`).

## Guardrails baked into the system prompt (keep them)

- Price: use web_search; **never fabricate** a retail/used price — leave it null
  and explain uncertainty if search is inconclusive.
- Trust: flag missing measurements / vague condition; write ready-to-send seller
  questions.
- Authenticity: judgment-assist only, fakeable brands only, **never claim
  authentic**. List of fakeable brands lives in `FAKEABLE_BRANDS` (tunable).

## Known risk to validate with a live key

Combining structured output (`output_format`) with the server-side `web_search`
tool in a single call is the documented-clean approach but unverified here (no
API key was available at build time). If the API rejects format + server tools
together, split into two passes: (a) search + reason, (b) format into
`CheckReport`. Keep it one call while it works.

## Verification (needs ANTHROPIC_API_KEY + a real screenshot)

```sh
curl -s -X POST localhost:8000/check \
  -F 'images=@uniqlo_listing.png' \
  -F 'user_context=it is a gift, I care more that it is legit than the price' \
  | python3 -m json.tool
```

Done when: a real listing screenshot returns a sane `priceRead` (retail anchor +
fairness + offer range), useful `questionsToAsk`, a correctly gated `authFlag`,
and a defensible verdict. Test a Uniqlo item (auth flag OFF) and a Ralph Lauren
item (auth flag ON) to confirm the brand gate both ways.

## Next: Phase 2

Tighten listing-trust (measurement detection, question quality). Then Phase 3 —
the iOS app + Share Extension + voice.
