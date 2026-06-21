"""Unit checks for run_check's error mapping — no network, no API key.

Each Anthropic SDK exception should map to an honest, user-facing
CheckReport.error: "try again" wording for transient failures only, and a
non-misleading message for non-retryable ones (server config / billing). The
client is mocked, so nothing leaves the machine.

Run from backend/:  python -m unittest tests.test_error_mapping -v
"""

from __future__ import annotations

import unittest
from unittest import mock

import anthropic
import httpx

from app import claude_check
from app.claude_check import run_check

# A throwaway image so we get past the "no images" guard into the Claude call.
_IMAGES = [(b"\x89PNG fake bytes", "image/png")]


def _status_exc(exc_cls, status_code: int, error_type: str, message: str):
    """Build a real APIStatusError subclass with a populated body (so .type is set)."""
    request = httpx.Request("POST", "https://api.anthropic.com/v1/messages")
    response = httpx.Response(status_code, request=request)
    body = {"type": "error", "error": {"type": error_type, "message": message}}
    return exc_cls(message, response=response, body=body)


def _run_with_exception(exc: BaseException) -> str:
    """Force ANTHROPIC_API_KEY present, raise `exc` from the parse call, return error."""
    client = mock.Mock()
    client.messages.parse.side_effect = exc
    with mock.patch.dict("os.environ", {"ANTHROPIC_API_KEY": "test-key"}), \
            mock.patch.object(claude_check.anthropic, "Anthropic", return_value=client):
        report = run_check(_IMAGES, user_context=None)
    return report.error or ""


class ErrorMappingTests(unittest.TestCase):
    def test_authentication_error_not_retryable(self):
        exc = _status_exc(
            anthropic.AuthenticationError, 401, "authentication_error", "invalid x-api-key"
        )
        msg = _run_with_exception(exc)
        self.assertIn("misconfigured", msg)
        self.assertNotIn("try again", msg.lower())

    def test_permission_denied_not_retryable(self):
        exc = _status_exc(
            anthropic.PermissionDeniedError, 403, "permission_error", "no model access"
        )
        msg = _run_with_exception(exc)
        self.assertIn("misconfigured", msg)
        self.assertNotIn("try again", msg.lower())

    def test_billing_low_credit_distinct_and_not_retryable(self):
        # The real-world case: a 400 whose message is about the credit balance.
        exc = _status_exc(
            anthropic.BadRequestError,
            400,
            "invalid_request_error",
            "Your credit balance is too low to access the Anthropic API.",
        )
        msg = _run_with_exception(exc)
        self.assertIn("billing", msg.lower())
        self.assertNotIn("try again", msg.lower())
        # Must be distinct from the generic bad-request message.
        generic = _run_with_exception(
            _status_exc(anthropic.BadRequestError, 400, "invalid_request_error", "bad schema")
        )
        self.assertNotEqual(msg, generic)

    def test_generic_bad_request_not_retryable(self):
        exc = _status_exc(
            anthropic.BadRequestError, 400, "invalid_request_error", "messages: malformed"
        )
        msg = _run_with_exception(exc)
        self.assertIn("won't help", msg.lower())

    def test_rate_limit_retryable(self):
        exc = _status_exc(anthropic.RateLimitError, 429, "rate_limit_error", "slow down")
        msg = _run_with_exception(exc)
        self.assertIn("try again", msg.lower())

    def test_overloaded_retryable(self):
        # OverloadedError (529) is a sibling of InternalServerError in this SDK,
        # not a subclass — it must still route through the transient branch, not
        # the generic fallback. Assert the specific message to catch that.
        exc = _status_exc(anthropic.OverloadedError, 529, "overloaded_error", "overloaded")
        msg = _run_with_exception(exc)
        self.assertEqual(msg, "Couldn't reach the check service. Try again in a moment.")

    def test_internal_server_error_retryable(self):
        exc = _status_exc(anthropic.InternalServerError, 500, "api_error", "boom")
        msg = _run_with_exception(exc)
        self.assertEqual(msg, "Couldn't reach the check service. Try again in a moment.")

    def test_connection_error_retryable(self):
        request = httpx.Request("POST", "https://api.anthropic.com/v1/messages")
        exc = anthropic.APIConnectionError(request=request)
        msg = _run_with_exception(exc)
        self.assertIn("try again", msg.lower())

    def test_timeout_retryable(self):
        request = httpx.Request("POST", "https://api.anthropic.com/v1/messages")
        exc = anthropic.APITimeoutError(request=request)
        msg = _run_with_exception(exc)
        self.assertIn("try again", msg.lower())

    def test_no_message_leaks_the_api_key(self):
        # Belt-and-suspenders: a secret in the exception must never reach the user.
        exc = _status_exc(
            anthropic.AuthenticationError, 401, "authentication_error", "key sk-ant-SECRET123 invalid"
        )
        msg = _run_with_exception(exc)
        self.assertNotIn("sk-ant-SECRET123", msg)

    def test_happy_path_unchanged(self):
        # Successful parse returns the parsed report, error stays None.
        from app.models import CheckReport, ListingFacts, Verdict

        parsed = CheckReport(listing_facts=ListingFacts(brand="Uniqlo"), verdict=Verdict())
        client = mock.Mock()
        client.messages.parse.return_value = mock.Mock(parsed_output=parsed)
        with mock.patch.dict("os.environ", {"ANTHROPIC_API_KEY": "test-key"}), \
                mock.patch.object(claude_check.anthropic, "Anthropic", return_value=client):
            report = run_check(_IMAGES, user_context=None)
        self.assertIsNone(report.error)
        self.assertEqual(report.listing_facts.brand, "Uniqlo")


if __name__ == "__main__":
    unittest.main()
