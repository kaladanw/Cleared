# Run review — run-1-9:32am

Fill this in after looking at the report + search trace side by side
(`python phase-1-tests/review_run.py run-1-9:32am`). Score each criterion
pass / weak / fail and jot the real-world reason. These criteria come from
actual Depop buying, not abstractions — the point is to catch reasoning that
*sounds* right but isn't grounded.

| # | Criterion | Score (pass/weak/fail) | Notes |
|---|-----------|------------------------|-------|
| 1 | **Price is grounded in real comps** — the retail/used numbers trace to actual search results, not invented. Check the trace: did sources actually back the figures? | pass | The trace searched Kenneth Cole leather jacket retail and used resale pages across Kenneth Cole, eBay, Poshmark, Amazon, Walmart, Mercari, and Etsy. The report correctly caveats that retail is a category estimate, not an exact vintage SKU. |
| 2 | **Product-specific, not brand-level** — sizing/fit nuance is about THIS item (this style runs oversized, etc.), not a generic brand prior dressed up as specifics. | pass | It did not invent style-specific sizing claims. The fit warning is tied to this screenshot/listing: vintage jacket, size L only, no measurements. |
| 3 | **Caught missing measurements** — flagged absent pit-to-pit / length / shoulder, since fit is the real risk at this price. | pass | Missing measurements are the first trust issue, with pit-to-pit, length, sleeve, and shoulder called out. |
| 4 | **Questions are send-ready** — 2–4 concrete seller questions a beginner could paste as-is. | pass | Four concrete questions: measurements, genuine vs faux/bonded leather, condition close-ups, and zipper function. |
| 5 | **Auth flag calibrated** — fires only for a fakeable brand, never claims "authentic," confidence is honest (not falsely high). | pass | Kenneth Cole is not in the fakeable set; `auth_flag.applicable=false` with empty red flags and inspection list. This confirms the OFF direction. |
| 6 | **Verdict is defensible** — buy/negotiate/skip follows from the above and respects the buyer's stated context. | pass | Buy verdict follows from $12 shipped vs the used/new ranges, while still prioritizing fit and material confirmation before purchase. |
| 7 | **Search effort matched the question** — did it search enough (and the right queries) for this item, or under/over-search? See `search_count` / `result_count`. | weak | Five searches and 50 sources is enough, but the last two queries are duplicates and several sources are broad category pages. Good enough for this low-price jacket, but not especially efficient. |

## Reddit / social signal (future — leave the seam, don't build yet)

When social grounding lands, add rows here for: does community sentiment on this
brand/style (sizing complaints, known dupes, fair-resale-price chatter) line up
with what the report claimed?

- [ ] _placeholder — not implemented_

## Overall

- **Verdict on the run:** keep
- **Real-world note (your own buying instinct vs the report):** The report is appropriately enthusiastic about a $12 jacket but keeps the real risk focused on fit, material, and condition. Brand gate OFF behavior is correct for Phase 1.
