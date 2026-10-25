"""Local prompt and provider usage counters. This module never calls a model."""

from __future__ import annotations

import datetime as dt
import fcntl
import json
import os
import uuid
from pathlib import Path


def support_directory() -> Path:
    return Path(os.environ.get("FOCUS_QUEUE_SUPPORT_DIR") or
                Path.home() / "Library/Application Support/ECC Focus Queue")


def record(source: str, component: str, *, prompt: str = "", provider: str | None = None,
           model: str | None = None, task_id: str | None = None,
           actual_input_tokens: int | None = None,
           actual_output_tokens: int | None = None,
           actual_total_tokens: int | None = None, cached_input_tokens: int | None = None,
           support: Path | None = None, characters: int | None = None,
           run_id: str | None = None, scope: str = "app") -> None:
    """Append one metadata event; failure never interrupts the measured operation."""
    chars = len(prompt) if characters is None else characters
    event = {
        "id": str(uuid.uuid4()),
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "source": source, "component": component, "provider": provider, "model": model,
        "taskID": task_id, "characters": chars,
        "estimatedInputTokens": (chars + 2) // 4,
        "actualInputTokens": actual_input_tokens, "actualOutputTokens": actual_output_tokens,
        "actualTotalTokens": actual_total_tokens, "cachedInputTokens": cached_input_tokens,
        "runID": run_id, "scope": scope,
    }
    try:
        path = (support or support_directory()) / "analytics/prompt-usage.jsonl"
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            data = (json.dumps(event, separators=(",", ":")) + "\n").encode("utf-8")
            while data:
                data = data[os.write(descriptor, data):]
        finally:
            os.close(descriptor)
    except OSError:
        pass


def record_provider_usage(provider: str, model: str | None, usage: dict | None,
                          *, source: str = "provider_usage", run_id: str | None = None,
                          support: Path | None = None) -> None:
    if usage:
        input_tokens = usage.get("inputTokens")
        output_tokens = usage.get("outputTokens")
        total_tokens = usage.get("totalTokens")
        record(source, "provider_usage", provider=provider, model=model,
               actual_input_tokens=int(input_tokens) if input_tokens is not None else None,
               actual_output_tokens=int(output_tokens) if output_tokens is not None else None,
               actual_total_tokens=int(total_tokens) if total_tokens is not None else None,
               cached_input_tokens=int(usage.get("cachedInputTokens") or 0),
               run_id=run_id, scope="provider", support=support)


def record_instruction_files(cwd: Path, provider: str, *, run_id: str,
                             task_id: str | None = None, support: Path | None = None) -> None:
    """Estimate provider-loaded instruction files in the Documents ancestor chain."""
    name = {"codex": "AGENTS.md", "claude": "CLAUDE.md"}.get(provider)
    if not name:
        return
    documents = Path.home() / "Documents"
    try:
        relative = cwd.resolve().relative_to(documents.resolve())
    except (OSError, ValueError):
        return
    directories = [documents]
    for part in relative.parts:
        directories.append(directories[-1] / part)
    start_marker = "<!-- BEGIN AGENT OUTPUT CONTRACT v1 -->"
    end_marker = "<!-- END AGENT OUTPUT CONTRACT v1 -->"
    for directory in directories:
        path = directory / name
        try:
            if path.is_symlink() or not path.is_file() or path.stat().st_size > 256_000:
                continue
            content = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            continue
        label = str(path.relative_to(documents))
        start, end = content.find(start_marker), content.find(end_marker)
        contract = content[start:end + len(end_marker)] if start >= 0 and end >= start else ""
        if contract:
            record("agent_launch", f"{label} · output_contract", characters=len(contract),
                   provider=provider, task_id=task_id, run_id=run_id,
                   scope="provider_file_estimate", support=support)
        other = len(content) - len(contract)
        if other:
            record("agent_launch", f"{label} · other_instructions", characters=other,
                   provider=provider, task_id=task_id, run_id=run_id,
                   scope="provider_file_estimate", support=support)
