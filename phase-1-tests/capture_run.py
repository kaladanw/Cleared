"""Capture a real run: report + web_search trace, into a fresh run folder.

This is the ONE script that makes a live Anthropic call (it costs money — run it
deliberately). It exists so the human can see not just the final CheckReport but
what the model actually searched on the way there, and judge whether the reasoning
is grounded.

Usage (needs ANTHROPIC_API_KEY in backend/.env.local or the env):

    cd /Users/kaladanwuke/Developer/cleared
    backend/.venv/bin/python phase-1-tests/capture_run.py \
        --name run-1-ralph-lauren \
        --context "it is a gift, I care more that it is legit than the price" \
        shot1.png shot2.png

Writes into phase-1-tests/runs/<name>/:
    <name>-output.json         the CheckReport (same shape the app renders)
    <name>-search-trace.json   the web_search queries + returned sources
    <name>-rubric.md           a copy of the rubric template, ready to fill in
    plus the source screenshots, copied in for the record.

Then review side by side:
    backend/.venv/bin/python phase-1-tests/review_run.py <name>
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

# Make `backend/app` importable and load backend/.env.local for the key.
_ROOT = Path(__file__).resolve().parent.parent
_BACKEND = _ROOT / "backend"
sys.path.insert(0, str(_BACKEND))

from dotenv import load_dotenv  # noqa: E402

load_dotenv(_BACKEND / ".env.local")

from app.claude_check import run_check_traced  # noqa: E402
from app.search_trace import extract_search_trace  # noqa: E402

RUNS_DIR = Path(__file__).resolve().parent / "runs"
RUBRIC_TEMPLATE = Path(__file__).resolve().parent / "rubric-template.md"

_MEDIA_BY_SUFFIX = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".gif": "image/gif",
}


def main() -> int:
    args = _parse_args()
    run_dir = RUNS_DIR / args.name
    if run_dir.exists() and not args.force:
        print(f"Run folder already exists: {run_dir} (use --force to overwrite)")
        return 1
    run_dir.mkdir(parents=True, exist_ok=True)

    images = _load_images(args.images)
    print(f"Calling Claude with {len(images)} screenshot(s)…")
    report, msg = run_check_traced(images, user_context=args.context)

    # The report — same shape the app renders.
    report_path = run_dir / f"{args.name}-output.json"
    report_path.write_text(json.dumps(report.model_dump(), indent=4))

    # The web_search trace — the debug artifact this whole tool is about.
    if msg is None:
        trace = {"searches": [], "search_count": 0, "result_count": 0,
                 "note": "No raw message (early-out or API error). See report.error."}
    else:
        trace = extract_search_trace(msg.content)
    trace_path = run_dir / f"{args.name}-search-trace.json"
    trace_path.write_text(json.dumps(trace, indent=4))

    # Seed a rubric for this run, copy the screenshots in for the record.
    rubric_path = run_dir / f"{args.name}-rubric.md"
    if not rubric_path.exists():
        rubric_path.write_text(
            RUBRIC_TEMPLATE.read_text().replace("<RUN_NAME>", args.name)
        )
    for src in args.images:
        dst = run_dir / Path(src).name
        if Path(src).resolve() != dst.resolve():
            shutil.copy2(src, dst)

    print(f"Wrote: {report_path.name}, {trace_path.name}, {rubric_path.name}")
    print(f"Searches: {trace.get('search_count')}, sources: {trace.get('result_count')}")
    print(f"Review:  backend/.venv/bin/python phase-1-tests/review_run.py {args.name}")
    return 0


def _load_images(paths: list[str]) -> list[tuple[bytes, str]]:
    loaded: list[tuple[bytes, str]] = []
    for p in paths:
        path = Path(p)
        media = _MEDIA_BY_SUFFIX.get(path.suffix.lower(), "image/jpeg")
        loaded.append((path.read_bytes(), media))
    return loaded


def _parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Capture a real CheckReport run + its web_search trace.")
    ap.add_argument("images", nargs="+", help="Listing screenshot file(s).")
    ap.add_argument("--name", required=True, help="Run folder name, e.g. run-1-ralph-lauren.")
    ap.add_argument("--context", default=None, help="Buyer's voice context, if any.")
    ap.add_argument("--force", action="store_true", help="Overwrite an existing run folder.")
    return ap.parse_args()


if __name__ == "__main__":
    raise SystemExit(main())
