import json
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import struct
import subprocess
import tempfile
import termios
import time
import unittest
import uuid
import fcntl


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
        self.support = self.root / "support"
        self.context = self.support / "tasks/ECC-035/context.json"
        self.context.parent.mkdir(parents=True)
        self.context.write_text(json.dumps({
            "ticketID": "ECC-035", "title": "Usage bar test", "subtasks": []}))
        for name, body in {
            "codex": ("#!/bin/bash\nprintf 'codex:%s\\n' \"$*\" >> \"$CALLS\"\n"
                      "printf '%s\\n' \"$PPID\" > \"$CODEX_PARENT\"\n"
                      "exit \"${CODEX_EXIT:-0}\"\n"),
            "focus-queue-session":
                "#!/bin/bash\nprintf 'session:%s\\n' \"$*\" >> \"$CALLS\"\n",
            "node": "#!/bin/bash\nexit 0\n",
            "tmux": ("#!/bin/bash\nprintf 'tmux:%s\\n' \"$*\" >> \"$CALLS\"\n"
                     "case \"$*\" in *'show-options -gv status-format[0]'*) printf 'native-window-row\\n' ;; esac\n"
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
            "FOCUS_QUEUE_SUPPORT_DIR": str(self.support),
        }
        for key in ("FOCUS_QUEUE_MANAGED_TMUX", "FOCUS_QUEUE_TASK_ID",
                    "FOCUS_QUEUE_SUBTASK_ID", "FOCUS_QUEUE_TMUX_NAME", "TMUX", "TMUX_PANE"):
            environment.pop(key, None)
        if managed:
            environment.update(
                FOCUS_QUEUE_MANAGED_TMUX="1",
                FOCUS_QUEUE_TASK_ID="ECC-035",
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
        self.assertTrue(any("status-format[0] native-window-row" in line for line in calls))
        status = [line for line in calls if "set-option" in line and "status-format[" in line]
        usage_status = [line for line in status if "status-format[0]" not in line]
        self.assertEqual(len(status), 4)
        self.assertEqual(len(usage_status), 3)
        self.assertTrue(all("#{@focus-queue-agent}" in line for line in usage_status))
        self.assertTrue(all("--context" in line and "context.json" in line for line in usage_status))
        self.assertTrue(all("focus_queue_codex_bar.js" in line for line in usage_status))
        self.assertTrue(all("$FOCUS_QUEUE_USAGE_BAR_PATH" not in line for line in usage_status))
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
                            if "set-option" in line and "status-format[" in line
                            and "status-format[0]" not in line))

        self.calls.unlink()
        result = self.run_wrapper(managed=True, overrides={"USAGE_BAR_INTERVAL": "not-a-number"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any("status-interval 15" in line for line in self.calls.read_text().splitlines()))

    def test_managed_usage_bar_can_be_disabled_without_losing_native_tabs(self):
        result = self.run_wrapper(managed=True, overrides={"FOCUS_QUEUE_USAGE_BAR": "off"})
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls[-1], "codex:--yolo hello")
        self.assertTrue(any("status on" in line for line in calls))
        self.assertTrue(any("status-format[0] native-window-row" in line for line in calls))
        self.assertEqual(len([line for line in calls
                              if "set-option" in line and "status-format[" in line]), 4)

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

    def test_real_tmux_renders_the_selected_agents_usage_rows(self):
        real_tmux = shutil.which("tmux", path=os.environ.get("PATH"))
        real_node = shutil.which("node", path=os.environ.get("PATH"))
        if not real_tmux or not real_node:
            self.skipTest("real tmux and node are required")

        session_id = "01a0d15c-33b1-7442-9e82-83038734d23b"
        codex_home = self.root / "codex"
        sessions = codex_home / "sessions/2026/09/24"
        sessions.mkdir(parents=True)
        (sessions / f"rollout-2026-09-24T03-01-15-{session_id}.jsonl").write_text(
            json.dumps({"type":"event_msg", "payload":{"type":"token_count", "info":{
                "total_token_usage":{"total_tokens":40000},
                "last_token_usage":{"input_tokens":25000, "cached_input_tokens":12500,
                                    "total_tokens":25000},
                "model_context_window":250000},
                "rate_limits":{"primary":{"used_percent":37, "window_minutes":300}}}}) + "\n")
        self.context.write_text(json.dumps({
            "ticketID":"ECC-035", "title":"Usage bar test", "subtasks":[{
                "id":"selected-agent", "sessionID":session_id,
                "launchConfiguration":{"model":"gpt-selected", "effort":"high"},
            }]}))
        live_bin = self.root / "live-bin"
        live_bin.mkdir()
        codex = live_bin / "codex"
        codex.write_text("#!/bin/bash\nsleep 30\n")
        codex.chmod(0o700)
        socket = "fq-usage-" + uuid.uuid4().hex[:12]
        session = "fq-task-ecc-035"
        environment = {
            **os.environ, "PATH": f"{live_bin}:{Path(real_node).parent}:/usr/bin:/bin",
            "CODEX_HOME": str(codex_home), "LANG": "en_US.UTF-8",
        }
        command = [
            "/usr/bin/env", "FOCUS_QUEUE_MANAGED_TMUX=1",
            f"FOCUS_QUEUE_TMUX_NAME={session}", "FOCUS_QUEUE_TASK_ID=ECC-035",
            "FOCUS_QUEUE_SUBTASK_ID=selected-agent", f"FOCUS_QUEUE_SUPPORT_DIR={self.support}",
            "/bin/bash", str(WRAPPER), str(self.delegate), "--",
        ]
        client = None
        master = None
        try:
            started = subprocess.run(
                [real_tmux, "-f", "/dev/null", "-L", socket, "new-session", "-d",
                 "-s", session, *command], capture_output=True, text=True,
                env=environment, timeout=10)
            self.assertEqual(started.returncode, 0, started.stderr)
            subprocess.run([real_tmux, "-L", socket, "set-option", "-p", "-t",
                            f"={session}:0.0", "@focus-queue-agent", "selected-agent"],
                           check=True, capture_output=True, env=environment)
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 160, 0, 0))
            client = subprocess.Popen(
                [real_tmux, "-L", socket, "attach-session", "-r", "-t", f"={session}"],
                stdin=slave, stdout=slave, stderr=slave, env={**environment, "TERM":"xterm-256color"},
                close_fds=True)
            os.close(slave)
            output = b""
            deadline = time.time() + 10
            while time.time() < deadline and b"gpt-selected" not in output:
                ready, _, _ = select.select([master], [], [], 0.25)
                if ready:
                    output += os.read(master, 65536)
            rendered = output.decode("utf-8", errors="replace")
            self.assertIn("gpt-selected", rendered)
            self.assertIn("37%", rendered)
            self.assertIn("10%", rendered)
        finally:
            if client is not None:
                client.terminate()
                try: client.wait(timeout=2)
                except subprocess.TimeoutExpired: client.kill()
            if master is not None:
                os.close(master)
            subprocess.run([real_tmux, "-L", socket, "kill-server"],
                           capture_output=True, env=environment)


if __name__ == "__main__":
    unittest.main()
