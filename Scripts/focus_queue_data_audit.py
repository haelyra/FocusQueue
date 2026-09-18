#!/usr/bin/env python3
"""Read-only inventory of Focus Queue's local support data.

The audit reports structure, counts, and missing metadata. It deliberately omits
stored text, message bodies, and secrets so its output can be shared safely.
"""

from __future__ import annotations

import argparse
import json
import sys
import os
from collections import Counter
from pathlib import Path
from typing import Any


TASK_FIELDS = ("ticketID", "title", "summary", "updatedAt", "worktreePath", "planPath", "subtasks", "successCriteria")


def _json(path: Path) -> tuple[Any | None, str | None]:
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except Exception as exc:  # inventory must remain useful with one bad file
        return None, type(exc).__name__


def _regular_files(root: Path) -> list[Path]:
    """List regular non-symlink files without crossing symlinked directories."""
    found: list[Path] = []
    if not root.is_dir() or root.is_symlink():
        return found
    for directory, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [name for name in dirnames if not (Path(directory) / name).is_symlink()]
        found.extend(Path(directory) / name for name in filenames if not (Path(directory) / name).is_symlink())
    return found


def audit(support_dir: Path) -> dict[str, Any]:
    support_dir = support_dir.expanduser().resolve()
    result: dict[str, Any] = {"support_dir": str(support_dir), "exists": support_dir.is_dir(), "files": {}, "tasks": {}, "gaps": []}
    if not support_dir.is_dir():
        result["gaps"].append("support directory is missing")
        result["gap_count"] = 1
        return result

    files = [p for p in _regular_files(support_dir) if not any(part.startswith(".") for part in p.relative_to(support_dir).parts)]
    counts = Counter(p.suffix or "[no extension]" for p in files)
    result["files"] = {"total": len(files), "by_extension": dict(sorted(counts.items())), "by_top_level": dict(sorted(Counter(p.relative_to(support_dir).parts[0] for p in files).items()))}

    for name in ("config.json", "state.json"):
        path = support_dir / name
        if path.exists():
            value, error = _json(path)
            result[name.removesuffix(".json")] = {"path": str(path), "valid_json": error is None, "keys": sorted(value) if isinstance(value, dict) else None, "error": error}
        else:
            result["gaps"].append(f"missing {name}")

    sessions = []
    state = result.get("state")
    if isinstance(state, dict):
        state_value, _ = _json(support_dir / "state.json")
        raw_sessions = state_value.get("agentSessions", []) if isinstance(state_value, dict) else []
        sessions = [s for s in raw_sessions if isinstance(s, dict)]
        result["sessions"] = {"count": len(sessions), "with_ticket_id": sum(bool(s.get("ticketID")) for s in sessions), "with_session_id": sum(bool(s.get("sessionID")) for s in sessions), "with_working_directory": sum(bool(s.get("workingDirectory")) for s in sessions)}
        if len(sessions) != len(raw_sessions):
            result["gaps"].append("state.json: agentSessions contains non-object entries")
    else:
        result["sessions"] = {"count": 0, "with_ticket_id": 0, "with_session_id": 0, "with_working_directory": 0}
        result["gaps"].append("state.json: agentSessions is unavailable")

    tasks_root = support_dir / "tasks"
    task_items = []
    if tasks_root.is_dir():
        for task_dir in sorted(p for p in tasks_root.iterdir() if p.is_dir() and not p.name.startswith(".")):
            context_path = task_dir / "context.json"
            context, error = _json(context_path) if context_path.exists() else (None, "missing")
            files_here = _regular_files(task_dir)
            conversation = task_dir / "conversation.json"
            messages, conversation_error = _json(conversation) if conversation.exists() else (None, None)
            missing = [field for field in TASK_FIELDS if not isinstance(context, dict) or field not in context or context[field] in (None, "")]
            subtasks = context.get("subtasks", []) if isinstance(context, dict) else []
            item = {"ticket_id": task_dir.name, "path": str(task_dir), "files": len(files_here), "archive_snapshots": len([p for p in (task_dir / "archive").iterdir() if p.is_dir() and not p.is_symlink() and p.name.startswith("snapshot-")]) if (task_dir / "archive").is_dir() and not (task_dir / "archive").is_symlink() else 0, "has_context": context_path.exists(), "context_valid_json": error is None, "context_fields": sorted(context) if isinstance(context, dict) else [], "missing_context_fields": missing, "has_plan": (task_dir / "plan.md").is_file(), "has_conversation": conversation.is_file(), "conversation_message_count": len(messages) if isinstance(messages, list) else None, "conversation_valid_json": conversation_error is None if conversation.exists() else None, "subtask_count": len(subtasks) if isinstance(subtasks, list) else None, "subtasks_with_id": sum(bool(s.get("id")) for s in subtasks if isinstance(s, dict)) if isinstance(subtasks, list) else None}
            task_items.append(item)
            for field in missing:
                result["gaps"].append(f"{task_dir.name}: missing context field {field}")
            if error:
                result["gaps"].append(f"{task_dir.name}: context.json {error}")
    result["tasks"] = {"count": len(task_items), "items": task_items, "with_conversation": sum(i["has_conversation"] for i in task_items), "with_plan": sum(i["has_plan"] for i in task_items), "with_worktree_path": sum("worktreePath" not in i["missing_context_fields"] for i in task_items)}

    ingestion = support_dir / "ingestion"
    reports = ingestion / "reports"
    report_files = sorted(reports.glob("*/*.json")) if reports.is_dir() else []
    result["ingestion"] = {"path": str(ingestion), "files": len(_regular_files(ingestion)), "report_days": len([p for p in reports.iterdir() if p.is_dir() and not p.is_symlink()]) if reports.is_dir() and not reports.is_symlink() else 0, "archived_report_files": len([p for p in report_files if not p.is_symlink()]), "latest_report": (ingestion / "latest-report.json").is_file() and not (ingestion / "latest-report.json").is_symlink(), "presentation_state": (ingestion / "report-presentation.json").is_file() and not (ingestion / "report-presentation.json").is_symlink(), "state": (ingestion / "state.json").is_file() and not (ingestion / "state.json").is_symlink()}
    if ingestion.is_dir() and not result["ingestion"]["latest_report"]:
        result["gaps"].append("ingestion/latest-report.json is missing")
    result["gaps"] = sorted(set(result["gaps"]))
    result["gap_count"] = len(result["gaps"])
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--support-dir", type=Path, default=Path.home() / "Library/Application Support/ECC Focus Queue")
    parser.add_argument("--json-output", type=Path, help="write JSON summary to this path")
    parser.add_argument("--report-output", type=Path, help="write a Markdown report to this path")
    args = parser.parse_args(argv)
    result = audit(args.support_dir)
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.json_output:
        args.json_output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    if args.report_output:
        args.report_output.write_text(render_report(result), encoding="utf-8")
    return 0


def render_report(result: dict[str, Any]) -> str:
    tasks = result.get("tasks", {})
    ingestion = result.get("ingestion", {})
    return "\n".join(["# Focus Queue data audit", "", f"Support directory: `{result['support_dir']}`", "", "## Counts", "", f"- Files: {result.get('files', {}).get('total', 0)}", f"- Task directories: {tasks.get('count', 0)}", f"- Tasks with conversations: {tasks.get('with_conversation', 0)}", f"- Tasks with plans: {tasks.get('with_plan', 0)}", f"- Archived report files: {ingestion.get('archived_report_files', 0)}", "", "## Gaps", "", *([f"- {gap}" for gap in result.get("gaps", [])] or ["- None detected by this structural audit."]), "", "This report contains counts and field names only; it does not claim that missing data can be recovered.", ""])


if __name__ == "__main__":
    sys.exit(main())
