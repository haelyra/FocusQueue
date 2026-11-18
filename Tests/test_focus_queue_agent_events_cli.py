"""Registration and open-failure logs, and start-agent's directory (FOC-142)."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid


BINARY = Path(__file__).parents[1] / ".build/debug/focus-queue-session"


@unittest.skipUnless(BINARY.is_file(), "Build focus-queue-session before CLI tests")
class AgentEventLogCLITests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fq-agent-events-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.support = self.root / "support"
        self.repository = self.root / "repository"
        self.repository.mkdir()
        self.environment = {key: value for key, value in os.environ.items()
            if not key.startswith(("FOCUS_QUEUE_", "WEZTERM_", "CODEX_", "CLAUDE_"))
            and key not in ("TMUX", "TMUX_PANE")}
        self.environment["FOCUS_QUEUE_SUPPORT_DIR"] = str(self.support)
        task = self.support / "tasks" / "ECC-501"
        task.mkdir(parents=True)
        (task / "plan.md").write_text("# ECC-501\n")
        (task / "context.json").write_text(json.dumps({
            "schemaVersion": 2, "ticketID": "ECC-501", "title": "Event log test",
            "summary": "Fixture", "successCriteria": "Logged",
            "planPath": str(task / "plan.md"), "repositoryPath": str(self.repository),
            "managedWorktree": False, "subtasks": [], "updatedAt": 0,
        }))

    def run_cli(self, *arguments, payload=None, extra_environment=None):
        return subprocess.run([str(BINARY), *arguments], cwd=self.repository,
            env={**self.environment, **(extra_environment or {})}, input=payload,
            capture_output=True, text=True, timeout=30)

    def log(self, name):
        path = self.support / "logs" / name
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines()]

    def add_agent(self):
        result = self.run_cli("add", "ECC-501", "claude", "Worker", "Does the work")
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)["id"]

    def test_hook_registration_and_attach_are_logged(self):
        session = str(uuid.uuid4())
        event = json.dumps({"session_id": session, "cwd": str(self.repository),
                            "hook_event_name": "SessionStart"})
        registered = self.run_cli("register-event", "--provider", "claude", "--task", "ECC-501",
            payload=event)
        self.assertEqual(registered.returncode, 0, registered.stderr)
        attached = self.run_cli("attach", "ECC-501",
            extra_environment={"CLAUDE_CODE_SESSION_ID": session})
        self.assertEqual(attached.returncode, 0, attached.stderr)
        entries = self.log("agent-registration.jsonl")
        self.assertEqual([entry["event"] for entry in entries], ["register-event", "attach"])
        for entry in entries:
            self.assertEqual(entry["task"], "ECC-501")
            self.assertEqual(entry["provider"], "claude")
            self.assertEqual(entry["session"], session)
            self.assertEqual(entry["outcome"], "registered")
            self.assertTrue(entry["subtask"])
            self.assertIn("time", entry)
        self.assertEqual(entries[0]["cwd"], str(self.repository))
        self.assertEqual(entries[0]["details"]["hook"], "SessionStart")

    def test_unplaced_registration_and_failed_repair_are_logged_with_reasons(self):
        event = json.dumps({"session_id": str(uuid.uuid4()), "cwd": str(self.repository),
                            "hook_event_name": "SessionStart"})
        unplaced = self.run_cli("register-event", "--provider", "claude", "--task", "NOPE-999",
            payload=event)
        self.assertEqual(unplaced.returncode, 0, unplaced.stderr)
        repair = self.run_cli("runtime", "repair", "ECC-501", "missing-agent")
        self.assertNotEqual(repair.returncode, 0)
        entries = self.log("agent-registration.jsonl")
        self.assertEqual([entry["event"] for entry in entries], ["register-event", "runtime-repair"])
        self.assertEqual(entries[0]["outcome"], "unassigned")
        self.assertIn("missing", entries[0]["reason"])
        self.assertEqual(entries[1]["outcome"], "failed")
        self.assertEqual(entries[1]["subtask"], "missing-agent")
        self.assertTrue(entries[1]["reason"])

    def test_failed_play_is_logged_and_the_alert_names_the_log(self):
        agent = self.add_agent()
        played = self.run_cli("play", "ECC-501", agent, "continue")
        self.assertNotEqual(played.returncode, 0)
        log_path = self.support / "logs" / "agent-open.jsonl"
        self.assertTrue(played.stderr.strip().endswith(f"Details: {log_path}"), played.stderr)
        entries = self.log("agent-open.jsonl")
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["source"], "play")
        self.assertEqual(entries[0]["task"], "ECC-501")
        self.assertEqual(entries[0]["subtask"], agent)
        self.assertEqual(entries[0]["step"], "play")
        self.assertTrue(entries[0]["reason"])

    def test_start_agent_refuses_without_a_recorded_workspace(self):
        agent = self.add_agent()
        started = self.run_cli("tmux", "start-agent", "ECC-501", agent, "--", "/bin/sleep", "1")
        self.assertNotEqual(started.returncode, 0)
        self.assertIn("has no recorded workspace", started.stderr)
        self.assertIn("--cwd", started.stderr)

    def test_start_agent_uses_the_recorded_workspace(self):
        agent = self.add_agent()
        missing = self.root / "gone-workspace"
        missing.mkdir()
        subprocess.run(["git", "init", "-q", str(missing)], check=True)
        subprocess.run(["git", "-C", str(missing), "-c", "user.name=t", "-c", "user.email=t@t",
                        "commit", "-q", "--allow-empty", "-m", "base"], check=True)
        assigned = self.run_cli("workspace", "ECC-501", agent, str(missing))
        self.assertEqual(assigned.returncode, 0, assigned.stderr)
        import shutil
        shutil.rmtree(missing)
        # The recorded path, not the caller's directory, is what start-agent
        # checks; a removed workspace is refused rather than replaced.
        started = self.run_cli("tmux", "start-agent", "ECC-501", agent, "--", "/bin/sleep", "1")
        self.assertNotEqual(started.returncode, 0)
        self.assertIn(f"records workspace {missing}", started.stderr)
        entries = [entry for entry in self.log("agent-registration.jsonl")
                   if entry["event"] == "workspace-assigned"]
        self.assertEqual(entries[0]["outcome"], "assigned")
        self.assertEqual(entries[0]["subtask"], agent)


if __name__ == "__main__":
    unittest.main()
