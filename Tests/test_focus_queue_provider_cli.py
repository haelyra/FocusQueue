import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).parents[1] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("provider_cli", SCRIPTS / "focus_queue_provider_cli.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def executable(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n")
    path.chmod(0o755)
    return path


class FindCLITests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        saved_path = os.environ["PATH"]
        self.addCleanup(os.environ.__setitem__, "PATH", saved_path)

    def shell_reports(self, stdout, returncode=0):
        return mock.patch.object(
            MODULE.subprocess, "run",
            return_value=subprocess.CompletedProcess([], returncode, stdout, ""))

    def test_a_trusted_location_wins_without_starting_a_shell(self):
        trusted = executable(self.root / "homebrew/codex")
        with mock.patch.object(MODULE.subprocess, "run") as run:
            self.assertEqual(MODULE.find_cli("codex", [trusted]), str(trusted))
        run.assert_not_called()

    def test_a_cli_only_the_login_shell_knows_is_found_and_its_path_is_kept(self):
        node_bin = self.root / "nvm/bin"
        found = executable(node_bin / "codex")
        with self.shell_reports(f"welcome back\n{node_bin}:/usr/bin\n"):
            self.assertEqual(MODULE.find_cli("codex", [self.root / "missing"]), str(found))
        self.assertEqual(os.environ["PATH"], f"{node_bin}:/usr/bin")

    def test_a_cli_nowhere_gives_none_and_leaves_path_alone(self):
        before = os.environ["PATH"]
        with self.shell_reports(f"{self.root}\n"):
            self.assertIsNone(MODULE.find_cli("codex", []))
        self.assertEqual(os.environ["PATH"], before)

    def test_a_shell_that_fails_or_hangs_gives_none(self):
        with self.shell_reports("partial\n", returncode=1):
            self.assertIsNone(MODULE.login_shell_path())
        with mock.patch.object(MODULE.subprocess, "run",
                               side_effect=subprocess.TimeoutExpired("zsh", 20)):
            self.assertIsNone(MODULE.login_shell_path())

    def test_the_path_comes_from_a_real_login_shell(self):
        home = self.root / "home"
        marked = home / "tools"
        home.mkdir()
        (home / ".zshrc").write_text(f'echo profile noise\nexport PATH="{marked}:$PATH"\n')
        (home / ".bashrc").write_text(f'echo profile noise\nexport PATH="{marked}:$PATH"\n')
        (home / ".bash_profile").write_text(". ~/.bashrc\n")
        with mock.patch.dict(os.environ, {"HOME": str(home), "ZDOTDIR": str(home)}):
            self.assertTrue(MODULE.login_shell_path().startswith(f"{marked}:"))


class HarnessErrorTests(unittest.TestCase):
    def test_each_harness_names_where_it_looked_when_the_cli_is_missing(self):
        import focus_queue_claude as claude
        import focus_queue_codex as codex
        import focus_queue_kimi as kimi
        for module, resolve, error in ((codex, codex.resolve_codex, codex.CodexHarnessError),
                                       (claude, claude.resolve_claude, claude.ClaudeHarnessError),
                                       (kimi, kimi.resolve_kimi, kimi.KimiHarnessError)):
            with mock.patch.object(module, "find_cli", return_value=None):
                with self.assertRaisesRegex(error, "was not found at .* or on your shell's PATH"):
                    resolve()


if __name__ == "__main__":
    unittest.main()
