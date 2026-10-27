import argparse
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import subprocess
import time
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "Scripts/focus_queue_codex.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("focus_queue_codex", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


# Agent shells export the live support directory; keep provider usage events
# from these fixtures out of its token analytics (FOC-061).
_SUPPORT = tempfile.TemporaryDirectory()
_SUPPORT_ENV = mock.patch.dict(os.environ, {"FOCUS_QUEUE_SUPPORT_DIR": _SUPPORT.name})


def setUpModule():
    _SUPPORT_ENV.start()


def tearDownModule():
    _SUPPORT_ENV.stop()
    _SUPPORT.cleanup()


class FocusQueueCodexTests(unittest.TestCase):
    @staticmethod
    def feature_listing(*names):
        return "".join(f"{name:<44} stable             true\n" for name in names)

    @staticmethod
    def discover(executable):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE,
            "build_no_tools_model_catalog",
            return_value=(Path(temporary) / "models.json", MODULE.NO_TOOLS_MODEL),
        ), mock.patch.object(MODULE, "assert_effective_no_tools_manifest"):
            return MODULE.discover_no_tools_codex_capabilities(
                executable,
                safety_directory=Path(temporary),
                workspace=Path(temporary),
            )

    @staticmethod
    def manifest(*, tools=None, input_items=None, **extra):
        payload = {key: None for key in MODULE.EXPECTED_MANIFEST_KEYS}
        payload.update(
            {
                "model": MODULE.NO_TOOLS_MODEL,
                "tools": [] if tools is None else tools,
                "input": (
                    [{"type": "message", "role": "user"}]
                    if input_items is None
                    else input_items
                ),
            }
        )
        payload.update(extra)
        return payload

    def test_no_tools_preflight_accepts_patch_upgrade_and_validates_discovered_features(self):
        calls = []
        listing = self.feature_listing("shell_tool", "future_tool_surface")

        def fake_run(command, **_kwargs):
            calls.append(command)
            if command[-1] == "--version":
                return subprocess.CompletedProcess(command, 0, "codex-cli 0.153.5\n", "")
            if command[-2:] == ["features", "list"]:
                return subprocess.CompletedProcess(command, 0, listing, "")
            return subprocess.CompletedProcess(command, 1, "", "No prompt provided via stdin.\n")

        with mock.patch.object(MODULE.subprocess, "run", side_effect=fake_run):
            features, overrides = self.discover("/usr/bin/codex")

        self.assertEqual(features, ("shell_tool", "future_tool_surface"))
        self.assertEqual(
            overrides,
            (
                'web_search="disabled"',
                "tools.web_search=false",
                "agents.enabled=false",
                "tools.experimental_request_user_input.enabled=false",
                "tools.update_plan.enabled=false",
                "tools.view_image=false",
                mock.ANY,
                f'model="{MODULE.NO_TOOLS_MODEL}"',
            ),
        )
        validation_command = calls[-1]
        self.assertIn("exec", validation_command)
        self.assertIn("--strict-config", validation_command)
        self.assertIn("--ignore-user-config", validation_command)
        self.assertIn('web_search="disabled"', validation_command)
        self.assertIn("tools.web_search=false", validation_command)
        self.assertIn("tools.view_image=false", validation_command)
        for feature in features:
            index = validation_command.index(feature)
            self.assertEqual(validation_command[index - 1], "--disable")

    def test_no_tools_preflight_omits_an_unsupported_optional_image_override(self):
        listing = self.feature_listing("shell_tool", "view_image")

        def fake_run(command, **_kwargs):
            if command[-1] == "--version":
                return subprocess.CompletedProcess(command, 0, "codex-cli 0.153.4\n", "")
            if command[-2:] == ["features", "list"]:
                return subprocess.CompletedProcess(command, 0, listing, "")
            if "tools.view_image=false" in command:
                return subprocess.CompletedProcess(
                    command,
                    1,
                    "",
                    "unknown configuration field `tools.view_image` in -c/--config override\n",
                )
            return subprocess.CompletedProcess(command, 1, "", "No prompt provided via stdin.\n")

        with mock.patch.object(MODULE.subprocess, "run", side_effect=fake_run):
            features, overrides = self.discover("/usr/bin/codex")

        self.assertEqual(features, ("shell_tool", "view_image"))
        self.assertIn('web_search="disabled"', overrides)
        self.assertIn("tools.web_search=false", overrides)
        self.assertNotIn("tools.view_image=false", overrides)

    def test_no_tools_model_selection_uses_an_available_approved_general_model(self):
        selected = MODULE.select_no_tools_model([
            {"slug": "gpt-6-sol", "supported_in_api": True},
            {"slug": "gpt-5.4", "supported_in_api": True},
        ])

        self.assertEqual(selected["slug"], "gpt-5.4")

    def test_no_tools_model_selection_fails_closed_without_an_approved_model(self):
        with self.assertRaisesRegex(ValueError, "no approved general model"):
            MODULE.select_no_tools_model([
                {"slug": "gpt-6-sol", "supported_in_api": True},
                {"slug": "gpt-5.5", "supported_in_api": False},
            ])

    def test_named_model_selection_requires_the_requested_available_slug(self):
        models = [
            {"slug": "gpt-5.4", "supported_in_api": True},
            {"slug": "gpt-5.2", "supported_in_api": False},
        ]
        self.assertEqual(MODULE.select_named_model(models, "gpt-5.4")["slug"], "gpt-5.4")
        with self.assertRaisesRegex(ValueError, "not available"):
            MODULE.select_named_model(models, "gpt-5.2")
        with self.assertRaisesRegex(ValueError, "not available"):
            MODULE.select_named_model(models, "gpt-9")

    def test_no_tools_preflight_disables_namespaced_features_from_codex_154(self):
        calls = []
        listing = (
            "shell_tool                              stable             true\n"
            "guardianv2.thread_context                under development  false\n"
        )

        def fake_run(command, **_kwargs):
            calls.append(command)
            if command[-1] == "--version":
                return subprocess.CompletedProcess(command, 0, "codex-cli 0.154.0\n", "")
            if command[-2:] == ["features", "list"]:
                return subprocess.CompletedProcess(command, 0, listing, "")
            return subprocess.CompletedProcess(command, 1, "", "No prompt provided via stdin.\n")

        with mock.patch.object(MODULE.subprocess, "run", side_effect=fake_run):
            features, _ = self.discover("/usr/bin/codex")
        self.assertEqual(features, ("shell_tool", "guardianv2.thread_context"))
        validation_command = calls[-1]
        index = validation_command.index("guardianv2.thread_context")
        self.assertEqual(validation_command[index - 1], "--disable")

    def test_namespaced_feature_parser_rejects_malformed_segments(self):
        for name in ["guardianv2..thread_context", ".thread_context", "guardianv2.",
                     "--guardianv2.thread_context", "guardianv2.thread_context;evil"]:
            with self.subTest(name=name):
                self.assertIsNone(MODULE.FEATURE_LIST_ROW.fullmatch(
                    f"{name} under development false"
                ))

    def test_no_tools_preflight_fails_closed_when_feature_listing_fails(self):
        responses = [
            subprocess.CompletedProcess([], 0, "codex-cli 0.153.4\n", ""),
            subprocess.CompletedProcess([], 2, "", "feature registry unavailable"),
        ]
        with mock.patch.object(MODULE.subprocess, "run", side_effect=responses):
            with self.assertRaises(MODULE.CodexHarnessError) as raised:
                self.discover("/usr/bin/codex")

        detail = str(raised.exception)
        self.assertIn("codex-cli 0.153.4", detail)
        self.assertIn("feature registry unavailable", detail)
        self.assertIn("Classification was stopped before inference", detail)

    def test_no_tools_preflight_fails_closed_for_unrecognized_feature_output(self):
        responses = [
            subprocess.CompletedProcess([], 0, "codex-cli 0.153.4\n", ""),
            subprocess.CompletedProcess([], 0, "a newly formatted feature row\n", ""),
        ]
        with mock.patch.object(MODULE.subprocess, "run", side_effect=responses):
            with self.assertRaises(MODULE.CodexHarnessError) as raised:
                self.discover("/usr/bin/codex")

        detail = str(raised.exception)
        self.assertIn("could not parse", detail)
        self.assertIn("codex features list", detail)
        self.assertIn("Classification was stopped before inference", detail)

    def test_no_tools_preflight_reports_rejected_safety_controls(self):
        listing = self.feature_listing("shell_tool")

        def fake_run(command, **_kwargs):
            if command[-1] == "--version":
                return subprocess.CompletedProcess(command, 0, "codex-cli 0.153.4\n", "")
            if command[-2:] == ["features", "list"]:
                return subprocess.CompletedProcess(command, 0, listing, "")
            if "tools.web_search=false" in command:
                return subprocess.CompletedProcess(
                    command, 2, "", "unknown config key: tools.web_search"
                )
            return subprocess.CompletedProcess(command, 1, "", "No prompt provided via stdin.\n")

        with mock.patch.object(MODULE.subprocess, "run", side_effect=fake_run):
            with self.assertRaises(MODULE.CodexHarnessError) as raised:
                self.discover("/usr/bin/codex")

        detail = str(raised.exception)
        self.assertIn("rejected the required no-tools controls", detail)
        self.assertIn("tools.web_search", detail)
        self.assertIn("Update Codex or the Focus Queue harness", detail)

    def test_effective_manifest_must_contain_zero_tools_or_additional_tool_inputs(self):
        MODULE.validate_effective_no_tools_manifest(
            self.manifest(),
            version="codex-cli 0.153.4",
        )

        with self.assertRaisesRegex(MODULE.CodexHarnessError, "unexpected classifier tools"):
            MODULE.validate_effective_no_tools_manifest(
                self.manifest(tools=[{"type": "function", "name": "functions.exec"}]),
                version="codex-cli 0.153.4",
            )
        with self.assertRaisesRegex(MODULE.CodexHarnessError, "incomplete classifier manifest"):
            MODULE.validate_effective_no_tools_manifest(
                {},
                version="codex-cli 0.153.4",
            )
        with self.assertRaisesRegex(MODULE.CodexHarnessError, "unexpected classifier tools"):
            MODULE.validate_effective_no_tools_manifest(
                self.manifest(input_items=[{"type": "additional_tools"}]),
                version="codex-cli 0.153.4",
            )
        with self.assertRaisesRegex(MODULE.CodexHarnessError, "unrecognized classifier manifest shape"):
            MODULE.validate_effective_no_tools_manifest(
                self.manifest(unexpected_field=True),
                version="codex-cli 0.153.5",
            )

    def test_empty_prompt_probe_accepts_stdout_when_stderr_contains_a_warning(self):
        result = subprocess.CompletedProcess(
            [],
            1,
            "No prompt provided via stdin.\n",
            "warning: deprecated setting\n",
        )
        self.assertTrue(MODULE.is_empty_prompt_probe_exit(result))

    def test_process_group_shutdown_does_not_leave_descendants_running(self):
        if os.name == "nt":
            self.skipTest("POSIX process-state assertion")
        with tempfile.TemporaryDirectory() as temporary:
            pid_path = Path(temporary) / "child.pid"
            process = subprocess.Popen(
                ["/bin/sh", "-c", f"sleep 30 & echo $! > '{pid_path}'; wait"],
                start_new_session=True,
            )
            deadline = time.monotonic() + 2
            while not pid_path.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            MODULE.stop_process_group(process, grace_seconds=0.1)
            child_pid = int(pid_path.read_text().strip())
            status = subprocess.run(
                ["/bin/ps", "-p", str(child_pid), "-o", "stat="],
                capture_output=True,
                text=True,
                check=False,
            ).stdout.strip()
            self.assertTrue(not status or status.startswith("Z"), status)

    def test_parse_thread_id_ignores_non_json_output(self):
        events = 'noise\n{"type":"thread.started","thread_id":"thread-123"}\n'
        self.assertEqual(MODULE.parse_thread_id(events), "thread-123")

    def test_parse_token_usage_uses_the_final_completed_turn(self):
        events = "\n".join(
            [
                '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":1}}',
                '{"type":"turn.completed","usage":{"input_tokens":20,"cached_input_tokens":4,"output_tokens":7,"reasoning_output_tokens":2}}',
            ]
        )

        self.assertEqual(
            MODULE.parse_token_usage(events),
            {
                "inputTokens": 20,
                "cachedInputTokens": 4,
                "outputTokens": 7,
                "reasoningOutputTokens": 2,
                "totalTokens": 27,
            },
        )

    def test_usage_metadata_is_written_privately_for_the_calling_worker(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "usage.json"
            stdout = (
                '{"type":"turn.completed","usage":{"input_tokens":20,'
                '"cached_input_tokens":4,"output_tokens":7,"reasoning_output_tokens":2}}\n'
            )

            MODULE.write_token_usage(path, stdout)

            self.assertEqual(json.loads(path.read_text())["totalTokens"], 27)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_no_tools_classification_is_ephemeral_and_disables_every_advertised_tool_surface(self):
        captured = {}

        class FakeProcess:
            returncode = 0
            pid = 123

            def __init__(self, command, **_kwargs):
                captured["command"] = command
                reply = Path(command[command.index("--output-last-message") + 1])
                reply.write_text('{"version":1}', encoding="utf-8")

            def communicate(self, **_kwargs):
                return ('{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}\n', "")

            def poll(self):
                return 0

        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE, "resolve_codex", return_value="/usr/bin/codex"
        ), mock.patch.object(
            MODULE,
            "discover_no_tools_codex_capabilities",
            return_value=(
                ("shell_tool", "future_tool_surface"),
                (
                    'web_search="disabled"',
                    "tools.web_search=false",
                    "tools.view_image=false",
                    'model_catalog_json="/tmp/models.json"',
                    'model="gpt-5.2"',
                ),
            ),
        ), mock.patch.object(MODULE.subprocess, "Popen", FakeProcess):
            MODULE.run_codex(
                prompt="classify",
                workspace=Path(temporary),
                runtime=Path(temporary) / "runtime",
                timeout=10,
                sandbox="read-only",
                thread_id=None,
                output_schema=None,
                disable_tools=True,
            )

        command = captured["command"]
        self.assertIn("--ephemeral", command)
        self.assertIn("--strict-config", command)
        self.assertIn('web_search="disabled"', command)
        self.assertIn("tools.web_search=false", command)
        self.assertIn("tools.view_image=false", command)
        for feature in ("shell_tool", "future_tool_surface"):
            index = command.index(feature)
            self.assertEqual(command[index - 1], "--disable")

    def test_chat_exposes_mail_commands_but_not_mail_receipts(self):
        captured = {}

        class FakeProcess:
            returncode = 0
            pid = 123

            def __init__(self, command, **_kwargs):
                captured["command"] = command
                reply = Path(command[command.index("--output-last-message") + 1])
                reply.write_text("done", encoding="utf-8")

            def communicate(self, **_kwargs):
                return ('{"type":"thread.started","thread_id":"thread-123"}\n', "")

            def poll(self):
                return 0

        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE, "resolve_codex", return_value="/usr/bin/codex"
        ), mock.patch.object(MODULE.subprocess, "Popen", FakeProcess):
            MODULE.run_codex(
                prompt="check mail",
                workspace=Path(temporary),
                runtime=Path(temporary) / "runtime",
                timeout=10,
                sandbox="workspace-write",
                thread_id=None,
                output_schema=None,
                expose_evidence_directories=True,
            )

        command = captured["command"]
        self.assertIn(str(MODULE.DEFAULT_MAIL_COMMAND_DIRECTORY), command)
        self.assertIn(str(MODULE.DEFAULT_PROOF_DIRECTORY), command)
        self.assertNotIn(
            "/Users/hira/Library/Application Support/ECC Focus Queue/mail-proofs",
            command,
        )

    def test_chat_persists_a_named_thread_in_private_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prompt = root / "prompt.txt"
            prompt.write_text("Reply safely.", encoding="utf-8")
            arguments = argparse.Namespace(
                runtime=root / "runtime",
                session="queue",
                workspace=root,
                prompt_file=prompt,
                timeout=60,
            )
            with mock.patch.object(
                MODULE,
                "run_codex",
                return_value=("Verified reply", "thread-123"),
            ):
                with contextlib.redirect_stdout(io.StringIO()):
                    result = MODULE.chat(arguments)

            state = root / "runtime/sessions.json"
            self.assertEqual(result, 0)
            self.assertEqual(json.loads(state.read_text())["sessions"]["queue"], "thread-123")
            self.assertEqual(state.stat().st_mode & 0o777, 0o600)

    def test_context_directory_only_expands_writable_tool_enabled_runs(self):
        captured = []

        class FakeProcess:
            returncode = 0
            pid = 123

            def __init__(self, command, **_kwargs):
                captured.append(command)
                Path(command[command.index("--output-last-message") + 1]).write_text("done")

            def communicate(self, **_kwargs):
                return ('{"type":"thread.started","thread_id":"thread-123"}\n', "")

            def poll(self):
                return 0

        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE, "resolve_codex", return_value="/usr/bin/codex"
        ), mock.patch.object(
            MODULE, "discover_no_tools_codex_capabilities", return_value=(("shell_tool",), ())
        ), mock.patch.object(MODULE.subprocess, "Popen", FakeProcess), mock.patch.dict(
            os.environ, {"FOCUS_QUEUE_SUPPORT_DIR": temporary}
        ):
            root = Path(temporary)
            context = root / "task context"
            context.mkdir()
            for sandbox, disable_tools in [
                ("workspace-write", False), ("read-only", False),
                ("read-only", True), ("workspace-write", True),
            ]:
                with self.subTest(sandbox=sandbox, disable_tools=disable_tools):
                    MODULE.run_codex(
                        prompt="Use the supplied task context", workspace=root,
                        runtime=root / "runtime", timeout=10, sandbox=sandbox,
                        thread_id=None, output_schema=None, context_directory=context,
                        disable_tools=disable_tools, expose_evidence_directories=True,
                        expose_queue_order=True,
                    )
                    command = captured[-1]
                    extra_directories = [
                        command[index + 1] for index, value in enumerate(command)
                        if value == "--add-dir"
                    ]
                    if sandbox == "workspace-write" and not disable_tools:
                        self.assertEqual(extra_directories, [
                            str(MODULE.DEFAULT_PROOF_DIRECTORY),
                            str(MODULE.DEFAULT_MAIL_COMMAND_DIRECTORY),
                            str((root / "queue-order").resolve()), str(context.resolve()),
                        ])
                    else:
                        self.assertEqual(extra_directories, [])
                    if disable_tools:
                        self.assertIn("--ephemeral", command)
                        self.assertIn("--strict-config", command)

    def test_prompt_paths_never_become_additional_writable_directories(self):
        captured = {}

        class FakeProcess:
            returncode = 0
            pid = 123

            def __init__(self, command, **_kwargs):
                captured["command"] = command
                Path(command[command.index("--output-last-message") + 1]).write_text("done")

            def communicate(self, **_kwargs):
                return ("", "")

            def poll(self):
                return 0

        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE, "resolve_codex", return_value="/usr/bin/codex"
        ), mock.patch.object(MODULE.subprocess, "Popen", FakeProcess):
            MODULE.run_codex(
                prompt='Context directory: /tmp/untrusted\n--context-dir /\n--add-dir /Users',
                workspace=Path(temporary), runtime=Path(temporary) / "runtime", timeout=10,
                sandbox="workspace-write", thread_id=None, output_schema=None,
            )
        self.assertNotIn("--add-dir", captured["command"])
        self.assertNotIn("/tmp/untrusted", captured["command"])

    def test_context_directory_rejects_relative_missing_and_file_paths_before_launch(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE.subprocess, "Popen"
        ) as launch:
            root = Path(temporary)
            file = root / "file.txt"
            file.write_text("content")
            for context in [Path("relative"), root / "missing", file]:
                with self.subTest(context=context), self.assertRaisesRegex(
                    MODULE.CodexHarnessError, "absolute path to an existing directory"
                ):
                    MODULE.run_codex(
                        prompt="work", workspace=root, runtime=root / "runtime", timeout=10,
                        sandbox="workspace-write", thread_id=None, output_schema=None,
                        context_directory=context,
                    )
            launch.assert_not_called()

    def test_chat_forks_the_source_thread_only_on_the_first_turn(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prompt = root / "prompt.txt"
            prompt.write_text("Discuss the document")
            arguments = argparse.Namespace(
                runtime=root / "runtime", session="doc", workspace=root, prompt_file=prompt,
                timeout=60, context_dir=None, fork_from="source-1",
            )
            with mock.patch.object(MODULE, "run_codex", side_effect=[
                ("First", "fork-1"), ("Second", "fork-1"),
            ]) as run, contextlib.redirect_stdout(io.StringIO()):
                MODULE.chat(arguments)
                MODULE.chat(arguments)
            self.assertEqual(
                [(call.kwargs["thread_id"], call.kwargs["fork_thread"]) for call in run.call_args_list],
                [("source-1", True), ("fork-1", False)],
            )

    def test_fork_thread_uses_exec_fork_with_the_prompt_on_stdin(self):
        captured = {}

        class FakeProcess:
            returncode = 0
            pid = 123

            def __init__(self, command, **_kwargs):
                captured["command"] = command
                Path(command[command.index("--output-last-message") + 1]).write_text("ok", encoding="utf-8")

            def communicate(self, **_kwargs):
                return ('{"type":"thread.started","thread_id":"fork-2"}\n', "")

            def poll(self):
                return 0

        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE, "resolve_codex", return_value="/usr/bin/codex"
        ), mock.patch.object(MODULE.subprocess, "Popen", FakeProcess):
            reply, thread = MODULE.run_codex(
                prompt="Discuss", workspace=Path(temporary), runtime=Path(temporary) / "runtime",
                timeout=10, sandbox="workspace-write", thread_id="source-2", output_schema=None,
                fork_thread=True,
            )
        self.assertEqual(captured["command"][-3:], ["fork", "source-2", "-"])
        self.assertEqual((reply, thread), ("ok", "fork-2"))

    def test_chat_forwards_context_to_initial_resume_and_missing_thread_retry(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prompt = root / "prompt.txt"
            prompt.write_text("Continue task")
            arguments = argparse.Namespace(
                runtime=root / "runtime", session="task", workspace=root,
                prompt_file=prompt, timeout=60, context_dir=root,
            )
            with mock.patch.object(MODULE, "run_codex", side_effect=[
                ("First", "thread-1"),
                MODULE.CodexHarnessError("unknown thread"),
                ("Retry", "thread-2"),
            ]) as run, contextlib.redirect_stdout(io.StringIO()):
                MODULE.chat(arguments)
                MODULE.chat(arguments)
            self.assertEqual([call.kwargs["thread_id"] for call in run.call_args_list],
                             [None, "thread-1", None])
            self.assertTrue(all(call.kwargs["context_directory"] == root
                                for call in run.call_args_list))

    def test_run_once_forwards_context_and_preserves_no_tools_controls(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prompt = root / "prompt.txt"
            prompt.write_text("Classify source")
            arguments = argparse.Namespace(
                runtime=root / "runtime", workspace=root, prompt_file=prompt,
                timeout=60, context_dir=root, sandbox="read-only", output_schema=None,
                usage_file=None, disable_tools=True,
            )
            with mock.patch.object(MODULE, "run_codex", return_value=("Done", None)) as run:
                with contextlib.redirect_stdout(io.StringIO()):
                    MODULE.run_once(arguments)
            self.assertEqual(run.call_args.kwargs["context_directory"], root)
            self.assertEqual(run.call_args.kwargs["sandbox"], "read-only")
            self.assertTrue(run.call_args.kwargs["disable_tools"])

    def test_cli_accepts_explicit_context_directory_for_chat_and_run(self):
        for command, handler, extra in [("chat", "chat", ["--session", "task"]),
                                        ("run", "run_once", [])]:
            with self.subTest(command=command), mock.patch.object(sys, "argv", [
                str(SCRIPT), command, "--workspace", "/tmp", "--prompt-file", "/tmp/prompt.txt",
                "--context-dir", "/tmp/context", *extra,
            ]), mock.patch.object(MODULE, handler, return_value=0) as called:
                self.assertEqual(MODULE.main(), 0)
                self.assertEqual(called.call_args.args[0].context_dir, Path("/tmp/context"))

    def test_chat_threads_model_and_effort_into_initial_resume_and_retry(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prompt = root / "prompt.txt"
            prompt.write_text("Continue task")
            arguments = argparse.Namespace(
                runtime=root / "runtime", session="task", workspace=root,
                prompt_file=prompt, timeout=60, context_dir=None,
                model="gpt-5.4", effort="low",
            )
            with mock.patch.object(MODULE, "run_codex", side_effect=[
                ("First", "thread-1"),
                MODULE.CodexHarnessError("unknown thread"),
                ("Retry", "thread-2"),
            ]) as run, contextlib.redirect_stdout(io.StringIO()):
                MODULE.chat(arguments)
                MODULE.chat(arguments)
            for call in run.call_args_list:
                self.assertEqual(call.kwargs["model"], "gpt-5.4")
                self.assertEqual(call.kwargs["effort"], "low")

    def test_run_codex_appends_model_and_effort_in_the_tool_enabled_path(self):
        captured = {}

        class FakeProcess:
            returncode = 0
            pid = 123

            def __init__(self, command, **_kwargs):
                captured["command"] = command
                Path(command[command.index("--output-last-message") + 1]).write_text("done")

            def communicate(self, **_kwargs):
                return ('{"type":"thread.started","thread_id":"thread-123"}\n', "")

            def poll(self):
                return 0

        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE, "resolve_codex", return_value="/usr/bin/codex"
        ), mock.patch.object(MODULE.subprocess, "Popen", FakeProcess):
            MODULE.run_codex(
                prompt="work", workspace=Path(temporary),
                runtime=Path(temporary) / "runtime", timeout=10,
                sandbox="workspace-write", thread_id=None, output_schema=None,
                model="gpt-5.4", effort="low",
            )

        command = captured["command"]
        self.assertEqual(command[command.index("--model") + 1], "gpt-5.4")
        index = command.index("model_reasoning_effort=low")
        self.assertEqual(command[index - 1], "-c")

    def test_disable_tools_keeps_catalog_model_and_appends_effort_override(self):
        captured = {}

        class FakeProcess:
            returncode = 0
            pid = 123

            def __init__(self, command, **_kwargs):
                captured["command"] = command
                Path(command[command.index("--output-last-message") + 1]).write_text("done")

            def communicate(self, **_kwargs):
                return ('{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}\n', "")

            def poll(self):
                return 0

        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE, "resolve_codex", return_value="/usr/bin/codex"
        ), mock.patch.object(
            MODULE,
            "discover_no_tools_codex_capabilities",
            return_value=(("shell_tool",), ('web_search="disabled"',)),
        ) as discover, mock.patch.object(MODULE.subprocess, "Popen", FakeProcess):
            MODULE.run_codex(
                prompt="classify", workspace=Path(temporary),
                runtime=Path(temporary) / "runtime", timeout=10,
                sandbox="read-only", thread_id=None, output_schema=None,
                disable_tools=True, model="gpt-5.4", effort="medium",
            )

        self.assertEqual(discover.call_args.kwargs["model"], "gpt-5.4")
        command = captured["command"]
        self.assertNotIn("--model", command)
        index = command.index("model_reasoning_effort=medium")
        self.assertEqual(command[index - 1], "-c")

    def test_run_once_forwards_model_and_effort(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prompt = root / "prompt.txt"
            prompt.write_text("Classify source")
            arguments = argparse.Namespace(
                runtime=root / "runtime", workspace=root, prompt_file=prompt,
                timeout=60, context_dir=None, sandbox="read-only", output_schema=None,
                usage_file=None, disable_tools=True, model="gpt-5.2", effort="high",
            )
            with mock.patch.object(MODULE, "run_codex", return_value=("Done", None)) as run:
                with contextlib.redirect_stdout(io.StringIO()):
                    MODULE.run_once(arguments)
            self.assertEqual(run.call_args.kwargs["model"], "gpt-5.2")
            self.assertEqual(run.call_args.kwargs["effort"], "high")

    def test_cli_accepts_model_and_effort_for_chat_and_run(self):
        for command, handler, extra in [("chat", "chat", ["--session", "task"]),
                                        ("run", "run_once", [])]:
            with self.subTest(command=command), mock.patch.object(sys, "argv", [
                str(SCRIPT), "--runtime", "/tmp/runtime", command,
                "--workspace", "/tmp", "--prompt-file", "/tmp/prompt.txt",
                "--model", "gpt-5.4", "--effort", "low", *extra,
            ]), mock.patch.object(MODULE, handler, return_value=0) as called:
                self.assertEqual(MODULE.main(), 0)
                parsed = called.call_args.args[0]
                self.assertEqual(parsed.model, "gpt-5.4")
                self.assertEqual(parsed.effort, "low")
                self.assertEqual(parsed.runtime, Path("/tmp/runtime"))


if __name__ == "__main__":
    unittest.main()
