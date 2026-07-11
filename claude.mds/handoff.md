# Session handoff — live working state (2026-07-11)

> Snapshot for a fresh coding agent (any harness — written to be self-contained)
> picking up mid-Phase-3. Read the root `CLAUDE.md` first (it auto-imports
> `claude.mds/phase-3.md`, the active brief); this file is only the *live state*
> on top of that. Historical snapshots live in `artifacts/handoffs/`.

## Where we are

**Phase 3 (iOS app + Share Extension) is mid-flight: slices S1–S3 are built,
tested, and committed; S4–S5 remain.** The engine (phases 0–2) and the live
Railway backend are done and stable.

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
- **S3 extension flow** (in working tree at handoff time; commit if not already):
  `ShareIngest` (NSItemProvider → UIImage, max 4), `UIImage+Downscale`
  (≤1600 px JPEG 0.8), `CheckSession` state machine
  (ingest → compose → checking → finished/failed), full SwiftUI panel in
  `ShareViewController.swift` with the staged "honest wait" progress view and
  an S3-placeholder report view. **All 8 unit tests green.**

## Live verification state (S3)

- The Swift client was proven against the **real** Railway backend from a
  macOS harness (job tmp dir, not in repo): loads the saved Aelfric Eden
  screenshot, re-encodes JPEG like the extension, posts with the real token.
- That harness first surfaced a real incident: the running deployment had a
  dead `ANTHROPIC_API_KEY` (rotated after a chat-transcript exposure;
  `--skip-deploys` meant the container kept the old value). Logs showed
  Anthropic 401 → the backend's calibrated "misconfigured on our end" error
  rendered correctly through the whole Swift stack — the error path is
  live-validated. The user re-set the key and redeployed; a fresh live check
  was still in flight when this handoff was written. **First task: rerun one
  live check** (see below) and confirm a real report comes back.

## What remains (per `claude.mds/phase-3.md`)

- **S4 — care-label UI.** Replace the placeholder `ReportView` in
  `ShareViewController.swift` with the full panel per the brief's section spec:
  verdict badge first, price read with null-price honesty ("couldn't verify",
  never 0), copyable trust questions, auth flag ONLY when `applicable`,
  listing facts collapsed last, styled to match
  `artifacts/design/architecture.html`.
- **S5 — E2E + handoff.** Push saved-run PNGs into the simulator
  (`xcrun simctl addmedia "iPhone 17 Pro" <png>`), share from Photos →
  Cleared, confirm live reports for gate-ON (Aelfric Eden) and gate-OFF
  (Kenneth Cole); wrong-token → honest 401 surface; update this file; merge to
  `main`. Device install if an iPhone is around (free Apple ID signing).
- **S6 (later) — voice.** Speech framework dictation → `user_context`.

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

- `main` is at `f5f6db1` (Railway deploy config + `/check` token gate), synced
  with `origin/main`. Phase 3 branch: `worktree-phase-3-ios` (local only, not
  pushed). Identity: `kaladanw`; repo `github.com/kaladanw/Cleared` (public).
- The web-extension track (`extension/`, `cleared-web` branch) is separate —
  don't touch it from iOS work.
