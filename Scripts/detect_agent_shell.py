#!/usr/bin/env python3
"""Record provider customization kinds without executing shells or retaining definitions."""
import argparse
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import tempfile


def scan(home: Path, shell: str) -> dict:
    shell_name = Path(shell).name
    names = ([".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zsh_aliases", ".aliases"]
             if shell_name == "zsh" else
             [".bash_profile", ".bash_login", ".profile", ".bashrc", ".bash_aliases", ".aliases"])
    providers = {name: {"kinds": [], "sourceFiles": [], "executableOnInstallerPath": shutil.which(name) is not None}
                 for name in ("codex", "claude")}
    for name in names:
        path = home / name
        try:
            if path.stat().st_size > 1_000_000:
                continue
            content = path.read_text(errors="replace")
        except OSError:
            continue
        for provider, record in providers.items():
            alias = re.search(r"(?m)^\s*alias\s+(?:-[A-Za-z]+\s+)*" + provider + r"=", content)
            function = re.search(r"(?m)^\s*(?:function\s+" + provider + r"(?:\s*\(\s*\))?\s*\{|"
                                 + provider + r"\s*\(\s*\)\s*\{)", content)
            for kind, found in (("alias", alias), ("function", function)):
                if found and kind not in record["kinds"]:
                    record["kinds"].append(kind)
            if alias or function:
                record["sourceFiles"].append(name)
    return {"schemaVersion": 1, "shell": shell, "scanMode": "static",
            "limitation": "Dynamic definitions and other sourced files are resolved by the interactive shell at launch.",
            "providers": providers}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--shell", default=pwd.getpwuid(os.getuid()).pw_shell)
    args = parser.parse_args()
    shell = args.shell if Path(args.shell).name in {"zsh", "bash"} else "/bin/zsh"
    result = scan(args.home, shell)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_path = tempfile.mkstemp(prefix=".agent-shell-", dir=args.output.parent)
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(result, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary_path, args.output)
    finally:
        if os.path.exists(temporary_path):
            os.unlink(temporary_path)


if __name__ == "__main__":
    main()
