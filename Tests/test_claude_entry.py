import contextlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
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


ENTRY = load("claude_entry", "focus_queue_claude_entry.py")
INSTALL = load("install_claude_entry", "install_claude_entry.py")


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
if args[:1] == ["placement"]:
    (root / "placement-env.json").write_text(json.dumps({key: os.environ.get(key) for key in (
        "FOCUS_QUEUE_PROVIDER", "CLAUDE_SESSION_ID", "CLAUDE_CODE_SESSION_ID",
        "CODEX_THREAD_ID", "CODEX_SESSION_ID")}))
    launch = args[args.index("--launch") + 1]
    support = Path(os.environ["FOCUS_QUEUE_SUPPORT_DIR"])
    custom_path = root / "placement.json"
    custom = json.loads(custom_path.read_text()) if custom_path.exists() else {}
    task = custom.get("taskID") or (args[args.index("--task") + 1] if "--task" in args else None)
    value = {"launchID":launch, "status":"placed" if task else "project-inbox",
             "projectID":custom.get("projectID", "other"), "taskID":task,
             "capsulePath":str(support / "tracking/placements" / (launch + ".json"))}
    value.update(custom)
    print(json.dumps(value))
elif args[:2] == ["runtime", "locate"]:
    location = root / "location.json"
    print(location.read_text() if location.exists() else '{"status":"stopped"}')
elif args[:2] == ["tmux", "list"]:
    print(json.dumps(panes))
elif args[:2] == ["tmux", "reference"]:
    print(json.dumps({"name":args[2], "serverPID":101, "createdAt":42, "paneID":args[3],
                      "panePID":202, "tty":"/dev/ttys099", "executable":"/tmp/tmux"}))
elif args[:2] in (["tmux", "start"], ["tmux", "start-agent"]):
    name = args[2] if args[1] == "start" else "fq-task-" + args[2].lower()
    item = {"name": name, "serverPID":101, "createdAt":42, "paneID":"%" + str(len(panes)),
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
        self.adapter = self.root / "focus-queue-usage-wrapper"
        self.adapter.write_text("#!/bin/bash\ndelegate=\"$1\"; shift; [ \"$1\" = -- ] && shift; exec /bin/bash \"$delegate\" \"$@\"\n")
        self.support = self.root / "support"
        self.session_id = str(uuid.uuid4())

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    @contextlib.contextmanager
    def working_directory(self, path):
        previous = os.getcwd()
        os.chdir(path)
        try:
            yield
        finally:
            os.chdir(previous)

    def initialize_repository(self, source):
        source.mkdir(parents=True)
        def git(*args):
            return subprocess.run(["/usr/bin/git", *args], cwd=source, check=True,
                                  capture_output=True, text=True).stdout.strip()
        git("init", "-q", "-b", "main")
        git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture", "--allow-empty")
        return git

    def install_session_helper(self, home, *, start_agent=True):
        helper = home / ".local/bin/focus-queue-session"
        helper.parent.mkdir(parents=True, exist_ok=True)
        capability = " | tmux start-agent <TASK-ID> <AGENT-ID> | placement" if start_agent else ""
        helper.write_text(f"#!/bin/bash\nprintf '%s\\n' 'Persistent terminals: tmux start <name>{capability}'\n")
        helper.chmod(0o700)
        return helper

    def install_wezterm(self, *, fail=False):
        binary = self.root / "bin"
        binary.mkdir(exist_ok=True)
        record = self.root / "wezterm-argv.jsonl"
        wezterm = binary / "wezterm"
        wezterm.write_text(f'''#!/usr/bin/python3
import json, sys
with open({str(record)!r}, "a") as stream: stream.write(json.dumps(sys.argv[1:]) + "\\n")
{ "sys.exit(1)" if fail else "" }
''')
        wezterm.chmod(0o700)
        return {"WEZTERM_PANE": "42", "PATH": str(binary) + os.pathsep + os.environ["PATH"]}

    def wezterm_calls(self):
        path = self.root / "wezterm-argv.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_cli_classification_and_help_never_launch(self):
        for arguments in (["mcp", "list"], ["doctor"], ["update"], ["--version"], ["-V"],
                          ["--help"], ["--resume", self.session_id, "--help"],
                          ["--model", "opus", "plugin", "install"]):
            with self.subTest(arguments=arguments):
                self.assertEqual(ENTRY.invocation(arguments)[0], "utility")
        self.assertEqual(ENTRY.invocation(["--resume", self.session_id]), ("resume", self.session_id))
        self.assertEqual(ENTRY.invocation(["-r", self.session_id]), ("resume", self.session_id))
        self.assertEqual(ENTRY.invocation(["--resume=" + self.session_id]), ("resume", self.session_id))
        self.assertEqual(ENTRY.invocation(["--resume", "named-session"]), ("resume", None))
        self.assertEqual(ENTRY.invocation(["--resume"]), ("resume", None))
        self.assertEqual(ENTRY.invocation(["--continue"]), ("continue", None))
        self.assertEqual(ENTRY.invocation(["-c", "keep going"]), ("continue", None))
        self.assertEqual(ENTRY.invocation(["fix the bug"]), ("new", None))

    def test_usage_command_drops_default_flags_the_user_repeated(self):
        flag = "--dangerously-skip-permissions"
        command = ENTRY.usage_command(self.wrapper, [flag], [flag, "hello"])
        self.assertEqual(command.count(flag), 1)
        self.assertEqual(command[-2:], [flag, "hello"])
        command = ENTRY.usage_command(self.wrapper, [flag], ["hello"])
        self.assertEqual(command.count(flag), 1)
        self.assertEqual(command[-2:], [flag, "hello"])
        self.assertEqual(ENTRY.invocation(["--", "--help"]), ("new", None))
        self.assertEqual(ENTRY.invocation(["--model", "sonnet", "hello"]), ("new", None))
        self.assertEqual(ENTRY.invocation(["-p", "hello"], classify_agents=True)[0], "noninteractive")
        self.assertEqual(ENTRY.invocation(["-p", "--resume", self.session_id, "go"], classify_agents=True),
                         ("noninteractive", self.session_id))
        self.assertEqual(ENTRY.invocation(["-p", "--help"], classify_agents=True)[0], "utility")

    def test_prompt_hook_reaches_focus_queue_without_global_settings(self):
        self.helper.chmod(0o755)
        home = self.root / "home"
        (home / ".claude").mkdir(parents=True)
        arguments = ENTRY.prompt_hook_arguments(["Fix the hotkey"], self.helper, home)
        self.assertEqual(arguments[0], "--settings")
        self.assertEqual(arguments[2:], ["Fix the hotkey"])
        self.assertIs(json.loads(arguments[1])["disableAllHooks"], False)
        settings = json.loads(arguments[1])["hooks"]
        hook, data = settings["UserPromptSubmit"][0]["hooks"]
        self.assertEqual(hook["command"],
                         shlex.quote(str(self.helper)) + " register-event --provider claude >/dev/null")
        self.assertEqual(data["command"], shlex.quote(str(self.helper)) + " data-event --provider claude")
        self.assertNotIn("async", data)
        self.assertEqual(settings["SessionStart"], [{"matcher": "clear|compact", "hooks": [data]}])
        self.assertEqual(ENTRY.initial_prompt(arguments), "Fix the hotkey")
        # The user's own settings and an installed global hook are never doubled.
        own = ["--settings", "/tmp/mine.json", "Fix the hotkey"]
        self.assertEqual(ENTRY.prompt_hook_arguments(own, self.helper, home), own)
        (home / ".claude/settings.json").write_text(json.dumps({"hooks": {"UserPromptSubmit": [
            {"hooks": [{"type": "command", "command": hook["command"]}]}]}}))
        # The global hook only registers, so saved data still needs its own hook.
        global_hook = ENTRY.prompt_hook_arguments(["hi"], self.helper, home)
        self.assertEqual(json.loads(global_hook[1])["hooks"]["UserPromptSubmit"][0]["hooks"], [data])
        self.assertEqual(ENTRY.prompt_hook_arguments(["hi"], self.root / "missing", home), ["hi"])

    def test_repository_identity_accepts_macos_tmp_alias_only_for_same_inode(self):
        self.assertTrue(ENTRY.same_repository_identity(
            "/tmp/project/.git:123:456", "/private/tmp/project/.git:123:456"))
        self.assertFalse(ENTRY.same_repository_identity(
            "/tmp/project/.git:123:456", "/private/tmp/project/.git:123:999"))

    def test_repository_identity_tolerates_device_drift_only_for_same_inode(self):
        # st_dev changes every time macOS mounts the volume, so a stored
        # identity must still match after a reboot — but only when the path
        # and inode agree.
        self.assertTrue(ENTRY.same_repository_identity(
            "/tmp/project/.git:16777232:456", "/tmp/project/.git:16777229:456"))
        self.assertTrue(ENTRY.same_repository_identity(
            "/tmp/project/.git:16777232:456", "/private/tmp/project/.git:16777229:456"))
        self.assertFalse(ENTRY.same_repository_identity(
            "/tmp/project/.git:16777232:456", "/tmp/project/.git:16777229:999"))

    def test_managed_agent_usage_bar_defaults_on_and_respects_opt_out(self):
        self.support.mkdir(parents=True, exist_ok=True)
        self.assertTrue(ENTRY.agent_usage_bar_enabled(self.support))
        (self.support / "config.json").write_text(json.dumps({"agentUsageBarEnabled": False}))
        self.assertFalse(ENTRY.agent_usage_bar_enabled(self.support))
        (self.support / "config.json").write_text(json.dumps({"agentUsageBarEnabled": True}))
        self.assertTrue(ENTRY.agent_usage_bar_enabled(self.support))

    def test_resume_uses_exact_saved_workspace_without_task_environment(self):
        saved = self.root / "assigned"
        saved.mkdir()
        folder = self.support / "tasks/ECC-1"
        folder.mkdir(parents=True)
        (folder / "context.json").write_text(json.dumps({"subtasks":[{
            "id":"agent", "sessionID":self.session_id, "workspace":{"path":str(saved)}}]}))
        with mock.patch.dict(os.environ, {}, clear=True):
            _, record, arguments = ENTRY.begin_tracking(
                ["--resume", self.session_id], "resume", self.session_id, self.support)
        self.assertEqual(record["cwd"], str(saved.resolve()))
        self.assertEqual(record["taskID"], "ECC-1")
        self.assertEqual(record["provider"], "claude")
        self.assertEqual(arguments, ["--resume", self.session_id])
        with mock.patch.dict(os.environ, {"FOCUS_QUEUE_TASK_ID":"ECC-1", "FOCUS_QUEUE_SUBTASK_ID":"agent",
                             "FOCUS_QUEUE_AGENT_ROLE":"research"}, clear=True):
            _, nested, _ = ENTRY.begin_tracking([], "new", None, self.support)
        self.assertNotIn("agentID", nested)
        self.assertEqual(nested["workspacePolicy"], "research")
        saved.rmdir()
        with mock.patch.dict(os.environ, {}, clear=True), self.assertRaises(ENTRY.EntryError):
            ENTRY.begin_tracking(["--resume", self.session_id], "resume", self.session_id, self.support)
        self.assertFalse((self.support / "worktrees").exists())

    def test_managed_route_preserves_authorized_launch_correlation(self):
        launch_id = str(uuid.uuid4())
        environment = {
            "FOCUS_QUEUE_LAUNCH_ID": launch_id,
            "FOCUS_QUEUE_AGENT_CONTEXT": str(
                self.support / "tracking/placements" / f"{launch_id}.json"),
            "FOCUS_QUEUE_TASK_ID": "ECC-35",
            "FOCUS_QUEUE_SUBTASK_ID": launch_id,
            "FOCUS_QUEUE_RUNTIME_MODE": "tmux",
        }
        with mock.patch.dict(os.environ, environment, clear=True):
            path, record, _ = ENTRY.begin_tracking(
                ["continue routed work"], "new", None, self.support, isolate=False)
            self.assertEqual(record["launchID"], launch_id)
            self.assertEqual(os.environ["FOCUS_QUEUE_LAUNCH_ID"], launch_id)
            parent_payload = path.read_bytes()
            nested_path, nested, _ = ENTRY.begin_tracking(
                ["inspect nested work"], "new", None, self.support, isolate=False)
            self.assertNotEqual(nested["launchID"], launch_id)
            self.assertNotEqual(nested_path, path)
            self.assertEqual(path.read_bytes(), parent_payload)

    def test_resume_uuid_overrides_inherited_parent_task_and_agent(self):
        parent_session = str(uuid.uuid4())
        resumed = self.root / "resumed-workspace"
        resumed.mkdir()
        for task_id, agent_id, session_id, workspace in (
            ("ECC-1", "parent-agent", parent_session, self.root / "parent-workspace"),
            ("ECC-2", "resumed-agent", self.session_id, resumed),
        ):
            workspace.mkdir(exist_ok=True)
            folder = self.support / "tasks" / task_id
            folder.mkdir(parents=True)
            (folder / "context.json").write_text(json.dumps({"subtasks":[{
                "id":agent_id, "sessionID":session_id,
                "workspace":{"path":str(workspace), "managed":False},
            }]}))
        environment = {"FOCUS_QUEUE_TASK_ID":"ECC-1", "FOCUS_QUEUE_SUBTASK_ID":"parent-agent"}
        with mock.patch.dict(os.environ, environment, clear=True):
            _, record, arguments = ENTRY.begin_tracking(
                ["--resume", self.session_id], "resume", self.session_id, self.support)
        self.assertEqual(record["taskID"], "ECC-2")
        self.assertEqual(record["agentID"], "resumed-agent")
        self.assertEqual(record["cwd"], str(resumed.resolve()))
        self.assertEqual(arguments, ["--resume", self.session_id])

    def test_untracked_resume_never_inherits_parent_assignment(self):
        parent = self.root / "parent-workspace"
        parent.mkdir()
        folder = self.support / "tasks/ECC-1"
        folder.mkdir(parents=True)
        (folder / "context.json").write_text(json.dumps({"subtasks":[{
            "id":"parent-agent", "sessionID":str(uuid.uuid4()),
            "workspace":{"path":str(parent), "managed":False},
        }]}))
        environment = {"FOCUS_QUEUE_TASK_ID":"ECC-1", "FOCUS_QUEUE_SUBTASK_ID":"parent-agent"}
        with mock.patch.dict(os.environ, environment, clear=True):
            _, record, _ = ENTRY.begin_tracking(
                ["--resume", self.session_id], "resume", self.session_id, self.support)
        self.assertNotIn("taskID", record)
        self.assertNotIn("agentID", record)
        self.assertNotEqual(record["cwd"], str(parent.resolve()))

    def test_prompt_metadata_is_only_unambiguous_positional_input(self):
        self.assertEqual(ENTRY.initial_prompt(["--model", "opus", "--add-dir", "subdir", "fix the bug"]),
                         "fix the bug")
        self.assertEqual(ENTRY.initial_prompt(["--resume", self.session_id, "continue"]), "continue")
        self.assertEqual(ENTRY.initial_prompt(["--resume=" + self.session_id, "continue"]), "continue")
        self.assertEqual(ENTRY.initial_prompt(["--", "--help"]), "--help")
        for args in (["--future-option", "value", "prompt"], ["--resume"], ["mcp", "list"]):
            self.assertIsNone(ENTRY.initial_prompt(args))
        self.assertEqual(len(ENTRY.initial_prompt(["x" * 5000])), 4096)

    def test_resume_receipt_prevents_duplicate_before_provider_discovery(self):
        command = ["/bin/bash", str(self.wrapper), "--resume", self.session_id]
        first = ENTRY.choose_resume(self.helper, self.session_id, command, self.support, prompt="continue")
        second = ENTRY.choose_resume(self.helper, self.session_id, command, self.support)
        self.assertEqual(first, second)
        self.assertIn(["runtime", "locate", "claude", self.session_id], self.calls())
        starts = [call for call in self.calls() if call[:2] == ["tmux", "start"]]
        self.assertEqual(len(starts), 1)
        self.assertTrue(starts[0][2].startswith("fq-claude-"))
        self.assertEqual(starts[0][-len(command):], command)
        saved = json.loads((self.support / "shell/launch-metadata" / (first["name"] + ".json")).read_text())
        self.assertEqual(saved["reference"], first)
        self.assertEqual(saved["provider"], "claude")
        self.assertEqual(saved["initialPrompt"], "continue")

    def test_exact_running_session_uses_its_current_pane(self):
        location = {"status":"running", "runtime":"tmux", "tmuxName":"fq-task-ecc-035",
                    "name":"fq-task-ecc-035", "serverPID":101, "createdAt":42,
                    "paneID":"%12", "panePID":212, "tty":"/dev/ttys099",
                    "executable":"/tmp/tmux", "agentID":"agent-123"}
        (self.root / "location.json").write_text(json.dumps(location))
        found = ENTRY.choose_resume(self.helper, self.session_id, ["claude"], self.support)
        self.assertEqual(found, {key: location[key] for key in (
            "name", "serverPID", "createdAt", "paneID", "panePID", "tty", "executable")})
        self.assertFalse(any(call[:2] == ["tmux", "start"] for call in self.calls()))

    def test_task_resume_rejects_running_pane_owned_by_another_task_or_agent(self):
        base = {"status":"running", "runtime":"tmux", "tmuxName":"fq-task-ecc-999",
                "name":"fq-task-ecc-999", "serverPID":101, "createdAt":42,
                "paneID":"%12", "panePID":212, "tty":"/dev/ttys099",
                "executable":"/tmp/tmux", "agentID":"agent-123"}
        for changed in ({}, {"tmuxName":"fq-task-ecc-035", "name":"fq-task-ecc-035",
                             "agentID":"another-agent"}):
            with self.subTest(changed=changed):
                (self.root / "location.json").write_text(json.dumps({**base, **changed}))
                with self.assertRaisesRegex(ENTRY.EntryError, "task|agent"):
                    ENTRY.choose_resume(self.helper, self.session_id, ["claude"], self.support,
                                        task_id="ECC-035", agent_id="agent-123")

    def test_reference_validation_requires_complete_process_identity(self):
        with self.assertRaisesRegex(ENTRY.EntryError, "identity"):
            ENTRY.validate_reference({"name":"fq-task-ecc-035", "paneID":"%12"})

    def test_unknown_or_direct_live_session_never_launches(self):
        for location in ({"status":"unknown"}, {"status":"running", "runtime":"terminal"}):
            (self.root / "location.json").write_text(json.dumps(location))
            with self.assertRaises(ENTRY.EntryError):
                ENTRY.choose_resume(self.helper, self.session_id, ["claude"], self.support)
        self.assertFalse(any(call[:2] == ["tmux", "start"] for call in self.calls()))

    def test_unconfirmed_resume_retains_intent_and_blocks_duplicate(self):
        (self.root / "unconfirmed").touch()
        with self.assertRaises(ENTRY.EntryError):
            ENTRY.choose_resume(self.helper, self.session_id, ["claude"], self.support)
        with self.assertRaisesRegex(ENTRY.EntryError, "still unconfirmed"):
            ENTRY.choose_resume(self.helper, self.session_id, ["claude"], self.support)
        self.assertEqual(sum(call[:2] == ["tmux", "start"] for call in self.calls()), 1)

    def test_resume_receipts_reject_redirected_or_writable_storage(self):
        shell = self.support / "shell"
        shell.mkdir(parents=True)
        outside = self.root / "outside-receipts"
        outside.mkdir()
        receipts = shell / "resume-receipts"
        receipts.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ENTRY.EntryError):
            ENTRY.choose_resume(self.helper, self.session_id, ["claude"], self.support)
        self.assertEqual(list(outside.iterdir()), [])

        receipts.unlink()
        receipts.mkdir(mode=0o777)
        receipts.chmod(0o777)
        with self.assertRaises(ENTRY.EntryError):
            ENTRY.choose_resume(self.helper, self.session_id, ["claude"], self.support)
        self.assertFalse(any(call[:2] == ["tmux", "start"] for call in self.calls()))

    def test_resume_receipt_symlink_is_never_followed(self):
        receipts = self.support / "shell/resume-receipts"
        receipts.mkdir(parents=True, mode=0o700)
        outside = self.root / "outside.json"
        outside.write_text(json.dumps({"sessionID":self.session_id, "reference":{
            "name":"fq-stolen", "serverPID":1, "createdAt":1, "paneID":"%1",
            "panePID":2, "tty":"/dev/ttys999", "executable":"/tmp/tmux",
        }}))
        (receipts / f"{self.session_id}.json").symlink_to(outside)
        with self.assertRaises(ENTRY.EntryError):
            ENTRY.choose_resume(self.helper, self.session_id, ["claude"], self.support)
        self.assertFalse(any(call[:2] == ["tmux", "start"] for call in self.calls()))

    def test_restored_shell_is_preserved_and_new_resume_has_a_receipt(self):
        old = {"name":"fq-claude-" + self.session_id, "paneID":"%99", "panePID":99}
        (self.root / "panes.json").write_text(json.dumps([old]))
        result = ENTRY.choose_resume(self.helper, self.session_id, ["claude"], self.support)
        self.assertNotEqual(result["name"], old["name"])
        self.assertTrue(result["name"].startswith("fq-claude-"))
        self.assertIn(old, json.loads((self.root / "panes.json").read_text()))

    def invoke_main(self, arguments, environment=None, interactive=True, adapter=None):
        class ExecCaptured(Exception):
            pass
        captured = []
        def execute(path, args):
            captured.append((path, args))
            raise ExecCaptured()
        clean = {**os.environ, "FOCUS_QUEUE_SUPPORT_DIR":str(self.support), "FOCUS_QUEUE_WORKSPACE_MODE":"existing"}
        for key in ("TMUX", "WEZTERM_PANE", "FOCUS_QUEUE_RUNTIME_MODE", "FOCUS_QUEUE_CLAUDE_TMUX",
                    "FOCUS_QUEUE_TASK_ID", "FOCUS_QUEUE_SUBTASK_ID", "FOCUS_QUEUE_AGENT_ROLE",
                    "FOCUS_QUEUE_LAUNCH_ID", "FOCUS_QUEUE_AGENT_CONTEXT", "FOCUS_QUEUE_MANAGED_TMUX"):
            clean.pop(key, None)
        clean.update(environment or {})
        with mock.patch.dict(os.environ, clean, clear=True), mock.patch.object(ENTRY.sys.stdin, "isatty", return_value=interactive), \
             mock.patch.object(ENTRY.sys.stdout, "isatty", return_value=interactive), mock.patch.object(ENTRY.os, "execv", side_effect=execute), \
             mock.patch.object(ENTRY.os, "chdir"), mock.patch.object(
                 ENTRY, "USAGE_ADAPTER", self.adapter if adapter is None else adapter):
            with self.assertRaises(ExecCaptured):
                ENTRY.main(["--helper", str(self.helper), "--usage-wrapper", str(self.wrapper),
                            "--", *arguments])
        return captured[0]

    def test_new_launch_enters_managed_tmux_with_claude_provider_identity(self):
        prompt = "fix 'quoted' $(touch never);\nnext line"
        path, args = self.invoke_main([prompt])
        self.assertEqual(path, str(self.helper))
        self.assertEqual(args[1:3], ["tmux", "attach-reference"])
        self.assertEqual(json.loads(args[3])["paneID"], "%0")
        start = next(call for call in self.calls() if call[:2] == ["tmux", "start"])
        self.assertTrue(start[2].startswith("fq-claude-"))
        self.assertIn("FOCUS_QUEUE_PROVIDER=claude", start)
        self.assertIn("FOCUS_QUEUE_MANAGED_TMUX=1", start)
        self.assertEqual(start[3:5], ["--cwd", os.getcwd()])
        self.assertEqual(start[-1], prompt)

    def test_placement_records_claude_without_a_parent_agent_session(self):
        # Launched from another agent's shell: that agent's provider and session are inherited.
        self.invoke_main(["Implement placement"], {
            "FOCUS_QUEUE_PROVIDER": "codex", "CODEX_THREAD_ID": str(uuid.uuid4()),
            "CLAUDE_CODE_SESSION_ID": str(uuid.uuid4()), "CLAUDE_SESSION_ID": str(uuid.uuid4()),
        })
        self.assertEqual(json.loads((self.root / "placement-env.json").read_text()), {
            "FOCUS_QUEUE_PROVIDER": "claude", "CLAUDE_SESSION_ID": None,
            "CLAUDE_CODE_SESSION_ID": None, "CODEX_THREAD_ID": None, "CODEX_SESSION_ID": None,
        })

    def test_successful_placement_labels_wezterm_tab_with_task_title(self):
        (self.root / "placement.json").write_text(json.dumps({
            "status":"placed", "projectID":"focus", "taskID":"FOC-001",
        }))
        self.invoke_main(["Implement placement"], self.install_wezterm())
        self.assertEqual(self.wezterm_calls(),
                         [["cli", "set-tab-title", "--pane-id", "42", "Implement placement"]])

    def test_placement_title_is_preferred_over_the_prompt_intake_title(self):
        (self.root / "placement.json").write_text(json.dumps({
            "status":"placed", "projectID":"focus", "taskID":"FOC-001", "title":"Real task title",
        }))
        self.invoke_main(["Implement placement"], self.install_wezterm())
        self.assertEqual(self.wezterm_calls(),
                         [["cli", "set-tab-title", "--pane-id", "42", "Real task title"]])

    def test_generic_agent_title_never_labels_the_tab(self):
        (self.root / "placement.json").write_text(json.dumps({
            "status":"placed", "projectID":"focus", "taskID":"FOC-002",
        }))
        self.invoke_main([], self.install_wezterm())
        self.assertEqual(self.wezterm_calls(), [])

    def test_tab_labeling_is_skipped_without_a_wezterm_pane_or_executable(self):
        (self.root / "placement.json").write_text(json.dumps({
            "status":"placed", "projectID":"focus", "taskID":"FOC-001",
        }))
        environment = self.install_wezterm()
        empty = self.root / "empty-bin"
        empty.mkdir()
        for overrides in ({"WEZTERM_PANE":"42", "PATH":str(empty)},
                          {"WEZTERM_PANE":"42", "TMUX":"/tmp/users-server,1,0"},
                          {"PATH":environment["PATH"]}):
            with self.subTest(overrides=overrides):
                self.invoke_main(["Implement placement"], overrides)
        self.assertEqual(self.wezterm_calls(), [])

    def test_failing_wezterm_never_breaks_the_launch(self):
        (self.root / "placement.json").write_text(json.dumps({
            "status":"placed", "projectID":"focus", "taskID":"FOC-001",
        }))
        path, args = self.invoke_main(["Implement placement"], self.install_wezterm(fail=True))
        self.assertEqual(path, str(self.helper))
        self.assertEqual(self.wezterm_calls(),
                         [["cli", "set-tab-title", "--pane-id", "42", "Implement placement"]])

    def test_task_launch_joins_stable_session_with_managed_usage_context(self):
        path, arguments = self.invoke_main(["hello"], {
            "FOCUS_QUEUE_TASK_ID":"ECC-035",
            "FOCUS_QUEUE_SUBTASK_ID":"agent-123",
        })

        self.assertEqual(path, str(self.helper))
        start = next(call for call in self.calls() if call[:2] == ["tmux", "start-agent"])
        self.assertEqual(start[:6], ["tmux", "start-agent", "ECC-035", "agent-123", "--cwd", os.getcwd()])
        self.assertEqual(start.count("FOCUS_QUEUE_MANAGED_TMUX=1"), 1)
        self.assertEqual(start.count("FOCUS_QUEUE_PROVIDER=claude"), 1)
        self.assertIn(str(self.adapter), start)
        self.assertIn(str(self.wrapper), start)
        self.assertEqual(start[start.index(str(self.adapter)):start.index(str(self.adapter)) + 3],
                         [str(self.adapter), str(self.wrapper), "--"])
        self.assertFalse(any(call[:2] == ["tmux", "start"] for call in self.calls()))
        self.assertEqual(arguments[1:3], ["tmux", "attach-reference"])
        self.assertEqual(json.loads(arguments[3])["paneID"], "%0")
        self.assertEqual(arguments[4:], ["--task", "ECC-035", "--agent", "agent-123"])
        receipt = json.loads(next((self.support / "tracking/launches").glob("*.json")).read_text())
        self.assertEqual(receipt["reference"]["name"], "fq-task-ecc-035")
        metadata = self.support / "shell/launch-metadata/fq-task-ecc-035-agent-123.json"
        self.assertEqual(json.loads(metadata.read_text())["reference"], receipt["reference"])
        notifications = [call for call in self.calls() if call == ["intake-changed"]]
        self.assertEqual(len(notifications), 3, "the exact pane reference must trigger an immediate UI refresh")

    def test_task_associated_resume_joins_the_stable_task_session(self):
        task = self.support / "tasks/ECC-035"
        task.mkdir(parents=True)
        (task / "context.json").write_text(json.dumps({"subtasks":[{
            "id":"agent-123", "sessionID":self.session_id,
            "workspace":{"path":str(self.root)},
        }]}))
        path, arguments = self.invoke_main(["--resume", self.session_id], {
            "FOCUS_QUEUE_TASK_ID":"ECC-035",
            "FOCUS_QUEUE_SUBTASK_ID":"agent-123",
        })

        self.assertEqual(path, str(self.helper))
        start = next(call for call in self.calls() if call[:2] == ["tmux", "start-agent"])
        self.assertEqual(start[2:4], ["ECC-035", "agent-123"])
        self.assertEqual(arguments[1:3], ["tmux", "attach-reference"])
        self.assertEqual(json.loads(arguments[3])["paneID"], "%0")
        self.assertEqual(arguments[4:], ["--task", "ECC-035", "--agent", "agent-123"])

    def test_task_launch_fails_closed_when_managed_usage_adapter_is_missing(self):
        with self.assertRaisesRegex(ENTRY.EntryError, "usage adapter"):
            self.invoke_main(["hello"], {
                "FOCUS_QUEUE_TASK_ID":"ECC-035",
                "FOCUS_QUEUE_SUBTASK_ID":"agent-123",
            }, adapter=self.root / "missing-adapter")
        self.assertFalse(any(call[:2] == ["tmux", "start-agent"] for call in self.calls()))

    def test_failed_managed_start_marks_intake_blocked_and_notifies(self):
        (self.root / "unconfirmed").touch()
        with self.assertRaises(ENTRY.EntryError):
            self.invoke_main(["hello"], {
                "FOCUS_QUEUE_TASK_ID":"ECC-035",
                "FOCUS_QUEUE_SUBTASK_ID":"agent-123",
            })
        receipt = json.loads(next((self.support / "tracking/launches").glob("*.json")).read_text())
        self.assertEqual(receipt["phase"], "blocked")
        self.assertIn("unconfirmed", receipt["note"].lower())
        notifications = [call for call in self.calls() if call == ["intake-changed"]]
        self.assertEqual(len(notifications), 3)

    def test_usage_adapter_is_automatic_and_has_a_legacy_fallback(self):
        with mock.patch.object(ENTRY, "USAGE_ADAPTER", self.adapter):
            self.assertEqual(ENTRY.usage_command(self.wrapper, ["--verbose"], ["hello"]), [
                "/bin/bash", str(self.adapter), str(self.wrapper), "--", "--verbose", "hello",
            ])
        with mock.patch.object(ENTRY, "USAGE_ADAPTER", self.root / "missing-adapter"):
            self.assertEqual(ENTRY.usage_command(self.wrapper, ["--verbose"], ["hello"]), [
                "/bin/bash", str(self.wrapper), "--verbose", "hello",
            ])

    def test_managed_tmux_terminal_opt_out_and_noninteractive_preserve_wrapper(self):
        for environment, interactive in (({"FOCUS_QUEUE_RUNTIME_MODE":"terminal"}, True),
                                         ({"FOCUS_QUEUE_CLAUDE_TMUX":"off"}, True), ({}, False)):
            with self.subTest(environment=environment, interactive=interactive):
                path, args = self.invoke_main(["hello"], environment, interactive)
                self.assertEqual(args, ["/bin/bash", str(self.adapter), str(self.wrapper), "--",
                               *ENTRY.prompt_hook_arguments(["hello"], self.helper)])
        self.assertTrue(all(call == ["intake-changed"] or call[:1] == ["placement"] for call in self.calls()))
        self.assertEqual(len(list((self.support / "tracking/launches").glob("*.json"))), 3)

    def test_managed_tmux_bypass_persists_exact_current_reference(self):
        path, args = self.invoke_main(["hello"], {
            "FOCUS_QUEUE_RUNTIME_MODE":"tmux",
            "FOCUS_QUEUE_TMUX_NAME":"fq-task-ecc-035",
            "FOCUS_QUEUE_TMUX_SERVER":"fq-live-test",
            "TMUX_PANE":"%7",
            "FOCUS_QUEUE_TASK_ID":"ECC-035",
            "FOCUS_QUEUE_SUBTASK_ID":"agent-123",
        })
        self.assertEqual(path, "/bin/bash")
        self.assertEqual(args, ["/bin/bash", str(self.adapter), str(self.wrapper), "--",
                               *ENTRY.prompt_hook_arguments(["hello"], self.helper)])
        reference_call = next(call for call in self.calls() if call[:2] == ["tmux", "reference"])
        self.assertEqual(reference_call, ["tmux", "reference", "fq-task-ecc-035", "%7",
                                          "--task", "ECC-035", "--agent", "agent-123",
                                          "--server", "fq-live-test"])
        receipt = json.loads(next((self.support / "tracking/launches").glob("*.json")).read_text())
        self.assertEqual(receipt["reference"]["name"], "fq-task-ecc-035")
        self.assertEqual(receipt["reference"]["paneID"], "%7")
        self.assertEqual(sum(call == ["intake-changed"] for call in self.calls()), 3)

    def test_noninteractive_resume_runs_the_duplicate_guard(self):
        (self.root / "location.json").write_text(json.dumps(
            {"status":"running", "runtime":"tmux", "tmuxName":"fq-task-ecc-035"}))
        with self.assertRaisesRegex(ENTRY.EntryError, "already running"):
            self.invoke_main(["-p", "--resume", self.session_id, "go"], {}, interactive=False)
        self.assertFalse(any(call[:2] == ["tmux", "start"] for call in self.calls()))
        self.assertIn(["runtime", "locate", "claude", self.session_id], self.calls())

    def test_missing_tracking_storage_prevents_provider_launch(self):
        self.support.mkdir()
        (self.support / "tracking").write_text("not a directory")
        with self.assertRaises(OSError):
            self.invoke_main(["hello"])
        self.assertEqual(self.calls(), [])

    def test_real_dirty_repository_isolated_and_research_reuses_source(self):
        source = self.root / "repository"
        git = self.initialize_repository(source)
        (source / "work.txt").write_text("committed")
        git("add", "work.txt")
        git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture")
        (source / "work.txt").write_text("user edits")
        with self.working_directory(source), mock.patch.dict(os.environ, {}, clear=True):
            path, receipt, arguments = ENTRY.begin_tracking(["fix bug"], "new", None, self.support)
        workspace = Path(receipt["cwd"])
        self.assertEqual(receipt["workspacePolicy"], "isolated")
        self.assertEqual(workspace.parent, (source / ".worktrees/unassigned").resolve())
        self.assertFalse(str(workspace).startswith(str(self.support)))
        marker_path = source / ".worktrees/.focus-queue-worktrees.json"
        marker = json.loads(marker_path.read_text())
        self.assertEqual(marker["repositoryPath"], str(source.resolve()))
        self.assertEqual(marker["repositoryIdentity"], ENTRY.repository_identity(source))
        self.assertFalse(marker_path.is_symlink())
        self.assertEqual(marker_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(path.read_text())["launchID"], receipt["launchID"])
        self.assertEqual(Path(receipt["placementPath"]),
                         (self.support / "tracking/placements" / (receipt["launchID"] + ".json")).resolve())
        self.assertEqual((workspace / "work.txt").read_text(), "committed")
        self.assertEqual((source / "work.txt").read_text(), "user edits")
        self.assertEqual(git("check-ignore", ".worktrees"), ".worktrees")
        self.assertEqual(arguments, ["fix bug"])
        with self.working_directory(source):
            with mock.patch.dict(os.environ, {"FOCUS_QUEUE_AGENT_ROLE":"research"}, clear=True):
                _, research, _ = ENTRY.begin_tracking([], "new", None, self.support)
        self.assertEqual(research["cwd"], str(source.resolve()))
        self.assertEqual(research["workspacePolicy"], "research")
        git("worktree", "remove", str(workspace))

    def test_unique_existing_task_hint_places_workspace_beside_repository_and_notifies(self):
        source = self.root / "repository"
        self.initialize_repository(source)
        (self.support / "tasks/ECC-035").mkdir(parents=True)
        (self.support / "tasks/ECC-035/context.json").write_text(json.dumps({"ticketID":"ECC-035", "subtasks":[]}))
        changed = []
        with self.working_directory(source), mock.patch.dict(os.environ, {}, clear=True):
            _, record, _ = ENTRY.begin_tracking(["Work on ECC-035 only"],
                "new", None, self.support, on_change=lambda item: changed.append(item["phase"]))
        workspace = Path(record["cwd"])
        self.assertEqual(record["taskID"], "ECC-035")
        self.assertEqual(workspace, (source / ".worktrees" /
                         "ecc-035" / "agents" / record["launchID"]).resolve())
        self.assertEqual(changed, ["preparing", "ready"])
        subprocess.run(["/usr/bin/git", "worktree", "remove", str(workspace)], cwd=source, check=True)

    def test_coding_source_inside_application_support_is_rejected(self):
        source = self.support / "source-repository"
        self.initialize_repository(source)

        with self.working_directory(source), mock.patch.dict(os.environ, {}, clear=True), \
                self.assertRaisesRegex(ENTRY.EntryError, "data folder"):
            ENTRY.begin_tracking(["fix bug"], "new", None, self.support)
        receipt = json.loads(next((self.support / "tracking/launches").glob("*.json")).read_text())
        self.assertEqual(receipt["phase"], "blocked")

    def test_actual_noninteractive_entry_persists_receipt_without_task_or_uuid(self):
        result = subprocess.run(["/usr/bin/python3", str(ROOT / "Scripts/focus_queue_claude_entry.py"),
            "--helper", str(self.helper), "--usage-wrapper", str(self.wrapper), "--", "hello"], cwd=self.root,
            env={"PATH":os.environ["PATH"], "FOCUS_QUEUE_SUPPORT_DIR":str(self.support)},
            capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        records = list((self.support / "tracking/launches").glob("*.json"))
        self.assertEqual(len(records), 1)
        record = json.loads(records[0].read_text())
        self.assertNotIn("sessionID", record)
        self.assertNotIn("taskID", record)
        self.assertEqual(record["provider"], "claude")
        self.assertEqual(record["phase"], "ready")
        self.assertEqual(json.loads(result.stdout)[-1], "hello")

    def test_installed_shell_preserves_alias_flags_and_avoids_recursion(self):
        home = self.root / "Another ' User"
        home.mkdir()
        self.install_session_helper(home)
        zshrc = home / ".zshrc"
        original = "# existing settings\nalias claude='echo original'\nexport KEEP_ME=yes\n"
        zshrc.write_text(original)
        settings = home / ".claude/settings.json"
        settings.parent.mkdir()
        custom = {"model":"opus", "hooks":{"SessionStart":[{"hooks":[{"type":"command", "command":"echo retained"}]}]}}
        settings.write_text(json.dumps(custom))
        original_settings = settings.read_bytes()
        preview = INSTALL.install(home, self.wrapper, [], check=True)
        self.assertEqual(preview["mode"], "preview")
        self.assertNotIn(str(settings), preview["paths"])
        self.assertNotIn("hookReview", preview)
        self.assertEqual(zshrc.read_text(), original)
        self.assertFalse((home / "Library").exists())
        result = INSTALL.install(home, self.wrapper, [])
        self.assertEqual(result["nativeHooks"], "unchanged")
        self.assertEqual(settings.read_bytes(), original_settings)
        self.assertIn(original.strip(), zshrc.read_text())
        self.assertTrue(Path(result["backupDirectory"]).exists())
        once = settings.read_bytes()
        self.assertEqual(INSTALL.install(home, self.wrapper, [])["paths"], [])
        self.assertEqual(settings.read_bytes(), once)
        self.assertEqual(json.loads(once)["hooks"]["SessionStart"][0], custom["hooks"]["SessionStart"][0])
        clean_environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith("FOCUS_QUEUE_") and key not in {"TMUX", "TMUX_PANE"}
        }
        completed = subprocess.run(["/bin/zsh", "-fc", 'source "$1"; claude --help',
            "entry-test", str(zshrc)], capture_output=True, text=True, timeout=10,
            env=clean_environment)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout), ["--help"])
        self.assertFalse((home / ".claude/hooks").exists())

    def test_default_install_never_creates_or_reads_native_hooks(self):
        home = self.root / "Default User"
        home.mkdir()
        self.install_session_helper(home)
        preview = INSTALL.install(home, self.wrapper, [], check=True)
        self.assertEqual(len(preview["paths"]), 11)  # includes the other provider's fq entry and analytics module
        self.assertFalse((home / ".claude").exists())
        INSTALL.install(home, self.wrapper, [])
        self.assertFalse((home / ".claude").exists())
        settings = home / ".claude/settings.json"
        settings.parent.mkdir()
        settings.write_bytes(b"user-owned content, deliberately not JSON\n")
        original = settings.read_bytes()
        self.assertEqual(INSTALL.install(home, self.wrapper, [])["paths"], [])
        self.assertEqual(settings.read_bytes(), original)

    def test_install_writes_executable_fq_shim_and_dispatcher(self):
        home = self.root / "Fq User"
        home.mkdir()
        self.install_session_helper(home)
        result = INSTALL.install(home, self.wrapper, [])
        shim = home / ".local/bin/fq"
        self.assertIn(str(shim), result["paths"])
        self.assertTrue(shim.stat().st_mode & 0o111)
        support = home / "Library/Application Support/ECC Focus Queue"
        dispatcher = support / "shell/focus_queue_fq.py"
        content = shim.read_text()
        self.assertTrue(content.startswith("#!/bin/sh\nexec /usr/bin/python3 "))
        self.assertIn("focus_queue_fq.py", content)
        self.assertTrue(content.endswith('"$@"\n'))
        self.assertTrue(dispatcher.is_file())
        self.assertTrue((support / "shell/focus_queue_placement.py").is_file())
        self.assertTrue((support / "shell/focus_queue_codex_entry.py").is_file(),
                        "fq dispatches codex without its shell function installed")
        self.assertEqual(INSTALL.install(home, self.wrapper, [])["paths"], [])

    def test_hooks_require_explicit_opt_in_and_merge_idempotently(self):
        home = self.root / "Opt In User"
        self.install_session_helper(home)
        settings = home / ".claude/settings.json"
        settings.parent.mkdir(parents=True)
        custom = {"model":"opus", "hooks":{"SessionStart":[{"hooks":[{"type":"command", "command":"echo retained"}]}]}}
        settings.write_text(json.dumps(custom))
        original = settings.read_bytes()
        preview = INSTALL.install(home, self.wrapper, [], check=True, install_hooks=True)
        self.assertEqual(preview["nativeHooks"], "requested")
        self.assertIn("hookReview", preview)
        self.assertIn(str(settings), preview["paths"])
        self.assertEqual(settings.read_bytes(), original)
        INSTALL.install(home, self.wrapper, [], install_hooks=True)
        installed = settings.read_bytes()
        value = json.loads(installed)
        self.assertEqual(value["model"], "opus")
        self.assertEqual(value["hooks"]["SessionStart"][0], custom["hooks"]["SessionStart"][0])
        self.assertEqual(set(value["hooks"]), set(INSTALL.HOOK_EVENTS))
        command = shlex.quote(str(home / ".local/bin/focus-queue-session")) + " register-event --provider claude >/dev/null"
        for event in INSTALL.HOOK_EVENTS:
            entries = [item for item in value["hooks"][event]
                       if item.get("hooks", [{}])[0].get("command") == command]
            self.assertEqual(len(entries), 1, event)
        self.assertEqual(value["hooks"]["SessionStart"][-1].get("matcher"),
                         "^(startup|resume|clear|compact)$")
        self.assertEqual(INSTALL.install(home, self.wrapper, [], install_hooks=True)["paths"], [])
        self.assertEqual(settings.read_bytes(), installed)
        # A later default install retains the explicitly selected hooks unchanged.
        self.assertEqual(INSTALL.install(home, self.wrapper, [])["paths"], [])
        self.assertEqual(settings.read_bytes(), installed)

    def test_install_failure_rolls_back_existing_user_files(self):
        home = self.root / "Rollback User"
        home.mkdir()
        self.install_session_helper(home)
        zshrc = home / ".zshrc"
        zshrc.write_text("alias claude='echo retained'\n")
        before = zshrc.read_bytes()
        real_install = INSTALL.install_staging
        def install_staging(source, destination, expected):
            if Path(destination).name == "settings.json":
                raise OSError("simulated hook install failure")
            real_install(source, destination, expected)
        with mock.patch.object(INSTALL, "install_staging", side_effect=install_staging):
            with self.assertRaisesRegex(OSError, "simulated"):
                INSTALL.install(home, self.wrapper, [], install_hooks=True)
        self.assertEqual(zshrc.read_bytes(), before)
        self.assertFalse((home / "Library/Application Support/ECC Focus Queue/shell/claude.zsh").exists())

    def test_install_aborts_instead_of_overwriting_concurrent_shell_edit(self):
        home = self.root / "Concurrent User"
        home.mkdir()
        self.install_session_helper(home)
        zshrc = home / ".zshrc"
        zshrc.write_text("original user settings\n")
        real_swap = INSTALL.atomic_swap
        changed = False
        def swap(source, destination):
            nonlocal changed
            if Path(destination) == zshrc and not changed:
                changed = True
                zshrc.write_text("newer concurrent user edit\n")
            real_swap(source, destination)
        with mock.patch.object(INSTALL, "atomic_swap", side_effect=swap):
            with self.assertRaisesRegex(ValueError, "changed during installation"):
                INSTALL.install(home, self.wrapper, [])
        self.assertEqual(zshrc.read_text(), "newer concurrent user edit\n")

    def test_install_rollback_retains_concurrent_edits_to_existing_and_new_files(self):
        home = self.root / "Concurrent Rollback User"
        home.mkdir()
        self.install_session_helper(home)
        zshrc = home / ".zshrc"
        zshrc.write_text("original user settings\n")
        generated = home / "Library/Application Support/ECC Focus Queue/shell/claude.zsh"
        real_install = INSTALL.install_staging

        def install_staging(source, destination, expected):
            if Path(destination).name == "settings.json":
                zshrc.write_text("newer concurrent settings\n")
                generated.write_text("newer generated-file edit\n")
                raise OSError("simulated late install failure")
            real_install(source, destination, expected)

        with mock.patch.object(INSTALL, "install_staging", side_effect=install_staging):
            with self.assertRaisesRegex(RuntimeError, "retained for recovery"):
                INSTALL.install(home, self.wrapper, [], install_hooks=True)
        self.assertEqual(zshrc.read_text(), "newer concurrent settings\n")
        self.assertEqual(generated.read_text(), "newer generated-file edit\n")
        backup = next((home / "Library/Application Support/ECC Focus Queue/backups").iterdir())
        manifest = json.loads((backup / "manifest.json").read_text())
        self.assertEqual(manifest["status"], "rollback-incomplete")
        self.assertTrue(manifest["rollbackConflicts"])

    def test_install_rejects_symlink_escape(self):
        home = self.root / "Unsafe User"
        home.mkdir()
        self.install_session_helper(home)
        (home / ".zshrc").symlink_to(self.root / "elsewhere")
        with self.assertRaises(ValueError):
            INSTALL.install(home, self.wrapper, [])

    def test_install_rejects_helper_without_task_session_capability(self):
        home = self.root / "Old Helper User"
        home.mkdir()
        self.install_session_helper(home, start_agent=False)
        with self.assertRaisesRegex(ValueError, "start-agent"):
            INSTALL.install(home, self.wrapper, [], check=True)
        self.assertFalse((home / "Library/Application Support/ECC Focus Queue/shell").exists())


if __name__ == "__main__":
    unittest.main()
