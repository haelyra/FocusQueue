import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid
from datetime import datetime, timezone


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
        (task / "plan.md").write_text(f"# {task_id}\n")
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
        parent, child, inherited_launch = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
        self.command("register-event", "--provider", "codex", payload=self.event(parent))
        registered = self.command("register-event", "--provider", "codex",
            payload=self.event(parent, "SubagentStart", agent_id=child),
            extra_environment={"FOCUS_QUEUE_LAUNCH_ID": inherited_launch})
        self.assertEqual(registered["sessionID"], child)
        self.assertEqual(registered["parentSessionID"], parent)
        placements = self.support / "tracking" / "placements"
        self.assertTrue((placements / f"{child}.json").is_file())
        self.assertFalse((placements / f"{inherited_launch}.json").exists())
        self.command("register-event", "--provider", "codex", payload="{malformed", expected=1)
        self.command("register-event", "--provider", "codex", payload=self.event("not-a-uuid"), expected=1)
        self.assertEqual(len(self.context()["subtasks"]), 2)

    def test_discovered_child_prompt_inherits_parent_without_creating_task(self):
        context = self.context()
        context["repositoryPath"] = str(self.root / "different repository")
        (self.support / "tasks/ECC-401/context.json").write_text(json.dumps(context))
        parent, child = str(uuid.uuid4()), str(uuid.uuid4())
        registered_parent = self.command(
            "register-event", "--provider", "codex", "--task", "ECC-401",
            payload=self.event(parent))
        self.assertEqual(registered_parent["taskID"], "ECC-401")

        registered_child = self.command(
            "register-event", "--provider", "codex",
            payload=self.event(
                child, "ProcessDiscovery", parent_session_id=parent,
                focus_queue_discovered_subagent=True,
                prompt="registration fix"))

        self.assertEqual(registered_child["taskID"], "ECC-401")
        self.assertEqual(registered_child["parentSessionID"], parent)
        self.assertEqual(len(self.context()["subtasks"]), 2)
        self.assertEqual(
            {path.name for path in (self.support / "tasks").iterdir()}, {"ECC-401"})

    def test_registered_route_replay_republishes_missing_inbox_record(self):
        config = json.loads((Path(__file__).parents[1] / "Config/config.example.json").read_text())
        config.update(
            dashboardPath=str(self.support / "dashboard.json"),
            workspacePath=str(self.repository),
            automaticAgentRouting=True,
            selectedProjectID="focus",
            projects=[{
                "id":"focus", "name":"Focus", "taskPrefix":"ECC",
                "repositoryPath":str(self.repository), "remoteAliases":[],
            }],
        )
        self.support.mkdir(parents=True, exist_ok=True)
        (self.support / "config.json").write_text(json.dumps(config))
        session_id, route_id = str(uuid.uuid4()), str(uuid.uuid4())
        registered = self.command(
            "register-event", "--provider", "codex", "--task", "ECC-401",
            payload=self.event(session_id, prompt="Replay registration"))
        agent_id = registered["subtaskID"]
        inbox = self.support / "agent-registrations"
        for payload in inbox.glob("*.json"):
            payload.unlink()

        now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        route_directory = self.support / "agent-routes"
        route_directory.mkdir(parents=True)
        route = {
            "schemaVersion":1, "routeID":route_id,
            "prompt":"Recover route publication", "provider":"codex",
            "source":{"cwd":str(self.repository)}, "origin":"automatic-shell",
            "inferredProjectID":"focus", "repositoryPath":str(self.repository),
            "createdAt":now, "startedAt":now, "taskID":"ECC-401",
            "subtaskID":agent_id,
        }
        route_path = route_directory / f"{route_id}.json"
        route_path.write_text(json.dumps(route))
        route_path.chmod(0o600)

        context = self.context()
        saved_agent = next(item for item in context["subtasks"] if item["id"] == agent_id)
        receipt_directory = self.support / "logs/agent-startups/ECC-401"
        receipt_directory.mkdir(parents=True)
        receipt = {
            "schemaVersion":1, "routeID":route_id, "status":"registered",
            "projectID":"focus", "projectName":"Focus", "taskID":"ECC-401",
            "taskTitle":"Registration test", "subtaskID":agent_id,
            "title":"Replay registration",
            "description":"Republish the canonical session before the router exits.",
            "provider":"codex", "providerSessionID":session_id,
            "providerLaunchCommand":[], "promptByteCount":1,
            "promptSHA256":"0" * 64, "workspace":saved_agent["workspace"],
            "context":{
                "taskPlan":str(self.support / "tasks/ECC-401/plan.md"),
                "taskContext":str(self.support / "tasks/ECC-401/context.json"),
                "taskLog":str(self.support / "tasks/ECC-401/agent-log.md"),
            },
            "source":{"cwd":str(self.repository)},
            "orchestrationPreparedAt":now, "handoffCompletedAt":now,
            "createdAt":now, "updatedAt":now,
        }
        receipt_path = receipt_directory / f"{agent_id.lower()}.json"
        receipt_path.write_text(json.dumps(receipt))
        receipt_path.chmod(0o600)

        replay = self.command(
            "route", "start", route_id, "--task", "ECC-401",
            "--title", "Replay registration", "--description",
            "Republish the canonical session before the router exits.",
            "--provider", "codex", "--workspace", "existing")

        self.assertTrue(replay["replayed"])
        self.assertEqual(replay["routerAction"], "exit")
        published = [json.loads(path.read_text()) for path in inbox.glob("*.json")]
        self.assertEqual(len(published), 1)
        self.assertEqual(published[0]["ticketID"], "ECC-401")
        self.assertEqual(published[0]["subtaskID"], agent_id)
        self.assertEqual(published[0]["sessionID"], session_id)

    def test_prompt_derived_title_and_first_seen_timestamp_survive_updates(self):
        session_id = str(uuid.uuid4())
        started = self.command("register-event", "--provider", "codex",
            payload=self.event(session_id))
        record_path = (self.support / "external-agent-sessions"
            / f"{started['registrationID']}.json")
        record = json.loads(record_path.read_text())
        self.assertTrue(record["title"].startswith("Codex · "), record["title"])
        self.assertEqual(record["registeredAt"], record["updatedAt"])
        first_seen = record["registeredAt"]

        prompted = self.command("register-event", "--provider", "codex",
            payload=self.event(session_id, "UserPromptSubmit",
                prompt="Fix the registration title regression"))
        self.assertEqual(prompted["registrationID"], started["registrationID"])
        record = json.loads(record_path.read_text())
        self.assertEqual(record["title"], "Fix the registration title regression")
        self.assertEqual(record["registeredAt"], first_seen)
        self.assertGreaterEqual(record["updatedAt"], first_seen)

    def test_add_requires_a_title_and_brief_description(self):
        self.command("add", "ECC-401", "codex", "Named work item", expected=1)
        self.assertEqual(self.context()["subtasks"], [])

        created = self.command("add", "ECC-401", "codex", "Named work item",
            "Verify exact task-pane recall from the saved workspace.")
        self.assertEqual(created["title"], "Named work item")
        self.assertEqual(created["assignmentDescription"],
            "Verify exact task-pane recall from the saved workspace.")
        self.assertFalse(created["isAssignmentOnly"])
        self.assertNotIn("runtimeMode", created)

        identified = self.command("identify", "ECC-401", created["id"],
            "Inspect shared panes", "Inspect the shared tmux panes after the first prompt.")
        self.assertEqual(identified["title"], "Inspect shared panes")
        self.assertEqual(identified["assignmentDescription"],
            "Inspect the shared tmux panes after the first prompt.")

        session_id = str(uuid.uuid4())
        context = self.context()
        context["subtasks"][0]["sessionID"] = session_id
        context["subtasks"][0]["lastHeartbeatAt"] = 1
        (self.support / "tasks/ECC-401/context.json").write_text(json.dumps(context))
        archived = self.command("archive-agent", "ECC-401", created["id"])
        self.assertEqual(archived, {
            "status": "archived", "subtaskID": created["id"], "taskID": "ECC-401",
        })
        saved = self.context()["subtasks"][0]
        self.assertIn("agentRemovedAt", saved)
        self.assertEqual(saved["title"], "Inspect shared panes")
        self.assertEqual(saved["sessionID"], session_id)

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
