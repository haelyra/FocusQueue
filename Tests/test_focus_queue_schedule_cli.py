import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


BINARY = Path(__file__).parents[1] / ".build/debug/focus-queue-session"


@unittest.skipUnless(BINARY.is_file(), "Build focus-queue-session before CLI integration tests")
class ScheduleCLITests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fq-schedule-cli-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.dashboard = self.root / "dashboard.json"
        self.dashboard.write_text(json.dumps({"tickets": [{
            "id": "FOC-157", "title": "Native resume", "status": "open", "summary": "",
        }]}))
        config = json.loads((Path(__file__).parents[1] / "Config/config.example.json").read_text())
        config.update(dashboardPath=str(self.dashboard), workspacePath=str(self.workspace))
        (self.root / "config.json").write_text(json.dumps(config))
        task = self.root / "tasks" / "FOC-157"
        task.mkdir(parents=True)
        plan = task / "plan.md"
        plan.write_text("# FOC-157\n")
        (task / "context.json").write_text(json.dumps({
            "schemaVersion": 2,
            "ticketID": "FOC-157",
            "title": "Native resume",
            "summary": "",
            "successCriteria": "",
            "planPath": str(plan),
            "worktreePath": str(self.workspace),
            "managedWorktree": True,
            "updatedAt": 0,
            "subtasks": [{
                "id": "agent-1",
                "title": "Scheduler",
                "assignmentDescription": "Own the schedule.",
                "provider": "codex",
                "sessionID": "11111111-2222-4333-8444-555555555555",
                "status": "idle",
                "progressSummary": "Waiting.",
                "completionUnread": False,
                "includeInitializationPrompt": True,
                "runtimeMode": "tmux",
                "tmux": {
                    "name": "fq-task-foc-157",
                    "serverPID": 41,
                    "createdAt": 42,
                    "paneID": "%7",
                    "panePID": 43,
                    "tty": "/dev/ttys007",
                    "executable": "/opt/homebrew/bin/tmux",
                },
                "workspace": {
                    "path": str(self.workspace),
                    "repositoryPath": str(self.workspace),
                    "managed": True,
                },
            }],
        }))
        self.environment = {**os.environ, "FOCUS_QUEUE_SUPPORT_DIR": str(self.root)}

    def command(self, *arguments, expected=0):
        result = subprocess.run(
            [str(BINARY), "schedule", *arguments], capture_output=True, text=True,
            env=self.environment, timeout=15,
        )
        self.assertEqual(result.returncode, expected, result.stderr)
        return json.loads(result.stdout) if expected == 0 else result.stderr

    def test_add_list_and_cancel_pin_the_existing_agent_without_touching_launches(self):
        receipt = self.command(
            "add", "FOC-157", "Nightly scheduler", "Continue the existing queue.",
            "--in", "60", "--resume-agent", "agent-1", "--grace-minutes", "15",
        )
        self.assertEqual(receipt["action"], "resumeExistingAgent")
        resume = receipt["resume"]
        self.assertEqual(resume["target"]["taskID"], "FOC-157")
        self.assertEqual(resume["target"]["agentID"], "agent-1")
        self.assertEqual(resume["target"]["sessionID"], "11111111-2222-4333-8444-555555555555")
        self.assertFalse((self.root / "scheduled-launches.json").exists())
        listing = self.command("list", "FOC-157")
        self.assertEqual(listing["launches"], [])
        self.assertEqual([item["id"] for item in listing["resumes"]], [resume["id"]])
        self.assertEqual(self.command("cancel", resume["id"])["action"], "resumeExistingAgent")
        self.assertEqual(self.command("list")["resumes"], [])

    def test_parallel_adds_are_not_lost(self):
        processes = [subprocess.Popen(
            [str(BINARY), "schedule", "add", "FOC-157", f"Job {index}", f"Prompt {index}",
             "--in", "60", "--resume-agent", "agent-1", "--grace-minutes", "15"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.environment,
        ) for index in range(16)]
        results = []
        try:
            for process in processes:
                _, stderr = process.communicate(timeout=15)
                results.append((process.returncode, stderr))
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=15)
                process.stdout.close()
                process.stderr.close()
        for returncode, stderr in results:
            self.assertEqual(returncode, 0, stderr)
        listing = self.command("list")
        self.assertEqual(len(listing["resumes"]), 16)
        self.assertEqual({item["title"] for item in listing["resumes"]}, {f"Job {index}" for index in range(16)})

    def test_resume_requires_an_expiry_and_rejects_provider_or_repeat_overrides(self):
        error = self.command(
            "add", "FOC-157", "Bad", "Prompt", "--in", "60", "--resume-agent", "agent-1",
            expected=1,
        )
        self.assertIn("require exactly one", error)
        error = self.command(
            "add", "FOC-157", "Bad", "Prompt", "--in", "60", "--resume-agent", "agent-1",
            "--grace-minutes", "15", "--provider", "claude", expected=1,
        )
        self.assertIn("provider is pinned", error)


if __name__ == "__main__":
    unittest.main()
