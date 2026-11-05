import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "Scripts/focus_queue_setup.py"
SPEC = importlib.util.spec_from_file_location("focus_queue_setup", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SetupPreviewTests(unittest.TestCase):
    def preview(self, home, **kwargs):
        return MODULE.preview(home=home, workspace=home / "Workspace with spaces", platform_name="darwin", system_bins=(), application_roots=(), **kwargs)

    def test_second_user_home_and_spaces_have_no_original_user_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "Another User"
            home.mkdir()
            result = self.preview(home)
            self.assertEqual(result["home"], str(home))
            self.assertEqual(result["workspace"]["kind"], "missing")
            self.assertNotIn("/Users/hira", json.dumps(result))
            self.assertTrue(all(Path(path["path"]).is_relative_to(home) for path in result["plannedPaths"]))
            self.assertEqual(list(home.iterdir()), [])
            self.assertFalse(result["installationReady"])

    def test_preview_uses_new_app_name_and_preserves_existing_support_location(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            paths = {path["purpose"]: path for path in self.preview(home)["plannedPaths"]}

            self.assertEqual(
                paths["application"]["path"],
                str(home / "Applications/Focus Queue.app"),
            )
            self.assertEqual(
                paths["support_directory"]["path"],
                str(home / "Library/Application Support/ECC Focus Queue"),
            )

    def test_optional_features_are_unselected_and_missing_dependencies_are_explicit(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = self.preview(Path(temporary))
            self.assertTrue(all(not capability["selected"] for capability in result["capabilities"]))
            agent = next(c for c in result["capabilities"] if c["id"] == "agent_chat")
            self.assertEqual(agent["missingToolGroups"], [["codex"], ["python3"]])
            self.assertTrue(all(tool["status"] == "missing" for tool in result["tools"]))

    def test_detected_providers_are_never_executed_or_treated_as_authenticated(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            binary = home / ".local/bin/codex"
            binary.parent.mkdir(parents=True)
            sentinel = home / "executed"
            binary.write_text(f"#!/bin/sh\ntouch '{sentinel}'\n")
            binary.chmod(0o700)
            result = self.preview(home, selected=["agent_chat"])
            tool = next(tool for tool in result["tools"] if tool["id"] == "codex")
            self.assertEqual(tool["status"], "detected_unverified")
            self.assertFalse(tool["authenticationVerified"])
            self.assertFalse(tool["compatibilityVerified"])
            self.assertIsNone(tool["version"])
            self.assertFalse(sentinel.exists())

    def test_agent_launch_needs_tmux_and_a_provider_but_not_wezterm(self):
        groups = MODULE.CAPABILITIES["agent_launch"][1]
        self.assertTrue(any("tmux" in group for group in groups))
        self.assertFalse(any(group == ("wezterm",) for group in groups))
        self.assertEqual(MODULE.CAPABILITIES["terminal_focus"][1], ())
        for name, (_, requirements, _) in MODULE.CAPABILITIES.items():
            self.assertNotIn(("wezterm",), requirements, name)

    def test_app_executables_and_symlinked_binaries_are_only_candidates(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            binary = home / "Applications/WezTerm.app/Contents/MacOS/wezterm"
            binary.parent.mkdir(parents=True)
            binary.write_text("never run me")
            binary.chmod(0o700)
            link = home / ".local/bin/wezterm"
            link.parent.mkdir(parents=True)
            link.symlink_to(binary)
            tool = next(t for t in self.preview(home)["tools"] if t["id"] == "wezterm")
            self.assertEqual(len(tool["candidates"]), 2)
            self.assertEqual(tool["candidates"][0]["kind"], "symlink")
            self.assertFalse(tool["compatibilityVerified"])

    def test_non_executable_and_broken_link_do_not_satisfy_dependencies(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            directory = home / ".local/bin"
            directory.mkdir(parents=True)
            (directory / "codex").write_text("configuration, not an executable")
            (directory / "claude").symlink_to(home / "missing-target")
            tools = {tool["id"]: tool for tool in self.preview(home)["tools"]}
            self.assertEqual(tools["codex"]["status"], "missing")
            self.assertEqual(tools["claude"]["status"], "missing")

    def test_existing_unrelated_destinations_and_symlinks_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            app = home / "Applications/Focus Queue.app"
            app.parent.mkdir()
            app.write_text("unrelated app contents")
            desktop = home / "Desktop"
            desktop.mkdir()
            (desktop / "Focus Queue.app").symlink_to(home / "missing-target")
            result = self.preview(home, selected=["desktop_shortcut"])
            paths = {path["purpose"]: path for path in result["plannedPaths"]}
            self.assertEqual(paths["application"]["status"], "existing_unverified")
            self.assertEqual(paths["desktop_shortcut"]["status"], "symlink_conflict")
            self.assertEqual(result["selectedConflictCount"], 2)
            self.assertEqual(app.read_text(), "unrelated app contents")
            self.assertTrue((desktop / "Focus Queue.app").is_symlink())

    def test_symlink_or_file_parent_blocks_child_destinations(self):
        for kind in ["symlink", "file"]:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                home = Path(temporary) / "fixture"
                home.mkdir()
                parent = home / "Library"
                if kind == "symlink":
                    parent.symlink_to(Path(temporary) / "outside")
                else:
                    parent.write_text("unrelated file")
                result = self.preview(home)
                support = next(path for path in result["plannedPaths"] if path["purpose"] == "support_directory")
                self.assertEqual(support["status"], "blocked_parent")
                self.assertEqual(support["conflictPath"], str(parent))
                self.assertFalse((Path(temporary) / "outside").exists())

    def test_inaccessible_destination_is_a_conflict(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            original = MODULE.metadata
            def inspect(path):
                return "inaccessible" if path == home / "Applications" else original(path)
            with mock.patch.object(MODULE, "metadata", side_effect=inspect):
                result = self.preview(home)
            app = next(p for p in result["plannedPaths"] if p["purpose"] == "application")
            self.assertEqual(app["status"], "blocked_parent")

    def test_no_profiles_credentials_tool_execution_network_or_model_spending(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            for name in [".zshrc", ".bash_profile", "credentials.json"]:
                (home / name).write_text("private-token-value")
            with mock.patch.object(Path, "open", side_effect=AssertionError("file content read")), \
                 mock.patch("subprocess.Popen", side_effect=AssertionError("process launched")), \
                 mock.patch("socket.socket", side_effect=AssertionError("network accessed")), \
                 mock.patch.dict(os.environ, {"SECRET_TOKEN": "private-token-value"}):
                result = self.preview(home, selected=list(MODULE.CAPABILITIES))
            self.assertNotIn("private-token-value", json.dumps(result))
            self.assertTrue(all(value == 0 for value in result["effects"].values()))
            self.assertEqual(len(list(home.iterdir())), 3)

    def test_unsupported_platform_has_no_mac_install_plan(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            result = MODULE.preview(home=home, workspace=home, platform_name="linux", system_bins=(), application_roots=())
            self.assertEqual(result["platform"]["status"], "unsupported")
            self.assertEqual(result["plannedPaths"], [])
            self.assertFalse(result["installationReady"])

    def test_shared_paths_follow_selected_capability_without_enabling_others(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = self.preview(Path(temporary), selected=["daily_reports"])
            paths = {path["purpose"]: path for path in result["plannedPaths"]}
            for purpose in ["automation_runtime", "agent_helper", "source_configuration", "source_cache", "report_helper"]:
                self.assertTrue(paths[purpose]["selected"], purpose)
            self.assertFalse(paths["mail_reader"]["selected"])
            selected = [c["id"] for c in result["capabilities"] if c["selected"]]
            self.assertEqual(selected, ["daily_reports"])

    def test_telegram_personal_inbox_is_unavailable_even_when_selected(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = self.preview(Path(temporary), selected=["telegram_connector"])
            telegram = next(c for c in result["capabilities"] if c["id"] == "telegram_connector")
            self.assertEqual(telegram["status"], "personal_inbox_unavailable")
            self.assertFalse(result["installationReady"])

    def test_relative_paths_and_unknown_capabilities_are_rejected(self):
        with self.assertRaises(ValueError):
            self.preview(Path("relative"))
        with tempfile.TemporaryDirectory() as temporary, self.assertRaises(ValueError):
            self.preview(Path(temporary), selected=["execute_everything"])

    def test_cli_emits_json_without_creating_fixture_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "Second User"
            result = subprocess.run([sys.executable, str(SCRIPT), "--home", str(home), "--workspace", str(home / "workspace"), "--enable", "login_launch"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = json.loads(result.stdout)
            self.assertTrue(output["readOnly"])
            self.assertFalse(home.exists())
            invalid = subprocess.run([sys.executable, str(SCRIPT), "--home", "relative"], capture_output=True, text=True)
            self.assertEqual(invalid.returncode, 1)
            self.assertEqual(json.loads(invalid.stdout)["errorCode"], "invalid_setup_paths")


if __name__ == "__main__":
    unittest.main()
