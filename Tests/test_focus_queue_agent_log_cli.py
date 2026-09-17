import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


BINARY = Path(__file__).parents[1] / ".build/debug/focus-queue-session"


@unittest.skipUnless(BINARY.is_file(), "Build focus-queue-session before CLI tests")
class AgentLogCLITests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fq-agent-log-cli-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.task = self.root / "tasks/DOC-1"
        self.task.mkdir(parents=True)
        self.plan = self.task / "plan.md"
        self.plan.write_text("# Shared short plan\n")
        self.context = self.task / "context.json"
        self.context.write_text(json.dumps({
            "schemaVersion": 2, "ticketID": "DOC-1", "title": "Log sanity",
            "summary": "", "successCriteria": "Preserved evidence",
            "planPath": str(self.plan), "managedWorktree": False,
            "subtasks": [{"id": "agent", "title": "Log test", "provider": "codex", "status": "working"}],
            "updatedAt": 0,
        }))
        self.environment = {**os.environ, "FOCUS_QUEUE_SUPPORT_DIR": str(self.root)}

    def test_concurrent_processes_append_once_and_preserve_plan_and_state(self):
        before = self.context.read_bytes(), self.plan.read_bytes()
        entries = [f'Entry {number}: literal $(echo no) `echo no`; "quotes"\nEvidence.' for number in range(16)]
        processes = [subprocess.Popen([str(BINARY), "log", "DOC-1", "agent", entry],
            env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for entry in entries]
        for process in processes:
            stdout, stderr = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(json.loads(stdout), {"appended": True})
        log = (self.task / "agent-log.md").read_text()
        for entry in entries:
            self.assertEqual(log.count(entry), 1)
        self.assertEqual((self.context.read_bytes(), self.plan.read_bytes()), before)

    def test_invalid_requests_do_not_create_log_or_change_state(self):
        before = self.context.read_bytes(), self.plan.read_bytes()
        for arguments in [("DOC-1", "missing", "entry"), ("DOC-1", "agent", "   "), ("../DOC-1", "agent", "entry")]:
            result = subprocess.run([str(BINARY), "log", *arguments], env=self.environment,
                capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertTrue(result.stderr.strip())
        self.assertFalse((self.task / "agent-log.md").exists())
        self.assertEqual((self.context.read_bytes(), self.plan.read_bytes()), before)


if __name__ == "__main__":
    unittest.main()
