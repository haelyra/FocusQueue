#!/usr/bin/env python3
"""Dispatch `fq <codex|claude> [args...]` through task placement.

`fq` classifies the launch with `focus_queue_placement.py` and then hands off
to the provider's existing Focus Queue entry script with every provider
argument unchanged. A ticket ID in the prompt places the agent directly;
otherwise one small model call either matches an open task or titles a new
one, which `fq` creates through `focus-queue-session placement` before launch.
A resolved task is forced through FOCUS_QUEUE_TASK_ID, the same channel the
app uses for managed launches; anything unplaced passes through untouched so
the entry script's own intake behavior decides. Plain `codex`/`claude` shell
functions never go through this script.
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import uuid


PROVIDERS = ("codex", "claude")
HERE = Path(__file__).resolve().parent
HELPER = Path.home() / ".local/bin/focus-queue-session"
# The creation call must not bind this launch's or a parent agent's identity.
CREATION_SCRUBBED = (
    "FOCUS_QUEUE_TASK_ID", "FOCUS_QUEUE_SUBTASK_ID", "FOCUS_QUEUE_LAUNCH_ID",
    "FOCUS_QUEUE_AGENT_CONTEXT", "FOCUS_QUEUE_TMUX_NAME", "TMUX_PANE", "CLAUDE_SESSION_ID",
    "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "CODEX_SESSION_ID")
USAGE = """Usage: fq <codex|claude> [provider args...]

Place the launch in a task (prompt ticket, else a small-model match against
open tasks, else a new titled task), then launch the provider through its
Focus Queue entry script.
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
    """Return (placement result or None, prompt, cwd)."""
    prompt, cwd = None, os.getcwd()
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
        result = placement.classify(
            prompt=prompt, cwd=cwd, environment=environment, provider=provider,
            announce=lambda text: print(f"[fq] {text}", file=sys.stderr, flush=True))
    except Exception as error:
        print(f"[fq] classification unavailable ({error}); launching without placement",
              file=sys.stderr)
        return None, prompt, cwd
    if result.get("modelError"):
        print(f"[fq] model placement unavailable ({result['modelError']}); used heuristics",
              file=sys.stderr)
    return result, prompt, cwd


def describe(result):
    if result.get("backend") == "model":
        return f"{result['model']}: {result['rationale']}, confidence {result['confidence']:.2f}"
    return f"heuristic: {result['rationale']}"


def helper_json(helper, arguments, environment):
    try:
        completed = subprocess.run([helper, *arguments], capture_output=True, text=True,
                                   timeout=35, env=environment, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise FqError(f"focus-queue-session {arguments[0]} failed: {error}") from error
    if completed.returncode:
        detail = " ".join((completed.stderr or completed.stdout).split())[:300]
        raise FqError(f"focus-queue-session {arguments[0]} failed: {detail}")
    try:
        return json.loads(completed.stdout)
    except ValueError as error:
        raise FqError(f"focus-queue-session {arguments[0]} returned malformed JSON") from error


def create_task(provider, result, prompt, cwd, environment):
    """Create the task through the validated placement path, then apply the model title.

    A rename failure keeps the created task: the agent still lands in it, only
    under the prompt-derived title.
    """
    helper = environment.get("FOCUS_QUEUE_SESSION_HELPER") or str(HELPER)
    child = {key: value for key, value in environment.items() if key not in CREATION_SCRUBBED}
    child["FOCUS_QUEUE_PROVIDER"] = provider
    capsule = helper_json(helper, ["placement", "--launch", str(uuid.uuid4()), "--cwd", cwd,
                                   "--prompt", prompt], child)
    if not isinstance(capsule, dict):
        raise FqError("placement returned no capsule")
    task_id = capsule.get("taskID")
    if capsule.get("status") != "placed" or not isinstance(task_id, str) or not task_id:
        raise FqError(f"placement did not create a task ({capsule.get('reason') or capsule.get('status')})")
    try:
        helper_json(helper, ["task", "rename", task_id, result["title"]], child)
    except FqError as error:
        print(f"[fq] kept the prompt-derived title for {task_id} ({error})", file=sys.stderr)
    return task_id.upper()


def dispatch(provider, provider_args, environment):
    """Build the entry-script command and apply a resolved or created task, if any."""
    result, prompt, cwd = classify_launch(provider, provider_args, environment)
    status = result.get("status") if result else None
    if status == "task" and isinstance(result.get("taskID"), str):
        environment["FOCUS_QUEUE_TASK_ID"] = result["taskID"]
        print(f"[fq] placed → {result['taskID']} ({describe(result)})", file=sys.stderr)
    elif status == "new-task" and prompt:
        try:
            task_id = create_task(provider, result, prompt, cwd, environment)
        except FqError as error:
            print(f"[fq] could not create a task ({error}) — launching untracked-by-task",
                  file=sys.stderr)
        else:
            environment["FOCUS_QUEUE_TASK_ID"] = task_id
            print(f"[fq] created → {task_id} “{result['title']}” ({describe(result)})",
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
