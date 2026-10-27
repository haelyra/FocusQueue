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


SCRIPT = Path(__file__).parents[1] / "Scripts/focus_queue_kimi.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("focus_queue_kimi", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

SESSION_ID = "session_11111111-2222-3333-4444-555555555555"


def stream_lines(*events: dict) -> str:
    return "".join(json.dumps(event) + "\n" for event in events)


def assistant_event(text: str, **extra) -> dict:
    event = {
        "type": "assistant",
        "message": {"role": "assistant", "content": [{"type": "text", "text": text}]},
    }
    event.update(extra)
    return event


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


class FocusQueueKimiTests(unittest.TestCase):
    def test_chat_command_uses_prompt_argument_and_stream_json(self):
        captured = {}
        stdout = stream_lines(assistant_event("done", session_id=SESSION_ID))
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE, "resolve_kimi", return_value="/usr/bin/kimi"
        ), mock.patch.object(
            MODULE, "newest_workspace_session", return_value=None
        ), mock.patch.object(
            MODULE.subprocess, "Popen", fake_process(captured, stdout)
        ), mock.patch.dict(os.environ, {"FOCUS_QUEUE_SUPPORT_DIR": temporary}):
            root = Path(temporary)
            context = root / "task context"
            context.mkdir()
            reply, session_id = MODULE.run_kimi(
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
        self.assertEqual(session_id, SESSION_ID)
        self.assertEqual(command[command.index("--prompt") + 1], "check mail")
        self.assertEqual(command[command.index("--output-format") + 1], "stream-json")
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
        self.assertEqual(captured["inputs"], [""])

    def test_model_and_session_flags_are_forwarded_and_effort_is_dropped(self):
        captured = {}
        stdout = stream_lines(assistant_event("continued"))
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE, "resolve_kimi", return_value="/usr/bin/kimi"
        ), mock.patch.object(
            MODULE, "newest_workspace_session", return_value=None
        ), mock.patch.object(MODULE.subprocess, "Popen", fake_process(captured, stdout)):
            _, session_id = MODULE.run_kimi(
                prompt="continue",
                workspace=Path(temporary),
                runtime=Path(temporary) / "runtime",
                timeout=10,
                sandbox="workspace-write",
                session_id=SESSION_ID,
                output_schema=None,
                model="kimi-code/k3",
            )

        command = captured["command"]
        self.assertEqual(command[command.index("--model") + 1], "kimi-code/k3")
        self.assertEqual(command[command.index("--session") + 1], SESSION_ID)
        self.assertNotIn("--effort", command)
        # A resumed session that emits no id keeps the stored identifier.
        self.assertEqual(session_id, SESSION_ID)

    def test_session_id_falls_back_to_the_newest_workspace_session(self):
        captured = {}
        stdout = stream_lines(assistant_event("fresh reply"))
        listings = [
            {"id": "session_old", "updatedAt": 1},
            {"id": SESSION_ID, "updatedAt": 2},
        ]
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE, "resolve_kimi", return_value="/usr/bin/kimi"
        ), mock.patch.object(
            MODULE, "newest_workspace_session", side_effect=listings
        ) as listing, mock.patch.object(
            MODULE.subprocess, "Popen", fake_process(captured, stdout)
        ):
            _, session_id = MODULE.run_kimi(
                prompt="hello",
                workspace=Path(temporary),
                runtime=Path(temporary) / "runtime",
                timeout=10,
                sandbox="workspace-write",
                session_id=None,
                output_schema=None,
            )

        self.assertEqual(session_id, SESSION_ID)
        self.assertEqual(listing.call_count, 2)

    def test_session_id_fallback_ignores_an_unchanged_store(self):
        captured = {}
        stdout = stream_lines(assistant_event("fresh reply"))
        unchanged = {"id": "session_old", "updatedAt": 1}
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE, "resolve_kimi", return_value="/usr/bin/kimi"
        ), mock.patch.object(
            MODULE, "newest_workspace_session", return_value=unchanged
        ), mock.patch.object(MODULE.subprocess, "Popen", fake_process(captured, stdout)):
            _, session_id = MODULE.run_kimi(
                prompt="hello",
                workspace=Path(temporary),
                runtime=Path(temporary) / "runtime",
                timeout=10,
                sandbox="workspace-write",
                session_id=None,
                output_schema=None,
            )

        self.assertIsNone(session_id)

    def test_lean_turn_uses_the_chat_profile_and_records_wire_usage(self):
        captured = {}
        stdout = stream_lines(assistant_event("done", session_id=SESSION_ID))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session_dir = root / "store" / "session_new"
            (session_dir / "agents" / "main").mkdir(parents=True)
            (session_dir / "agents" / "main" / "wire.jsonl").write_text("\n".join(json.dumps(e) for e in [
                {"type": "usage.record", "usage": {"inputOther": 100, "inputCacheRead": 900, "output": 20}},
                {"type": "usage.record", "usage": {"inputOther": 50, "inputCacheRead": 1000, "output": 30}},
                {"type": "turn.ended"},
            ]))
            listings = [None, {"id": "session_new", "updatedAt": 2, "sessionDir": str(session_dir)}]
            with mock.patch.object(MODULE, "resolve_kimi", return_value="/usr/bin/kimi"), \
                    mock.patch.object(MODULE, "newest_workspace_session", side_effect=listings) as newest, \
                    mock.patch.object(MODULE.subprocess, "Popen", fake_process(captured, stdout)):
                MODULE.run_kimi(
                    prompt="hi", workspace=root, runtime=root / "runtime", timeout=10,
                    sandbox="workspace-write", session_id=None, output_schema=None,
                    usage_file=root / "usage.json", lean=True,
                )

            command = captured["command"]
            lean_directory = root / "runtime" / "lean-chat"
            self.assertEqual(captured["kwargs"]["cwd"], str(lean_directory))
            self.assertEqual(newest.call_args_list[0].args[1], lean_directory)
            agent_file = Path(command[command.index("--agent-file") + 1])
            self.assertIn("tools: Bash, Read, Edit, Write, Grep, Glob", agent_file.read_text())
            self.assertEqual(command[command.index("--skills-dir") + 1], str(root / "runtime" / "lean-chat-skills"))
            self.assertIn(str(root), [command[i + 1] for i, v in enumerate(command) if v == "--add-dir"])
            usage = json.loads((root / "usage.json").read_text())
            self.assertEqual(usage["inputTokens"], 2050)
            self.assertEqual(usage["cachedInputTokens"], 1900)
            self.assertEqual(usage["outputTokens"], 50)

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
                "run_kimi",
                return_value=("Verified reply", SESSION_ID),
            ):
                with contextlib.redirect_stdout(io.StringIO()):
                    result = MODULE.chat(arguments)

            state = root / "runtime/sessions.json"
            self.assertEqual(result, 0)
            self.assertEqual(json.loads(state.read_text())["sessions"]["queue"], SESSION_ID)
            self.assertEqual(state.stat().st_mode & 0o777, 0o600)

    def test_chat_forks_once_and_saves_the_fork_before_the_first_turn(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prompt = root / "prompt.txt"
            prompt.write_text("Discuss the document")
            arguments = argparse.Namespace(
                runtime=root / "runtime", session="doc", workspace=root, prompt_file=prompt,
                timeout=60, context_dir=None, model=None, fork_from="session_source",
            )
            forked = mock.Mock(returncode=0, stdout='Forked to session_fork-1 ("Fork: session_source") in 9ms\n', stderr="")
            with mock.patch.object(MODULE, "resolve_kimi", return_value="/usr/bin/kimi"), \
                    mock.patch.object(MODULE.subprocess, "run", return_value=forked) as fork, \
                    mock.patch.object(MODULE, "run_kimi", side_effect=[
                        ("First", "session_fork-1"), ("Second", "session_fork-1"),
                    ]) as run, contextlib.redirect_stdout(io.StringIO()):
                MODULE.chat(arguments)
                MODULE.chat(arguments)
            self.assertEqual(fork.call_count, 1)
            self.assertEqual(fork.call_args.args[0], ["/usr/bin/kimi", "fork", "session_source", "-y"])
            self.assertEqual([call.kwargs["session_id"] for call in run.call_args_list],
                             ["session_fork-1", "session_fork-1"])

    def test_a_failed_fork_reports_the_kimi_error(self):
        failed = mock.Mock(returncode=1, stdout="", stderr="Session not found")
        with mock.patch.object(MODULE, "resolve_kimi", return_value="/usr/bin/kimi"), \
                mock.patch.object(MODULE.subprocess, "run", return_value=failed), \
                self.assertRaisesRegex(MODULE.KimiHarnessError, "Session not found"):
            MODULE.fork_session("session_gone", Path("/tmp"))

    def test_chat_recovers_from_a_missing_session_by_retrying_fresh(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prompt = root / "prompt.txt"
            prompt.write_text("Continue task")
            arguments = argparse.Namespace(
                runtime=root / "runtime", session="task", workspace=root,
                prompt_file=prompt, timeout=60, context_dir=None, model=None,
            )
            with mock.patch.object(MODULE, "run_kimi", side_effect=[
                ("First", "session-1"),
                MODULE.KimiHarnessError("session session-1 not found"),
                ("Retry", "session-2"),
            ]) as run, contextlib.redirect_stdout(io.StringIO()):
                MODULE.chat(arguments)
                MODULE.chat(arguments)
            self.assertEqual(
                [call.kwargs["session_id"] for call in run.call_args_list],
                [None, "session-1", None],
            )

    def test_disable_tools_run_validates_the_schema_and_retries_once(self):
        schema = {
            "type": "object",
            "required": ["version"],
            "properties": {"version": {"type": "integer", "const": 1}},
        }
        processes = []

        class FlakyProcess:
            def __init__(self, command, **_kwargs):
                self.command = command
                self.returncode = 0
                self.pid = 123
                processes.append(self)
                self.attempt = len(processes)

            def communicate(self, input=None, **_kwargs):
                if self.attempt == 1:
                    return stream_lines(assistant_event("not json")), ""
                return stream_lines(assistant_event('{"version": 1}')), ""

            def poll(self):
                return 0

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            schema_path = root / "schema.json"
            schema_path.write_text(json.dumps(schema))
            with mock.patch.object(
                MODULE, "resolve_kimi", return_value="/usr/bin/kimi"
            ), mock.patch.object(
                MODULE, "newest_workspace_session", return_value=None
            ), mock.patch.object(MODULE.subprocess, "Popen", FlakyProcess):
                reply, _ = MODULE.run_kimi(
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
        self.assertNotIn("--add-dir", processes[0].command)
        retry_prompt = processes[1].command[processes[1].command.index("--prompt") + 1]
        self.assertIn("previous reply was rejected", retry_prompt)

    def test_usage_file_maps_stream_usage_to_the_shared_shape(self):
        stdout = stream_lines(
            assistant_event("done"),
            {"type": "result", "usage": {"input_tokens": 7, "output_tokens": 3}},
        )
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "usage.json"
            usage = MODULE.write_token_usage(path, stdout)
            self.assertEqual(usage, {
                "inputTokens": 7,
                "cachedInputTokens": 0,
                "outputTokens": 3,
                "reasoningOutputTokens": 0,
                "totalTokens": 10,
            })
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_usage_file_is_not_written_without_usage_events(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "usage.json"
            usage = MODULE.write_token_usage(path, stream_lines(assistant_event("done")))
            self.assertIsNone(usage)
            self.assertFalse(path.exists())

    def test_context_directory_rejects_relative_missing_and_file_paths_before_launch(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            MODULE.subprocess, "Popen"
        ) as launch:
            root = Path(temporary)
            file = root / "file.txt"
            file.write_text("content")
            for context in [Path("relative"), root / "missing", file]:
                with self.subTest(context=context), self.assertRaisesRegex(
                    MODULE.KimiHarnessError, "absolute path to an existing directory"
                ):
                    MODULE.run_kimi(
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

    def test_cli_accepts_and_drops_effort_for_chat_and_run(self):
        for command, handler, extra in [("chat", "chat", ["--session", "task"]),
                                        ("run", "run_once", [])]:
            with self.subTest(command=command), mock.patch.object(sys, "argv", [
                str(SCRIPT), "--runtime", "/tmp/runtime", command,
                "--workspace", "/tmp", "--prompt-file", "/tmp/prompt.txt",
                "--model", "kimi-code/k3", "--effort", "low", *extra,
            ]), mock.patch.object(MODULE, handler, return_value=0) as called:
                self.assertEqual(MODULE.main(), 0)
                parsed = called.call_args.args[0]
                self.assertEqual(parsed.model, "kimi-code/k3")
                self.assertEqual(parsed.effort, "low")

    def test_newest_workspace_session_reads_the_local_store(self):
        completed = MODULE.subprocess.CompletedProcess(
            [], 0, json.dumps([{"id": SESSION_ID, "updatedAt": 5}]), ""
        )
        with mock.patch.object(MODULE.subprocess, "run", return_value=completed) as run:
            session = MODULE.newest_workspace_session("/usr/bin/kimi", Path("/tmp/workspace"))

        self.assertEqual(session["id"], SESSION_ID)
        command = run.call_args.args[0]
        self.assertEqual(command[:2], ["/usr/bin/kimi", "session"])
        self.assertIn("--json", command)
        self.assertEqual(command[command.index("--cwd") + 1], "/tmp/workspace")
        self.assertEqual(MODULE.session_marker(session), (SESSION_ID, 5))


if __name__ == "__main__":
    unittest.main()
