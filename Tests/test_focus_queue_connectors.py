import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "Scripts/focus_queue_connectors.py"
SPEC = importlib.util.spec_from_file_location("focus_queue_connectors", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ConnectorDiagnosticsTests(unittest.TestCase):
    def test_diagnostics_do_not_echo_account_data_or_execute_configured_helper(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = root / "helper"
            sentinel = root / "executed"
            helper.write_text(f"#!/bin/sh\ntouch '{sentinel}'\n")
            helper.chmod(0o700)
            result = MODULE.diagnose({"telegramArchiveExecutable": str(helper), "emailAddress": "private@example.test", "discordBotToken": "secret-value"})
            serialized = json.dumps(result)
            self.assertNotIn("private@example.test", serialized)
            self.assertNotIn("secret-value", serialized)
            self.assertFalse(sentinel.exists())
            self.assertEqual(result["connectors"][0]["status"], "limited")
            self.assertFalse(result["connectors"][0]["personalInboxSupported"])

    def test_missing_configuration_is_setup_required(self):
        result = MODULE.diagnose({})
        self.assertTrue(all(connector["status"] == "setup_required" for connector in result["connectors"]))
        self.assertFalse(result["authenticationVerified"])

    def test_invalid_config_cli_returns_safe_structured_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "invalid.json"
            config.write_text('{"secret": "sensitive-value"')
            result = subprocess.run([sys.executable, str(SCRIPT), "--config", str(config)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)["errorCode"], "invalid_connector_config")
            self.assertNotIn("sensitive-value", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
