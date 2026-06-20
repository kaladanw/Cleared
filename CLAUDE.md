# Cleared — coding-agent guide

A buyer-side iOS assistant: a two-tap second opinion before you offer on a Depop
listing. Personal, single-user tool. Born from a Preflight session that
pressure-tested the idea against reality; the design artifact is
`architecture.html` (open in a browser).

## Per-phase briefs (read the one you're working on)

Detailed, phase-scoped guidance lives in `claude.mds/phase-N.md`. The active
phase is imported below so it auto-loads; read the others directly as needed.

- `claude.mds/phase-0.md` — backend skeleton + ingestion (done; why input = images)
- `claude.mds/phase-1.md` — the Claude vision → report call (current)

@claude.mds/phase-1.md

## Locked decisions (do not relitigate — each cost real back-and-forth)

- **Buyer-side, single-user, personal.** Not seller automation, not multi-user.
- **iOS, on-demand "summon" model.** No always-on overlay — the iOS sandbox
  forbids reading another app's screen. Interaction = a Share Extension that pops
  a result panel, plus a mic for voice context.
- **Input = screenshot(s), NOT a URL.** Depop flat-edge-blocks (403) every
  server-side fetch, and the app share link is an unusable Branch deep-link. See
  `claude.mds/phase-0.md`. Vision reads the screenshots.
- **Authenticity = judgment-assist red flags, never a verdict.** Brand-conditional
  (fires only for fakeable brands; silent for Uniqlo/jorts/etc.). A confident
  false "authentic" is worse than no tool.
- **Pricing = retail-anchored + light used read via `web_search`.** For $5–40 mass
  brands the real question is "is this even a discount vs new?" No gated comp APIs.
- **Intelligence = thin backend proxy + Claude.** The API key never ships in the app.
- **Model = `claude-opus-4-8`** (vision, adaptive thinking). `claude-sonnet-4-6`
  is the cost lever (`CLEARED_MODEL` env). At personal volume, pennies/check.

## The report contract

One object, `CheckReport` in `backend/app/models.py`, returned by the backend and
rendered by the app as the "care label" panel. It is the spine of the build —
every phase serves filling it in honestly. Sections: `listingFacts`, `priceRead`,
`listingTrust`, `authFlag` (brand-gated), `verdict`.

## Stack & layout

- `backend/` — Python 3.13 + FastAPI. One endpoint, `POST /check` (multipart:
  listing images + optional `user_context`). Anthropic Python SDK, vision over the
  images, `web_search` server tool, structured output = `CheckReport`.
- `backend/app/` — `models.py` (contract), `claude_check.py` (the one Claude call),
  `main.py` (the endpoint). The URL-fetch path (`depop.py`) was removed — see
  `claude.mds/phase-0.md` for why.
- iOS app (Swift/SwiftUI + Share Extension) — Phase 3, not built yet.

## Run the backend

```sh
cd backend
/opt/homebrew/bin/python3.13 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # add ANTHROPIC_API_KEY
uvicorn app.main:app --reload --port 8000
# Test with real listing screenshots:
curl -s -X POST localhost:8000/check \
  -F 'images=@shot1.png' -F 'images=@shot2.png' \
  -F 'user_context=it is a gift, I care more that it is legit than the price' \
  | python3 -m json.tool
```

## Working principles (from the Preflight session)

Reality over assumption (verify external facts live — that's how the 403 wall was
found before it cost a week). Start simple, earn complexity. Honest pushback over
agreeableness. The report must never fabricate a price or claim authenticity it
can't support — calibrated, honest output is the whole point.
