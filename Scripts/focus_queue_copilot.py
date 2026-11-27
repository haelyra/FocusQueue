#!/usr/bin/env python3
"""Bounded local Copilot harness for Focus Queue.

GitHub Copilot CLI notes (verified against copilot-cli 1.0.116 on this machine):
- Non-interactive mode is `copilot -p <text>`; the prompt is an argument, not
  stdin. `-s` prints only the agent response, which is the harness reply.
- A new session gets its UUID up front with `--session-id <uuid>`; a saved
  conversation resumes with `--resume <uuid>`. Sessions live under
  `~/.copilot/session-state/<uuid>/` (`$COPILOT_HOME` overrides `~/.copilot`).
- `--allow-all` grants tools, paths, and URLs without confirmation, matching
  the other harnesses' permission bypass; without it, non-interactive mode
  denies unapproved tool requests, which is the `ask` permission mode.
- `--usage-output-file` writes token usage as JSON when the session ends.
- `--available-tools` with no names turns off every tool; a name list is the
  lean chat, reader, and editor tool set.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import focus_queue_claude as claude_harness
import focus_queue_morning as morning
import focus_queue_prompt_usage as prompt_usage
from focus_queue_lock import acquire_exclusive_file_lock, release_file_lock
from focus_queue_provider_cli import find_cli


DEFAULT_RUNTIME = claude_harness.SUPPORT_DIRECTORY / "agent-copilot"
DEFAULT_PROOF_DIRECTORY = claude_harness.DEFAULT_PROOF_DIRECTORY
DEFAULT_MAIL_COMMAND_DIRECTORY = claude_harness.DEFAULT_MAIL_COMMAND_DIRECTORY
TRUSTED_COPILOT_CANDIDATES = (
    Path.home() / ".local/bin/copilot",
    Path("/opt/homebrew/bin/copilot"),
    Path("/usr/local/bin/copilot"),
)
# Copilot's own tool names, from `session.tool_baseline` events.
LEAN_CHAT_TOOLS = "bash,view,edit,create,grep,glob"
READ_ONLY_TOOLS = "view,grep,glob"
READER_TOOLS = "view,grep,glob,web_fetch,web_search"
# A document edit is one tool-free reply that the app applies (FOC-097); the
# instruction replaces Claude's `--system-prompt`, which Copilot lacks.
EDITOR_INSTRUCTION = "You edit one document. Follow the user message and reply only in the format it asks for."
TOOL_FREE_INSTRUCTION = (
    "You answer one request using only the text in this message. You have no tools, "
    "so never claim to have run commands, read files, or changed anything. "
    "Follow the user message and reply only in the format it asks for."
)


class CopilotHarnessError(RuntimeError):
    pass


def resolve_copilot() -> str:
    executable = find_cli("copilot", TRUSTED_COPILOT_CANDIDATES)
    if executable:
        return executable
    raise CopilotHarnessError(
        "The Copilot CLI was not found at "
        + " or ".join(str(candidate) for candidate in TRUSTED_COPILOT_CANDIDATES)
        + " or on your shell's PATH"
    )


def copilot_home() -> Path:
    return Path(os.environ.get("COPILOT_HOME") or Path.home() / ".copilot").expanduser()


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"version": 1, "sessions": {}}
    value = morning.load_json(path)
    if not isinstance(value.get("sessions"), dict):
        raise CopilotHarnessError("Copilot Queue session state is invalid")
    return value


def parse_usage_file(path: Path) -> dict[str, int] | None:
    """Map `--usage-output-file` JSON to the shared usage shape."""
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(value, dict):
        return None
    details = value.get("tokenDetails")
    if isinstance(details, dict):
        def count(key: str) -> int:
            entry = details.get(key)
            return int(entry.get("tokenCount", 0) or 0) if isinstance(entry, dict) else 0
        input_tokens = count("input")
        cached = count("cache_read") + count("cache_write")
        output_tokens = count("output")
        return {
            "inputTokens": input_tokens,
            "cachedInputTokens": cached,
            "outputTokens": output_tokens,
            "reasoningOutputTokens": 0,
            "totalTokens": input_tokens + output_tokens,
        }
    metrics = value.get("modelMetrics")
    if isinstance(metrics, dict) and metrics:
        input_tokens = cached = output_tokens = reasoning = 0
        for entry in metrics.values():
            if not isinstance(entry, dict) or not isinstance(entry.get("usage"), dict):
                continue
            usage = entry["usage"]
            cache_read = int(usage.get("cacheReadTokens", 0) or 0)
            cache_write = int(usage.get("cacheWriteTokens", 0) or 0)
            input_tokens += int(usage.get("inputTokens", 0) or 0) - cache_read - cache_write
            cached += cache_read + cache_write
            output_tokens += int(usage.get("outputTokens", 0) or 0)
            reasoning += int(usage.get("reasoningTokens", 0) or 0)
        return {
            "inputTokens": max(0, input_tokens),
            "cachedInputTokens": cached,
            "outputTokens": output_tokens,
            "reasoningOutputTokens": reasoning,
            "totalTokens": max(0, input_tokens) + output_tokens,
        }
    return None


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
    payload = {
        "startedAt": started_at,
        "finishedAt": datetime.now(timezone.utc).isoformat(),
        "timeoutSeconds": timeout,
        "sandbox": sandbox,
        "resumedSession": bool(session_id),
        "observedSessionId": session_id,
        "returnCode": return_code,
        "timedOut": timed_out,
        "stdoutBytes": len(stdout.encode("utf-8")),
        "stderrBytes": len(stderr.encode("utf-8")),
    }
    morning.write_private_json(runtime / "latest-run.json", payload)


def tool_arguments(tools: str) -> list[str]:
    """`--available-tools` with no names turns every tool off; a list is an allowlist."""
    return ["--available-tools", *[name for name in tools.split(",") if name]]


def run_copilot(
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
    effort: str | None = None,
    expose_evidence_directories: bool = False,
    expose_queue_order: bool = False,
    disable_tools: bool = False,
    context_directory: Path | None = None,
    writable_directories: list[Path] | None = None,
    lean: bool = False,
    reader: bool = False,
    editor: bool = False,
    bypass_permissions: bool = True,
    _retried_schema: bool = False,
) -> tuple[str, str | None]:
    if context_directory is not None:
        if not context_directory.is_absolute() or not context_directory.is_dir():
            raise CopilotHarnessError("Context directory must be an absolute path to an existing directory")
        context_directory = context_directory.resolve(strict=True)
    runtime.mkdir(parents=True, exist_ok=True)
    runtime.chmod(0o700)
    started_at = datetime.now(timezone.utc).isoformat()
    if usage_file is not None:
        usage_file = usage_file.expanduser()
        usage_file.unlink(missing_ok=True)
    lean_directory = runtime / "lean-chat"
    if lean:
        lean_directory.mkdir(mode=0o700, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="turn-", dir=runtime) as turn_directory:
        executable = resolve_copilot()
        usage_output = Path(turn_directory) / "usage.json"
        # A resumed session keeps its UUID; a new one is named up front so the
        # harness never parses the CLI's output for an identity.
        observed_session = session_id or str(uuid.uuid4())
        text = prompt
        if editor:
            text = f"{EDITOR_INSTRUCTION}\n\n{prompt}"
        elif disable_tools:
            text = f"{TOOL_FREE_INSTRUCTION}\n\n{prompt}"
        command = [executable, "-p", text, "-s", "--no-color", "--usage-output-file", str(usage_output)]
        if session_id:
            command.extend(["--resume", session_id])
        else:
            command.extend(["--session-id", observed_session])
        if disable_tools or editor:
            command.extend(tool_arguments(""))
        elif reader:
            command.extend(tool_arguments(READER_TOOLS))
        elif lean:
            command.extend(tool_arguments(LEAN_CHAT_TOOLS if bypass_permissions else READ_ONLY_TOOLS))
        if editor or reader or disable_tools or lean:
            # Lean turns keep workspace AGENTS.md and user skills out, matching
            # the other harnesses' stripped-down chat profiles (FOC-075).
            command.append("--no-custom-instructions")
        if bypass_permissions:
            command.append("--allow-all")
        elif sandbox == "read-only":
            command.extend(["--deny-tool", "write"])
        if expose_evidence_directories:
            command.extend(["--add-dir", str(DEFAULT_PROOF_DIRECTORY),
                            "--add-dir", str(DEFAULT_MAIL_COMMAND_DIRECTORY)])
        if expose_queue_order:
            support = Path(os.environ.get("FOCUS_QUEUE_SUPPORT_DIR", str(runtime.parent)))
            queue_order_directory = support / "queue-order"
            queue_order_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            command.extend(["--add-dir", str(queue_order_directory.resolve())])
        if context_directory is not None:
            command.extend(["--add-dir", str(context_directory)])
        if writable_directories:
            for directory in writable_directories:
                resolved = Path(directory).expanduser()
                if resolved.is_dir():
                    command.extend(["--add-dir", str(resolved.resolve())])
        if lean and not editor:
            command.extend(["--add-dir", str(workspace)])
        if model is not None:
            command.extend(["--model", model])
        if effort is not None:
            command.extend(["--reasoning-effort", effort])

        if os.environ.get("FOCUS_QUEUE_COPILOT_DEBUG"):
            print("copilot harness command:", command, file=sys.stderr)
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
            cwd=str(lean_directory) if lean else str(workspace),
            env={
                **os.environ,
                "FOCUS_QUEUE_CONNECTOR_PROOF_DIR": str(DEFAULT_PROOF_DIRECTORY),
            },
        )

        def terminate_child(_signum: int, _frame: Any) -> None:
            claude_harness.stop_process_group(process)
            raise SystemExit(143)

        previous_handler = signal.signal(signal.SIGTERM, terminate_child)
        # Closing the QChat tmux window hangs up the harness; stop the provider too.
        previous_hangup = signal.signal(signal.SIGHUP, terminate_child)
        stdout = ""
        stderr = ""
        try:
            try:
                stdout, stderr = process.communicate(timeout=timeout or None)
            except subprocess.TimeoutExpired as error:
                claude_harness.stop_process_group(process)
                stdout, stderr = process.communicate()
                write_run_diagnostic(
                    runtime, started_at=started_at, timeout=timeout, sandbox=sandbox,
                    session_id=session_id, stdout=stdout, stderr=stderr,
                    return_code=process.returncode, timed_out=True,
                )
                if usage_file is not None:
                    write_token_usage(usage_file, usage_output)
                raise CopilotHarnessError(f"Copilot exceeded the {timeout}-second run budget") from error
        finally:
            signal.signal(signal.SIGTERM, previous_handler)
            signal.signal(signal.SIGHUP, previous_hangup)

        write_run_diagnostic(
            runtime, started_at=started_at, timeout=timeout, sandbox=sandbox,
            session_id=session_id, stdout=stdout, stderr=stderr,
            return_code=process.returncode, timed_out=False,
        )
        usage = write_token_usage(usage_file, usage_output) if usage_file is not None else None
        if usage_file is None:
            # A caller that asks for a usage file records its own attributed event.
            prompt_usage.record_provider_usage("copilot", model, usage or parse_usage_file(usage_output),
                source=os.environ.get("FOCUS_QUEUE_MODEL_USAGE_SOURCE") or "provider_usage",
                run_id=os.environ.get("FOCUS_QUEUE_MODEL_USAGE_RUN_ID"),
                support=Path(os.environ["FOCUS_QUEUE_SUPPORT_DIR"]) if os.environ.get("FOCUS_QUEUE_SUPPORT_DIR") else runtime.parent)

        if process.returncode != 0:
            detail = (stderr or stdout).strip()
            raise CopilotHarnessError(f"Copilot exited with code {process.returncode}: {detail[:1200]}")
        reply = stdout.strip()
        if not reply:
            raise CopilotHarnessError("Copilot returned an empty final response")
        if output_schema is not None:
            try:
                payload = claude_harness.extract_json_payload(reply)
                claude_harness.validate_payload_against_schema_file(payload, output_schema)
            except (claude_harness.ClaudeHarnessError, morning.ReconciliationError) as error:
                if _retried_schema:
                    raise CopilotHarnessError(
                        f"Copilot did not satisfy the output schema after one retry: {error}"
                    ) from error
                correction = (
                    f"{prompt}\n\nYour previous reply was rejected: {error}. "
                    "Return only the JSON object required by the schema."
                )
                return run_copilot(
                    prompt=correction,
                    workspace=workspace,
                    runtime=runtime,
                    timeout=timeout,
                    sandbox=sandbox,
                    session_id=None,
                    output_schema=output_schema,
                    usage_file=usage_file,
                    model=model,
                    effort=effort,
                    disable_tools=disable_tools,
                    context_directory=context_directory,
                    lean=lean,
                    reader=reader,
                    editor=editor,
                    bypass_permissions=bypass_permissions,
                    _retried_schema=True,
                )
            reply = json.dumps(payload, ensure_ascii=False)
        return reply, observed_session


def write_token_usage(path: Path, usage_output: Path) -> dict[str, int] | None:
    usage = parse_usage_file(usage_output)
    if usage is not None:
        morning.write_private_json(path.expanduser(), usage)
    return usage


def bypass_permissions(arguments: argparse.Namespace) -> bool:
    """`chat --permissions ask` turns Focus Queue's permission bypass off (FOC-119)."""
    return getattr(arguments, "permissions", "bypass") != "ask"


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
        fork_from = None if prior_session else getattr(arguments, "fork_from", None)
        prompt = arguments.prompt_file.read_text(encoding="utf-8")
        reader = getattr(arguments, "reader", False)
        editor = getattr(arguments, "editor", False)
        if reader or editor or getattr(arguments, "fresh", False):
            # A fresh turn never reads or writes sessions.json, so it releases the
            # lock and parallel QChat tabs run concurrently instead of queueing.
            release_file_lock(lock)
            # The app sends its own short recap, so a fresh turn neither resumes
            # nor saves a provider session whose history would grow every turn.
            reply, _ = run_copilot(
                prompt=prompt,
                bypass_permissions=bypass_permissions(arguments),
                workspace=arguments.workspace,
                runtime=runtime,
                timeout=arguments.timeout,
                sandbox="read-only" if reader or editor else "workspace-write",
                session_id=None,
                output_schema=None,
                usage_file=getattr(arguments, "usage_file", None),
                expose_evidence_directories=True,
                expose_queue_order=True,
                model=getattr(arguments, "model", None),
                effort=getattr(arguments, "effort", None),
                context_directory=getattr(arguments, "context_dir", None),
                writable_directories=getattr(arguments, "writable_dirs", None),
                lean=True,
                reader=reader,
                editor=editor,
            )
            print(reply)
            return 0
        try:
            reply, observed_session = run_copilot(
                prompt=prompt,
                bypass_permissions=bypass_permissions(arguments),
                workspace=arguments.workspace,
                runtime=runtime,
                timeout=arguments.timeout,
                sandbox="workspace-write",
                session_id=prior_session or fork_from,
                output_schema=None,
                usage_file=getattr(arguments, "usage_file", None),
                expose_evidence_directories=True,
                expose_queue_order=True,
                model=getattr(arguments, "model", None),
                effort=getattr(arguments, "effort", None),
                context_directory=getattr(arguments, "context_dir", None),
                writable_directories=getattr(arguments, "writable_dirs", None),
            )
        except CopilotHarnessError as error:
            detail = str(error).casefold()
            missing_session = prior_session and any(
                phrase in detail
                for phrase in ["no conversation found", "not found", "unknown session",
                               "invalid session", "failed to resume"]
            )
            if not missing_session:
                raise
            sessions.pop(arguments.session, None)
            morning.write_private_json(state_path, state)
            reply, observed_session = run_copilot(
                prompt=prompt,
                bypass_permissions=bypass_permissions(arguments),
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
                effort=getattr(arguments, "effort", None),
                context_directory=getattr(arguments, "context_dir", None),
                writable_directories=getattr(arguments, "writable_dirs", None),
            )
        # A fork continues the source conversation: no new identity exists.
        session_id = fork_from if fork_from else (observed_session or prior_session)
        if not session_id:
            raise CopilotHarnessError("Copilot did not return a persistent session identifier")
        sessions[arguments.session] = session_id
        morning.write_private_json(state_path, state)
        print(reply)
        return 0


def run_once(arguments: argparse.Namespace) -> int:
    prompt = arguments.prompt_file.read_text(encoding="utf-8")
    reply, _ = run_copilot(
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
        effort=getattr(arguments, "effort", None),
        context_directory=getattr(arguments, "context_dir", None),
    )
    print(reply)
    return 0


def remove_session_transcripts(session_id: str) -> int:
    """Delete Copilot's saved session state so a cleared chat leaves no
    resumable history behind."""
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", session_id):
        return 0
    directory = copilot_home() / "session-state" / session_id.lower()
    if not directory.is_dir() or directory.is_symlink():
        return 0
    shutil.rmtree(directory, ignore_errors=True)
    return 1


def reset(arguments: argparse.Namespace) -> int:
    runtime = arguments.runtime.expanduser()
    state_path = runtime / "sessions.json"
    state = load_state(state_path)
    removed = state.setdefault("sessions", {}).pop(arguments.session, None)
    morning.write_private_json(state_path, state)
    transcripts = remove_session_transcripts(str(removed)) if removed else 0
    print(json.dumps({"status": "ok", "session": arguments.session, "reset": bool(removed),
                      "transcriptsRemoved": transcripts}))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, default=DEFAULT_RUNTIME)
    subparsers = parser.add_subparsers(dest="command", required=True)

    chat_parser = subparsers.add_parser("chat")
    chat_parser.add_argument("--permissions", choices=["bypass", "ask"], default="bypass",
                             help="ask: run without Focus Queue's permission bypass")
    chat_parser.add_argument("--session", required=True)
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
    chat_parser.add_argument("--timeout", type=int, default=120,
                             help="Run budget in seconds; 0 runs until the provider finishes")
    chat_parser.add_argument("--model", help="Override the chat model slug")
    chat_parser.add_argument("--effort", help="Override the chat effort level")
    chat_parser.add_argument(
        "--fork-from",
        help="Start a session with no saved conversation as a continuation of this provider session",
    )
    chat_parser.add_argument("--fresh", action="store_true",
                             help="Run a lean one-off turn without resuming or saving a session")
    chat_parser.add_argument("--editor", action="store_true",
                             help="Run one tool-free document edit; the app applies the reply")
    chat_parser.add_argument("--reader", action="store_true",
                             help="Run an ephemeral document question with read/search tools")

    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--workspace", type=Path, required=True)
    run_parser.add_argument("--context-dir", type=Path)
    run_parser.add_argument("--prompt-file", type=Path, required=True)
    run_parser.add_argument("--timeout", type=int, default=120)
    run_parser.add_argument("--sandbox", choices=["read-only", "workspace-write"], default="read-only")
    run_parser.add_argument("--output-schema", type=Path)
    run_parser.add_argument("--usage-file", type=Path)
    run_parser.add_argument("--disable-tools", action="store_true")
    run_parser.add_argument("--model", help="Override the model slug")
    run_parser.add_argument("--effort", help="Override the effort level")
    run_parser.add_argument("--label")

    reset_parser = subparsers.add_parser("reset")
    reset_parser.add_argument("--session", required=True)
    arguments = parser.parse_args()
    timeout = getattr(arguments, "timeout", 120)
    if not (timeout == 0 or 10 <= timeout <= 900):
        parser.error("timeout must be 0 (no limit) or between 10 and 900 seconds")
    try:
        if arguments.command == "chat":
            return chat(arguments)
        if arguments.command == "run":
            return run_once(arguments)
        return reset(arguments)
    except Exception as error:
        print(f"Copilot Queue harness failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
