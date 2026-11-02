#!/usr/bin/env python3
"""Portable staged installation with retained backups and rollback on failure."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import sys
from urllib.parse import urlparse
import urllib.request

PRODUCT = "Focus Queue"
LEGACY_PRODUCT = "ECC Focus Queue"
IDENTIFIER = "com.haelyra.ecc-focus-queue"
TREE_DIGEST_ALGORITHM = "sha256-tree-v1"
PROMPT_START = "<!-- BEGIN ECC FOCUS QUEUE AGENT CONTRACT v1 -->"
PROMPT_END = "<!-- END ECC FOCUS QUEUE AGENT CONTRACT v1 -->"
PROVENANCE_SCHEMA_VERSION = 1
MANIFEST_VERSION = 2
DEFAULT_INTEGRATION_REF = "origin/main"
OFFICIAL_REPOSITORY_IDENTITY = "github.com/haelyra/eccfocusqueue"
PROVENANCE_FIELDS = {
    "schemaVersion",
    "repositoryIdentity",
    "originURL",
    "revision",
    "branch",
    "dirty",
    "integrationRef",
    "integrationRevision",
    "reachableRevisions",
    "builtAt",
}
REVISION_PATTERN = re.compile(r"[0-9a-f]{40}")


def utc_timestamp():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def normalize_repository_identity(remote):
    """Return a stable, credential-free identity for a Git remote."""
    if not isinstance(remote, str) or not remote.strip():
        raise ValueError("Git origin URL is missing.")
    value = remote.strip()
    scp_match = re.fullmatch(r"(?:[^@/]+@)?([^:/]+):(.+)", value)
    if scp_match and "://" not in value:
        host, repository_path = scp_match.groups()
    else:
        parsed = urlparse(value)
        if parsed.scheme and parsed.hostname:
            host = parsed.hostname
            repository_path = parsed.path
        else:
            path = Path(value).expanduser().resolve()
            return path.with_suffix("").as_posix().rstrip("/").lower()
    repository_path = repository_path.strip("/")
    if repository_path.lower().endswith(".git"):
        repository_path = repository_path[:-4]
    if not host or not repository_path:
        raise ValueError("Git origin URL does not identify a repository.")
    return f"{host.lower()}/{repository_path.lower()}"


def sanitize_repository_url(remote):
    """Remove credentials and URL parameters before embedding a remote."""
    if not isinstance(remote, str) or not remote.strip():
        raise ValueError("Git origin URL is missing.")
    value = remote.strip()
    scp_match = re.fullmatch(r"(?:[^@/]+@)?([^:/]+):(.+)", value)
    if scp_match and "://" not in value:
        host, repository_path = scp_match.groups()
        return f"{host}:{repository_path}"
    parsed = urlparse(value)
    if parsed.scheme and parsed.hostname:
        authority = parsed.hostname
        if parsed.port is not None:
            authority += f":{parsed.port}"
        return f"{parsed.scheme}://{authority}{parsed.path}"
    return value


def _git(repository, *arguments):
    try:
        result = subprocess.run(
            ["/usr/bin/git", *arguments],
            cwd=repository,
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.SubprocessError as error:
        detail = getattr(error, "stderr", "") or str(error)
        raise ValueError(f"Could not capture Git source provenance: {detail.strip()}") from error
    return result.stdout.strip()


def split_integration_ref(integration_ref):
    try:
        remote, branch = integration_ref.split("/", 1)
    except ValueError as error:
        raise ValueError("The integration ref must name a remote branch.") from error
    if not remote or not branch:
        raise ValueError("The integration ref must name a remote branch.")
    return remote, branch


def parse_remote_revision(output, branch):
    rows = [line.split() for line in output.splitlines() if line.strip()]
    if len(rows) != 1 or len(rows[0]) != 2 or rows[0][1] != f"refs/heads/{branch}":
        raise ValueError("The canonical integration revision is unavailable from the remote.")
    revision = rows[0][0]
    if not REVISION_PATTERN.fullmatch(revision):
        raise ValueError("The remote returned an invalid integration revision.")
    return revision


def remote_integration_revision(repository, integration_ref):
    remote, branch = split_integration_ref(integration_ref)
    output = _git(repository, "ls-remote", "--exit-code", remote, f"refs/heads/{branch}")
    return parse_remote_revision(output, branch)


def validate_primary_checkout(repository):
    top_level = Path(
        _git(repository, "rev-parse", "--path-format=absolute", "--show-toplevel")
    ).resolve()
    common_directory = Path(
        _git(repository, "rev-parse", "--path-format=absolute", "--git-common-dir")
    ).resolve()
    if top_level != repository or common_directory != (repository / ".git").resolve():
        raise ValueError(
            "Release provenance may only be written from the primary canonical checkout."
        )


def capture_source_provenance(repository, integration_ref=DEFAULT_INTEGRATION_REF):
    repository = Path(repository).resolve()
    validate_primary_checkout(repository)
    origin_url = _git(repository, "config", "--get", "remote.origin.url")
    revision = _git(repository, "rev-parse", "HEAD")
    integration_revision = remote_integration_revision(repository, integration_ref)
    branch = _git(repository, "branch", "--show-current") or "HEAD"
    reachable = _git(repository, "rev-list", "HEAD").splitlines()
    dirty = bool(_git(repository, "status", "--porcelain", "--untracked-files=normal"))
    provenance = {
        "schemaVersion": PROVENANCE_SCHEMA_VERSION,
        "repositoryIdentity": normalize_repository_identity(origin_url),
        "originURL": sanitize_repository_url(origin_url),
        "revision": revision,
        "branch": branch,
        "dirty": dirty,
        "integrationRef": integration_ref,
        "integrationRevision": integration_revision,
        "reachableRevisions": reachable,
        "builtAt": utc_timestamp(),
    }
    validate_source_provenance(provenance)
    return provenance


def _validate_timestamp(value, description):
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ValueError(f"{description} must be a UTC timestamp.")
    try:
        datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise ValueError(f"{description} must be a UTC timestamp.") from error


def validate_source_provenance(value, *, require_integrated=False):
    if not isinstance(value, dict) or set(value) != PROVENANCE_FIELDS:
        raise ValueError("The source provenance has an unrecognized schema.")
    if value.get("schemaVersion") != PROVENANCE_SCHEMA_VERSION:
        raise ValueError("The source provenance has an unrecognized schema version.")
    for field in ("repositoryIdentity", "originURL", "branch", "integrationRef"):
        if not isinstance(value.get(field), str) or not value[field].strip():
            raise ValueError(f"The source provenance field {field} is invalid.")
    if normalize_repository_identity(value["originURL"]) != value["repositoryIdentity"]:
        raise ValueError("The source provenance repository identity is inconsistent.")
    for field in ("revision", "integrationRevision"):
        if not isinstance(value.get(field), str) or not REVISION_PATTERN.fullmatch(value[field]):
            raise ValueError(f"The source provenance field {field} is not a Git revision.")
    reachable = value.get("reachableRevisions")
    if (
        not isinstance(reachable, list)
        or not reachable
        or any(not isinstance(item, str) or not REVISION_PATTERN.fullmatch(item) for item in reachable)
        or len(set(reachable)) != len(reachable)
        or value["revision"] not in reachable
    ):
        raise ValueError("The source provenance reachable revisions are invalid.")
    if type(value.get("dirty")) is not bool:
        raise ValueError("The source provenance dirty state is invalid.")
    _validate_timestamp(value.get("builtAt"), "The source provenance build time")
    if require_integrated:
        if value["integrationRef"] != DEFAULT_INTEGRATION_REF:
            raise ValueError("The candidate build does not use the canonical integration ref.")
        if value["repositoryIdentity"] != OFFICIAL_REPOSITORY_IDENTITY:
            raise ValueError("The candidate build does not come from the official repository.")
        if value["dirty"]:
            raise ValueError("The candidate build contains uncommitted changes.")
        if value["revision"] != value["integrationRevision"]:
            raise ValueError("The candidate revision is not the canonical integration revision.")
    return value


def validate_bundle_member(bundle, path):
    if not path.is_relative_to(bundle):
        raise ValueError("The built app resource is outside its bundle.")
    current = path
    while current != bundle:
        if current.is_symlink():
            raise ValueError(f"The built app contains a symlinked bundle path: {current}.")
        current = current.parent
    if bundle.is_symlink() or not path.resolve().is_relative_to(bundle.resolve()):
        raise ValueError("The built app resource escapes its bundle.")


def read_source_provenance(bundle, *, require_integrated=False):
    path = bundle / "Contents/Resources/source-provenance.json"
    validate_bundle_member(bundle, path)
    if path.is_symlink() or not path.is_file():
        raise ValueError("The built app is missing signed source provenance.")
    try:
        value = json.loads(path.read_text())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("The built app source provenance is unreadable.") from error
    return validate_source_provenance(value, require_integrated=require_integrated)


def merge_agent_prompt(original, payload, *, label):
    """Replace only our delimited block; keep personal instructions byte-for-byte."""
    if not payload.startswith(PROMPT_START) or not payload.rstrip().endswith(PROMPT_END):
        raise ValueError(f"The bundled {label} instruction block is incomplete.")
    if PROMPT_START in original or PROMPT_END in original:
        if original.count(PROMPT_START) != 1 or original.count(PROMPT_END) != 1:
            raise ValueError(f"The installed {label} instruction markers require review.")
        start, end = original.index(PROMPT_START), original.index(PROMPT_END) + len(PROMPT_END)
        if end <= start:
            raise ValueError(f"The installed {label} instruction markers are reversed.")
        return original[:start] + payload.rstrip("\n") + original[end:]
    return original + ("\n\n" if original else "") + payload
# fq and its placement classifier come from the shell-entry installers. Once fq
# is installed, every app install refreshes them, plus the Claude entry fq
# dispatches, under the same local-change rules as the configured Codex entry.
FQ_SHELL_FILES = ("focus_queue_fq.py", "focus_queue_placement.py", "focus_queue_prompt_usage.py", "focus_queue_claude_entry.py")
AUTOMATION_FILES = (
    "Scripts/focus_queue_morning.py",
    "Scripts/focus_queue_codex.py",
    "Scripts/focus_queue_claude.py",
    "Scripts/focus_queue_kimi.py",
    "Scripts/focus_queue_lock.py",
    "Scripts/focus_queue_mail.py",
    "Scripts/focus_queue_gmail.py",
    "Scripts/focus_queue_discord.py",
    "Scripts/focus_queue_slack.py",
    "Scripts/focus_queue_connectors.py",
    "Scripts/focus_queue_triage.py",
    "Scripts/focus_queue_extractor.py",
    "Scripts/focus_queue_prompt_usage.py",
    "Scripts/focus-queue-mail.js",
    "Config/task-proposals.schema.json",
)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_digest(path):
    entries = []
    if path.is_symlink() or not path.is_dir():
        raise ValueError(f"Managed directory is not a regular directory: {path}")
    for item in path.rglob("*"):
        if item.is_symlink():
            raise ValueError(f"Symlink inside managed directory requires review: {item}")
        if item.is_dir():
            continue
        if not item.is_file():
            raise ValueError(f"Special file inside managed directory requires review: {item}")
        entries.append((item.relative_to(path).as_posix().encode(), item.read_bytes()))

    value = hashlib.sha256()
    value.update(b"focus-queue-managed-tree-v1")
    value.update(len(entries).to_bytes(8, "big"))
    for relative, content in sorted(entries):
        value.update(len(relative).to_bytes(8, "big"))
        value.update(relative)
        value.update(len(content).to_bytes(8, "big"))
        value.update(hashlib.sha256(content).digest())
    return value.hexdigest()


def legacy_tree_digest(path):
    value = hashlib.sha256()
    for item in sorted(path.rglob("*")):
        if item.is_symlink():
            raise ValueError(f"Symlink inside managed directory requires review: {item}")
        if item.is_dir():
            continue
        if not item.is_file():
            raise ValueError(f"Special file inside managed directory requires review: {item}")
        content = item.read_bytes()
        if b"\0" in content:
            raise ValueError(
                f"Legacy automation digest cannot verify NUL-containing content: {item}"
            )
        value.update(str(item.relative_to(path)).encode())
        value.update(b"\0")
        value.update(content)
        value.update(b"\0")
    return value.hexdigest()


def validate_automation_tree(path, *, expected_files=AUTOMATION_FILES):
    if path.is_symlink() or not path.is_dir():
        raise ValueError(f"Built app automation is not a regular directory: {path}")
    found = set()
    for item in path.rglob("*"):
        if item.is_symlink():
            raise ValueError(f"Built app automation contains a symlink: {item}")
        if item.is_dir():
            continue
        if not item.is_file():
            raise ValueError(f"Built app automation contains a special file: {item}")
        found.add(item.relative_to(path).as_posix())
    if expected_files is not None:
        expected = set(expected_files)
        if found != expected:
            missing = sorted(expected - found)
            extra = sorted(found - expected)
            raise ValueError(
                f"Built app automation payload is incomplete or unexpected; "
                f"missing={missing}, extra={extra}."
            )


def automation_digest_matches(path, artifact):
    # An installed payload may be from an older release with a different exact
    # file manifest. Its recorded digest still proves ownership. The incoming
    # bundle is validated separately against the current exact manifest.
    validate_automation_tree(path, expected_files=None)
    recorded = artifact.get("sha256")
    algorithm = artifact.get("digestAlgorithm")
    if algorithm == TREE_DIGEST_ALGORITHM:
        return tree_digest(path) == recorded
    if algorithm is None:
        return recorded in {tree_digest(path), legacy_tree_digest(path)}
    return False


@contextmanager
def installation_lock(support, home):
    safe_destination(support, home)
    support.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_path = support / "install.lock"
    safe_destination(lock_path, home)
    with lock_path.open("a") as lock:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def safe_destination(path, home):
    if not path.is_relative_to(home) or path == home:
        raise ValueError(f"Destination is outside the selected home: {path}")
    current = path
    while current != home:
        if current.is_symlink():
            raise ValueError(f"Symlink destination requires review: {current}")
        if current != path and current.exists() and not current.is_dir():
            raise ValueError(f"Destination parent is not a directory: {current}")
        current = current.parent


def app_identity(path):
    try:
        return plistlib.loads((path / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier")
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None


def verify_installed_app(path, description):
    if path.is_symlink() or app_identity(path) != IDENTIFIER:
        raise ValueError(f"The {description} has an unexpected identity and was preserved: {path}")
    try:
        subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)],
            check=True,
            capture_output=True,
        )
    except subprocess.SubprocessError as error:
        raise ValueError(
            f"The {description} has an invalid code signature and was preserved: {path}"
        ) from error


class Installer:
    def __init__(self, bundle, home, *, login=False, desktop=False, start=True):
        self.bundle = bundle.absolute()
        self.home = home.absolute()
        self.support = self.home / "Library/Application Support" / LEGACY_PRODUCT
        self.automation = self.support / "automation"
        self.app = self.home / "Applications" / f"{PRODUCT}.app"
        self.legacy_app = self.home / "Applications" / f"{LEGACY_PRODUCT}.app"
        self.helper = self.home / ".local/bin/focus-queue-session"
        self.agent = self.home / "Library/LaunchAgents" / f"{IDENTIFIER}.plist"
        self.desktop = self.home / "Desktop" / f"{PRODUCT}.app"
        self.legacy_desktop = self.home / "Desktop" / f"{LEGACY_PRODUCT}.app"
        self.manifest = self.support / "install-manifest.json"
        self.codex_prompt = self.home / "Documents/AGENTS.md"
        self.claude_prompt = self.home / "Documents/CLAUDE.md"
        self.codex_entry = self.support / "shell/focus_queue_codex_entry.py"
        self.codex_usage_wrapper = self.support / "shell/focus_queue_usage_wrapper.sh"
        self.codex_usage_renderer = self.support / "shell/focus_queue_codex_bar.js"
        self.codex_usage_license = self.support / "shell/AgentUsageBar-LICENSE.txt"
        self.fq_files = [self.support / "shell" / name for name in FQ_SHELL_FILES]
        self.login, self.shortcut, self.start = login, desktop, start
        self.service = f"gui/{os.getuid()}/{IDENTIFIER}"
        self.legacy_shortcut_owned = False
        self.source_provenance = None

    def preflight(self):
        if os.uname().sysname != "Darwin":
            raise ValueError("The app installer supports macOS only.")
        if self.bundle.is_symlink() or app_identity(self.bundle) != IDENTIFIER:
            raise ValueError("Built bundle has an unexpected identity or is a symlink.")
        bundle_info = plistlib.loads((self.bundle / "Contents/Info.plist").read_bytes())
        if (
            bundle_info.get("CFBundleDisplayName") != PRODUCT
            or bundle_info.get("CFBundleName") != PRODUCT
            or bundle_info.get("CFBundleExecutable") != "ECCFocusQueue"
        ):
            raise ValueError("Built bundle has an unexpected display identity.")
        for name in ("ECCFocusQueue", "focus-queue-session", "focus-queue-map"):
            executable = self.bundle / "Contents/MacOS" / name
            validate_bundle_member(self.bundle, executable)
            if not os.access(executable, os.X_OK):
                raise ValueError(f"Built app is incomplete: missing executable {name}.")
        bundled_automation = self.bundle / "Contents/Resources/automation"
        validate_bundle_member(self.bundle, bundled_automation)
        safe_destination(self.codex_prompt, self.home)
        safe_destination(self.claude_prompt, self.home)
        payload = self.bundle / "Contents/Resources/CODEX_GLOBAL_INSTRUCTIONS.md"
        validate_bundle_member(self.bundle, payload)
        if not payload.is_file() or payload.is_symlink():
            raise ValueError("The built app is missing its shareable Codex instructions.")
        merge_agent_prompt(self.codex_prompt.read_text() if self.codex_prompt.exists() else "", payload.read_text(), label="Codex")
        claude_payload = self.bundle / "Contents/Resources/CLAUDE_GLOBAL_INSTRUCTIONS.md"
        validate_bundle_member(self.bundle, claude_payload)
        if not claude_payload.is_file() or claude_payload.is_symlink():
            raise ValueError("The built app is missing its shareable Claude instructions.")
        merge_agent_prompt(self.claude_prompt.read_text() if self.claude_prompt.exists() else "", claude_payload.read_text(), label="Claude")
        safe_destination(self.codex_entry, self.home)
        safe_destination(self.codex_usage_wrapper, self.home)
        safe_destination(self.codex_usage_renderer, self.home)
        safe_destination(self.codex_usage_license, self.home)
        for path in self.fq_files:
            safe_destination(path, self.home)
        for relative in (
            "Contents/Resources/shell/focus_queue_codex_entry.py",
            "Contents/Resources/shell/focus_queue_claude_entry.py",
            "Contents/Resources/shell/focus_queue_usage_wrapper.sh",
            "Contents/Resources/shell/focus_queue_codex_bar.js",
            "Contents/Resources/shell/AgentUsageBar-LICENSE.txt",
            "Contents/Resources/shell/focus_queue_fq.py",
            "Contents/Resources/shell/focus_queue_placement.py",
            "Contents/Resources/shell/focus_queue_prompt_usage.py",
        ):
            validate_bundle_member(self.bundle, self.bundle / relative)
        if self.codex_entry.exists():
            candidates = [
                app / "Contents/Resources/shell/focus_queue_codex_entry.py"
                for app in (self.app, self.legacy_app, self.bundle)
            ]
            if not self.codex_entry.is_file() or not any(p.is_file() and digest(p) == digest(self.codex_entry) for p in candidates):
                raise ValueError("The installed Codex entry has local changes; retained for review.")
        if self.codex_usage_wrapper.exists():
            candidates = [app / "Contents/Resources/shell/focus_queue_usage_wrapper.sh" for app in (self.app, self.bundle)]
            if not self.codex_usage_wrapper.is_file() or not any(
                p.is_file() and digest(p) == digest(self.codex_usage_wrapper) for p in candidates
            ):
                raise ValueError("The installed Codex usage adapter has local changes; retained for review.")
        for installed, relative, label in (
            (self.codex_usage_renderer, "focus_queue_codex_bar.js", "usage renderer"),
            (self.codex_usage_license, "AgentUsageBar-LICENSE.txt", "usage renderer license"),
        ):
            if installed.exists():
                candidates = [app / "Contents/Resources/shell" / relative
                              for app in (self.app, self.bundle)]
                if not installed.is_file() or not any(
                    candidate.is_file() and digest(candidate) == digest(installed)
                    for candidate in candidates
                ):
                    raise ValueError(f"The installed Codex {label} has local changes; retained for review.")
        for installed in self.fq_files:
            if installed.exists():
                candidates = [app / "Contents/Resources/shell" / installed.name
                              for app in (self.app, self.legacy_app, self.bundle)]
                if not installed.is_file() or not any(
                    candidate.is_file() and digest(candidate) == digest(installed)
                    for candidate in candidates
                ):
                    raise ValueError(f"The installed fq file {installed.name} has local changes; retained for review.")
        validate_automation_tree(bundled_automation)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.bundle)], check=True, capture_output=True)
        self.source_provenance = read_source_provenance(
            self.bundle, require_integrated=True
        )
        for path in (
            self.app,
            self.legacy_app,
            self.helper,
            self.agent,
            self.support,
            self.automation,
            self.manifest,
        ):
            safe_destination(path, self.home)
        if self.app.exists():
            verify_installed_app(self.app, "installation target")
        if self.legacy_app.exists():
            verify_installed_app(self.legacy_app, "legacy app")
        if self.helper.exists():
            candidates = [
                app / "Contents/MacOS/focus-queue-session"
                for app in (self.app, self.legacy_app, self.bundle)
            ]
            if not self.helper.is_file() or not any(p.is_file() and digest(self.helper) == digest(p) for p in candidates):
                raise ValueError(f"Existing session helper is unrecognized: {self.helper}")
        if self.agent.exists():
            value = plistlib.loads(self.agent.read_bytes())
            known_executables = {
                str(app / "Contents/MacOS/ECCFocusQueue")
                for app in (self.app, self.legacy_app)
            }
            arguments = value.get("ProgramArguments")
            if (
                value.get("Label") != IDENTIFIER
                or not isinstance(arguments, list)
                or len(arguments) != 1
                or arguments[0] not in known_executables
            ):
                raise ValueError(f"Existing login service is unrecognized: {self.agent}")
            self.login = True
        self.legacy_shortcut_owned = (
            self.legacy_desktop.is_symlink()
            and self.legacy_desktop.readlink() == self.legacy_app
        )
        if self.legacy_shortcut_owned:
            self.shortcut = True
            safe_destination(self.legacy_desktop.parent / "ownership-check", self.home)
        if self.desktop.is_symlink():
            if self.desktop.readlink() == self.app:
                self.shortcut = True
                safe_destination(self.desktop.parent / "ownership-check", self.home)
            elif self.shortcut:
                raise ValueError(f"Desktop shortcut belongs to another target: {self.desktop}")
        elif self.shortcut:
            safe_destination(self.desktop, self.home)
            if self.desktop.exists():
                raise ValueError(f"Desktop item already exists: {self.desktop}")
        if self.manifest.exists():
            value = json.loads(self.manifest.read_text())
            if value.get("product") != IDENTIFIER or value.get("version") not in (1, 2):
                raise ValueError("Existing installation manifest is unrecognized.")
            if value["version"] == 2:
                installed_provenance = validate_source_provenance(
                    value.get("sourceProvenance"), require_integrated=True
                )
                _validate_timestamp(value.get("installedAt"), "The installation time")
                if (
                    installed_provenance["repositoryIdentity"]
                    != self.source_provenance["repositoryIdentity"]
                ):
                    raise ValueError(
                        "The candidate build comes from a different repository."
                    )
                if (
                    installed_provenance["revision"]
                    not in self.source_provenance["reachableRevisions"]
                ):
                    raise ValueError(
                        "The candidate build does not contain the installed revision."
                    )
            automation_entry = next(
                (item for item in value.get("artifacts", [])
                 if item.get("path") == str(self.automation)),
                None,
            )
            if automation_entry is not None and self.automation.exists():
                if (self.automation.is_symlink() or not self.automation.is_dir()
                        or not automation_digest_matches(self.automation, automation_entry)):
                    raise ValueError(
                        f"Installed automation changed; retained for review: {self.automation}")
        return {"mode": "preflight", "application": str(self.app), "helper": str(self.helper),
                "launchAtLogin": self.login, "desktopShortcut": self.shortcut,
                "configuration": "preserve existing; first launch offers setup",
                "companions": "app-owned automation updated; companion launch agents unchanged",
                "codexInstructions": "merge app-owned block; preserve personal instructions",
                "claudeInstructions": "merge app-owned block; preserve personal instructions",
                "signature": "verified (does not imply notarization)"}

    def stop(self):
        subprocess.run(["/bin/launchctl", "bootout", self.service], capture_output=True)
        executables = {
            str(app / "Contents/MacOS/ECCFocusQueue")
            for app in (self.app, self.legacy_app)
        }

        def running_processes():
            result = subprocess.run(
                ["/bin/ps", "-axo", "pid=,comm="],
                capture_output=True,
                text=True,
                check=True,
            )
            processes = []
            for line in result.stdout.splitlines():
                values = line.strip().split(None, 1)
                if len(values) == 2 and values[1] in executables:
                    processes.append((int(values[0]), values[1]))
            return processes

        processes = running_processes()
        for process, _ in processes:
            try:
                os.kill(process, 15)
            except ProcessLookupError:
                pass
        for attempt in range(50):
            if not running_processes():
                return
            if attempt < 49:
                time.sleep(0.1)
        raise RuntimeError("The previous Focus Queue app is still running; installation stopped.")

    def start_app(self, *, login, application=None):
        if login:
            for attempt in range(5):
                result = subprocess.run(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(self.agent)], capture_output=True, text=True)
                if result.returncode == 0:
                    break
                time.sleep(0.5)
            if result.returncode:
                raise RuntimeError(f"Login service failed to start: {result.stderr.strip()}")
            subprocess.run(["/bin/launchctl", "kickstart", self.service], check=True, capture_output=True)
        else:
            subprocess.run(
                ["/usr/bin/open", "-g", str(application or self.app)],
                check=True,
                capture_output=True,
            )

    def install(self):
        self.preflight()
        with installation_lock(self.support, self.home):
            result = self._install_locked()
        return result

    def _install_locked(self):
        self.preflight()
        backup_root = self.support / "backups"
        safe_destination(backup_root, self.home)
        backup_root.mkdir(exist_ok=True, mode=0o700)
        backup = Path(tempfile.mkdtemp(prefix="install-", dir=backup_root))
        self.app.parent.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix=".focus-queue-stage-", dir=self.app.parent))
        changes = []
        old_application = (
            self.app if self.app.exists()
            else self.legacy_app if self.legacy_app.exists()
            else None
        )
        old_login, stopped = self.agent.exists(), False
        legacy_application_migrated = self.legacy_app.exists()
        try:
            staged_app = stage / self.app.name
            subprocess.run(["/usr/bin/ditto", str(self.bundle), str(staged_app)], check=True, capture_output=True)
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(staged_app)], check=True, capture_output=True)
            if read_source_provenance(staged_app, require_integrated=True) != self.source_provenance:
                raise ValueError("The candidate bundle changed while installation was being prepared.")
            for relative in (
                "Contents/MacOS/ECCFocusQueue",
                "Contents/MacOS/focus-queue-session",
                "Contents/MacOS/focus-queue-map",
                "Contents/Resources/CODEX_GLOBAL_INSTRUCTIONS.md",
                "Contents/Resources/CLAUDE_GLOBAL_INSTRUCTIONS.md",
                "Contents/Resources/shell/focus_queue_codex_entry.py",
                "Contents/Resources/shell/focus_queue_claude_entry.py",
                "Contents/Resources/shell/focus_queue_usage_wrapper.sh",
                "Contents/Resources/shell/focus_queue_codex_bar.js",
                "Contents/Resources/shell/AgentUsageBar-LICENSE.txt",
                "Contents/Resources/shell/focus_queue_fq.py",
                "Contents/Resources/shell/focus_queue_placement.py",
                "Contents/Resources/shell/focus_queue_prompt_usage.py",
                "Contents/Resources/automation",
            ):
                validate_bundle_member(staged_app, staged_app / relative)
            staged_helper = stage / self.helper.name
            shutil.copy2(staged_app / "Contents/MacOS/focus-queue-session", staged_helper)
            staged_automation = stage / "automation-payload"
            shutil.copytree(
                staged_app / "Contents/Resources/automation",
                staged_automation,
                symlinks=True,
            )
            validate_automation_tree(staged_automation)
            planned = [
                (staged_app, self.app),
                (staged_helper, self.helper),
                (staged_automation, self.automation),
            ]
            original_prompt = self.codex_prompt.read_bytes() if self.codex_prompt.exists() else b""
            staged_prompt = stage / "codex-instructions.md"
            staged_prompt.write_text(merge_agent_prompt(original_prompt.decode(),
                (staged_app / "Contents/Resources/CODEX_GLOBAL_INSTRUCTIONS.md").read_text(), label="Codex"))
            staged_prompt.chmod(self.codex_prompt.stat().st_mode & 0o777 if self.codex_prompt.exists() else 0o600)
            planned.append((staged_prompt, self.codex_prompt))
            original_claude_prompt = self.claude_prompt.read_bytes() if self.claude_prompt.exists() else b""
            staged_claude_prompt = stage / "claude-instructions.md"
            staged_claude_prompt.write_text(merge_agent_prompt(original_claude_prompt.decode(),
                (staged_app / "Contents/Resources/CLAUDE_GLOBAL_INSTRUCTIONS.md").read_text(), label="Claude"))
            staged_claude_prompt.chmod(self.claude_prompt.stat().st_mode & 0o777 if self.claude_prompt.exists() else 0o600)
            planned.append((staged_claude_prompt, self.claude_prompt))
            # Refresh an already configured entry without changing aliases, flags or hook trust.
            original_entry = self.codex_entry.read_bytes() if self.codex_entry.exists() else None
            original_usage_wrapper = (self.codex_usage_wrapper.read_bytes()
                                      if self.codex_usage_wrapper.exists() else None)
            original_usage_renderer = (self.codex_usage_renderer.read_bytes()
                                       if self.codex_usage_renderer.exists() else None)
            original_usage_license = (self.codex_usage_license.read_bytes()
                                      if self.codex_usage_license.exists() else None)
            if original_entry is not None:
                staged_entry = stage / "codex-entry.py"
                shutil.copy2(staged_app / "Contents/Resources/shell/focus_queue_codex_entry.py", staged_entry)
                staged_entry.chmod(self.codex_entry.stat().st_mode & 0o777)
                planned.append((staged_entry, self.codex_entry))
                staged_usage_wrapper = stage / "codex-usage-wrapper.sh"
                shutil.copy2(staged_app / "Contents/Resources/shell/focus_queue_usage_wrapper.sh", staged_usage_wrapper)
                staged_usage_wrapper.chmod(
                    self.codex_usage_wrapper.stat().st_mode & 0o777
                    if self.codex_usage_wrapper.exists() else 0o600)
                planned.append((staged_usage_wrapper, self.codex_usage_wrapper))
                staged_usage_renderer = stage / "codex-usage-renderer.js"
                shutil.copy2(
                    staged_app / "Contents/Resources/shell/focus_queue_codex_bar.js",
                    staged_usage_renderer)
                staged_usage_renderer.chmod(
                    self.codex_usage_renderer.stat().st_mode & 0o777
                    if self.codex_usage_renderer.exists() else 0o600)
                planned.append((staged_usage_renderer, self.codex_usage_renderer))
                staged_usage_license = stage / "codex-usage-license.txt"
                shutil.copy2(
                    staged_app / "Contents/Resources/shell/AgentUsageBar-LICENSE.txt",
                    staged_usage_license)
                staged_usage_license.chmod(
                    self.codex_usage_license.stat().st_mode & 0o777
                    if self.codex_usage_license.exists() else 0o600)
                planned.append((staged_usage_license, self.codex_usage_license))
            original_fq = {path: path.read_bytes() if path.exists() else None for path in self.fq_files}
            if original_fq[self.fq_files[0]] is not None:
                for path in self.fq_files:
                    staged_fq = stage / f"fq-{path.name}"
                    shutil.copy2(staged_app / "Contents/Resources/shell" / path.name, staged_fq)
                    staged_fq.chmod(path.stat().st_mode & 0o777 if path.exists() else 0o600)
                    planned.append((staged_fq, path))
            if self.login:
                staged_agent = stage / self.agent.name
                staged_agent.write_bytes(plistlib.dumps({"Label": IDENTIFIER,
                    "ProgramArguments": [str(self.app / "Contents/MacOS/ECCFocusQueue")],
                    "RunAtLoad": True, "KeepAlive": {"SuccessfulExit": False}, "ThrottleInterval": 5,
                    "ProcessType": "Interactive", "StandardOutPath": str(self.support / "launch.stdout.log"),
                    "StandardErrorPath": str(self.support / "launch.stderr.log")}))
                planned.append((staged_agent, self.agent))
            if self.shortcut:
                staged_link = stage / "desktop-link"
                staged_link.symlink_to(self.app)
                planned.append((staged_link, self.desktop))
            manifest = {"version": MANIFEST_VERSION, "product": IDENTIFIER,
                "installedAt": utc_timestamp(),
                "sourceProvenance": self.source_provenance,
                "backupDirectory": str(backup),
                "artifacts": [{"path": str(target),
                               "kind": "symlink" if source.is_symlink() else "directory" if source.is_dir() else "file",
                               "sha256": digest(source) if source.is_file() and not source.is_symlink()
                               else tree_digest(source) if target == self.automation else None,
                               **({"digestAlgorithm": TREE_DIGEST_ALGORITHM}
                                  if target == self.automation else {})}
                              for source, target in planned if target not in {
                                  self.codex_prompt, self.claude_prompt, self.codex_entry,
                                  self.codex_usage_wrapper,
                                  self.codex_usage_renderer, self.codex_usage_license, *self.fq_files}],
                "managedSettings": [{"path": str(self.codex_prompt), "ownership": "delimited-block-only"},
                    {"path": str(self.claude_prompt), "ownership": "delimited-block-only"},
                    {"path": str(self.codex_entry), "ownership": "configured-entry-only"},
                    {"path": str(self.codex_usage_wrapper), "ownership": "configured-entry-support"},
                    {"path": str(self.codex_usage_renderer), "ownership": "configured-entry-support"},
                    {"path": str(self.codex_usage_license), "ownership": "configured-entry-support"},
                    *({"path": str(path), "ownership": "configured-entry-support"}
                      for path in self.fq_files if original_fq[self.fq_files[0]] is not None)],
                "launchAtLogin": self.login, "desktopShortcut": self.shortcut}
            staged_manifest = stage / "manifest.json"
            staged_manifest.write_text(json.dumps(manifest, indent=2) + "\n")
            staged_manifest.chmod(0o600)
            planned.append((staged_manifest, self.manifest))
            obsolete = []
            if self.legacy_app.exists():
                obsolete.append(self.legacy_app)
            if self.legacy_shortcut_owned:
                obsolete.append(self.legacy_desktop)
            operations = [
                (None, target) for target in obsolete
            ] + planned
            recovery = {"version": 1, "status": "prepared", "paths": [
                {"destination": str(target), "backup": str(backup / str(index))}
                for index, (_, target) in enumerate(operations)]}
            (backup / "recovery.json").write_text(json.dumps(recovery, indent=2) + "\n")
            if self.start:
                self.stop()
                stopped = True
            for index, (source, target) in enumerate(operations):
                if target == self.codex_prompt and (target.read_bytes() if target.exists() else b"") != original_prompt:
                    raise ValueError("Codex instructions changed during installation; retry to preserve the newer edit.")
                if target == self.claude_prompt and (target.read_bytes() if target.exists() else b"") != original_claude_prompt:
                    raise ValueError("Claude instructions changed during installation; retry to preserve the newer edit.")
                if target == self.codex_entry and (target.read_bytes() if target.exists() else None) != original_entry:
                    raise ValueError("Codex entry changed during installation; retry to preserve the newer edit.")
                if target == self.codex_usage_wrapper and (
                    target.read_bytes() if target.exists() else None
                ) != original_usage_wrapper:
                    raise ValueError("Codex usage adapter changed during installation; retry to preserve the newer edit.")
                if target == self.codex_usage_renderer and (
                    target.read_bytes() if target.exists() else None
                ) != original_usage_renderer:
                    raise ValueError("Codex usage renderer changed during installation; retry to preserve the newer edit.")
                if target == self.codex_usage_license and (
                    target.read_bytes() if target.exists() else None
                ) != original_usage_license:
                    raise ValueError("Codex usage license changed during installation; retry to preserve the newer edit.")
                if target in original_fq and (
                    target.read_bytes() if target.exists() else None
                ) != original_fq[target]:
                    raise ValueError(f"{target.name} changed during installation; retry to preserve the newer edit.")
                if source is not None:
                    target.parent.mkdir(parents=True, exist_ok=True)
                previous = backup / str(index)
                existed = target.exists() or target.is_symlink()
                if existed:
                    target.rename(previous)
                changes.append((target, previous if existed else None))
                if source is not None:
                    source.rename(target)
            if self.start:
                self.start_app(login=self.login)
            recovery["status"] = "installed"
            (backup / "recovery.json").write_text(json.dumps(recovery, indent=2) + "\n")
            return {"status": "installed", "application": str(self.app), "backupDirectory": str(backup),
                    "manifest": str(self.manifest), "started": self.start,
                    "legacyApplicationMigrated": legacy_application_migrated}
        except BaseException:
            shutdown_error = None
            if stopped:
                try:
                    self.stop()
                except Exception as error:
                    # File restoration must still run if service shutdown fails.
                    shutdown_error = error
            for index, (target, previous) in enumerate(reversed(changes)):
                if target.exists() or target.is_symlink():
                    target.rename(backup / f"failed-new-{index}")
                if previous is not None:
                    previous.rename(target)
            recovery_file = backup / "recovery.json"
            if recovery_file.exists():
                recovery["status"] = "rolled_back"
                recovery_file.write_text(json.dumps(recovery, indent=2) + "\n")
            if stopped and old_application is not None:
                if shutdown_error is not None:
                    raise RuntimeError(
                        f"Files restored, but the replacement app did not stop; the previous "
                        f"app was not restarted to avoid a duplicate. Recovery: {backup}. "
                        f"{shutdown_error}"
                    ) from shutdown_error
                try:
                    self.start_app(login=old_login, application=old_application)
                except Exception as error:
                    raise RuntimeError(f"Files restored, but restarting the previous app failed. Recovery: {backup}. {error}") from error
            raise
        finally:
            shutil.rmtree(stage)


def _uninstall_locked(installer, home, *, check, stop):
    safe_destination(installer.manifest, home)
    if not installer.manifest.is_file():
        raise ValueError("No installation ownership manifest exists. Install the current version before using managed uninstall.")
    manifest = json.loads(installer.manifest.read_text())
    if manifest.get("product") != IDENTIFIER or manifest.get("version") not in (1, 2):
        raise ValueError("Unrecognized installation manifest.")
    if manifest["version"] == 2:
        validate_source_provenance(
            manifest.get("sourceProvenance"), require_integrated=True
        )
        _validate_timestamp(manifest.get("installedAt"), "The installation time")
    allowed = {
        installer.app, installer.legacy_app, installer.helper, installer.agent,
        installer.desktop, installer.legacy_desktop, installer.automation,
    }
    targets = []
    for item in manifest["artifacts"]:
        path = Path(item["path"])
        if path not in allowed:
            raise ValueError(f"Manifest path is outside the app installation: {path}")
        if not path.exists() and not path.is_symlink():
            continue
        if path in {installer.desktop, installer.legacy_desktop}:
            safe_destination(path.parent / "ownership-check", home)
            expected_app = (
                installer.app if path == installer.desktop else installer.legacy_app
            )
            if not path.is_symlink() or path.readlink() != expected_app:
                raise ValueError(f"Desktop shortcut changed; retained: {path}")
        else:
            safe_destination(path, home)
            if path in {installer.app, installer.legacy_app}:
                verify_installed_app(path, "installed app")
            elif path == installer.automation:
                if (path.is_symlink() or not path.is_dir()
                        or not automation_digest_matches(path, item)):
                    raise ValueError(f"Installed automation changed; retained: {path}")
            elif not path.is_file() or digest(path) != item["sha256"]:
                raise ValueError(f"Installed file changed; retained: {path}")
        targets.append(path)
    result = {"mode": "uninstall-preview", "paths": [str(path) for path in targets],
              "preserved": "configuration, task files, history, backups, tmux sessions and companion services"}
    if check:
        return result
    backup_root = installer.support / "backups"
    safe_destination(backup_root, home)
    backup_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = Path(tempfile.mkdtemp(prefix="uninstall-", dir=backup_root))
    if stop:
        installer.stop()
    moved = []
    try:
        for index, path in enumerate(targets + [installer.manifest]):
            destination = backup / str(index)
            path.rename(destination)
            moved.append((path, destination))
        (backup / "recovery.json").write_text(json.dumps({"paths": [
            {"destination": str(path), "backup": str(saved)} for path, saved in moved]}, indent=2) + "\n")
    except BaseException:
        for path, saved in reversed(moved):
            saved.rename(path)
        raise
    return {**result, "mode": "uninstalled", "backupDirectory": str(backup)}


def uninstall(home, *, check=False, stop=True):
    installer = Installer(home / "Applications" / f"{PRODUCT}.app", home, start=False)
    if check:
        return _uninstall_locked(installer, home, check=True, stop=stop)
    with installation_lock(installer.support, home):
        return _uninstall_locked(installer, home, check=False, stop=stop)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument(
        "--write-provenance",
        type=Path,
        help="Write source provenance JSON for inclusion in a bundle before signing.",
    )
    parser.add_argument("--repository", type=Path, help="Source Git repository.")
    parser.add_argument(
        "--integration-ref",
        default=DEFAULT_INTEGRATION_REF,
        help="Canonical Git ref that is allowed to ship.",
    )
    parser.add_argument("--uninstall", action="store_true", help="Move only manifest-owned installation files to a retained backup.")
    parser.add_argument("--check", action="store_true", help="Read-only preflight.")
    parser.add_argument("--login", action="store_true", help="Enable login launch; existing choice is retained.")
    parser.add_argument("--desktop", action="store_true", help="Add a Desktop shortcut.")
    parser.add_argument("--no-start", action="store_true", help="Install files without stopping or starting services.")
    args = parser.parse_args()
    try:
        if args.write_provenance is not None:
            if args.uninstall or args.bundle is not None or args.check:
                parser.error("--write-provenance cannot be combined with install modes")
            if args.repository is None:
                parser.error("--repository is required with --write-provenance")
            provenance = capture_source_provenance(
                args.repository, integration_ref=args.integration_ref
            )
            args.write_provenance.parent.mkdir(parents=True, exist_ok=True)
            args.write_provenance.write_text(json.dumps(provenance, indent=2) + "\n")
            print(json.dumps(provenance, indent=2))
            return 0
        if args.uninstall:
            print(json.dumps(uninstall(Path.home(), check=args.check, stop=not args.no_start), indent=2))
            return 0
        if args.bundle is None:
            parser.error("--bundle is required for installation")
        installer = Installer(args.bundle, Path.home(), login=args.login, desktop=args.desktop, start=not args.no_start)
        print(json.dumps(installer.preflight() if args.check else installer.install(), indent=2))
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Installation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
