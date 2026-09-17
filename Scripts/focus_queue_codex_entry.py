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
import re


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


def invocation(arguments, *, classify_agents=False):
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
                if classify_agents and argument in {"exec", "e", "review"}:
                    return ("utility" if any(item in {"--help", "-h", "-V", "--version"} for item in arguments[index + 1:]) else "noninteractive"), None
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
    except (ValueError, AttributeError, TypeError):
        return None


def support_directory(environment):
    return Path(environment.get("FOCUS_QUEUE_SUPPORT_DIR") or
                str(Path.home() / "Library/Application Support/ECC Focus Queue")).absolute()


def selected_directory(arguments):
    directory = os.getcwd()
    index = 0
    while index < len(arguments):
        value = arguments[index]
        if value == "--":
            break
        if value in VALUE_OPTIONS:
            if index + 1 >= len(arguments):
                raise EntryError(f"Missing value for {value}.")
            if value in {"--cd", "-C"}:
                directory = os.path.abspath(arguments[index + 1])
            index += 2
            continue
        if value.startswith("--cd=") or (value.startswith("-C") and len(value) > 2):
            directory = os.path.abspath(value.split("=", 1)[1] if value.startswith("--cd=") else value[2:])
        index += 1
    if not Path(directory).is_dir():
        raise EntryError("The selected working directory is missing. Choose an existing directory.")
    return str(Path(directory).resolve())


def workspace_arguments(arguments, directory):
    result, index = ["--cd", directory], 0
    while index < len(arguments):
        value = arguments[index]
        if value == "--":
            result.extend(arguments[index:])
            break
        if value in {"-C", "--cd"}:
            index += 2
            continue
        if value.startswith("--cd=") or (value.startswith("-C") and len(value) > 2):
            index += 1
            continue
        if value in VALUE_OPTIONS and index + 1 < len(arguments):
            result.extend(arguments[index:index + 2])
            index += 2
            continue
        result.append(value)
        index += 1
    return result


def git(directory, arguments, *, required=True):
    result = subprocess.run(["/usr/bin/git", *arguments], cwd=directory,
                            capture_output=True, text=True, timeout=25)
    if required and result.returncode:
        raise EntryError(result.stderr.strip()[:500] or "Git workspace preparation failed.")
    return result


def begin_tracking(arguments, mode, session_id, support, *, isolate=True):
    """Persist intent first. Unknown task/session/configuration fields stay optional."""
    support = support.resolve()
    directory = support / "tracking/launches"
    for path in (support / "tracking", directory):
        if path.is_symlink():
            raise EntryError("Tracking storage is redirected. Restore it before launching an agent.")
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
    launch_id = str(uuid.uuid4())
    path = directory / (launch_id + ".json")
    source = selected_directory(arguments)
    role = os.environ.get("FOCUS_QUEUE_AGENT_ROLE", "coding")
    if role not in {"coding", "research", "orchestrator"}:
        role = "coding"
    record = {"schemaVersion": 1, "launchID": launch_id, "provider": "codex", "mode": mode,
              "role": role, "sourceCwd": source, "cwd": source, "processID": os.getpid(),
              "createdAt": datetime.now(timezone.utc).isoformat(), "phase": "preparing",
              "title": (initial_prompt(arguments) or "Codex agent").splitlines()[0][:120]}
    started = subprocess.run(["/bin/ps", "-p", str(os.getpid()), "-o", "lstart="],
                             capture_output=True, text=True, timeout=5)
    record["processStartedAt"] = " ".join(started.stdout.split()) if started.returncode == 0 else None
    for key, value in (("sessionID", session_id), ("taskID", os.environ.get("FOCUS_QUEUE_TASK_ID")),
                       ("agentID", os.environ.get("FOCUS_QUEUE_SUBTASK_ID"))):
        if value:
            record[key] = value
    write_private_json(path, record)  # Failure here must prevent provider execution.
    try:
        workspace = source
        saved = None
        task_id = record.get("taskID", "")
        if re.fullmatch(r"[A-Za-z0-9_-]+", task_id):
            context = support / "tasks" / task_id.upper() / "context.json"
            try:
                value = json.loads(context.read_text())
                rows = value.get("subtasks") or []
                assigned = next((row for row in rows if isinstance(row, dict) and (
                    (record.get("agentID") and row.get("id") == record["agentID"])
                    or (session_id and canonical_uuid(row.get("sessionID")) == session_id))), None)
                if assigned and mode in {"new", "fork"} and canonical_uuid(assigned.get("sessionID")):
                    # A nested new Codex process must not inherit its parent's
                    # existing writer workspace just through environment values.
                    record.pop("agentID", None)
                    assigned = None
                saved = assigned.get("workspace") if assigned else None
            except (OSError, ValueError, AttributeError, TypeError):
                record["note"] = "Task context is incomplete; tracking is retained for reconciliation."
        if not saved and session_id:
            matches = []
            for context in (support / "tasks").glob("*/context.json"):
                if context.is_symlink() or context.parent.is_symlink():
                    continue
                try:
                    rows = json.loads(context.read_text()).get("subtasks") or []
                    for row in rows:
                        if isinstance(row, dict) and canonical_uuid(row.get("sessionID")) == session_id and isinstance(row.get("workspace"), dict):
                            matches.append((context.parent.name, row))
                except (OSError, ValueError, AttributeError, TypeError):
                    continue
            if len(matches) > 1:
                raise EntryError("Multiple task records own this conversation. Resolve its placement before resuming.")
            if matches:
                task_id, row = matches[0]
                saved = row["workspace"]
                record.update(taskID=task_id, agentID=row.get("id"))
                write_private_json(path, record)
        existing = os.environ.get("FOCUS_QUEUE_WORKSPACE_MODE") == "existing"
        if saved and (not isinstance(saved.get("path"), str) or not Path(saved["path"]).is_absolute() or not Path(saved["path"]).is_dir()):
            raise EntryError("The saved workspace is missing. Restore it from the task before resuming; no replacement was created.")
        if saved:
            workspace = str(Path(saved["path"]).resolve())
            if mode in {"new", "fork"} and workspace != source:
                raise EntryError("The launch directory differs from this agent's assigned workspace.")
            if saved.get("branch"):
                actual = git(workspace, ["branch", "--show-current"]).stdout.strip()
                if actual != saved["branch"]:
                    raise EntryError("The assigned branch changed. Restore it before launching this agent.")
            record["workspacePolicy"] = "assigned"
        elif mode not in {"new", "fork"} or not isolate or role != "coding" or existing:
            record["workspacePolicy"] = "resume" if mode == "resume" else "existing-requested" if existing else "noninteractive-existing" if not isolate else role
        else:
            if any(part.lower().endswith(".app") for part in Path(source).parts):
                raise EntryError("Choose source files instead of an application bundle.")
            repository = git(source, ["rev-parse", "--show-toplevel"], required=False)
            if repository.returncode:
                record["workspacePolicy"] = "non-git"
                record["note"] = "No Git checkout; workspace isolation is unavailable. Tracking remains active."
            else:
                commit = git(source, ["rev-parse", "HEAD"], required=False)
                if commit.returncode:
                    record["workspacePolicy"] = "unborn-repository"
                    record["note"] = "No committed base yet. Create the initial commit before isolated coding."
                else:
                    base = git(source, ["branch", "--show-current"]).stdout.strip()
                    destination = support / "worktrees/external" / launch_id
                    if destination.parent.is_symlink() or destination.parent.parent.is_symlink():
                        raise EntryError("The worktree storage is redirected; review it before launching.")
                    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    branch = "focus-queue/agent-" + launch_id
                    git(source, ["worktree", "add", "-b", branch, str(destination), commit.stdout.strip()])
                    workspace = str(destination)
                    record.update(workspacePolicy="isolated", repositoryPath=repository.stdout.strip(),
                                  branch=branch, baseBranch=base, baseCommit=commit.stdout.strip())
                    if git(source, ["status", "--porcelain"]).stdout.strip():
                        record["note"] = "Source edits retained; this agent uses the committed snapshot."
        record.update(cwd=workspace, phase="ready")
        write_private_json(path, record)
        os.environ["FOCUS_QUEUE_LAUNCH_ID"] = launch_id
        return path, record, workspace_arguments(arguments, workspace)
    except BaseException as error:
        record.update(phase="blocked", note=str(error)[:500])
        write_private_json(path, record)
        raise


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
            stream.flush()
            os.fsync(stream.fileno())
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
    mode, session_id = invocation(arguments, classify_agents=True)
    interactive = sys.stdin.isatty() and sys.stdout.isatty()
    bypass = (bool(os.environ.get("TMUX")) or
              os.environ.get("FOCUS_QUEUE_RUNTIME_MODE") == "terminal" or
              os.environ.get("FOCUS_QUEUE_CODEX_TMUX") == "off")
    command = ["/bin/bash", str(options.usage_wrapper), *options.default_flag, *arguments]
    # Utility commands do not create agents. Explicit exec/review invocations do.
    creates_agent = mode != "utility"
    if mode == "noninteractive":
        interactive = False
    if not creates_agent:
        os.execv(command[0], command)
    intake_path, intake, arguments = begin_tracking(arguments, mode, session_id,
        support_directory(os.environ), isolate=interactive)
    command = ["/bin/bash", str(options.usage_wrapper), *options.default_flag, *arguments]
    os.chdir(intake["cwd"])
    if not interactive:
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
    intake["reference"] = reference
    write_private_json(intake_path, intake)
    # Attachment failure leaves the already-started agent available in Focus Queue.
    os.execv(str(options.helper), [str(options.helper), "tmux", "attach", name, "--pane", pane])


if __name__ == "__main__":
    try:
        main()
    except (EntryError, OSError) as error:
        print(f"Codex: {error}", file=sys.stderr)
        raise SystemExit(1)
