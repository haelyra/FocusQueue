import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import time

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
        (self.root / "state.json").write_text(json.dumps({
            "deferredTicketIDs": ["ECC-029"], "showsAllProjects": False}))

    def command(self, *arguments, expected=0, project=""):
        result = subprocess.run([str(BINARY), "queue", *arguments], capture_output=True, text=True,
            env={**os.environ, "FOCUS_QUEUE_SUPPORT_DIR": str(self.root), "FOCUS_QUEUE_PROJECT_ID": project}, timeout=10)
        self.assertEqual(result.returncode, expected, result.stderr)
        return json.loads(result.stdout)["order"] if expected == 0 else result.stderr

    def task_status(self, ticket, status):
        result = subprocess.run([str(BINARY), "task", "status", ticket, status],
            capture_output=True, text=True,
            env={**os.environ, "FOCUS_QUEUE_SUPPORT_DIR": str(self.root)}, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def set_recent_activity(self):
        state_path = self.root / "state.json"
        state = json.loads(state_path.read_text())
        state["queueSortMode"] = "recentActivity"
        state_path.write_text(json.dumps(state))
        now = time.time() - 978307200
        for ticket, age in [("ECC-029", 60), ("ECC-040", 3600), ("ECC-035", 3 * 86400 + 1)]:
            task = self.root / "tasks" / ticket
            task.mkdir(parents=True, exist_ok=True)
            plan = task / "plan.md"
            plan.write_text(f"# {ticket}\n")
            (task / "context.json").write_text(json.dumps({
                "schemaVersion": 2, "ticketID": ticket, "title": ticket,
                "summary": "", "successCriteria": "", "planPath": str(plan),
                "managedWorktree": False, "subtasks": [], "updatedAt": now,
                "lastPromptAt": now - age,
            }))

    def test_project_commands_require_the_active_dashboard_and_keep_orders_isolated(self):
        config = json.loads((self.root / "config.json").read_text())
        focus_dashboard = self.root / "focus-dashboard.json"
        focus_dashboard.write_text(json.dumps({"tickets": [
            {"id": ticket, "title": ticket, "status": "open", "priority": "critical", "summary": ""}
            for ticket in ["FOC-001", "FOC-002"]
        ]}))
        config["focusQueueProjects"] = [
            {"id": "ecc", "name": "ECC", "taskPrefix": "ECC",
             "dashboardPath": str(self.dashboard), "workspacePath": str(self.root),
             "repositoryPath": ""},
            {"id": "focus", "name": "Focus", "taskPrefix": "FOC",
             "dashboardPath": str(focus_dashboard), "workspacePath": str(self.root),
             "repositoryPath": ""},
        ]
        config["focusQueueSelectedProjectID"] = "ecc"
        dashboard = json.loads(self.dashboard.read_text())
        for ticket in dashboard["tickets"]:
            ticket["projectID"] = "ecc"
        self.dashboard.write_text(json.dumps(dashboard))
        (self.root / "config.json").write_text(json.dumps(config))
        self.assertEqual(self.command("move", "ECC-029", "top", project="ecc"),
                         ["ECC-029", "ECC-035", "ECC-040"])
        self.command("list", project="focus", expected=1)
        self.command("list", project="missing", expected=1)
        config["focusQueueSelectedProjectID"] = "focus"
        (self.root / "config.json").write_text(json.dumps(config))
        self.assertEqual(self.command("list", project="focus"), ["FOC-001", "FOC-002"])
        self.assertEqual(self.command("move", "FOC-002", "top", project="focus"),
                         ["FOC-002", "FOC-001"])
        self.command("list", project="ecc", expected=1)

    def test_moves_preserve_other_tasks_and_keep_recent_order_selected(self):
        original_dashboard = self.dashboard.read_bytes()
        self.assertEqual(self.command("list"), ["ECC-035", "ECC-040", "ECC-029"])
        self.assertEqual(self.command("move", "ecc-029", "after", "ecc-035"), ["ECC-035", "ECC-029", "ECC-040"])
        self.assertEqual(self.command("move", "ECC-040", "top"), ["ECC-040", "ECC-035", "ECC-029"])
        self.assertEqual(self.command("move", "ECC-040", "bottom"), ["ECC-035", "ECC-029", "ECC-040"])
        self.assertEqual(self.command("move", "ECC-029", "before", "ECC-035"), ["ECC-029", "ECC-035", "ECC-040"])
        self.assertEqual(self.command("list"), ["ECC-029", "ECC-035", "ECC-040"])
        self.assertEqual(self.dashboard.read_bytes(), original_dashboard)
        state = json.loads((self.root / "state.json").read_text())
        self.assertEqual(state.get("queueSortMode", "recentActivity"), "recentActivity")

    def test_invalid_commands_are_atomic_and_reset_restores_automatic_order(self):
        self.command("move", "ECC-040", "top")
        before = self.command("list")
        for arguments in [("move", "missing", "top"), ("move", "ECC-029", "after", "missing"),
                          ("move", "ECC-029", "top", "extra"), ("move", "ECC-029", "before")]:
            self.command(*arguments, expected=1)
            self.assertEqual(self.command("list"), before)
        self.assertEqual(self.command("reset"), ["ECC-035", "ECC-040", "ECC-029"])

    def test_manual_moves_override_recent_agent_prompts(self):
        self.assertEqual(self.command("move", "ECC-035", "top"),
                         ["ECC-035", "ECC-040", "ECC-029"])
        self.set_recent_activity()

        self.assertEqual(self.command("list"), ["ECC-029", "ECC-040", "ECC-035"])

    def test_move_from_recent_mode_is_temporary_and_reset_restores_recency(self):
        self.command("reorder", "ECC-035", "ECC-029", "ECC-040")
        self.set_recent_activity()
        self.assertEqual(self.command("list"), ["ECC-029", "ECC-040", "ECC-035"])

        self.assertEqual(self.command("move", "ECC-040", "after", "ECC-035"),
                         ["ECC-029", "ECC-035", "ECC-040"])
        state = json.loads((self.root / "state.json").read_text())
        self.assertEqual(state["queueSortMode"], "recentActivity")
        self.assertEqual(self.command("reset"), ["ECC-029", "ECC-040", "ECC-035"])

    def test_partial_reorder_appends_omitted_tasks_in_displayed_relative_order(self):
        self.command("reorder", "ECC-035", "ECC-040", "ECC-029")
        self.set_recent_activity()
        self.assertEqual(self.command("list"), ["ECC-029", "ECC-040", "ECC-035"])

        self.assertEqual(self.command("reorder", "ECC-035"),
                         ["ECC-035", "ECC-029", "ECC-040"])

    def test_pin_and_unpin_create_a_newest_first_top_tier(self):
        self.assertEqual(self.command("pin", "ECC-029"),
                         ["ECC-029", "ECC-035", "ECC-040"])
        time.sleep(0.01)
        self.assertEqual(self.command("pin", "ECC-040"),
                         ["ECC-040", "ECC-029", "ECC-035"])
        context = json.loads((self.root / "tasks" / "ECC-040" / "context.json").read_text())
        self.assertIsNotNone(context["pinnedAt"])
        self.assertEqual(self.command("unpin", "ECC-040"),
                         ["ECC-029", "ECC-035", "ECC-040"])
        context = json.loads((self.root / "tasks" / "ECC-040" / "context.json").read_text())
        self.assertNotIn("pinnedAt", context)

    def test_moves_cannot_displace_or_reorder_the_pinned_tier(self):
        self.assertEqual(self.command("pin", "ECC-029"),
                         ["ECC-029", "ECC-035", "ECC-040"])
        time.sleep(0.01)
        self.assertEqual(self.command("pin", "ECC-035"),
                         ["ECC-035", "ECC-029", "ECC-040"])
        self.assertEqual(self.command("move", "ECC-040", "top"),
                         ["ECC-035", "ECC-029", "ECC-040"])
        self.assertEqual(self.command("move", "ECC-029", "top"),
                         ["ECC-035", "ECC-029", "ECC-040"])

    def test_task_status_closure_clears_pin_and_reopen_does_not_restore_it(self):
        for ticket, closed_status in [("ECC-029", "resolved"), ("ECC-035", "cancelled")]:
            self.command("pin", ticket)
            context_path = self.root / "tasks" / ticket / "context.json"
            self.assertIsNotNone(json.loads(context_path.read_text())["pinnedAt"])

            self.task_status(ticket, closed_status)
            context = json.loads(context_path.read_text())
            self.assertNotIn("pinnedAt", context)

            self.task_status(ticket, "backlog")
            context = json.loads(context_path.read_text())
            self.assertNotIn("pinnedAt", context)

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
