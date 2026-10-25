import importlib.util
import fcntl
import hashlib
import json
import os
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
    repository_identity = "github.com/haelyra/eccfocusqueue"
    first_revision = "a" * 40
    automation_files = (
        "Scripts/focus_queue_morning.py",
        "Scripts/focus_queue_codex.py",
        "Scripts/focus_queue_claude.py",
        "Scripts/focus_queue_kimi.py",
        "Scripts/focus_queue_lock.py",
        "Scripts/focus_queue_mail.py",
        "Scripts/focus_queue_gmail.py",
        "Scripts/focus_queue_discord.py",
        "Scripts/focus_queue_slack.py",
        "Scripts/focus_queue_connectors.py",
        "Scripts/focus_queue_triage.py",
        "Scripts/focus_queue_extractor.py",
        "Scripts/focus_queue_prompt_usage.py",
        "Scripts/focus-queue-mail.js",
        "Config/task-proposals.schema.json",
    )

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "Another User"
        self.bundle = self.root / "Built.app"
        self.live_revision = self.first_revision
        self.make_app(self.bundle, b"new executable")
        self.installer = MODULE.Installer(
            self.bundle, self.home, start=False
        )
        self.calls = []
        def run(args, **kwargs):
            self.calls.append(args)
            if args[0] == "/usr/bin/ditto":
                shutil.copytree(args[1], args[2])
            if args[:3] == ["/usr/bin/git", "ls-remote", "--exit-code"]:
                return subprocess.CompletedProcess(
                    args, 0, f"{self.live_revision}\t{args[-1]}\n", ""
                )
            return subprocess.CompletedProcess(args, 0, "", "")
        self.mock_run = mock.patch.object(MODULE.subprocess, "run", side_effect=run)
        self.mock_run.start()
        self.addCleanup(self.mock_run.stop)
        self.mock_download = mock.patch.object(
            MODULE.urllib.request,
            "urlopen",
            side_effect=OSError("network is unavailable in tests"),
        )
        self.mock_download.start()
        self.addCleanup(self.mock_download.stop)

    def make_app(self, path, content):
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Resources").mkdir(parents=True)
        shutil.copy2(Path(__file__).parents[1] / "Config/CODEX_GLOBAL_INSTRUCTIONS.md",
                     path / "Contents/Resources/CODEX_GLOBAL_INSTRUCTIONS.md")
        shutil.copy2(Path(__file__).parents[1] / "Config/CLAUDE_GLOBAL_INSTRUCTIONS.md",
                     path / "Contents/Resources/CLAUDE_GLOBAL_INSTRUCTIONS.md")
        shell = path / "Contents/Resources/shell"
        shell.mkdir()
        (shell / "focus_queue_codex_entry.py").write_bytes(b"entry:" + content)
        (shell / "focus_queue_claude_entry.py").write_bytes(b"claude-entry:" + content)
        (shell / "focus_queue_usage_wrapper.sh").write_bytes(b"wrapper:" + content)
        (shell / "focus_queue_codex_bar.js").write_bytes(b"renderer:" + content)
        (shell / "AgentUsageBar-LICENSE.txt").write_bytes(b"license:" + content)
        (shell / "focus_queue_fq.py").write_bytes(b"fq:" + content)
        (shell / "focus_queue_placement.py").write_bytes(b"placement:" + content)
        (shell / "focus_queue_prompt_usage.py").write_bytes(b"usage:" + content)
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
        self.write_provenance(path)
        for name in ("ECCFocusQueue", "focus-queue-session", "focus-queue-map"):
            binary = path / "Contents/MacOS" / name
            binary.write_bytes(content)
            binary.chmod(0o755)

    def write_provenance(
        self,
        path,
        *,
        revision=None,
        reachable=None,
        integration_revision=None,
        integration_ref="origin/main",
        repository_identity=None,
        dirty=False,
    ):
        revision = revision or self.first_revision
        provenance = {
            "schemaVersion": 1,
            "repositoryIdentity": repository_identity or self.repository_identity,
            "originURL": "https://github.com/haelyra/ECCFocusQueue.git",
            "revision": revision,
            "branch": "main",
            "dirty": dirty,
            "integrationRef": integration_ref,
            "integrationRevision": integration_revision or revision,
            "reachableRevisions": reachable or [revision],
            "builtAt": "2026-09-21T21:00:00Z",
        }
        target = path / "Contents/Resources/source-provenance.json"
        target.write_text(json.dumps(provenance, indent=2) + "\n")
        return provenance

    def test_check_is_read_only_and_services_are_optional(self):
        result = self.installer.preflight()
        self.assertFalse(self.home.exists())
        self.assertFalse(result["launchAtLogin"])
        self.assertFalse(result["desktopShortcut"])
        self.assertEqual(
            [call[0] for call in self.calls],
            ["/usr/bin/codesign", "/usr/bin/git"],
        )

    def test_first_install_records_source_provenance_in_v2_receipt(self):
        self.installer.install()

        manifest = json.loads(self.installer.manifest.read_text())
        self.assertEqual(manifest["version"], 2)
        self.assertEqual(
            manifest["sourceProvenance"]["revision"], self.first_revision
        )
        self.assertEqual(
            manifest["sourceProvenance"]["repositoryIdentity"],
            self.repository_identity,
        )

    def test_integrated_descendant_replaces_installed_revision(self):
        self.installer.install()
        second_revision = "b" * 40
        replacement_bundle = self.root / "Integrated.app"
        self.make_app(replacement_bundle, b"integrated executable")
        self.write_provenance(
            replacement_bundle,
            revision=second_revision,
            reachable=[second_revision, self.first_revision],
            integration_revision=second_revision,
        )
        self.live_revision = second_revision

        MODULE.Installer(replacement_bundle, self.home, start=False).install()

        manifest = json.loads(self.installer.manifest.read_text())
        self.assertEqual(manifest["sourceProvenance"]["revision"], second_revision)
        self.assertEqual(
            (self.installer.app / "Contents/MacOS/ECCFocusQueue").read_bytes(),
            b"integrated executable",
        )

    def test_divergent_release_is_rejected_before_stop_or_replacement(self):
        self.installer.install()
        before_app = (self.installer.app / "Contents/MacOS/ECCFocusQueue").read_bytes()
        before_manifest = self.installer.manifest.read_bytes()
        sibling_revision = "c" * 40
        replacement_bundle = self.root / "Sibling.app"
        self.make_app(replacement_bundle, b"sibling executable")
        self.write_provenance(
            replacement_bundle,
            revision=sibling_revision,
            reachable=[sibling_revision],
            integration_revision=sibling_revision,
        )
        replacement = MODULE.Installer(replacement_bundle, self.home, start=True)

        with mock.patch.object(replacement, "stop") as stop, self.assertRaisesRegex(
            ValueError, "does not contain the installed revision"
        ):
            replacement.install()

        stop.assert_not_called()
        self.assertEqual(
            (self.installer.app / "Contents/MacOS/ECCFocusQueue").read_bytes(),
            before_app,
        )
        self.assertEqual(self.installer.manifest.read_bytes(), before_manifest)

    def test_feature_branch_build_is_rejected_until_revision_reaches_integration_ref(self):
        self.installer.install()
        feature_revision = "d" * 40
        replacement_bundle = self.root / "Feature.app"
        self.make_app(replacement_bundle, b"feature executable")
        self.write_provenance(
            replacement_bundle,
            revision=feature_revision,
            reachable=[feature_revision, self.first_revision],
            integration_revision=self.first_revision,
        )

        with self.assertRaisesRegex(ValueError, "canonical integration revision"):
            MODULE.Installer(replacement_bundle, self.home, start=False).install()

    def test_artifact_is_rejected_if_remote_main_advanced_after_build(self):
        self.installer.install()
        before_app = (self.installer.app / "Contents/MacOS/ECCFocusQueue").read_bytes()
        before_manifest = self.installer.manifest.read_bytes()
        self.live_revision = "e" * 40
        replacement = MODULE.Installer(self.bundle, self.home, start=True)

        with mock.patch.object(replacement, "stop") as stop, self.assertRaisesRegex(
            ValueError, "no longer the live canonical integration revision"
        ):
            replacement.install()

        stop.assert_not_called()
        self.assertEqual(
            (self.installer.app / "Contents/MacOS/ECCFocusQueue").read_bytes(),
            before_app,
        )
        self.assertEqual(self.installer.manifest.read_bytes(), before_manifest)

    def test_candidate_cannot_select_a_different_integration_ref(self):
        self.write_provenance(self.bundle, integration_ref="HEAD")

        with self.assertRaisesRegex(ValueError, "canonical integration ref"):
            self.installer.install()

    def test_dirty_missing_and_mismatched_provenance_are_rejected(self):
        scenarios = ("dirty", "missing", "repository")
        for scenario in scenarios:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                bundle = root / "Candidate.app"
                self.make_app(bundle, b"candidate")
                if scenario == "dirty":
                    self.write_provenance(bundle, dirty=True)
                elif scenario == "missing":
                    (bundle / "Contents/Resources/source-provenance.json").unlink()
                else:
                    self.write_provenance(
                        bundle, repository_identity="github.com/example/other"
                    )
                home = root / "home"
                installed = root / "Installed.app"
                self.make_app(installed, b"installed")
                first = MODULE.Installer(installed, home, start=False)
                first.install()

                expected = {
                    "dirty": "uncommitted changes",
                    "missing": "source provenance",
                    "repository": "repository identity is inconsistent",
                }[scenario]
                with self.assertRaisesRegex(ValueError, expected):
                    MODULE.Installer(bundle, home, start=False).install()

    def test_foreign_repository_cannot_seed_the_first_receipt(self):
        self.write_provenance(
            self.bundle, repository_identity="github.com/example/impostor"
        )
        provenance_path = self.bundle / "Contents/Resources/source-provenance.json"
        provenance = json.loads(provenance_path.read_text())
        provenance["originURL"] = "https://github.com/example/impostor.git"
        provenance_path.write_text(json.dumps(provenance, indent=2) + "\n")

        with self.assertRaisesRegex(ValueError, "official repository"):
            self.installer.install()

    def test_provenance_origin_must_match_its_repository_identity(self):
        provenance_path = self.bundle / "Contents/Resources/source-provenance.json"
        provenance = json.loads(provenance_path.read_text())
        provenance["originURL"] = "https://github.com/example/other.git"
        provenance_path.write_text(json.dumps(provenance, indent=2) + "\n")

        with self.assertRaisesRegex(ValueError, "repository identity is inconsistent"):
            self.installer.install()

    def test_global_contract_forbids_rewriting_or_bypassing_main_delivery(self):
        payload = (
            Path(__file__).parents[1] / "Config/CODEX_GLOBAL_INSTRUCTIONS.md"
        ).read_text()

        self.assertIn("fast-forward-only", payload)
        self.assertIn("Never reset the integration branch", payload)
        self.assertIn("bypass repository push guards", payload)
        self.assertIn("verify the remote integration ref equals the local commit", payload)

    def test_global_contract_maps_report_stages_to_existing_task_statuses(self):
        repository = Path(__file__).parents[1]
        output_contract = (
            repository / "Docs/output-design/agent-output-contract.md"
        ).read_text()
        self.assertIn("`backlog` → `idea`", output_contract)
        self.assertIn("`qa` → `deployed-verification`", output_contract)
        self.assertNotIn("qa-in-progress", output_contract)

        for name in (
            "Config/CODEX_GLOBAL_INSTRUCTIONS.md",
            "Config/CLAUDE_GLOBAL_INSTRUCTIONS.md",
        ):
            with self.subTest(name=name):
                payload = (repository / name).read_text()
                self.assertIn("Task status follows report stage", payload)
                self.assertIn("`backlog` is the default", payload)
                self.assertIn(
                    'focus-queue-session task status "$FOCUS_QUEUE_TASK_ID" in-progress',
                    payload,
                )
                self.assertIn(
                    'focus-queue-session task status "$FOCUS_QUEUE_TASK_ID" qa',
                    payload,
                )
                self.assertNotIn("qa-in-progress", payload)

    def test_provenance_rejects_a_symlinked_resources_parent(self):
        resources = self.bundle / "Contents/Resources"
        external = self.root / "ExternalResources"
        resources.rename(external)
        resources.symlink_to(external, target_is_directory=True)

        with self.assertRaisesRegex(ValueError, "symlinked bundle path"):
            self.installer.preflight()

    def test_installer_rejects_a_symlinked_shell_resource_parent(self):
        shell = self.bundle / "Contents/Resources/shell"
        external = self.root / "ExternalShell"
        shell.rename(external)
        shell.symlink_to(external, target_is_directory=True)

        with self.assertRaisesRegex(ValueError, "symlinked bundle path"):
            self.installer.preflight()

    def test_installer_rejects_a_symlinked_map_executable(self):
        executable = self.bundle / "Contents/MacOS/focus-queue-map"
        executable.unlink()
        executable.symlink_to(self.root / "external-map")

        with self.assertRaisesRegex(ValueError, "symlinked bundle path"):
            self.installer.preflight()

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
        prompt = self.home / "Documents/AGENTS.md"
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

    def test_claude_global_prompt_merges_beside_codex_and_stays_idempotent(self):
        prompt = self.home / "Documents/CLAUDE.md"
        prompt.parent.mkdir(parents=True)
        personal = "# Personal\n\nKeep my exact words.\n\n"
        prompt.write_text(personal)
        self.installer.install()
        once = prompt.read_text()
        self.assertTrue(once.startswith(personal))
        self.assertEqual(once.count(MODULE.PROMPT_START), 1)
        self.assertIn("installed `claude` shell entry", once)
        codex_prompt = (self.home / "Documents/AGENTS.md").read_text()
        self.assertIn("installed `codex` shell entry", codex_prompt)
        self.assertEqual(codex_prompt.count(MODULE.PROMPT_START), 1)
        self.installer.install()
        self.assertEqual(prompt.read_text(), once)
        self.assertEqual((self.home / "Documents/AGENTS.md").read_text(), codex_prompt)

    def test_malformed_claude_global_prompt_markers_fail_without_overwriting(self):
        prompt = self.home / "Documents/CLAUDE.md"
        prompt.parent.mkdir(parents=True)
        prompt.write_text("My notes\n" + MODULE.PROMPT_START)
        before = prompt.read_bytes()
        with self.assertRaises(ValueError):
            self.installer.install()
        self.assertEqual(prompt.read_bytes(), before)

    def test_malformed_global_prompt_markers_fail_without_overwriting(self):
        prompt = self.home / "Documents/AGENTS.md"
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
        self.assertEqual(self.installer.codex_usage_renderer.read_bytes(), b"renderer:new executable")
        self.assertEqual(self.installer.codex_usage_license.read_bytes(), b"license:new executable")
        self.assertEqual(shell.read_text(), "my configured aliases and flags")
        installed_prompt = prompt.read_bytes()
        MODULE.uninstall(self.home, stop=False)
        self.assertEqual(prompt.read_bytes(), installed_prompt)
        self.assertTrue(entry.exists())

    def test_installed_fq_refreshes_with_the_claude_entry_it_dispatches(self):
        self.make_app(self.installer.app, b"previous")
        dispatcher, placement, analytics, claude_entry = self.installer.fq_files
        dispatcher.parent.mkdir(parents=True)
        dispatcher.write_bytes(b"fq:previous")
        placement.write_bytes(b"placement:previous")
        self.installer.install()
        self.assertEqual(dispatcher.read_bytes(), b"fq:new executable")
        self.assertEqual(placement.read_bytes(), b"placement:new executable")
        self.assertEqual(analytics.read_bytes(), b"usage:new executable")
        self.assertEqual(claude_entry.read_bytes(), b"claude-entry:new executable")
        manifest = json.loads(self.installer.manifest.read_text())
        self.assertNotIn(str(dispatcher), [artifact["path"] for artifact in manifest["artifacts"]],
                         "Uninstall must leave fq to the shell-entry installers")
        self.assertIn({"path": str(dispatcher), "ownership": "configured-entry-support"},
                      manifest["managedSettings"])

    def test_app_install_never_creates_fq(self):
        self.installer.install()
        for path in self.installer.fq_files:
            self.assertFalse(path.exists(), path.name)

    def test_locally_changed_fq_stops_install_without_clobbering(self):
        self.make_app(self.installer.app, b"previous")
        dispatcher, placement = self.installer.fq_files[:2]
        dispatcher.parent.mkdir(parents=True)
        dispatcher.write_bytes(b"fq:previous")
        placement.write_bytes(b"my local placement tweak")
        with self.assertRaisesRegex(ValueError, "focus_queue_placement.py has local changes"):
            self.installer.install()
        self.assertEqual(placement.read_bytes(), b"my local placement tweak")
        self.assertEqual(dispatcher.read_bytes(), b"fq:previous")

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

    def test_upgrade_accepts_a_verified_previous_automation_file_manifest(self):
        self.installer.install()
        gmail = self.installer.automation / "Scripts/focus_queue_gmail.py"
        gmail.unlink()
        manifest = json.loads(self.installer.manifest.read_text())
        automation = next(
            item for item in manifest["artifacts"]
            if item["path"] == str(self.installer.automation)
        )
        automation["sha256"] = MODULE.tree_digest(self.installer.automation)
        self.installer.manifest.write_text(json.dumps(manifest))

        self.installer.preflight()
        self.installer.install()

        self.assertTrue(gmail.is_file())

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
