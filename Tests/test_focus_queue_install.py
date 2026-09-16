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
        automation = path / "Contents/Resources/automation"
        for relative in self.automation_files:
            destination = automation / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(b"worker:" + content + b":" + relative.encode())
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": MODULE.IDENTIFIER}))
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


if __name__ == "__main__":
    unittest.main()
