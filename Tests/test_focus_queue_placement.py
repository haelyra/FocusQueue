import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "Scripts" / "focus_queue_placement.py"


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PLACEMENT = load("focus_queue_placement", "focus_queue_placement.py")


class PlacementFixture:
    def __init__(self, root, *, repository=None, tickets=("ECC-214",), prefixes=("ECC", "WEB")):
        self.support = root / "support"
        self.support.mkdir()
        self.config_path = root / "config.json"
        self.ledger = root / "ledger.sqlite"
        projects = []
        if repository is not None:
            projects.append({"id": "ecc", "name": "ECC", "taskPrefix": "ECC",
                             "repositoryPath": str(repository)})
        for prefix in prefixes:
            if any(project.get("taskPrefix") == prefix for project in projects):
                continue
            projects.append({"id": prefix.lower(), "name": prefix, "taskPrefix": prefix,
                             "repositoryPath": ""})
        self.config = {"focusQueueProjects": projects}
        self.config_path.write_text(json.dumps(self.config))
        for ticket in tickets:
            (self.support / "tasks" / ticket).mkdir(parents=True)

    @property
    def environment(self):
        return {"FOCUS_QUEUE_SUPPORT_DIR": str(self.support),
                "FOCUS_QUEUE_PLACEMENT_CONFIG": str(self.config_path),
                "FOCUS_QUEUE_PLACEMENT_LEDGER": str(self.ledger)}

    def classify(self, **kwargs):
        kwargs.setdefault("environment", self.environment)
        return PLACEMENT.classify(**kwargs)


def git_init(path):
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/git", "init", "-q", "-b", "main"], cwd=path,
                   check=True, capture_output=True)


class PlacementTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="placement test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_explicit_task_wins_with_full_confidence(self):
        fixture = PlacementFixture(self.root)
        result = fixture.classify(prompt="unrelated", cwd=str(self.root), task_id="ecc-123")
        self.assertEqual(result["status"], "task")
        self.assertEqual(result["taskID"], "ECC-123")
        self.assertEqual(result["projectID"], "ecc")
        self.assertEqual(result["confidence"], 1.0)
        self.assertEqual(result["rationale"], "explicit")
        self.assertEqual(result["backend"], "heuristic")
        self.assertGreaterEqual(result["latencyMs"], 0)

    def test_invalid_explicit_task_exits_two(self):
        fixture = PlacementFixture(self.root)
        with self.assertRaises(PLACEMENT.PlacementError):
            fixture.classify(task_id="not a ticket")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "classify", "--task", "not a ticket"],
            capture_output=True, text=True, env={**os.environ, **fixture.environment})
        self.assertEqual(result.returncode, 2)
        self.assertIn("Invalid task ID", result.stderr)

    def test_prompt_ticket_existing_in_task_state(self):
        fixture = PlacementFixture(self.root)
        result = fixture.classify(prompt="Fix ecc-214 label truncation", cwd=str(self.root))
        self.assertEqual(result["status"], "task")
        self.assertEqual(result["taskID"], "ECC-214")
        self.assertEqual(result["projectID"], "ecc")
        self.assertEqual(result["confidence"], 0.95)
        self.assertEqual(result["rationale"], "prompt-ticket")

    def test_prompt_ticket_existing_only_in_dashboard(self):
        fixture = PlacementFixture(self.root, tickets=())
        dashboard = self.root / "dashboard.json"
        dashboard.write_text(json.dumps({"tickets": [{"id": "WEB-007", "title": "x"}]}))
        config = json.loads(fixture.config_path.read_text())
        for project in config["focusQueueProjects"]:
            if project["taskPrefix"] == "WEB":
                project["dashboardPath"] = str(dashboard)
        fixture.config_path.write_text(json.dumps(config))
        result = fixture.classify(prompt="pick up web-007 next", cwd=str(self.root))
        self.assertEqual(result["status"], "task")
        self.assertEqual(result["taskID"], "WEB-007")
        self.assertEqual(result["projectID"], "web")

    def test_unknown_prompt_ticket_falls_through(self):
        fixture = PlacementFixture(self.root)
        result = fixture.classify(prompt="work on ECC-999 someday", cwd=str(self.root))
        self.assertEqual(result["status"], "inbox")
        self.assertEqual(result["rationale"], "no-signal")
        self.assertEqual(result["confidence"], 0.1)

    def test_cwd_inside_configured_repository(self):
        repository = self.root / "checkout"
        git_init(repository)
        fixture = PlacementFixture(self.root, repository=repository)
        (repository / "sub").mkdir()
        result = fixture.classify(prompt="explore the code", cwd=str(repository / "sub"))
        self.assertEqual(result["status"], "project-inbox")
        self.assertEqual(result["projectID"], "ecc")
        self.assertEqual(result["confidence"], 0.6)
        self.assertEqual(result["rationale"], "cwd-project")
        self.assertNotIn("taskID", result)

    def test_cwd_git_top_level_matches_repository(self):
        repository = self.root / "checkout"
        git_init(repository)
        fixture = PlacementFixture(self.root, repository=repository)
        result = fixture.classify(prompt=None, cwd=str(repository))
        self.assertEqual(result["status"], "project-inbox")
        self.assertEqual(result["rationale"], "cwd-project")

    def test_unmapped_git_repo_goes_to_inbox(self):
        elsewhere = self.root / "elsewhere"
        git_init(elsewhere)
        fixture = PlacementFixture(self.root)
        result = fixture.classify(prompt="hello", cwd=str(elsewhere))
        self.assertEqual(result["status"], "inbox")
        self.assertEqual(result["confidence"], 0.2)
        self.assertEqual(result["rationale"], "unmapped-repo")

    def test_no_signal_inbox(self):
        fixture = PlacementFixture(self.root)
        result = fixture.classify(prompt="hello", cwd=str(self.root))
        self.assertEqual(result["status"], "inbox")
        self.assertEqual(result["confidence"], 0.1)
        self.assertEqual(result["rationale"], "no-signal")

    def test_cli_json_output_shape(self):
        fixture = PlacementFixture(self.root)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "classify", "--prompt", "fix ECC-214",
             "--cwd", str(self.root), "--json"],
            capture_output=True, text=True, env={**os.environ, **fixture.environment})
        self.assertEqual(result.returncode, 0, result.stderr)
        parsed = json.loads(result.stdout)
        self.assertEqual(parsed["status"], "task")
        self.assertEqual(parsed["taskID"], "ECC-214")
        self.assertEqual(parsed["projectID"], "ecc")
        self.assertEqual(parsed["confidence"], 0.95)
        self.assertEqual(parsed["rationale"], "prompt-ticket")
        self.assertEqual(parsed["backend"], "heuristic")
        self.assertIsInstance(parsed["latencyMs"], (int, float))

    def test_ledger_row_written(self):
        fixture = PlacementFixture(self.root)
        fixture.classify(prompt="x" * 250 + " ECC-214", cwd=str(self.root))
        connection = sqlite3.connect(str(fixture.ledger))
        try:
            rows = connection.execute(
                "SELECT timestamp, backend, status, task_id, project_id, confidence,"
                " rationale, prompt_excerpt, cwd, latency_ms FROM placements").fetchall()
        finally:
            connection.close()
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row[1], "heuristic")
        self.assertEqual(row[2], "task")
        self.assertEqual(row[3], "ECC-214")
        self.assertEqual(row[4], "ecc")
        self.assertEqual(row[5], 0.95)
        self.assertEqual(row[6], "prompt-ticket")
        self.assertEqual(len(row[7]), 200)
        self.assertEqual(row[8], str(self.root.resolve()))
        self.assertGreaterEqual(row[9], 0)

    def test_ledger_failure_never_blocks_classification(self):
        fixture = PlacementFixture(self.root)
        blocked = self.root / "blocked"
        blocked.mkdir()  # a directory cannot be opened as a SQLite database
        environment = {**fixture.environment, "FOCUS_QUEUE_PLACEMENT_LEDGER": str(blocked)}
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "classify", "--prompt", "fix ECC-214",
             "--cwd", str(self.root), "--json"],
            capture_output=True, text=True, env={**os.environ, **environment})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["taskID"], "ECC-214")
        self.assertIn("ledger write failed", result.stderr)

    def test_missing_config_and_state_never_crash(self):
        fixture = PlacementFixture(self.root)
        fixture.config_path.unlink()
        environment = {"FOCUS_QUEUE_SUPPORT_DIR": str(self.root / "absent"),
                       "FOCUS_QUEUE_PLACEMENT_CONFIG": str(self.root / "absent.json"),
                       "FOCUS_QUEUE_PLACEMENT_LEDGER": str(fixture.ledger)}
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "classify", "--prompt", "fix ECC-214",
             "--cwd", str(self.root), "--json"],
            capture_output=True, text=True, env={**os.environ, **environment})
        self.assertEqual(result.returncode, 0, result.stderr)
        parsed = json.loads(result.stdout)
        self.assertEqual(parsed["status"], "inbox")
        self.assertEqual(parsed["rationale"], "no-signal")


if __name__ == "__main__":
    unittest.main()
