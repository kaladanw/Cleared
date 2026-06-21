# Phase 2 Listing Trust Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve `CheckReport` listing-trust outputs by tightening trust instructions and adding machine-checkable eval expectations for saved runs.

**Architecture:** Keep the one-call backend unchanged. Add no-API eval tooling under `phase-1-tests/` that validates saved report JSON against checked-in expectations, then update the prompt and rubric so Phase 2 trust quality is explicit and reviewable.

**Tech Stack:** Python 3.13, FastAPI backend, Pydantic `CheckReport`, standard-library `json`/`unittest`, existing `phase-1-tests` harness.

---

## File Map

- Modify `backend/app/claude_check.py`: tighten `_SYSTEM` listing-trust instructions only.
- Create `backend/tests/test_phase2_prompt.py`: no-API tests proving the prompt names Phase 2 trust requirements.
- Create `phase-1-tests/check_expectations.py`: CLI and importable helpers for validating saved run JSON.
- Create `phase-1-tests/expectations.json`: machine-checkable expectations for `run-0-12:58am` and `run-1-9:32am`.
- Create `phase-1-tests/test_expectations.py`: no-API tests for the checker.
- Modify `phase-1-tests/rubric-template.md`: make Phase 2 trust scoring more explicit.
- Modify `phase-1-tests/README.md`: document the expectation checker and how it complements manual rubric review.

## Task 1: Add Saved-Run Expectation Checker

**Files:**
- Create: `phase-1-tests/check_expectations.py`
- Create: `phase-1-tests/test_expectations.py`
- Create: `phase-1-tests/expectations.json`

- [ ] **Step 1: Write the failing checker tests**

Create `phase-1-tests/test_expectations.py` with tests that load `check_expectations.py` by path and call `_check_report`.

```python
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parent / "check_expectations.py"
_SPEC = importlib.util.spec_from_file_location("check_expectations", _SCRIPT)
assert _SPEC is not None and _SPEC.loader is not None
check_expectations = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = check_expectations
_SPEC.loader.exec_module(check_expectations)


class ExpectationCheckerTests(unittest.TestCase):
    def test_accepts_report_that_matches_expectations(self):
        report = {
            "error": None,
            "listing_trust": {
                "missing_info": ["No pit-to-pit, length, or sleeve measurements."],
                "questions_to_ask": [
                    "Can you share pit-to-pit and length measurements?",
                    "Any damage or stains?",
                ],
            },
            "auth_flag": {
                "applicable": False,
                "red_flags": [],
                "what_to_inspect": [],
            },
            "verdict": {"one_line": "Good price, but confirm fit first."},
        }
        expectation = {
            "error_must_be_null": True,
            "auth_applicable": False,
            "min_questions": 2,
            "max_questions": 4,
            "required_missing_info_terms": ["pit-to-pit", "length", "sleeve"],
            "required_question_terms": ["pit-to-pit", "length"],
            "required_verdict_terms": ["fit"],
        }

        failures = check_expectations._check_report("sample-run", report, expectation)

        self.assertEqual(failures, [])

    def test_reports_each_failed_expectation(self):
        report = {
            "error": "bad",
            "listing_trust": {"missing_info": ["No photos."], "questions_to_ask": []},
            "auth_flag": {"applicable": True, "red_flags": [], "what_to_inspect": []},
            "verdict": {"one_line": "Buy it."},
        }
        expectation = {
            "error_must_be_null": True,
            "auth_applicable": False,
            "min_questions": 2,
            "max_questions": 4,
            "required_missing_info_terms": ["pit-to-pit"],
            "required_question_terms": ["length"],
            "required_verdict_terms": ["fit"],
        }

        failures = check_expectations._check_report("sample-run", report, expectation)

        joined = "\n".join(failures)
        self.assertIn("expected error to be null", joined)
        self.assertIn("expected auth_flag.applicable=False", joined)
        self.assertIn("expected at least 2 questions", joined)
        self.assertIn("missing_info should mention 'pit-to-pit'", joined)
        self.assertIn("questions_to_ask should mention 'length'", joined)
        self.assertIn("verdict.one_line should mention 'fit'", joined)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test to verify RED**

Run:

```bash
backend/.venv/bin/python phase-1-tests/test_expectations.py
```

Expected: FAIL because `phase-1-tests/check_expectations.py` does not exist.

- [ ] **Step 3: Implement the minimal checker**

Create `phase-1-tests/check_expectations.py`.

```python
"""Validate saved CheckReport runs against small machine-checkable expectations.

This is a no-API companion to the human rubric. It catches mechanical regressions
such as an auth gate flipping, empty seller questions, or missing measurement
terms before a person spends time on qualitative review.
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

    print(f"PASS — {len(runs)} saved run expectation set(s) matched.")
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
        if len(auth.get("red_flags") or []) < expectation.get("min_auth_red_flags", 0):
            failures.append(f"{run_name}: expected at least {expectation['min_auth_red_flags']} auth red flag(s)")
        if len(auth.get("what_to_inspect") or []) < expectation.get("min_auth_inspection_items", 0):
            failures.append(
                f"{run_name}: expected at least {expectation['min_auth_inspection_items']} auth inspection item(s)"
            )

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
```

- [ ] **Step 4: Add expectations for existing saved runs**

Create `phase-1-tests/expectations.json`.

```json
{
    "runs": {
        "run-0-12:58am": {
            "error_must_be_null": true,
            "auth_applicable": true,
            "min_auth_red_flags": 1,
            "min_auth_inspection_items": 2,
            "min_questions": 2,
            "max_questions": 4,
            "required_missing_info_terms": ["pit-to-pit", "length", "shoulder"],
            "required_question_terms": ["pit-to-pit", "length"],
            "required_verdict_terms": ["measurements"]
        },
        "run-1-9:32am": {
            "error_must_be_null": true,
            "auth_applicable": false,
            "min_questions": 2,
            "max_questions": 4,
            "required_missing_info_terms": ["pit-to-pit", "length", "sleeve"],
            "required_question_terms": ["pit-to-pit", "length"],
            "required_verdict_terms": ["fit"]
        }
    }
}
```

- [ ] **Step 5: Run the checker tests and saved-run checker**

Run:

```bash
backend/.venv/bin/python phase-1-tests/test_expectations.py
backend/.venv/bin/python phase-1-tests/check_expectations.py
```

Expected: both PASS.

- [ ] **Step 6: Commit Task 1**

```bash
git add phase-1-tests/check_expectations.py phase-1-tests/test_expectations.py phase-1-tests/expectations.json
git commit -m "Add saved-run expectation checks"
```

## Task 2: Tighten Phase 2 Prompt Instructions

**Files:**
- Modify: `backend/app/claude_check.py`
- Create: `backend/tests/test_phase2_prompt.py`

- [ ] **Step 1: Write failing prompt tests**

Create `backend/tests/test_phase2_prompt.py`.

```python
"""No-API checks for Phase 2 listing-trust prompt requirements."""

from __future__ import annotations

import unittest

from app import claude_check


class Phase2PromptTests(unittest.TestCase):
    def test_prompt_names_category_specific_measurements(self):
        text = claude_check._SYSTEM.lower()
        for term in ("pit-to-pit", "length", "sleeve", "shoulder", "waist", "inseam", "rise"):
            with self.subTest(term=term):
                self.assertIn(term, text)

    def test_prompt_requires_item_specific_send_ready_questions(self):
        text = claude_check._SYSTEM.lower()
        for phrase in ("send-ready", "item-specific", "not generic", "material", "condition uncertainty"):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, text)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the prompt tests to verify RED**

Run:

```bash
cd backend && ./.venv/bin/python -m unittest tests.test_phase2_prompt -v
```

Expected: FAIL because `_SYSTEM` does not yet include all Phase 2 terms.

- [ ] **Step 3: Tighten `_SYSTEM` listing-trust instructions**

Modify only section `2) LISTING TRUST.` in `backend/app/claude_check.py` so it reads:

```python
2) LISTING TRUST.
   - The biggest real risk at this price isn't fakes, it's a bad listing. Treat
     fit, condition uncertainty, material uncertainty, and photo sufficiency as
     separate trust questions.
   - Missing measurements are a first-class risk. For tops/jackets/sweaters,
     look for pit-to-pit, length, sleeve, and shoulder. For pants/shorts/jorts,
     look for waist, inseam, rise, and leg opening. If relevant measurements are
     absent or only a letter size is shown, add them to `missing_info`.
   - Flag vague condition claims when the photos do not prove them: no close-ups
     of cuffs/collars/hems, lining, tags, stains, pilling, cracking, peeling,
     zipper function, or fabric wear.
   - Write 2–4 item-specific, send-ready `questions_to_ask` the buyer can paste
     to the seller. Make them concrete ("Can you share pit-to-pit and length
     laid flat?"), not generic ("Can you provide more info?").
```

- [ ] **Step 4: Run prompt tests to verify GREEN**

Run:

```bash
cd backend && ./.venv/bin/python -m unittest tests.test_phase2_prompt -v
```

Expected: PASS.

- [ ] **Step 5: Commit Task 2**

```bash
git add backend/app/claude_check.py backend/tests/test_phase2_prompt.py
git commit -m "Tighten listing trust prompt"
```

## Task 3: Update Eval Rubric And README

**Files:**
- Modify: `phase-1-tests/rubric-template.md`
- Modify: `phase-1-tests/README.md`

- [ ] **Step 1: Update rubric trust rows**

Replace rows 2-4 in `phase-1-tests/rubric-template.md` with more Phase 2-specific checks:

```markdown
| 2 | **Trust is item-specific, not generic** — fit/material/condition concerns are about THIS item and screenshot, not broad brand guesses. | | |
| 3 | **Caught missing measurements** — flagged category-relevant measurements: tops/jackets need pit-to-pit, length, sleeve/shoulder; pants/shorts need waist, inseam, rise. | | |
| 4 | **Questions are send-ready** — 2–4 concrete seller questions a beginner could paste as-is, covering measurements plus the most important material/condition/photo gap. | | |
```

- [ ] **Step 2: Document expectation checker**

In `phase-1-tests/README.md`, add an item for:

```markdown
- `expectations.json` + `check_expectations.py` — machine-checkable saved-run
  expectations for obvious regressions (auth gate, question count, required
  measurement terms). Run this before manual rubric review.
```

Add a command section:

````markdown
## Check saved-run expectations (no API call)

```sh
backend/.venv/bin/python phase-1-tests/check_expectations.py
```
````

- [ ] **Step 3: Run no-API eval checks**

Run:

```bash
backend/.venv/bin/python phase-1-tests/check_expectations.py
backend/.venv/bin/python phase-1-tests/test_search_trace.py
backend/.venv/bin/python phase-1-tests/test_expectations.py
```

Expected: all PASS.

- [ ] **Step 4: Commit Task 3**

```bash
git add phase-1-tests/rubric-template.md phase-1-tests/README.md
git commit -m "Document Phase 2 eval checks"
```

## Task 4: Final Verification And PR

**Files:**
- No new files.

- [ ] **Step 1: Run backend tests**

Run:

```bash
cd backend && ./.venv/bin/python -m unittest discover -v
```

Expected: all tests pass.

- [ ] **Step 2: Run Phase 1/2 no-API eval checks**

Run:

```bash
backend/.venv/bin/python phase-1-tests/test_search_trace.py
backend/.venv/bin/python phase-1-tests/test_expectations.py
backend/.venv/bin/python phase-1-tests/check_expectations.py
```

Expected: all PASS.

- [ ] **Step 3: Check git conflict and status state**

Run:

```bash
git diff --name-only --diff-filter=U
git ls-files -u
rg -n '^(<<<<<<<|=======|>>>>>>>)' -g '!backend/.venv/**' -g '!node_modules/**' .
git status --short --branch
```

Expected: no unmerged files or conflict markers; branch contains only intended changes.

- [ ] **Step 4: Push branch and open PR**

Run:

```bash
git push -u origin claude/phase-2-listing-trust
gh pr create \
  --base main \
  --head claude/phase-2-listing-trust \
  --title "Improve Phase 2 listing trust evals" \
  --body "## Summary
- tighten listing-trust prompt requirements around measurements, material/condition uncertainty, and send-ready seller questions
- add machine-checkable saved-run expectations for obvious CheckReport regressions
- update Phase 1/2 eval docs and rubric

## Verification
- cd backend && ./.venv/bin/python -m unittest discover -v
- backend/.venv/bin/python phase-1-tests/test_search_trace.py
- backend/.venv/bin/python phase-1-tests/test_expectations.py
- backend/.venv/bin/python phase-1-tests/check_expectations.py"
```

Expected: branch pushed and PR URL returned.
