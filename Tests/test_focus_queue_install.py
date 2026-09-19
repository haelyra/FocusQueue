import importlib.util
import fcntl
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("installer", Path(__file__).parents[1] / "Scripts/focus_queue_install.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class InstallerTests(unittest.TestCase):
    automation_files = (
        "Scripts/focus_queue_morning.py",
        "Scripts/focus_queue_codex.py",
        "Scripts/focus_queue_lock.py",
        "Scripts/focus_queue_mail.py",
        "Scripts/focus_queue_discord.py",
        "Scripts/focus_queue_connectors.py",
        "Scripts/focus-queue-mail.js",
        "Config/task-proposals.schema.json",
    )

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "Another User"
        self.bundle = self.root / "Built.app"
        self.make_app(self.bundle, b"new executable")
        self.installer = MODULE.Installer(self.bundle, self.home, start=False)
        self.calls = []
        def run(args, **kwargs):
            self.calls.append(args)
            if args[0] == "/usr/bin/ditto":
                shutil.copytree(args[1], args[2])
            return subprocess.CompletedProcess(args, 0, "", "")
        self.mock_run = mock.patch.object(MODULE.subprocess, "run", side_effect=run)
        self.mock_run.start()
        self.addCleanup(self.mock_run.stop)

    def make_app(self, path, content):
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Resources").mkdir(parents=True)
        shutil.copy2(Path(__file__).parents[1] / "Config/CODEX_GLOBAL_INSTRUCTIONS.md",
                     path / "Contents/Resources/CODEX_GLOBAL_INSTRUCTIONS.md")
        shell = path / "Contents/Resources/shell"
        shell.mkdir()
        (shell / "focus_queue_codex_entry.py").write_bytes(b"entry:" + content)
        (shell / "focus_queue_usage_wrapper.sh").write_bytes(b"wrapper:" + content)
        automation = path / "Contents/Resources/automation"
        for relative in self.automation_files:
            destination = automation / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(b"worker:" + content + b":" + relative.encode())
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleDisplayName": MODULE.PRODUCT,
            "CFBundleExecutable": "ECCFocusQueue",
            "CFBundleIdentifier": MODULE.IDENTIFIER,
            "CFBundleName": MODULE.PRODUCT,
        }))
        for name in ("ECCFocusQueue", "focus-queue-session"):
            binary = path / "Contents/MacOS" / name
            binary.write_bytes(content)
            binary.chmod(0o755)

    def test_check_is_read_only_and_services_are_optional(self):
        result = self.installer.preflight()
        self.assertFalse(self.home.exists())
        self.assertFalse(result["launchAtLogin"])
        self.assertFalse(result["desktopShortcut"])
        self.assertEqual([call[0] for call in self.calls], ["/usr/bin/codesign"])

    def test_source_bundle_must_have_the_renamed_display_identity(self):
        info_path = self.bundle / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleDisplayName"] = MODULE.LEGACY_PRODUCT
        info_path.write_bytes(plistlib.dumps(info))

        with self.assertRaisesRegex(ValueError, "display identity"):
            self.installer.preflight()

    def test_paths_use_new_app_name_and_preserve_legacy_support_directory(self):
        self.assertEqual(self.installer.app, self.home / "Applications/Focus Queue.app")
        self.assertEqual(
            self.installer.legacy_app,
            self.home / "Applications/ECC Focus Queue.app",
        )
        self.assertEqual(
            self.installer.support,
            self.home / "Library/Application Support/ECC Focus Queue",
        )

    def test_verified_legacy_app_and_shortcut_are_migrated(self):
        self.make_app(self.installer.legacy_app, b"legacy executable")
        self.installer.legacy_desktop.parent.mkdir(parents=True)
        self.installer.legacy_desktop.symlink_to(self.installer.legacy_app)
        self.installer.agent.parent.mkdir(parents=True)
        self.installer.agent.write_bytes(plistlib.dumps({
            "Label": MODULE.IDENTIFIER,
            "ProgramArguments": [
                str(self.installer.legacy_app / "Contents/MacOS/ECCFocusQueue")
            ],
        }))

        result = self.installer.install()

        self.assertFalse(self.installer.legacy_app.exists())
        self.assertFalse(self.installer.legacy_desktop.exists())
        self.assertTrue(self.installer.app.exists())
        self.assertEqual(self.installer.desktop.readlink(), self.installer.app)
        agent = plistlib.loads(self.installer.agent.read_bytes())
        self.assertEqual(
            agent["ProgramArguments"],
            [str(self.installer.app / "Contents/MacOS/ECCFocusQueue")],
        )
        self.assertTrue(result["legacyApplicationMigrated"])

    def test_unverified_legacy_app_is_preserved_and_blocks_install(self):
        self.installer.legacy_app.parent.mkdir(parents=True)
        self.installer.legacy_app.write_text("unrelated application")

        with self.assertRaisesRegex(ValueError, "legacy app"):
            self.installer.install()

        self.assertEqual(self.installer.legacy_app.read_text(), "unrelated application")
        self.assertFalse(self.installer.app.exists())

    def test_legacy_app_with_invalid_code_signature_is_preserved(self):
        self.make_app(self.installer.legacy_app, b"legacy executable")

        def reject_legacy_signature(args, **kwargs):
            if args[0] == "/usr/bin/codesign" and args[-1] == str(self.installer.legacy_app):
                raise subprocess.CalledProcessError(1, args)
            return subprocess.CompletedProcess(args, 0, "", "")

        with mock.patch.object(
            MODULE.subprocess,
            "run",
            side_effect=reject_legacy_signature,
        ), self.assertRaisesRegex(ValueError, "legacy app"):
            self.installer.install()

        self.assertTrue(self.installer.legacy_app.exists())
        self.assertFalse(self.installer.app.exists())

    def test_global_prompt_install_is_idempotent_and_preserves_personal_text(self):
        prompt = self.home / ".codex/AGENTS.md"
        prompt.parent.mkdir(parents=True)
        personal = "# Personal\n\nKeep my exact words.\n\n"
        prompt.write_text(personal)
        self.installer.install()
        once = prompt.read_text()
        self.assertTrue(once.startswith(personal))
        self.assertEqual(once.count(MODULE.PROMPT_START), 1)
        self.installer.install()
        self.assertEqual(prompt.read_text(), once)
        manifest = json.loads(self.installer.manifest.read_text())
        self.assertNotIn(str(prompt), [entry["path"] for entry in manifest["artifacts"]])
        self.assertEqual(manifest["managedSettings"][0]["ownership"], "delimited-block-only")

    def test_malformed_global_prompt_markers_fail_without_overwriting(self):
        prompt = self.home / ".codex/AGENTS.md"
        prompt.parent.mkdir(parents=True)
        prompt.write_text("My notes\n" + MODULE.PROMPT_START)
        before = prompt.read_bytes()
        with self.assertRaises(ValueError):
            self.installer.install()
        self.assertEqual(prompt.read_bytes(), before)

    def test_existing_launcher_refresh_preserves_alias_and_uninstall_preserves_personal_prompt(self):
        self.make_app(self.installer.app, b"previous")
        entry = self.installer.codex_entry
        entry.parent.mkdir(parents=True)
        entry.write_bytes(b"entry:previous")
        usage_wrapper = self.installer.codex_usage_wrapper
        usage_wrapper.write_bytes(b"wrapper:previous")
        shell = entry.parent / "codex.zsh"
        shell.write_text("my configured aliases and flags")
        prompt = self.installer.codex_prompt
        prompt.parent.mkdir(parents=True)
        prompt.write_text("Personal text\n")
        self.installer.install()
        self.assertEqual(entry.read_bytes(), b"entry:new executable")
        self.assertEqual(usage_wrapper.read_bytes(), b"wrapper:new executable")
        self.assertEqual(shell.read_text(), "my configured aliases and flags")
        installed_prompt = prompt.read_bytes()
        MODULE.uninstall(self.home, stop=False)
        self.assertEqual(prompt.read_bytes(), installed_prompt)
        self.assertTrue(entry.exists())

    def test_changed_launcher_stops_install_without_clobbering(self):
        entry = self.installer.codex_entry
        entry.parent.mkdir(parents=True)
        entry.write_text("custom launcher")
        with self.assertRaises(ValueError):
            self.installer.install()
        self.assertEqual(entry.read_text(), "custom launcher")

    def test_second_user_install_and_reinstall_preserve_config_and_record_ownership(self):
        self.installer.support.mkdir(parents=True)
        config = self.installer.support / "config.json"
        config.write_text("user owned config")
        result = self.installer.install()
        self.assertEqual(config.read_text(), "user owned config")
        self.assertEqual(self.installer.helper.read_bytes(), b"new executable")
        self.assertEqual(
            (self.installer.automation / "Scripts/focus_queue_morning.py").read_bytes(),
            b"worker:new executable:Scripts/focus_queue_morning.py",
        )
        self.assertFalse(self.installer.agent.exists())
        self.assertFalse((self.home / "Applications/ECC Focus Mail Reader.app").exists())
        manifest = json.loads(self.installer.manifest.read_text())
        self.assertTrue(all(Path(item["path"]).is_relative_to(self.home) for item in manifest["artifacts"]))
        self.assertTrue(Path(result["backupDirectory"]).exists())
        self.installer.install()
        self.assertEqual(config.read_text(), "user owned config")
        self.assertEqual(
            (self.installer.automation / "Scripts/focus_queue_morning.py").read_bytes(),
            b"worker:new executable:Scripts/focus_queue_morning.py",
        )

    def test_unknown_app_helper_and_parent_symlink_are_preserved(self):
        for conflict in ["app", "helper", "parent"]:
            with self.subTest(conflict=conflict), tempfile.TemporaryDirectory() as temporary:
                home = Path(temporary) / "home"
                installer = MODULE.Installer(self.bundle, home, start=False)
                if conflict == "parent":
                    home.mkdir()
                    (home / "Applications").symlink_to(self.root)
                else:
                    path = installer.app if conflict == "app" else installer.helper
                    path.parent.mkdir(parents=True)
                    path.write_text("unrelated")
                with self.assertRaises(ValueError):
                    installer.install()
                if conflict != "parent":
                    self.assertEqual(path.read_text(), "unrelated")

    def test_automation_digest_distinguishes_file_boundaries(self):
        first = self.root / "first"
        second = self.root / "second"
        first.mkdir()
        second.mkdir()
        (first / "a").write_bytes(b"X")
        (first / "b").write_bytes(b"Y")
        (second / "a").write_bytes(b"X\0b\0Y")
        self.assertNotEqual(MODULE.tree_digest(first), MODULE.tree_digest(second))

    def test_automation_payload_rejects_missing_extra_and_symlink_entries(self):
        for scenario in ("missing", "extra", "symlink"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                bundle = Path(temporary) / "Built.app"
                self.make_app(bundle, b"payload")
                automation = bundle / "Contents/Resources/automation"
                if scenario == "missing":
                    (automation / "Scripts/focus_queue_codex.py").unlink()
                elif scenario == "extra":
                    (automation / "Scripts/unexpected.py").write_text("unexpected")
                else:
                    source = automation / "Scripts/focus_queue_connectors.py"
                    source.unlink()
                    source.symlink_to(Path(temporary) / "outside")
                with self.assertRaisesRegex(ValueError, "automation"):
                    MODULE.Installer(bundle, Path(temporary) / "home", start=False).preflight()

    def test_uninstall_uses_the_installation_lock(self):
        self.installer.install()
        lock_path = self.installer.support / "install.lock"
        with lock_path.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                MODULE.uninstall(self.home, stop=False)
        self.assertTrue(self.installer.app.exists())

    def test_upgrade_accepts_and_replaces_a_verified_legacy_automation_digest(self):
        self.installer.install()
        legacy = hashlib.sha256()
        for item in sorted(self.installer.automation.rglob("*")):
            if item.is_file():
                legacy.update(str(item.relative_to(self.installer.automation)).encode())
                legacy.update(b"\0")
                legacy.update(item.read_bytes())
                legacy.update(b"\0")
        manifest = json.loads(self.installer.manifest.read_text())
        automation = next(
            item for item in manifest["artifacts"]
            if item["path"] == str(self.installer.automation)
        )
        automation["sha256"] = legacy.hexdigest()
        automation.pop("digestAlgorithm", None)
        self.installer.manifest.write_text(json.dumps(manifest))

        self.installer.install()

        upgraded = json.loads(self.installer.manifest.read_text())
        automation = next(
            item for item in upgraded["artifacts"]
            if item["path"] == str(self.installer.automation)
        )
        self.assertEqual(automation["digestAlgorithm"], "sha256-tree-v1")

    def test_legacy_automation_digest_rejects_nul_content(self):
        self.installer.install()
        target = self.installer.automation / "Scripts/focus_queue_codex.py"
        target.write_bytes(target.read_bytes() + b"\0Scripts/focus_queue_lock.py\0")
        legacy = hashlib.sha256()
        for item in sorted(self.installer.automation.rglob("*")):
            if item.is_file():
                legacy.update(str(item.relative_to(self.installer.automation)).encode())
                legacy.update(b"\0")
                legacy.update(item.read_bytes())
                legacy.update(b"\0")
        manifest = json.loads(self.installer.manifest.read_text())
        automation = next(
            item for item in manifest["artifacts"]
            if item["path"] == str(self.installer.automation)
        )
        automation["sha256"] = legacy.hexdigest()
        automation.pop("digestAlgorithm", None)
        self.installer.manifest.write_text(json.dumps(manifest))

        with self.assertRaisesRegex(ValueError, "NUL"):
            self.installer.preflight()

    def test_launch_failure_restores_old_app_helper_and_manifest(self):
        self.installer.install()
        before = self.installer.manifest.read_bytes()
        self.make_app(self.root / "Next.app", b"next executable")
        replacement = MODULE.Installer(self.root / "Next.app", self.home, start=True)
        with mock.patch.object(replacement, "stop"), mock.patch.object(replacement, "start_app", side_effect=[RuntimeError("injected start failure"), None]) as start:
            with self.assertRaisesRegex(RuntimeError, "injected start failure"):
                replacement.install()
        self.assertEqual(self.installer.helper.read_bytes(), b"new executable")
        self.assertEqual((self.installer.app / "Contents/MacOS/ECCFocusQueue").read_bytes(), b"new executable")
        self.assertEqual(self.installer.manifest.read_bytes(), before)
        self.assertEqual(start.call_count, 2)

    def test_legacy_upgrade_failure_restores_and_restarts_legacy_app(self):
        self.make_app(self.installer.legacy_app, b"legacy executable")
        self.installer.start = True
        with mock.patch.object(self.installer, "stop"), mock.patch.object(
            self.installer,
            "start_app",
            side_effect=[RuntimeError("injected start failure"), None],
        ) as start:
            with self.assertRaisesRegex(RuntimeError, "injected start failure"):
                self.installer.install()

        self.assertTrue(self.installer.legacy_app.exists())
        self.assertFalse(self.installer.app.exists())
        self.assertEqual(
            start.call_args_list[-1],
            mock.call(login=False, application=self.installer.legacy_app),
        )

    def test_rollback_does_not_restart_legacy_app_if_replacement_will_not_stop(self):
        self.make_app(self.installer.legacy_app, b"legacy executable")
        self.installer.start = True
        with mock.patch.object(
            self.installer,
            "stop",
            side_effect=[None, RuntimeError("replacement is still running")],
        ), mock.patch.object(
            self.installer,
            "start_app",
            side_effect=RuntimeError("ambiguous launch failure"),
        ) as start:
            with self.assertRaisesRegex(RuntimeError, "not restarted"):
                self.installer.install()

        self.assertTrue(self.installer.legacy_app.exists())
        self.assertFalse(self.installer.app.exists())
        self.assertEqual(start.call_count, 1)

    def test_stop_terminates_new_and_legacy_app_executables(self):
        renamed_executable = self.installer.app / "Contents/MacOS/ECCFocusQueue"
        legacy_executable = self.installer.legacy_app / "Contents/MacOS/ECCFocusQueue"
        process_checks = 0

        def run(args, **kwargs):
            nonlocal process_checks
            if args[:2] == ["/bin/ps", "-axo"]:
                process_checks += 1
                return subprocess.CompletedProcess(
                    args,
                    0,
                    (
                        f"123 {renamed_executable}\n456 {legacy_executable}\n"
                        if process_checks == 1
                        else ""
                    ),
                    "",
                )
            return subprocess.CompletedProcess(args, 0, "", "")

        with mock.patch.object(MODULE.subprocess, "run", side_effect=run), mock.patch.object(
            MODULE.os,
            "kill",
        ) as kill:
            self.installer.stop()

        self.assertEqual(kill.call_args_list, [mock.call(123, 15), mock.call(456, 15)])
        self.assertEqual(process_checks, 2)

    def test_stop_fails_closed_when_a_legacy_process_does_not_exit(self):
        legacy_executable = self.installer.legacy_app / "Contents/MacOS/ECCFocusQueue"

        def run(args, **kwargs):
            if args[:2] == ["/bin/ps", "-axo"]:
                return subprocess.CompletedProcess(
                    args,
                    0,
                    f"456 {legacy_executable}\n",
                    "",
                )
            return subprocess.CompletedProcess(args, 0, "", "")

        with mock.patch.object(MODULE.subprocess, "run", side_effect=run), mock.patch.object(
            MODULE.os,
            "kill",
        ), mock.patch.object(MODULE.time, "sleep"):
            with self.assertRaisesRegex(RuntimeError, "still running"):
                self.installer.stop()

    def test_copy_failure_does_not_stop_app(self):
        original = MODULE.subprocess.run.side_effect
        def fail_copy(args, **kwargs):
            if args[0] == "/usr/bin/ditto":
                raise OSError("copy failed")
            return original(args, **kwargs)
        self.installer.start = True
        with mock.patch.object(MODULE.subprocess, "run", side_effect=fail_copy), mock.patch.object(self.installer, "stop") as stop:
            with self.assertRaises(OSError):
                self.installer.install()
            stop.assert_not_called()

    def test_login_and_shortcut_are_explicit_and_persist_on_upgrade(self):
        self.installer.login = True
        self.installer.shortcut = True
        self.installer.install()
        agent = plistlib.loads(self.installer.agent.read_bytes())
        self.assertEqual(agent["ProgramArguments"], [str(self.installer.app / "Contents/MacOS/ECCFocusQueue")])
        self.assertEqual(self.installer.desktop.readlink(), self.installer.app)
        next_install = MODULE.Installer(self.bundle, self.home, start=False)
        result = next_install.preflight()
        self.assertTrue(result["launchAtLogin"])
        self.assertTrue(result["desktopShortcut"])

    def test_uninstall_retains_data_and_rejects_changed_files_or_manifest_escape(self):
        self.installer.install()
        config = self.installer.support / "config.json"
        config.write_text("saved tasks and settings")
        preview = MODULE.uninstall(self.home, check=True, stop=False)
        self.assertEqual(preview["mode"], "uninstall-preview")
        self.installer.helper.write_bytes(b"user changed this")
        with self.assertRaises(ValueError):
            MODULE.uninstall(self.home, stop=False)
        self.assertTrue(self.installer.app.exists())
        self.installer.helper.write_bytes(b"new executable")
        manifest = json.loads(self.installer.manifest.read_text())
        manifest["artifacts"].append({"path": str(config), "kind": "file", "sha256": MODULE.digest(config)})
        self.installer.manifest.write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            MODULE.uninstall(self.home, stop=False)
        manifest["artifacts"].pop()
        self.installer.manifest.write_text(json.dumps(manifest))
        result = MODULE.uninstall(self.home, stop=False)
        self.assertEqual(config.read_text(), "saved tasks and settings")
        self.assertFalse(self.installer.app.exists())
        self.assertTrue(Path(result["backupDirectory"]).exists())

    def test_uninstall_accepts_verified_manifest_owned_legacy_app(self):
        self.installer.install()
        self.installer.app.rename(self.installer.legacy_app)
        manifest = json.loads(self.installer.manifest.read_text())
        app_artifact = next(
            artifact
            for artifact in manifest["artifacts"]
            if artifact["path"] == str(self.installer.app)
        )
        app_artifact["path"] = str(self.installer.legacy_app)
        self.installer.manifest.write_text(json.dumps(manifest))

        result = MODULE.uninstall(self.home, stop=False)

        self.assertEqual(result["mode"], "uninstalled")
        self.assertFalse(self.installer.legacy_app.exists())


if __name__ == "__main__":
    unittest.main()
