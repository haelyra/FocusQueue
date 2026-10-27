#!/usr/bin/env python3
"""Bounded local Kimi harness for Focus Queue.

Kimi CLI notes (verified against kimi-code 2.1.1 on this machine):
- Non-interactive mode is `kimi --prompt <text>`; the prompt is an argument,
  not stdin. Print mode auto-approves regular tool calls (the `auto`
  permission policy), which provides the chat tool-use parity; `--yolo` and
  `--auto` cannot be combined with `--prompt`.
- Session resume is `--session <id>`; `--output-format stream-json` emits one
  JSON event per stdout line for programmatic parsing.
- Kimi has no reasoning-effort flag, so `--effort` is accepted and dropped,
  matching AgentProvider.effortArguments in Sources/FocusQueueCore/Models.swift.
- Kimi has no switch to disable built-in tools in print mode; `run
  --disable-tools` therefore relies on the classification prompt's read-only
  contract, with static deny rules still enforced by the CLI.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import focus_queue_claude as claude_harness
import focus_queue_morning as morning
import focus_queue_prompt_usage as prompt_usage
from focus_queue_lock import acquire_exclusive_file_lock


DEFAULT_RUNTIME = Path("/Users/hira/Library/Application Support/ECC Focus Queue/agent-kimi")
DEFAULT_PROOF_DIRECTORY = claude_harness.DEFAULT_PROOF_DIRECTORY
DEFAULT_MAIL_COMMAND_DIRECTORY = claude_harness.DEFAULT_MAIL_COMMAND_DIRECTORY
TRUSTED_KIMI_CANDIDATES = (
    Path.home() / ".kimi-code/bin/kimi",
    Path("/opt/homebrew/bin/kimi"),
    Path("/usr/local/bin/kimi"),
)


class KimiHarnessError(RuntimeError):
    pass


def resolve_kimi() -> str:
    for candidate in TRUSTED_KIMI_CANDIDATES:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    raise KimiHarnessError(
        "The trusted Kimi CLI is not installed at "
        + " or ".join(str(candidate) for candidate in TRUSTED_KIMI_CANDIDATES)
    )


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"version": 1, "sessions": {}}
    value = morning.load_json(path)
    if not isinstance(value.get("sessions"), dict):
        raise KimiHarnessError("Kimi Queue session state is invalid")
    return value


def newest_workspace_session(executable: str, workspace: Path) -> dict[str, Any] | None:
    """Read Kimi's local session store; never calls the model API."""
    try:
        result = subprocess.run(
            [executable, "session", "list", "--json", "--cwd", str(workspace), "--limit", "1"],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    try:
        sessions = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    if not isinstance(sessions, list) or not sessions or not isinstance(sessions[0], dict):
        return None
    return sessions[0]


def session_marker(session: dict[str, Any] | None) -> tuple[str, Any] | None:
    if session is None or not session.get("id"):
        return None
    return str(session["id"]), session.get("updatedAt")


def parse_stream_events(stdout: str) -> tuple[list[str], str | None, dict[str, Any] | None]:
    """Tolerantly collect assistant text, a session id, and usage from stream-json."""
    texts: list[str] = []
    session_id: str | None = None
    usage: dict[str, Any] | None = None
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        for key in ("session_id", "sessionId"):
            if event.get(key):
                session_id = str(event[key])
        session = event.get("session")
        if isinstance(session, dict) and session.get("id"):
            session_id = str(session["id"])
        message = event.get("message")
        candidates = [event]
        if isinstance(message, dict):
            candidates.append(message)
        for candidate in candidates:
            is_assistant = candidate.get("type") == "assistant" or candidate.get("role") == "assistant"
            content = candidate.get("content")
            if isinstance(content, str) and is_assistant:
                texts.append(content)
            elif isinstance(content, list) and (is_assistant or candidate is message):
                for part in content:
                    if isinstance(part, dict) and part.get("type") == "text" and part.get("text"):
                        texts.append(str(part["text"]))
                    elif isinstance(part, str):
                        texts.append(part)
        candidate_usage = event.get("usage")
        if isinstance(candidate_usage, dict):
            usage = candidate_usage
    return texts, session_id, usage


def parse_token_usage(stdout: str) -> dict[str, int] | None:
    _, _, usage = parse_stream_events(stdout)
    if usage is None:
        return None
    input_tokens = int(
        usage.get("input_tokens", usage.get("inputTokens", 0)) or 0
    )
    output_tokens = int(
        usage.get("output_tokens", usage.get("outputTokens", 0)) or 0
    )
    cached = usage.get("cached_input_tokens", usage.get("cachedInputTokens", 0)) or 0
    return {
        "inputTokens": input_tokens,
        "cachedInputTokens": int(cached),
        "outputTokens": output_tokens,
        "reasoningOutputTokens": int(usage.get("reasoning_output_tokens", 0) or 0),
        "totalTokens": input_tokens + output_tokens,
    }


def write_token_usage(
    path: Path, stdout: str, fallback: dict[str, int] | None = None
) -> dict[str, int] | None:
    usage = parse_token_usage(stdout) or fallback
    if usage is not None:
        morning.write_private_json(path.expanduser(), usage)
    return usage


def wire_token_usage(session: dict[str, Any] | None) -> dict[str, int] | None:
    """Kimi print mode omits usage from stream-json, so read the per-call
    `usage.record` events from the session's wire log instead."""
    directory = (session or {}).get("sessionDir")
    if not directory:
        return None
    input_tokens = cached = output_tokens = 0
    found = False
    try:
        for wire in Path(directory).glob("agents/*/wire.jsonl"):
            for line in wire.read_text(encoding="utf-8").splitlines():
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                usage = event.get("usage") if event.get("type") == "usage.record" else None
                if not isinstance(usage, dict):
                    continue
                found = True
                cached += int(usage.get("inputCacheRead", 0) or 0)
                input_tokens += int(usage.get("inputOther", 0) or 0) + int(
                    usage.get("inputCacheRead", 0) or 0
                ) + int(usage.get("inputCacheCreation", 0) or 0)
                output_tokens += int(usage.get("output", 0) or 0)
    except OSError:
        return None
    if not found:
        return None
    return {
        "inputTokens": input_tokens,
        "cachedInputTokens": cached,
        "outputTokens": output_tokens,
        "reasoningOutputTokens": 0,
        "totalTokens": input_tokens + output_tokens,
    }


# A lean chat profile keeps only the tools a chat turn needs and replaces
# Kimi's default system prompt; the default profile sent ~21k tokens of
# prompt and 27 tool schemas on every call (FOC-075).
LEAN_CHAT_AGENT = """---
name: focus-queue-chat
description: Focus Queue chat turn with shell and file tools only.
tools: Bash, Read, Edit, Write, Grep, Glob
---
You are a concise assistant running one Focus Queue chat turn on the user's Mac. Follow the instructions in the user message, reading the request by its intent rather than its literal wording. Use tools only when the message does not already answer the request, use absolute paths in shell commands, and reply briefly.
"""


def lean_chat_arguments(runtime: Path, workspace: Path) -> tuple[Path, list[str]]:
    """Working directory and flags for a lean turn: an empty directory keeps
    workspace AGENTS.md files out, an empty skills directory drops the skill
    listing, and the workspace stays reachable as an added directory."""
    lean_directory = runtime / "lean-chat"
    skills_directory = runtime / "lean-chat-skills"
    for directory in (lean_directory, skills_directory):
        directory.mkdir(mode=0o700, exist_ok=True)
    agent_file = runtime / "lean-chat-agent.md"
    if not agent_file.exists() or agent_file.read_text(encoding="utf-8") != LEAN_CHAT_AGENT:
        agent_file.write_text(LEAN_CHAT_AGENT, encoding="utf-8")
        agent_file.chmod(0o600)
    return lean_directory, [
        "--agent-file", str(agent_file),
        "--skills-dir", str(skills_directory),
        "--add-dir", str(workspace),
    ]


def write_run_diagnostic(
    runtime: Path,
    *,
    started_at: str,
    timeout: int,
    sandbox: str,
    session_id: str | None,
    stdout: str,
    stderr: str,
    return_code: int | None,
    timed_out: bool,
) -> None:
    """Keep a private, prompt-free record so harness failures are diagnosable."""
    _, observed, _ = parse_stream_events(stdout)
    payload = {
        "startedAt": started_at,
        "finishedAt": datetime.now(timezone.utc).isoformat(),
        "timeoutSeconds": timeout,
        "sandbox": sandbox,
        "resumedSession": bool(session_id),
        "observedSessionId": observed,
        "returnCode": return_code,
        "timedOut": timed_out,
        "usage": parse_token_usage(stdout),
        "stdoutBytes": len(stdout.encode("utf-8")),
        "stderrBytes": len(stderr.encode("utf-8")),
    }
    morning.write_private_json(runtime / "latest-run.json", payload)


def run_kimi(
    *,
    prompt: str,
    workspace: Path,
    runtime: Path,
    timeout: int,
    sandbox: str,
    session_id: str | None,
    output_schema: Path | None,
    usage_file: Path | None = None,
    model: str | None = None,
    expose_evidence_directories: bool = False,
    expose_queue_order: bool = False,
    disable_tools: bool = False,
    context_directory: Path | None = None,
    writable_directories: list[Path] | None = None,
    lean: bool = False,
    _retried_schema: bool = False,
) -> tuple[str, str | None]:
    if context_directory is not None:
        if not context_directory.is_absolute() or not context_directory.is_dir():
            raise KimiHarnessError("Context directory must be an absolute path to an existing directory")
        context_directory = context_directory.resolve(strict=True)
    runtime.mkdir(parents=True, exist_ok=True)
    runtime.chmod(0o700)
    started_at = datetime.now(timezone.utc).isoformat()
    if usage_file is not None:
        usage_file = usage_file.expanduser()
        usage_file.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix="turn-", dir=runtime):
        executable = resolve_kimi()
        work_directory, lean_arguments = (
            lean_chat_arguments(runtime, workspace) if lean else (workspace, [])
        )
        prior_marker = session_marker(newest_workspace_session(executable, work_directory))
        command = [
            executable,
            "--prompt",
            prompt,
            "--output-format",
            "stream-json",
            *lean_arguments,
        ]
        allow_extra_directories = sandbox == "workspace-write" and not disable_tools
        if expose_evidence_directories and allow_extra_directories:
            command.extend(
                [
                    "--add-dir",
                    str(DEFAULT_PROOF_DIRECTORY),
                    "--add-dir",
                    str(DEFAULT_MAIL_COMMAND_DIRECTORY),
                ]
            )
        if expose_queue_order and allow_extra_directories:
            support = Path(os.environ.get("FOCUS_QUEUE_SUPPORT_DIR", str(runtime.parent)))
            queue_order_directory = support / "queue-order"
            queue_order_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            command.extend(["--add-dir", str(queue_order_directory.resolve())])
        if context_directory is not None and allow_extra_directories:
            command.extend(["--add-dir", str(context_directory)])
        if writable_directories and allow_extra_directories:
            for directory in writable_directories:
                resolved = Path(directory).expanduser()
                if resolved.is_dir():
                    command.extend(["--add-dir", str(resolved.resolve())])
        if model is not None:
            command.extend(["--model", model])
        if session_id:
            command.extend(["--session", session_id])

        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
            cwd=str(work_directory),
            env={
                **os.environ,
                "FOCUS_QUEUE_CONNECTOR_PROOF_DIR": str(DEFAULT_PROOF_DIRECTORY),
            },
        )

        def terminate_child(_signum: int, _frame: Any) -> None:
            claude_harness.stop_process_group(process)
            raise SystemExit(143)

        previous_handler = signal.signal(signal.SIGTERM, terminate_child)
        stdout = ""
        stderr = ""
        try:
            try:
                stdout, stderr = process.communicate(input="", timeout=timeout)
            except subprocess.TimeoutExpired as error:
                claude_harness.stop_process_group(process)
                stdout, stderr = process.communicate()
                write_run_diagnostic(
                    runtime,
                    started_at=started_at,
                    timeout=timeout,
                    sandbox=sandbox,
                    session_id=session_id,
                    stdout=stdout,
                    stderr=stderr,
                    return_code=process.returncode,
                    timed_out=True,
                )
                if usage_file is not None:
                    write_token_usage(usage_file, stdout)
                raise KimiHarnessError(f"Kimi exceeded the {timeout}-second run budget") from error
        finally:
            signal.signal(signal.SIGTERM, previous_handler)

        write_run_diagnostic(
            runtime,
            started_at=started_at,
            timeout=timeout,
            sandbox=sandbox,
            session_id=session_id,
            stdout=stdout,
            stderr=stderr,
            return_code=process.returncode,
            timed_out=False,
        )
        latest_session = newest_workspace_session(executable, work_directory)
        turn_usage = parse_token_usage(stdout)
        if turn_usage is None and session_marker(latest_session) != prior_marker:
            turn_usage = wire_token_usage(latest_session)
        if usage_file is not None:
            write_token_usage(usage_file, stdout, turn_usage)
        if usage_file is None:
            # A caller that asks for a usage file records its own attributed event.
            prompt_usage.record_provider_usage("kimi", model, turn_usage,
                source=os.environ.get("FOCUS_QUEUE_MODEL_USAGE_SOURCE") or "provider_usage",
                run_id=os.environ.get("FOCUS_QUEUE_MODEL_USAGE_RUN_ID"),
                support=Path(os.environ["FOCUS_QUEUE_SUPPORT_DIR"]) if os.environ.get("FOCUS_QUEUE_SUPPORT_DIR") else runtime.parent)

        if process.returncode != 0:
            detail = (stderr or stdout).strip()
            raise KimiHarnessError(f"Kimi exited with code {process.returncode}: {detail[:1200]}")
        texts, observed_session, _ = parse_stream_events(stdout)
        if observed_session is None:
            latest = session_marker(latest_session)
            if latest is not None and latest != prior_marker:
                observed_session = latest[0]
            elif session_id:
                observed_session = session_id
        reply = "".join(texts).strip()
        if not reply:
            raise KimiHarnessError("Kimi returned an empty final response")
        if output_schema is not None:
            try:
                payload = claude_harness.extract_json_payload(reply)
                claude_harness.validate_payload_against_schema_file(payload, output_schema)
            except (claude_harness.ClaudeHarnessError, morning.ReconciliationError) as error:
                if _retried_schema:
                    raise KimiHarnessError(
                        f"Kimi did not satisfy the output schema after one retry: {error}"
                    ) from error
                correction = (
                    f"{prompt}\n\nYour previous reply was rejected: {error}. "
                    "Return only the JSON object required by the schema."
                )
                return run_kimi(
                    prompt=correction,
                    workspace=workspace,
                    runtime=runtime,
                    timeout=timeout,
                    sandbox=sandbox,
                    session_id=None,
                    output_schema=output_schema,
                    usage_file=usage_file,
                    model=model,
                    disable_tools=disable_tools,
                    context_directory=context_directory,
                    lean=lean,
                    _retried_schema=True,
                )
            reply = json.dumps(payload, ensure_ascii=False)
        return reply, observed_session


def fork_session(source: str, workspace: Path) -> str:
    """`kimi fork <id> -y` copies a session and exits, printing the new ID."""
    try:
        result = subprocess.run(
            [resolve_kimi(), "fork", source, "-y"],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
            cwd=str(workspace),
            stdin=subprocess.DEVNULL,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise KimiHarnessError(f"Kimi could not fork session {source}: {error}") from error
    match = re.search(r"Forked to (session_[A-Za-z0-9-]+)", result.stdout)
    if result.returncode != 0 or match is None:
        detail = (result.stderr or result.stdout).strip()
        raise KimiHarnessError(f"Kimi could not fork session {source}: {detail[:600]}")
    return match.group(1)


def chat(arguments: argparse.Namespace) -> int:
    runtime = arguments.runtime.expanduser()
    state_path = runtime / "sessions.json"
    lock_path = runtime / "sessions.lock"
    runtime.mkdir(parents=True, exist_ok=True)
    runtime.chmod(0o700)
    with lock_path.open("a+", encoding="utf-8") as lock:
        lock_path.chmod(0o600)
        acquire_exclusive_file_lock(lock)
        state = load_state(state_path)
        sessions = state.setdefault("sessions", {})
        prior_session = str(sessions.get(arguments.session, "")) or None
        fork_from = getattr(arguments, "fork_from", None)
        if prior_session is None and fork_from:
            # Save the fork before the first turn so a failed turn never forks twice.
            prior_session = fork_session(fork_from, arguments.workspace)
            sessions[arguments.session] = prior_session
            morning.write_private_json(state_path, state)
        prompt = arguments.prompt_file.read_text(encoding="utf-8")
        if getattr(arguments, "fresh", False):
            # The app sends its own short recap, so a fresh turn neither resumes
            # nor saves a session mapping whose history would grow every turn.
            reply, _ = run_kimi(
                prompt=prompt,
                workspace=arguments.workspace,
                runtime=runtime,
                timeout=arguments.timeout,
                sandbox="workspace-write",
                session_id=None,
                output_schema=None,
                usage_file=getattr(arguments, "usage_file", None),
                expose_evidence_directories=True,
                expose_queue_order=True,
                model=getattr(arguments, "model", None),
                context_directory=getattr(arguments, "context_dir", None),
                writable_directories=getattr(arguments, "writable_dirs", None),
                lean=True,
            )
            print(reply)
            return 0
        try:
            reply, observed_session = run_kimi(
                prompt=prompt,
                workspace=arguments.workspace,
                runtime=runtime,
                timeout=arguments.timeout,
                sandbox="workspace-write",
                session_id=prior_session,
                output_schema=None,
                usage_file=getattr(arguments, "usage_file", None),
                expose_evidence_directories=True,
                expose_queue_order=True,
                model=getattr(arguments, "model", None),
                context_directory=getattr(arguments, "context_dir", None),
                writable_directories=getattr(arguments, "writable_dirs", None),
            )
        except KimiHarnessError as error:
            detail = str(error).casefold()
            missing_session = prior_session and any(
                phrase in detail
                for phrase in ["not found", "unknown session", "no session", "invalid session"]
            )
            if not missing_session:
                raise
            sessions.pop(arguments.session, None)
            morning.write_private_json(state_path, state)
            reply, observed_session = run_kimi(
                prompt=prompt,
                workspace=arguments.workspace,
                runtime=runtime,
                timeout=arguments.timeout,
                sandbox="workspace-write",
                session_id=None,
                output_schema=None,
                usage_file=getattr(arguments, "usage_file", None),
                expose_evidence_directories=True,
                expose_queue_order=True,
                model=getattr(arguments, "model", None),
                context_directory=getattr(arguments, "context_dir", None),
                writable_directories=getattr(arguments, "writable_dirs", None),
            )
        session_id = observed_session or prior_session
        if not session_id:
            raise KimiHarnessError("Kimi did not return a persistent session identifier")
        sessions[arguments.session] = session_id
        morning.write_private_json(state_path, state)
        print(reply)
        return 0


def run_once(arguments: argparse.Namespace) -> int:
    prompt = arguments.prompt_file.read_text(encoding="utf-8")
    reply, _ = run_kimi(
        prompt=prompt,
        workspace=arguments.workspace,
        runtime=arguments.runtime.expanduser(),
        timeout=arguments.timeout,
        sandbox=arguments.sandbox,
        session_id=None,
        output_schema=arguments.output_schema,
        usage_file=arguments.usage_file,
        disable_tools=arguments.disable_tools,
        model=getattr(arguments, "model", None),
        context_directory=getattr(arguments, "context_dir", None),
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
    chat_parser.add_argument("--fresh", action="store_true",
                             help="Run a one-off turn without resuming or saving a session")
    chat_parser.add_argument("--workspace", type=Path, required=True)
    chat_parser.add_argument("--context-dir", type=Path)
    chat_parser.add_argument(
        "--writable-dir",
        dest="writable_dirs",
        type=Path,
        action="append",
        default=[],
        help="Extra directory the chat sandbox may write (repeatable)",
    )
    chat_parser.add_argument("--prompt-file", type=Path, required=True)
    chat_parser.add_argument("--usage-file", type=Path)
    chat_parser.add_argument("--timeout", type=int, default=120)
    chat_parser.add_argument("--model", help="Override the chat model alias")
    chat_parser.add_argument(
        "--effort",
        help="Accepted for contract parity; Kimi has no effort flag and drops it",
    )
    chat_parser.add_argument(
        "--fork-from",
        help="Start a session with no saved conversation as a fork of this provider session",
    )

    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--workspace", type=Path, required=True)
    run_parser.add_argument("--context-dir", type=Path)
    run_parser.add_argument("--prompt-file", type=Path, required=True)
    run_parser.add_argument("--timeout", type=int, default=120)
    run_parser.add_argument("--sandbox", choices=["read-only", "workspace-write"], default="read-only")
    run_parser.add_argument("--output-schema", type=Path)
    run_parser.add_argument("--usage-file", type=Path)
    run_parser.add_argument("--disable-tools", action="store_true")
    run_parser.add_argument("--model", help="Override the model alias")
    run_parser.add_argument(
        "--effort",
        help="Accepted for contract parity; Kimi has no effort flag and drops it",
    )
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
        print(f"Kimi Queue harness failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
