import base64
import importlib.util
import json
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).parents[1] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
SCRIPT = SCRIPTS / "focus_queue_gmail.py"
SPEC = importlib.util.spec_from_file_location("focus_queue_gmail", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class FakeResponse:
    def __init__(self, payload):
        self.payload = json.dumps(payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, _maximum):
        return self.payload


class FakeClient:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def get(self, path, parameters=None):
        self.calls.append((path, parameters))
        response = self.responses[path]
        return response(parameters) if callable(response) else response


def encoded(value):
    return base64.urlsafe_b64encode(value.encode("utf-8")).decode("ascii").rstrip("=")


def gmail_message(identifier="abc123", body=None):
    payload = {
        "mimeType": "multipart/alternative",
        "headers": [
            {"name": "From", "value": "Customer <customer@example.com>"},
            {"name": "To", "value": "reader@example.com"},
            {"name": "Subject", "value": "Activation problem"},
            {"name": "Message-ID", "value": "<message@example.com>"},
        ],
    }
    if body is not None:
        payload["parts"] = [
            {"mimeType": "text/plain", "body": {"data": encoded(body)}},
            {
                "mimeType": "application/pdf",
                "filename": "details.pdf",
                "body": {"attachmentId": "attachment-1"},
            },
        ]
    return {
        "id": identifier,
        "threadId": "thread-1",
        "labelIds": ["INBOX", "UNREAD", "STARRED"],
        "internalDate": "1720000000000",
        "snippet": "The activation is blocked.",
        "payload": payload,
    }


class GmailConnectorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.oauth = self.root / "oauth.json"
        self.oauth.write_text(
            json.dumps(
                {
                    "installed": {
                        "client_id": "client-id.apps.googleusercontent.com",
                        "client_secret": "client-secret",
                    }
                }
            )
        )
        self.oauth.chmod(0o600)
        self.config = {
            "emailAddress": "reader@example.com",
            "emailProvider": "gmail",
            "gmailOAuthClientPath": str(self.oauth),
            "lookbackHours": 48,
            "maxEmailMessages": 20,
        }

    def test_authorization_url_is_pkce_and_read_only(self):
        url = MODULE.authorization_url(
            "client-id",
            "http://127.0.0.1:1234/oauth/callback",
            "state-value",
            "challenge-value",
        )
        query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        self.assertEqual(query["scope"], [MODULE.GMAIL_SCOPE])
        self.assertEqual(query["code_challenge_method"], ["S256"])
        self.assertEqual(query["access_type"], ["offline"])
        self.assertEqual(query["prompt"], ["consent"])
        serialized = json.dumps(query)
        self.assertNotIn("gmail.send", serialized)
        self.assertNotIn("gmail.compose", serialized)
        self.assertNotIn("gmail.modify", serialized)

    def test_oauth_client_file_must_be_private_installed_app_configuration(self):
        self.assertEqual(
            MODULE.oauth_client(self.config)["client_id"],
            "client-id.apps.googleusercontent.com",
        )
        self.oauth.chmod(0o644)
        with self.assertRaisesRegex(MODULE.GmailAccessError, "private"):
            MODULE.oauth_client(self.config)

    def test_config_requires_supported_provider_and_gmail_oauth_client(self):
        base = {
            "dashboardPath": "/tmp/dashboard.json",
            "dashboardDirectory": "/tmp/dashboard",
            "emailAddress": "reader@example.com",
            "discordGuildId": "guild",
            "githubRepositories": ["owner/repository"],
            "telegramBotUsername": "bot",
            "agentExecutable": "/tmp/focus-queue-codex",
        }
        config = self.root / "ingestion.json"
        config.write_text(json.dumps({**base, "emailProvider": "gmail"}))
        with self.assertRaisesRegex(MODULE.morning.ReconciliationError, "gmailOAuthClientPath"):
            MODULE.morning.load_config(config)

        config.write_text(json.dumps({**base, "emailProvider": "unsupported"}))
        with self.assertRaisesRegex(MODULE.morning.ReconciliationError, "emailProvider"):
            MODULE.morning.load_config(config)

    def test_refresh_uses_keychain_token_without_persisting_access_token(self):
        captured = {}

        def opener(request, timeout):
            captured["url"] = request.full_url
            captured["body"] = urllib.parse.parse_qs(request.data.decode("utf-8"))
            captured["timeout"] = timeout
            return FakeResponse({"access_token": "short-lived-token", "expires_in": 3600})

        with mock.patch.object(
            MODULE,
            "keychain_refresh_token",
            return_value="long-lived-refresh-token",
        ):
            token = MODULE.refresh_access_token(self.config, opener=opener)

        self.assertEqual(token, "short-lived-token")
        self.assertEqual(captured["url"], MODULE.TOKEN_ENDPOINT)
        self.assertEqual(captured["body"]["refresh_token"], ["long-lived-refresh-token"])
        self.assertEqual(captured["body"]["grant_type"], ["refresh_token"])

    def test_search_uses_gmail_query_pagination_and_returns_bounded_metadata(self):
        first_page = {
            "messages": [{"id": "one"}, {"id": "two"}],
            "nextPageToken": "next",
        }
        second_page = {"messages": [{"id": "three"}]}

        def list_response(parameters):
            return second_page if parameters.get("pageToken") == "next" else first_page

        client = FakeClient(
            {
                "messages": list_response,
                "messages/two": gmail_message("two"),
                "messages/three": gmail_message("three"),
            }
        )
        result = MODULE.search(self.config, client, "activation", 30, 2, offset=1)

        self.assertEqual([item["id"] for item in result["results"]], ["gmail:two", "gmail:three"])
        self.assertEqual(result["results"][0]["mailbox"], "INBOX")
        self.assertNotIn("body", result["results"][0])
        list_calls = [parameters for path, parameters in client.calls if path == "messages"]
        self.assertEqual(len(list_calls), 2)
        self.assertIn("newer_than:30d", list_calls[0]["q"])
        self.assertIn("-in:sent", list_calls[0]["q"])
        self.assertTrue(list_calls[0]["includeSpamTrash"])

    def test_read_decodes_plain_body_and_reports_attachments(self):
        client = FakeClient({"messages/abc123": gmail_message("abc123", "Full customer text")})
        result = MODULE.read(self.config, client, "gmail:abc123")

        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["message"]["body"], "Full customer text")
        self.assertEqual(result["message"]["attachments"][0]["filename"], "details.pdf")
        self.assertFalse(result["writesEnabled"])

    def test_status_exposes_future_writes_without_enabling_them(self):
        client = FakeClient(
            {
                "profile": {
                    "emailAddress": "reader@example.com",
                    "messagesTotal": 12,
                    "threadsTotal": 8,
                }
            }
        )
        result = MODULE.status(self.config, client)
        self.assertEqual(result["capabilities"], ["status", "search", "read"])
        self.assertEqual(result["plannedWriteCapabilities"], ["draft", "send", "reply"])
        self.assertFalse(result["writesEnabled"])
        self.assertEqual(result["scope"], MODULE.GMAIL_SCOPE)

    def test_daily_report_mapping_matches_existing_email_envelope(self):
        search_result = {
            "status": "ok",
            "account": "reader@example.com",
            "results": [MODULE.message_metadata(gmail_message("abc123"), full=False)],
            "truncated": False,
        }
        with mock.patch.object(MODULE, "GmailClient", return_value=object()), mock.patch.object(
            MODULE, "search", return_value=search_result
        ):
            result = MODULE.collect_for_daily_report(self.config)
        self.assertEqual(result["reader"], "gmail-api")
        self.assertEqual(result["provider"], "gmail")
        self.assertEqual(result["messages"][0]["sourceKey"], "email:gmail:abc123")
        self.assertEqual(result["messages"][0]["text"], "The activation is blocked.")

    def test_helper_service_writes_nonce_bound_proof(self):
        request = self.root / "mail-request.json"
        response = self.root / "mail-response.json"
        request.write_text(
            json.dumps({"operation": "status", "nonce": "request-nonce"})
        )
        config = {
            **self.config,
            "mailRequestDirectory": str(self.root),
            "mailResponseDirectory": str(self.root),
        }
        status_result = {
            "status": "ok",
            "verified": True,
            "operation": "status",
            "connector": MODULE.CONNECTOR,
            "provider": "gmail",
        }
        with mock.patch.object(MODULE, "GmailClient", return_value=object()), mock.patch.object(
            MODULE, "status", return_value=status_result
        ):
            result = MODULE.serve(config)

        self.assertEqual(result, 0)
        proof = json.loads(response.read_text())
        self.assertEqual(proof["nonce"], "request-nonce")
        self.assertEqual(proof["connector"], "ecc-focus-mail-reader")
        self.assertEqual(response.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
