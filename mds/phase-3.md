# Phase 3 — iOS app + Share Extension (the front door) — CURRENT

> Per-phase brief for coding agents. Imported by the root `CLAUDE.md`. The
> engine is done (phases 0–2); this phase is packaging it into the two-tap
> "summon" flow the product was designed around.

## Goal

Share Depop listing screenshot(s) from the iOS share sheet → the Cleared panel
pops up → one tap (plus optional typed context) → a real `CheckReport` rendered
as the care-label panel. Against the **live Railway backend**, not localhost.

**Deferred to a later slice:** voice/mic context (Speech framework dictation
feeding the same `user_context` field the text box fills). Locked decision says
it ships eventually; it is not in the first build.

## The live backend (deployed 2026-07-02)

- URL: `https://cleared-backend-production.up.railway.app`
- `POST /check` (multipart `images[]` + `user_context`) — now **requires** the
  `X-Cleared-Token` header; requests without it get 401.
- `GET /health` — liveness probe, no token.
- Deploy config: `backend/Dockerfile` + `backend/railway.json`; Railway project
  `cleared`, service `cleared-backend`. Env vars (incl. the token and
  `ANTHROPIC_API_KEY`) live in Railway variables, never in git.
- A check takes **~30–90 s** (Opus + adaptive thinking + web_search). The
  client must be designed around that: a visible progress state, a generous
  URLSession timeout (≥180 s), and the share sheet staying open for the wait.

## Secrets (the repo is PUBLIC — this is load-bearing)

Mirror the backend's `.env.local` / `.env.example` pattern in Xcode's idiom:

- `ios/Secrets.xcconfig` — **gitignored.** Holds `CLEARED_BACKEND_URL` and
  `CLEARED_SHARED_TOKEN`. Flows into the app via build settings → Info.plist
  keys → read at runtime from the bundle.
- `ios/Secrets.example.xcconfig` — committed template with placeholders.
- **Never** put the real token or URL in a tracked Swift/plist/yml file. A
  hardcoded token in a public repo = an open proxy to a paid Anthropic key.

## Layout & tooling (decided)

```
ios/
  project.yml            # XcodeGen manifest — the .xcodeproj is generated, gitignored
  Secrets.example.xcconfig
  Cleared/               # host app target (SwiftUI, deliberately minimal)
  ClearedShare/          # the Share Extension target (the actual product)
  ClearedKit/            # shared sources compiled into both targets:
                         #   models (CheckReport mirror), API client, report views
  ClearedTests/          # unit tests (decode fixtures, multipart encoding)
```

- **XcodeGen** (`brew install xcodegen`) generates `Cleared.xcodeproj` from
  `project.yml`. Rationale: `.xcodeproj` files are merge-hostile and unreviewable;
  a YAML manifest is diffable and agent-friendly. Regenerate with
  `xcodegen generate` after editing `project.yml`; gitignore the `.xcodeproj`.
- Swift 6 / SwiftUI, iOS 17+ deployment target. No third-party dependencies —
  URLSession, Foundation, and SwiftUI cover everything this app does.
- The host app is a shell: it explains the share-sheet flow, shows backend
  health, and re-displays the last saved report. All real interaction happens
  in the extension. Do not grow the host app.

## The Share Extension flow

1. **Activation:** images only, up to 4
   (`NSExtensionActivationSupportsImageWithMaxCount = 4`). The user screenshots
   a Depop listing and taps Cleared in the share sheet.
2. **Ingest:** `NSItemProvider` → image data. Screenshots arrive as PNG; downscale
   to max ~1600 px long edge and re-encode JPEG ~0.8 before upload — keeps the
   upload small and the vision tokens sane without hurting legibility.
3. **Compose:** optional one-line text field — "anything the buyer cares about?"
   (maps to `user_context`). One primary button: **Check**.
4. **Call:** multipart POST to `/check` with `X-Cleared-Token`. Progress state
   that acknowledges the honest wait ("reading the listing… checking prices…").
5. **Render:** the returned `CheckReport` as the care-label panel (below).
   If `report.error` is set, show *that message* prominently and nothing else —
   the backend's calibrated errors are the UX, don't re-wrap them.
6. **Done** dismisses the extension. Persist the last report JSON to the shared
   app-group container so the host app can re-show it.

## The care-label panel (render the contract, hide what's absent)

Sections map 1:1 to `CheckReport` (`backend/app/models.py` is the source of
truth — JSON is snake_case; decode with `.convertFromSnakeCase` or CodingKeys):

- **Verdict** first: recommendation badge (buy / negotiate / skip) + `one_line`.
- **Price read:** retail anchor, used range, fairness, suggested offer range,
  and the reasoning text. Null prices render as "couldn't verify" — never as 0
  or a made-up number (same honesty rule as the backend prompt).
- **Listing trust:** `missing_info`, `concerns`, and `questions_to_ask` as
  copyable rows (tap a question → copied, ready to paste to the seller).
- **Auth flag:** render ONLY when `applicable == true`. When it fires: red
  flags + what-to-inspect list + confidence. Never present it as a verdict.
- **Listing facts** last, collapsed: what the model read off the screenshots.
- Style: match `artifacts/design/architecture.html` so iOS and web read as one
  product.

## Build order (slices — one worktree branch, commit per slice)

- **S1 — Scaffold.** `project.yml`, three source dirs, secrets xcconfig wiring,
  app-group entitlement, empty-but-launching host app + extension.
  *Done when `xcodebuild build` succeeds for both targets on the simulator.*
- **S2 — Contract + client.** Swift `CheckReport` models mirroring
  `models.py`; multipart `URLSession` client with the token header + long
  timeout. **No-API tests:** decode the saved fixtures
  (`phase-1-tests/runs/run-0-12:58am/run-0-12:58am-output.json` and run-1's) —
  the same saved-run-as-regression-guard trick the backend eval uses; assert
  multipart body shape. *Done when `xcodebuild test` is green.*
- **S3 — Extension flow.** Ingest → downscale → compose → call → raw-ish
  result. *Done when sharing a saved-run PNG from simulator Photos returns a
  live report end-to-end.*
- **S4 — Care-label UI.** The full panel per the section spec above, including
  the error state and null-price honesty. *Done when both saved-run screenshots
  render correct, gated, honest panels.*
- **S5 — E2E validation + handoff.** Fresh listing screenshot, both gate
  directions live (fakeable brand ON, non-fakeable OFF), wrong-token → honest
  401 surface, update `mds/handoff.md`. Real-device install is part of
  this slice if a device is available (free Apple ID personal signing is
  enough; no paid account needed).
- **S6 (later) — Voice.** Speech framework dictation → `user_context`.

## Verification assets already in the repo

- `phase-1-tests/runs/run-0-12:58am/Aelfric_eden_cleared_test.png` (gate ON)
  and `phase-1-tests/runs/run-1-9:32am/kc_leather_jacket_test.png` (gate OFF) —
  push into the simulator with `xcrun simctl addmedia`, then share from Photos.
- The paired `*-output.json` files are the decoding fixtures for S2.

## Environment prerequisites (blockers if absent)

- **Full Xcode** (App Store), not just Command Line Tools — confirmed absent
  2026-07-11; must be installed before S1 can build. After install:
  `sudo xcode-select -s /Applications/Xcode.app` + first-launch iOS SDK download.
- `xcodegen` via Homebrew.
- Live checks in S3/S5 hit the real backend: pennies per check, needs the
  Railway service up and the token in `Secrets.xcconfig`.
