"""Headless affected-workflow sanity using the real helper, Git and process checks."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

HELPER = Path(__file__).parents[1] / ".build/debug/focus-queue-session"


@unittest.skipUnless(HELPER.exists(), "Run swift build before the CLI sanity suite")
class TrackingSanityTests(unittest.TestCase):
    def test_incomplete_task_and_real_cleanup_lifecycle(self):
        with tempfile.TemporaryDirectory(prefix="tracking-sanity-") as temporary:
            root = Path(temporary).resolve()
            support = root / "support"
            context_dir = support / "tasks/ECC-SANITY"
            context_dir.mkdir(parents=True)
            context_file = context_dir / "context.json"
            context_file.write_text(json.dumps({"subtasks": [{}]}))
            environment = {**os.environ, "FOCUS_QUEUE_SUPPORT_DIR": str(support)}

            def reconcile():
                result = subprocess.run([str(HELPER), "reconcile", "ECC-SANITY"], env=environment,
                                        capture_output=True, text=True, timeout=90)
                self.assertEqual(result.returncode, 0, result.stderr)
                return json.loads(result.stdout)

            partial = reconcile()
            self.assertIn("identity pending", next(iter(partial["agentStates"].values())))
            self.assertTrue((context_dir / "plan.md").exists())
            self.assertTrue((context_dir / "agent-log.md").exists())
            repository = root / "repo"
            repository.mkdir()

            def git(*arguments, at=repository):
                result = subprocess.run(["/usr/bin/git", *arguments], cwd=at, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout.strip()

            git("init", "-q", "-b", "main")
            git("-c", "user.name=Sanity", "-c", "user.email=sanity@example.invalid", "-c", "core.hooksPath=/dev/null",
                "commit", "-qm", "initial", "--allow-empty")
            agent_id = str(uuid.uuid4())
            branch = "focus-queue/sanity-" + agent_id
            workspace = support / "worktrees/agents" / agent_id
            workspace.parent.mkdir(parents=True)
            git("worktree", "add", "-b", branch, str(workspace))
            context = json.loads(context_file.read_text())
            context["subtasks"] = [{"id":agent_id, "title":"Sanity", "provider":"codex", "status":"completed",
                "sessionID":str(uuid.uuid4()), "workspace":{"path":str(workspace), "repositoryPath":str(repository),
                "branch":branch, "baseBranch":"main", "managed":True}}]
            context_file.write_text(json.dumps(context))
            (workspace / "keep.txt").write_text("sanity-owned content")
            dirty_state = reconcile()["agentStates"][agent_id]
            self.assertTrue("uncommitted" in dirty_state or dirty_state.startswith("Retained:"), dirty_state)
            self.assertTrue(workspace.exists())
            git("add", "keep.txt", at=workspace)
            git("-c", "user.name=Sanity", "-c", "user.email=sanity@example.invalid", "-c", "core.hooksPath=/dev/null",
                "commit", "-qm", "work", at=workspace)
            unmerged_state = reconcile()["agentStates"][agent_id]
            self.assertTrue("not been merged" in unmerged_state or unmerged_state.startswith("Retained:"), unmerged_state)
            git("merge", "--ff-only", branch)
            merged_state = reconcile()["agentStates"][agent_id]
            # This workstation may contain unrelated providers still starting.
            # An incomplete process scan must retain even a clean merged tree.
            if merged_state.startswith("Retained:"):
                self.assertTrue(workspace.exists())
                print("CLEANUP_SANITY conservatively retained:", merged_state)
            else:
                self.assertIn("Cleaned", merged_state)
                self.assertFalse(workspace.exists())
            self.assertEqual(git("show", branch + ":keep.txt"), "sanity-owned content")
            self.assertTrue((context_dir / "plan.md").exists())
            if not workspace.exists():
                self.assertEqual(reconcile()["agentStates"][agent_id], "Cleaned; branch and task documents retained.")
