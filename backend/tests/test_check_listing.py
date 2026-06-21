"""No-network tests for the web listing input seam.

Run from backend/:  python -m unittest tests.test_check_listing -v
"""

from __future__ import annotations

import os
import unittest
from unittest import mock

import httpx
from fastapi.testclient import TestClient

from app import claude_check
from app.models import CheckReport, ListingFacts, Verdict


class FetchImagesTests(unittest.TestCase):
    def test_fetch_images_keeps_only_allowed_images_and_derives_media_type(self):
        from app.images import fetch_images

        responses = [
            httpx.Response(
                200,
                headers={"content-type": "image/jpeg; charset=binary"},
                content=b"jpeg-bytes",
            ),
            httpx.Response(
                200,
                headers={"content-type": "text/html"},
                content=b"<html>not an image</html>",
            ),
            httpx.Response(500, content=b"nope"),
            httpx.Response(
                200,
                headers={"content-type": "application/octet-stream"},
                content=b"png-bytes",
            ),
            httpx.Response(
                200,
                headers={"content-type": "image/gif"},
                content=b"this-is-too-large",
            ),
        ]

        with mock.patch("app.images.httpx.get", side_effect=responses) as get:
            images = fetch_images(
                [
                    "https://media-photos.depop.com/a.jpg",
                    "https://media-photos.depop.com/not-image",
                    "https://media-photos.depop.com/500.jpg",
                    "https://media-photos.depop.com/fallback.png",
                    "https://media-photos.depop.com/large.gif",
                ],
                per_image_cap=12,
            )

        self.assertEqual(images, [(b"jpeg-bytes", "image/jpeg"), (b"png-bytes", "image/png")])
        self.assertEqual(get.call_count, 5)

    def test_fetch_images_caps_number_of_attempted_urls(self):
        from app.images import fetch_images

        with mock.patch(
            "app.images.httpx.get",
            return_value=httpx.Response(200, headers={"content-type": "image/webp"}, content=b"ok"),
        ) as get:
            images = fetch_images(
                ["https://example.com/1.webp", "https://example.com/2.webp"],
                max_images=1,
            )

        self.assertEqual(images, [(b"ok", "image/webp")])
        self.assertEqual(get.call_count, 1)


class SeededFactsTests(unittest.TestCase):
    def test_build_user_text_includes_seeded_facts_when_supplied(self):
        facts = ListingFacts(
            brand="Uniqlo",
            model_or_name="Linen blend shirt",
            size="M",
            asking_price=18.0,
        )

        text = claude_check._build_user_text("gift purchase", seeded_facts=facts)

        self.assertIn("listing's stated facts", text)
        self.assertIn('"brand": "Uniqlo"', text)
        self.assertIn('"asking_price": 18.0', text)
        self.assertIn("gift purchase", text)

    def test_build_user_text_omits_seeded_facts_when_not_supplied(self):
        text = claude_check._build_user_text(None)

        self.assertNotIn("listing's stated facts", text)


class CheckListingEndpointTests(unittest.TestCase):
    def setUp(self):
        self._old_token = os.environ.pop("CLEARED_SHARED_TOKEN", None)

    def tearDown(self):
        if self._old_token is not None:
            os.environ["CLEARED_SHARED_TOKEN"] = self._old_token
        else:
            os.environ.pop("CLEARED_SHARED_TOKEN", None)

    def test_check_listing_fetches_images_and_runs_check_without_token_in_dev(self):
        from app import main

        client = TestClient(main.app)
        report = CheckReport(
            listing_facts=ListingFacts(brand="Uniqlo"),
            verdict=Verdict(one_line="looks fair"),
        )

        with mock.patch.object(main, "fetch_images", return_value=[(b"img", "image/jpeg")]) as fetch, \
                mock.patch.object(main, "run_check", return_value=report) as run:
            response = client.post(
                "/check-listing",
                json={
                    "facts": {"brand": "Uniqlo", "asking_price": 18},
                    "image_urls": ["https://media-photos.depop.com/item.jpg"],
                    "user_context": "gift",
                },
            )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["listing_facts"]["brand"], "Uniqlo")
        fetch.assert_called_once_with(["https://media-photos.depop.com/item.jpg"])
        seeded = run.call_args.kwargs["seeded_facts"]
        self.assertEqual(seeded.brand, "Uniqlo")
        self.assertEqual(run.call_args.kwargs["user_context"], "gift")

    def test_check_listing_requires_token_when_configured(self):
        from app import main

        os.environ["CLEARED_SHARED_TOKEN"] = "secret"
        client = TestClient(main.app)

        response = client.post(
            "/check-listing",
            json={"facts": {}, "image_urls": ["https://media-photos.depop.com/item.jpg"]},
        )

        self.assertEqual(response.status_code, 401)

    def test_check_listing_returns_report_error_when_no_images_fetch(self):
        from app import main

        client = TestClient(main.app)

        with mock.patch.object(main, "fetch_images", return_value=[]), \
                mock.patch.object(main, "run_check") as run:
            response = client.post(
                "/check-listing",
                json={"facts": {}, "image_urls": ["https://media-photos.depop.com/missing.jpg"]},
            )

        self.assertEqual(response.status_code, 200)
        self.assertIn("Could not fetch listing photos", response.json()["error"])
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
