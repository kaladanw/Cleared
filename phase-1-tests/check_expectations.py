"""Validate saved CheckReport runs against machine-checkable expectations.

This is a no-API companion to the human rubric. It catches mechanical
regressions such as an auth gate flipping, empty seller questions, or missing
measurement terms before a person spends time on qualitative review.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
RUNS_DIR = ROOT / "runs"
DEFAULT_EXPECTATIONS = ROOT / "expectations.json"


def main() -> int:
    args = _parse_args()
    expectations = json.loads(args.expectations.read_text())
    runs = expectations.get("runs", {})

    failures: list[str] = []
    for run_name, expectation in runs.items():
        report_path = RUNS_DIR / run_name / f"{run_name}-output.json"
        if not report_path.exists():
            failures.append(f"{run_name}: missing report {report_path}")
            continue
        report = json.loads(report_path.read_text())
        failures.extend(_check_report(run_name, report, expectation))

    if failures:
        print("FAIL")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print(f"PASS - {len(runs)} saved run expectation set(s) matched.")
    return 0


def _check_report(run_name: str, report: dict[str, Any], expectation: dict[str, Any]) -> list[str]:
    failures: list[str] = []

    if expectation.get("error_must_be_null") and report.get("error") is not None:
        failures.append(f"{run_name}: expected error to be null, got {report.get('error')!r}")

    auth = report.get("auth_flag") or {}
    if "auth_applicable" in expectation:
        actual = auth.get("applicable")
        expected = expectation["auth_applicable"]
        if actual is not expected:
            failures.append(f"{run_name}: expected auth_flag.applicable={expected}, got {actual}")

    if auth.get("applicable"):
        min_red_flags = expectation.get("min_auth_red_flags", 0)
        min_inspection_items = expectation.get("min_auth_inspection_items", 0)
        if len(auth.get("red_flags") or []) < min_red_flags:
            failures.append(f"{run_name}: expected at least {min_red_flags} auth red flag(s)")
        if len(auth.get("what_to_inspect") or []) < min_inspection_items:
            failures.append(f"{run_name}: expected at least {min_inspection_items} auth inspection item(s)")

    trust = report.get("listing_trust") or {}
    questions = trust.get("questions_to_ask") or []
    min_questions = expectation.get("min_questions")
    max_questions = expectation.get("max_questions")
    if min_questions is not None and len(questions) < min_questions:
        failures.append(f"{run_name}: expected at least {min_questions} questions, got {len(questions)}")
    if max_questions is not None and len(questions) > max_questions:
        failures.append(f"{run_name}: expected at most {max_questions} questions, got {len(questions)}")

    _require_terms(
        failures,
        run_name,
        "missing_info",
        trust.get("missing_info") or [],
        expectation.get("required_missing_info_terms") or [],
    )
    _require_terms(
        failures,
        run_name,
        "questions_to_ask",
        questions,
        expectation.get("required_question_terms") or [],
    )
    verdict = report.get("verdict") or {}
    _require_terms(
        failures,
        run_name,
        "verdict.one_line",
        [verdict.get("one_line") or ""],
        expectation.get("required_verdict_terms") or [],
    )

    return failures


def _require_terms(
    failures: list[str],
    run_name: str,
    field_name: str,
    values: list[str],
    terms: list[str],
) -> None:
    haystack = " ".join(values).lower()
    for term in terms:
        if term.lower() not in haystack:
            failures.append(f"{run_name}: {field_name} should mention {term!r}")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Check saved CheckReport runs against expectations.")
    parser.add_argument(
        "--expectations",
        type=Path,
        default=DEFAULT_EXPECTATIONS,
        help="Path to expectations JSON. Defaults to phase-1-tests/expectations.json.",
    )
    return parser.parse_args()


if __name__ == "__main__":
    raise SystemExit(main())
