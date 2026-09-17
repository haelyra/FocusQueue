import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BINARY = Path(__file__).parents[1] / ".build/debug/focus-queue-session"


@unittest.skipUnless(BINARY.is_file(), "Build focus-queue-session before CLI integration tests")
class QueueOrderCLITests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fq-order-cli-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.dashboard = self.root / "dashboard.json"
        self.dashboard.write_text(json.dumps({"tickets": [
            {"id": ticket, "title": ticket, "status": "open", "priority": "critical", "summary": ""}
            for ticket in ["ECC-029", "ECC-035", "ECC-040"]
        ]}))
        config = json.loads((Path(__file__).parents[1] / "Config/config.example.json").read_text())
        config.update(dashboardPath=str(self.dashboard), workspacePath=str(self.root))
        (self.root / "config.json").write_text(json.dumps(config))
        (self.root / "state.json").write_text(json.dumps({"deferredTicketIDs": ["ECC-029"]}))

    def command(self, *arguments, expected=0, project=""):
        result = subprocess.run([str(BINARY), "queue", *arguments], capture_output=True, text=True,
            env={**os.environ, "FOCUS_QUEUE_SUPPORT_DIR": str(self.root), "FOCUS_QUEUE_PROJECT_ID": project}, timeout=10)
        self.assertEqual(result.returncode, expected, result.stderr)
        return json.loads(result.stdout)["order"] if expected == 0 else result.stderr

    def test_project_commands_preserve_hidden_positions_and_reject_hidden_targets(self):
        config = json.loads((self.root / "config.json").read_text())
        config["projects"] = [{"id": "ecc", "name": "ECC", "repositoryPath": str(self.root)},
                              {"id": "focus", "name": "Focus", "repositoryPath": str(self.root)}]
        (self.root / "config.json").write_text(json.dumps(config))
        dashboard = json.loads(self.dashboard.read_text())
        for ticket in dashboard["tickets"]:
            ticket["projectID"] = "focus" if ticket["id"] == "ECC-035" else "ecc"
        self.dashboard.write_text(json.dumps(dashboard))
        self.command("move", "ECC-029", "top")
        self.assertEqual(self.command("list"), ["ECC-029", "ECC-035", "ECC-040"])
        self.assertEqual(self.command("list", project="ecc"), ["ECC-029", "ECC-040"])
        self.assertEqual(self.command("move", "ECC-040", "top", project="ecc"), ["ECC-040", "ECC-029"])
        self.assertEqual(self.command("list"), ["ECC-040", "ECC-035", "ECC-029"])
        self.command("move", "ECC-035", "top", project="ecc", expected=1)
        self.command("move", "ECC-040", "before", "ECC-035", project="ecc", expected=1)
        self.command("list", project="missing", expected=1)

    def test_moves_preserve_other_tasks_and_do_not_edit_dashboard_or_app_state(self):
        original = {name: (self.root / name).read_bytes() for name in ["dashboard.json", "state.json"]}
        self.assertEqual(self.command("list"), ["ECC-035", "ECC-040", "ECC-029"])
        self.assertEqual(self.command("move", "ecc-029", "after", "ecc-035"), ["ECC-035", "ECC-029", "ECC-040"])
        self.assertEqual(self.command("move", "ECC-040", "top"), ["ECC-040", "ECC-035", "ECC-029"])
        self.assertEqual(self.command("move", "ECC-040", "bottom"), ["ECC-035", "ECC-029", "ECC-040"])
        self.assertEqual(self.command("move", "ECC-029", "before", "ECC-035"), ["ECC-029", "ECC-035", "ECC-040"])
        self.assertEqual(self.command("list"), ["ECC-029", "ECC-035", "ECC-040"])
        self.assertEqual(original, {name: (self.root / name).read_bytes() for name in original})

    def test_invalid_commands_are_atomic_and_reset_restores_priority_order(self):
        self.command("move", "ECC-040", "top")
        before = self.command("list")
        for arguments in [("move", "missing", "top"), ("move", "ECC-029", "after", "missing"),
                          ("move", "ECC-029", "top", "extra"), ("move", "ECC-029", "before")]:
            self.command(*arguments, expected=1)
            self.assertEqual(self.command("list"), before)
        self.assertEqual(self.command("reset"), ["ECC-029", "ECC-035", "ECC-040"])

    def test_simultaneous_helpers_keep_both_moves(self):
        self.command("reset")
        env = {**os.environ, "FOCUS_QUEUE_SUPPORT_DIR": str(self.root)}
        processes = [subprocess.Popen([str(BINARY), "queue", "move", ticket, destination],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            for ticket, destination in [("ECC-040", "top"), ("ECC-029", "bottom")]]
        for process in processes:
            _, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(self.command("list"), ["ECC-040", "ECC-035", "ECC-029"])
