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
import stat as stat_module


USAGE_ADAPTER = Path(__file__).with_name("focus_queue_usage_wrapper.sh")


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


def automatic_routing_enabled(support):
    """Read only the opt-in flag. An unsafe or malformed file fails closed."""
    path = Path(support) / "config.json"
    try:
        metadata = path.lstat()
        if (path.is_symlink() or not stat_module.S_ISREG(metadata.st_mode)
                or metadata.st_size > 1_048_576):
            return False
        return json.loads(path.read_text()).get("automaticAgentRouting") is True
    except (OSError, ValueError, TypeError, AttributeError):
        return False


def agent_usage_bar_enabled(support):
    """The managed terminal usage bar is on unless a valid config opts out."""
    path = Path(support) / "config.json"
    try:
        metadata = path.lstat()
        if (path.is_symlink() or not stat_module.S_ISREG(metadata.st_mode)
                or metadata.st_size > 1_048_576):
            return True
        return json.loads(path.read_text()).get("agentUsageBarEnabled", True) is not False
    except (OSError, ValueError, TypeError, AttributeError):
        return True


def should_route_automatically(mode, interactive, environment, support):
    """Only a fresh, unassigned top-level agent can become an intake router."""
    return (mode == "new" and interactive
            and environment.get("FOCUS_QUEUE_ROUTER") != "1"
            and environment.get("FOCUS_QUEUE_RUNTIME_MODE") not in {"tmux", "terminal"}
            and not environment.get("FOCUS_QUEUE_TASK_ID")
            and not environment.get("FOCUS_QUEUE_SUBTASK_ID")
            and automatic_routing_enabled(support))


def should_run_explicit_router(mode, interactive, environment):
    """A queue-composer router is already explicit and must skip normal intake."""
    return (mode == "new" and interactive
            and environment.get("FOCUS_QUEUE_ROUTER") == "1"
            and environment.get("FOCUS_QUEUE_ROUTER_SOURCE") == "queue-composer"
            and environment.get("FOCUS_QUEUE_RUNTIME_MODE") not in {"tmux", "terminal"}
            and not environment.get("FOCUS_QUEUE_TASK_ID")
            and not environment.get("FOCUS_QUEUE_SUBTASK_ID"))


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


def existing_task_hint(prompt, support):
    if not prompt:
        return None
    candidates = {match.upper() for match in re.findall(r"(?<![A-Za-z0-9_])([A-Za-z][A-Za-z0-9_]*-[0-9]+)(?![A-Za-z0-9_])", prompt)}
    matches = []
    for ticket_id in candidates:
        task = support / "tasks" / ticket_id
        if task.is_dir() and not task.is_symlink():
            matches.append(ticket_id)
    return matches[0] if len(matches) == 1 else None


def canonical_repository_root(source):
    common = git(source, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout.strip()
    path = Path(common).resolve()
    if path.name != ".git":
        raise EntryError("Focus Queue needs a non-bare Git repository before it can create an isolated workspace.")
    return path.parent


def repository_identity(source):
    common = git(source, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout.strip()
    path = Path(common).resolve()
    try:
        metadata = path.lstat()
    except OSError as error:
        raise EntryError("The repository identity could not be verified.") from error
    if not stat_module.S_ISDIR(metadata.st_mode) or path.is_symlink():
        raise EntryError("The repository identity is redirected or is not a directory.")
    return f"{path}:{metadata.st_dev}:{metadata.st_ino}"


def same_repository_identity(left, right):
    """Compare canonical filesystem identity across macOS path aliases."""
    if not isinstance(left, str) or not isinstance(right, str):
        return False
    try:
        left_path, left_device, left_inode = left.rsplit(":", 2)
        right_path, right_device, right_inode = right.rsplit(":", 2)
    except ValueError:
        return False
    return (left_device == right_device and left_inode == right_inode
            and Path(left_path).resolve() == Path(right_path).resolve())


def path_within(path, root):
    candidate = str(Path(path).resolve()).casefold()
    boundary = str(Path(root).resolve()).casefold()
    return candidate == boundary or candidate.startswith(boundary + os.sep)


def reject_application_support(path, support):
    default_support = Path.home() / "Library/Application Support/ECC Focus Queue"
    if path_within(path, support) or path_within(path, default_support):
        raise EntryError("Coding workspaces cannot be stored in ECC Focus Queue Application Support. "
                         "Choose a source checkout under Documents or another project directory.")


def reject_coding_location(path, support):
    reject_application_support(path, support)
    common = git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"], required=False)
    if common.returncode == 0:
        reject_application_support(Path(common.stdout.strip()).resolve(), support)


def read_managed_marker(path):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise EntryError("The managed worktree ownership marker could not be opened safely.") from error
    try:
        metadata = os.fstat(descriptor)
        if (not stat_module.S_ISREG(metadata.st_mode) or metadata.st_size > 65536
                or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022):
            raise EntryError("The managed worktree ownership marker is not a safe regular file.")
        with os.fdopen(descriptor, "r", closefd=False) as stream:
            try:
                return json.load(stream)
            except (ValueError, UnicodeError) as error:
                raise EntryError("The managed worktree ownership marker is unreadable.") from error
    finally:
        os.close(descriptor)


def write_managed_marker(path, value):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        data = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise EntryError("The managed worktree ownership marker could not be written.")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def managed_root(primary):
    return Path(primary).resolve() / ".worktrees"


def legacy_managed_root(primary):
    primary = Path(primary).resolve()
    return primary.parent / (primary.name + "-worktrees")


def ensure_managed_root_excluded(primary):
    primary = Path(primary).resolve()
    result = git(primary, ["rev-parse", "--git-path", "info/exclude"])
    exclude = Path(result.stdout.strip())
    if not exclude.is_absolute():
        exclude = primary / exclude
    exclude.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(exclude, flags, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if (not stat_module.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                or metadata.st_mode & 0o022):
            raise EntryError("The repository's local exclude file is not safe to update.")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        with os.fdopen(descriptor, "r+", closefd=False) as stream:
            previous = stream.read()
            if "/.worktrees/" not in previous.splitlines():
                separator = "" if not previous or previous.endswith("\n") else "\n"
                stream.seek(0, os.SEEK_END)
                stream.write(separator + "# Local Focus Queue worktrees\n/.worktrees/\n")
                stream.flush()
                os.fsync(descriptor)
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def prepare_managed_root(primary, *, create=True, root=None):
    primary = Path(primary).resolve()
    root = Path(root).absolute() if root is not None else managed_root(primary)
    if root == managed_root(primary):
        ensure_managed_root_excluded(primary)
    expected = {"schemaVersion": 1, "repositoryPath": str(primary),
                "repositoryIdentity": repository_identity(primary)}
    try:
        root_metadata = root.lstat()
    except FileNotFoundError:
        if not create:
            raise EntryError(f"Managed worktree storage is missing: {root}")
        try:
            root.mkdir(mode=0o700)
        except FileExistsError:
            pass
        root_metadata = root.lstat()
    except OSError as error:
        raise EntryError("Managed worktree storage metadata could not be inspected safely.") from error
    if (not stat_module.S_ISDIR(root_metadata.st_mode) or root.is_symlink()
            or root.resolve() != root or root_metadata.st_uid != os.geteuid()
            or root_metadata.st_mode & 0o022):
        raise EntryError("Managed worktree storage must be owned by the current user, "
                         "not writable by other users, and not redirected.")

    marker = root / ".focus-queue-worktrees.json"
    try:
        marker_metadata = marker.lstat()
    except FileNotFoundError:
        if any(root.iterdir()):
            raise EntryError("Managed worktree storage is nonempty but has no ownership marker.")
        if not create:
            raise EntryError("Managed worktree storage has no ownership marker.")
        try:
            write_managed_marker(marker, expected)
        except FileExistsError:
            pass
        marker_metadata = marker.lstat()
    except OSError as error:
        raise EntryError("Managed worktree ownership marker could not be inspected safely.") from error
    if (not stat_module.S_ISREG(marker_metadata.st_mode) or marker.is_symlink()
            or marker_metadata.st_uid != os.geteuid() or marker_metadata.st_mode & 0o022):
        raise EntryError("Managed worktree ownership marker must be owned by the current user, "
                         "not writable by other users, and not redirected.")
    actual = read_managed_marker(marker)
    if (not isinstance(actual, dict)
            or actual.get("schemaVersion") != expected["schemaVersion"]
            or not isinstance(actual.get("repositoryPath"), str)
            or Path(actual["repositoryPath"]).resolve() != Path(expected["repositoryPath"]).resolve()
            or not same_repository_identity(actual.get("repositoryIdentity"), expected["repositoryIdentity"])):
        raise EntryError("Managed worktree storage belongs to a different repository.")
    return root


def saved_managed_root(primary, workspace):
    workspace = Path(workspace).absolute()
    for root in (managed_root(primary), legacy_managed_root(primary)):
        try:
            workspace.relative_to(root)
        except ValueError:
            continue
        return prepare_managed_root(primary, create=False, root=root)
    raise EntryError("Managed workspace path escapes its repository-owned root.")


def validate_managed_ancestors(root, candidate, *, create=False):
    root = Path(root).absolute()
    candidate = Path(candidate).absolute()
    try:
        relative = candidate.relative_to(root)
    except ValueError as error:
        raise EntryError("Managed workspace path escapes its repository-owned root.") from error
    current = root
    for component in (Path("."), *relative.parts):
        if component != Path("."):
            current = current / component
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            if not create:
                break
            try:
                current.mkdir(mode=0o700)
            except FileExistsError:
                pass
            metadata = current.lstat()
        except OSError as error:
            raise EntryError("Managed workspace metadata could not be inspected safely.") from error
        if (not stat_module.S_ISDIR(metadata.st_mode) or current.is_symlink()
                or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022):
            raise EntryError(f"Managed workspace ancestor is redirected, writable by other users, "
                             f"or is not owned by the current user: {current}")
        if not path_within(current, root):
            raise EntryError(f"Managed workspace ancestor resolves outside its repository-owned root: {current}")


def notify_intake_changed(helper):
    try:
        subprocess.run([str(helper), "intake-changed"], capture_output=True, text=True,
                       timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        pass


def begin_tracking(arguments, mode, session_id, support, *, isolate=True, on_change=None):
    """Persist intent first. Unknown task/session/configuration fields stay optional."""
    support = support.resolve()
    directory = support / "tracking/launches"
    placement_directory = support / "tracking/placements"
    for path in (support / "tracking", directory, placement_directory):
        if path.is_symlink():
            raise EntryError("Tracking storage is redirected. Restore it before launching an agent.")
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
    launch_id = str(uuid.uuid4())
    path = directory / (launch_id + ".json")
    placement_path = placement_directory / (launch_id + ".json")
    source = selected_directory(arguments)
    role = os.environ.get("FOCUS_QUEUE_AGENT_ROLE", "coding")
    if role not in {"coding", "research", "orchestrator"}:
        role = "coding"
    record = {"schemaVersion": 1, "launchID": launch_id, "provider": "codex", "mode": mode,
              "role": role, "sourceCwd": source, "cwd": source, "processID": os.getpid(),
              "createdAt": datetime.now(timezone.utc).isoformat(), "phase": "preparing",
              "title": (initial_prompt(arguments) or "Codex agent").splitlines()[0][:120],
              "placementPath": str(placement_path)}
    os.environ["FOCUS_QUEUE_AGENT_CONTEXT"] = str(placement_path)
    started = subprocess.run(["/bin/ps", "-p", str(os.getpid()), "-o", "lstart="],
                             capture_output=True, text=True, timeout=5)
    record["processStartedAt"] = " ".join(started.stdout.split()) if started.returncode == 0 else None
    inherited_task_id = os.environ.get("FOCUS_QUEUE_TASK_ID")
    inherited_agent_id = os.environ.get("FOCUS_QUEUE_SUBTASK_ID")
    if session_id:
        record["sessionID"] = session_id
    else:
        if inherited_task_id:
            record["taskID"] = inherited_task_id
        if inherited_agent_id:
            record["agentID"] = inherited_agent_id
    if "taskID" not in record and not session_id:
        task_id = existing_task_hint(initial_prompt(arguments), support)
        if task_id:
            record["taskID"] = task_id
            record["agentID"] = launch_id

    def persist():
        write_private_json(path, record)
        if on_change is not None:
            on_change(record.copy())

    persist()  # Failure here must prevent provider execution.
    try:
        if role == "coding":
            reject_coding_location(source, support)
        workspace = source
        saved = None
        task_id = record.get("taskID", "") or ((inherited_task_id or "") if session_id else "")
        matched_session_assignment = False
        if re.fullmatch(r"[A-Za-z0-9_-]+", task_id):
            context = support / "tasks" / task_id.upper() / "context.json"
            try:
                value = json.loads(context.read_text())
                rows = value.get("subtasks") or []
                assigned = next((row for row in rows if isinstance(row, dict) and (
                    (session_id and canonical_uuid(row.get("sessionID")) == session_id)
                    or (not session_id and record.get("agentID") and row.get("id") == record["agentID"]))), None)
                if assigned and session_id:
                    matched_session_assignment = True
                    record.update(taskID=task_id.upper(), agentID=assigned.get("id"))
                if assigned and mode in {"new", "fork"} and canonical_uuid(assigned.get("sessionID")):
                    # A nested new Codex process must not inherit its parent's
                    # existing writer workspace just through environment values.
                    record.pop("agentID", None)
                    assigned = None
                candidate = assigned.get("workspace") if assigned else None
                saved = candidate if isinstance(candidate, dict) else None
            except (OSError, ValueError, AttributeError, TypeError):
                record["note"] = "Task context is incomplete; tracking is retained for reconciliation."
        if session_id and not matched_session_assignment:
            matches = []
            for context in (support / "tasks").glob("*/context.json"):
                if context.is_symlink() or context.parent.is_symlink():
                    continue
                try:
                    rows = json.loads(context.read_text()).get("subtasks") or []
                    for row in rows:
                        if isinstance(row, dict) and canonical_uuid(row.get("sessionID")) == session_id:
                            matches.append((context.parent.name, row))
                except (OSError, ValueError, AttributeError, TypeError):
                    continue
            if len(matches) > 1:
                raise EntryError("Multiple task records own this conversation. Resolve its placement before resuming.")
            if matches:
                task_id, row = matches[0]
                candidate = row.get("workspace")
                saved = candidate if isinstance(candidate, dict) else None
                record.update(taskID=task_id, agentID=row.get("id"))
                persist()
            else:
                record.pop("taskID", None)
                record.pop("agentID", None)
                task_id = ""
        existing = os.environ.get("FOCUS_QUEUE_WORKSPACE_MODE") == "existing"
        if saved and (not isinstance(saved.get("path"), str) or not Path(saved["path"]).is_absolute() or not Path(saved["path"]).is_dir()):
            raise EntryError("The saved workspace is missing. Restore it from the task before resuming; no replacement was created.")
        if saved:
            workspace = str(Path(saved["path"]).resolve())
            if role == "coding":
                reject_coding_location(workspace, support)
            if saved.get("managed") is True:
                if not isinstance(saved.get("repositoryPath"), str) or not saved["repositoryPath"]:
                    raise EntryError("The managed workspace record is missing its repository identity.")
                saved_primary = canonical_repository_root(saved["repositoryPath"])
                saved_root = saved_managed_root(saved_primary, workspace)
                validate_managed_ancestors(saved_root, workspace)
                agent_id = record.get("agentID")
                if (not re.fullmatch(r"[A-Za-z0-9_-]+", task_id)
                        or not isinstance(agent_id, str)
                        or not re.fullmatch(r"[A-Za-z0-9_-]+", agent_id)):
                    raise EntryError("The managed workspace record is missing its task assignment identity.")
                expected_workspace = saved_root / task_id.lower() / "agents" / agent_id.lower()
                if Path(workspace) != expected_workspace:
                    raise EntryError("The managed workspace is outside this agent's exact assigned location.")
                actual_primary = canonical_repository_root(workspace)
                expected_identity = repository_identity(saved_primary)
                if actual_primary != saved_primary or repository_identity(workspace) != expected_identity:
                    raise EntryError("The managed workspace belongs to a different repository.")
                if (saved.get("repositoryIdentity") is not None
                        and not same_repository_identity(saved["repositoryIdentity"], expected_identity)):
                    raise EntryError("The managed workspace repository identity changed.")
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
                    primary = canonical_repository_root(source)
                    reject_application_support(primary, support)
                    managed_root = prepare_managed_root(primary)
                    bucket = (managed_root / task_id.lower() / "agents"
                              if re.fullmatch(r"[A-Za-z0-9_-]+", task_id)
                              else managed_root / "unassigned")
                    destination = bucket / launch_id.lower()
                    validate_managed_ancestors(managed_root, destination.parent, create=True)
                    branch = "focus-queue/agent-" + launch_id
                    git(source, ["worktree", "add", "-b", branch, str(destination), commit.stdout.strip()])
                    validate_managed_ancestors(managed_root, destination)
                    workspace = str(destination)
                    record.update(workspacePolicy="isolated", repositoryPath=str(primary),
                                  branch=branch, baseBranch=base, baseCommit=commit.stdout.strip())
                    if git(source, ["status", "--porcelain"]).stdout.strip():
                        record["note"] = "Source edits retained; this agent uses the committed snapshot."
        record.update(cwd=workspace, phase="ready")
        persist()
        os.environ["FOCUS_QUEUE_LAUNCH_ID"] = launch_id
        return path, record, workspace_arguments(arguments, workspace)
    except BaseException as error:
        record.update(phase="blocked", note=str(error)[:500])
        persist()
        raise


def run_json(helper, arguments):
    try:
        result = subprocess.run([str(helper), *arguments], capture_output=True, text=True,
                                timeout=35, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise EntryError(f"Focus Queue could not check the terminal: {error}") from error
    if result.returncode:
        raise EntryError(result.stderr.strip()[:600] or "Focus Queue could not verify the terminal.")
    if result.stderr.strip():
        print(result.stderr.strip(), file=sys.stderr)
    try:
        return json.loads(result.stdout)
    except ValueError as error:
        raise EntryError("Focus Queue returned an incomplete terminal record. Check the app before retrying.") from error


def apply_placement(helper, intake_path, intake, prompt):
    """Resolve project/task ownership before the provider starts."""
    launch_id = canonical_uuid(intake.get("launchID"))
    if not launch_id:
        raise EntryError("The launch receipt has no valid placement identity.")
    provisional_agent = intake.get("agentID") or launch_id
    os.environ["FOCUS_QUEUE_SUBTASK_ID"] = provisional_agent
    arguments = ["placement", "--launch", launch_id, "--cwd", intake["cwd"]]
    if intake.get("taskID"):
        arguments.extend(["--task", intake["taskID"]])
    if prompt:
        arguments.extend(["--prompt", prompt])
    else:
        arguments.append("--no-create")
    placement = run_json(helper, arguments)
    if not isinstance(placement, dict) or placement.get("launchID") != launch_id:
        raise EntryError("Focus Queue returned a placement for a different launch.")
    expected_path = str(Path(intake["placementPath"]).resolve())
    if str(Path(placement.get("capsulePath", "")).resolve()) != expected_path:
        raise EntryError("Focus Queue returned an unexpected placement capsule path.")
    if placement.get("status") == "blocked-conflict":
        raise EntryError(placement.get("reason") or
                         "The requested task and working directory identify different projects.")
    task_id = placement.get("taskID")
    if task_id is not None and not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*-[0-9]+", task_id):
        raise EntryError("Focus Queue returned an invalid task ID.")
    existing_task = intake.get("taskID")
    if existing_task and task_id and existing_task.casefold() != task_id.casefold():
        raise EntryError("Focus Queue tried to replace the launch's existing task assignment.")
    intake["placementStatus"] = placement.get("status")
    intake["projectID"] = placement.get("projectID")
    if task_id:
        intake["taskID"] = task_id.upper()
        intake["agentID"] = provisional_agent
        os.environ["FOCUS_QUEUE_TASK_ID"] = intake["taskID"]
    write_private_json(intake_path, intake)
    return placement


@contextmanager
def resume_lock(support, session_id):
    try:
        support.mkdir(parents=True, exist_ok=True, mode=0o700)
        root = os.open(support, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as error:
        raise EntryError("Resume receipt storage is redirected or unsafe.") from error
    try:
        # Older installs created these app-owned parent directories with the
        # process umask. Tighten them through the already-open no-follow file
        # descriptor before validating descendants.
        os.fchmod(root, 0o700)
        validate_private_directory(root, "resume receipt root")
        shell = open_private_directory(root, "shell", "resume receipt parent", repair_permissions=True)
        try:
            directory = open_private_directory(shell, "resume-receipts", "resume receipt directory")
        finally:
            os.close(shell)
    except BaseException:
        os.close(root)
        raise
    os.close(root)
    lock_leaf = f"{session_id}.lock"
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(lock_leaf, flags, 0o600, dir_fd=directory)
        validate_private_file(descriptor, "resume lock")
    except BaseException:
        os.close(directory)
        raise EntryError("Resume receipt storage is redirected or unsafe.")
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
        yield ResumeReceiptStore(directory, f"{session_id}.json")
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)
        os.close(directory)


def validate_private_directory(descriptor, purpose):
    metadata = os.fstat(descriptor)
    if (not stat_module.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid()
            or metadata.st_mode & 0o077):
        raise EntryError(f"The {purpose} must be a private directory owned by the current user.")


def open_private_directory(parent, leaf, purpose, *, repair_permissions=False):
    try:
        os.mkdir(leaf, mode=0o700, dir_fd=parent)
    except FileExistsError:
        pass
    try:
        descriptor = os.open(leaf, os.O_RDONLY | os.O_DIRECTORY
                             | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent)
        if repair_permissions:
            os.fchmod(descriptor, 0o700)
        validate_private_directory(descriptor, purpose)
        return descriptor
    except BaseException as error:
        if "descriptor" in locals():
            os.close(descriptor)
        if isinstance(error, EntryError):
            raise
        raise EntryError(f"The {purpose} is redirected or unsafe.") from error


def validate_private_file(descriptor, purpose):
    metadata = os.fstat(descriptor)
    if (not stat_module.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
            or metadata.st_mode & 0o077 or metadata.st_nlink != 1):
        raise EntryError(f"The {purpose} must be a private regular file owned by the current user.")


class ResumeReceiptStore:
    def __init__(self, directory, leaf):
        self.directory = directory
        self.leaf = leaf

    def read(self):
        try:
            descriptor = os.open(self.leaf, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                                 dir_fd=self.directory)
        except FileNotFoundError:
            return None
        except OSError as error:
            raise EntryError("The previous resume receipt cannot be read safely.") from error
        try:
            validate_private_file(descriptor, "resume receipt")
            with os.fdopen(descriptor, "r", closefd=False) as stream:
                return json.load(stream)
        except (OSError, ValueError) as error:
            raise EntryError("The previous resume receipt cannot be read. Check the existing session before retrying.") from error
        finally:
            os.close(descriptor)

    def write(self, value):
        try:
            metadata = os.stat(self.leaf, dir_fd=self.directory, follow_symlinks=False)
            if (not stat_module.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                    or metadata.st_mode & 0o077 or metadata.st_nlink != 1):
                raise EntryError("The previous resume receipt is redirected or unsafe.")
        except FileNotFoundError:
            pass
        temporary = f".resume-{uuid.uuid4().hex}.tmp"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                             | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=self.directory)
        try:
            with os.fdopen(descriptor, "w", closefd=False) as stream:
                json.dump(value, stream)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.leaf,
                       src_dir_fd=self.directory, dst_dir_fd=self.directory)
            os.fsync(self.directory)
        finally:
            os.close(descriptor)
            try:
                os.unlink(temporary, dir_fd=self.directory)
            except FileNotFoundError:
                pass


def read_receipt(store, session_id, panes):
    saved = store.read()
    if saved is None:
        return None
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
    for field in ("serverPID", "createdAt", "panePID"):
        value = reference.get(field)
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            raise EntryError("The terminal has an incomplete process identity.")
    tty, executable = reference.get("tty"), reference.get("executable")
    if (not isinstance(tty, str) or not tty.startswith("/dev/") or "\x00" in tty
            or not isinstance(executable, str) or not Path(executable).is_absolute()
            or "\x00" in executable):
        raise EntryError("The terminal has an incomplete process identity.")
    return name, pane


def runtime_reference(location):
    fields = ("name", "serverPID", "createdAt", "paneID", "panePID", "tty", "executable")
    reference = {field: location.get(field) for field in fields}
    validate_reference(reference)
    return reference


def managed_current_reference(helper, task_id=None, agent_id=None):
    name = os.environ.get("FOCUS_QUEUE_TMUX_NAME")
    pane = os.environ.get("TMUX_PANE")
    server = os.environ.get("FOCUS_QUEUE_TMUX_SERVER", "ecc-focus-queue")
    if (not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", name)
            or not isinstance(pane, str) or not re.fullmatch(r"%[0-9]+", pane)
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", server)):
        raise EntryError("The managed tmux pane identity is incomplete. Reopen it from Focus Queue.")
    arguments = ["tmux", "reference", name, pane]
    if task_id is not None or agent_id is not None:
        if not (isinstance(task_id, str) and isinstance(agent_id, str)):
            raise EntryError("The managed task pane identity is incomplete.")
        arguments.extend(["--task", task_id, "--agent", agent_id])
    arguments.extend(["--server", server])
    reference = run_json(helper, arguments)
    exact_name, exact_pane = validate_reference(reference)
    if exact_name != name or exact_pane != pane:
        raise EntryError("The managed tmux pane changed before tracking was confirmed.")
    return reference


def usage_command(wrapper, flags, arguments):
    command = (["/bin/bash", str(USAGE_ADAPTER), str(wrapper), "--"]
               if USAGE_ADAPTER.is_file() else ["/bin/bash", str(wrapper)])
    return [*command, *flags, *arguments]


def start(helper, name, command, *, prompt=None, support=None, task_id=None, agent_id=None):
    if task_id is not None or agent_id is not None:
        if not (isinstance(task_id, str) and isinstance(agent_id, str)
                and re.fullmatch(r"[A-Za-z0-9_-]+", task_id)
                and re.fullmatch(r"[A-Za-z0-9_-]+", agent_id)):
            raise EntryError("The task pane assignment has an invalid identity.")
        launch = ["tmux", "start-agent", task_id, agent_id]
    else:
        launch = ["tmux", "start", name]
    reference = run_json(helper, [*launch, "--cwd", os.getcwd(), "--",
        "/usr/bin/env", "FOCUS_QUEUE_RUNTIME_MODE=tmux", "FOCUS_QUEUE_PROVIDER=codex",
        "FOCUS_QUEUE_MANAGED_TMUX=1", *command])
    validate_reference(reference)
    if support is not None:
        try:
            metadata = support / "shell/launch-metadata"
            metadata.mkdir(parents=True, exist_ok=True, mode=0o700)
            value = {"schemaVersion": 1, "provider": "codex", "cwd": os.getcwd(),
                     "launchedAt": datetime.now(timezone.utc).isoformat(), "reference": reference}
            if prompt is not None:
                value["initialPrompt"] = prompt
            metadata_name = name or f"{reference['name']}-{agent_id}"
            write_private_json(metadata / f"{metadata_name}.json", value)
        except OSError:
            print("Codex started, but its title metadata could not be saved. Session discovery remains active.", file=sys.stderr)
    return reference


def choose_resume(helper, session_id, command, support, *, prompt=None, task_id=None, agent_id=None):
    with resume_lock(support, session_id) as receipt:
        location = run_json(helper, ["runtime", "locate", "codex", session_id])
        if not isinstance(location, dict) or location.get("status") not in {"running", "stopped"}:
            raise EntryError("Focus Queue could not confirm whether this conversation is already running. Check it in the app before resuming.")
        if location["status"] == "running":
            if location.get("runtime") != "tmux" or not location.get("tmuxName"):
                raise EntryError("This conversation is already running in another terminal. Open its existing session in Focus Queue.")
            reference = runtime_reference(location)
            if location["tmuxName"] != reference["name"]:
                raise EntryError("The running conversation has conflicting terminal identity.")
            if task_id is not None or agent_id is not None:
                expected_name = "fq-task-" + task_id.lower()
                if reference["name"] != expected_name:
                    raise EntryError("The running conversation belongs to another task.")
                if location.get("agentID") != agent_id:
                    raise EntryError("The running conversation belongs to another agent.")
            return reference
        panes = run_json(helper, ["tmux", "list"])
        if not isinstance(panes, list) or not all(isinstance(pane, dict) for pane in panes):
            raise EntryError("Focus Queue could not inspect the managed terminals.")
        if previous := read_receipt(receipt, session_id, panes):
            validate_reference(previous)
            return previous
        name = "fq-task-" + task_id.lower() if task_id and agent_id else "fq-codex-" + session_id
        if not task_id and any(pane.get("name") == name for pane in panes):
            # A restored shell or unrelated pane must keep its contents and process.
            name += "-" + uuid.uuid4().hex[:8]
        receipt.write({"sessionID": session_id, "tmuxName": name, "pending": True})
        reference = start(helper, name, command, prompt=prompt, support=support,
                          task_id=task_id, agent_id=agent_id)
        receipt.write({"sessionID": session_id, "reference": reference})
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
    bypass = (os.environ.get("FOCUS_QUEUE_RUNTIME_MODE") in {"tmux", "terminal"} or
              os.environ.get("FOCUS_QUEUE_CODEX_TMUX") == "off")
    command = usage_command(options.usage_wrapper, options.default_flag, arguments)
    # Utility commands do not create agents. Explicit exec/review invocations do.
    creates_agent = mode != "utility"
    if mode == "noninteractive":
        interactive = False
    if not creates_agent:
        os.execv(command[0], command)
    if should_run_explicit_router(mode, interactive, os.environ):
        os.execv(command[0], command)
    support = support_directory(os.environ)
    os.environ.setdefault(
        "FOCUS_QUEUE_USAGE_BAR", "on" if agent_usage_bar_enabled(support) else "off")
    if should_route_automatically(mode, interactive, os.environ, support):
        # The router stays in the user's current terminal and performs no source
        # writes. Its two Focus Queue commands create and verify the successor.
        os.environ["FOCUS_QUEUE_ROUTER"] = "1"
        os.execv(command[0], command)
    intake_path, intake, arguments = begin_tracking(arguments, mode, session_id,
        support, isolate=interactive,
        on_change=lambda _: notify_intake_changed(options.helper))
    try:
        apply_placement(options.helper, intake_path, intake, initial_prompt(arguments))
    except BaseException as error:
        intake.update(phase="blocked", note=str(error)[:500])
        write_private_json(intake_path, intake)
        notify_intake_changed(options.helper)
        raise
    command = usage_command(options.usage_wrapper, options.default_flag, arguments)
    os.chdir(intake["cwd"])
    if not interactive:
        os.execv(command[0], command)
    if bypass:
        if session_id:
            location = run_json(options.helper, ["runtime", "locate", "codex", session_id])
            if not isinstance(location, dict) or location.get("status") != "stopped":
                raise EntryError("This conversation is already running or could not be verified. Open its existing session in Focus Queue.")
        if os.environ.get("FOCUS_QUEUE_RUNTIME_MODE") == "tmux":
            task_id = intake.get("taskID")
            agent_id = intake.get("agentID")
            task_pane = isinstance(task_id, str) and isinstance(agent_id, str)
            intake["reference"] = managed_current_reference(options.helper,
                task_id if task_pane else None, agent_id if task_pane else None)
            write_private_json(intake_path, intake)
            notify_intake_changed(options.helper)
        os.execv(command[0], command)
    if not options.usage_wrapper.is_file():
        raise EntryError("The configured Codex usage wrapper is missing. Reinstall the shell integration.")
    task_id = intake.get("taskID")
    agent_id = intake.get("agentID")
    task_pane = (isinstance(task_id, str) and isinstance(agent_id, str)
                 and re.fullmatch(r"[A-Za-z0-9_-]+", task_id)
                 and re.fullmatch(r"[A-Za-z0-9_-]+", agent_id))
    if task_pane and not USAGE_ADAPTER.is_file():
        message = "The managed tmux usage adapter is missing. Reinstall Focus Queue before starting a task agent."
        intake.update(phase="blocked", note=message)
        write_private_json(intake_path, intake)
        notify_intake_changed(options.helper)
        raise EntryError(message)
    try:
        if session_id:
            reference = choose_resume(options.helper, session_id, command, support_directory(os.environ),
                                      prompt=initial_prompt(arguments),
                                      task_id=task_id if task_pane else None,
                                      agent_id=agent_id if task_pane else None)
        elif task_pane:
            reference = start(options.helper, None, command, prompt=initial_prompt(arguments),
                              support=support_directory(os.environ), task_id=task_id, agent_id=agent_id)
        else:
            reference = start(options.helper, "fq-codex-" + str(uuid.uuid4()), command,
                              prompt=initial_prompt(arguments), support=support_directory(os.environ))
        name, pane = validate_reference(reference)
    except BaseException as error:
        intake.update(phase="blocked", note=str(error)[:500])
        write_private_json(intake_path, intake)
        notify_intake_changed(options.helper)
        raise
    intake["reference"] = reference
    write_private_json(intake_path, intake)
    notify_intake_changed(options.helper)
    # Attachment failure leaves the already-started agent available in Focus Queue.
    attach = [str(options.helper), "tmux", "attach-reference",
              json.dumps(reference, separators=(",", ":"), sort_keys=True)]
    if task_pane:
        attach.extend(["--task", task_id, "--agent", agent_id])
    os.execv(str(options.helper), attach)


if __name__ == "__main__":
    try:
        main()
    except (EntryError, OSError) as error:
        print(f"Codex: {error}", file=sys.stderr)
        raise SystemExit(1)
