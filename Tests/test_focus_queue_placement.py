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

    def test_cli_without_provider_never_calls_a_model(self):
        fixture = PlacementFixture(self.root)
        environment = {**os.environ, **fixture.environment,
                       "FOCUS_QUEUE_PLACEMENT_CLAUDE_EXECUTABLE": str(self.root / "absent-cli")}
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "classify", "--prompt", "hello", "--cwd", str(self.root),
             "--json"], capture_output=True, text=True, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        parsed = json.loads(result.stdout)
        self.assertEqual(parsed["backend"], "heuristic")
        self.assertNotIn("modelError", parsed)

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


def claude_reply(task_id, confidence, title="Fix tmux clipboard sync", reason="Same bug."):
    return json.dumps({"type": "result", "is_error": False, "result": "", "structured_output": {
        "taskID": task_id, "confidence": confidence, "title": title, "reason": reason}})


def fake_cli(path, stdout, *, log=None, exit_code=0, sleep=0):
    """An executable stand-in for a provider CLI: logs argv and stdin, then replies."""
    path.write_text(
        f"#!{sys.executable}\n"
        "import json, sys, time\n"
        f"time.sleep({sleep})\n"
        f"log = {str(log) if log else None!r}\n"
        "if log:\n"
        "    stdin = '' if sys.stdin is None or sys.stdin.isatty() else sys.stdin.read()\n"
        "    open(log, 'w').write(json.dumps({'argv': sys.argv[1:], 'stdin': stdin}))\n"
        f"sys.stdout.write({stdout!r})\n"
        f"sys.exit({exit_code})\n")
    path.chmod(0o755)
    return path


class ModelPlacementTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="placement model test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repository = self.root / "checkout"
        git_init(self.repository)
        self.fixture = PlacementFixture(self.root, repository=self.repository, tickets=(),
                                        prefixes=("ECC", "OTH", "WEB"))
        self.write_dashboard("ecc", [
            {"id": "ECC-018", "title": "Fix tmux and WezTerm clipboard sync", "status": "in-progress",
             "summary": "Copies in tmux do not reach the system clipboard.", "updatedAt": "2026-10-10"},
            {"id": "ECC-001", "title": "Explain the folder", "status": "resolved", "updatedAt": "2026-10-18"},
        ])
        self.write_dashboard("oth", [{"id": "OTH-004", "title": "Steward PRs", "status": "backlog",
                                      "updatedAt": "2026-10-19"}])
        self.write_dashboard("web", [{"id": "WEB-002", "title": "Landing page", "status": "backlog"}])
        config = json.loads(self.fixture.config_path.read_text())
        for project in config["focusQueueProjects"]:
            if project["id"] == "web":
                project["repositoryPath"] = str(self.root / "web-repo")
        self.fixture.config_path.write_text(json.dumps(config))
        self.calls = []

    def write_dashboard(self, project_id, tickets):
        path = self.root / f"{project_id}-dashboard.json"
        path.write_text(json.dumps({"tickets": tickets}))
        config = json.loads(self.fixture.config_path.read_text())
        for project in config["focusQueueProjects"]:
            if project["id"] == project_id:
                project["dashboardPath"] = str(path)
        self.fixture.config_path.write_text(json.dumps(config))

    def configure(self, **values):
        config = json.loads(self.fixture.config_path.read_text())
        config.update(values)
        self.fixture.config_path.write_text(json.dumps(config))

    def runner(self, stdout):
        def run(command, stdin, cwd, environment, timeout):
            self.calls.append({"command": command, "stdin": stdin, "cwd": cwd,
                               "environment": environment, "timeout": timeout})
            if callable(stdout):
                return stdout(command, cwd)
            return stdout
        return run

    def classify(self, prompt, *, provider="claude", stdout=None, environment=None, cwd=None):
        environment = {**self.fixture.environment,
                       "FOCUS_QUEUE_PLACEMENT_CLAUDE_EXECUTABLE": "/fake/claude",
                       "FOCUS_QUEUE_PLACEMENT_CODEX_EXECUTABLE": "/fake/codex",
                       "FOCUS_QUEUE_PLACEMENT_KIMI_EXECUTABLE": "/fake/kimi",
                       **(environment or {})}
        return PLACEMENT.classify(prompt=prompt, cwd=cwd or str(self.repository),
                                  environment=environment, provider=provider,
                                  runner=self.runner(stdout) if stdout is not None else None)

    def test_confident_match_joins_the_listed_task(self):
        result = self.classify("tmux copy stopped syncing again", stdout=claude_reply("ecc-018", 0.9),
                               environment={"CLAUDE_CODE_SESSION_ID": "parent", "FOCUS_QUEUE_TASK_ID": "X-1"})
        self.assertEqual(result["status"], "task")
        self.assertEqual(result["taskID"], "ECC-018")
        self.assertEqual(result["projectID"], "ecc")
        self.assertEqual(result["rationale"], "model-match")
        self.assertEqual(result["backend"], "model")
        self.assertEqual(result["model"], "claude/haiku")
        self.assertEqual(result["confidence"], 0.9)
        call = self.calls[0]
        command = call["command"]
        self.assertEqual(command[:4], ["/fake/claude", "-p", "--model", "haiku"])
        self.assertEqual(command[command.index("--effort") + 1], "low")
        self.assertEqual(command[command.index("--tools") + 1], "")
        self.assertEqual(command[command.index("--setting-sources") + 1], "")
        self.assertIn("--no-session-persistence", command)
        self.assertEqual(json.loads(command[command.index("--json-schema") + 1]),
                         PLACEMENT.RESPONSE_SCHEMA)
        self.assertIn("ECC-018 | in-progress | Fix tmux and WezTerm clipboard sync", call["stdin"])
        self.assertIn("tmux copy stopped syncing again", call["stdin"])
        self.assertNotIn("ECC-001", call["stdin"], "Resolved tasks are not candidates")
        self.assertNotIn("CLAUDE_CODE_SESSION_ID", call["environment"])
        self.assertFalse(any(key.startswith("FOCUS_QUEUE_") for key in call["environment"]))
        self.assertEqual(call["timeout"], PLACEMENT.DEFAULT_TIMEOUT_SECONDS)

    def test_candidates_are_the_launch_project_then_repositoryless_projects(self):
        self.classify("anything", stdout=claude_reply(None, 0))
        lines = [line for line in self.calls[0]["stdin"].splitlines()
                 if PLACEMENT.TICKET_SHAPE.match(line.split(" | ")[0])]
        self.assertEqual([line.split(" | ")[0] for line in lines], ["ECC-018", "OTH-004"])
        self.assertNotIn("WEB-002", self.calls[0]["stdin"], "Another repository's tasks would block launch")

    def test_low_confidence_match_creates_a_titled_task_instead(self):
        result = self.classify("maybe the clipboard thing", stdout=claude_reply("ECC-018", 0.4))
        self.assertEqual(result["status"], "new-task")
        self.assertEqual(result["rationale"], "model-new")
        self.assertEqual(result["projectID"], "ecc")
        self.assertEqual(result["nearestTaskID"], "ECC-018")
        self.assertEqual(result["title"], "Fix tmux clipboard sync")
        self.assertNotIn("taskID", result)

    def test_new_work_outside_any_project_lands_in_other(self):
        outside = self.root / "outside"
        outside.mkdir()
        result = self.classify("write a haiku", cwd=str(outside),
                               stdout=claude_reply(None, 0, title='  "Write a   haiku"  '))
        self.assertEqual(result["status"], "new-task")
        self.assertEqual(result["projectID"], "other")
        self.assertEqual(result["title"], "Write a haiku")
        self.assertNotIn("nearestTaskID", result)

    def test_invalid_replies_fall_back_to_heuristics(self):
        cases = {
            "unlisted": claude_reply("ECC-999", 0.9),
            "closed": claude_reply("ECC-001", 0.9),
            "no title": claude_reply(None, 0, title="  "),
            "not json": "Sorry, I cannot help with that.",
            "error": json.dumps({"is_error": True, "result": "quota"}),
            "confidence": json.dumps({"structured_output": {
                "taskID": None, "confidence": "high", "title": "x", "reason": ""}}),
        }
        for label, stdout in cases.items():
            with self.subTest(label):
                result = self.classify("tmux copy broke", stdout=stdout)
                self.assertEqual(result["status"], "project-inbox")
                self.assertEqual(result["rationale"], "cwd-project")
                self.assertEqual(result["backend"], "heuristic")
                self.assertTrue(result["modelError"])

    def test_explicit_or_prompt_tickets_never_call_the_model(self):
        (self.fixture.support / "tasks" / "ECC-018").mkdir(parents=True)
        self.assertEqual(self.classify("fix ECC-018", stdout=claude_reply(None, 0))["rationale"],
                         "prompt-ticket")
        self.assertEqual(PLACEMENT.classify(prompt="x", task_id="ECC-5", cwd=str(self.repository),
                                            environment=self.fixture.environment, provider="claude",
                                            runner=self.runner(""))["rationale"], "explicit")
        self.assertEqual(self.calls, [])

    def test_disabled_backend_missing_provider_or_prompt_skip_the_model(self):
        self.assertEqual(self.classify("hello", provider=None, stdout="")["backend"], "heuristic")
        self.assertEqual(self.classify(None, stdout="")["backend"], "heuristic")
        self.configure(placementModelEnabled=False)
        result = self.classify("hello", stdout="")
        self.assertEqual(result["backend"], "heuristic")
        self.assertNotIn("modelError", result)
        self.assertEqual(self.calls, [])

    def test_configured_codex_model_and_effort(self):
        self.configure(placementModels={"codex": "gpt-5.6-luna"}, placementEfforts={"codex": "medium"},
                       placementTimeoutSeconds=9)

        def answer(command, cwd):
            Path(command[command.index("-o") + 1]).write_text(json.dumps(
                {"taskID": "ECC-018", "confidence": 0.9, "title": "Clipboard", "reason": "r"}))
            return "noise"

        result = self.classify("tmux copy broke", provider="codex", stdout=answer)
        self.assertEqual(result["taskID"], "ECC-018")
        self.assertEqual(result["model"], "codex/gpt-5.6-luna")
        call = self.calls[0]
        command = call["command"]
        self.assertEqual(command[:4], ["/fake/codex", "exec", "-m", "gpt-5.6-luna"])
        self.assertIn("model_reasoning_effort=medium", command)
        for flag in ("--ephemeral", "--ignore-user-config", "--skip-git-repo-check"):
            self.assertIn(flag, command)
        self.assertEqual(command[command.index("--sandbox") + 1], "read-only")
        self.assertEqual(command[-1], "-")
        self.assertIn("tmux copy broke", call["stdin"])
        self.assertEqual(call["timeout"], 9)

    def test_provider_override_runs_kimi_and_parses_prose(self):
        self.configure(placementProvider="kimi", placementEfforts={"kimi": "high"})
        prose = ('• Thinking about {"taskID": "ECC-001"} first.\n'
                 '• {"taskID": "ECC-018", "confidence": 0.95, "title": "Clipboard sync", "reason": "x"}\n')
        result = self.classify("tmux copy broke", provider="claude", stdout=prose)
        self.assertEqual(result["taskID"], "ECC-018")
        self.assertEqual(result["model"], "kimi/kimi-code/kimi-for-coding-highspeed")
        command = self.calls[0]["command"]
        self.assertEqual(command[:4], ["/fake/kimi", "-m", "kimi-code/kimi-for-coding-highspeed", "-p"])
        self.assertIn("tmux copy broke", command[4])
        self.assertIsNone(self.calls[0]["stdin"])
        self.assertNotIn("high", command, "Kimi has no effort flag")

    def test_real_subprocess_reply_timeout_and_failure(self):
        log = self.root / "cli.json"
        executable = fake_cli(self.root / "claude", claude_reply("ECC-018", 0.95), log=log)
        environment = {"FOCUS_QUEUE_PLACEMENT_CLAUDE_EXECUTABLE": str(executable)}
        result = self.classify("tmux copy broke", environment=environment)
        self.assertEqual(result["taskID"], "ECC-018")
        recorded = json.loads(log.read_text())
        self.assertIn("tmux copy broke", recorded["stdin"])
        self.assertEqual(recorded["argv"][:3], ["-p", "--model", "haiku"])

        fake_cli(self.root / "claude", claude_reply("ECC-018", 0.95), exit_code=3)
        failed = self.classify("tmux copy broke", environment=environment)
        self.assertIn("exited 3", failed["modelError"])

        self.configure(placementTimeoutSeconds=1)
        fake_cli(self.root / "claude", claude_reply("ECC-018", 0.95), sleep=5)
        timed_out = self.classify("tmux copy broke", environment=environment)
        self.assertIn("timed out after 1s", timed_out["modelError"])
        self.assertLess(timed_out["latencyMs"], 4000)

        missing = self.classify("tmux copy broke", environment={
            "FOCUS_QUEUE_PLACEMENT_CLAUDE_EXECUTABLE": "", "PATH": str(self.root / "empty")})
        self.assertIn("not on PATH", missing["modelError"])

    def test_cli_provider_flag_uses_the_model(self):
        executable = fake_cli(self.root / "claude", claude_reply(None, 0, title="Brand new work"))
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "classify", "--provider", "claude", "--prompt", "new idea",
             "--cwd", str(self.repository)],
            capture_output=True, text=True,
            env={**os.environ, **self.fixture.environment,
                 "FOCUS_QUEUE_PLACEMENT_CLAUDE_EXECUTABLE": str(executable)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(),
                         "new-task: ecc “Brand new work” (confidence 0.0, model-new, claude/haiku)")

    def test_ledger_records_model_fields_and_upgrades_phase_one_ledgers(self):
        connection = sqlite3.connect(str(self.fixture.ledger))
        connection.execute(
            "CREATE TABLE placements(id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp TEXT NOT NULL,"
            " backend TEXT NOT NULL, status TEXT NOT NULL, task_id TEXT, project_id TEXT,"
            " confidence REAL NOT NULL, rationale TEXT NOT NULL, prompt_excerpt TEXT, cwd TEXT,"
            " latency_ms REAL NOT NULL)")
        connection.execute("INSERT INTO placements(timestamp, backend, status, confidence, rationale,"
                           " latency_ms) VALUES('t', 'heuristic', 'inbox', 0.1, 'no-signal', 1)")
        connection.commit()
        connection.close()
        self.classify("tmux copy broke", stdout=claude_reply("ECC-018", 0.9))
        self.classify("tmux copy broke", stdout="garbage")
        connection = sqlite3.connect(str(self.fixture.ledger))
        try:
            rows = connection.execute(
                "SELECT backend, task_id, model, title, error FROM placements ORDER BY id").fetchall()
        finally:
            connection.close()
        self.assertEqual(rows[0], ("heuristic", None, None, None, None))
        self.assertEqual(rows[1], ("model", "ECC-018", "claude/haiku", "Fix tmux clipboard sync", None))
        self.assertEqual(rows[2][0], "heuristic")
        self.assertIn("malformed JSON", rows[2][4])

    def test_defaults_match_the_shipped_configurations(self):
        for name in ("config.example.json", "ecc.config.json"):
            with self.subTest(name):
                config = json.loads((ROOT / "Config" / name).read_text())
                self.assertEqual(config["placementModels"], PLACEMENT.DEFAULT_MODELS)
                self.assertEqual(config["placementEfforts"], PLACEMENT.DEFAULT_EFFORTS)
                self.assertEqual(config["placementConfidenceThreshold"],
                                 PLACEMENT.DEFAULT_CONFIDENCE_THRESHOLD)
                self.assertEqual(config["placementTimeoutSeconds"], PLACEMENT.DEFAULT_TIMEOUT_SECONDS)
        swift = (ROOT / "Sources" / "FocusQueueCore" / "Models.swift").read_text()
        for provider, model in PLACEMENT.DEFAULT_MODELS.items():
            self.assertIn(f'.{provider}: "{model}"', swift)
        for provider, effort in PLACEMENT.DEFAULT_EFFORTS.items():
            self.assertIn(f'.{provider}: "{effort}"', swift)
        self.assertIn(f"defaultPlacementConfidenceThreshold = {PLACEMENT.DEFAULT_CONFIDENCE_THRESHOLD}", swift)
        self.assertIn(f"defaultPlacementTimeoutSeconds = {PLACEMENT.DEFAULT_TIMEOUT_SECONDS}", swift)


if __name__ == "__main__":
    unittest.main()
