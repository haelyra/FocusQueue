import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).parents[1]
WRAPPER = ROOT / "Scripts/focus_queue_usage_wrapper.sh"


class ManagedUsageWrapperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="managed usage ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls"
        self.delegate = self.root / "configured-wrapper"
        self.delegate.write_text(
            "#!/bin/bash\nprintf 'delegate:%s\\n' \"$*\" >> \"$CALLS\"\n"
        )
        self.delegate.chmod(0o700)
        (self.root / "codex-bar.js").write_text("// fixture\n")
        for name, body in {
            "codex": ("#!/bin/bash\nprintf 'codex:%s\\n' \"$*\" >> \"$CALLS\"\n"
                      "printf '%s\\n' \"$PPID\" > \"$CODEX_PARENT\"\n"),
            "node": "#!/bin/bash\nexit 0\n",
            "tmux": ("#!/bin/bash\nprintf 'tmux:%s\\n' \"$*\" >> \"$CALLS\"\n"
                     "case \"${*: -1}\" in '#{session_name}') printf '%s\\n' \"${LIVE_TMUX_SESSION:-fq-task-ecc-035}\" ;; '#{client_utf8}') printf '1\\n' ;; esac\n"),
        }.items():
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o700)

    def run_wrapper(self, *, managed, overrides=None):
        environment = {
            **os.environ,
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "CALLS": str(self.calls),
            "CODEX_PARENT": str(self.root / "codex-parent"),
        }
        for key in ("FOCUS_QUEUE_MANAGED_TMUX", "FOCUS_QUEUE_TMUX_NAME", "TMUX", "TMUX_PANE"):
            environment.pop(key, None)
        if managed:
            environment.update(
                FOCUS_QUEUE_MANAGED_TMUX="1",
                FOCUS_QUEUE_TMUX_NAME="fq-task-ecc-035",
                TMUX="/tmp/focus-queue,1,0",
                TMUX_PANE="%7",
            )
        environment.update(overrides or {})
        return subprocess.run(
            ["/bin/bash", str(WRAPPER), str(self.delegate), "--", "--yolo", "hello"],
            capture_output=True,
            text=True,
            env=environment,
            timeout=10,
        )

    def test_nonmanaged_launch_delegates_without_changing_tmux(self):
        result = self.run_wrapper(managed=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["delegate:--yolo hello"])

    def test_managed_tmux_bar_tracks_active_pane_and_is_not_removed_on_exit(self):
        result = self.run_wrapper(managed=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls[-1], "codex:--yolo hello")
        self.assertNotEqual(int((self.root / "codex-parent").read_text()), os.getpid(),
                            "the adapter must remain the pane PID so Codex is its discoverable child")
        self.assertFalse(any(line.startswith("delegate:") for line in calls))
        self.assertTrue(any("status 4" in line for line in calls))
        self.assertTrue(any(
            f"set-environment -t %7 FOCUS_QUEUE_USAGE_BAR_PATH {self.root / 'codex-bar.js'}" in line
            for line in calls
        ))
        status = [line for line in calls if "status-format[" in line]
        self.assertEqual(len(status), 3)
        self.assertTrue(all("USAGE_BAR_WRAPPER_PID=#{pane_pid}" in line for line in status))
        self.assertTrue(all("$FOCUS_QUEUE_USAGE_BAR_PATH" in line for line in status))
        self.assertTrue(all(str(self.root / "codex-bar.js") not in line for line in status))
        self.assertTrue(all("set-option -u" not in line for line in calls))

    def test_managed_mode_requires_exact_focus_queue_marker_and_pane(self):
        environment = {
            **os.environ,
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "CALLS": str(self.calls),
            "CODEX_PARENT": str(self.root / "codex-parent"),
            "FOCUS_QUEUE_MANAGED_TMUX": "1",
            "TMUX": "/tmp/focus-queue,1,0",
            "TMUX_PANE": "not-a-pane",
        }
        result = subprocess.run(
            ["/bin/bash", str(WRAPPER), str(self.delegate), "--", "hello"],
            capture_output=True,
            text=True,
            env=environment,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["delegate:hello"])

    def test_managed_mode_rejects_a_different_live_tmux_session(self):
        result = self.run_wrapper(managed=True, overrides={"LIVE_TMUX_SESSION":"personal"})
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls[-1], "delegate:--yolo hello")
        self.assertFalse(any("set-option" in line or "set-environment" in line for line in calls))

    def test_managed_mode_preserves_supported_usage_controls(self):
        result = self.run_wrapper(managed=True, overrides={
            "USAGE_BAR_INTERVAL": "7",
            "USAGE_BAR_GLYPHS": "ascii",
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text().splitlines()
        self.assertTrue(any("status-interval 7" in line for line in calls))
        self.assertTrue(all("USAGE_BAR_GLYPHS=ascii" in line for line in calls
                            if "status-format[" in line))

        self.calls.unlink()
        result = self.run_wrapper(managed=True, overrides={"USAGE_BAR_INTERVAL": "not-a-number"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any("status-interval 15" in line for line in self.calls.read_text().splitlines()))

    def test_managed_usage_bar_can_be_disabled_without_mutating_tmux(self):
        result = self.run_wrapper(managed=True, overrides={"USAGE_BAR": "off"})
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls[-1], "codex:--yolo hello")
        self.assertFalse(any("set-option" in line or "set-environment" in line for line in calls))


if __name__ == "__main__":
    unittest.main()
