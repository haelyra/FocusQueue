import datetime as dt
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).parents[1] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("focus_queue_slack", SCRIPTS / "focus_queue_slack.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

CUTOFF = dt.datetime(2026, 10, 6, tzinfo=dt.timezone.utc)
INSIDE = f"{CUTOFF.timestamp() + 3600:.6f}"
LATER = f"{CUTOFF.timestamp() + 7200:.6f}"


class FakeSlack:
    """Serves Slack Web API responses and records each call."""

    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def __call__(self, method, cursor, parameters):
        self.calls.append((method, cursor, dict(parameters)))
        handler = self.responses[method]
        return handler(cursor, parameters) if callable(handler) else handler


def workspace(**overrides):
    responses = {
        "auth.test": {"ok": True, "team_id": "T1", "user_id": "U_ME", "url": "https://ecc.slack.com/"},
        "users.conversations": {"ok": True, "channels": [
            {"id": "C1", "name": "general"},
            {"id": "D1", "is_im": True, "user": "U2"},
            {"id": "C9", "name": "private-ops"},
        ]},
        "users.info": lambda _cursor, parameters: {"ok": True, "user": {
            "name": parameters["user"].lower(),
            "profile": {"display_name": {"U1": "Ada", "U2": "Grace"}.get(parameters["user"], "")},
        }},
        "conversations.history": lambda _cursor, parameters: {
            "C1": {"ok": True, "messages": [
                {"ts": INSIDE, "user": "U1", "text": "Can someone review the installer?",
                 "thread_ts": INSIDE, "reply_count": 1, "latest_reply": LATER},
                {"ts": INSIDE, "subtype": "channel_join", "user": "U3", "text": "joined"},
                {"ts": LATER, "bot_id": "B1", "text": "CI passed"},
            ]},
            "D1": {"ok": True, "messages": [{"ts": LATER, "user": "U2", "text": "ping me"}]},
            "C9": {"ok": False, "error": "not_in_channel"},
        }[parameters["channel"]],
        "conversations.replies": {"ok": True, "messages": [
            {"ts": INSIDE, "user": "U1", "text": "Can someone review the installer?", "thread_ts": INSIDE},
            {"ts": LATER, "user": "U_ME", "text": "On it", "thread_ts": INSIDE},
        ]},
    }
    responses.update(overrides)
    return FakeSlack(responses)


class FocusQueueSlackTests(unittest.TestCase):
    def test_collects_member_conversations_threads_and_direct_messages(self):
        fake = workspace()
        result = MODULE.collect({"maxSlackMessagesPerChannel": 200}, CUTOFF, request=fake)

        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["channelsScanned"], 3)
        self.assertEqual(result["hiddenChannels"], ["private-ops"])
        texts = {item["text"]: item for item in result["messages"]}
        self.assertEqual(set(texts), {"Can someone review the installer?", "On it", "ping me"})
        self.assertEqual(texts["ping me"]["channel"], "DM with Grace")
        self.assertEqual(texts["On it"]["author"], "you")
        self.assertEqual(texts["Can someone review the installer?"]["author"], "Ada")
        self.assertEqual(
            texts["Can someone review the installer?"]["sourceKey"], f"slack:T1:C1:{INSIDE}"
        )
        self.assertEqual(
            texts["ping me"]["url"],
            f"https://ecc.slack.com/archives/D1/p{LATER.replace('.', '')}",
        )
        self.assertIn("thread_ts=", texts["On it"]["url"])
        history = [call for call in fake.calls if call[0] == "conversations.history"]
        self.assertTrue(all(call[2]["oldest"] == f"{CUTOFF.timestamp():.6f}" for call in history))

    def test_follows_cursors_until_the_last_page(self):
        pages = {
            "": {"ok": True, "messages": [{"ts": INSIDE, "user": "U1", "text": "one"}],
                 "response_metadata": {"next_cursor": "next"}},
            "next": {"ok": True, "messages": [{"ts": LATER, "user": "U1", "text": "two"}]},
        }
        fake = workspace(**{
            "users.conversations": {"ok": True, "channels": [{"id": "C1", "name": "general"}]},
            "conversations.history": lambda cursor, _parameters: pages[cursor],
        })
        result = MODULE.collect({}, CUTOFF, request=fake)

        self.assertEqual([item["text"] for item in result["messages"]], ["two", "one"])
        self.assertFalse(result["truncated"])

    def test_channel_allowlist_limits_the_conversations_read(self):
        fake = workspace()
        result = MODULE.collect({"slackChannels": ["#general"]}, CUTOFF, request=fake)

        self.assertEqual(result["channelsScanned"], 1)
        read = {call[2]["channel"] for call in fake.calls if call[0] == "conversations.history"}
        self.assertEqual(read, {"C1"})

    def test_rejected_token_and_missing_scope_fail_the_whole_source(self):
        for response, code in (
            ({"ok": False, "error": "invalid_auth"}, "slack_auth_failed"),
            ({"ok": False, "error": "missing_scope", "needed": "im:history"}, "slack_missing_scope"),
        ):
            with self.subTest(code=code):
                fake = workspace(**{"conversations.history": response})
                with self.assertRaises(MODULE.SlackAccessError) as raised:
                    MODULE.collect({}, CUTOFF, request=fake)
                self.assertEqual(raised.exception.code, code)

    def test_other_conversation_errors_mark_the_source_partial(self):
        fake = workspace(**{
            "users.conversations": {"ok": True, "channels": [{"id": "C1", "name": "general"}]},
            "conversations.history": {"ok": False, "error": "internal_error"},
        })
        result = MODULE.collect({}, CUTOFF, request=fake)

        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["inaccessibleChannels"], ["general"])

    def test_missing_token_reports_setup_instead_of_calling_slack(self):
        with tempfile.TemporaryDirectory() as temporary:
            credentials = Path(temporary) / "credentials.json"
            credentials.write_text(json.dumps({"discordBotToken": "x"}))
            result = MODULE.collect({"discordCredentialPath": str(credentials)}, CUTOFF)

        self.assertEqual(result["status"], "unavailable")
        self.assertIn("slackToken", result["error"])


if __name__ == "__main__":
    unittest.main()
