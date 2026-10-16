#!/usr/bin/env python3
"""Dispatch `fq <codex|claude> [args...]` through heuristic placement.

`fq` classifies the launch with `focus_queue_placement.py` and then hands off
to the provider's existing Focus Queue entry script with every provider
argument unchanged. A resolved task is forced through FOCUS_QUEUE_TASK_ID, the
same channel the app uses for managed launches; anything unplaced passes
through untouched so the entry script's own intake behavior decides. Plain
`codex`/`claude` shell functions never go through this script.
"""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import sys


PROVIDERS = ("codex", "claude")
HERE = Path(__file__).resolve().parent
USAGE = """Usage: fq <codex|claude> [provider args...]

Classify the launch heuristically (prompt ticket, configured project, else
inbox), then launch the provider through its Focus Queue entry script.
"""


class FqError(RuntimeError):
    pass


def load_sibling(name):
    path = HERE / name
    if not path.is_file():
        raise FqError(f"The Focus Queue sibling script is missing: {path}")
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def support_directory(environment):
    return Path(environment.get("FOCUS_QUEUE_SUPPORT_DIR") or
                str(Path.home() / "Library/Application Support/ECC Focus Queue")).absolute()


def installed_entry_arguments(provider, support):
    """Reconstruct the installed shell function's fixed entry arguments."""
    shell = support / "shell" / f"{provider}.zsh"
    try:
        text = shell.read_text()
    except OSError:
        text = ""
    entry_name = f"focus_queue_{provider}_entry.py"
    for line in text.splitlines():
        if entry_name not in line or "--usage-wrapper" not in line:
            continue
        try:
            tokens = shlex.split(line)
        except ValueError:
            continue
        start = next((index for index, token in enumerate(tokens)
                      if token.endswith(entry_name)), None)
        if start is None:
            continue
        arguments = []
        for token in tokens[start + 1:]:
            if token == "--":
                break
            arguments.append(token)
        if any(token.startswith("--usage-wrapper") for token in arguments):
            return arguments
    return None


def entry_command(provider, support, environment):
    entry = HERE / f"focus_queue_{provider}_entry.py"
    if not entry.is_file():
        raise FqError(f"The Focus Queue {provider} entry script is missing: {entry}")
    arguments = installed_entry_arguments(provider, support)
    if arguments is None:
        wrapper = (environment.get(f"FOCUS_QUEUE_{provider.upper()}_USAGE_WRAPPER")
                   or shutil.which(provider))
        if not wrapper:
            raise FqError(f"The {provider} shell entry is not installed and no usage wrapper "
                          f"was found. Reinstall the Focus Queue shell integration.")
        arguments = ["--usage-wrapper", wrapper]
    interpreter = "/usr/bin/python3" if Path("/usr/bin/python3").is_file() else sys.executable
    return [interpreter, str(entry), *arguments, "--"]


def classify_launch(provider, provider_args, environment):
    """Return the placement result, or None when classification is impossible."""
    try:
        entry_module = load_sibling(f"focus_queue_{provider}_entry.py")
        placement = load_sibling("focus_queue_placement.py")
        try:
            prompt = entry_module.initial_prompt(provider_args)
        except Exception:
            prompt = None
        try:
            cwd = entry_module.selected_directory(provider_args)
        except Exception:
            cwd = os.getcwd()
        return placement.classify(prompt=prompt, cwd=cwd, environment=environment)
    except Exception as error:
        print(f"[fq] classification unavailable ({error}); launching without placement",
              file=sys.stderr)
        return None


def dispatch(provider, provider_args, environment):
    """Build the entry-script command and apply a resolved task, if any."""
    result = classify_launch(provider, provider_args, environment)
    if result and result.get("status") == "task" and isinstance(result.get("taskID"), str):
        environment["FOCUS_QUEUE_TASK_ID"] = result["taskID"]
        print(f"[fq] placed → {result['taskID']} (heuristic: {result['rationale']})",
              file=sys.stderr)
    else:
        rationale = result.get("rationale", "classifier-unavailable") if result else "classifier-unavailable"
        print(f"[fq] unplaced ({rationale}) — launching untracked-by-task", file=sys.stderr)
    return entry_command(provider, support_directory(environment), environment) + list(provider_args)


def main(argv=None, *, environment=None, execv=None):
    arguments = list(sys.argv[1:] if argv is None else argv)
    environment = os.environ if environment is None else environment
    if arguments[:1] in (["-h"], ["--help"]):
        print(USAGE)
        return 0
    if not arguments:
        print(USAGE, file=sys.stderr)
        return 2
    provider = arguments[0]
    if provider not in PROVIDERS:
        print(f"fq: choose a provider: {', '.join(PROVIDERS)}", file=sys.stderr)
        return 2
    try:
        command = dispatch(provider, arguments[1:], environment)
    except FqError as error:
        print(f"fq: {error}", file=sys.stderr)
        return 2
    (os.execv if execv is None else execv)(command[0], command)
    return 0  # unreachable with a real execv


if __name__ == "__main__":
    raise SystemExit(main())
