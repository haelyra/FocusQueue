#!/usr/bin/env python3
"""Bounded local Codex harness for Focus Queue."""

from __future__ import annotations

import argparse
import http.server
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import focus_queue_morning as morning
import focus_queue_prompt_usage as prompt_usage
from focus_queue_lock import acquire_exclusive_file_lock


SUPPORT_DIRECTORY = Path.home() / "Library/Application Support/ECC Focus Queue"
DEFAULT_RUNTIME = SUPPORT_DIRECTORY / "agent"
DEFAULT_PROOF_DIRECTORY = SUPPORT_DIRECTORY / "connector-proofs"
DEFAULT_MAIL_COMMAND_DIRECTORY = SUPPORT_DIRECTORY / "connector-commands"
DEFAULT_CODEX = Path("/opt/homebrew/bin/codex")
NO_TOOLS_MODEL = "gpt-5.5"
NO_TOOLS_MODEL_PREFERENCES = (
    NO_TOOLS_MODEL,
    "gpt-5.4",
    "gpt-5.2",
)
EXPECTED_MANIFEST_KEYS = {
    "model",
    "instructions",
    "input",
    "tools",
    "tool_choice",
    "parallel_tool_calls",
    "reasoning",
    "store",
    "stream",
    "include",
    "prompt_cache_key",
    "text",
    "client_metadata",
}
REQUIRED_NO_TOOLS_CONFIG_OVERRIDES = (
    'web_search="disabled"',
    "tools.web_search=false",
    "agents.enabled=false",
    "tools.experimental_request_user_input.enabled=false",
    "tools.update_plan.enabled=false",
)
OPTIONAL_NO_TOOLS_CONFIG_OVERRIDES = (
    "tools.view_image=false",
)
FEATURE_LIST_ROW = re.compile(
    r"^([a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*)\s+(.+?)\s+(true|false)$"
)
# Chat turns need the shell and file edits only. These optional features add
# tool schemas and instructions to every chat call (FOC-075).
LEAN_CHAT_DISABLED_FEATURES = (
    "multi_agent", "plugins", "apps", "remote_plugin", "browser_use", "browser_use_external",
    "in_app_browser", "computer_use", "image_generation", "skill_search", "goals", "tool_suggest",
)


class CodexHarnessError(RuntimeError):
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


def resolve_codex() -> str:
    if DEFAULT_CODEX.is_file() and os.access(DEFAULT_CODEX, os.X_OK):
        return str(DEFAULT_CODEX)
    raise CodexHarnessError(f"The trusted Codex CLI is not installed at {DEFAULT_CODEX}")


def run_codex_capability_probe(
    command: list[str], *, operation: str
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            input="",
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CodexHarnessError(
            f"Could not {operation}: {error}. Classification was stopped before inference. "
            "Check the Codex CLI installation and retry."
        ) from error


def is_empty_prompt_probe_exit(result: subprocess.CompletedProcess[str]) -> bool:
    detail = f"{result.stderr}\n{result.stdout}".strip()
    return result.returncode != 0 and "no prompt provided via stdin" in detail.casefold()


def select_no_tools_model(models: list[dict[str, Any]]) -> dict[str, Any]:
    by_slug = {
        str(item.get("slug")): item
        for item in models
        if isinstance(item, dict) and item.get("supported_in_api") is not False
    }
    for slug in NO_TOOLS_MODEL_PREFERENCES:
        if slug in by_slug:
            return by_slug[slug]
    raise ValueError("no approved general model is available")


def select_named_model(models: list[dict[str, Any]], slug: str) -> dict[str, Any]:
    for item in models:
        if (
            isinstance(item, dict)
            and str(item.get("slug")) == slug
            and item.get("supported_in_api") is not False
        ):
            return item
    raise ValueError(f"the requested model {slug} is not available")


def build_no_tools_model_catalog(
    executable: str,
    directory: Path,
    version: str,
    model: str | None = None,
) -> tuple[Path, str]:
    result = run_codex_capability_probe(
        [executable, "debug", "models", "--bundled"],
        operation=f"inspect the bundled model catalog for {version}",
    )
    try:
        payload = json.loads(result.stdout)
        models = payload["models"]
        selected = (
            select_named_model(models, model) if model else select_no_tools_model(models)
        )
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        raise CodexHarnessError(
            f"Could not build the no-tools model profile for {version}. Classification was "
            "stopped before inference. Update Codex or the Focus Queue harness, then retry."
        ) from error
    if result.returncode != 0 or not isinstance(selected, dict):
        raise CodexHarnessError(
            f"Could not inspect the bundled model catalog for {version}. Classification was "
            "stopped before inference. Update Codex or the Focus Queue harness, then retry."
        )
    sanitized = dict(selected)
    sanitized["shell_type"] = "disabled"
    sanitized["apply_patch_tool_type"] = None
    sanitized["supports_search_tool"] = False
    sanitized["experimental_supported_tools"] = []
    sanitized.pop("tool_mode", None)
    sanitized.pop("multi_agent_version", None)
    path = directory / "no-tools-model-catalog.json"
    morning.write_private_json(path, {"models": [sanitized]})
    return path, str(sanitized["slug"])


def assert_effective_no_tools_manifest(
    executable: str,
    *,
    version: str,
    features: tuple[str, ...],
    overrides: tuple[str, ...],
    catalog_path: Path,
    model: str,
    workspace: Path,
) -> None:
    captured: list[tuple[str, dict[str, Any]]] = []

    class ProbeHandler(http.server.BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length < 1 or length > 2_000_000:
                    raise ValueError("invalid manifest probe size")
                captured.append((self.path, json.loads(self.rfile.read(length))))
            except (ValueError, json.JSONDecodeError):
                pass
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"manifest probe complete"}}')

        def log_message(self, _format: str, *_args: Any) -> None:
            return

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ProbeHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    port = server.server_address[1]
    provider = (
        '{name="Focus Queue manifest probe", '
        f'base_url="http://127.0.0.1:{port}/v1", '
        'env_key="FOCUS_QUEUE_MANIFEST_PROBE_KEY", wire_api="responses"}'
    )
    command = [executable]
    for feature in features:
        command.extend(["--disable", feature])
    command.extend(
        [
            "exec",
            "--ephemeral",
            "--strict-config",
            "--ignore-user-config",
            "--sandbox",
            "read-only",
            "--skip-git-repo-check",
            "-C",
            str(workspace),
            "-c",
            f"model_catalog_json={json.dumps(str(catalog_path))}",
            "-c",
            f"model={json.dumps(model)}",
            "-c",
            'model_provider="focus_queue_manifest_probe"',
            "-c",
            f"model_providers.focus_queue_manifest_probe={provider}",
        ]
    )
    for override in overrides:
        command.extend(["-c", override])
    command.append("manifest probe")
    try:
        subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
            env={**os.environ, "FOCUS_QUEUE_MANIFEST_PROBE_KEY": "local-probe"},
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CodexHarnessError(
            f"Could not inspect the effective tool manifest for {version}: {error}. "
            "Classification was stopped before inference."
        ) from error
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)
    if len(captured) != 1:
        raise CodexHarnessError(
            f"Could not inspect one effective tool manifest for {version}. Classification was "
            "stopped before inference. Update Codex or the Focus Queue harness, then retry."
        )
    request_path, payload = captured[0]
    if request_path != "/v1/responses":
        raise CodexHarnessError(
            f"Codex {version} used an unexpected classifier manifest endpoint. Classification "
            "was stopped before inference. Update Codex or the Focus Queue harness, then retry."
        )
    validate_effective_no_tools_manifest(payload, version=version, model=model)


def validate_effective_no_tools_manifest(
    payload: dict[str, Any], *, version: str, model: str = NO_TOOLS_MODEL
) -> None:
    if (
        not isinstance(payload, dict)
        or payload.get("model") != model
        or "tools" not in payload
        or "input" not in payload
    ):
        raise CodexHarnessError(
            f"Codex {version} returned an incomplete classifier manifest. Classification was "
            "stopped before inference. Update Codex or the Focus Queue harness, then retry."
        )
    if set(payload) != EXPECTED_MANIFEST_KEYS:
        raise CodexHarnessError(
            f"Codex {version} returned an unrecognized classifier manifest shape. "
            "Classification was stopped before inference. Update Codex or the Focus Queue "
            "harness, then retry."
        )
    tools = payload["tools"]
    input_items = payload["input"]
    valid_input = isinstance(input_items, list) and bool(input_items) and all(
        isinstance(item, dict) and item.get("type") == "message"
        for item in input_items
    )
    if tools != [] or not valid_input:
        names = [
            str(item.get("name", item.get("type", "unknown")))
            for item in tools or []
            if isinstance(item, dict)
        ]
        names.extend(
            str(item.get("name", item.get("type", "additional_tools")))
            for item in input_items or []
            if isinstance(item, dict) and item.get("type") == "additional_tools"
        )
        raise CodexHarnessError(
            f"Codex {version} exposed unexpected classifier tools: {', '.join(names) or 'unknown'}. "
            "Classification was stopped before inference. Update Codex or the Focus Queue "
            "harness, then retry."
        )


def no_tools_config_probe_command(
    executable: str, overrides: tuple[str, ...]
) -> list[str]:
    command = [executable, "exec", "--ephemeral", "--strict-config", "--ignore-user-config"]
    for override in overrides:
        command.extend(["-c", override])
    command.append("-")
    return command


def lean_chat_disabled_features(executable: str) -> tuple[str, ...]:
    """Lean chat feature switches this Codex build still offers. A probe failure
    only costs tokens, so it falls back to the full feature set."""
    result = run_codex_capability_probe(
        [executable, "features", "list"], operation="list Codex features for a lean chat turn"
    )
    if result.returncode != 0:
        return ()
    offered = {
        match.group(1)
        for line in result.stdout.splitlines()
        if (match := FEATURE_LIST_ROW.fullmatch(line.strip())) and match.group(2).strip() != "removed"
    }
    return tuple(feature for feature in LEAN_CHAT_DISABLED_FEATURES if feature in offered)


def discover_no_tools_codex_capabilities(
    executable: str,
    *,
    safety_directory: Path,
    workspace: Path,
    model: str | None = None,
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    version_result = run_codex_capability_probe(
        [executable, "--version"],
        operation="determine the installed Codex CLI version",
    )
    version = version_result.stdout.strip() or "unknown Codex version"
    if version_result.returncode != 0:
        detail = (version_result.stderr or version_result.stdout).strip() or "no diagnostic output"
        raise CodexHarnessError(
            f"Could not determine the installed Codex CLI version (exit "
            f"{version_result.returncode}): {detail[:1200]}. Classification was stopped before "
            "inference. Check the Codex CLI installation and retry."
        )
    feature_result = run_codex_capability_probe(
        [executable, "features", "list"],
        operation=f"list Codex feature capabilities for {version}",
    )
    if feature_result.returncode != 0:
        detail = (feature_result.stderr or feature_result.stdout).strip() or "no diagnostic output"
        raise CodexHarnessError(
            f"Could not list Codex feature capabilities for {version} (exit "
            f"{feature_result.returncode}): {detail[:1200]}. Classification was stopped before "
            "inference. Update Codex or the Focus Queue harness, then retry."
        )

    features: list[str] = []
    for line in feature_result.stdout.splitlines():
        if not line.strip():
            continue
        match = FEATURE_LIST_ROW.fullmatch(line.strip())
        if match is None:
            raise CodexHarnessError(
                f"The Focus Queue harness could not parse `codex features list` output from "
                f"{version}: {line.strip()[:200]}. Classification was stopped before inference. "
                "Update Codex or the Focus Queue harness, then retry."
            )
        feature = match.group(1)
        if feature in features:
            raise CodexHarnessError(
                f"The Focus Queue harness found duplicate feature `{feature}` in "
                f"`codex features list` output from {version}. Classification was stopped before "
                "inference. Update Codex or the Focus Queue harness, then retry."
            )
        features.append(feature)
    if not features:
        raise CodexHarnessError(
            f"Codex reported no feature capabilities for {version}. Classification was stopped "
            "before inference. Update Codex or the Focus Queue harness, then retry."
        )

    supported_overrides: list[str] = []
    for override in REQUIRED_NO_TOOLS_CONFIG_OVERRIDES + OPTIONAL_NO_TOOLS_CONFIG_OVERRIDES:
        override_result = run_codex_capability_probe(
            no_tools_config_probe_command(executable, (override,)),
            operation=f"validate Codex no-tools control {override} for {version}",
        )
        if is_empty_prompt_probe_exit(override_result):
            supported_overrides.append(override)
            continue
        detail = (override_result.stderr or override_result.stdout).strip()
        optional_and_unsupported = (
            override in OPTIONAL_NO_TOOLS_CONFIG_OVERRIDES
            and "unknown configuration field" in detail.casefold()
        )
        if optional_and_unsupported:
            continue
        raise CodexHarnessError(
            f"Codex {version} rejected the required no-tools controls while checking "
            f"`{override}` (exit {override_result.returncode}): "
            f"{(detail or 'no diagnostic output')[:1200]}. Classification was stopped before "
            "inference. Update Codex or the Focus Queue harness, then retry."
        )

    catalog_path, no_tools_model = build_no_tools_model_catalog(
        executable, safety_directory, version, model=model
    )
    catalog_overrides = (
        f"model_catalog_json={json.dumps(str(catalog_path))}",
        f"model={json.dumps(no_tools_model)}",
    )
    validation_command = [executable]
    for feature in features:
        validation_command.extend(["--disable", feature])
    validation_command.extend(["exec", "--ephemeral", "--strict-config", "--ignore-user-config"])
    for override in tuple(supported_overrides) + catalog_overrides:
        validation_command.extend(["-c", override])
    validation_command.append("-")
    validation_result = run_codex_capability_probe(
        validation_command,
        operation=f"validate no-tools controls for {version}",
    )
    validation_detail = (validation_result.stderr or validation_result.stdout).strip()
    if not is_empty_prompt_probe_exit(validation_result):
        detail = validation_detail or "the empty-input safety probe unexpectedly succeeded"
        raise CodexHarnessError(
            f"Codex {version} rejected the required no-tools controls (exit "
            f"{validation_result.returncode}): {detail[:1200]}. Classification was stopped before "
            "inference. Update Codex or the Focus Queue harness, then retry."
        )
    assert_effective_no_tools_manifest(
        executable,
        version=version,
        features=tuple(features),
        overrides=tuple(supported_overrides),
        catalog_path=catalog_path,
        model=no_tools_model,
        workspace=workspace,
    )
    return tuple(features), tuple(supported_overrides) + catalog_overrides


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


def parse_token_usage(stdout: str) -> dict[str, int] | None:
    usage: dict[str, Any] | None = None
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        candidate = event.get("usage")
        if event.get("type") == "turn.completed" and isinstance(candidate, dict):
            usage = candidate
    if usage is None:
        return None
    input_tokens = int(usage.get("input_tokens", 0) or 0)
    output_tokens = int(usage.get("output_tokens", 0) or 0)
    return {
        "inputTokens": input_tokens,
        "cachedInputTokens": int(usage.get("cached_input_tokens", 0) or 0),
        "outputTokens": output_tokens,
        "reasoningOutputTokens": int(usage.get("reasoning_output_tokens", 0) or 0),
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
    thread_id: str | None,
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
        "resumedThread": bool(thread_id),
        "observedThreadId": parse_thread_id(stdout),
        "returnCode": return_code,
        "timedOut": timed_out,
        "usage": parse_token_usage(stdout),
        "stdoutBytes": len(stdout.encode("utf-8")),
        "stderrBytes": len(stderr.encode("utf-8")),
    }
    morning.write_private_json(runtime / "latest-run.json", payload)


def run_codex(
    *,
    prompt: str,
    workspace: Path,
    runtime: Path,
    timeout: int,
    sandbox: str,
    thread_id: str | None,
    output_schema: Path | None,
    usage_file: Path | None = None,
    model: str | None = None,
    effort: str | None = None,
    expose_evidence_directories: bool = False,
    expose_queue_order: bool = False,
    disable_tools: bool = False,
    context_directory: Path | None = None,
    writable_directories: list[Path] | None = None,
    fork_thread: bool = False,
    lean: bool = False,
    persist_session: bool = True,
) -> tuple[str, str | None]:
    if context_directory is not None:
        if not context_directory.is_absolute() or not context_directory.is_dir():
            raise CodexHarnessError("Context directory must be an absolute path to an existing directory")
        context_directory = context_directory.resolve(strict=True)
    runtime.mkdir(parents=True, exist_ok=True)
    runtime.chmod(0o700)
    started_at = datetime.now(timezone.utc).isoformat()
    if usage_file is not None:
        usage_file = usage_file.expanduser()
        usage_file.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix="turn-", dir=runtime) as temporary:
        reply_path = Path(temporary) / "reply.txt"
        executable = resolve_codex()
        tool_features: tuple[str, ...] = ()
        no_tools_config_overrides: tuple[str, ...] = ()
        if disable_tools:
            tool_features, no_tools_config_overrides = discover_no_tools_codex_capabilities(
                executable,
                safety_directory=Path(temporary),
                workspace=workspace,
                model=model,
            )
        command = [
            executable,
            "--ask-for-approval",
            "never",
        ]
        if disable_tools:
            for feature in tool_features:
                command.extend(["--disable", feature])
        elif lean:
            for feature in lean_chat_disabled_features(executable):
                command.extend(["--disable", feature])
        if sandbox == "workspace-write":
            command.extend(["-c", "sandbox_workspace_write.network_access=true"])
        command.append("exec")
        if disable_tools:
            command.extend(["--ephemeral", "--strict-config"])
            for override in no_tools_config_overrides:
                command.extend(["-c", override])
        elif not persist_session:
            command.append("--ephemeral")
        # A lean turn runs from one stable empty directory so Codex does not
        # load AGENTS.md files from the workspace and its ancestors; the
        # workspace stays reachable as an added directory.
        lean_directory = runtime / "lean-chat"
        if lean:
            lean_directory.mkdir(mode=0o700, exist_ok=True)
        command.extend(
            [
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
                str(lean_directory if lean else workspace),
            ]
        )
        allow_extra_writes = sandbox == "workspace-write" and not disable_tools
        if lean and allow_extra_writes:
            command.extend(["--add-dir", str(workspace)])
        if expose_evidence_directories and allow_extra_writes:
            command.extend(
                [
                    "--add-dir",
                    str(DEFAULT_PROOF_DIRECTORY),
                    "--add-dir",
                    str(DEFAULT_MAIL_COMMAND_DIRECTORY),
                ]
            )
        if expose_queue_order and allow_extra_writes:
            support = Path(os.environ.get("FOCUS_QUEUE_SUPPORT_DIR", str(runtime.parent)))
            queue_order_directory = support / "queue-order"
            queue_order_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            command.extend(["--add-dir", str(queue_order_directory.resolve())])
        if context_directory is not None and allow_extra_writes:
            command.extend(["--add-dir", str(context_directory)])
        if writable_directories and allow_extra_writes:
            for directory in writable_directories:
                resolved = Path(directory).expanduser()
                if resolved.is_dir():
                    command.extend(["--add-dir", str(resolved.resolve())])
        if model is not None and not disable_tools:
            command.extend(["--model", model])
        if effort is not None:
            command.extend(["-c", f"model_reasoning_effort={effort}"])
        if output_schema is not None:
            command.extend(["--output-schema", str(output_schema)])
        if thread_id:
            # A fork answers in a new thread and leaves the source untouched.
            command.extend(["fork" if fork_thread else "resume", thread_id, "-"])
        else:
            command.append("-")

        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
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
                    thread_id=thread_id,
                    stdout=stdout,
                    stderr=stderr,
                    return_code=process.returncode,
                    timed_out=True,
                )
                if usage_file is not None:
                    write_token_usage(usage_file, stdout)
                raise CodexHarnessError(f"Codex exceeded the {timeout}-second run budget") from error
        finally:
            signal.signal(signal.SIGTERM, previous_handler)

        write_run_diagnostic(
            runtime,
            started_at=started_at,
            timeout=timeout,
            sandbox=sandbox,
            thread_id=thread_id,
            stdout=stdout,
            stderr=stderr,
            return_code=process.returncode,
            timed_out=False,
        )
        if usage_file is not None:
            write_token_usage(usage_file, stdout)
        if usage_file is None:
            # A caller that asks for a usage file records its own attributed event.
            prompt_usage.record_provider_usage("codex", model, parse_token_usage(stdout),
                source=os.environ.get("FOCUS_QUEUE_MODEL_USAGE_SOURCE") or "provider_usage",
                run_id=os.environ.get("FOCUS_QUEUE_MODEL_USAGE_RUN_ID"),
                support=Path(os.environ["FOCUS_QUEUE_SUPPORT_DIR"]) if os.environ.get("FOCUS_QUEUE_SUPPORT_DIR") else runtime.parent)

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
        acquire_exclusive_file_lock(lock)
        state = load_state(state_path)
        sessions = state.setdefault("sessions", {})
        prior_thread = str(sessions.get(arguments.session, "")) or None
        fork_from = None if prior_thread else getattr(arguments, "fork_from", None)
        prompt = arguments.prompt_file.read_text(encoding="utf-8")
        reader = getattr(arguments, "reader", False)
        if reader or getattr(arguments, "fresh", False):
            # The app sends its own short recap, so a fresh turn neither resumes
            # nor saves a session mapping whose history would grow every turn.
            reply, _ = run_codex(
                prompt=prompt,
                workspace=arguments.workspace,
                runtime=runtime,
                timeout=arguments.timeout,
                sandbox="read-only" if reader else "workspace-write",
                thread_id=None,
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
            reply, observed_thread = run_codex(
                prompt=prompt,
                workspace=arguments.workspace,
                runtime=runtime,
                timeout=arguments.timeout,
                sandbox="workspace-write",
                thread_id=prior_thread or fork_from,
                fork_thread=fork_from is not None,
                output_schema=None,
                usage_file=getattr(arguments, "usage_file", None),
                expose_evidence_directories=True,
                expose_queue_order=True,
                model=getattr(arguments, "model", None),
                effort=getattr(arguments, "effort", None),
                context_directory=getattr(arguments, "context_dir", None),
                writable_directories=getattr(arguments, "writable_dirs", None),
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
                usage_file=getattr(arguments, "usage_file", None),
                expose_evidence_directories=True,
                expose_queue_order=True,
                model=getattr(arguments, "model", None),
                effort=getattr(arguments, "effort", None),
                context_directory=getattr(arguments, "context_dir", None),
                writable_directories=getattr(arguments, "writable_dirs", None),
            )
        thread_id = observed_thread or prior_thread
        if not thread_id or thread_id == fork_from:
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
        usage_file=arguments.usage_file,
        disable_tools=arguments.disable_tools,
        model=getattr(arguments, "model", None),
        effort=getattr(arguments, "effort", None),
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
    chat_parser.add_argument("--reader", action="store_true",
                             help="Run an ephemeral read-only document question")
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
    chat_parser.add_argument("--effort", help="Override the chat reasoning effort level")
    chat_parser.add_argument(
        "--fork-from",
        help="Start a session with no saved conversation as a fork of this provider thread",
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
    run_parser.add_argument("--model", help="Override the pinned no-tools model slug")
    run_parser.add_argument("--effort", help="Override the reasoning effort level")
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
