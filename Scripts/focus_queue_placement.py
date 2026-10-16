#!/usr/bin/env python3
"""Heuristic placement classifier for Focus Queue agent launches (phase 1).

Resolves a launch prompt and working directory to a task, a project inbox, or
the global inbox using only local signals — no model calls. Every `classify`
call appends one row to the placement ledger (SQLite) in the support directory;
ledger failures never block classification.

Resolution order: explicit --task, ticket ID in the prompt that exists in app
state, cwd inside a configured project repository, cwd in any other git repo,
then no signal.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time


BACKEND = "heuristic"
SUPPORT_DIRECTORY_NAME = "ECC Focus Queue"
GENERIC_TICKET = re.compile(r"(?<![A-Za-z0-9_])([A-Za-z][A-Za-z0-9_]*-[0-9]+)(?![A-Za-z0-9_])")
TICKET_SHAPE = re.compile(r"[A-Za-z][A-Za-z0-9_]*-[0-9]+")
LEDGER_SCHEMA = """
CREATE TABLE IF NOT EXISTS placements(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT NOT NULL,
  backend TEXT NOT NULL,
  status TEXT NOT NULL,
  task_id TEXT,
  project_id TEXT,
  confidence REAL NOT NULL,
  rationale TEXT NOT NULL,
  prompt_excerpt TEXT,
  cwd TEXT,
  latency_ms REAL NOT NULL
);
"""


class PlacementError(RuntimeError):
    pass


def support_directory(environment):
    return Path(environment.get("FOCUS_QUEUE_SUPPORT_DIR") or
                str(Path.home() / "Library/Application Support" / SUPPORT_DIRECTORY_NAME)).absolute()


def load_configuration(environment, support):
    """Read the app configuration, tolerating both project-list shapes."""
    override = environment.get("FOCUS_QUEUE_PLACEMENT_CONFIG")
    candidates = ([Path(override)] if override else
                  [support / "config.json",
                   Path(__file__).resolve().parents[1] / "Config" / "ecc.config.json"])
    for path in candidates:
        try:
            metadata = path.lstat()
            if path.is_symlink() or not path.is_file() or metadata.st_size > 1_048_576:
                continue
            value = json.loads(path.read_text())
            if isinstance(value, dict):
                return value
        except (OSError, ValueError):
            continue
    return {}


def projects_of(configuration):
    projects = configuration.get("focusQueueProjects")
    if not isinstance(projects, list):
        projects = configuration.get("projects")
    if not isinstance(projects, list):
        return []
    return [project for project in projects if isinstance(project, dict)]


def project_for_prefix(projects, ticket_id):
    prefix = ticket_id.rsplit("-", 1)[0].upper()
    for project in projects:
        configured = project.get("taskPrefix")
        if isinstance(configured, str) and configured.strip().upper() == prefix:
            return project.get("id")
    return None


def known_tickets(projects, support):
    """Map uppercase ticket IDs to (canonical ID, project ID) from app state."""
    tickets = {}

    def record(ticket_id, project_id):
        if isinstance(ticket_id, str) and TICKET_SHAPE.fullmatch(ticket_id):
            tickets.setdefault(ticket_id.upper(), (ticket_id, project_id))

    for project in projects:
        dashboard = project.get("dashboardPath")
        if not isinstance(dashboard, str) or not dashboard:
            continue
        try:
            path = Path(dashboard)
            if path.is_symlink() or not path.is_file() or path.stat().st_size > 67_108_864:
                continue
            rows = json.loads(path.read_text()).get("tickets")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(rows, list):
            for row in rows:
                if isinstance(row, dict):
                    record(row.get("id"), project.get("id"))
    tasks = support / "tasks"
    try:
        children = list(tasks.iterdir())
    except OSError:
        children = []
    for child in children:
        try:
            if child.is_dir() and not child.is_symlink():
                record(child.name, project_for_prefix(projects, child.name))
        except OSError:
            continue
    return tickets


def prompt_ticket(prompt, projects, tickets):
    prefixes = sorted({project["taskPrefix"].strip().upper() for project in projects
                       if isinstance(project.get("taskPrefix"), str) and project["taskPrefix"].strip()})
    if prefixes:
        pattern = re.compile(r"(?<![A-Za-z0-9_])(?:" + "|".join(re.escape(prefix) for prefix in prefixes)
                             + r")-[0-9]+(?![A-Za-z0-9_])", re.IGNORECASE)
        ordered = [match.group(0) for match in pattern.finditer(prompt)]
    else:
        ordered = [match.group(0) for match in GENERIC_TICKET.finditer(prompt)]
    for candidate in ordered:
        known = tickets.get(candidate.upper())
        if known:
            return known
    return None


def path_within(path, root):
    candidate = str(Path(path).resolve()).casefold()
    boundary = str(Path(root).resolve()).casefold()
    return candidate == boundary or candidate.startswith(boundary + os.sep)


def git_top_level(cwd):
    try:
        result = subprocess.run(["/usr/bin/git", "rev-parse", "--show-toplevel"],
                                cwd=cwd, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode:
        return None
    return result.stdout.strip() or None


def match_project(cwd, projects):
    try:
        resolved = Path(cwd).resolve()
    except OSError:
        return None, None
    for project in projects:
        repository = project.get("repositoryPath")
        if isinstance(repository, str) and repository and path_within(resolved, repository):
            return project, None
    top_level = git_top_level(cwd)
    if top_level:
        for project in projects:
            repository = project.get("repositoryPath")
            if (isinstance(repository, str) and repository
                    and str(Path(repository).resolve()).casefold()
                    == str(Path(top_level).resolve()).casefold()):
                return project, top_level
    return None, top_level


def ledger_path(environment, support):
    override = environment.get("FOCUS_QUEUE_PLACEMENT_LEDGER")
    if override:
        return Path(override).absolute()
    return support / "placement-ledger.sqlite"


def append_ledger(path, result, prompt, cwd):
    """Best effort: a ledger failure warns on stderr but never blocks placement."""
    try:
        if path.is_symlink():
            raise OSError("ledger path is a symlink")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        connection = sqlite3.connect(str(path), timeout=5)
        try:
            connection.execute(LEDGER_SCHEMA)
            connection.execute(
                "INSERT INTO placements(timestamp, backend, status, task_id, project_id,"
                " confidence, rationale, prompt_excerpt, cwd, latency_ms)"
                " VALUES(?,?,?,?,?,?,?,?,?,?)",
                (datetime.now(timezone.utc).isoformat(), result["backend"], result["status"],
                 result.get("taskID"), result.get("projectID"), result["confidence"],
                 result["rationale"], (prompt or "")[:200] or None, str(cwd), result["latencyMs"]))
            connection.commit()
        finally:
            connection.close()
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
    except (OSError, sqlite3.Error) as error:
        print(f"placement: ledger write failed ({error}); classification is unaffected",
              file=sys.stderr)


def classify(prompt=None, cwd=None, task_id=None, *, environment=None):
    """Resolve a launch to task, project-inbox, or inbox. Pure heuristics, no model."""
    started = time.monotonic()
    environment = os.environ if environment is None else environment
    support = support_directory(environment)
    projects = projects_of(load_configuration(environment, support))
    cwd = str(Path(cwd or os.getcwd()).resolve())

    result = None
    if task_id is not None:
        if not TICKET_SHAPE.fullmatch(task_id):
            raise PlacementError(f"Invalid task ID: {task_id!r}. Expected a ticket like ECC-123.")
        result = {"status": "task", "taskID": task_id.upper(),
                  "projectID": project_for_prefix(projects, task_id),
                  "confidence": 1.0, "rationale": "explicit"}
    if result is None and prompt:
        tickets = known_tickets(projects, support)
        match = prompt_ticket(prompt, projects, tickets)
        if match:
            canonical, project_id = match
            result = {"status": "task", "taskID": canonical,
                      "projectID": project_id or project_for_prefix(projects, canonical),
                      "confidence": 0.95, "rationale": "prompt-ticket"}
    if result is None:
        project, top_level = match_project(cwd, projects)
        if project is not None:
            result = {"status": "project-inbox", "projectID": project.get("id"),
                      "confidence": 0.6, "rationale": "cwd-project"}
        elif top_level:
            result = {"status": "inbox", "confidence": 0.2, "rationale": "unmapped-repo"}
        else:
            result = {"status": "inbox", "confidence": 0.1, "rationale": "no-signal"}
    result["backend"] = BACKEND
    result["latencyMs"] = round((time.monotonic() - started) * 1000, 3)
    append_ledger(ledger_path(environment, support), result, prompt, cwd)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    classify_parser = subcommands.add_parser("classify", help="Classify one launch.")
    classify_parser.add_argument("--prompt", default=None)
    classify_parser.add_argument("--cwd", default=None)
    classify_parser.add_argument("--task", default=None)
    classify_parser.add_argument("--json", action="store_true", help="Pretty-print the result JSON.")
    options = parser.parse_args(argv)
    try:
        result = classify(prompt=options.prompt, cwd=options.cwd, task_id=options.task)
    except PlacementError as error:
        print(f"placement: {error}", file=sys.stderr)
        return 2
    if options.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        target = result.get("taskID") or result.get("projectID") or "inbox"
        print(f"{result['status']}: {target} (confidence {result['confidence']}, "
              f"{result['rationale']}, {result['backend']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
