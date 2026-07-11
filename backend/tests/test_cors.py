"""Unit checks for the CORS allowlist builder in app.main.

_build_cors_origins is a pure function extracted from module-level import-time
code so it can be exercised directly with different inputs, instead of
monkeypatching env vars and re-importing the FastAPI app (which only runs
add_middleware once, at import time).

Run from backend/:  python -m unittest tests.test_cors -v
"""

from __future__ import annotations

import unittest

from app.main import _build_cors_origins

_HARDCODED = ["https://www.depop.com", "http://localhost:8000", "http://localhost:3000"]


class CorsOriginsTests(unittest.TestCase):
    def test_no_env_vars_falls_back_to_wildcard(self):
        origins = _build_cors_origins("", "")
        self.assertEqual(origins, ["*"])

    def test_only_extension_origin_preserves_old_behavior(self):
        origins = _build_cors_origins("chrome-extension://abc123", "")
        self.assertNotIn("*", origins)
        self.assertIn("chrome-extension://abc123", origins)
        for hardcoded in _HARDCODED:
            self.assertIn(hardcoded, origins)

    def test_only_web_origins_single_value(self):
        origins = _build_cors_origins("", "https://cleared.vercel.app")
        self.assertNotIn("*", origins)
        self.assertIn("https://cleared.vercel.app", origins)
        for hardcoded in _HARDCODED:
            self.assertIn(hardcoded, origins)

    def test_web_origins_multiple_with_whitespace_and_empty_entries(self):
        origins = _build_cors_origins(
            "", "https://a.com, ,https://b.com,, https://c.com "
        )
        self.assertIn("https://a.com", origins)
        self.assertIn("https://b.com", origins)
        self.assertIn("https://c.com", origins)
        self.assertNotIn("", origins)
        self.assertNotIn(" ", origins)
        # No duplicate/empty noise, dedupe preserved.
        self.assertEqual(len(origins), len(set(origins)))

    def test_both_set_together_no_duplicates(self):
        origins = _build_cors_origins(
            "chrome-extension://abc123",
            "https://cleared.vercel.app,https://www.depop.com",
        )
        self.assertNotIn("*", origins)
        self.assertIn("chrome-extension://abc123", origins)
        self.assertIn("https://cleared.vercel.app", origins)
        self.assertIn("https://www.depop.com", origins)
        for hardcoded in _HARDCODED:
            self.assertIn(hardcoded, origins)
        # depop.com appears in both the web-origins list and the hardcoded
        # list -- must be deduped to a single entry.
        self.assertEqual(len(origins), len(set(origins)))


if __name__ == "__main__":
    unittest.main()
