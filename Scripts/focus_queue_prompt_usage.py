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
           support: Path | None = None, characters: int | None = None) -> None:
    """Append one metadata event; failure never interrupts the measured operation."""
    chars = len(prompt) if characters is None else characters
    event = {
        "id": str(uuid.uuid4()),
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "source": source, "component": component, "provider": provider, "model": model,
        "taskID": task_id, "characters": chars,
        "estimatedInputTokens": (chars + 2) // 4,
        "actualInputTokens": actual_input_tokens, "actualOutputTokens": actual_output_tokens,
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


def record_provider_usage(provider: str, model: str | None, usage: dict | None) -> None:
    if usage:
        record("provider_usage", "actual", provider=provider, model=model,
               actual_input_tokens=int(usage.get("inputTokens", 0)),
               actual_output_tokens=int(usage.get("outputTokens", 0)))
