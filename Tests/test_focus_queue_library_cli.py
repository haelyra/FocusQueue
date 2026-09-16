import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


BINARY = Path(__file__).parents[1] / ".build/debug/focus-queue-session"


@unittest.skipUnless(BINARY.is_file(), "Build focus-queue-session before CLI integration tests")
class DurableLibraryCLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fq-library-cli-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.support = self.root / "Fixture User" / "Support"
        self.task = self.support / "tasks/ECC-401"
        self.task.mkdir(parents=True)
        self.repository = self.root / "Repository with spaces"
        self.repository.mkdir()
        self.plan = self.task / "plan.md"
        self.plan.write_text("# Retained task\n\nAcceptance evidence.\n")
        context = {
            "schemaVersion": 1, "ticketID": "ECC-401", "title": "Retain a task",
            "summary": "CLI fixture", "successCriteria": "Restorable metadata",
            "planPath": str(self.plan), "repositoryPath": str(self.repository),
            "managedWorktree": False, "subtasks": [], "updatedAt": 0,
        }
        (self.task / "context.json").write_text(json.dumps(context))

    def command(self, *arguments, support=None, expected=0):
        environment = {**os.environ, "FOCUS_QUEUE_SUPPORT_DIR": str(support or self.support)}
        result = subprocess.run([str(BINARY), *arguments], env=environment,
            capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, expected, result.stderr)
        return json.loads(result.stdout) if result.stdout else result

    def test_agent_activity_and_assignment_associations(self):
        first = self.command("add", "ECC-401", "codex", "First assignment")
        second = self.command("add", "ECC-401", "codex", "Second assignment")
        self.command("progress", "ECC-401", first["id"], "working", "Started")
        context = self.command("associate", "ECC-401", first["id"], second["id"])
        record = next(item for item in context["subtasks"] if item["id"] == first["id"])
        self.assertEqual(record["associatedSubtaskIDs"], [second["id"]])
        context = self.command("attention", "ECC-401", first["id"], "approval", "Approve the change")
        record = next(item for item in context["subtasks"] if item["id"] == first["id"])
        self.assertEqual(record["attention"], "approval")
        self.assertEqual(record["status"], "idle")
        context = self.command("result", "ECC-401", first["id"], "Ready to review")
        record = next(item for item in context["subtasks"] if item["id"] == first["id"])
        self.assertTrue(record["completionUnread"])
        self.assertEqual(record["status"], "idle")
        self.assertTrue(record["resultID"])
        self.command("attention", "ECC-401", first["id"], "invalid", "Bad status", expected=1)

    def test_migrate_status_and_scoped_task_preserve_source_files(self):
        before = {path.name: path.read_bytes() for path in self.task.iterdir()}
        first = self.command("library", "migrate")
        self.assertEqual(first["storageMode"], "local")
        self.assertEqual(first["tasks"], 1)
        second = self.command("library", "migrate")
        self.assertEqual(first["revision"], second["revision"])
        status = self.command("library", "status")
        self.assertEqual(status["workspaceID"], first["workspaceID"])
        view = self.command("library", "task", "ecc-401")
        self.assertEqual(view["task"]["ticketID"], "ECC-401")
        self.assertTrue(view["documents"])
        self.assertNotIn("Acceptance evidence.", json.dumps(view))
        self.command("library", "task", "missing", expected=1)
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.task.iterdir()})

    def test_export_does_not_reimport_changed_legacy_sources_and_restore_preserves_library(self):
        original = self.command("library", "migrate")
        self.plan.write_text("# Changed since migration\n")
        exported = self.root / "Portable export"
        self.command("library", "export", str(exported))
        self.assertEqual(self.command("library", "status")["revision"], original["revision"])
        restored = self.root / "Restored support"
        self.command("library", "restore", str(exported), support=restored)
        status = self.command("library", "status", support=restored)
        self.assertEqual(status["workspaceID"], original["workspaceID"])
        self.assertNotEqual(status["deviceID"], original["deviceID"])
        self.assertFalse((restored / "tasks/ECC-401/plan.md").exists())
        self.command("library", "restore", str(exported), support=self.support, expected=1)
        self.command("library", "export", str(exported), expected=1)

    def test_explicit_architecture_generation_registers_only_local_artifacts(self):
        source = self.repository / "Sources/Example.swift"
        source.parent.mkdir()
        source.write_text("struct Example {}\n")
        cards = self.repository / "Docs/Architecture"
        cards.mkdir(parents=True)
        metadata = {"id": "example", "title": "Example component", "sources": [
            {"path": "Sources/Example.swift", "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}]}
        card = cards / "example.md"
        card.write_text("<!-- fq-architecture: " + json.dumps(metadata) + " -->\n# Example\nA fixture description.\n")
        before = card.read_bytes()
        result = self.command("architecture", "ECC-401", str(self.repository))
        self.assertEqual(int(result["cardCount"]), 1)
        self.assertTrue(Path(result["indexPath"]).is_file())
        self.assertEqual(card.read_bytes(), before)
        task = self.command("library", "task", "ECC-401")
        self.assertEqual(len([doc for doc in task["documents"] if doc["kind"] == "architecture"]), 3)

    def test_explicit_markdown_document_registration_preserves_guide_and_validates_scope(self):
        self.command("library", "migrate")
        guide = self.repository / "Setup Guide.md"
        guide.write_text("# Setup Guide\n\nKeep the original document.\n")
        before = guide.read_bytes()
        result = self.command("library", "document", "ecc-401", str(guide), "guide")
        self.assertEqual(result["status"], "registered")
        self.assertEqual(result["taskID"], "ECC-401")
        self.assertEqual(result["kind"], "guide")
        task = self.command("library", "task", "ECC-401")
        documents = [doc for doc in task["documents"] if doc["kind"] == "guide"]
        self.assertEqual(len(documents), 1)
        self.assertEqual(Path(documents[0]["sourcePath"]), guide)
        self.assertEqual(guide.read_bytes(), before)
        reference = self.repository / "Reference.MD"
        reference.write_text("# Reference\n")
        self.assertEqual(self.command("library", "document", "ECC-401", str(reference))["kind"], "reference")
        self.command("library", "document", "ECC-401", str(guide), "executable", expected=1)
        self.command("library", "document", "ECC-401", str(self.task / "context.json"), expected=1)
        self.command("library", "document", "missing", str(guide), expected=1)

    def test_architecture_requires_repository_when_task_has_no_binding(self):
        context_path = self.task / "context.json"
        context = json.loads(context_path.read_text())
        del context["repositoryPath"]
        context_path.write_text(json.dumps(context))
        failure = self.command("architecture", "ECC-401", expected=1)
        self.assertIn("explicit repository", failure.stderr)
        self.assertFalse((self.task / "architecture").exists())
        self.assertFalse((self.support / "library").exists())
        result = self.command("architecture", "ECC-401", str(self.repository))
        self.assertTrue(Path(result["indexPath"]).is_file())


if __name__ == "__main__":
    unittest.main()
