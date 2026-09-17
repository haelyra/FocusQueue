import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import uuid


ROOT = Path(__file__).parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ENTRY = load("codex_entry", "focus_queue_codex_entry.py")
INSTALL = load("install_codex_entry", "install_codex_entry.py")


class EntryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="entry ' test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.helper = self.root / "helper"
        self.helper.write_text('''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
root = Path(__file__).parent
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as stream: stream.write(json.dumps(args) + "\\n")
panes_file = root / "panes.json"
panes = json.loads(panes_file.read_text()) if panes_file.exists() else []
if args[:2] == ["runtime", "locate"]:
    location = root / "location.json"
    print(location.read_text() if location.exists() else '{"status":"stopped"}')
elif args[:2] == ["tmux", "list"]:
    print(json.dumps(panes))
elif args[:2] == ["tmux", "start"]:
    item = {"name": args[2], "serverPID":101, "createdAt":42, "paneID":"%" + str(len(panes)),
            "panePID": 202 + len(panes), "tty":"/dev/ttys099", "executable":"/tmp/tmux"}
    panes.append(item)
    panes_file.write_text(json.dumps(panes))
    if (root / "unconfirmed").exists():
        print("Started but unconfirmed", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(item))
else:
    print("unexpected helper call", file=sys.stderr)
    sys.exit(1)
''')
        self.helper.chmod(0o700)
        self.wrapper = self.root / "usage-wrapper"
        self.wrapper.write_text("#!/bin/bash\nexec /usr/bin/python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' \"$@\"\n")
        self.support = self.root / "support"
        self.session_id = str(uuid.uuid4())

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_cli_classification_and_help_never_launch(self):
        for arguments in (["exec", "hello"], ["-m", "exec", "review"], ["resume", self.session_id, "--help"],
                          ["hello", "--help"], ["--version"], ["--remote", "unix://test"]):
            with self.subTest(arguments=arguments):
                self.assertEqual(ENTRY.invocation(arguments)[0], "utility")
        self.assertEqual(ENTRY.invocation(["-m", "review", "hello"]), ("new", None))
        self.assertEqual(ENTRY.invocation(["--", "--help"]), ("new", None))
        self.assertEqual(ENTRY.invocation(["resume", "--cd", "/tmp", self.session_id]), ("resume", self.session_id))
        self.assertEqual(ENTRY.invocation(["resume", "named-session", self.session_id]), ("resume", None))
        self.assertEqual(ENTRY.invocation(["resume", "named-session", "--", self.session_id]), ("resume", None))
        self.assertEqual(ENTRY.invocation(["fork", self.session_id]), ("fork", None))

    def test_prompt_metadata_is_only_unambiguous_positional_input(self):
        self.assertEqual(ENTRY.initial_prompt(["-m", "model", "-C", "subdir", "fix the bug"]), "fix the bug")
        self.assertEqual(ENTRY.initial_prompt(["resume", self.session_id, "continue"]), "continue")
        self.assertEqual(ENTRY.initial_prompt(["fork", self.session_id, "try option two"]), "try option two")
        self.assertEqual(ENTRY.initial_prompt(["--", "--help"]), "--help")
        for args in (["--future-option", "value", "prompt"], ["resume", "named", "prompt"], ["resume", "--last"], ["exec", "prompt"]):
            self.assertIsNone(ENTRY.initial_prompt(args))
        self.assertEqual(len(ENTRY.initial_prompt(["x" * 5000])), 4096)

    def test_resume_receipt_prevents_duplicate_before_provider_discovery(self):
        command = ["/bin/bash", str(self.wrapper), "--yolo", "resume", self.session_id]
        first = ENTRY.choose_resume(self.helper, self.session_id, command, self.support, prompt="continue")
        second = ENTRY.choose_resume(self.helper, self.session_id, command, self.support)
        self.assertEqual(first, second)
        starts = [call for call in self.calls() if call[:2] == ["tmux", "start"]]
        self.assertEqual(len(starts), 1)
        self.assertEqual(starts[0][-len(command):], command)
        saved = json.loads((self.support / "shell/launch-metadata" / (first["name"] + ".json")).read_text())
        self.assertEqual(saved["reference"], first)
        self.assertEqual(saved["initialPrompt"], "continue")

    def test_exact_running_session_uses_its_current_pane(self):
        (self.root / "location.json").write_text(json.dumps({"status":"running", "runtime":"tmux", "tmuxName":"fq-task-ecc-035", "paneID":"%12"}))
        found = ENTRY.choose_resume(self.helper, self.session_id, ["codex"], self.support)
        self.assertEqual(found, {"name":"fq-task-ecc-035", "paneID":"%12"})
        self.assertFalse(any(call[:2] == ["tmux", "start"] for call in self.calls()))

    def test_unknown_or_direct_live_session_never_launches(self):
        for location in ({"status":"unknown"}, {"status":"running", "runtime":"terminal"}):
            (self.root / "location.json").write_text(json.dumps(location))
            with self.assertRaises(ENTRY.EntryError):
                ENTRY.choose_resume(self.helper, self.session_id, ["codex"], self.support)
        self.assertFalse(any(call[:2] == ["tmux", "start"] for call in self.calls()))

    def test_unconfirmed_resume_retains_intent_and_blocks_duplicate(self):
        (self.root / "unconfirmed").touch()
        with self.assertRaises(ENTRY.EntryError):
            ENTRY.choose_resume(self.helper, self.session_id, ["codex"], self.support)
        with self.assertRaisesRegex(ENTRY.EntryError, "still unconfirmed"):
            ENTRY.choose_resume(self.helper, self.session_id, ["codex"], self.support)
        self.assertEqual(sum(call[:2] == ["tmux", "start"] for call in self.calls()), 1)

    def test_restored_shell_is_preserved_and_new_resume_has_a_receipt(self):
        old = {"name":"fq-codex-" + self.session_id, "paneID":"%99", "panePID":99}
        (self.root / "panes.json").write_text(json.dumps([old]))
        result = ENTRY.choose_resume(self.helper, self.session_id, ["codex"], self.support)
        self.assertNotEqual(result["name"], old["name"])
        self.assertIn(old, json.loads((self.root / "panes.json").read_text()))

    def invoke_main(self, arguments, environment=None, interactive=True):
        class ExecCaptured(Exception):
            pass
        captured = []
        def execute(path, args):
            captured.append((path, args))
            raise ExecCaptured()
        clean = {**os.environ, "FOCUS_QUEUE_SUPPORT_DIR":str(self.support)}
        for key in ("TMUX", "FOCUS_QUEUE_RUNTIME_MODE", "FOCUS_QUEUE_CODEX_TMUX"):
            clean.pop(key, None)
        clean.update(environment or {})
        with mock.patch.dict(os.environ, clean, clear=True), mock.patch.object(ENTRY.sys.stdin, "isatty", return_value=interactive), \
             mock.patch.object(ENTRY.sys.stdout, "isatty", return_value=interactive), mock.patch.object(ENTRY.os, "execv", side_effect=execute):
            with self.assertRaises(ExecCaptured):
                ENTRY.main(["--helper", str(self.helper), "--usage-wrapper", str(self.wrapper), "--default-flag=--yolo", "--", *arguments])
        return captured[0]

    def test_new_launch_preserves_argv_cwd_and_uses_attach_pane(self):
        prompt = "fix 'quoted' $(touch never);\nnext line"
        path, args = self.invoke_main(["--cd", "relative-dir", prompt])
        self.assertEqual(path, str(self.helper))
        self.assertEqual(args[-2:], ["--pane", "%0"])
        start = next(call for call in self.calls() if call[:2] == ["tmux", "start"])
        self.assertEqual(start[3:5], ["--cwd", os.getcwd()])
        self.assertEqual(start[-4:], ["--yolo", "--cd", "relative-dir", prompt])

    def test_existing_tmux_terminal_opt_out_and_noninteractive_preserve_wrapper(self):
        for environment, interactive in (({"TMUX":"/tmp/users-server,1,0"}, True),
                                         ({"FOCUS_QUEUE_RUNTIME_MODE":"terminal"}, True),
                                         ({"FOCUS_QUEUE_CODEX_TMUX":"off"}, True), ({}, False)):
            with self.subTest(environment=environment, interactive=interactive):
                path, args = self.invoke_main(["hello"], environment, interactive)
                self.assertEqual(args, ["/bin/bash", str(self.wrapper), "--yolo", "hello"])
        self.assertEqual(self.calls(), [])

    def test_installed_shell_preserves_alias_flags_and_avoids_recursion(self):
        home = self.root / "Another ' User"
        home.mkdir()
        zshrc = home / ".zshrc"
        original = "# existing settings\nalias codex='echo original'\nexport KEEP_ME=yes\n"
        zshrc.write_text(original)
        hooks = home / ".codex/hooks.json"
        hooks.parent.mkdir()
        custom = {"hooks":{"SessionStart":[{"hooks":[{"type":"command", "command":"echo retained"}]}]}}
        hooks.write_text(json.dumps(custom))
        original_hooks = hooks.read_bytes()
        preview = INSTALL.install(home, self.wrapper, ["--yolo"], check=True)
        self.assertEqual(preview["mode"], "preview")
        self.assertNotIn(str(hooks), preview["paths"])
        self.assertNotIn("hookReview", preview)
        self.assertEqual(zshrc.read_text(), original)
        self.assertFalse((home / "Library").exists())
        result = INSTALL.install(home, self.wrapper, ["--yolo"])
        self.assertEqual(result["nativeHooks"], "unchanged")
        self.assertEqual(hooks.read_bytes(), original_hooks)
        self.assertIn(original.strip(), zshrc.read_text())
        self.assertTrue(Path(result["backupDirectory"]).exists())
        once = hooks.read_bytes()
        self.assertEqual(INSTALL.install(home, self.wrapper, ["--yolo"])["paths"], [])
        self.assertEqual(hooks.read_bytes(), once)
        self.assertEqual(json.loads(once)["hooks"]["SessionStart"][0], custom["hooks"]["SessionStart"][0])
        completed = subprocess.run(["/bin/zsh", "-fc", 'source "$1"; codex --help', "entry-test", str(zshrc)], capture_output=True, text=True, timeout=10)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout), ["--yolo", "--help"])
        self.assertFalse((home / ".codex/config.toml").exists())
        self.assertFalse(any("trust" in path.name for path in (home / ".codex").iterdir()))

    def test_default_install_never_creates_or_reads_native_hooks(self):
        home = self.root / "Default User"
        home.mkdir()
        preview = INSTALL.install(home, self.wrapper, ["--yolo"], check=True)
        self.assertEqual(len(preview["paths"]), 3)
        self.assertFalse((home / ".codex").exists())
        INSTALL.install(home, self.wrapper, ["--yolo"])
        self.assertFalse((home / ".codex").exists())
        hooks = home / ".codex/hooks.json"
        hooks.parent.mkdir()
        hooks.write_bytes(b"user-owned content, deliberately not JSON\n")
        original = hooks.read_bytes()
        self.assertEqual(INSTALL.install(home, self.wrapper, ["--yolo"])["paths"], [])
        self.assertEqual(hooks.read_bytes(), original)

    def test_hooks_require_explicit_opt_in_and_merge_idempotently(self):
        home = self.root / "Opt In User"
        hooks = home / ".codex/hooks.json"
        hooks.parent.mkdir(parents=True)
        custom = {"description":"user notes", "hooks":{"SessionStart":[{"hooks":[{"type":"command", "command":"echo retained"}]}]}}
        hooks.write_text(json.dumps(custom))
        original = hooks.read_bytes()
        preview = INSTALL.install(home, self.wrapper, ["--yolo"], check=True, install_hooks=True)
        self.assertEqual(preview["nativeHooks"], "requested")
        self.assertIn("hookReview", preview)
        self.assertIn(str(hooks), preview["paths"])
        self.assertEqual(hooks.read_bytes(), original)
        INSTALL.install(home, self.wrapper, ["--yolo"], install_hooks=True)
        installed = hooks.read_bytes()
        value = json.loads(installed)
        self.assertEqual(value["description"], "user notes")
        self.assertEqual(value["hooks"]["SessionStart"][0], custom["hooks"]["SessionStart"][0])
        self.assertEqual(set(value["hooks"]), set(INSTALL.HOOK_EVENTS))
        self.assertEqual(INSTALL.install(home, self.wrapper, ["--yolo"], install_hooks=True)["paths"], [])
        self.assertEqual(hooks.read_bytes(), installed)
        # A later default install retains the explicitly selected hooks unchanged.
        self.assertEqual(INSTALL.install(home, self.wrapper, ["--yolo"])["paths"], [])
        self.assertEqual(hooks.read_bytes(), installed)

    def test_install_failure_rolls_back_existing_user_files(self):
        home = self.root / "Rollback User"
        home.mkdir()
        zshrc = home / ".zshrc"
        zshrc.write_text("alias codex='echo retained'\n")
        before = zshrc.read_bytes()
        real_replace = INSTALL.os.replace
        def replace(source, destination):
            if Path(destination).name == "hooks.json":
                raise OSError("simulated hook install failure")
            real_replace(source, destination)
        with mock.patch.object(INSTALL.os, "replace", side_effect=replace):
            with self.assertRaisesRegex(OSError, "simulated"):
                INSTALL.install(home, self.wrapper, ["--yolo"], install_hooks=True)
        self.assertEqual(zshrc.read_bytes(), before)
        self.assertFalse((home / "Library/Application Support/ECC Focus Queue/shell/codex.zsh").exists())

    def test_install_rejects_symlink_escape_and_hook_trust_bypass(self):
        home = self.root / "Unsafe User"
        home.mkdir()
        (home / ".zshrc").symlink_to(self.root / "elsewhere")
        with self.assertRaises(ValueError):
            INSTALL.install(home, self.wrapper, [])
        with self.assertRaisesRegex(ValueError, "hook trust"):
            INSTALL.install(home, self.wrapper, ["--dangerously-bypass-hook-trust"])


if __name__ == "__main__":
    unittest.main()
