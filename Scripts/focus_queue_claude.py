#!/usr/bin/env python3
"""Bounded local Claude harness for Focus Queue."""

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
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import focus_queue_morning as morning
import focus_queue_prompt_usage as prompt_usage
from focus_queue_lock import acquire_exclusive_file_lock


DEFAULT_RUNTIME = Path("/Users/hira/Library/Application Support/ECC Focus Queue/agent-claude")
DEFAULT_PROOF_DIRECTORY = Path(
    "/Users/hira/Library/Application Support/ECC Focus Queue/connector-proofs"
)
DEFAULT_MAIL_COMMAND_DIRECTORY = Path(
    "/Users/hira/Library/Application Support/ECC Focus Queue/connector-commands"
)
# Chat turns need shell, file reads, and plan edits only. Agent, Workflow,
# skills, and MCP schemas added ~15.7k tokens to every API call (FOC-075).
LEAN_CHAT_TOOLS = "Bash,Read,Edit,Write,Grep,Glob"
TRUSTED_CLAUDE_CANDIDATES = (
    Path("/Users/hira/.local/bin/claude"),
    Path("/opt/homebrew/bin/claude"),
    Path("/usr/local/bin/claude"),
)


class ClaudeHarnessError(RuntimeError):
    pass


def stop_process_group(process: subprocess.Popen[str], *, grace_seconds: float = 2.0) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        process.terminate()
    else:
        os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            process.kill()
        else:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def resolve_claude() -> str:
    for candidate in TRUSTED_CLAUDE_CANDIDATES:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    raise ClaudeHarnessError(
        "The trusted Claude CLI is not installed at "
        + " or ".join(str(candidate) for candidate in TRUSTED_CLAUDE_CANDIDATES)
    )


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"version": 1, "sessions": {}}
    value = morning.load_json(path)
    if not isinstance(value.get("sessions"), dict):
        raise ClaudeHarnessError("Claude Queue session state is invalid")
    return value


def parse_envelope(stdout: str) -> dict[str, Any]:
    stripped = stdout.strip()
    try:
        value = json.loads(stripped)
    except json.JSONDecodeError:
        start, end = stripped.find("{"), stripped.rfind("}")
        if start < 0 or end <= start:
            raise ClaudeHarnessError("Claude did not return a JSON result envelope")
        try:
            value = json.loads(stripped[start : end + 1])
        except json.JSONDecodeError as error:
            raise ClaudeHarnessError("Claude did not return a JSON result envelope") from error
    if not isinstance(value, dict) or "session_id" not in value:
        raise ClaudeHarnessError("Claude returned an unrecognized result envelope")
    return value


def parse_token_usage(stdout: str) -> dict[str, int] | None:
    try:
        envelope = parse_envelope(stdout)
    except ClaudeHarnessError:
        return None
    usage = envelope.get("usage")
    if not isinstance(usage, dict):
        return None
    input_tokens = int(usage.get("input_tokens", 0) or 0)
    output_tokens = int(usage.get("output_tokens", 0) or 0)
    return {
        "inputTokens": input_tokens,
        # Claude's input_tokens excludes cache reads and writes; analytics adds them back.
        "cachedInputTokens": int(usage.get("cache_read_input_tokens", 0) or 0)
        + int(usage.get("cache_creation_input_tokens", 0) or 0),
        "outputTokens": output_tokens,
        "reasoningOutputTokens": 0,
        "totalTokens": input_tokens + output_tokens,
    }


def write_token_usage(path: Path, stdout: str) -> dict[str, int] | None:
    usage = parse_token_usage(stdout)
    if usage is not None:
        morning.write_private_json(path.expanduser(), usage)
    return usage


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
    try:
        observed = str(parse_envelope(stdout).get("session_id") or "") or None
    except ClaudeHarnessError:
        observed = None
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


def extract_json_payload(text: str) -> dict[str, Any]:
    stripped = text.strip()
    candidates = [stripped]
    fenced = re.search(r"```(?:json)?\s*(\{.*\})\s*```", stripped, re.DOTALL)
    if fenced:
        candidates.append(fenced.group(1))
    start, end = stripped.find("{"), stripped.rfind("}")
    if start >= 0 and end > start:
        candidates.append(stripped[start : end + 1])
    for candidate in candidates:
        try:
            value = json.loads(candidate)
            if isinstance(value, dict):
                return value
        except json.JSONDecodeError:
            continue
    raise ClaudeHarnessError("The agent did not return a JSON object")


def validate_against_schema(
    value: Any,
    schema: dict[str, Any],
    *,
    definitions: dict[str, Any] | None = None,
    path: str = "$",
) -> None:
    """Structural check for the JSON-schema subset Focus Queue schemas use."""
    ref = schema.get("$ref")
    if isinstance(ref, str):
        prefix = "#/$defs/"
        if not ref.startswith(prefix) or definitions is None or ref[len(prefix):] not in definitions:
            raise ClaudeHarnessError(f"Unsupported schema reference {ref} at {path}")
        validate_against_schema(value, definitions[ref[len(prefix):]], definitions=definitions, path=path)
        return
    if "const" in schema and value != schema["const"]:
        raise ClaudeHarnessError(f"Schema mismatch at {path}: expected constant {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        raise ClaudeHarnessError(f"Schema mismatch at {path}: {value!r} is not an allowed value")
    expected = schema.get("type")
    expected_types = expected if isinstance(expected, list) else [expected] if expected else []
    type_checks = {
        "object": lambda item: isinstance(item, dict),
        "array": lambda item: isinstance(item, list),
        "string": lambda item: isinstance(item, str),
        "integer": lambda item: isinstance(item, int) and not isinstance(item, bool),
        "number": lambda item: isinstance(item, (int, float)) and not isinstance(item, bool),
        "boolean": lambda item: isinstance(item, bool),
        "null": lambda item: item is None,
    }
    if expected_types and not any(type_checks[name](value) for name in expected_types if name in type_checks):
        raise ClaudeHarnessError(
            f"Schema mismatch at {path}: expected type {expected_types}, got {type(value).__name__}"
        )
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                raise ClaudeHarnessError(f"Schema mismatch at {path}: missing required key {key!r}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            unknown = sorted(str(key) for key in value if key not in properties)
            if unknown:
                raise ClaudeHarnessError(
                    f"Schema mismatch at {path}: unexpected keys {', '.join(unknown)}"
                )
        for key, subschema in properties.items():
            if key in value and isinstance(subschema, dict):
                validate_against_schema(
                    value[key], subschema, definitions=definitions, path=f"{path}.{key}"
                )
    if isinstance(value, list):
        if "minItems" in schema and len(value) < int(schema["minItems"]):
            raise ClaudeHarnessError(f"Schema mismatch at {path}: fewer than {schema['minItems']} items")
        if "maxItems" in schema and len(value) > int(schema["maxItems"]):
            raise ClaudeHarnessError(f"Schema mismatch at {path}: more than {schema['maxItems']} items")
        items = schema.get("items")
        if isinstance(items, dict):
            for index, item in enumerate(value):
                validate_against_schema(item, items, definitions=definitions, path=f"{path}[{index}]")
    if isinstance(value, str):
        if "minLength" in schema and len(value) < int(schema["minLength"]):
            raise ClaudeHarnessError(f"Schema mismatch at {path}: shorter than {schema['minLength']}")
        if "maxLength" in schema and len(value) > int(schema["maxLength"]):
            raise ClaudeHarnessError(f"Schema mismatch at {path}: longer than {schema['maxLength']}")
        pattern = schema.get("pattern")
        if isinstance(pattern, str) and re.fullmatch(pattern, value) is None:
            raise ClaudeHarnessError(f"Schema mismatch at {path}: does not match {pattern}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            raise ClaudeHarnessError(f"Schema mismatch at {path}: below minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            raise ClaudeHarnessError(f"Schema mismatch at {path}: above maximum {schema['maximum']}")


def validate_payload_against_schema_file(payload: dict[str, Any], schema_path: Path) -> None:
    schema = morning.load_json(schema_path)
    definitions = schema.get("$defs")
    validate_against_schema(
        payload,
        schema,
        definitions=definitions if isinstance(definitions, dict) else None,
    )


def run_claude(
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
    fork_session: bool = False,
    lean: bool = False,
    persist_session: bool = True,
    _retried_schema: bool = False,
) -> tuple[str, str | None]:
    if context_directory is not None:
        if not context_directory.is_absolute() or not context_directory.is_dir():
            raise ClaudeHarnessError("Context directory must be an absolute path to an existing directory")
        context_directory = context_directory.resolve(strict=True)
    runtime.mkdir(parents=True, exist_ok=True)
    runtime.chmod(0o700)
    started_at = datetime.now(timezone.utc).isoformat()
    if usage_file is not None:
        usage_file = usage_file.expanduser()
        usage_file.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix="turn-", dir=runtime) as turn_directory:
        executable = resolve_claude()
        command = [
            executable,
            "-p",
            "--output-format",
            "json",
        ]
        if disable_tools:
            # `claude --help`: --tools "" disables every built-in tool; this is
            # how a read-only sandbox is approximated for the daily sweep.
            command.extend(["--tools", ""])
        else:
            command.extend(["--permission-mode", "bypassPermissions"])
            if lean:
                command.extend([
                    "--tools", LEAN_CHAT_TOOLS, "--strict-mcp-config", "--disable-slash-commands",
                ])
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
        if lean:
            # A lean turn runs from its empty turn directory so Claude does not
            # auto-load CLAUDE.md files above the workspace (~5.7k tokens);
            # the workspace stays reachable as an added directory.
            command.extend(["--add-dir", str(workspace)])
        if model is not None:
            command.extend(["--model", model])
        if effort is not None:
            command.extend(["--effort", effort])
        if not persist_session:
            command.append("--no-session-persistence")
        elif session_id:
            command.extend(["--resume", session_id])
            if fork_session:
                # The source conversation stays untouched; the reply arrives
                # in a new session that later turns resume.
                command.append("--fork-session")

        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
            cwd=turn_directory if lean else str(workspace),
            env={
                **os.environ,
                "FOCUS_QUEUE_CONNECTOR_PROOF_DIR": str(DEFAULT_PROOF_DIRECTORY),
            },
        )

        def terminate_child(_signum: int, _frame: Any) -> None:
            stop_process_group(process)
            raise SystemExit(143)

        previous_handler = signal.signal(signal.SIGTERM, terminate_child)
        stdout = ""
        stderr = ""
        try:
            try:
                stdout, stderr = process.communicate(input=prompt, timeout=timeout)
            except subprocess.TimeoutExpired as error:
                stop_process_group(process)
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
                raise ClaudeHarnessError(f"Claude exceeded the {timeout}-second run budget") from error
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
        if usage_file is not None:
            write_token_usage(usage_file, stdout)
        if usage_file is None:
            # A caller that asks for a usage file records its own attributed event.
            prompt_usage.record_provider_usage("claude", model, parse_token_usage(stdout),
                source=os.environ.get("FOCUS_QUEUE_MODEL_USAGE_SOURCE") or "provider_usage",
                run_id=os.environ.get("FOCUS_QUEUE_MODEL_USAGE_RUN_ID"),
                support=Path(os.environ["FOCUS_QUEUE_SUPPORT_DIR"]) if os.environ.get("FOCUS_QUEUE_SUPPORT_DIR") else runtime.parent)

        if process.returncode != 0:
            detail = (stderr or stdout).strip()
            raise ClaudeHarnessError(f"Claude exited with code {process.returncode}: {detail[:1200]}")
        envelope = parse_envelope(stdout)
        if envelope.get("is_error"):
            detail = str(envelope.get("result") or "unknown error").strip()
            raise ClaudeHarnessError(f"Claude reported an error: {detail[:1200]}")
        reply = str(envelope.get("result") or "").strip()
        if not reply:
            raise ClaudeHarnessError("Claude returned an empty final response")
        if output_schema is not None:
            try:
                payload = extract_json_payload(reply)
                validate_payload_against_schema_file(payload, output_schema)
            except (ClaudeHarnessError, morning.ReconciliationError) as error:
                if _retried_schema:
                    raise ClaudeHarnessError(
                        f"Claude did not satisfy the output schema after one retry: {error}"
                    ) from error
                correction = (
                    f"{prompt}\n\nYour previous reply was rejected: {error}. "
                    "Return only the JSON object required by the schema."
                )
                return run_claude(
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
                    persist_session=persist_session,
                    _retried_schema=True,
                )
            reply = json.dumps(payload, ensure_ascii=False)
        return reply, str(envelope.get("session_id") or "") or None


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
        if getattr(arguments, "fresh", False):
            # The app sends its own short recap, so a fresh turn neither resumes
            # nor saves a provider session whose history would grow every turn.
            reply, _ = run_claude(
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
                effort=getattr(arguments, "effort", None),
                context_directory=getattr(arguments, "context_dir", None),
                writable_directories=getattr(arguments, "writable_dirs", None),
                lean=True,
                persist_session=False,
            )
            print(reply)
            return 0
        try:
            reply, observed_session = run_claude(
                prompt=prompt,
                workspace=arguments.workspace,
                runtime=runtime,
                timeout=arguments.timeout,
                sandbox="workspace-write",
                session_id=prior_session or fork_from,
                fork_session=fork_from is not None,
                output_schema=None,
                usage_file=getattr(arguments, "usage_file", None),
                expose_evidence_directories=True,
                expose_queue_order=True,
                model=getattr(arguments, "model", None),
                effort=getattr(arguments, "effort", None),
                context_directory=getattr(arguments, "context_dir", None),
                writable_directories=getattr(arguments, "writable_dirs", None),
            )
        except ClaudeHarnessError as error:
            detail = str(error).casefold()
            missing_session = prior_session and any(
                phrase in detail
                for phrase in ["no conversation found", "not found", "unknown session", "invalid session"]
            )
            if not missing_session:
                raise
            sessions.pop(arguments.session, None)
            morning.write_private_json(state_path, state)
            reply, observed_session = run_claude(
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
                effort=getattr(arguments, "effort", None),
                context_directory=getattr(arguments, "context_dir", None),
                writable_directories=getattr(arguments, "writable_dirs", None),
            )
        session_id = observed_session or prior_session
        if not session_id or session_id == fork_from:
            raise ClaudeHarnessError("Claude did not return a persistent session identifier")
        sessions[arguments.session] = session_id
        morning.write_private_json(state_path, state)
        print(reply)
        return 0


def run_once(arguments: argparse.Namespace) -> int:
    prompt = arguments.prompt_file.read_text(encoding="utf-8")
    reply, _ = run_claude(
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
    """Delete Claude's saved transcript for one session so a cleared chat
    leaves no resumable history behind."""
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", session_id):
        return 0
    config = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude").expanduser()
    removed = 0
    for transcript in (config / "projects").glob(f"*/{session_id}.jsonl"):
        transcript.unlink(missing_ok=True)
        removed += 1
        sidecar = transcript.with_suffix("")
        if sidecar.is_dir() and not sidecar.is_symlink():
            shutil.rmtree(sidecar, ignore_errors=True)
    return removed


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
    chat_parser.add_argument("--timeout", type=int, default=120)
    chat_parser.add_argument("--model", help="Override the chat model slug")
    chat_parser.add_argument("--effort", help="Override the chat effort level")
    chat_parser.add_argument(
        "--fork-from",
        help="Start a session with no saved conversation as a fork of this provider session",
    )
    chat_parser.add_argument("--fresh", action="store_true",
                             help="Run a lean one-off turn without resuming or saving a session")

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
    if not (10 <= getattr(arguments, "timeout", 120) <= 900):
        parser.error("timeout must be between 10 and 900 seconds")
    try:
        if arguments.command == "chat":
            return chat(arguments)
        if arguments.command == "run":
            return run_once(arguments)
        return reset(arguments)
    except Exception as error:
        print(f"Claude Queue harness failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
