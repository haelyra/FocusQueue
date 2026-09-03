import argparse
import importlib.util
import json
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "Scripts/focus_queue_discord.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("focus_queue_discord", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class FocusQueueDiscordTests(unittest.TestCase):
    def test_credential_migration_moves_token_to_private_ecc_store(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            legacy = root / "legacy.env"
            legacy.write_text("DISCORD_BOT_TOKEN=test-token\n", encoding="utf-8")
            destination = root / "credentials.json"
            config = {"discordCredentialPath": str(destination)}
            with mock.patch.object(MODULE, "LEGACY_CREDENTIALS", legacy):
                result = MODULE.migrate_credentials(config)

            self.assertTrue(result["migrated"])
            self.assertEqual(json.loads(destination.read_text())["discordBotToken"], "test-token")
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)

    def test_status_reports_partial_server_coverage_without_enabling_writes(self):
        config = {"discordGuildId": "1"}

        def fake_get(_token, endpoint, query=None):
            if endpoint == "/users/@me":
                return {"id": "7", "username": "queue-bot"}
            if endpoint == "/guilds/1":
                return {"id": "1", "name": "ECC"}
            if endpoint == "/guilds/1/channels":
                return [
                    {"id": "2", "name": "general", "type": 0},
                    {"id": "3", "name": "private", "type": 0},
                ]
            if endpoint == "/guilds/1/threads/active":
                return {"threads": []}
            if endpoint == "/channels/3/messages":
                raise urllib.error.HTTPError("test", 403, "Forbidden", {}, None)
            if endpoint == "/channels/2/messages":
                return []
            raise AssertionError(endpoint)

        with mock.patch.object(MODULE.morning, "discord_get", fake_get):
            result = MODULE.status(config, "secret")

        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["readableChannelCount"], 1)
        self.assertEqual(result["inaccessibleChannels"][0]["name"], "private")
        self.assertFalse(result["writesEnabled"])

    def test_read_uses_a_stable_message_link_and_returns_full_text(self):
        config = {"discordGuildId": "1"}

        def fake_get(_token, endpoint, query=None):
            if endpoint == "/guilds/1/channels":
                return [{"id": "2", "name": "general", "type": 0}]
            if endpoint == "/guilds/1/threads/active":
                return {"threads": []}
            if endpoint == "/channels/2/messages/3":
                return {
                    "id": "3",
                    "content": "Please investigate the regression.",
                    "timestamp": "2026-09-03T01:00:00Z",
                    "author": {"id": "4", "username": "maintainer"},
                    "attachments": [],
                }
            raise AssertionError(endpoint)

        with mock.patch.object(MODULE.morning, "discord_get", fake_get):
            result = MODULE.read(config, "secret", "https://discord.com/channels/1/2/3", None)

        self.assertTrue(result["verified"])
        self.assertEqual(result["operation"], "read")
        self.assertEqual(result["message"]["id"], "3")
        self.assertEqual(result["message"]["text"], "Please investigate the regression.")


if __name__ == "__main__":
    unittest.main()
