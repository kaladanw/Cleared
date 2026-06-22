# phase-1-tests — eval + introspection for CheckReport reasoning

A lightweight way to judge whether the one Claude call's reasoning is *grounded*,
not just well-phrased. The CheckReport is what the app renders; this tooling also
surfaces the **web_search trace** the model used to get there, so you can tell
whether the $72 retail figure and the "runs oversized" note came from real comps
or from brand-level priors dressed up as specifics.

Strictly additive: the `/check` endpoint and the `CheckReport` contract are
unchanged. The trace is a separate debug artifact.

## Files

- `../backend/app/search_trace.py` — `extract_search_trace(msg.content)`: walks a
  Claude response, pulls out each `web_search` query + the sources it returned
  (or the error). Pure, no API calls.
- `../backend/app/claude_check.py` — `run_check_traced(images, ctx)` returns
  `(report, raw_msg)` so the trace is reachable; `run_check` is unchanged.
- `capture_run.py` — the only script that makes a **live** call. Runs a check on
  screenshots and writes report + trace + a seeded rubric into a new run folder.
- `review_run.py` — no API call. Prints a run's report next to its search trace
  for side-by-side judgment, and points at the rubric.
- `rubric-template.md` — the per-run scorecard (criteria from real Depop buying).
- `expectations.json` + `check_expectations.py` — machine-checkable saved-run
  expectations for obvious regressions (auth gate, question count, required
  measurement terms). Run this before manual rubric review.
- `test_search_trace.py` — structural validation of the extractor against the
  real anthropic SDK block types. No API call.
- `runs/<name>/` — one folder per run: `*-output.json`, `*-search-trace.json`,
  `*-rubric.md`, and the source screenshots.

## Capture a real run (costs money — needs ANTHROPIC_API_KEY)

```sh
cd /Users/kaladanwuke/Developer/cleared
backend/.venv/bin/python phase-1-tests/capture_run.py \
    --name run-1-ralph-lauren \
    --context "it's a gift, I care more that it's legit than the price" \
    shot1.png shot2.png
```

## Review a run (no API call)

```sh
backend/.venv/bin/python phase-1-tests/review_run.py run-1-ralph-lauren
```

Then open `runs/run-1-ralph-lauren/*-rubric.md` and score it.

## Check saved-run expectations (no API call)

```sh
backend/.venv/bin/python phase-1-tests/check_expectations.py
```

This catches mechanical regressions before manual review, such as an auth gate
flipping, missing seller questions, or measurement terms disappearing from runs
where fit info is absent.

## Validate the extractor (no API call)

```sh
backend/.venv/bin/python phase-1-tests/test_search_trace.py
```

## Future seam — Reddit / social signal

The rubric has a placeholder section for community-sentiment grounding (sizing
complaints, known dupes, fair-resale chatter). Not built. When it lands, the
natural home is a `social_trace.py` sibling to `search_trace.py` and extra rubric
rows — keep it the same additive, capture-then-review shape.
