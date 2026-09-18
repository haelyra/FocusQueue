import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parents[1] / "Scripts"))
import focus_queue_projects as projects
import focus_queue_morning as morning


class ProjectMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "config.json"
        self.dashboard = self.root / "dashboard.json"
        self.manifest = self.root / "manifest.json"
        self.original = {"unknown": {"retained": True}, "tickets": [
            {"id": "ECC-035", "title": "Focus Queue", "status": "in-progress"},
            {"id": "ECC-044", "title": "Integration", "worktree": "/focus-queue", "status": "in-progress"},
            {"id": "ECC-003", "title": "History", "status": "resolved", "completion": {"evidence": ["retained"]}},
        ]}
        projects.write_json(self.config, {"dashboardPath": str(self.dashboard), "unknown": 42,
                                        "dailyRoutines": [{"id": "review-prs"}, {"id": "global"}]})
        projects.write_json(self.dashboard, self.original)
        self.state = self.root / "state.json"
        self.state.write_text('{"dismissedNotificationIDs":["keep"],"deferredTicketIDs":["ECC-044"]}')

    def prepare(self):
        value = projects.preview(self.config, self.root / "focus", self.root / "ecc")
        projects.write_json(self.manifest, value)
        return value

    def test_preview_apply_repeat_and_rollback_preserve_history_and_later_edits(self):
        state = self.state.read_bytes()
        original_config = self.config.read_bytes()
        manifest = self.prepare()
        self.assertEqual(manifest["counts"], {"ecc-focus-queue": 1, "ecc": 2, "other": 0})
        self.assertEqual(json.loads(self.dashboard.read_bytes()), self.original)
        projects.apply(self.manifest)
        migrated = json.loads(self.dashboard.read_bytes())
        self.assertEqual([t["projectID"] for t in migrated["tickets"]], ["ecc-focus-queue", "ecc", "ecc"])
        self.assertEqual(migrated["tickets"][1]["worktree"], "/focus-queue")
        for ticket in migrated["tickets"]:
            ticket.pop("projectID")
        self.assertEqual(migrated, self.original)
        self.assertEqual(self.state.read_bytes(), state)
        self.assertEqual(projects.apply(self.manifest)["status"], "already-applied")
        applied = json.loads(self.dashboard.read_bytes())
        applied["tickets"][0]["title"] = "Later task edit"
        applied["tickets"][1]["projectID"] = "custom"
        projects.write_json(self.dashboard, applied)
        result = projects.rollback(self.manifest)
        restored = json.loads(self.dashboard.read_bytes())
        self.assertEqual(restored["tickets"][0]["title"], "Later task edit")
        self.assertNotIn("projectID", restored["tickets"][0])
        self.assertEqual(restored["tickets"][1]["projectID"], "custom")
        self.assertEqual(result["preservedAssignments"], ["ECC-044"])
        self.assertEqual((self.root / "manifest-backup/config.json").read_bytes(), original_config)
        self.assertEqual(self.state.read_bytes(), state)

    def test_stale_preview_does_not_overwrite_a_concurrent_edit(self):
        self.prepare()
        updated = dict(self.original, newField="Keep this concurrent change")
        projects.write_json(self.dashboard, updated)
        config_before = self.config.read_bytes()
        with self.assertRaisesRegex(ValueError, "Source changed"):
            projects.apply(self.manifest)
        self.assertEqual(json.loads(self.dashboard.read_bytes()), updated)
        self.assertEqual(self.config.read_bytes(), config_before)

    def test_duplicate_ids_and_assignment_conflicts_fail_before_writing(self):
        duplicate = dict(self.original, tickets=self.original["tickets"] * 2)
        projects.write_json(self.dashboard, duplicate)
        with self.assertRaisesRegex(ValueError, "unique"):
            self.prepare()
        conflicting = json.loads(json.dumps(self.original))
        conflicting["tickets"][1]["projectID"] = "another"
        projects.write_json(self.dashboard, conflicting)
        with self.assertRaisesRegex(ValueError, "another project"):
            self.prepare()

    def test_imported_projects_require_a_unique_repository_match(self):
        registry = [{"id": "ecc", "remote": "git@github.com:affaan-m/ECC.git", "remoteAliases": ["https://github.com/haelyra/ECC"]},
                    {"id": "focus", "remote": "https://github.com/example/focus"}]
        ecc = {"type": "github", "url": "https://github.com/affaan-m/ECC/issues/123"}
        fork = {"type": "github", "url": "https://github.com/haelyra/ECC/pull/1"}
        focus = {"type": "github", "url": "https://github.com/example/focus/issues/1"}
        self.assertEqual(morning.project_for_source_links(registry, [ecc]), "ecc")
        self.assertEqual(morning.project_for_source_links(registry, [fork]), "ecc")
        self.assertIsNone(morning.project_for_source_links(registry, [ecc, focus]))
        self.assertIsNone(morning.project_for_source_links(registry, [{"type": "email", "url": ecc["url"]}]))
        self.assertIsNone(morning.project_for_source_links(registry, []))


if __name__ == "__main__":
    unittest.main()
