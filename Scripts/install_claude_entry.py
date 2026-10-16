#!/usr/bin/env python3
"""Install the Claude shell entry, with native lifecycle hooks available by opt-in."""
from __future__ import annotations

import argparse
import ctypes
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import stat
import tempfile

START = "# >>> ECC Focus Queue Claude entry >>>"
END = "# <<< ECC Focus Queue Claude entry <<<"
HOOK_EVENTS = ("SessionStart", "UserPromptSubmit", "Stop", "SessionEnd", "SubagentStart", "SubagentStop")


def safe_destination(path, home):
    if not path.is_relative_to(home) or path == home:
        raise ValueError(f"Integration destination is outside the selected home: {path}")
    current = path
    while current != home:
        if current.is_symlink():
            raise ValueError(f"Integration destination is a symlink: {current}")
        current = current.parent


def merge_shell(original, source_path):
    block = f'{START}\nsource {shlex.quote(str(source_path))}\n{END}'
    if START in original or END in original:
        pattern = re.compile(r"(?m)^" + re.escape(START) + r"\n.*?^" + re.escape(END) + r"$", re.S)
        matches = list(pattern.finditer(original))
        if len(matches) != 1 or original.count(START) != 1 or original.count(END) != 1:
            raise ValueError("The existing Focus Queue shell block is incomplete or duplicated.")
        return original[:matches[0].start()] + block + original[matches[0].end():]
    return original.rstrip("\n") + "\n\n" + block + "\n"


def merge_hooks(original, helper):
    value = json.loads(original) if original.strip() else {}
    if not isinstance(value, dict) or not isinstance(value.get("hooks", {}), dict):
        raise ValueError("The existing hooks configuration is not a JSON object with a hooks table.")
    hooks = value.setdefault("hooks", {})
    command = shlex.quote(str(helper)) + " register-event --provider claude >/dev/null"
    for event in HOOK_EVENTS:
        existing = hooks.setdefault(event, [])
        if not isinstance(existing, list):
            raise ValueError(f"The existing {event} hooks are not a list.")
        entry = {"hooks": [{"type": "command", "command": command,
            "timeout": 3 if event == "SessionEnd" else 10,
            "statusMessage": "Track this session in Focus Queue"}]}
        if event == "SessionStart":
            entry["matcher"] = "^(startup|resume|clear|compact)$"
        # Only replace this integration's exact command; other user's hooks retain order.
        existing[:] = [item for item in existing if not (
            isinstance(item, dict) and isinstance(item.get("hooks"), list) and len(item["hooks"]) == 1
            and isinstance(item["hooks"][0], dict) and item["hooks"][0].get("command") == command)]
        existing.append(entry)
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def require_task_session_helper(helper, home):
    safe_destination(helper, home)
    if helper.is_symlink() or not helper.is_file() or not os.access(helper, os.X_OK):
        raise ValueError("Install the current Focus Queue helper before configuring the Claude shell entry.")
    try:
        result = subprocess.run([str(helper), "--help"], capture_output=True, text=True,
                                timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ValueError("Focus Queue could not verify the installed session helper.") from error
    if (result.returncode or "tmux start-agent <TASK-ID> <AGENT-ID>" not in result.stdout
            or "placement" not in result.stdout):
        raise ValueError("The installed Focus Queue helper lacks placement or tmux start-agent support. Upgrade the app first.")


def file_snapshot(path):
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except FileNotFoundError:
        return None
    except OSError as error:
        raise ValueError(f"Integration target changed or is unsafe: {path}") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError(f"Integration target is not a regular file: {path}")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            content = stream.read()
        return (content, stat.S_IMODE(metadata.st_mode), metadata.st_uid,
                metadata.st_gid, metadata.st_dev, metadata.st_ino,
                metadata.st_size, metadata.st_mtime_ns)
    finally:
        os.close(descriptor)


def atomic_swap(left, right):
    """Atomically exchange two same-directory paths on the supported macOS host."""
    rename = ctypes.CDLL(None, use_errno=True).renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-2, os.fsencode(left), -2, os.fsencode(right), 0x00000002) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(right))


def atomic_move_no_replace(source, destination):
    """Move one directory entry only when the destination is still absent."""
    rename = ctypes.CDLL(None, use_errno=True).renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-2, os.fsencode(source), -2, os.fsencode(destination), 0x00000004) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def install_staging(staging, destination, expected):
    if expected is None:
        try:
            os.link(staging, destination, follow_symlinks=False)
        except FileExistsError as error:
            raise ValueError(f"Integration target changed during installation: {destination}") from error
        os.unlink(staging)
        return
    os.chmod(staging, expected[1])
    atomic_swap(staging, destination)
    restored = False
    try:
        if file_snapshot(Path(staging)) != expected:
            atomic_swap(staging, destination)
            restored = True
            raise ValueError(f"Integration target changed during installation: {destination}")
    except BaseException:
        # If validation itself failed after the exchange, restore the exact old
        # directory entry before reporting the error.
        if not restored:
            try:
                atomic_swap(staging, destination)
            except OSError:
                pass
        raise


def plan(home, usage_wrapper, flags, *, source_directory=None, install_hooks=False):
    home = home.absolute()
    source_directory = source_directory or Path(__file__).resolve().parent
    support = home / "Library/Application Support/ECC Focus Queue"
    directory = support / "shell"
    helper = home / ".local/bin/focus-queue-session"
    entry = directory / "focus_queue_claude_entry.py"
    managed_usage_wrapper = directory / "focus_queue_usage_wrapper.sh"
    managed_usage_renderer = directory / "focus_queue_codex_bar.js"
    managed_usage_license = directory / "AgentUsageBar-LICENSE.txt"
    shell = directory / "claude.zsh"
    zshrc = home / ".zshrc"
    hook_file = home / ".claude/settings.json"
    fq_dispatcher = directory / "focus_queue_fq.py"
    fq_placement = directory / "focus_queue_placement.py"
    fq_shim = home / ".local/bin/fq"
    if not usage_wrapper.is_absolute() or not usage_wrapper.is_file():
        raise ValueError("Choose the existing usage wrapper with an absolute file path.")
    require_task_session_helper(helper, home)
    destinations = (entry, managed_usage_wrapper, managed_usage_renderer,
                    managed_usage_license, shell, zshrc, fq_dispatcher, fq_placement, fq_shim)
    if install_hooks:
        destinations = destinations + (hook_file,)
    for path in destinations:
        safe_destination(path, home)
    command = ["/usr/bin/python3", str(entry), "--usage-wrapper", str(usage_wrapper)]
    command += ["--default-flag=" + flag for flag in flags]
    command += ["--"]
    shell_source = (
        "# Generated by ECC Focus Queue; the earlier alias stays in .zshrc for recovery.\n"
        "unalias claude 2>/dev/null || true\n"
        "function claude {\n  " + shlex.join(command) + ' "$@"\n}\n'
    )
    files = {
        entry: (source_directory / "focus_queue_claude_entry.py").read_bytes(),
        managed_usage_wrapper: (source_directory / "focus_queue_usage_wrapper.sh").read_bytes(),
        managed_usage_renderer: (source_directory / "focus_queue_codex_bar.js").read_bytes(),
        managed_usage_license: (source_directory / "AgentUsageBar-LICENSE.txt").read_bytes(),
        shell: shell_source.encode(),
        zshrc: merge_shell(zshrc.read_text() if zshrc.exists() else "", shell).encode(),
        fq_dispatcher: (source_directory / "focus_queue_fq.py").read_bytes(),
        fq_placement: (source_directory / "focus_queue_placement.py").read_bytes(),
        fq_shim: ("#!/bin/sh\nexec /usr/bin/python3 " + shlex.quote(str(fq_dispatcher))
                  + ' "$@"\n').encode(),
    }
    if install_hooks:
        files[hook_file] = merge_hooks(hook_file.read_text() if hook_file.exists() else "", helper).encode()
    return support, files, {fq_shim}


def install(home, usage_wrapper, flags, *, check=False, source_directory=None, install_hooks=False):
    support, files, executables = plan(home, usage_wrapper, flags, source_directory=source_directory, install_hooks=install_hooks)
    observed = {path: file_snapshot(path) for path in files}
    changed = {path: content for path, content in files.items()
               if observed[path] is None or observed[path][0] != content}
    expected = {path: observed[path] for path in changed}
    for path in executables & set(changed):
        if expected[path] is not None:
            expected[path] = (expected[path][0], 0o755, *expected[path][2:])
    result = {"mode": "preview" if check else "installed", "paths": [str(path) for path in changed],
        "tracking": "process discovery and verified launch metadata",
        "nativeHooks": "requested" if install_hooks else "unchanged",
        "originalAlias": "retained", "defaultFlags": flags}
    if install_hooks:
        result["hookReview"] = "Claude Code will prompt to review these hooks before they run. Review and approve them when prompted."
    if check or not changed:
        return result
    backups = support / "backups"
    safe_destination(backups, home.absolute())
    backups.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = Path(tempfile.mkdtemp(prefix="claude-entry-", dir=backups))
    saved = []
    for index, path in enumerate(changed):
        previous = None
        if expected[path] is not None:
            previous = backup / str(index)
            previous.write_bytes(expected[path][0])
            previous.chmod(expected[path][1])
        saved.append({"path": str(path), "backup": str(previous) if previous else None,
                      "index": index})
    manifest = {"createdAt": datetime.now(timezone.utc).isoformat(), "status": "prepared", "files": saved}
    manifest_path = backup / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    applied = {}
    try:
        for path, content in changed.items():
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            descriptor, staging = tempfile.mkstemp(prefix=".claude-entry-", dir=path.parent)
            try:
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(content)
                if path in executables:
                    os.chmod(staging, 0o755)
                install_staging(staging, path, expected[path])
                installed = file_snapshot(path)
                if installed is None or installed[0] != content:
                    raise ValueError(f"Integration target changed after installation: {path}")
                applied[path] = installed
            finally:
                if os.path.exists(staging):
                    os.unlink(staging)
    except BaseException as install_error:
        conflicts = []
        for item in reversed(saved):
            path = Path(item["path"])
            if path not in applied:
                continue
            installed = applied[path]
            try:
                if item["backup"]:
                    descriptor, staging = tempfile.mkstemp(prefix=".claude-rollback-", dir=path.parent)
                    try:
                        with os.fdopen(descriptor, "wb") as stream:
                            stream.write(Path(item["backup"]).read_bytes())
                        install_staging(staging, path, installed)
                    finally:
                        if os.path.exists(staging):
                            os.unlink(staging)
                else:
                    # Move newly installed files into the retained backup rather
                    # than unlinking a name that could have changed after the
                    # last check. If its bytes changed, link that user version
                    # back without replacing any newer directory entry.
                    retained = backup / f"rollback-installed-{item['index']}"
                    os.rename(path, retained)
                    mismatch = False
                    try:
                        mismatch = file_snapshot(retained) != installed
                    except BaseException:
                        mismatch = True
                    if mismatch:
                        try:
                            atomic_move_no_replace(retained, path)
                            conflicts.append(f"{path} (newer directory entry restored)")
                        except OSError:
                            conflicts.append(f"{path} (newer directory entry retained at {retained})")
            except BaseException as rollback_error:
                conflicts.append(f"{path} ({rollback_error})")
        manifest["status"] = "rollback-incomplete" if conflicts else "rolled-back"
        if conflicts:
            manifest["rollbackConflicts"] = conflicts
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        if conflicts:
            raise RuntimeError("Installation failed and newer files were retained for recovery: "
                               + "; ".join(conflicts)) from install_error
        raise
    manifest["status"] = "installed"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    return {**result, "backupDirectory": str(backup)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--usage-wrapper", type=Path, required=True)
    parser.add_argument("--default-flag", action="append", default=[])
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--install-hooks", action="store_true",
                        help="Also merge native Claude Code hooks into ~/.claude/settings.json; Claude Code will require interactive review before they run.")
    options = parser.parse_args()
    print(json.dumps(install(options.home, options.usage_wrapper, options.default_flag,
                            check=options.check, install_hooks=options.install_hooks), indent=2))


if __name__ == "__main__":
    main()
