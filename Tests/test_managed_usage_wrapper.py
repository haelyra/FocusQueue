import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid


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
                      "printf '%s\\n' \"$PPID\" > \"$CODEX_PARENT\"\n"
                      "exit \"${CODEX_EXIT:-0}\"\n"),
            "focus-queue-session":
                "#!/bin/bash\nprintf 'session:%s\\n' \"$*\" >> \"$CALLS\"\n",
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
        self.assertTrue(any("status-position bottom" in line for line in calls))
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

    def test_graceful_managed_exit_archives_the_exact_agent(self):
        result = self.run_wrapper(managed=True, overrides={
            "FOCUS_QUEUE_TASK_ID": "FOC-005",
            "FOCUS_QUEUE_SUBTASK_ID": "agent-6",
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines()[-1],
                         "session:archive-agent FOC-005 agent-6")

    def test_uncertain_managed_exit_remains_active_and_recallable(self):
        result = self.run_wrapper(managed=True, overrides={
            "FOCUS_QUEUE_TASK_ID": "FOC-005",
            "FOCUS_QUEUE_SUBTASK_ID": "agent-6",
            "CODEX_EXIT": "17",
        })
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertFalse(any(line.startswith("session:archive-agent")
                             for line in self.calls.read_text().splitlines()))

    def test_real_tmux_classifies_graceful_and_uncertain_exits_without_killing_session(self):
        real_tmux = shutil.which("tmux", path=os.environ.get("PATH"))
        helper = ROOT / ".build/debug/focus-queue-session"
        if not real_tmux or not helper.is_file():
            self.skipTest("real tmux and a built focus-queue-session are required")

        support = self.root / "support"
        task = support / "tasks/SAN-001"
        task.mkdir(parents=True)
        plan = task / "plan.md"
        plan.write_text("# Managed exit sanity\n")
        subtasks = [{
            "id": agent_id,
            "title": title,
            "provider": "codex",
            "status": "working",
            "runtimeMode": "tmux",
            "lastHeartbeatAt": 1,
        } for agent_id, title in (
            ("graceful", "Graceful agent"), ("uncertain", "Uncertain agent"))]
        context = task / "context.json"
        context.write_text(json.dumps({
            "schemaVersion": 2,
            "ticketID": "SAN-001",
            "title": "Managed exit sanity",
            "summary": "",
            "successCriteria": "Classify exits without losing the task session.",
            "planPath": str(plan),
            "managedWorktree": False,
            "subtasks": subtasks,
            "updatedAt": 0,
        }))

        real_bin = self.root / "real-bin"
        real_bin.mkdir()
        for name, body in {
            "codex": "#!/bin/bash\nexit \"${CODEX_EXIT:-0}\"\n",
            "node": "#!/bin/bash\nexit 0\n",
        }.items():
            path = real_bin / name
            path.write_text(body)
            path.chmod(0o700)
        socket = "fq-archive-" + uuid.uuid4().hex[:12]
        session = "fq-task-san-001"
        path = f"{real_bin}:{helper.parent}:{os.environ.get('PATH', '/usr/bin:/bin')}"

        def tmux(*arguments, check=True):
            return subprocess.run(
                [real_tmux, "-L", socket, *arguments], capture_output=True,
                text=True, timeout=10, check=check)

        def launch(agent_id, exit_code):
            command = shlex.join([
                "env", f"PATH={path}", "FOCUS_QUEUE_MANAGED_TMUX=1",
                f"FOCUS_QUEUE_TMUX_NAME={session}", "FOCUS_QUEUE_TASK_ID=SAN-001",
                f"FOCUS_QUEUE_SUBTASK_ID={agent_id}",
                f"FOCUS_QUEUE_SUPPORT_DIR={support}", f"CODEX_EXIT={exit_code}",
                "/bin/bash", str(WRAPPER), str(self.delegate), "--",
            ])
            tmux("split-window", "-d", "-t", session, command)

        try:
            tmux("new-session", "-d", "-s", session, "sleep 60")
            launch("graceful", 0)
            launch("uncertain", 17)
            deadline = time.time() + 10
            while time.time() < deadline:
                saved = json.loads(context.read_text())
                archived = {item["id"]: item.get("agentRemovedAt") for item in saved["subtasks"]}
                panes = tmux("list-panes", "-t", session, "-F", "#{pane_id}").stdout.splitlines()
                if archived["graceful"] and archived["uncertain"] is None and len(panes) == 1:
                    break
                time.sleep(0.1)
            self.assertTrue(archived["graceful"])
            self.assertIsNone(archived["uncertain"])
            self.assertEqual(len(panes), 1, "the sibling pane must keep the task session alive")
            self.assertEqual(tmux("has-session", "-t", session).returncode, 0)
        finally:
            tmux("kill-server", check=False)


if __name__ == "__main__":
    unittest.main()
