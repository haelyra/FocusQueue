from pathlib import Path
import subprocess
import tempfile
import unittest


HOOK = Path(__file__).parents[1] / ".githooks/pre-push"
ZERO = "0" * 40


class GitDeliveryGuardTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fq-push-guard-")
        self.addCleanup(temporary.cleanup)
        self.repository = Path(temporary.name) / "repository"
        self.git("init", "-q", "-b", "main", str(self.repository), cwd=temporary.name)
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        (self.repository / "tracked.txt").write_text("base\n")
        self.git("add", "tracked.txt")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD")
        (self.repository / "tracked.txt").write_text("next\n")
        self.git("commit", "-qam", "next")
        self.tip = self.git("rev-parse", "HEAD")

    def git(self, *arguments, cwd=None):
        return subprocess.run(
            ["/usr/bin/git", *arguments],
            cwd=cwd or self.repository,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def guard(self, local_ref, local_oid, remote_oid):
        return subprocess.run(
            [str(HOOK), "origin", "unused"],
            cwd=self.repository,
            input=f"{local_ref} {local_oid} refs/heads/main {remote_oid}\n",
            capture_output=True,
            text=True,
        )

    def test_allows_fast_forward_from_local_main(self):
        result = self.guard("refs/heads/main", self.tip, self.base)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_non_fast_forward_main_update(self):
        result = self.guard("refs/heads/main", self.base, self.tip)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not an ancestor", result.stderr)

    def test_rejects_updating_main_from_a_feature_ref(self):
        result = self.guard("refs/heads/feature", self.tip, self.base)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("from local main", result.stderr)

    def test_rejects_deleting_main(self):
        result = self.guard("(delete)", ZERO, self.tip)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("deleting remote main", result.stderr)


if __name__ == "__main__":
    unittest.main()
