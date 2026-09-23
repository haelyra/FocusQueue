import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


BINARY = Path(__file__).parents[1] / ".build/debug/focus-queue-session"


@unittest.skipUnless(BINARY.is_file(), "Build focus-queue-session before CLI integration tests")
class ProjectCLITests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fq-project-cli-")
        self.addCleanup(temporary.cleanup)
        self.support = Path(temporary.name) / "support"
        self.source_workspace = Path(temporary.name) / "ecc"
        self.target_workspace = Path(temporary.name) / "focus-queue"
        self.support.mkdir(parents=True)
        self.source_workspace.mkdir()
        self.target_workspace.mkdir()
        self.dashboard = self.source_workspace / "dashboard.json"
        self.dashboard.write_text(json.dumps({
            "metadata": {"keep": True},
            "tickets": [
                {"id": "ECC-035", "title": "App", "status": "open", "unknown": [1, 2]},
                {"id": "ECC-044", "title": "Integrations", "status": "open"},
                {"id": "ECC-099", "title": "Other", "status": "open"},
            ],
        }))
        config = json.loads(
            (Path(__file__).parents[1] / "Config/config.example.json").read_text()
        )
        config.update(
            dashboardPath=str(self.dashboard),
            workspacePath=str(self.source_workspace),
            vendorMetadata={"keep": "exactly"},
        )
        (self.support / "config.json").write_text(json.dumps(config, indent=2))
        self.environment = {
            **os.environ,
            "FOCUS_QUEUE_SUPPORT_DIR": str(self.support),
        }

    def command(self, *arguments, expected=0):
        result = subprocess.run(
            [str(BINARY), "projects", *arguments],
            capture_output=True,
            text=True,
            env=self.environment,
            timeout=15,
        )
        self.assertEqual(result.returncode, expected, result.stderr)
        return json.loads(result.stdout) if expected == 0 else result.stderr

    def test_create_lists_and_moves_tasks_with_a_machine_readable_receipt(self):
        before = self.command("list")
        self.assertEqual([project["id"] for project in before["projects"]], ["ecc"])

        receipt = self.command(
            "create",
            "--id", "focus-queue",
            "--name", "Focus Queue",
            "--workspace", str(self.target_workspace),
            "--from", "ecc",
            "--task", "ECC-035",
            "--task", "ECC-044",
        )
        self.assertEqual(receipt["status"], "created")
        self.assertEqual(receipt["sourceProjectID"], "ecc")
        self.assertEqual(receipt["project"]["id"], "focus-queue")
        self.assertEqual(receipt["movedTaskIDs"], ["ECC-035", "ECC-044"])
        self.assertTrue(Path(receipt["backupDirectory"]).is_dir())

        listing = self.command("list")
        self.assertEqual(
            [project["id"] for project in listing["projects"]],
            ["ecc", "focus-queue"],
        )
        destination = json.loads(Path(receipt["dashboardPath"]).read_text())
        self.assertEqual([task["id"] for task in destination["tickets"]], ["ECC-035", "ECC-044"])
        self.assertEqual(destination["tickets"][0]["unknown"], [1, 2])
        self.assertEqual(
            [task["id"] for task in json.loads(self.dashboard.read_text())["tickets"]],
            ["ECC-099"],
        )
        self.assertEqual(
            json.loads((self.support / "config.json").read_text())["vendorMetadata"],
            {"keep": "exactly"},
        )

    def test_repeated_or_incomplete_creation_fails_without_further_changes(self):
        arguments = (
            "create",
            "--id", "focus-queue",
            "--name", "Focus Queue",
            "--workspace", str(self.target_workspace),
            "--from", "ecc",
            "--task", "ECC-035",
        )
        self.command(*arguments)
        snapshot = {
            path: path.read_bytes()
            for path in [self.dashboard, self.support / "config.json"]
        }
        error = self.command(*arguments, expected=1)
        self.assertIn("already exists", error)
        another_workspace = self.target_workspace.parent / "another"
        another_workspace.mkdir()
        missing = self.command(
            "create",
            "--id", "another",
            "--name", "Another",
            "--workspace", str(another_workspace),
            "--from", "ecc",
            "--task", "ECC-404",
            expected=1,
        )
        self.assertIn("ECC-404", missing)
        self.assertEqual(snapshot, {path: path.read_bytes() for path in snapshot})

    def test_recover_is_idempotent_when_no_transaction_is_pending(self):
        self.assertEqual(self.command("recover")["recoveries"], [])


if __name__ == "__main__":
    unittest.main()
