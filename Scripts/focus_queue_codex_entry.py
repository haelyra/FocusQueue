#!/usr/bin/env python3
"""Route interactive Codex starts through Focus Queue's persistent tmux server."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid


UTILITY_COMMANDS = {
    "agents", "exec", "e", "review", "login", "logout", "mcp", "plugin", "app-server",
    "remote-control", "app", "completion", "update", "doctor", "sandbox", "debug",
    "apply", "a", "queue", "archive", "delete", "migrate-rollouts", "unarchive",
    "cloud", "exec-server", "features", "help",
}
VALUE_OPTIONS = {
    "-c", "--config", "--enable", "--disable", "--remote", "--remote-auth-token-env",
    "-i", "--image", "-m", "--model", "--local-provider", "-p", "--profile",
    "-s", "--sandbox", "-C", "--cd", "--add-dir", "-a", "--ask-for-approval",
}
BOOLEAN_OPTIONS = {
    "--yolo", "--strict-config", "--oss", "--approve-for-me",
    "--dangerously-bypass-approvals-and-sandbox", "--worktree", "--search",
    "--no-alt-screen", "--last", "--all", "--include-non-interactive",
}


class EntryError(RuntimeError):
    pass


def invocation(arguments):
    """Return interactive kind and an explicit resume UUID, without interpreting prompts."""
    mode = "new"
    positional = False
    session_id = None
    resume_target_seen = False
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in {"-h", "--help", "-V", "--version"}:
            return "utility", None
        if argument == "--":
            if mode == "resume" and not resume_target_seen and index + 1 < len(arguments):
                return mode, session_id or canonical_uuid(arguments[index + 1])
            return mode, session_id
        if argument == "--remote" or argument.startswith("--remote="):
            return "utility", None
        if argument in VALUE_OPTIONS:
            index += 2
            continue
        if argument.startswith("-"):
            index += 1
            continue
        if not positional:
            positional = True
            if argument in UTILITY_COMMANDS:
                return "utility", None
            if argument in {"resume", "fork"}:
                mode = argument
                index += 1
                continue
        elif mode == "resume" and not resume_target_seen:
            resume_target_seen = True
            session_id = canonical_uuid(argument)
        index += 1
    return mode, session_id


def initial_prompt(arguments):
    """Recognize only the known CLI grammar. Unknown options leave the label generic."""
    positional = []
    index = 0
    while index < len(arguments):
        value = arguments[index]
        if value == "--":
            positional.extend(arguments[index + 1:])
            break
        if value in VALUE_OPTIONS:
            if index + 1 >= len(arguments):
                return None
            index += 2
            continue
        if value in BOOLEAN_OPTIONS:
            index += 1
            continue
        if value.startswith("--") and "=" in value and value.split("=", 1)[0] in VALUE_OPTIONS:
            index += 1
            continue
        if len(value) > 2 and value[:2] in VALUE_OPTIONS:
            index += 1
            continue
        if value.startswith("-"):
            return None
        positional.append(value)
        index += 1
    if len(positional) == 1 and positional[0] not in UTILITY_COMMANDS | {"resume", "fork"}:
        return positional[0][:4096]
    if len(positional) == 3 and positional[0] in {"resume", "fork"} and canonical_uuid(positional[1]):
        return positional[2][:4096]
    return None


def canonical_uuid(value):
    try:
        return str(uuid.UUID(value))
    except (ValueError, AttributeError):
        return None


def support_directory(environment):
    return Path(environment.get("FOCUS_QUEUE_SUPPORT_DIR") or
                str(Path.home() / "Library/Application Support/ECC Focus Queue")).absolute()


def run_json(helper, arguments):
    try:
        result = subprocess.run([str(helper), *arguments], capture_output=True, text=True,
                                timeout=35, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise EntryError(f"Focus Queue could not check the terminal: {error}") from error
    if result.returncode:
        raise EntryError(result.stderr.strip()[:600] or "Focus Queue could not verify the terminal.")
    try:
        return json.loads(result.stdout)
    except ValueError as error:
        raise EntryError("Focus Queue returned an incomplete terminal record. Check the app before retrying.") from error


@contextmanager
def resume_lock(support, session_id):
    directory = support / "shell/resume-receipts"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / f"{session_id}.lock"
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        # A second terminal must wait until the first has saved its exact launch receipt.
        deadline = time.monotonic() + 30
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise EntryError("A resume is already starting. Check the task before retrying.")
                time.sleep(0.05)
        yield directory / f"{session_id}.json"
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def read_receipt(path, session_id, panes):
    if not path.exists():
        return None
    try:
        saved = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise EntryError("The previous resume receipt cannot be read. Check the existing session before retrying.") from error
    reference = saved.get("reference")
    if saved.get("sessionID") == session_id and saved.get("pending") is True:
        if any(pane.get("name") == saved.get("tmuxName") for pane in panes):
            raise EntryError("The previous resume is still unconfirmed. Check its existing terminal in Focus Queue before retrying.")
        return None
    if saved.get("sessionID") != session_id or not isinstance(reference, dict):
        raise EntryError("The previous resume receipt has an unexpected identity.")
    # Equality includes server PID, creation time, pane PID and terminal device.
    return reference if reference in panes else None


def write_private_json(path, value):
    descriptor, temporary = tempfile.mkstemp(prefix=".resume-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate_reference(reference):
    if not isinstance(reference, dict):
        raise EntryError("The terminal was started, but its identity was not confirmed. Check Focus Queue before retrying.")
    name, pane = reference.get("name"), reference.get("paneID")
    import re
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", name):
        raise EntryError("The terminal has an invalid session name.")
    if not isinstance(pane, str) or not re.fullmatch(r"%[0-9]+", pane):
        raise EntryError("The terminal has an invalid pane identity.")
    return name, pane


def start(helper, name, command, *, prompt=None, support=None):
    reference = run_json(helper, ["tmux", "start", name, "--cwd", os.getcwd(), "--",
        "/usr/bin/env", "FOCUS_QUEUE_RUNTIME_MODE=tmux", "FOCUS_QUEUE_PROVIDER=codex", *command])
    validate_reference(reference)
    if support is not None:
        try:
            metadata = support / "shell/launch-metadata"
            metadata.mkdir(parents=True, exist_ok=True, mode=0o700)
            value = {"schemaVersion": 1, "provider": "codex", "cwd": os.getcwd(),
                     "launchedAt": datetime.now(timezone.utc).isoformat(), "reference": reference}
            if prompt is not None:
                value["initialPrompt"] = prompt
            write_private_json(metadata / f"{name}.json", value)
        except OSError:
            print("Codex started, but its title metadata could not be saved. Session discovery remains active.", file=sys.stderr)
    return reference


def choose_resume(helper, session_id, command, support, *, prompt=None):
    with resume_lock(support, session_id) as receipt:
        location = run_json(helper, ["runtime", "locate", "codex", session_id])
        if not isinstance(location, dict) or location.get("status") not in {"running", "stopped"}:
            raise EntryError("Focus Queue could not confirm whether this conversation is already running. Check it in the app before resuming.")
        if location["status"] == "running":
            if location.get("runtime") != "tmux" or not location.get("tmuxName"):
                raise EntryError("This conversation is already running in another terminal. Open its existing session in Focus Queue.")
            reference = {"name": location["tmuxName"], "paneID": location.get("paneID")}
            validate_reference(reference)
            return reference
        panes = run_json(helper, ["tmux", "list"])
        if not isinstance(panes, list) or not all(isinstance(pane, dict) for pane in panes):
            raise EntryError("Focus Queue could not inspect the managed terminals.")
        if previous := read_receipt(receipt, session_id, panes):
            validate_reference(previous)
            return previous
        name = "fq-codex-" + session_id
        if any(pane.get("name") == name for pane in panes):
            # A restored shell or unrelated pane must keep its contents and process.
            name += "-" + uuid.uuid4().hex[:8]
        write_private_json(receipt, {"sessionID": session_id, "tmuxName": name, "pending": True})
        reference = start(helper, name, command, prompt=prompt, support=support)
        write_private_json(receipt, {"sessionID": session_id, "reference": reference})
        return reference


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--usage-wrapper", required=True, type=Path)
    parser.add_argument("--default-flag", action="append", default=[])
    parser.add_argument("--helper", type=Path, default=Path.home() / ".local/bin/focus-queue-session")
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    options = parser.parse_args(argv)
    arguments = options.arguments
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    command = ["/bin/bash", str(options.usage_wrapper), *options.default_flag, *arguments]
    mode, session_id = invocation(arguments)
    interactive = sys.stdin.isatty() and sys.stdout.isatty()
    bypass = (bool(os.environ.get("TMUX")) or
              os.environ.get("FOCUS_QUEUE_RUNTIME_MODE") == "terminal" or
              os.environ.get("FOCUS_QUEUE_CODEX_TMUX") == "off")
    if mode == "utility" or not interactive:
        os.execv(command[0], command)
    if bypass:
        if session_id:
            location = run_json(options.helper, ["runtime", "locate", "codex", session_id])
            if not isinstance(location, dict) or location.get("status") != "stopped":
                raise EntryError("This conversation is already running or could not be verified. Open its existing session in Focus Queue.")
        os.execv(command[0], command)
    if not options.usage_wrapper.is_file():
        raise EntryError("The configured Codex usage wrapper is missing. Reinstall the shell integration.")
    if session_id:
        reference = choose_resume(options.helper, session_id, command, support_directory(os.environ),
                                  prompt=initial_prompt(arguments))
    else:
        reference = start(options.helper, "fq-codex-" + str(uuid.uuid4()), command,
                          prompt=initial_prompt(arguments), support=support_directory(os.environ))
    name, pane = validate_reference(reference)
    # Attachment failure leaves the already-started agent available in Focus Queue.
    os.execv(str(options.helper), [str(options.helper), "tmux", "attach", name, "--pane", pane])


if __name__ == "__main__":
    try:
        main()
    except (EntryError, OSError) as error:
        print(f"Codex: {error}", file=sys.stderr)
        raise SystemExit(1)
