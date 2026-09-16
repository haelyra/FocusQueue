#!/usr/bin/env python3
"""Portable staged installation with retained backups and rollback on failure."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import sys

PRODUCT = "ECC Focus Queue"
IDENTIFIER = "com.haelyra.ecc-focus-queue"
TREE_DIGEST_ALGORITHM = "sha256-tree-v1"
AUTOMATION_FILES = (
    "Scripts/focus_queue_morning.py",
    "Scripts/focus_queue_codex.py",
    "Scripts/focus_queue_lock.py",
    "Scripts/focus_queue_mail.py",
    "Scripts/focus_queue_discord.py",
    "Scripts/focus_queue_connectors.py",
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
        value.update(str(item.relative_to(path)).encode())
        value.update(b"\0")
        value.update(item.read_bytes())
        value.update(b"\0")
    return value.hexdigest()


def validate_automation_tree(path):
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
    expected = set(AUTOMATION_FILES)
    if found != expected:
        missing = sorted(expected - found)
        extra = sorted(found - expected)
        raise ValueError(
            f"Built app automation payload is incomplete or unexpected; "
            f"missing={missing}, extra={extra}."
        )


def automation_digest_matches(path, artifact):
    validate_automation_tree(path)
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


class Installer:
    def __init__(self, bundle, home, *, login=False, desktop=False, start=True):
        self.bundle = bundle.absolute()
        self.home = home.absolute()
        self.support = self.home / "Library/Application Support" / PRODUCT
        self.automation = self.support / "automation"
        self.app = self.home / "Applications" / f"{PRODUCT}.app"
        self.helper = self.home / ".local/bin/focus-queue-session"
        self.agent = self.home / "Library/LaunchAgents" / f"{IDENTIFIER}.plist"
        self.desktop = self.home / "Desktop" / f"{PRODUCT}.app"
        self.manifest = self.support / "install-manifest.json"
        self.login, self.shortcut, self.start = login, desktop, start
        self.service = f"gui/{os.getuid()}/{IDENTIFIER}"

    def preflight(self):
        if os.uname().sysname != "Darwin":
            raise ValueError("The app installer supports macOS only.")
        if self.bundle.is_symlink() or app_identity(self.bundle) != IDENTIFIER:
            raise ValueError("Built bundle has an unexpected identity or is a symlink.")
        for name in ("ECCFocusQueue", "focus-queue-session"):
            if not os.access(self.bundle / "Contents/MacOS" / name, os.X_OK):
                raise ValueError(f"Built app is incomplete: missing executable {name}.")
        bundled_automation = self.bundle / "Contents/Resources/automation"
        validate_automation_tree(bundled_automation)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.bundle)], check=True, capture_output=True)
        for path in (self.app, self.helper, self.agent, self.support, self.automation, self.manifest):
            safe_destination(path, self.home)
        if self.app.exists() and app_identity(self.app) != IDENTIFIER:
            raise ValueError(f"Installation target belongs to another app: {self.app}")
        if self.helper.exists():
            candidates = [app / "Contents/MacOS/focus-queue-session" for app in (self.app, self.bundle)]
            if not self.helper.is_file() or not any(p.is_file() and digest(self.helper) == digest(p) for p in candidates):
                raise ValueError(f"Existing session helper is unrecognized: {self.helper}")
        if self.agent.exists():
            value = plistlib.loads(self.agent.read_bytes())
            if value.get("Label") != IDENTIFIER or value.get("ProgramArguments") != [str(self.app / "Contents/MacOS/ECCFocusQueue")]:
                raise ValueError(f"Existing login service is unrecognized: {self.agent}")
            self.login = True
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
            if value.get("product") != IDENTIFIER or value.get("version") != 1:
                raise ValueError("Existing installation manifest is unrecognized.")
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
                "signature": "verified (does not imply notarization)"}

    def stop(self):
        subprocess.run(["/bin/launchctl", "bootout", self.service], capture_output=True)
        result = subprocess.run(["/bin/ps", "-axo", "pid=,comm="], capture_output=True, text=True, check=True)
        for line in result.stdout.splitlines():
            values = line.strip().split(None, 1)
            if len(values) == 2 and values[1] == str(self.app / "Contents/MacOS/ECCFocusQueue"):
                try:
                    os.kill(int(values[0]), 15)
                except ProcessLookupError:
                    pass

    def start_app(self, *, login):
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
            subprocess.run(["/usr/bin/open", "-g", str(self.app)], check=True, capture_output=True)

    def install(self):
        self.preflight()
        with installation_lock(self.support, self.home):
            return self._install_locked()

    def _install_locked(self):
        self.preflight()
        backup_root = self.support / "backups"
        safe_destination(backup_root, self.home)
        backup_root.mkdir(exist_ok=True, mode=0o700)
        backup = Path(tempfile.mkdtemp(prefix="install-", dir=backup_root))
        self.app.parent.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix=".focus-queue-stage-", dir=self.app.parent))
        changes = []
        old_app, old_login, stopped = self.app.exists(), self.agent.exists(), False
        try:
            staged_app = stage / self.app.name
            subprocess.run(["/usr/bin/ditto", str(self.bundle), str(staged_app)], check=True, capture_output=True)
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(staged_app)], check=True, capture_output=True)
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
            manifest = {"version": 1, "product": IDENTIFIER, "backupDirectory": str(backup),
                "artifacts": [{"path": str(target),
                               "kind": "symlink" if source.is_symlink() else "directory" if source.is_dir() else "file",
                               "sha256": digest(source) if source.is_file() and not source.is_symlink()
                               else tree_digest(source) if target == self.automation else None,
                               **({"digestAlgorithm": TREE_DIGEST_ALGORITHM}
                                  if target == self.automation else {})}
                              for source, target in planned],
                "launchAtLogin": self.login, "desktopShortcut": self.shortcut}
            staged_manifest = stage / "manifest.json"
            staged_manifest.write_text(json.dumps(manifest, indent=2) + "\n")
            staged_manifest.chmod(0o600)
            planned.append((staged_manifest, self.manifest))
            recovery = {"version": 1, "status": "prepared", "paths": [
                {"destination": str(target), "backup": str(backup / str(index))}
                for index, (_, target) in enumerate(planned)]}
            (backup / "recovery.json").write_text(json.dumps(recovery, indent=2) + "\n")
            if self.start:
                self.stop()
                stopped = True
            for index, (source, target) in enumerate(planned):
                target.parent.mkdir(parents=True, exist_ok=True)
                previous = backup / str(index)
                existed = target.exists() or target.is_symlink()
                if existed:
                    target.rename(previous)
                changes.append((target, previous if existed else None))
                source.rename(target)
            if self.start:
                self.start_app(login=self.login)
            recovery["status"] = "installed"
            (backup / "recovery.json").write_text(json.dumps(recovery, indent=2) + "\n")
            return {"status": "installed", "application": str(self.app), "backupDirectory": str(backup),
                    "manifest": str(self.manifest), "started": self.start}
        except BaseException:
            if stopped:
                try:
                    self.stop()
                except Exception:
                    pass  # File restoration must still run if service shutdown fails.
            for index, (target, previous) in enumerate(reversed(changes)):
                if target.exists() or target.is_symlink():
                    target.rename(backup / f"failed-new-{index}")
                if previous is not None:
                    previous.rename(target)
            recovery_file = backup / "recovery.json"
            if recovery_file.exists():
                recovery["status"] = "rolled_back"
                recovery_file.write_text(json.dumps(recovery, indent=2) + "\n")
            if stopped and old_app:
                try:
                    self.start_app(login=old_login)
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
    if manifest.get("product") != IDENTIFIER or manifest.get("version") != 1:
        raise ValueError("Unrecognized installation manifest.")
    allowed = {
        installer.app, installer.helper, installer.agent,
        installer.desktop, installer.automation,
    }
    targets = []
    for item in manifest["artifacts"]:
        path = Path(item["path"])
        if path not in allowed:
            raise ValueError(f"Manifest path is outside the app installation: {path}")
        if not path.exists() and not path.is_symlink():
            continue
        if path == installer.desktop:
            safe_destination(path.parent / "ownership-check", home)
            if not path.is_symlink() or path.readlink() != installer.app:
                raise ValueError(f"Desktop shortcut changed; retained: {path}")
        else:
            safe_destination(path, home)
            if path == installer.app:
                if app_identity(path) != IDENTIFIER:
                    raise ValueError(f"App identity changed; retained: {path}")
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
    parser.add_argument("--uninstall", action="store_true", help="Move only manifest-owned installation files to a retained backup.")
    parser.add_argument("--check", action="store_true", help="Read-only preflight.")
    parser.add_argument("--login", action="store_true", help="Enable login launch; existing choice is retained.")
    parser.add_argument("--desktop", action="store_true", help="Add a Desktop shortcut.")
    parser.add_argument("--no-start", action="store_true", help="Install files without stopping or starting services.")
    args = parser.parse_args()
    try:
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
