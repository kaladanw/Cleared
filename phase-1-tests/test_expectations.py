"""No-API tests for saved-run expectation checks."""

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
