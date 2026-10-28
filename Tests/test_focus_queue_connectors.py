import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).parents[1] / "Scripts/focus_queue_connectors.py"
SPEC = importlib.util.spec_from_file_location("focus_queue_connectors", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
sys.path.insert(0, str(SCRIPT.parent))
import focus_queue_morning as MORNING  # noqa: E402

VALID_CLIENT = {"installed": {"client_id": "client.apps.googleusercontent.com", "client_secret": "s"}}


def connector(result, identifier):
    return next(item for item in result["connectors"] if item["id"] == identifier)


class ConnectorDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.config_path = self.root / "ingestion.json"

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, name, payload, mode=0o600):
        path = self.root / name
        path.write_text(json.dumps(payload) if not isinstance(payload, str) else payload)
        path.chmod(mode)
        return path

    def diagnose(self, config):
        return MODULE.diagnose(config, self.config_path)

    def test_diagnostics_do_not_echo_account_data_or_execute_configured_helper(self):
        helper = self.root / "helper"
        sentinel = self.root / "executed"
        helper.write_text(f"#!/bin/sh\ntouch '{sentinel}'\n")
        helper.chmod(0o700)
        result = self.diagnose({"telegramArchiveExecutable": str(helper), "emailAddress": "private@example.test", "discordBotToken": "secret-value"})
        serialized = json.dumps(result)
        self.assertNotIn("private@example.test", serialized)
        self.assertNotIn("secret-value", serialized)
        self.assertFalse(sentinel.exists())
        self.assertEqual(result["connectors"][0]["status"], "limited")
        self.assertFalse(result["connectors"][0]["personalInboxSupported"])

    def test_missing_configuration_is_setup_required(self):
        result = self.diagnose({})
        self.assertTrue(all(connector["status"] == "setup_required" for connector in result["connectors"]))
        self.assertFalse(result["authenticationVerified"])
        self.assertEqual({item["id"] for item in result["connectors"]}, set(MORNING.REPORT_PLATFORMS))

    def test_absent_config_file_reports_every_platform_instead_of_failing(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--config", str(self.config_path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["configurationPresent"])
        self.assertEqual(len(payload["connectors"]), 6)
        self.assertTrue(all(item["status"] == "setup_required" for item in payload["connectors"]))
        self.assertTrue(all("ingestion.json" in item["nextStep"] for item in payload["connectors"]))

    def test_gmail_diagnostics_require_private_client_configuration_without_reading_it(self):
        client = self.write("oauth.json", {"installed": {"client_id": "sensitive-oauth-client"}})
        self.write("gmail-auth.json", {"account": "private@example.test"})
        result = self.diagnose(
            {
                "emailProvider": "gmail",
                "emailAddress": "private@example.test",
                "gmailOAuthClientPath": str(client),
            }
        )
        email = connector(result, "email")
        self.assertEqual(email["status"], "configured_unverified")
        self.assertEqual(email["coverage"], "configured_gmail_api_account")
        serialized = json.dumps(result)
        self.assertNotIn("private@example.test", serialized)
        self.assertNotIn("sensitive-oauth-client", serialized)

    def test_gmail_client_gates_match_the_connector(self):
        address = {"gmailAddress": "report@example.test"}
        insecure = self.write("insecure.json", VALID_CLIENT, 0o644)
        self.assertIn("chmod 600", connector(self.diagnose({**address, "gmailOAuthClientPath": str(insecure)}), "gmail")["nextStep"])
        web = self.write("web.json", {"web": {"client_id": "x"}})
        result = connector(self.diagnose({**address, "gmailOAuthClientPath": str(web)}), "gmail")
        self.assertEqual(result["status"], "setup_required")
        self.assertIn("Desktop app", result["nextStep"])
        valid = self.write("valid.json", VALID_CLIENT)
        result = connector(self.diagnose({**address, "gmailOAuthClientPath": str(valid)}), "gmail")
        self.assertEqual(result["status"], "setup_required")
        self.assertIn("--report-account authorize", result["nextStep"])
        self.write("gmail-auth.json", {"account": "other@example.test", "accounts": ["other@example.test", "REPORT@example.test"]})
        result = connector(self.diagnose({**address, "gmailOAuthClientPath": str(valid)}), "gmail")
        self.assertEqual(result["status"], "configured_unverified")

    def test_discord_requires_a_bot_token_in_the_sibling_credentials_file(self):
        self.write("credentials.json", {"slackToken": "xoxb-token"})
        discord = connector(self.diagnose({"discordGuildId": "1"}), "discord")
        self.assertEqual(discord["status"], "setup_required")
        self.assertIn("discordBotToken", discord["nextStep"])
        self.write("credentials.json", {"discordBotToken": "token", "slackToken": "xoxb-token"})
        result = self.diagnose({"discordGuildId": "1"})
        self.assertEqual(connector(result, "discord")["status"], "configured_unverified")
        self.assertEqual(connector(result, "slack")["status"], "configured_unverified")
        self.assertNotIn("xoxb-token", json.dumps(result))

    def test_github_requires_owner_name_repositories_and_an_installed_cli(self):
        bad = connector(self.diagnose({"githubRepositories": ["owner"]}), "github")
        self.assertIn("owner/name", bad["nextStep"])
        with mock.patch.object(MODULE, "GITHUB_CLI_CANDIDATES", ()), mock.patch.object(MODULE.shutil, "which", return_value=None):
            missing = connector(self.diagnose({"githubRepositories": ["owner/repo"]}), "github")
        self.assertEqual(missing["status"], "setup_required")
        self.assertIn("Install the GitHub CLI", missing["nextStep"])
        gh = self.root / "gh"
        sentinel = self.root / "ran"
        gh.write_text(f"#!/bin/sh\ntouch '{sentinel}'\n")
        gh.chmod(0o700)
        present = connector(self.diagnose({"githubRepositories": ["owner/repo"], "githubExecutable": str(gh)}), "github")
        self.assertEqual(present["status"], "configured_unverified")
        self.assertFalse(sentinel.exists())

    def test_github_cli_candidates_match_the_collector(self):
        self.assertEqual(MODULE.GITHUB_CLI_CANDIDATES, MORNING.GITHUB_CLI_CANDIDATES)

    def test_invalid_config_cli_returns_safe_structured_error(self):
        config = self.write("invalid.json", '{"secret": "sensitive-value"')
        result = subprocess.run([sys.executable, str(SCRIPT), "--config", str(config)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["errorCode"], "invalid_connector_config")
        self.assertNotIn("sensitive-value", result.stdout + result.stderr)


class PlatformScopedConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.path = self.root / "ingestion.json"

    def tearDown(self):
        self.temporary.cleanup()

    def load(self, payload, platforms=None, **keywords):
        self.path.write_text(json.dumps(payload))
        if platforms is not None:
            (self.root / "config.json").write_text(json.dumps({"dailyReport": {"enabledPlatforms": platforms}}))
        return MORNING.load_config(self.path, **keywords)

    def test_report_requires_only_enabled_platform_settings(self):
        core = {"dashboardPath": "d", "dashboardDirectory": "d", "agentExecutable": "x"}
        config = self.load(core, ["slack"])
        self.assertEqual(config["dailyReport"]["enabledPlatforms"], ["slack"])
        self.assertEqual(config["discordCredentialPath"], str(self.root / "credentials.json"))
        with self.assertRaisesRegex(MORNING.ReconciliationError, "discordGuildId"):
            self.load(core, ["discord", "slack"])
        with self.assertRaisesRegex(MORNING.ReconciliationError, "agentExecutable"):
            self.load({"dashboardPath": "d", "dashboardDirectory": "d"}, ["slack"])

    def test_telegram_bot_username_is_no_longer_required(self):
        core = {"dashboardPath": "d", "dashboardDirectory": "d", "agentExecutable": "x"}
        self.load(core, ["telegram"])

    def test_connector_cli_needs_only_its_own_settings(self):
        config = self.load({"discordGuildId": "1"}, connector="discord")
        self.assertEqual(config["discordGuildId"], "1")
        with self.assertRaisesRegex(MORNING.ReconciliationError, "emailAddress"):
            self.load({"discordGuildId": "1"}, connector="email")
        with self.assertRaisesRegex(MORNING.ReconciliationError, "gmailOAuthClientPath"):
            self.load({"emailProvider": "gmail", "emailAddress": "a@example.test"}, connector="email")
        self.load({"gmailAddress": "a@example.test"}, connector="gmail")

    def test_explicit_platforms_are_validated(self):
        with self.assertRaisesRegex(MORNING.ReconciliationError, "githubRepositories"):
            MORNING.require_platform_settings({}, {"github"})

    def test_missing_github_cli_names_the_fix(self):
        with mock.patch.object(MORNING, "GITHUB_CLI_CANDIDATES", ()), mock.patch.object(MORNING.shutil, "which", return_value=None):
            with self.assertRaisesRegex(MORNING.ReconciliationError, "brew install gh"):
                MORNING.resolve_github_cli({})


if __name__ == "__main__":
    unittest.main()
