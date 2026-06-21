# Phase 2 Listing Trust Design

## Goal

Phase 2 tightens the screenshot-based iOS backend's listing-trust read. Phase 1
proved that one Claude vision call can fill `CheckReport`, use `web_search`, and
gate authenticity correctly. Phase 2 should make the trust section more reliable
for the buyer's real risk: unclear fit, vague condition, insufficient photos, and
seller questions that are too generic to send.

The user-facing outcome is still the same `CheckReport` returned by `POST
/check`. This work must not change the report schema, add a second model call, or
touch the web extension track.

## Scope

In scope:

- Tighten the Phase 1 prompt's listing-trust instructions.
- Make missing measurements a first-class trust concern for clothing screenshots.
- Improve questions so they are concrete, send-ready, and specific to the item.
- Preserve the existing one-call `run_check` / `run_check_traced` architecture.
- Extend evaluation artifacts so saved runs can be reviewed for trust quality.
- Add no-API regression checks where they can prove structure or prompt content.

Out of scope:

- Changing `CheckReport` or adding new response fields.
- Building iOS UI or Share Extension code.
- Changing `extension/` or `/check-listing`.
- Adding a second Claude call, OCR layer, or deterministic computer-vision pass.
- Building the future Reddit/social signal seam.

## Architecture

The implementation stays inside the existing backend and eval harness:

- `backend/app/claude_check.py` remains the only model-call path.
- `_SYSTEM` becomes more explicit about trust criteria:
  - clothing listings should flag missing pit-to-pit, length, sleeve, waist,
    inseam, rise, or shoulder measurements when relevant;
  - category-specific questions should match the item type;
  - material and condition uncertainty should be called out when photos/listing
    text do not prove them;
  - questions should be written as buyer-sendable messages, not internal notes.
- `phase-1-tests/rubric-template.md` expands the trust rows enough that future
  runs can distinguish price quality from trust quality.
- Saved run artifacts remain the proof format: report JSON, search trace, copied
  screenshot, and filled rubric.

No schema changes are needed because the existing `ListingTrust` fields already
carry the Phase 2 output: `missing_info`, `concerns`, and `questions_to_ask`.

## Data Flow

The screenshot flow remains unchanged:

1. `POST /check` receives one or more listing screenshots and optional
   `user_context`.
2. `run_check_traced` sends images plus the tightened system/user instructions to
   Claude.
3. Claude returns the same structured `CheckReport`.
4. `_enforce_brand_gate` still post-processes only authenticity.
5. The eval harness captures the report and trace for review.

Phase 2 does not add post-processing to `listing_trust`. If later live runs show
Claude still omits obvious missing measurements, a narrow normalizer can be
considered as a separate follow-up. For this PR, the safer move is to make the
model's task explicit and evaluate whether the single-call path is enough.

## Error Handling

The existing error handling remains authoritative. Phase 2 should not change
`_user_error_for`, endpoint behavior, or the early exits for missing API keys and
missing screenshots. Prompt changes must not mask errors or produce partial trust
claims when `CheckReport.error` is set.

## Testing And Verification

No-API checks:

- Backend unittest discovery stays green.
- `phase-1-tests/test_search_trace.py` stays green.
- New or updated tests should verify prompt/rubric structure without calling the
  live API when practical.

Live/eval checks:

- Re-review the saved Aelfric Eden and Kenneth Cole runs against the updated
  rubric.
- If another screenshot is available, capture one Phase 2 run where measurements
  are missing and confirm:
  - `listing_trust.missing_info` includes relevant measurements;
  - `questions_to_ask` contains 2-4 send-ready questions;
  - the verdict accounts for fit/condition uncertainty without overreacting;
  - `auth_flag` behavior is unchanged.

## PR Boundary

The PR should be named around Phase 2 listing trust. It should include the design
spec, prompt/eval/test changes, and any new Phase 2 run artifacts created for
verification. It should not include web-extension changes or unrelated cleanup.
