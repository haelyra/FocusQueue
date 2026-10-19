#!/usr/bin/env python3
"""Measure placement accuracy, latency, and fallbacks against labeled launches.

`build` turns a support directory's placement capsules and task contexts into
labeled cases: the first prompt recorded for a task becomes a "new work" case
(that task is hidden from the candidates), and later prompts for the same task
become "existing task" cases. Cases hold real prompts, so keep them outside the
repository.

`run` replays cases through `focus_queue_placement.classify` with the real
configuration and dashboards (filtered per case into a temporary copy) and
prints accuracy by kind next to the heuristic baseline. Model calls use the
configured provider CLI, so a run spends subscription usage.

Case format (JSON lines): {"id", "prompt", "cwd", "expected": "<TASK-ID>"|"new",
"kind", "exclude": [task IDs hidden from candidates]}.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import re
import statistics
import sys
import tempfile


HERE = Path(__file__).resolve().parent
TICKET = re.compile(r"(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9_]*-[0-9]+(?![A-Za-z0-9_])")
# Generated labels and resume stubs carry no objective worth placing.
BOILERPLATE = re.compile(r"^(continue\b|resume\b|(codex|claude|kimi)\s·\s\w+\s*$)", re.IGNORECASE)


def load_placement():
    spec = importlib.util.spec_from_file_location("focus_queue_placement", HERE / "focus_queue_placement.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def clean_prompt(text):
    # Drop generated label lines: "Codex · 57a656", "Agent 6", "Blank Codex agent".
    label = re.compile(r"\s*((codex|claude|kimi)\s·\s\w+|agent\s+\d+|(blank\s+)?(codex|claude|kimi)\s+agent)\s*",
                       re.IGNORECASE)
    return "\n".join(line for line in str(text or "").splitlines() if not label.fullmatch(line)).strip()


def usable(prompt):
    return len(prompt) >= 30 and not TICKET.search(prompt) and not BOILERPLATE.match(prompt)


def build_cases(support):
    """Label each usable prompt by the task it ended up in, oldest first per task."""
    seen, records = set(), []
    for path in sorted((support / "tracking" / "placements").glob("*.json")):
        try:
            capsule = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        prompt = clean_prompt(capsule.get("promptHint"))
        if capsule.get("taskID") and usable(prompt):
            records.append((str(capsule.get("generatedAt", "")), capsule["taskID"].upper(), prompt,
                            capsule.get("workspacePath") or ""))
    for path in sorted((support / "tasks").glob("*/context.json")):
        try:
            context = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        for index, subtask in enumerate(context.get("subtasks") or []):
            prompt = clean_prompt(subtask.get("initialPrompt"))
            workspace = (subtask.get("workspace") or {}).get("path") or ""
            if usable(prompt):
                order = str(subtask.get("lastHeartbeatAt") or index)
                records.append((order, str(context.get("ticketID", "")).upper(), prompt, workspace))
    cases, first_seen = [], set()
    for order, task_id, prompt, cwd in sorted(records):
        key = prompt[:200].casefold()
        if key in seen or not task_id:
            continue
        seen.add(key)
        new = task_id not in first_seen
        first_seen.add(task_id)
        cases.append({"id": f"{task_id}-{len(cases) + 1}", "prompt": prompt, "cwd": cwd or str(Path.home()),
                      "expected": "new" if new else task_id, "kind": "real-new" if new else "real-existing",
                      "exclude": [task_id] if new else []})
    return cases


def case_configuration(configuration, exclude, reopen, directory, overrides=None):
    """Copy the configuration with each dashboard filtered to hide excluded tasks
    and reopen the expected task, which may have been resolved since."""
    hidden = {task.upper() for task in exclude}
    reopened = {task.upper() for task in reopen}
    copied = json.loads(json.dumps(configuration))
    copied.update(overrides or {})
    key = "focusQueueProjects" if isinstance(copied.get("focusQueueProjects"), list) else "projects"
    for index, project in enumerate(copied.get(key) or []):
        dashboard = project.get("dashboardPath")
        if not isinstance(dashboard, str) or not dashboard:
            continue
        try:
            document = json.loads(Path(dashboard).read_text())
        except (OSError, ValueError):
            continue
        document["tickets"] = [ticket for ticket in document.get("tickets") or []
                               if str(ticket.get("id", "")).upper() not in hidden]
        for ticket in document["tickets"]:
            if str(ticket.get("id", "")).upper() in reopened:
                ticket["status"] = "in-progress"
        target = directory / f"dashboard-{index}.json"
        target.write_text(json.dumps(document))
        project["dashboardPath"] = str(target)
    path = directory / "config.json"
    path.write_text(json.dumps(copied))
    return path


def score(case, result):
    """Classify one outcome: correct, false-match, missed-match, wrong-task, or fallback."""
    if result.get("modelError"):
        return "fallback"
    expected = case["expected"]
    if result.get("status") == "task":
        if expected == "new":
            return "false-match"
        return "correct" if result.get("taskID") == expected else "wrong-task"
    if expected == "new":
        return "correct"  # new-task, or a heuristic inbox the entry script turns into a task
    return "missed-match"


def run_case(placement, case, configuration, provider, base_environment, overrides=None):
    with tempfile.TemporaryDirectory(prefix="placement-eval-") as directory:
        directory = Path(directory)
        environment = dict(base_environment,
                           FOCUS_QUEUE_PLACEMENT_CONFIG=str(case_configuration(
                               configuration, case.get("exclude") or [],
                               [] if case["expected"] == "new" else [case["expected"]], directory,
                               overrides)),
                           FOCUS_QUEUE_PLACEMENT_LEDGER=str(directory / "ledger.sqlite"))
        # Removed worktrees resolve to their nearest surviving ancestor, usually the repository.
        cwd = Path(case["cwd"] or Path.home())
        while not cwd.is_dir() and cwd != cwd.parent:
            cwd = cwd.parent
        cwd = str(cwd)
        result = placement.classify(prompt=case["prompt"], cwd=cwd, environment=environment,
                                    provider=provider)
    return {"id": case["id"], "kind": case["kind"], "expected": case["expected"],
            "status": result.get("status"), "taskID": result.get("taskID"),
            "title": result.get("title"), "confidence": result.get("confidence"),
            "latencyMs": result.get("latencyMs"), "error": result.get("modelError"),
            "outcome": score(case, result)}


def summarize(label, rows):
    lines = [f"{label}: {sum(row['outcome'] == 'correct' for row in rows)}/{len(rows)} correct"]
    for kind in sorted({row["kind"] for row in rows}):
        subset = [row for row in rows if row["kind"] == kind]
        outcomes = {}
        for row in subset:
            outcomes[row["outcome"]] = outcomes.get(row["outcome"], 0) + 1
        detail = ", ".join(f"{name} {count}" for name, count in sorted(outcomes.items()))
        lines.append(f"  {kind}: {outcomes.get('correct', 0)}/{len(subset)} ({detail})")
    latencies = sorted(row["latencyMs"] for row in rows if row.get("latencyMs") is not None)
    if latencies:
        p95 = latencies[min(len(latencies) - 1, int(round(0.95 * (len(latencies) - 1))))]
        lines.append(f"  latency ms: p50 {statistics.median(latencies):.0f}, p95 {p95:.0f}, "
                     f"max {latencies[-1]:.0f}")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build", help="Write labeled cases from a support directory.")
    build.add_argument("--support", type=Path, required=True)
    build.add_argument("--out", type=Path, required=True)
    run = commands.add_parser("run", help="Replay cases and print accuracy and latency.")
    run.add_argument("--cases", type=Path, action="append", required=True)
    run.add_argument("--provider", choices=("claude", "codex", "kimi"), required=True)
    run.add_argument("--out", type=Path, help="Write per-case results as JSON lines.")
    run.add_argument("--workers", type=int, default=4)
    run.add_argument("--timeout", type=int, help="Override placementTimeoutSeconds for this run.")
    run.add_argument("--threshold", type=float, help="Override placementConfidenceThreshold.")
    options = parser.parse_args(argv)

    if options.command == "build":
        cases = build_cases(options.support)
        options.out.write_text("".join(json.dumps(case) + "\n" for case in cases))
        print(f"wrote {len(cases)} cases to {options.out}")
        return 0

    placement = load_placement()
    environment = dict(os.environ)
    configuration = placement.load_configuration(environment, placement.support_directory(environment))
    cases = [json.loads(line) for path in options.cases for line in path.read_text().splitlines() if line.strip()]
    overrides = {}
    if options.timeout:
        overrides["placementTimeoutSeconds"] = options.timeout
    if options.threshold is not None:
        overrides["placementConfidenceThreshold"] = options.threshold
    with ThreadPoolExecutor(max_workers=max(1, options.workers)) as pool:
        model_rows = list(pool.map(
            lambda case: run_case(placement, case, configuration, options.provider, environment, overrides),
            cases))
    baseline = [run_case(placement, case, configuration, None, environment) for case in cases]
    settings = placement.placement_settings(dict(configuration, **overrides), options.provider) or {}
    print(summarize(f"model {settings.get('provider')}/{settings.get('model')} "
                    f"(threshold {settings.get('threshold')}, timeout {settings.get('timeout')}s)", model_rows))
    print(summarize("heuristic baseline", baseline))
    for row in model_rows:
        if row["outcome"] != "correct":
            print(f"  ✗ {row['id']} [{row['kind']}] expected {row['expected']} → {row['outcome']}: "
                  f"{row['status']} {row['taskID'] or ''} {row['confidence']} {row['error'] or ''}",
                  file=sys.stderr)
    if options.out:
        options.out.write_text("".join(json.dumps(row) + "\n" for row in model_rows))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
