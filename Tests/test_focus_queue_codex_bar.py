import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).parents[1]
RENDERER = ROOT / "Scripts/focus_queue_codex_bar.js"


class FocusQueueCodexBarTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="focus queue codex bar ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.codex_home = self.root / "codex"
        self.sessions = self.codex_home / "sessions/2026/09/24"
        self.sessions.mkdir(parents=True)
        self.context = self.root / "context.json"
        self.first_session = "01a0d15c-33b1-7442-9e82-83038734d23b"
        self.second_session = "01a0d15c-ad43-7ab3-bbaa-e8b703b84f05"
        self.context.write_text(json.dumps({
            "ticketID": "ECC-035",
            "title": "Usage bar test",
            "subtasks": [
                {
                    "id": "agent-one",
                    "sessionID": self.first_session,
                    "launchConfiguration": {"model": "gpt-agent-one", "effort": "high"},
                },
                {
                    "id": "agent-two",
                    "sessionID": self.second_session,
                    "launchConfiguration": {"model": "gpt-agent-two", "effort": "low"},
                },
            ],
        }))
        self.write_session(self.first_session, context_tokens=25_000, total_tokens=40_000,
                           context_window=250_000, used_percent=12)
        self.write_session(self.second_session, context_tokens=200_000, total_tokens=300_000,
                           context_window=250_000, used_percent=88)
        os.utime(self.session_path(self.second_session), (2_000_000_000, 2_000_000_000))

    def session_path(self, session_id):
        return self.sessions / f"rollout-2026-09-24T00-00-00-{session_id}.jsonl"

    def write_session(self, session_id, *, context_tokens, total_tokens, context_window,
                      used_percent):
        event = {
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "total_token_usage": {"total_tokens": total_tokens},
                    "last_token_usage": {
                        "input_tokens": context_tokens,
                        "cached_input_tokens": context_tokens // 2,
                        "total_tokens": context_tokens,
                    },
                    "model_context_window": context_window,
                },
                "rate_limits": {
                    "primary": {"used_percent": used_percent, "window_minutes": 300},
                },
            },
        }
        self.session_path(session_id).write_text(json.dumps(event) + "\n")

    def render(self, agent, line):
        return subprocess.run([
            "node", str(RENDERER), "--plain", "--context", str(self.context),
            "--agent", agent, "--cwd", str(self.root / agent), "--line", str(line),
        ], capture_output=True, text=True, env={**os.environ, "CODEX_HOME": str(self.codex_home)},
           timeout=10)

    def test_context_window_and_model_are_selected_by_exact_agent_session(self):
        first = self.render("agent-one", 2)
        second = self.render("agent-two", 2)

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("gpt-agent-one", first.stdout)
        self.assertIn("high", first.stdout)
        self.assertIn("ctx", first.stdout)
        self.assertIn("10%", first.stdout)
        self.assertNotIn("80%", first.stdout)

        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("gpt-agent-two", second.stdout)
        self.assertIn("low", second.stdout)
        self.assertIn("80%", second.stdout)

    def test_quota_uses_the_freshest_account_snapshot_while_directory_follows_the_agent(self):
        usage = self.render("agent-one", 1)
        details = self.render("agent-one", 3)

        self.assertEqual(usage.returncode, 0, usage.stderr)
        self.assertIn("88%", usage.stdout)
        self.assertEqual(details.returncode, 0, details.stderr)
        self.assertIn("agent-one", details.stdout)
        self.assertIn("ECC-035", details.stdout)

    def test_unregistered_agent_never_falls_back_to_another_transcript(self):
        result = self.render("unknown-agent", 2)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("waiting for agent session", result.stdout)
        self.assertNotIn("gpt-agent-one", result.stdout)
        self.assertNotIn("gpt-agent-two", result.stdout)


if __name__ == "__main__":
    unittest.main()
