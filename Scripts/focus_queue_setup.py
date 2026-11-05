#!/usr/bin/env python3
"""Preview Focus Queue setup using filesystem metadata only; never install or run tools."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import stat
import sys
from typing import Any, Iterable


PRODUCT = "Focus Queue"
SUPPORT_DIRECTORY_NAME = "ECC Focus Queue"
SYSTEM_BIN_DIRECTORIES = (Path("/opt/homebrew/bin"), Path("/usr/local/bin"), Path("/usr/bin"))
TOOL_NAMES = ("codex", "claude", "kimi", "wezterm", "ghostty", "kitty", "python3", "gh", "tmux", "tailscale", "code", "cursor")
APP_EXECUTABLES = {
    "wezterm": "WezTerm.app/Contents/MacOS/wezterm",
    "ghostty": "Ghostty.app/Contents/MacOS/ghostty",
    "kitty": "kitty.app/Contents/MacOS/kitty",
    "tailscale": "Tailscale.app/Contents/MacOS/Tailscale",
    "code": "Visual Studio Code.app/Contents/Resources/app/bin/code",
    "cursor": "Cursor.app/Contents/Resources/app/bin/cursor",
    "terminal": "Utilities/Terminal.app/Contents/MacOS/Terminal",
}

# Each dependency group requires at least one tool. Detection is never authentication
# or compatibility verification, and a capability choice authorizes no execution.
CAPABILITIES = {
    "terminal_sessions": ("Associate and revisit terminal sessions", (("tmux", "wezterm"),), "No window movement during setup."),
    "persistent_sessions": ("Keep new sessions in tmux", (("tmux",),), "Implemented on the local Mac; sessions survive client disconnects while the host and server remain alive."),
    "remote_reconnect": ("Reconnect over SSH and Tailscale", (("tmux",), ("tailscale",)), "Command generation is implemented. SSH server access, known host keys and cross-device reachability require separate configuration."),
    "agent_chat": ("Answer queue questions with Codex", (("codex",), ("python3",)), "Agent execution can spend tokens; budgets require separate configuration."),
    "agent_launch": ("Launch task agents", (("tmux", "wezterm"), ("codex", "claude", "kimi")), "Provider sign-in and installed versions remain unverified."),
    "daily_reports": ("Schedule source reviews", (("codex",), ("python3",)), "Requires explicit source scopes, schedule, and token budget."),
    "mail_connector": ("Read a selected Apple Mail or Gmail account", (("python3",),), "Requires provider configuration and explicit account authorization; no inbox access in this preview."),
    "discord_connector": ("Read selected Discord server channels", (("python3",),), "Requires an authorized bot account and verified channel scope."),
    "telegram_connector": ("Configure Telegram coverage", (), "Personal inbox integration remains unavailable; archive coverage must be labeled separately."),
    "github_connector": ("Read selected GitHub repositories", (("gh",),), "Requires explicit account and repository selection."),
    "login_launch": ("Start the queue at login", (), "The managed installer supports --login; this preview creates no service."),
    "terminal_focus": ("Reposition terminal windows for task focus", (), "Optional Accessibility permission; no permission request or window movement here."),
    "desktop_shortcut": ("Add a Desktop launcher", (), "An existing Desktop item must be preserved."),
}


def metadata(path: Path) -> str:
    """Use lstat so conflict inspection never follows the final symlink."""
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return "missing"
    except OSError:
        return "inaccessible"
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISREG(mode):
        return "file"
    return "special_file"


def discover_tools(home: Path, system_bins: Iterable[Path], application_roots: Iterable[Path]) -> list[dict[str, Any]]:
    bins = (home / ".local/bin", home / "bin", *system_bins)
    apps = (home / "Applications", *application_roots)
    detected = []
    for name in (*TOOL_NAMES, "terminal"):
        candidates = [directory / name for directory in bins] if name != "terminal" else []
        if name in APP_EXECUTABLES:
            candidates.extend(directory / APP_EXECUTABLES[name] for directory in apps)
        matches = []
        for path in dict.fromkeys(candidates):
            kind = metadata(path)
            if kind == "missing":
                continue
            try:
                executable = path.is_file() and os.access(path, os.X_OK)
            except OSError:
                executable = False
            matches.append({"path": str(path), "kind": kind, "executableCandidate": executable})
        present = any(match["executableCandidate"] for match in matches)
        detected.append({
            "id": name,
            "status": "detected_unverified" if present else "missing",
            "candidates": matches,
            "version": None,
            "compatibilityVerified": False,
            "authenticationVerified": False,
        })
    return detected


def destination_status(path: Path, home: Path) -> tuple[str, str | None]:
    current = home
    for component in path.relative_to(home).parts[:-1]:
        kind = metadata(current)
        if kind in {"symlink", "file", "special_file", "inaccessible"}:
            return "blocked_parent", str(current)
        current /= component
    kind = metadata(current)
    if kind in {"symlink", "file", "special_file", "inaccessible"}:
        return "blocked_parent", str(current)
    kind = metadata(path)
    if kind == "missing":
        return "available", None
    if kind == "symlink":
        return "symlink_conflict", str(path)
    if kind == "inaccessible":
        return "inaccessible", str(path)
    return "existing_unverified", str(path)


def planned_paths(home: Path, selected: set[str]) -> list[dict[str, Any]]:
    support = home / "Library/Application Support" / SUPPORT_DIRECTORY_NAME
    launch_agents = home / "Library/LaunchAgents"
    specifications = [
        (home / "Applications" / f"{PRODUCT}.app", "application", None),
        (support, "support_directory", None),
        (support / "config.json", "configuration", None),
        (support / "state.json", "local_state", None),
        (support / "tasks", "task_context", None),
        (home / ".local/bin/focus-queue-session", "session_helper", ("terminal_sessions", "agent_launch")),
        (support / "automation", "automation_runtime", ("agent_chat", "daily_reports", "mail_connector", "discord_connector")),
        (home / ".local/bin/focus-queue-codex", "agent_helper", ("agent_chat", "daily_reports")),
        (home / ".local/bin/focus-queue-claude", "agent_helper", ("agent_chat", "daily_reports")),
        (home / ".local/bin/focus-queue-kimi", "agent_helper", ("agent_chat", "daily_reports")),
        (support / "ingestion.json", "source_configuration", ("daily_reports", "mail_connector", "discord_connector", "telegram_connector", "github_connector")),
        (support / "ingestion", "source_cache", "daily_reports"),
        (home / ".local/bin/focus-queue-report", "report_helper", "daily_reports"),
        (home / "Applications/ECC Focus Mail Reader.app", "mail_reader", "mail_connector"),
        (home / ".local/bin/focus-mail", "mail_helper", "mail_connector"),
        (launch_agents / "tools.ecc.focus-mail-reader.plist", "mail_service", "mail_connector"),
        (home / ".local/bin/focus-discord", "discord_helper", "discord_connector"),
        (launch_agents / "com.haelyra.ecc-focus-queue.plist", "login_service", "login_launch"),
        (home / "Desktop" / f"{PRODUCT}.app", "desktop_shortcut", "desktop_shortcut"),
    ]
    result = []
    for path, purpose, capability in specifications:
        status, conflict = destination_status(path, home)
        required_by = [] if capability is None else [capability] if isinstance(capability, str) else list(capability)
        result.append({
            "path": str(path),
            "purpose": purpose,
            "requiredBy": required_by,
            "selected": not required_by or bool(selected.intersection(required_by)),
            "status": status,
            "conflictPath": conflict,
            "ownership": "unverified" if status != "available" else "absent",
            "action": "would_create" if status == "available" else "preserve_and_review",
        })
    return result


def preview(
    *, home: Path, workspace: Path, selected: Iterable[str] = (),
    platform_name: str = sys.platform,
    system_bins: Iterable[Path] = SYSTEM_BIN_DIRECTORIES,
    application_roots: Iterable[Path] = (Path("/Applications"), Path("/System/Applications")),
) -> dict[str, Any]:
    if not home.is_absolute() or not workspace.is_absolute():
        raise ValueError("absolute_paths_required")
    home = Path(os.path.abspath(home))
    workspace = Path(os.path.abspath(workspace))
    enabled = set(selected)
    if enabled - CAPABILITIES.keys():
        raise ValueError("unknown_capability")
    tools = discover_tools(home, system_bins, application_roots)
    present = {tool["id"] for tool in tools if tool["status"] == "detected_unverified"}
    capabilities = []
    for identifier, (description, groups, detail) in CAPABILITIES.items():
        missing = [list(group) for group in groups if not present.intersection(group)]
        status = "missing_dependencies" if missing else "requires_configuration_and_verification"
        if identifier == "telegram_connector":
            status = "personal_inbox_unavailable"
        if platform_name != "darwin":
            status = "unsupported_platform"
        capabilities.append({
            "id": identifier, "description": description, "optional": True,
            "selected": identifier in enabled, "missingToolGroups": missing,
            "status": status,
            "detail": detail,
        })
    paths = planned_paths(home, enabled) if platform_name == "darwin" else []
    return {
        "version": 1, "mode": "preview", "readOnly": True,
        "platform": {"id": platform_name, "status": "macos_candidate_unverified" if platform_name == "darwin" else "unsupported"},
        "home": str(home),
        "workspace": {"path": str(workspace), "kind": metadata(workspace), "schemaVerified": False},
        "tools": tools, "capabilities": capabilities, "plannedPaths": paths,
        "selectedConflictCount": sum(path["selected"] and path["status"] != "available" for path in paths),
        "installationReady": False,
        "effects": {"filesWritten": 0, "toolsExecuted": 0, "networkRequests": 0, "modelCalls": 0, "tokensSpent": 0},
        "limitations": [
            "Filesystem presence does not verify a tool version, compatibility, authentication, or account scope.",
            "Existing destinations are preserved; an ownership manifest and reviewed migration are still required.",
            "This is an initial path inventory, not a complete installer manifest or permission check.",
            "No shell profiles, agent configuration, credentials, task documents, or inbox contents are read.",
            "Optional choices describe a future setup plan and do not authorize execution or token spending.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, help="Override home only for isolated fixture previews.")
    parser.add_argument("--workspace", type=Path, help="Workspace metadata to preview; defaults to the current directory.")
    parser.add_argument("--enable", action="append", choices=tuple(CAPABILITIES), default=[], help="Select an optional capability in the preview only; repeatable.")
    args = parser.parse_args()
    try:
        result = preview(home=args.home or Path.home(), workspace=args.workspace or Path.cwd(), selected=args.enable)
    except (OSError, ValueError):
        print(json.dumps({"version": 1, "mode": "preview", "errorCode": "invalid_setup_paths", "readOnly": True}))
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
