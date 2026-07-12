# Cleared

Cleared is a buyer-side second opinion for Depop listings. It returns one
calibrated `CheckReport`: listing facts, retail-anchored price read, listing
trust questions, brand-gated authenticity red flags, and a buy / negotiate /
skip recommendation. It is judgment-assist, never an authenticity verdict.

## Current product map

One FastAPI backend and Claude check engine serve two intentionally different
front doors:

- **iOS Share Extension** — a buyer shares one or more listing screenshots.
  The app uploads multipart images to `POST /check` with its development shared
  token, then renders the report as a care label. This path is built and
  simulator-validated; it is not yet distribution-ready.
- **Browser extension** — on a Depop product page, the extension reads listing
  facts in the browser and supplies CDN image URLs to JWT-protected
  `POST /check-listing`. The backend fetches those images, runs the same engine,
  and saves web reports for the signed-in user when persistence is configured.

`backend/app/models.py` defines `CheckReport`, the shared contract that both
surfaces render. The backend keeps the AI key server-side.

## Start here

- [Current-state snapshot](docs/current-state.md) — the evidence-backed status,
  service facts, and next validation gates.
- [Local visual snapshot](docs/current-state.html) — a self-contained diagram
  and phase view; open it locally in a browser. It is not a public product page.
- [Agent guidance](AGENTS.md) — project constraints and current implementation
  references.
- [iOS release runbook](ios/RELEASE.md) — the remaining device, security, and
  App Store gates.
- [Web onboarding notes](web/README.md) and [extension setup](extension/README.md).

## Local backend

```sh
cd backend
/opt/homebrew/bin/python3.13 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env  # add ANTHROPIC_API_KEY locally
uvicorn app.main:app --reload --port 8000
```

The screenshot endpoint accepts multipart images:

```sh
curl -s -X POST localhost:8000/check \
  -F 'images=@shot1.png' \
  -F 'images=@shot2.png' \
  -F 'user_context=it is a gift; I care more that it is legit than the price'
```

Do not treat configured Vercel files as evidence of a deployed site, or the
iOS simulator build as evidence of TestFlight/App Store readiness. The current
snapshot records those distinctions explicitly.
