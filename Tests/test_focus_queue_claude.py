import argparse
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "Scripts/focus_queue_claude.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("focus_queue_claude", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def envelope(result: str, session_id: str = "11111111-2222-3333-4444-555555555555", **extra):
    payload = {
        "type": "result",
        "subtype": "success",
        "is_error": False,
        "result": result,
        "session_id": session_id,
        "usage": {
            "input_tokens": 10,
            "cache_read_input_tokens": 2,
            "output_tokens": 5,
        },
    }
    payload.update(extra)
    return json.dumps(payload) + "\n"


def fake_process(captured, stdout: str, returncode: int = 0, stderr: str = ""):
    class FakeProcess:
        def __init__(self, command, **kwargs):
            captured["command"] = command
            captured["kwargs"] = kwargs
            self.returncode = returncode
            self.pid = 123

        def communicate(self, input=None, **_kwargs):
            captured.setdefault("inputs", []).append(input)
            return stdout, stderr

        def poll(self):
            return self.returncode

    return FakeProcess


# Agent shells export the live support directory; keep provider usage events
# from these fixtures out of its token analytics (FOC-061).
_SUPPORT = tempfile.TemporaryDirectory()
_SUPPORT_ENV = mock.patch.dict(os.environ, {"FOCUS_QUEUE_SUPPORT_DIR": _SUPPORT.name})


def setUpModule():
    _SUPPORT_ENV.start()


def tearDownModule():
    _SUPPORT_ENV.stop()
    _SUPPORT.cleanup()


class FocusQueueClaudeTests(unittest.TestCase):
    def test_chat_command_uses_print_json_mode_with_full_parity_tools(self):
        captured = {}
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE, "resolve_claude", return_value="/usr/bin/claude"
        ), mock.patch.object(
            MODULE.subprocess, "Popen", fake_process(captured, envelope("done"))
        ), mock.patch.dict(os.environ, {"FOCUS_QUEUE_SUPPORT_DIR": temporary}):
            root = Path(temporary)
            context = root / "task context"
            context.mkdir()
            reply, session_id = MODULE.run_claude(
                prompt="check mail",
                workspace=root,
                runtime=root / "runtime",
                timeout=10,
                sandbox="workspace-write",
                session_id=None,
                output_schema=None,
                expose_evidence_directories=True,
                expose_queue_order=True,
                context_directory=context,
            )

            command = captured["command"]
            self.assertEqual(reply, "done")
            self.assertEqual(session_id, "11111111-2222-3333-4444-555555555555")
            self.assertIn("-p", command)
            self.assertEqual(command[command.index("--output-format") + 1], "json")
            self.assertEqual(
                command[command.index("--permission-mode") + 1], "bypassPermissions"
            )
            extra_directories = [
                command[index + 1] for index, value in enumerate(command) if value == "--add-dir"
            ]
            self.assertEqual(extra_directories, [
                str(MODULE.DEFAULT_PROOF_DIRECTORY),
                str(MODULE.DEFAULT_MAIL_COMMAND_DIRECTORY),
                str((root / "queue-order").resolve()),
                str(context.resolve()),
            ])
            self.assertEqual(captured["kwargs"]["cwd"], str(root))
            self.assertEqual(
                captured["kwargs"]["env"]["FOCUS_QUEUE_CONNECTOR_PROOF_DIR"],
                str(MODULE.DEFAULT_PROOF_DIRECTORY),
            )
            self.assertEqual(captured["inputs"], ["check mail"])
            self.assertEqual((root / "queue-order").stat().st_mode & 0o777, 0o700)

    def test_model_effort_and_resume_flags_are_forwarded(self):
        captured = {}
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE, "resolve_claude", return_value="/usr/bin/claude"
        ), mock.patch.object(
            MODULE.subprocess, "Popen", fake_process(captured, envelope("done"))
        ):
            MODULE.run_claude(
                prompt="continue",
                workspace=Path(temporary),
                runtime=Path(temporary) / "runtime",
                timeout=10,
                sandbox="workspace-write",
                session_id="99999999-8888-7777-6666-555555555555",
                output_schema=None,
                model="opus",
                effort="high",
            )

        command = captured["command"]
        self.assertEqual(command[command.index("--model") + 1], "opus")
        self.assertEqual(command[command.index("--effort") + 1], "high")
        self.assertEqual(
            command[command.index("--resume") + 1],
            "99999999-8888-7777-6666-555555555555",
        )

    def test_chat_persists_a_named_session_in_private_state(self):
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
                "run_claude",
                return_value=("Verified reply", "session-123"),
            ):
                with contextlib.redirect_stdout(io.StringIO()):
                    result = MODULE.chat(arguments)

            state = root / "runtime/sessions.json"
            self.assertEqual(result, 0)
            self.assertEqual(json.loads(state.read_text())["sessions"]["queue"], "session-123")
            self.assertEqual(state.stat().st_mode & 0o777, 0o600)

    def test_chat_forks_the_source_session_only_on_the_first_turn(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prompt = root / "prompt.txt"
            prompt.write_text("Discuss the document")
            arguments = argparse.Namespace(
                runtime=root / "runtime", session="doc", workspace=root, prompt_file=prompt,
                timeout=60, context_dir=None, model=None, effort=None, fork_from="source-1",
            )
            with mock.patch.object(MODULE, "run_claude", side_effect=[
                ("First", "fork-1"), ("Second", "fork-1"),
            ]) as run, contextlib.redirect_stdout(io.StringIO()):
                MODULE.chat(arguments)
                MODULE.chat(arguments)
            self.assertEqual(
                [(call.kwargs["session_id"], call.kwargs["fork_session"]) for call in run.call_args_list],
                [("source-1", True), ("fork-1", False)],
            )
            state = json.loads((root / "runtime/sessions.json").read_text())
            self.assertEqual(state["sessions"]["doc"], "fork-1")

    def test_a_missing_fork_source_fails_instead_of_starting_fresh(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prompt = root / "prompt.txt"
            prompt.write_text("Discuss the document")
            arguments = argparse.Namespace(
                runtime=root / "runtime", session="doc", workspace=root, prompt_file=prompt,
                timeout=60, context_dir=None, model=None, effort=None, fork_from="gone",
            )
            with mock.patch.object(MODULE, "run_claude", side_effect=MODULE.ClaudeHarnessError(
                "No conversation found with session ID: gone"
            )) as run, self.assertRaises(MODULE.ClaudeHarnessError):
                MODULE.chat(arguments)
            self.assertEqual(run.call_count, 1)

    def test_fork_session_resumes_the_source_with_the_fork_flag(self):
        captured = {}
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE, "resolve_claude", return_value="/usr/bin/claude"
        ), mock.patch.object(MODULE.subprocess, "Popen", fake_process(captured, envelope("ok", "fork-2"))):
            reply, session = MODULE.run_claude(
                prompt="Discuss", workspace=Path(temporary), runtime=Path(temporary) / "runtime",
                timeout=10, sandbox="workspace-write", session_id="source-2", output_schema=None,
                fork_session=True,
            )
        command = captured["command"]
        index = command.index("--resume")
        self.assertEqual(command[index:index + 3], ["--resume", "source-2", "--fork-session"])
        self.assertEqual((reply, session), ("ok", "fork-2"))

    def test_chat_recovers_from_a_missing_conversation_by_retrying_fresh(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prompt = root / "prompt.txt"
            prompt.write_text("Continue task")
            arguments = argparse.Namespace(
                runtime=root / "runtime", session="task", workspace=root,
                prompt_file=prompt, timeout=60, context_dir=None,
                model=None, effort=None,
            )
            with mock.patch.object(MODULE, "run_claude", side_effect=[
                ("First", "session-1"),
                MODULE.ClaudeHarnessError("No conversation found with session ID: session-1"),
                ("Retry", "session-2"),
            ]) as run, contextlib.redirect_stdout(io.StringIO()):
                MODULE.chat(arguments)
                MODULE.chat(arguments)
            self.assertEqual(
                [call.kwargs["session_id"] for call in run.call_args_list],
                [None, "session-1", None],
            )
            state = json.loads((root / "runtime/sessions.json").read_text())
            self.assertEqual(state["sessions"]["task"], "session-2")

    def test_disable_tools_run_disables_builtin_tools_and_validates_the_schema(self):
        captured = {}
        schema = {
            "type": "object",
            "additionalProperties": False,
            "required": ["version", "summary"],
            "properties": {
                "version": {"type": "integer", "const": 1},
                "summary": {"type": "string", "minLength": 1},
            },
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            schema_path = root / "schema.json"
            schema_path.write_text(json.dumps(schema))
            payload = {"version": 1, "summary": "classified"}
            with mock.patch.object(
                MODULE, "resolve_claude", return_value="/usr/bin/claude"
            ), mock.patch.object(
                MODULE.subprocess,
                "Popen",
                fake_process(captured, envelope(f"Here is the JSON:\n{json.dumps(payload)}")),
            ):
                reply, _ = MODULE.run_claude(
                    prompt="classify",
                    workspace=root,
                    runtime=root / "runtime",
                    timeout=10,
                    sandbox="read-only",
                    session_id=None,
                    output_schema=schema_path,
                    disable_tools=True,
                )

            command = captured["command"]
            self.assertEqual(command[command.index("--tools") + 1], "")
            self.assertNotIn("--permission-mode", command)
            self.assertNotIn("--add-dir", command)
            self.assertEqual(json.loads(reply), payload)

    def test_schema_violation_retries_once_with_a_correction(self):
        schema = {
            "type": "object",
            "required": ["version"],
            "properties": {"version": {"type": "integer", "const": 1}},
        }
        processes = []

        class FlakyProcess:
            def __init__(self, command, **_kwargs):
                self.returncode = 0
                self.pid = 123
                processes.append(self)
                self.attempt = len(processes)

            def communicate(self, input=None, **_kwargs):
                self.prompt = input
                if self.attempt == 1:
                    return envelope("not json at all"), ""
                return envelope('{"version": 1}'), ""

            def poll(self):
                return 0

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            schema_path = root / "schema.json"
            schema_path.write_text(json.dumps(schema))
            with mock.patch.object(
                MODULE, "resolve_claude", return_value="/usr/bin/claude"
            ), mock.patch.object(MODULE.subprocess, "Popen", FlakyProcess):
                reply, _ = MODULE.run_claude(
                    prompt="classify",
                    workspace=root,
                    runtime=root / "runtime",
                    timeout=10,
                    sandbox="read-only",
                    session_id=None,
                    output_schema=schema_path,
                    disable_tools=True,
                )

        self.assertEqual(json.loads(reply), {"version": 1})
        self.assertEqual(len(processes), 2)
        self.assertIn("previous reply was rejected", processes[1].prompt)

    def test_schema_violation_fails_after_one_retry(self):
        schema = {"type": "object", "required": ["version"]}

        class BadProcess:
            returncode = 0
            pid = 123

            def __init__(self, command, **_kwargs):
                pass

            def communicate(self, **_kwargs):
                return envelope("still not json"), ""

            def poll(self):
                return 0

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            schema_path = root / "schema.json"
            schema_path.write_text(json.dumps(schema))
            with mock.patch.object(
                MODULE, "resolve_claude", return_value="/usr/bin/claude"
            ), mock.patch.object(MODULE.subprocess, "Popen", BadProcess):
                with self.assertRaisesRegex(MODULE.ClaudeHarnessError, "after one retry"):
                    MODULE.run_claude(
                        prompt="classify",
                        workspace=root,
                        runtime=root / "runtime",
                        timeout=10,
                        sandbox="read-only",
                        session_id=None,
                        output_schema=schema_path,
                        disable_tools=True,
                    )

    def test_usage_file_maps_the_claude_envelope_to_the_shared_shape(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "usage.json"
            usage = MODULE.write_token_usage(path, envelope("done"))
            self.assertEqual(usage, {
                "inputTokens": 10,
                "cachedInputTokens": 2,
                "outputTokens": 5,
                "reasoningOutputTokens": 0,
                "totalTokens": 15,
            })
            self.assertEqual(json.loads(path.read_text())["totalTokens"], 15)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_envelope_errors_surface_without_prompt_content(self):
        captured = {}
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE, "resolve_claude", return_value="/usr/bin/claude"
        ), mock.patch.object(
            MODULE.subprocess,
            "Popen",
            fake_process(captured, "", returncode=1, stderr="authentication failed"),
        ):
            with self.assertRaisesRegex(MODULE.ClaudeHarnessError, "exited with code 1"):
                MODULE.run_claude(
                    prompt="secret prompt text",
                    workspace=Path(temporary),
                    runtime=Path(temporary) / "runtime",
                    timeout=10,
                    sandbox="read-only",
                    session_id=None,
                    output_schema=None,
                )

            diagnostic = json.loads(
                (Path(temporary) / "runtime/latest-run.json").read_text()
            )
            self.assertEqual(diagnostic["returnCode"], 1)
            self.assertNotIn("secret prompt text", json.dumps(diagnostic))

    def test_context_directory_rejects_relative_missing_and_file_paths_before_launch(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE.subprocess, "Popen"
        ) as launch:
            root = Path(temporary)
            file = root / "file.txt"
            file.write_text("content")
            for context in [Path("relative"), root / "missing", file]:
                with self.subTest(context=context), self.assertRaisesRegex(
                    MODULE.ClaudeHarnessError, "absolute path to an existing directory"
                ):
                    MODULE.run_claude(
                        prompt="work", workspace=root, runtime=root / "runtime", timeout=10,
                        sandbox="workspace-write", session_id=None, output_schema=None,
                        context_directory=context,
                    )
            launch.assert_not_called()

    def test_reset_drops_the_stored_session(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / "runtime"
            runtime.mkdir()
            MODULE.morning.write_private_json(
                runtime / "sessions.json", {"version": 1, "sessions": {"queue": "session-1"}}
            )
            arguments = argparse.Namespace(runtime=runtime, session="queue")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = MODULE.reset(arguments)

            self.assertEqual(result, 0)
            status = json.loads(output.getvalue())
            self.assertEqual(status, {"status": "ok", "session": "queue", "reset": True})
            state = json.loads((runtime / "sessions.json").read_text())
            self.assertEqual(state["sessions"], {})

    def test_schema_validator_enforces_the_supported_subset(self):
        definitions = {
            "link": {
                "type": "object",
                "required": ["url"],
                "properties": {"url": {"type": "string"}},
            }
        }
        schema = {
            "type": "object",
            "additionalProperties": False,
            "required": ["name", "links"],
            "properties": {
                "name": {"type": "string", "minLength": 2},
                "kind": {"type": "string", "enum": ["a", "b"]},
                "links": {"type": "array", "minItems": 1, "items": {"$ref": "#/$defs/link"}},
                "count": {"type": "integer", "minimum": 0},
            },
        }
        validate = lambda value: MODULE.validate_against_schema(  # noqa: E731
            value, schema, definitions=definitions
        )
        validate({"name": "ok", "kind": "a", "links": [{"url": "u"}], "count": 0})
        with self.assertRaisesRegex(MODULE.ClaudeHarnessError, "missing required key"):
            validate({"links": [{"url": "u"}]})
        with self.assertRaisesRegex(MODULE.ClaudeHarnessError, "unexpected keys"):
            validate({"name": "ok", "links": [{"url": "u"}], "extra": 1})
        with self.assertRaisesRegex(MODULE.ClaudeHarnessError, "not an allowed value"):
            validate({"name": "ok", "kind": "c", "links": [{"url": "u"}]})
        with self.assertRaisesRegex(MODULE.ClaudeHarnessError, "fewer than 1 items"):
            validate({"name": "ok", "links": []})
        with self.assertRaisesRegex(MODULE.ClaudeHarnessError, "shorter than 2"):
            validate({"name": "x", "links": [{"url": "u"}]})
        with self.assertRaisesRegex(MODULE.ClaudeHarnessError, "expected type"):
            validate({"name": "ok", "links": [{"url": 3}]})
        with self.assertRaisesRegex(MODULE.ClaudeHarnessError, "Unsupported schema reference"):
            MODULE.validate_against_schema(
                {"x": 1},
                {"type": "object", "properties": {"x": {"$ref": "#/$defs/absent"}}},
                definitions=definitions,
            )

    def test_cli_accepts_model_effort_and_runtime_for_chat_and_run(self):
        for command, handler, extra in [("chat", "chat", ["--session", "task"]),
                                        ("run", "run_once", [])]:
            with self.subTest(command=command), mock.patch.object(sys, "argv", [
                str(SCRIPT), "--runtime", "/tmp/runtime", command,
                "--workspace", "/tmp", "--prompt-file", "/tmp/prompt.txt",
                "--model", "opus", "--effort", "low", *extra,
            ]), mock.patch.object(MODULE, handler, return_value=0) as called:
                self.assertEqual(MODULE.main(), 0)
                parsed = called.call_args.args[0]
                self.assertEqual(parsed.model, "opus")
                self.assertEqual(parsed.effort, "low")
                self.assertEqual(parsed.runtime, Path("/tmp/runtime"))


if __name__ == "__main__":
    unittest.main()
