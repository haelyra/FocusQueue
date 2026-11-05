"""Headless checks for the actual Focus Queue scoped-data command."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid


REPO = Path(__file__).resolve().parents[1]
CLI = REPO / ".build/debug/focus-queue-session"


class ScopedDataCommandTests(unittest.TestCase):
    def setUp(self):
        if not CLI.exists():
            self.skipTest("build focus-queue-session first")
        self.scratch = tempfile.TemporaryDirectory(prefix="fq-scoped-data-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        config = json.loads((REPO / "Config/ecc.config.json").read_text())
        projects = []
        for project_id, prefix in (("space-site", "WEB"), ("focus-queue", "FOC")):
            dashboard = self.root / f"{project_id}.json"
            tickets = ([{"id": "WEB-001", "title": "Landing Page", "status": "backlog"},
                        {"id": "WEB-002", "title": "Demo Video", "status": "backlog"}]
                       if prefix == "WEB" else
                       [{"id": "FOC-010", "title": "Data placement", "status": "backlog"}])
            dashboard.write_text(json.dumps({"tickets": tickets}))
            projects.append({"id": project_id, "name": project_id,
                             "dashboardPath": str(dashboard),
                             "workspacePath": str(self.root / project_id),
                             "taskPrefix": prefix})
        config.update(projects=projects, dashboardPath=projects[0]["dashboardPath"],
                      workspacePath=projects[0]["workspacePath"])
        config.pop("focusQueueProjects", None)
        (self.root / "config.json").write_text(json.dumps(config))

    def run_command(self, *args):
        return subprocess.run([str(CLI), *args], text=True, capture_output=True,
                              env=dict(os.environ, FOCUS_QUEUE_SUPPORT_DIR=str(self.root)))

    def test_all_scopes_cross_project_and_idempotence(self):
        cases = [
            ("user", "user", "Always use concise output across all projects.", "user/data.md"),
            ("project", "space-site", "Use an all-gray theme with blue accents. Never use beige.",
             "projects/space-site/data.md"),
            ("task", "WEB-002", "Provide a demo video shorter than 10 seconds.",
             "tasks/WEB-002/data.md"),
        ]
        for scope, target, fact, relative in cases:
            first = self.run_command("data", "place", scope, target, fact)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertTrue(json.loads(first.stdout)["added"])
            again = self.run_command("data", "place", scope, target, fact)
            self.assertEqual(again.returncode, 0, again.stderr)
            self.assertFalse(json.loads(again.stdout)["added"])
            self.assertEqual((self.root / relative).read_text(), f"- {fact}\n")
        self.assertFalse((self.root / "tasks/WEB-001/data.md").exists())
        self.assertFalse((self.root / "projects/focus-queue/data.md").exists())

    def test_ensure_creates_empty_files_and_preserves_existing_facts(self):
        existing = self.root / "projects/space-site/data.md"
        existing.parent.mkdir(parents=True)
        existing.write_text("- Use gray with blue accents.\n")
        first = self.run_command("data", "ensure")
        self.assertEqual(first.returncode, 0, first.stderr)
        receipt = json.loads(first.stdout)
        self.assertEqual(receipt["created"], [
            str(self.root / "user/data.md"),
            str(self.root / "projects/focus-queue/data.md"),
            str(self.root / "projects/other/data.md"),
        ])
        self.assertEqual(receipt["existing"], [str(existing)])
        for relative in ("user/data.md", "projects/focus-queue/data.md",
                         "projects/other/data.md"):
            self.assertEqual((self.root / relative).read_bytes(), b"")
            self.assertEqual((self.root / relative).stat().st_mode & 0o777, 0o600)
        self.assertEqual(existing.read_text(), "- Use gray with blue accents.\n")
        second = self.run_command("data", "ensure")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(json.loads(second.stdout)["created"], [])
        append = self.run_command("data", "place", "project", "focus-queue",
                                  "Keep scoped data concise.")
        self.assertEqual(append.returncode, 0, append.stderr)
        self.assertEqual((self.root / "projects/focus-queue/data.md").read_text(),
                         "- Keep scoped data concise.\n")

    def test_show_prints_saved_facts_and_rejects_a_bad_project(self):
        empty = self.run_command("data", "show", "space-site")
        self.assertEqual((empty.returncode, empty.stdout), (0, ""))
        self.run_command("data", "place", "project", "space-site", "Use gray.")
        shown = self.run_command("data", "show", "space-site")
        self.assertIn("- Use gray.", shown.stdout)
        self.assertEqual(self.run_command("data", "show", "../outside").stdout, "")

    def test_placement_gives_a_new_project_its_data_and_the_capsule_its_paths(self):
        launch = str(uuid.uuid4())
        workspace = self.root / "space-site"
        workspace.mkdir()
        result = self.run_command("placement", "--launch", launch, "--cwd", str(workspace),
                                  "--task", "WEB-001", "--no-create")
        self.assertEqual(result.returncode, 0, result.stderr)
        capsule = json.loads(result.stdout)
        self.assertEqual(capsule["projectDataPath"], str(self.root / "projects/space-site/data.md"))
        self.assertEqual(capsule["userDataPath"], str(self.root / "user/data.md"))
        self.assertEqual(Path(capsule["projectDataPath"]).read_bytes(), b"")
        self.assertEqual(Path(capsule["userDataPath"]).read_bytes(), b"")

    def test_data_event_delivers_saved_facts_once_and_only_to_a_placed_agent(self):
        self.run_command("data", "place", "project", "space-site", "Use gray.")
        payload = json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "s-1", "prompt": "Go"})
        def event(environment):
            return subprocess.run([str(CLI), "data-event", "--provider", "claude"], text=True, input=payload,
                                  capture_output=True, env=dict(os.environ, FOCUS_QUEUE_SUPPORT_DIR=str(self.root),
                                                                **environment))
        placed = {"FOCUS_QUEUE_TASK_ID": "WEB-001", "FOCUS_QUEUE_AGENT_CONTEXT": ""}
        outside = {key: "" for key in ("FOCUS_QUEUE_TASK_ID", "FOCUS_QUEUE_AGENT_CONTEXT")}
        self.assertEqual((event(outside).returncode, event(outside).stdout), (0, ""))
        first = event(placed)
        self.assertEqual(first.returncode, 0, first.stderr)
        output = json.loads(first.stdout)["hookSpecificOutput"]
        self.assertEqual(output["hookEventName"], "UserPromptSubmit")
        self.assertIn("- Use gray.", output["additionalContext"])
        self.assertEqual(event(placed).stdout, "")

    def test_ensure_rejects_symlinked_project_directory(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.root / "projects").symlink_to(outside, target_is_directory=True)
        result = self.run_command("data", "ensure")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((outside / "focus-queue/data.md").exists())

    def test_unknown_targets_and_verbose_data_are_rejected(self):
        for scope, target, fact in [
            ("project", "missing", "Use gray."),
            ("task", "WEB-999", "Use gray."),
            ("user", "space-site", "Use gray."),
            ("project", "space-site", "First. Second. Third."),
        ]:
            result = self.run_command("data", "place", scope, target, fact)
            self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "projects/space-site/data.md").exists())

    def test_symlinked_scope_is_rejected(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.root / "projects").symlink_to(outside, target_is_directory=True)
        result = self.run_command("data", "place", "project", "space-site", "Use gray.")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((outside / "space-site/data.md").exists())


if __name__ == "__main__":
    unittest.main()
