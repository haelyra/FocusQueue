import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location(
    "installer", ROOT / "Scripts/focus_queue_install.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReleaseProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repository = self.root / "repository"
        self.remote = self.root / "remote.git"
        self.git(self.root, "init", "--bare", str(self.remote))
        self.git(self.root, "init", "-q", "-b", "main", str(self.repository))
        self.git(self.repository, "config", "user.name", "Test")
        self.git(self.repository, "config", "user.email", "test@example.invalid")
        (self.repository / "tracked.txt").write_text("one\n")
        self.git(self.repository, "add", "tracked.txt")
        self.git(self.repository, "commit", "-qm", "first")
        self.git(self.repository, "remote", "add", "origin", str(self.remote))
        self.git(self.repository, "push", "-qu", "origin", "main")

    def git(self, cwd, *arguments):
        return subprocess.run(
            ["/usr/bin/git", *arguments],
            cwd=cwd,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def test_capture_reports_clean_integrated_commit_and_reachable_history(self):
        provenance = MODULE.capture_source_provenance(
            self.repository, integration_ref="origin/main"
        )

        revision = self.git(self.repository, "rev-parse", "HEAD")
        self.assertEqual(provenance["revision"], revision)
        self.assertEqual(provenance["integrationRevision"], revision)
        self.assertEqual(provenance["reachableRevisions"], [revision])
        self.assertFalse(provenance["dirty"])
        self.assertEqual(provenance["branch"], "main")
        self.assertNotIn(str(self.repository), json.dumps(provenance))

    def test_capture_marks_feature_and_dirty_state_without_moving_integration_tip(self):
        self.git(self.repository, "switch", "-qc", "feature")
        (self.repository / "tracked.txt").write_text("two\n")
        self.git(self.repository, "commit", "-qam", "feature")
        (self.repository / "untracked.txt").write_text("dirty\n")

        provenance = MODULE.capture_source_provenance(
            self.repository, integration_ref="origin/main"
        )

        self.assertTrue(provenance["dirty"])
        self.assertEqual(provenance["branch"], "feature")
        self.assertNotEqual(
            provenance["revision"], provenance["integrationRevision"]
        )
        self.assertIn(
            provenance["integrationRevision"], provenance["reachableRevisions"]
        )

    def test_capture_uses_remote_main_instead_of_mutable_tracking_ref(self):
        remote_revision = self.git(self.repository, "rev-parse", "HEAD")
        self.git(self.repository, "switch", "-qc", "feature")
        (self.repository / "tracked.txt").write_text("feature\n")
        self.git(self.repository, "commit", "-qam", "feature")
        feature_revision = self.git(self.repository, "rev-parse", "HEAD")
        self.git(
            self.repository,
            "update-ref",
            "refs/remotes/origin/main",
            feature_revision,
        )

        provenance = MODULE.capture_source_provenance(self.repository)

        self.assertEqual(provenance["integrationRevision"], remote_revision)
        self.assertNotEqual(provenance["revision"], provenance["integrationRevision"])

    def test_github_remote_identity_is_normalized_across_common_urls(self):
        expected = "github.com/haelyra/eccfocusqueue"
        for remote in (
            "git@github.com:Haelyra/ECCFocusQueue.git",
            "ssh://git@github.com/Haelyra/ECCFocusQueue.git",
            "https://github.com/Haelyra/ECCFocusQueue.git",
        ):
            with self.subTest(remote=remote):
                self.assertEqual(MODULE.normalize_repository_identity(remote), expected)

    def test_embedded_origin_url_drops_remote_credentials(self):
        remote = "https://release-token@github.com/Haelyra/ECCFocusQueue.git"

        self.assertEqual(
            MODULE.sanitize_repository_url(remote),
            "https://github.com/Haelyra/ECCFocusQueue.git",
        )
        self.assertNotIn("release-token", MODULE.sanitize_repository_url(remote))


if __name__ == "__main__":
    unittest.main()
