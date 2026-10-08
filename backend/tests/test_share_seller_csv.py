"""No-network tests for share links, seller capture/filter, and CSV export.

Run from backend/:  python -m unittest tests.test_share_seller_csv -v
"""

from __future__ import annotations

import csv
import io
import unittest
from unittest import mock

from fastapi.testclient import TestClient

from app.models import CheckListingRequest, CheckReport, ListingFacts, Verdict
from tests.fake_supabase import FakeSupabase

OWNER = {"id": "owner-1", "email": "owner@example.com"}
OTHER = {"id": "other-2", "email": "other@example.com"}


def _row(**over):
    base = {
        "id": "r1",
        "user_id": OWNER["id"],
        "listing_url": "https://www.depop.com/products/polo/",
        "listing_name": "RL Polo",
        "marketplace": "depop",
        "verdict": "negotiate",
        "checked_at": "2026-10-05T12:00:00+00:00",
        "hub_status": "watching",
        "notes": "private note: gift for mom",
        "tags": ["gift", "winter"],
        "image_urls": ["https://media-photos.depop.com/a.jpg"],
        "share_token": None,
        "shared_at": None,
        "seller_username": "vintage.finds",
        "seller_url": "https://www.depop.com/vintage.finds/",
        "report_json": {
            "listing_facts": {"brand": "Ralph Lauren", "asking_price": 35.0, "currency": "USD"},
            "price_read": {"fairness": "fair", "retail_estimate": 98.0},
            "listing_trust": {"concerns": ["No measurements"]},
            "auth_flag": {"applicable": True, "confidence": "medium"},
            "verdict": {
                "recommendation": "negotiate",
                "one_line": "Fair, ask for measurements",
                "user_context": "it's a gift for my mom, must be legit",
            },
        },
    }
    base.update(over)
    return base


class _Base(unittest.TestCase):
    def setUp(self):
        from app import main

        self.main = main
        main._reset_share_rate_limit()
        self.sb = FakeSupabase([_row()])
        self._patch = mock.patch.object(main, "get_supabase", return_value=self.sb)
        self._patch.start()

    def tearDown(self):
        self._patch.stop()
        self.main.app.dependency_overrides.clear()
        self.main._reset_share_rate_limit()

    def client_as(self, user):
        from app.auth import get_current_user

        self.main.app.dependency_overrides[get_current_user] = lambda: user
        return TestClient(self.main.app)

    def anon_client(self):
        """Client with NO auth override (for asserting 401s on owner routes)."""
        self.main.app.dependency_overrides.clear()
        return TestClient(self.main.app)

    def public_client(self):
        """Plain client for the public share endpoint (it has no auth dependency).

        Does not touch dependency_overrides, which are app-global.
        """
        return TestClient(self.main.app)


class ShareTests(_Base):
    def test_create_fetch_revoke_flow(self):
        owner = self.client_as(OWNER)
        created = owner.post("/api/reports/r1/share")
        self.assertEqual(created.status_code, 200)
        token = created.json()["token"]
        self.assertGreaterEqual(len(token), 32)
        self.assertEqual(created.json()["path"], f"/r/{token}")

        # Idempotent: a second create returns the same token.
        again = owner.post("/api/reports/r1/share")
        self.assertEqual(again.json()["token"], token)

        public = self.public_client().get(f"/api/shared/{token}")
        self.assertEqual(public.status_code, 200)
        body = public.json()
        self.assertEqual(body["listing_name"], "RL Polo")
        self.assertEqual(body["marketplace"], "depop")
        self.assertEqual(body["verdict"], "negotiate")
        self.assertEqual(body["report"]["price_read"]["fairness"], "fair")
        self.assertEqual(public.headers["cache-control"], "no-store")
        self.assertIn("noindex", public.headers["x-robots-tag"])

        # Sanitized: no owner identity, triage fields, images, or private context.
        flat = repr(body)
        for leaked in ("owner-1", "owner@example.com", "private note", "gift", "watching",
                       "user_context", "image_urls", "share_token", "must be legit"):
            self.assertNotIn(leaked, flat, leaked)

        revoked = owner.delete("/api/reports/r1/share")
        self.assertEqual(revoked.status_code, 200)
        self.assertEqual(revoked.json(), {"revoked": True})
        self.assertEqual(self.public_client().get(f"/api/shared/{token}").status_code, 404)

        # A fresh share after revoke mints a different token.
        fresh = owner.post("/api/reports/r1/share").json()["token"]
        self.assertNotEqual(fresh, token)

    def test_non_owner_cannot_create_or_revoke(self):
        other = self.client_as(OTHER)
        self.assertEqual(other.post("/api/reports/r1/share").status_code, 404)
        self.assertEqual(other.delete("/api/reports/r1/share").status_code, 404)
        self.assertIsNone(self.sb.tables["reports"][0]["share_token"])

    def test_share_requires_auth(self):
        anon = self.anon_client()
        self.assertEqual(anon.post("/api/reports/r1/share").status_code, 401)
        self.assertEqual(anon.delete("/api/reports/r1/share").status_code, 401)

    def test_unknown_and_malformed_tokens_404_without_db_hit_for_malformed(self):
        anon = self.public_client()
        self.assertEqual(anon.get("/api/shared/" + "A" * 43).status_code, 404)
        before = len(self.sb.calls)
        self.assertEqual(anon.get("/api/shared/short").status_code, 404)
        self.assertEqual(anon.get("/api/shared/bad%20token%20with%20spaces%20xxxxxxxxxxxxxx").status_code, 404)
        self.assertEqual(len(self.sb.calls), before, "malformed tokens must not query the DB")

    def test_public_endpoint_is_rate_limited_per_client(self):
        anon = self.public_client()
        with mock.patch.object(self.main, "SHARE_RATE_LIMIT", 3):
            codes = [anon.get("/api/shared/" + "A" * 43).status_code for _ in range(5)]
        self.assertEqual(codes[:3], [404, 404, 404])
        self.assertEqual(codes[3:], [429, 429])

    def test_public_endpoint_sends_cors_headers_like_other_routes(self):
        anon = self.public_client()
        resp = anon.get("/api/shared/" + "A" * 43, headers={"Origin": "https://cleared.vercel.app"})
        self.assertIn("access-control-allow-origin", {k.lower() for k in resp.headers})


class SellerTests(_Base):
    def test_check_listing_persists_seller(self):
        client = self.client_as(OWNER)
        report = CheckReport(
            listing_facts=ListingFacts(brand="Levi's"),
            verdict=Verdict(recommendation="buy", one_line="good"),
        )
        with mock.patch.object(self.main, "fetch_images", return_value=[(b"i", "image/jpeg")]), \
                mock.patch.object(self.main, "run_check", return_value=report):
            resp = client.post("/check-listing", json={
                "facts": {"brand": "Levi's"},
                "image_urls": ["https://media-photos.depop.com/b.jpg"],
                "listing_url": "https://www.depop.com/products/jeans/",
                "marketplace": "depop",
                "seller": {"username": "@RetroRack", "profile_url": "https://www.depop.com/retrorack/"},
            })
        self.assertEqual(resp.status_code, 200)
        saved = self.sb.tables["reports"][-1]
        self.assertEqual(saved["seller_username"], "retrorack")
        self.assertEqual(saved["seller_url"], "https://www.depop.com/retrorack/")

    def test_missing_or_invalid_seller_saves_null(self):
        self.assertIsNone(CheckListingRequest().seller)
        req = CheckListingRequest(seller={"username": "has spaces", "profile_url": "javascript:alert(1)"})
        self.assertIsNone(req.seller.username)
        self.assertIsNone(req.seller.profile_url)

    def test_seller_filter_and_validation(self):
        self.sb.tables["reports"].extend([
            _row(id="r2", seller_username="vintage.finds", verdict="skip"),
            _row(id="r3", seller_username="someone.else", verdict="buy"),
            _row(id="r4", seller_username=None, verdict="buy"),
            _row(id="r5", user_id=OTHER["id"], seller_username="vintage.finds"),
        ])
        client = self.client_as(OWNER)
        resp = client.get("/api/reports?seller=@Vintage.Finds")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(sorted(r["id"] for r in resp.json()), ["r1", "r2"])
        self.assertTrue(all(r["seller_username"] == "vintage.finds" for r in resp.json()))
        self.assertEqual(client.get("/api/reports?seller=bad%20seller").status_code, 422)

    def test_text_search_matches_seller(self):
        client = self.client_as(OWNER)
        self.assertEqual(len(client.get("/api/reports?q=vintage").json()), 1)


class CsvTests(_Base):
    def test_csv_columns_order_and_values(self):
        client = self.client_as(OWNER)
        resp = client.get("/api/reports.csv")
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.headers["content-type"].startswith("text/csv"))
        self.assertIn("attachment", resp.headers["content-disposition"])
        rows = list(csv.reader(io.StringIO(resp.text)))
        self.assertEqual(rows[0], [
            "checked_at", "marketplace", "listing_name", "listing_url", "verdict",
            "one_line", "asking_price", "currency", "fairness", "status", "tags", "notes",
        ])
        self.assertEqual(rows[1], [
            "2026-10-05T12:00:00+00:00", "depop", "RL Polo",
            "https://www.depop.com/products/polo/", "negotiate",
            "Fair, ask for measurements", "35.0", "USD", "fair", "watching",
            "gift; winter", "private note: gift for mom",
        ])

    def test_csv_honors_filters_and_neutralizes_formulas(self):
        self.sb.tables["reports"].append(
            _row(id="r9", verdict="skip", listing_name="=HYPERLINK(\"http://evil\")", notes="+1 call me")
        )
        client = self.client_as(OWNER)
        rows = list(csv.reader(io.StringIO(client.get("/api/reports.csv?verdict=skip").text)))
        self.assertEqual(len(rows), 2)
        self.assertTrue(rows[1][2].startswith("'="))
        self.assertTrue(rows[1][11].startswith("'+"))
        self.assertEqual(client.get("/api/reports.csv?verdict=maybe").status_code, 422)

    def test_csv_requires_auth(self):
        self.assertEqual(self.anon_client().get("/api/reports.csv").status_code, 401)


if __name__ == "__main__":
    unittest.main()
