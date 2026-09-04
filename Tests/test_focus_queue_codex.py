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


class FocusQueueCodexTests(unittest.TestCase):
    def test_classification_tool_denylist_covers_execution_and_connectors(self):
        self.assertIn("shell_tool", MODULE.TOOL_FEATURES)
        self.assertIn("unified_exec", MODULE.TOOL_FEATURES)
        self.assertIn("browser_use", MODULE.TOOL_FEATURES)
        self.assertIn("apps", MODULE.TOOL_FEATURES)
        self.assertIn("plugins", MODULE.TOOL_FEATURES)
        self.assertIn("tool_call_mcp_elicitation", MODULE.TOOL_FEATURES)

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

    def test_no_tools_classification_is_ephemeral_and_disables_every_known_tool_surface(self):
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
            MODULE.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 0, "codex-cli 0.153.0\n", ""),
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
        for feature in MODULE.TOOL_FEATURES:
            index = command.index(feature)
            self.assertEqual(command[index - 1], "--disable")

    def test_no_tools_classification_fails_closed_for_an_unaudited_codex_version(self):
        result = subprocess.CompletedProcess([], 0, "codex-cli 0.154.0\n", "")
        with mock.patch.object(MODULE.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(MODULE.CodexHarnessError, "until this Codex CLI version is audited"):
                MODULE.assert_supported_no_tools_codex("/usr/bin/codex")

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


if __name__ == "__main__":
    unittest.main()
