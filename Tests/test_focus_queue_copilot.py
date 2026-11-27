from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "Scripts/focus_queue_copilot.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("focus_queue_copilot", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

SESSION_ID = "11111111-2222-4333-8444-555555555555"

USAGE_PAYLOAD = {
    "tokenDetails": {
        "input": {"tokenCount": 10},
        "cache_read": {"tokenCount": 700},
        "cache_write": {"tokenCount": 60},
        "output": {"tokenCount": 25},
    }
}


def fake_process(captured, stdout: str, returncode: int = 0, stderr: str = "", usage: dict | None = None):
    class FakeProcess:
        def __init__(self, command, **kwargs):
            captured["command"] = command
            captured["kwargs"] = kwargs
            self.returncode = returncode
            self.pid = 123

        def communicate(self, input=None, **_kwargs):
            captured.setdefault("inputs", []).append(input)
            if usage is not None:
                index = captured["command"].index("--usage-output-file")
                Path(captured["command"][index + 1]).write_text(json.dumps(usage), encoding="utf-8")
            return stdout, stderr

        def poll(self):
            return self.returncode

    return FakeProcess


def run_chat(captured, stdout="done", **overrides):
    options = {
        "prompt": "check the queue",
        "workspace": Path(tempfile.mkdtemp()),
        "runtime": Path(tempfile.mkdtemp()) / "runtime",
        "timeout": 10,
        "sandbox": "workspace-write",
        "session_id": None,
        "output_schema": None,
        "expose_evidence_directories": True,
        "expose_queue_order": True,
        "lean": True,
    }
    options.update(overrides)
    with mock.patch.object(MODULE, "resolve_copilot", return_value="/usr/bin/copilot"), mock.patch.object(
        MODULE.subprocess, "Popen", fake_process(captured, stdout)
    ):
        return MODULE.run_copilot(**options)


class FocusQueueCopilotTests(unittest.TestCase):
    def test_chat_command_builds_prompt_mode_invocation(self):
        captured = {}
        reply, session_id = run_chat(captured)
        command = captured["command"]
        self.assertEqual(reply, "done")
        self.assertEqual(session_id, captured_session_id(command))
        self.assertEqual(command[:2], ["/usr/bin/copilot", "-p"])
        self.assertIn("check the queue", command)
        self.assertIn("-s", command)
        self.assertIn("--allow-all", command)
        self.assertIn("--no-custom-instructions", command)
        tools = command[command.index("--available-tools") + 1:command.index("--no-custom-instructions")]
        self.assertEqual(tools, MODULE.LEAN_CHAT_TOOLS.split(","))
        # A fresh session is named up front with a valid UUID.
        self.assertTrue(uuid.UUID(captured_session_id(command)))

    def test_resume_uses_saved_session(self):
        captured = {}
        _, session_id = run_chat(captured, session_id=SESSION_ID)
        command = captured["command"]
        self.assertEqual(session_id, SESSION_ID)
        self.assertIn("--resume", command)
        self.assertEqual(command[command.index("--resume") + 1], SESSION_ID)
        self.assertNotIn("--session-id", command)

    def test_permissions_ask_omits_allow_all_and_writes(self):
        captured = {}
        run_chat(captured, bypass_permissions=False)
        command = captured["command"]
        self.assertNotIn("--allow-all", command)
        tools = command[command.index("--available-tools") + 1:command.index("--no-custom-instructions")]
        self.assertEqual(tools, MODULE.READ_ONLY_TOOLS.split(","))

    def test_editor_turn_is_tool_free_with_instruction(self):
        captured = {}
        run_chat(captured, editor=True)
        command = captured["command"]
        prompt = command[command.index("-p") + 1]
        self.assertTrue(prompt.startswith(MODULE.EDITOR_INSTRUCTION))
        # `--available-tools` is followed immediately by the next flag: no tools.
        self.assertTrue(command[command.index("--available-tools") + 1].startswith("--"))

    def test_reader_turn_uses_reader_tools(self):
        captured = {}
        run_chat(captured, reader=True)
        command = captured["command"]
        tools = command[command.index("--available-tools") + 1:command.index("--no-custom-instructions")]
        self.assertEqual(tools, MODULE.READER_TOOLS.split(","))

    def test_model_and_effort_flags(self):
        captured = {}
        run_chat(captured, model="claude-sonnet-5.5", effort="high")
        command = captured["command"]
        self.assertEqual(command[command.index("--model") + 1], "claude-sonnet-5.5")
        self.assertEqual(command[command.index("--reasoning-effort") + 1], "high")

    def test_usage_file_maps_token_details(self):
        with tempfile.TemporaryDirectory() as temporary:
            usage_path = Path(temporary) / "usage.json"
            captured = {}
            with mock.patch.object(MODULE, "resolve_copilot", return_value="/usr/bin/copilot"), mock.patch.object(
                MODULE.subprocess, "Popen", fake_process(captured, "done", usage=USAGE_PAYLOAD)
            ):
                MODULE.run_copilot(
                    prompt="hi",
                    workspace=Path(temporary),
                    runtime=Path(temporary) / "runtime",
                    timeout=10,
                    sandbox="workspace-write",
                    session_id=None,
                    output_schema=None,
                    usage_file=usage_path,
                )
            usage = json.loads(usage_path.read_text(encoding="utf-8"))
            self.assertEqual(
                usage,
                {"inputTokens": 10, "cachedInputTokens": 760, "outputTokens": 25,
                 "reasoningOutputTokens": 0, "totalTokens": 35},
            )

    def test_parse_usage_file_model_metrics_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "usage.json"
            path.write_text(json.dumps({
                "modelMetrics": {
                    "claude-sonnet-5.5": {"usage": {
                        "inputTokens": 860, "outputTokens": 89,
                        "cacheReadTokens": 700, "cacheWriteTokens": 60, "reasoningTokens": 3,
                    }}
                }
            }), encoding="utf-8")
            self.assertEqual(
                MODULE.parse_usage_file(path),
                {"inputTokens": 100, "cachedInputTokens": 760, "outputTokens": 89,
                 "reasoningOutputTokens": 3, "totalTokens": 189},
            )

    def test_reset_removes_session_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "copilot-home"
            state_dir = home / "session-state" / SESSION_ID
            state_dir.mkdir(parents=True)
            runtime = Path(temporary) / "runtime"
            runtime.mkdir()
            (runtime / "sessions.json").write_text(
                json.dumps({"version": 1, "sessions": {"chat": SESSION_ID}}), encoding="utf-8")
            with mock.patch.dict(os.environ, {"COPILOT_HOME": str(home)}):
                stream = io.StringIO()
                with contextlib.redirect_stdout(stream):
                    MODULE.reset(argparse.Namespace(runtime=runtime, session="chat"))
            result = json.loads(stream.getvalue())
            self.assertTrue(result["reset"])
            self.assertEqual(result["transcriptsRemoved"], 1)
            self.assertFalse(state_dir.exists())
            self.assertNotIn("chat", json.loads((runtime / "sessions.json").read_text())["sessions"])

    def test_nonzero_exit_raises_with_detail(self):
        captured = {}
        with self.assertRaises(MODULE.CopilotHarnessError):
            with mock.patch.object(MODULE, "resolve_copilot", return_value="/usr/bin/copilot"), mock.patch.object(
                MODULE.subprocess, "Popen", fake_process(captured, "", returncode=1, stderr="boom")
            ):
                MODULE.run_copilot(
                    prompt="hi",
                    workspace=Path(tempfile.mkdtemp()),
                    runtime=Path(tempfile.mkdtemp()) / "runtime",
                    timeout=10,
                    sandbox="workspace-write",
                    session_id=None,
                    output_schema=None,
                )


def captured_session_id(command):
    return command[command.index("--session-id") + 1]


if __name__ == "__main__":
    unittest.main()
