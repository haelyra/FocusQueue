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
        self.claude_home = self.root / "claude"
        self.claude_project = self.claude_home / "projects/-Users-test-repository"
        self.claude_project.mkdir(parents=True)
        self.context = self.root / "context.json"
        self.first_session = "01a0d15c-33b1-7442-9e82-83038734d23b"
        self.second_session = "01a0d15c-ad43-7ab3-bbaa-e8b703b84f05"
        self.first_claude_session = "3f4a9c1e-2b7d-4c5a-8e6f-1a2b3c4d5e6f"
        self.second_claude_session = "9b8a7d6c-5e4f-4a3b-8c2d-0e1f2a3b4c5d"
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
                {
                    "id": "claude-one",
                    "provider": "claude",
                    "sessionID": self.first_claude_session,
                    "launchConfiguration": {"model": "claude-agent-one", "effort": "medium"},
                },
                {
                    "id": "claude-two",
                    "provider": "claude",
                    "sessionID": self.second_claude_session,
                },
            ],
        }))
        self.write_session(self.first_session, context_tokens=25_000, total_tokens=40_000,
                           context_window=250_000, used_percent=12)
        self.write_session(self.second_session, context_tokens=200_000, total_tokens=300_000,
                           context_window=250_000, used_percent=88)
        os.utime(self.session_path(self.second_session), (2_000_000_000, 2_000_000_000))
        self.write_claude_session(self.first_claude_session, context_tokens=20_000)
        self.write_claude_session(self.second_claude_session, context_tokens=80_000,
                                  model="claude-agent-two")

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

    def write_claude_session(self, session_id, *, context_tokens, model="claude-transcript-model"):
        events = [
            {"type": "user", "sessionId": session_id,
             "message": {"role": "user", "content": "hello"}},
            {"type": "assistant", "sessionId": session_id,
             "message": {"role": "assistant", "model": model,
                         "usage": {"input_tokens": 4,
                                   "cache_read_input_tokens": context_tokens - 1004,
                                   "cache_creation_input_tokens": 1000,
                                   "output_tokens": 350}}},
        ]
        transcript = self.claude_project / f"{session_id}.jsonl"
        transcript.write_text("".join(json.dumps(event) + "\n" for event in events))

    def render(self, agent, line):
        return subprocess.run([
            "node", str(RENDERER), "--plain", "--context", str(self.context),
            "--agent", agent, "--cwd", str(self.root / agent), "--line", str(line),
        ], capture_output=True, text=True,
           env={**os.environ, "CODEX_HOME": str(self.codex_home),
                "CLAUDE_CONFIG_DIR": str(self.claude_home)},
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

    def test_compact_line_combines_quota_context_and_ticket_for_one_pane_border(self):
        first = self.render("agent-one", 0)
        second = self.render("agent-two", 0)

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(len(first.stdout.splitlines()), 1)
        self.assertIn("88%", first.stdout)
        self.assertIn("gpt-agent-one", first.stdout)
        self.assertIn("10%", first.stdout)
        self.assertIn("ECC-035", first.stdout)

        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(len(second.stdout.splitlines()), 1)
        self.assertIn("gpt-agent-two", second.stdout)
        self.assertIn("80%", second.stdout)

    def test_compact_line_stays_empty_for_panes_without_a_registered_agent(self):
        result = self.render("unknown-agent", 0)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "")

    def test_claude_agent_renders_model_and_context_from_transcript_usage(self):
        first = self.render("claude-one", 2)
        second = self.render("claude-two", 2)

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("claude-agent-one", first.stdout)
        self.assertIn("medium", first.stdout)
        self.assertIn("ctx", first.stdout)
        self.assertIn("10%", first.stdout)
        self.assertIn("200K", first.stdout)

        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("claude-agent-two", second.stdout)
        self.assertIn("40%", second.stdout)

    def test_claude_agent_has_no_quota_segments_in_full_or_compact_lines(self):
        quota = self.render("claude-one", 1)
        compact = self.render("claude-one", 0)

        self.assertEqual(quota.returncode, 0, quota.stderr)
        self.assertIn("no provider quota data", quota.stdout)
        self.assertNotIn("88%", quota.stdout)
        self.assertEqual(compact.returncode, 0, compact.stderr)
        self.assertEqual(len(compact.stdout.splitlines()), 1)
        self.assertIn("no provider quota data", compact.stdout)
        self.assertIn("claude-agent-one", compact.stdout)
        self.assertIn("10%", compact.stdout)
        self.assertIn("ECC-035", compact.stdout)
        self.assertNotIn("88%", compact.stdout)

    def test_claude_agent_without_transcript_waits_without_codex_fallback(self):
        (self.claude_project / f"{self.first_claude_session}.jsonl").unlink()
        result = self.render("claude-one", 2)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("claude-agent-one", result.stdout)
        self.assertIn("ctx waiting", result.stdout)
        self.assertNotIn("gpt-agent-one", result.stdout)


if __name__ == "__main__":
    unittest.main()
