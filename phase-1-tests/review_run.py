"""Present a captured run side by side: the CheckReport next to what it searched.

No API calls — reads the JSON a capture (or any past run) left on disk. The whole
point is to put the model's CLAIMS next to its EVIDENCE so the human can spot
reasoning that sounds grounded but isn't: a $72 retail figure with no matching
search source, "runs oversized" with no product-specific query, etc.

    backend/.venv/bin/python phase-1-tests/review_run.py run-0-12:58am

If a run has no search-trace.json yet (e.g. run-0, captured before this tooling),
it still prints the report and says so.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

RUNS_DIR = Path(__file__).resolve().parent / "runs"


def main() -> int:
    args = _parse_args()
    run_dir = RUNS_DIR / args.name
    if not run_dir.is_dir():
        print(f"No such run: {run_dir}")
        return 1

    report = _load_json(run_dir, suffix="-output.json")
    trace = _load_json(run_dir, suffix="-search-trace.json")

    _section("REPORT  " + args.name)
    if report is None:
        print("(no *-output.json found)")
    else:
        _print_report(report)

    _section("WEB SEARCH TRACE")
    if trace is None:
        print("(no *-search-trace.json — this run predates trace capture, or none ran)")
    else:
        _print_trace(trace)

    rubric = run_dir / f"{args.name}-rubric.md"
    _section("RUBRIC")
    print(f"{'(exists) ' if rubric.exists() else '(not yet) '}{rubric}")
    print("Fill it in: score each criterion pass/weak/fail against the two sections above.")
    return 0


# --- printing -------------------------------------------------------------


def _print_report(r: dict[str, Any]) -> None:
    if r.get("error"):
        print(f"ERROR: {r['error']}")
        return
    facts = r.get("listing_facts", {})
    price = r.get("price_read", {})
    trust = r.get("listing_trust", {})
    auth = r.get("auth_flag", {})
    verdict = r.get("verdict", {})

    print(f"Item:   {facts.get('brand')} — {facts.get('model_or_name')}")
    print(f"Size:   {facts.get('size')}   Cond: {facts.get('listed_condition')}   "
          f"Asking: {facts.get('asking_price')} {facts.get('currency')}")

    print("\nPRICE")
    print(f"  retail={price.get('retail_estimate')}  "
          f"used={price.get('used_estimate_low')}–{price.get('used_estimate_high')}  "
          f"fairness={price.get('fairness')}  "
          f"offer={price.get('suggested_offer_low')}–{price.get('suggested_offer_high')}")
    print(f"  reasoning: {price.get('reasoning')}")

    print("\nTRUST")
    _bullets("missing_info", trust.get("missing_info"))
    _bullets("concerns", trust.get("concerns"))
    _bullets("questions_to_ask", trust.get("questions_to_ask"))

    print("\nAUTH")
    if not auth.get("applicable"):
        print("  applicable=False (brand-gated off)")
    else:
        print(f"  applicable=True  confidence={auth.get('confidence')}")
        _bullets("red_flags", auth.get("red_flags"))
        _bullets("what_to_inspect", auth.get("what_to_inspect"))

    print("\nVERDICT")
    print(f"  {verdict.get('recommendation')}: {verdict.get('one_line')}")
    if verdict.get("user_context"):
        print(f"  context: {verdict.get('user_context')}")


def _print_trace(t: dict[str, Any]) -> None:
    print(f"{t.get('search_count', 0)} search(es), {t.get('result_count', 0)} source(s) total")
    if t.get("note"):
        print(f"note: {t['note']}")
    for i, s in enumerate(t.get("searches", []), 1):
        print(f"\n  [{i}] query: {s.get('query')!r}")
        if "error" in s:
            print(f"      ERROR: {s['error']}")
            continue
        results = s.get("results", [])
        if not results:
            print("      (no sources returned)")
        for row in results:
            age = f"  [{row['page_age']}]" if row.get("page_age") else ""
            print(f"      - {row.get('title')}{age}")
            print(f"        {row.get('url')}")


def _bullets(label: str, items: Any) -> None:
    items = items or []
    print(f"  {label}: {'(none)' if not items else ''}")
    for it in items:
        print(f"    - {it}")


# --- io helpers -----------------------------------------------------------


def _load_json(run_dir: Path, suffix: str) -> dict[str, Any] | None:
    matches = sorted(run_dir.glob(f"*{suffix}"))
    if not matches:
        return None
    return json.loads(matches[0].read_text())


def _section(title: str) -> None:
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)


def _parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Review a captured run: report + search trace, side by side.")
    ap.add_argument("name", help="Run folder name under phase-1-tests/runs/.")
    return ap.parse_args()


if __name__ == "__main__":
    raise SystemExit(main())
