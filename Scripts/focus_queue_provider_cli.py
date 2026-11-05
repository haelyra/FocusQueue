"""Finds a provider CLI for the chat harnesses."""

from __future__ import annotations

import os
from pathlib import Path
import pwd
import shutil
import subprocess
from typing import Iterable

LOGIN_SHELL_TIMEOUT_SECONDS = 20


def login_shell() -> str:
    """The user's zsh or bash, matching the shells the app runs agents in."""
    shell = pwd.getpwuid(os.getuid()).pw_shell
    return shell if Path(shell).name in {"zsh", "bash"} and os.access(shell, os.X_OK) else "/bin/zsh"


def login_shell_path() -> str | None:
    """The PATH a new terminal sees; None when the shell cannot report it.

    The app starts harnesses with a short fixed PATH, but its sign-in check runs
    in this shell. Without this a CLI can show as signed in and still not start.
    Profiles may print to stdout, so the PATH is the last line.
    """
    try:
        result = subprocess.run(
            [login_shell(), "-lic", "/usr/bin/printenv PATH"],
            capture_output=True, text=True, stdin=subprocess.DEVNULL, check=False,
            timeout=LOGIN_SHELL_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return lines[-1] if result.returncode == 0 and lines else None


def find_cli(name: str, trusted: Iterable[Path]) -> str | None:
    """A trusted install location first, then whatever the user's own shell runs."""
    for candidate in trusted:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    path = login_shell_path()
    found = shutil.which(name, path=path) if path else None
    if found:
        # npm installs run through `env node`, which must resolve in this PATH too.
        os.environ["PATH"] = path
    return found
