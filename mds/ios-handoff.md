# Session handoff — live working state (2026-07-11)

> Historical snapshot. It records the state at handoff time; use
> [`docs/current-state.md`](../docs/current-state.md) for the canonical current
> status and this file only for implementation context.

> Snapshot for a fresh coding agent (any harness — written to be self-contained)
> picking up mid-Phase-3. Read the root `CLAUDE.md` first (it auto-imports
> `mds/phase-3.md`, the active brief); this file is only the *live state*
> on top of that. Historical snapshots live in `artifacts/handoffs/`.

## Where we are

**Phase 3 (iOS app + Share Extension) slices S1–S5 are built and tested.**
The engine (phases 0–2) and the live Railway backend are done and stable.
S6 voice input remains intentionally deferred.

Work lives on branch **`worktree-phase-3-ios`** (worktree under
`.claude/worktrees/phase-3-ios/`). Commits so far:

- `0d0ea47` — Phase 3 brief added, made the active phase in `CLAUDE.md`.
- `27c2c61` — **S1 scaffold**: XcodeGen project (`ios/project.yml` → generated,
  gitignored `Cleared.xcodeproj`), host app + `ClearedShare` extension +
  `ClearedTests`, secrets via gitignored `ios/Secrets.xcconfig` (committed
  `Secrets.example.xcconfig` template). Verified: builds, launches on the
  iPhone 17 Pro simulator, live backend host visible in the UI.
- `d7d9d3e` — **S2 contract + client**: `ios/ClearedKit/CheckReport.swift`
  mirrors `backend/app/models.py` (snake_case via `.convertFromSnakeCase`);
  `MultipartBody` + `ClearedAPIClient` (multipart POST `/check`,
  `X-Cleared-Token`, 240 s timeout). Fixture-decode tests against copies of the
  phase-1 saved runs in `ios/ClearedTests/Fixtures/`.
- `1495bbb` — **S3 extension flow**:
  `ShareIngest` (NSItemProvider → UIImage, max 4), `UIImage+Downscale`
  (≤1600 px JPEG 0.8), `CheckSession` state machine
  (ingest → compose → checking → finished/failed), full SwiftUI panel in
  `ShareViewController.swift` with the staged "honest wait" progress view and
  an S3-placeholder report view.
- `f9c89ba` — **S4 care-label UI**: verdict-first stitched label, honest nullable
  prices, suggested offer, trust groups, tap-to-copy questions, brand-gated
  authenticity assist, and collapsed listing facts.
- **S5 validation + persistence**: successful reports save atomically to the
  shared app-group container and the host app re-displays the latest report.
  **All 8 unit tests green.**

## Live verification state (S5)

- iPhone 17 Pro Simulator builds, tests, installs, and launches. Both saved-run
  PNGs are loaded into Photos.
- Live Railway gate-ON: Aelfric Eden → `skip`, `auth_applicable: true`, two
  red flags, price estimates populated.
- Live Railway gate-OFF: Kenneth Cole → `negotiate`, `auth_applicable: false`,
  zero auth flags, price estimates populated.
- Wrong token → HTTP 401 with `Invalid Cleared token.`; the Swift client maps
  401 to the explicit token-rejected failure surface.
- The live Aelfric report was placed in the Simulator app-group container to
  verify the persistence/readback path. Simulator UI automation opened the
  host's Recent row and visually confirmed the full care-label rendering.
- No physical iPhone was connected, so personal-signing/device installation
  remains untested. Interactive Photos → share sheet selection was not
  automated in this harness; S3's Swift request path and S5's live payloads
  were verified separately against the same regression images.

## What remains

- **Distribution readiness:** `ios/RELEASE.md` is the practical signing,
  versioning, artwork, metadata, privacy, TestFlight, and App Store checklist.
  Host and extension versions now share `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` in `ios/project.yml`.
- **S6 (later) — voice.** Speech framework dictation → `user_context`.
- Optional manual smoke test: Photos → select a saved screenshot → Share →
  Cleared, then compare the panel to the already verified host rendering.
- Install on a physical iPhone when one is available.

## Cross-platform / distribution decision (2026-07-11)

- The web product may continue to ingest listing URLs; iOS remains deliberately
  screenshot-first. Do **not** try to reconstruct a Depop URL from seller
  details, item names, or pixels: it is ambiguous, fragile, and reintroduces
  the dependency on Depop's URL surface that iOS intentionally avoids.
- The eventual web ↔ iOS connection is through a Cleared-owned `check_id` and
  an authenticated user's report history. Both clients create/read the same
  owned report; neither needs the other client's source input.
- Later, a Cleared-domain report URL (for example `/check/<id>`) can be a
  Universal Link: it opens the installed iOS app or falls back to the Vercel
  web report. This needs user accounts, report ownership/authorization,
  backend persistence, and the domain's Associated Domains/AASA setup, so it
  is explicitly deferred from Phase 3.
- Distribution work now splits into two isolated branches/tasks: iOS release
  foundation from `worktree-phase-3-ios`, and Vercel launch + iOS handoff from
  `cleared-web`. The immediate web scope is a landing page plus privacy,
  support, and download/TestFlight CTA—not Universal Links yet.
- Before any public App Store release, replace the app-embedded shared backend
  token with real access control and usage limits. Keeping it only in an
  xcconfig keeps it out of git, not out of a distributed app binary.

## How to build / test / verify

```sh
cd ios
/opt/homebrew/bin/xcodegen generate     # after any project.yml change
xcodebuild -project Cleared.xcodeproj -scheme Cleared \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
# App: build, then
xcrun simctl install "iPhone 17 Pro" <DerivedData>/Build/Products/Debug-iphonesimulator/Cleared.app
xcrun simctl launch "iPhone 17 Pro" com.kaladanw.cleared
```

One cheap live check (~pennies, ~30–90 s): share a listing screenshot through
the extension, or curl `/check` with `-F 'images=@shot.png'` and the
`X-Cleared-Token` from `ios/Secrets.xcconfig`.

## Gotchas already paid for (don't re-learn)

- **Bundle IDs:** extension ID must be a *child* of the app ID
  (`com.kaladanw.cleared` / `.cleared.share`) — XcodeGen's derived sibling ID
  fails simulator install with "Mismatched bundle IDs".
- **xcconfig URLs:** `//` starts a comment; write `https:/$()/host`.
- **Swift 6 strict concurrency:** `NSExtensionContext`/`NSItemProvider` are not
  Sendable — `ShareIngest` is `@MainActor` for that reason.
- **Test resources:** fixture copies are colon-free renames; the originals'
  `12:58am` filenames upset resource copying.
- **Railway:** variables set with `--skip-deploys` don't reach the running
  container until a redeploy — that's how the dead-key incident happened.
- **This repo is PUBLIC.** `ios/Secrets.xcconfig` is gitignored and must stay
  that way; committed plists carry `$(VAR)` placeholders only. Verify with
  `git grep cleared-backend-production -- ios/` before pushing (expect no hits).

## Backend / infra facts

- Live URL: `https://cleared-backend-production.up.railway.app` (`/health` open;
  `/check` + `/check-listing` need `X-Cleared-Token`).
- Railway project `cleared` (`de910467-5a0a-4bb6-a806-8241975015ed`), service
  `cleared-backend`, env `production`. CLI: `~/.railway/bin/railway`.
- Secrets: token + URL in `ios/Secrets.xcconfig` (local only) and Railway
  variables. `ANTHROPIC_API_KEY` lives ONLY in Railway. Never echo secrets into
  a chat transcript or commit them — one key already had to be rotated.

## Git state

- Phase 3 branch: `worktree-phase-3-ios`; commits are pushed but do **not**
  merge to `main` until the physical-device smoke test passes. Identity:
  `kaladanw`; repo
  `github.com/kaladanw/Cleared` (public).
- The web-extension track (`extension/`, `cleared-web` branch) is separate —
  don't touch it from iOS work.
