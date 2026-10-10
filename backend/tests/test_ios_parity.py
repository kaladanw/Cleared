"""No-network tests for iOS account parity: Bearer /check, refresh tokens,
private screenshot storage, and recheck from stored images.

Run from backend/:  python -m unittest tests.test_ios_parity -v
"""

from __future__ import annotations

import os
import unittest
from types import SimpleNamespace
from unittest import mock

from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.models import CheckReport, ListingFacts, Verdict
from tests.fake_supabase import FakeSupabase

USER = {"id": "11111111-1111-4111-8111-111111111111", "email": "ios@example.com"}
OTHER = {"id": "22222222-2222-4222-8222-222222222222", "email": "other@example.com"}

JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64


def _report(**over) -> CheckReport:
    data = dict(
        listing_facts=ListingFacts(brand="Barbour", model_or_name="Beaufort jacket", asking_price=120.0),
        verdict=Verdict(recommendation="negotiate", one_line="Offer $90", user_context="gift"),
    )
    data.update(over)
    return CheckReport(**data)


def _files(*blobs, ctype="image/jpeg"):
    return [("images", (f"shot-{i}.jpg", blob, ctype)) for i, blob in enumerate(blobs)]


class _Base(unittest.TestCase):
    def setUp(self):
        from app import main

        self.main = main
        main._reset_share_rate_limit()
        self.sb = FakeSupabase()
        self._patches = [
            mock.patch.object(main, "get_supabase", return_value=self.sb),
            mock.patch.object(main, "run_check", return_value=_report()),
            mock.patch.dict(os.environ, {"CLEARED_SHARED_TOKEN": "shared-secret"}),
        ]
        for p in self._patches:
            p.start()
        self.run_check = main.run_check
        self.client = TestClient(main.app)

    def tearDown(self):
        for p in reversed(self._patches):
            p.stop()
        self.main.app.dependency_overrides.clear()
        self.main._reset_share_rate_limit()

    def bearer_as(self, user):
        """Make /check's direct get_current_user(...) call resolve to `user`."""

        async def fake_get_current_user(authorization=None):
            if authorization != "Bearer good-jwt":
                raise HTTPException(status_code=401, detail="Invalid or expired token.")
            return user

        p = mock.patch.object(self.main, "get_current_user", side_effect=fake_get_current_user)
        p.start()
        self._patches.append(p)

    def owner_client(self, user):
        from app.auth import get_current_user

        self.main.app.dependency_overrides[get_current_user] = lambda: user
        return TestClient(self.main.app)

    @property
    def rows(self):
        return self.sb.tables["reports"]

    @property
    def objects(self):
        return self.sb.storage.objects.get("check-images", {})


# ---------------------------------------------------------------------------
# POST /check
# ---------------------------------------------------------------------------

class BearerCheckTests(_Base):
    def test_bearer_check_saves_report_images_and_returns_report_id(self):
        self.bearer_as(USER)
        resp = self.client.post(
            "/check",
            headers={"Authorization": "Bearer good-jwt"},
            files=_files(JPEG, PNG),
            data={
                "user_context": "it's a gift",
                "listing_url": "https://www.depop.com/products/beaufort/",
                "marketplace": "Depop",
                "seller_username": "@Vintage.Finds",
            },
        )
        self.assertEqual(resp.status_code, 200, resp.text)
        body = resp.json()

        # Backward compatible: every CheckReport field is still present.
        for key in ("listing_facts", "price_read", "listing_trust", "auth_flag", "verdict", "error"):
            self.assertIn(key, body)
        self.assertEqual(body["verdict"]["recommendation"], "negotiate")

        self.assertEqual(len(self.rows), 1)
        row = self.rows[0]
        self.assertEqual(body["report_id"], row["id"])
        self.assertEqual(body["images_stored"], 2)
        self.assertEqual(row["user_id"], USER["id"])
        self.assertEqual(row["listing_url"], "https://www.depop.com/products/beaufort/")
        self.assertEqual(row["listing_name"], "Beaufort jacket")
        self.assertEqual(row["marketplace"], "depop")
        self.assertEqual(row["verdict"], "negotiate")
        self.assertEqual(row["seller_username"], "vintage.finds")
        self.assertEqual(row["seller_url"], "https://www.depop.com/vintage.finds/")
        self.assertEqual(row["image_urls"], [])

        rid = row["id"]
        expected = [f"{USER['id']}/{rid}/0.jpg", f"{USER['id']}/{rid}/1.png"]
        self.assertEqual(row["image_paths"], expected)
        self.assertEqual(set(self.objects), set(expected))
        self.assertEqual(self.objects[expected[0]][0], JPEG)
        self.assertEqual(self.objects[expected[1]][1]["content-type"], "image/png")
        self.assertEqual(self.objects[expected[0]][1]["x-upsert"], "false")

        args, kwargs = self.run_check.call_args
        self.assertEqual(args[0], [(JPEG, "image/jpeg"), (PNG, "image/png")])
        self.assertEqual(kwargs["user_context"], "it's a gift")

    def test_bearer_check_without_listing_url_still_saves(self):
        self.bearer_as(USER)
        resp = self.client.post("/check", headers={"Authorization": "Bearer good-jwt"}, files=_files(JPEG))
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(self.rows[0]["listing_url"], "")
        self.assertEqual(self.rows[0]["marketplace"], "depop")
        self.assertIsNone(self.rows[0]["seller_username"])
        self.assertEqual(resp.json()["report_id"], self.rows[0]["id"])

    def test_bearer_wins_over_shared_secret(self):
        self.bearer_as(USER)
        resp = self.client.post(
            "/check",
            headers={"Authorization": "Bearer good-jwt", "X-Cleared-Token": "WRONG"},
            files=_files(JPEG),
        )
        self.assertEqual(resp.status_code, 200)
        self.assertIsNotNone(resp.json()["report_id"])
        self.assertEqual(len(self.rows), 1)

    def test_invalid_bearer_is_401_not_a_silent_fallback(self):
        self.bearer_as(USER)
        resp = self.client.post(
            "/check",
            headers={"Authorization": "Bearer expired-jwt", "X-Cleared-Token": "shared-secret"},
            files=_files(JPEG),
        )
        self.assertEqual(resp.status_code, 401)
        self.run_check.assert_not_called()
        self.assertEqual(self.rows, [])

    def test_malformed_authorization_header_is_401(self):
        # Real get_current_user: rejects a non-Bearer scheme before touching Supabase.
        resp = self.client.post(
            "/check",
            headers={"Authorization": "Basic abc", "X-Cleared-Token": "shared-secret"},
            files=_files(JPEG),
        )
        self.assertEqual(resp.status_code, 401)
        self.run_check.assert_not_called()

    def test_upload_failure_is_tolerated_and_report_saved_without_images(self):
        self.bearer_as(USER)
        self.sb.storage.fail_uploads = True
        with self.assertLogs("cleared", level="WARNING") as logs:
            resp = self.client.post("/check", headers={"Authorization": "Bearer good-jwt"}, files=_files(JPEG))
        self.assertEqual(resp.status_code, 200)
        body = resp.json()
        self.assertEqual(body["images_stored"], 0)
        self.assertEqual(body["report_id"], self.rows[0]["id"])
        self.assertEqual(self.rows[0]["image_paths"], [])
        self.assertTrue(any("image upload failed" in line for line in logs.output))

    def test_insert_failure_cleans_up_uploaded_images(self):
        self.bearer_as(USER)
        self.sb.fail_inserts = True
        resp = self.client.post("/check", headers={"Authorization": "Bearer good-jwt"}, files=_files(JPEG))
        self.assertEqual(resp.status_code, 200)
        self.assertIsNone(resp.json()["report_id"])
        self.assertEqual(resp.json()["images_stored"], 0)
        self.assertEqual(self.objects, {})
        self.assertEqual(len(self.sb.storage.removed), 1)

    def test_error_report_is_not_saved(self):
        self.bearer_as(USER)
        self.run_check.return_value = CheckReport(listing_facts=ListingFacts(), error="Couldn't read it")
        resp = self.client.post("/check", headers={"Authorization": "Bearer good-jwt"}, files=_files(JPEG))
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json()["error"], "Couldn't read it")
        self.assertIsNone(resp.json()["report_id"])
        self.assertEqual(self.rows, [])
        self.assertEqual(self.objects, {})

    def test_invalid_marketplace_and_listing_url_are_422(self):
        self.bearer_as(USER)
        bad_mp = self.client.post(
            "/check", headers={"Authorization": "Bearer good-jwt"}, files=_files(JPEG),
            data={"marketplace": "Not A Slug!"},
        )
        self.assertEqual(bad_mp.status_code, 422)
        bad_url = self.client.post(
            "/check", headers={"Authorization": "Bearer good-jwt"}, files=_files(JPEG),
            data={"listing_url": "javascript:alert(1)"},
        )
        self.assertEqual(bad_url.status_code, 422)
        self.run_check.assert_not_called()


class SharedSecretCheckTests(_Base):
    def test_shared_secret_path_unchanged_and_unsaved(self):
        resp = self.client.post(
            "/check",
            headers={"X-Cleared-Token": "shared-secret"},
            files=_files(JPEG),
            data={"user_context": "gift", "listing_url": "https://www.depop.com/products/x/"},
        )
        self.assertEqual(resp.status_code, 200)
        body = resp.json()
        self.assertEqual(body["verdict"]["recommendation"], "negotiate")
        self.assertIsNone(body["report_id"])
        self.assertEqual(body["images_stored"], 0)
        self.assertEqual(self.rows, [])
        self.assertEqual(self.objects, {})
        self.assertEqual([c for c in self.sb.calls if c[0] == "insert"], [])

    def test_wrong_or_missing_shared_secret_is_401(self):
        self.assertEqual(
            self.client.post("/check", headers={"X-Cleared-Token": "nope"}, files=_files(JPEG)).status_code, 401
        )
        self.assertEqual(self.client.post("/check", files=_files(JPEG)).status_code, 401)
        self.run_check.assert_not_called()

    def test_no_images_returns_error_report(self):
        resp = self.client.post("/check", headers={"X-Cleared-Token": "shared-secret"})
        self.assertEqual(resp.status_code, 200)
        self.assertIn("No screenshots", resp.json()["error"])


class ImageLimitTests(_Base):
    def test_more_than_eight_images_is_400(self):
        resp = self.client.post("/check", headers={"X-Cleared-Token": "shared-secret"}, files=_files(*[JPEG] * 9))
        self.assertEqual(resp.status_code, 400)
        self.assertIn("at most 8", resp.json()["detail"])

    def test_eight_images_ok(self):
        resp = self.client.post("/check", headers={"X-Cleared-Token": "shared-secret"}, files=_files(*[JPEG] * 8))
        self.assertEqual(resp.status_code, 200)

    def test_non_image_bytes_are_415_even_if_declared_image(self):
        resp = self.client.post(
            "/check", headers={"X-Cleared-Token": "shared-secret"},
            files=_files(b"<html>nope</html>", ctype="image/jpeg"),
        )
        self.assertEqual(resp.status_code, 415)

    def test_oversized_image_is_413(self):
        with mock.patch("app.check_images.MAX_IMAGE_BYTES", 32):
            resp = self.client.post("/check", headers={"X-Cleared-Token": "shared-secret"}, files=_files(JPEG))
        self.assertEqual(resp.status_code, 413)

    def test_type_is_sniffed_not_trusted(self):
        resp = self.client.post(
            "/check", headers={"X-Cleared-Token": "shared-secret"},
            files=_files(PNG, ctype="application/octet-stream"),
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(self.run_check.call_args[0][0], [(PNG, "image/png")])


# ---------------------------------------------------------------------------
# Hub reads, recheck from storage, share sanitization
# ---------------------------------------------------------------------------

def _stored_row(user=USER, rid="33333333-3333-4333-8333-333333333333", **over):
    row = {
        "id": rid,
        "user_id": user["id"],
        "listing_url": "",
        "listing_name": "Beaufort jacket",
        "marketplace": "depop",
        "verdict": "negotiate",
        "checked_at": "2026-10-07T10:00:00+00:00",
        "hub_status": None,
        "notes": "",
        "tags": [],
        "image_urls": [],
        "image_paths": [f"{user['id']}/{rid}/0.jpg", f"{user['id']}/{rid}/1.png"],
        "share_token": None,
        "shared_at": None,
        "seller_username": None,
        "seller_url": None,
        "report_json": _report().model_dump(mode="json"),
    }
    row.update(over)
    return row


class StoredImageRecheckTests(_Base):
    def setUp(self):
        super().setUp()
        self.row = _stored_row()
        self.sb.tables["reports"].append(self.row)
        bucket = self.sb.storage.from_("check-images")
        bucket.upload(self.row["image_paths"][0], JPEG, {"content-type": "image/jpeg"})
        bucket.upload(self.row["image_paths"][1], PNG, {"content-type": "image/png"})

    def test_recheck_uses_stored_images_and_saves_new_row(self):
        client = self.owner_client(USER)
        with mock.patch.object(self.main, "fetch_images") as fetch:
            resp = client.post(f"/api/reports/{self.row['id']}/recheck")
        self.assertEqual(resp.status_code, 200, resp.text)
        fetch.assert_not_called()
        args, kwargs = self.run_check.call_args
        self.assertEqual(args[0], [(JPEG, "image/jpeg"), (PNG, "image/png")])
        self.assertEqual(kwargs["seeded_facts"].brand, "Barbour")

        self.assertEqual(len(self.rows), 2)
        new = self.rows[1]
        self.assertEqual(resp.json()["report_id"], new["id"])
        self.assertEqual(new["image_paths"], self.row["image_paths"])
        self.assertEqual(new["user_id"], USER["id"])

    def test_recheck_ignores_paths_outside_the_owner_prefix(self):
        foreign = _stored_row(user=OTHER)["image_paths"]
        self.row["image_paths"] = foreign
        resp = self.owner_client(USER).post(f"/api/reports/{self.row['id']}/recheck")
        self.assertEqual(resp.status_code, 409)
        self.run_check.assert_not_called()

    def test_recheck_of_someone_elses_report_is_404(self):
        resp = self.owner_client(OTHER).post(f"/api/reports/{self.row['id']}/recheck")
        self.assertEqual(resp.status_code, 404)

    def test_list_reports_flags_can_recheck_for_stored_images(self):
        self.sb.tables["reports"].append(_stored_row(rid="44444444-4444-4444-8444-444444444444", image_paths=[]))
        resp = self.owner_client(USER).get("/api/reports")
        self.assertEqual(resp.status_code, 200)
        by_id = {r["id"]: r for r in resp.json()}
        self.assertTrue(by_id[self.row["id"]]["can_recheck"])
        self.assertEqual(by_id[self.row["id"]]["image_paths"], self.row["image_paths"])
        self.assertFalse(by_id["44444444-4444-4444-8444-444444444444"]["can_recheck"])

    def test_list_reports_errors_are_503_not_an_empty_history(self):
        self.sb.fail_selects = True
        resp = self.owner_client(USER).get("/api/reports")
        self.assertEqual(resp.status_code, 503)

    def test_public_share_never_exposes_image_paths_or_urls(self):
        owner = self.owner_client(USER)
        token = owner.post(f"/api/reports/{self.row['id']}/share").json()["token"]
        shared = TestClient(self.main.app).get(f"/api/shared/{token}")
        self.assertEqual(shared.status_code, 200)
        text = shared.text
        self.assertNotIn("image_paths", text)
        self.assertNotIn("image_urls", text)
        self.assertNotIn(USER["id"], text)
        self.assertNotIn("check-images", text)


# ---------------------------------------------------------------------------
# Auth: session shape, refresh, isolated auth client
# ---------------------------------------------------------------------------

def _session(access="acc-1", refresh="ref-1"):
    user = SimpleNamespace(id=USER["id"], email=USER["email"])
    return SimpleNamespace(
        access_token=access, refresh_token=refresh, expires_in=3600,
        expires_at=1_791_000_000, token_type="bearer", user=user,
    ), user


class AuthTests(unittest.TestCase):
    def setUp(self):
        from app import main

        self.client = TestClient(main.app)
        self.auth_client = mock.MagicMock()
        self._p = mock.patch("app.auth.new_auth_client", return_value=self.auth_client)
        self._p.start()
        # The cached service-role client must never be used for user auth actions.
        self.service = mock.MagicMock()
        self._p2 = mock.patch("app.auth.require_supabase", return_value=self.service)
        self._p2.start()

    def tearDown(self):
        self._p2.stop()
        self._p.stop()

    def assert_session_shape(self, body, access, refresh):
        self.assertEqual(body["access_token"], access)
        self.assertEqual(body["refresh_token"], refresh)
        self.assertEqual(body["expires_in"], 3600)
        self.assertEqual(body["expires_at"], 1_791_000_000)
        self.assertEqual(body["token_type"], "bearer")
        self.assertEqual(body["user"], USER)

    def test_login_returns_refresh_token_and_expiry(self):
        session, user = _session()
        self.auth_client.auth.sign_in_with_password.return_value = SimpleNamespace(session=session, user=user)
        resp = self.client.post("/auth/login", json={"email": USER["email"], "password": "pw"})
        self.assertEqual(resp.status_code, 200)
        self.assert_session_shape(resp.json(), "acc-1", "ref-1")
        self.service.auth.sign_in_with_password.assert_not_called()

    def test_login_bad_credentials_401(self):
        from supabase_auth.errors import AuthApiError

        self.auth_client.auth.sign_in_with_password.side_effect = AuthApiError(
            "Invalid login credentials", 400, "invalid_credentials"
        )
        resp = self.client.post("/auth/login", json={"email": USER["email"], "password": "x"})
        self.assertEqual(resp.status_code, 401)

    def test_signup_returns_session_shape_and_keeps_allowlist(self):
        session, user = _session()
        self.auth_client.auth.sign_up.return_value = SimpleNamespace(session=session, user=user)
        with mock.patch.dict(os.environ, {"CLEARED_ALLOWED_EMAILS": USER["email"]}):
            ok = self.client.post("/auth/signup", json={"email": USER["email"], "password": "pw"})
            blocked = self.client.post("/auth/signup", json={"email": "stranger@example.com", "password": "pw"})
        self.assertEqual(ok.status_code, 200)
        self.assert_session_shape(ok.json(), "acc-1", "ref-1")
        self.assertEqual(blocked.status_code, 403)
        self.assertEqual(self.auth_client.auth.sign_up.call_count, 1)

    def test_signup_without_session_returns_null_tokens(self):
        _, user = _session()
        self.auth_client.auth.sign_up.return_value = SimpleNamespace(session=None, user=user)
        with mock.patch.dict(os.environ, {"CLEARED_ALLOWED_EMAILS": ""}):
            body = self.client.post("/auth/signup", json={"email": USER["email"], "password": "pw"}).json()
        self.assertIsNone(body["access_token"])
        self.assertIsNone(body["refresh_token"])
        self.assertEqual(body["user"], USER)

    def test_refresh_success_returns_rotated_session(self):
        session, user = _session(access="acc-2", refresh="ref-2")
        self.auth_client.auth.refresh_session.return_value = SimpleNamespace(session=session, user=user)
        resp = self.client.post("/auth/refresh", json={"refresh_token": "ref-1"})
        self.assertEqual(resp.status_code, 200)
        self.assert_session_shape(resp.json(), "acc-2", "ref-2")
        self.auth_client.auth.refresh_session.assert_called_once_with("ref-1")
        self.service.auth.refresh_session.assert_not_called()

    def test_refresh_invalid_token_401(self):
        from supabase_auth.errors import AuthApiError

        self.auth_client.auth.refresh_session.side_effect = AuthApiError(
            "Invalid Refresh Token: Already Used", 400, "refresh_token_already_used"
        )
        resp = self.client.post("/auth/refresh", json={"refresh_token": "used"})
        self.assertEqual(resp.status_code, 401)

    def test_refresh_without_session_401(self):
        self.auth_client.auth.refresh_session.return_value = SimpleNamespace(session=None, user=None)
        self.assertEqual(self.client.post("/auth/refresh", json={"refresh_token": "x"}).status_code, 401)

    def test_refresh_auth_service_down_is_503_not_401(self):
        from supabase_auth.errors import AuthRetryableError

        self.auth_client.auth.refresh_session.side_effect = AuthRetryableError("network", 0)
        resp = self.client.post("/auth/refresh", json={"refresh_token": "ref-1"})
        self.assertEqual(resp.status_code, 503)

    def test_refresh_requires_token_422(self):
        self.assertEqual(self.client.post("/auth/refresh", json={}).status_code, 422)
        self.assertEqual(self.client.post("/auth/refresh", json={"refresh_token": ""}).status_code, 422)


class AuthClientIsolationTests(unittest.TestCase):
    def test_new_auth_client_is_ephemeral_and_prefers_anon_key(self):
        from app import supabase_client

        env = {"SUPABASE_URL": "https://x.supabase.co", "SUPABASE_SERVICE_KEY": "svc", "SUPABASE_ANON_KEY": "anon"}
        with mock.patch.dict(os.environ, env), mock.patch("supabase.create_client") as create:
            supabase_client.new_auth_client()
            supabase_client.new_auth_client()
        self.assertEqual(create.call_count, 2)  # never cached
        url, key = create.call_args[0]
        options = create.call_args[1]["options"]
        self.assertEqual((url, key), ("https://x.supabase.co", "anon"))
        self.assertFalse(options.auto_refresh_token)
        self.assertFalse(options.persist_session)


if __name__ == "__main__":
    unittest.main()
