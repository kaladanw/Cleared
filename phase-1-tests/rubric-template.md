# Run review — <RUN_NAME>

Fill this in after looking at the report + search trace side by side
(`python phase-1-tests/review_run.py <RUN_NAME>`). Score each criterion
pass / weak / fail and jot the real-world reason. These criteria come from
actual Depop buying, not abstractions — the point is to catch reasoning that
*sounds* right but isn't grounded.

| # | Criterion | Score (pass/weak/fail) | Notes |
|---|-----------|------------------------|-------|
| 1 | **Price is grounded in real comps** — the retail/used numbers trace to actual search results, not invented. Check the trace: did sources actually back the figures? | | |
| 2 | **Product-specific, not brand-level** — sizing/fit nuance is about THIS item (this style runs oversized, etc.), not a generic brand prior dressed up as specifics. | | |
| 3 | **Caught missing measurements** — flagged absent pit-to-pit / length / shoulder, since fit is the real risk at this price. | | |
| 4 | **Questions are send-ready** — 2–4 concrete seller questions a beginner could paste as-is. | | |
| 5 | **Auth flag calibrated** — fires only for a fakeable brand, never claims "authentic," confidence is honest (not falsely high). | | |
| 6 | **Verdict is defensible** — buy/negotiate/skip follows from the above and respects the buyer's stated context. | | |
| 7 | **Search effort matched the question** — did it search enough (and the right queries) for this item, or under/over-search? See `search_count` / `result_count`. | | |

## Reddit / social signal (future — leave the seam, don't build yet)

When social grounding lands, add rows here for: does community sentiment on this
brand/style (sizing complaints, known dupes, fair-resale-price chatter) line up
with what the report claimed?

- [ ] _placeholder — not implemented_

## Overall

- **Verdict on the run:** <keep / tune prompt / tune brand gate / other>
- **Real-world note (your own buying instinct vs the report):**
