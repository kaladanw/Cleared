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
