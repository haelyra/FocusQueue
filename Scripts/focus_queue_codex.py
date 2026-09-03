#!/usr/bin/env python3
"""Bounded local Codex harness for ECC Focus Queue."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

import focus_queue_morning as morning


DEFAULT_RUNTIME = Path("/Users/hira/Library/Application Support/ECC Focus Queue/agent")
DEFAULT_CODEX = Path("/opt/homebrew/bin/codex")


class CodexHarnessError(RuntimeError):
    pass


def resolve_codex() -> str:
    if DEFAULT_CODEX.is_file() and os.access(DEFAULT_CODEX, os.X_OK):
        return str(DEFAULT_CODEX)
    executable = shutil.which("codex")
    if executable:
        return executable
    raise CodexHarnessError("Codex CLI is not installed or executable")


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"version": 1, "sessions": {}}
    value = morning.load_json(path)
    if not isinstance(value.get("sessions"), dict):
        raise CodexHarnessError("Codex Queue session state is invalid")
    return value


def parse_thread_id(stdout: str) -> str | None:
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "thread.started" and event.get("thread_id"):
            return str(event["thread_id"])
    return None


def run_codex(
    *,
    prompt: str,
    workspace: Path,
    runtime: Path,
    timeout: int,
    sandbox: str,
    thread_id: str | None,
    output_schema: Path | None,
) -> tuple[str, str | None]:
    runtime.mkdir(parents=True, exist_ok=True)
    runtime.chmod(0o700)
    with tempfile.TemporaryDirectory(prefix="turn-", dir=runtime) as temporary:
        reply_path = Path(temporary) / "reply.txt"
        command = [
            resolve_codex(),
            "--ask-for-approval",
            "never",
        ]
        if sandbox == "workspace-write":
            command.extend(["-c", "sandbox_workspace_write.network_access=true"])
        command.extend(
            [
                "exec",
                "--ignore-user-config",
                "--sandbox",
                sandbox,
                "--skip-git-repo-check",
                "--color",
                "never",
                "--json",
                "--output-last-message",
                str(reply_path),
                "--thread-source",
                "app",
                "-C",
                str(workspace),
                "--add-dir",
                str(runtime),
                "--add-dir",
                "/Users/hira/Library/Application Support/ECC Focus Queue/ingestion",
            ]
        )
        if output_schema is not None:
            command.extend(["--output-schema", str(output_schema)])
        if thread_id:
            command.extend(["resume", thread_id, "-"])
        else:
            command.append("-")

        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )

        def terminate_child(_signum: int, _frame: Any) -> None:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
            raise SystemExit(143)

        previous_handler = signal.signal(signal.SIGTERM, terminate_child)
        try:
            try:
                stdout, stderr = process.communicate(input=prompt, timeout=timeout)
            except subprocess.TimeoutExpired as error:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.communicate(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
                raise CodexHarnessError(f"Codex exceeded the {timeout}-second run budget") from error
        finally:
            signal.signal(signal.SIGTERM, previous_handler)

        if process.returncode != 0:
            detail = (stderr or stdout).strip()
            raise CodexHarnessError(f"Codex exited with code {process.returncode}: {detail[:1200]}")
        if not reply_path.exists():
            raise CodexHarnessError("Codex completed without a final response")
        reply = reply_path.read_text(encoding="utf-8").strip()
        if not reply:
            raise CodexHarnessError("Codex returned an empty final response")
        return reply, parse_thread_id(stdout)


def chat(arguments: argparse.Namespace) -> int:
    runtime = arguments.runtime.expanduser()
    state_path = runtime / "sessions.json"
    lock_path = runtime / "sessions.lock"
    runtime.mkdir(parents=True, exist_ok=True)
    runtime.chmod(0o700)
    with lock_path.open("a+", encoding="utf-8") as lock:
        lock_path.chmod(0o600)
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        state = load_state(state_path)
        sessions = state.setdefault("sessions", {})
        prior_thread = str(sessions.get(arguments.session, "")) or None
        prompt = arguments.prompt_file.read_text(encoding="utf-8")
        try:
            reply, observed_thread = run_codex(
                prompt=prompt,
                workspace=arguments.workspace,
                runtime=runtime,
                timeout=arguments.timeout,
                sandbox="workspace-write",
                thread_id=prior_thread,
                output_schema=None,
            )
        except CodexHarnessError as error:
            detail = str(error).casefold()
            missing_thread = prior_thread and any(
                phrase in detail
                for phrase in ["not found", "no rollout", "unknown thread", "invalid thread"]
            )
            if not missing_thread:
                raise
            sessions.pop(arguments.session, None)
            morning.write_private_json(state_path, state)
            reply, observed_thread = run_codex(
                prompt=prompt,
                workspace=arguments.workspace,
                runtime=runtime,
                timeout=arguments.timeout,
                sandbox="workspace-write",
                thread_id=None,
                output_schema=None,
            )
        thread_id = observed_thread or prior_thread
        if not thread_id:
            raise CodexHarnessError("Codex did not return a persistent thread identifier")
        sessions[arguments.session] = thread_id
        morning.write_private_json(state_path, state)
        print(reply)
        return 0


def run_once(arguments: argparse.Namespace) -> int:
    prompt = arguments.prompt_file.read_text(encoding="utf-8")
    reply, _ = run_codex(
        prompt=prompt,
        workspace=arguments.workspace,
        runtime=arguments.runtime.expanduser(),
        timeout=arguments.timeout,
        sandbox=arguments.sandbox,
        thread_id=None,
        output_schema=arguments.output_schema,
    )
    print(reply)
    return 0


def reset(arguments: argparse.Namespace) -> int:
    runtime = arguments.runtime.expanduser()
    state_path = runtime / "sessions.json"
    state = load_state(state_path)
    removed = state.setdefault("sessions", {}).pop(arguments.session, None)
    morning.write_private_json(state_path, state)
    print(json.dumps({"status": "ok", "session": arguments.session, "reset": bool(removed)}))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, default=DEFAULT_RUNTIME)
    subparsers = parser.add_subparsers(dest="command", required=True)

    chat_parser = subparsers.add_parser("chat")
    chat_parser.add_argument("--session", required=True)
    chat_parser.add_argument("--workspace", type=Path, required=True)
    chat_parser.add_argument("--prompt-file", type=Path, required=True)
    chat_parser.add_argument("--timeout", type=int, default=120)

    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--workspace", type=Path, required=True)
    run_parser.add_argument("--prompt-file", type=Path, required=True)
    run_parser.add_argument("--timeout", type=int, default=120)
    run_parser.add_argument("--sandbox", choices=["read-only", "workspace-write"], default="read-only")
    run_parser.add_argument("--output-schema", type=Path)
    run_parser.add_argument("--label")

    reset_parser = subparsers.add_parser("reset")
    reset_parser.add_argument("--session", required=True)
    arguments = parser.parse_args()
    if not (10 <= getattr(arguments, "timeout", 120) <= 900):
        parser.error("timeout must be between 10 and 900 seconds")
    try:
        if arguments.command == "chat":
            return chat(arguments)
        if arguments.command == "run":
            return run_once(arguments)
        return reset(arguments)
    except Exception as error:
        print(f"Codex Queue harness failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
