import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid


BINARY = Path(__file__).parents[1] / ".build/debug/focus-queue-session"


@unittest.skipUnless(BINARY.is_file(), "Build focus-queue-session before CLI tests")
class RegistrationCLITests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fq-registration-cli-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.support = self.root / "support"
        self.repository = self.root / "repository with spaces"
        self.repository.mkdir()
        self.environment = {key: value for key, value in os.environ.items()
            if not key.startswith(("FOCUS_QUEUE_", "WEZTERM_", "CODEX_", "CLAUDE_"))
            and key not in ("TMUX", "TMUX_PANE")}
        self.environment["FOCUS_QUEUE_SUPPORT_DIR"] = str(self.support)
        self.add_task("ECC-401")

    def add_task(self, task_id):
        task = self.support / "tasks" / task_id
        task.mkdir(parents=True)
        (task / "context.json").write_text(json.dumps({
            "schemaVersion": 2, "ticketID": task_id, "title": "Registration test",
            "summary": "Fixture", "successCriteria": "Exact identity",
            "planPath": str(task / "plan.md"), "repositoryPath": str(self.repository),
            "managedWorktree": False, "subtasks": [], "updatedAt": 0,
        }))

    def command(self, *arguments, payload=None, extra_environment=None, expected=0):
        result = subprocess.run([str(BINARY), *arguments], cwd=self.repository,
            env={**self.environment, **(extra_environment or {})}, input=payload,
            capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stderr)
        return json.loads(result.stdout) if result.stdout else None

    def event(self, session_id, name="SessionStart", **fields):
        return json.dumps(dict(session_id=session_id, cwd=str(self.repository),
            hook_event_name=name, **fields))

    def context(self, task_id="ECC-401"):
        return json.loads((self.support / "tasks" / task_id / "context.json").read_text())

    def test_exact_identity_repeated_events_and_stale_attach(self):
        session_id = str(uuid.uuid4())
        first = self.command("register-event", "--provider", "codex", "--task", "ECC-401",
            payload=self.event(session_id, "UserPromptSubmit", prompt="Fix pane recall"),
            extra_environment={"CODEX_THREAD_ID": str(uuid.uuid4())})
        again = self.command("register-event", "--provider", "codex",
            payload=self.event(session_id))
        self.assertEqual(first["sessionID"], session_id)
        self.assertEqual(first["subtaskID"], again["subtaskID"])
        self.assertEqual(self.context()["subtasks"][0]["title"], "Fix pane recall")
        self.assertEqual(len(self.context()["subtasks"]), 1)
        attached = self.command("attach", "ECC-401", extra_environment={
            "CODEX_THREAD_ID": str(uuid.uuid4()), "FOCUS_QUEUE_TASK_ID": "ECC-401",
            "FOCUS_QUEUE_SUBTASK_ID": "deleted-inherited-id"})
        self.assertEqual(attached["status"], "registered")
        self.assertNotEqual(attached["subtaskID"], "deleted-inherited-id")

    def test_manual_prompt_creates_a_tracked_task_until_explicitly_reassigned(self):
        self.add_task("ECC-402")
        session_id = str(uuid.uuid4())
        event = self.event(session_id, prompt="ECC-401 in text is not assignment authority")
        registered = self.command("register-event", "--provider", "codex", payload=event)
        self.assertEqual(registered["status"], "registered")
        self.assertTrue(registered["taskID"].startswith("OTH-"))
        self.assertEqual(self.context()["subtasks"], [])
        assigned = self.command("register-event", "--provider", "codex", "--task", "ECC-402", payload=event)
        self.assertEqual(assigned["taskID"], "ECC-402")

    def test_subagent_child_identity_and_invalid_input(self):
        parent, child = str(uuid.uuid4()), str(uuid.uuid4())
        self.command("register-event", "--provider", "codex", payload=self.event(parent))
        registered = self.command("register-event", "--provider", "codex",
            payload=self.event(parent, "SubagentStart", agent_id=child))
        self.assertEqual(registered["sessionID"], child)
        self.assertEqual(registered["parentSessionID"], parent)
        self.command("register-event", "--provider", "codex", payload="{malformed", expected=1)
        self.command("register-event", "--provider", "codex", payload=self.event("not-a-uuid"), expected=1)
        self.assertEqual(len(self.context()["subtasks"]), 2)

    def test_placement_cli_creates_other_task_and_private_capsule(self):
        dashboard = self.support / "dashboard.json"
        dashboard.write_text('{"tickets":[]}\n')
        config = json.loads((Path(__file__).parents[1] / "Config/config.example.json").read_text())
        config["dashboardPath"] = str(dashboard)
        config["workspacePath"] = str(self.repository)
        config["focusQueueProjects"] = [{
            "id":"other", "name":"Other", "taskPrefix":"OTH",
            "dashboardPath":str(dashboard), "workspacePath":str(self.repository),
            "repositoryPath":"", "remoteAliases":[],
        }]
        config["focusQueueSelectedProjectID"] = "other"
        config["wezTerm"]["executable"] = "/missing/wezterm"
        config["verifier"]["executable"] = "/missing/codex"
        self.support.mkdir(parents=True, exist_ok=True)
        (self.support / "config.json").write_text(json.dumps(config))
        launch_id = str(uuid.uuid4())
        result = self.command("placement", "--launch", launch_id,
            "--cwd", str(self.repository), "--prompt", "Review a miscellaneous note")
        self.assertEqual(result["status"], "placed")
        self.assertEqual(result["projectID"], "other")
        self.assertEqual(result["taskID"], "OTH-001")
        capsule = Path(result["capsulePath"])
        self.assertEqual(capsule.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(capsule.read_text())["launchID"], launch_id)
        self.assertEqual(json.loads(dashboard.read_text())["tickets"][0]["projectID"], "other")


if __name__ == "__main__":
    unittest.main()
