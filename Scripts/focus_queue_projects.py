#!/usr/bin/env python3
"""Preview, apply and undo the approved ECC project assignment migration.

Only project fields change. A manifest pins the preview to its source files;
rollback removes those fields while preserving later edits to task content.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import tempfile

from focus_queue_lock import acquire_exclusive_file_lock


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        file.write((json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode())
        file.flush()
        os.fsync(file.fileno())
    try:
        temporary.chmod(mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


@contextlib.contextmanager
def locked(paths: list[Path]):
    with contextlib.ExitStack() as stack:
        for path in sorted(set(paths)):
            file = stack.enter_context(Path(str(path) + ".focus-queue.lock").open("a+"))
            acquire_exclusive_file_lock(file)
        yield


def preview(config_path: Path, focus_repo: Path, ecc_repo: Path) -> dict:
    config_bytes = config_path.read_bytes()
    config = json.loads(config_bytes)
    dashboard_path = Path(config["dashboardPath"])
    dashboard_bytes = dashboard_path.read_bytes()
    dashboard = json.loads(dashboard_bytes)
    tickets = dashboard["tickets"]
    ids = [task["id"] for task in tickets]
    if len(ids) != len(set(ids)) or "ECC-035" not in ids:
        raise ValueError("Migration requires unique task IDs and the existing ECC-035 task")
    projects = [
        {"id": "ecc-focus-queue", "name": "ECC Focus Queue", "repositoryPath": str(focus_repo.resolve()), "remoteAliases": []},
        {"id": "ecc", "name": "ECC", "repositoryPath": str(ecc_repo.resolve()),
         "remote": "https://github.com/affaan-m/ECC", "remoteAliases": ["https://github.com/haelyra/ECC"]},
    ]
    existing = {project["id"]: project for project in config.get("projects", [])}
    for project in projects:
        if project["id"] in existing and existing[project["id"]] != project:
            raise ValueError("Existing project configuration differs; preserve it and review the migration")
    assignments = []
    for task in tickets:
        owner = "ecc-focus-queue" if task["id"] == "ECC-035" else "ecc"
        if task.get("projectID") and task["projectID"] != owner:
            raise ValueError(f"{task['id']} already belongs to another project; review its assignment")
        assignments.append({"id": task["id"], "before": task.get("projectID"),
                            "hadField": "projectID" in task, "after": owner})
    routines = [{"id": r["id"], "before": r.get("projectID"), "hadField": "projectID" in r, "after": "ecc"}
                for r in config.get("dailyRoutines", []) if r["id"] in {"review-prs", "triage-issues"}]
    return {"version": 1, "status": "preview", "configPath": str(config_path.resolve()),
            "dashboardPath": str(dashboard_path.resolve()), "configSHA256": digest(config_bytes),
            "dashboardSHA256": digest(dashboard_bytes), "projects": projects,
            "addedProjectIDs": [p["id"] for p in projects if p["id"] not in existing],
            "assignments": assignments, "routines": routines,
            "counts": {"ecc-focus-queue": 1, "ecc": len(tickets) - 1},
            "workspaceExceptions": [{"id": "ECC-044", "projectID": "ecc", "worktree": t.get("worktree")}
                                    for t in tickets if t["id"] == "ECC-044"]}


def apply(manifest_path: Path) -> dict:
    manifest = json.loads(manifest_path.read_bytes())
    config_path, dashboard_path = Path(manifest["configPath"]), Path(manifest["dashboardPath"])
    with locked([config_path, dashboard_path, manifest_path]):
        manifest = json.loads(manifest_path.read_bytes())
        if manifest["status"] == "applied":
            return {"status": "already-applied", "counts": manifest["counts"]}
        if manifest["status"] != "preview":
            raise ValueError("Only a fresh preview can be applied")
        originals = {p: p.read_bytes() for p in (config_path, dashboard_path)}
        if digest(originals[config_path]) != manifest["configSHA256"] or digest(originals[dashboard_path]) != manifest["dashboardSHA256"]:
            raise ValueError("Source changed after preview; generate a fresh preview")
        backup = manifest_path.parent / (manifest_path.stem + "-backup")
        backup.mkdir(mode=0o700, exist_ok=False)
        for name, path in [("config.json", config_path), ("dashboard.json", dashboard_path), ("state.json", config_path.parent / "state.json")]:
            if path.exists():
                target = backup / name
                target.write_bytes(path.read_bytes())
                target.chmod(0o600)
        manifest["backupDirectory"] = str(backup.resolve())
        manifest["contextHashes"] = {str(p.relative_to(config_path.parent)): digest(p.read_bytes())
                                     for p in (config_path.parent / "tasks").glob("*/context.json")}
        config, dashboard = json.loads(originals[config_path]), json.loads(originals[dashboard_path])
        registry = config.setdefault("projects", [])
        registry.extend(p for p in manifest["projects"] if p["id"] in manifest["addedProjectIDs"])
        owners = {entry["id"]: entry["after"] for entry in manifest["assignments"]}
        for ticket in dashboard["tickets"]:
            ticket["projectID"] = owners[ticket["id"]]
        routine_owners = {entry["id"]: entry["after"] for entry in manifest["routines"]}
        for routine in config.get("dailyRoutines", []):
            if routine["id"] in routine_owners:
                routine["projectID"] = routine_owners[routine["id"]]
        manifest["status"] = "prepared"
        write_json(manifest_path, manifest)
        # Config precedes assignments so a crash still leaves every task visible in All projects.
        write_json(config_path, config)
        write_json(dashboard_path, dashboard)
        manifest["status"] = "applied"
        manifest["appliedConfigSHA256"] = digest(config_path.read_bytes())
        manifest["appliedDashboardSHA256"] = digest(dashboard_path.read_bytes())
        write_json(manifest_path, manifest)
        return {"status": "applied", "counts": manifest["counts"], "backupDirectory": str(backup)}


def rollback(manifest_path: Path) -> dict:
    manifest = json.loads(manifest_path.read_bytes())
    config_path, dashboard_path = Path(manifest["configPath"]), Path(manifest["dashboardPath"])
    with locked([config_path, dashboard_path, manifest_path]):
        manifest = json.loads(manifest_path.read_bytes())
        if manifest["status"] == "rolled-back":
            return {"status": "already-rolled-back"}
        if manifest["status"] not in {"applied", "prepared"}:
            raise ValueError("Only an applied or interrupted migration can be rolled back")
        config, dashboard = json.loads(config_path.read_bytes()), json.loads(dashboard_path.read_bytes())
        assignments = {item["id"]: item for item in manifest["assignments"]}
        conflicts = []
        for ticket in dashboard["tickets"]:
            change = assignments.get(ticket["id"])
            if not change:
                continue
            if ticket.get("projectID") != change["after"]:
                if ticket.get("projectID") != change["before"]:
                    conflicts.append(ticket["id"])
                continue
            if change["hadField"]:
                ticket["projectID"] = change["before"]
            else:
                ticket.pop("projectID", None)
        for routine in config.get("dailyRoutines", []):
            change = next((r for r in manifest["routines"] if r["id"] == routine["id"]), None)
            if change and routine.get("projectID") == change["after"]:
                if change["hadField"]:
                    routine["projectID"] = change["before"]
                else:
                    routine.pop("projectID", None)
        referenced = {t.get("projectID") for t in dashboard["tickets"]}
        referenced.update(r.get("projectID") for r in config.get("dailyRoutines", []))
        added = {p["id"]: p for p in manifest["projects"] if p["id"] in manifest["addedProjectIDs"]}
        config["projects"] = [p for p in config.get("projects", []) if p["id"] in referenced or added.get(p["id"]) != p]
        write_json(dashboard_path, dashboard)
        write_json(config_path, config)
        manifest["status"] = "rolled-back"
        manifest["rollbackConflicts"] = conflicts
        write_json(manifest_path, manifest)
        return {"status": "rolled-back", "preservedAssignments": conflicts}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["preview", "apply", "rollback"])
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--focus-queue-repository", type=Path)
    parser.add_argument("--ecc-repository", type=Path)
    args = parser.parse_args()
    if args.operation == "preview":
        if not all([args.config, args.focus_queue_repository, args.ecc_repository]):
            parser.error("preview requires config and both repository paths")
        if args.manifest.exists():
            parser.error("Use a new manifest path to preserve prior migration evidence")
        result = preview(args.config, args.focus_queue_repository, args.ecc_repository)
        write_json(args.manifest, result)
    else:
        result = apply(args.manifest) if args.operation == "apply" else rollback(args.manifest)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
