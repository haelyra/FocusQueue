#!/usr/bin/env python3
"""Focus Queue automatic-token audit.

Counts the tokens the app itself adds to agent inputs: launch briefs, global
instruction contracts, queue-chat envelopes, verifier prompts, and extractor
prompts. Counting is fully local: file reads, source-literal extraction, and
`focus-queue-session brief|rules` output measurement. No model is ever called,
so observing token usage never spends tokens.

Token counts are estimates. Without a bundled tokenizer this uses the common
chars-per-token heuristic: estimate = chars/4, bounded by chars/5 (low) and
chars/3 (high). Costs use a configurable USD-per-million-input-token price.
"""
import argparse
import ast
import json
import re
import subprocess
import sys
from pathlib import Path

CHARS_PER_TOKEN = 4.0
CHARS_PER_TOKEN_LOW = 5.0
CHARS_PER_TOKEN_HIGH = 3.0

# Inline-document caps from Sources/FocusQueueCore/TaskContext.swift
INLINE_CAPS = {
    "project_plan": 1500,
    "task_plan": 4000,
    "task_data": 2000,
    "user_data": 2000,
    "project_data": 3000,
}


def estimate(chars):
    return {
        "chars": chars,
        "tokens": round(chars / CHARS_PER_TOKEN),
        "tokens_low": round(chars / CHARS_PER_TOKEN_LOW),
        "tokens_high": round(chars / CHARS_PER_TOKEN_HIGH),
    }


def strip_swift_interpolations(literal):
    """Remove \\( ... ) interpolations from a Swift string literal body."""
    out = []
    i = 0
    while i < len(literal):
        if literal.startswith("\\(", i):
            depth = 1
            i += 2
            while i < len(literal) and depth:
                if literal[i] == "(":
                    depth += 1
                elif literal[i] == ")":
                    depth -= 1
                i += 1
        else:
            out.append(literal[i])
            i += 1
    return "".join(out)


def swift_func_span(source, marker, after=0):
    """Return the body span (text between braces) of the func named by marker."""
    start = source.find(marker, after)
    if start < 0:
        return ""
    open_at = source.find("{", start)
    if open_at < 0:
        return ""
    depth = 0
    i = open_at
    while i < len(source):
        ch = source[i]
        if source.startswith('"""', i):
            close = source.find('"""', i + 3)
            i = len(source) if close < 0 else close + 3
            continue
        if ch == '"':
            i += 1
            while i < len(source):
                if source.startswith("\\(", i):  # interpolation may nest braces
                    level = 1
                    i += 2
                    while i < len(source) and level:
                        if source[i] == "(":
                            level += 1
                        elif source[i] == ")":
                            level -= 1
                        i += 1
                elif source[i] == "\\":
                    i += 2
                elif source[i] == '"':
                    i += 1
                    break
                else:
                    i += 1
            continue
        if source.startswith("//", i):
            nl = source.find("\n", i)
            i = len(source) if nl < 0 else nl
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[open_at + 1 : i]
        i += 1
    return source[open_at + 1 :]


def swift_literals_in(span, whole_source="", span_offset=0):
    """Static chars of every string literal in span, interpolations stripped."""
    total = 0
    i = 0
    while i < len(span):
        if span.startswith('"""', i):
            close = span.find('"""', i + 3)
            if close < 0:
                break
            body = span[i + 3 : close]
            if body.startswith("\n"):
                body = body[1:]
            if whole_source:
                abs_close = span_offset + close
                line_start = whole_source.rfind("\n", 0, abs_close) + 1
                margin = whole_source[line_start:abs_close]
                if margin.strip() == "":
                    body = "\n".join(
                        line[len(margin):] if line.startswith(margin) else line
                        for line in body.split("\n")
                    )
            total += len(strip_swift_interpolations(body))
            i = close + 3
            continue
        if span[i] == '"':
            i += 1
            start = i
            while i < len(span):
                if span.startswith("\\(", i):
                    total += len(strip_swift_interpolations(span[start:i]))
                    level = 1
                    i += 2
                    while i < len(span) and level:
                        if span[i] == "(":
                            level += 1
                        elif span[i] == ")":
                            level -= 1
                        i += 1
                    start = i
                elif span[i] == "\\":
                    i += 2
                elif span[i] == '"':
                    total += len(strip_swift_interpolations(span[start:i]))
                    i += 1
                    break
                else:
                    i += 1
            continue
        i += 1
    return total


def swift_static_chars(path, marker, after_marker=None):
    """Static literal chars in the body of the func at marker.

    `after_marker` scopes the search when the func name alone is ambiguous.
    """
    source = Path(path).read_text()
    after = source.find(after_marker) if after_marker else 0
    if after < 0:
        return 0
    span = swift_func_span(source, marker, after=after)
    offset = source.find(span) if span else 0
    return swift_literals_in(span, whole_source=source, span_offset=offset)


def swift_let_string(path, name):
    """Value length of `static let <name> = \"...\"`-style constants."""
    source = Path(path).read_text()
    match = re.search(r'\b(?:static\s+)?let\s+' + re.escape(name) + r'\s*=\s*"', source)
    if not match:
        return 0
    i = match.end()  # just past the opening quote
    start = i
    total = 0
    while i < len(source):
        if source.startswith("\\(", i):
            total += len(strip_swift_interpolations(source[start:i]))
            level = 1
            i += 2
            while i < len(source) and level:
                if source[i] == "(":
                    level += 1
                elif source[i] == ")":
                    level -= 1
                i += 1
            start = i
        elif source[i] == "\\":
            i += 2
        elif source[i] == '"':
            total += len(strip_swift_interpolations(source[start:i]))
            return total
        else:
            i += 1
    return total


def python_string_constant(path, name):
    tree = ast.parse(Path(path).read_text())
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == name:
                    try:
                        value = ast.literal_eval(node.value)
                    except (ValueError, SyntaxError):
                        return None
                    return value if isinstance(value, str) else None
    return None


def run_session_command(session_bin, args):
    try:
        result = subprocess.run(
            [session_bin] + args, capture_output=True, text=True, timeout=30
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return None, str(exc)
    if result.returncode != 0:
        return None, result.stderr.strip() or f"exit {result.returncode}"
    return result.stdout, None


def audit(repo_root, task=None, subtask=None, session_bin=None, price_in=3.0):
    repo_root = Path(repo_root).resolve()
    session_bin = session_bin or str(Path.home() / ".local/bin/focus-queue-session")
    components = []

    def add(name, feature, trigger, frequency, chars, note="", automatic=True):
        entry = {
            "component": name,
            "feature": feature,
            "trigger": trigger,
            "frequency": frequency,
            "automatic": automatic,
            "note": note,
            **estimate(chars),
        }
        components.append(entry)
        return entry

    # --- Global instruction contracts (installed into ~/Documents) ---
    config = repo_root / "Config"
    for filename, label in [
        ("CLAUDE_GLOBAL_INSTRUCTIONS.md", "claude"),
        ("CODEX_GLOBAL_INSTRUCTIONS.md", "codex"),
    ]:
        path = config / filename
        if path.exists():
            add(
                f"Global agent contract ({label})",
                "Provider global instructions",
                "every provider session under ~/Documents",
                "per session (system context, re-sent every turn)",
                path.stat().st_size,
                note=str(path),
            )

    # --- Launch brief scaffold (static text in TaskContext.swift) ---
    task_context = repo_root / "Sources/FocusQueueCore/TaskContext.swift"
    if task_context.exists():
        header = swift_static_chars(task_context, "func briefHeader(")
        rule = swift_let_string(task_context, "dataWritingRule")
        detailed = swift_static_chars(task_context, "func agentPrompt(subtask:") + header + rule
        bootstrap = swift_static_chars(task_context, "func agentBootstrap(") + header + rule
        add(
            "Launch brief scaffold (detailed mode)",
            "Agent launch",
            "fresh agent launch (not resumes)",
            "once per agent",
            detailed,
            note="static lines only; user prompt and inlined files are extra",
        )
        add(
            "Launch brief scaffold (compact mode)",
            "Agent launch",
            "fresh agent launch without detailed instructions",
            "once per agent",
            bootstrap,
            note="static lines only",
        )

    # --- Live measurements via the CLI ---
    if task and subtask:
        text, error = run_session_command(session_bin, ["brief", task, subtask])
        if text is not None:
            add(
                f"Measured launch brief ({task}/{subtask[:8]})",
                "Agent launch",
                "fresh agent launch",
                "once per agent",
                len(text),
                note="focus-queue-session brief output, dynamic content included",
            )
        else:
            components.append({
                "component": f"Measured launch brief ({task})",
                "feature": "Agent launch",
                "trigger": "fresh agent launch",
                "frequency": "once per agent",
                "automatic": True,
                "note": f"skipped: {error}",
                **estimate(0),
            })
    text, error = run_session_command(session_bin, ["rules"])
    if text is not None:
        add(
            "Agent rules output",
            "Agent launch",
            "agent runs `focus-queue-session rules` (brief instructs it)",
            "typically once per agent (agent-initiated pull)",
            len(text),
            note="enters context as tool output only when the agent runs it",
        )

    # --- Queue chat envelope ---
    integrations = repo_root / "Sources/FocusQueueCore/Integrations.swift"
    if integrations.exists():
        envelope = swift_static_chars(
            integrations, "static func build(", after_marker="enum QueueAgentPrompt"
        )
        add(
            "Queue agent envelope (system prompt)",
            "Queue/task chat",
            "every queue-chat message send",
            "per user message",
            envelope,
            note="re-sent in full on every message to the persistent queue agent",
        )
        verifier = swift_static_chars(
            integrations, "func verify(", after_marker="actor CodexCompletionVerifier"
        )
        add(
            "Completion review prompt",
            "Completion verification",
            "all subtasks complete (auto) or review button",
            "per completion event",
            verifier,
            note="one-shot verifier agent",
        )

    # --- Document chat wrapper ---
    doc_conversation = repo_root / "Sources/ECCFocusQueue/DocumentConversation.swift"
    if doc_conversation.exists():
        wrapper = swift_static_chars(doc_conversation, "func prompt(document:")
        add(
            "Document chat wrapper (static)",
            "Document chat",
            "every document-chat message send",
            "per user message",
            wrapper,
            note="plus up to 160,000 chars of <source> excerpts and 20,000 chars of history",
        )

    # --- Python automation prompts ---
    scripts = repo_root / "Scripts"
    extractor = scripts / "focus_queue_extractor.py"
    if extractor.exists():
        for name, label in [("INSTRUCTIONS", "instructions"), ("SYSTEM_PROMPT", "system prompt")]:
            value = python_string_constant(extractor, name)
            if value:
                add(
                    f"Data-placement extractor {label}",
                    "Data placement (off by default)",
                    "UserPromptSubmit hook when enabled",
                    "per user prompt",
                    len(value),
                    note="one-shot extractor call; facts land in future briefs",
                )
    placement = scripts / "focus_queue_placement.py"
    if placement.exists():
        value = python_string_constant(placement, "SYSTEM_PROMPT")
        if value:
            add(
                "Placement classifier system prompt",
                "Launch placement",
                "app-side launch classification",
                "per launch",
                len(value),
                note="app-side only; never visible to the launched agent",
            )

    total = sum(c["tokens"] for c in components)
    result = {
        "repo_root": str(repo_root),
        "estimator": {
            "method": "chars/4 heuristic",
            "chars_per_token": CHARS_PER_TOKEN,
            "bounds": [CHARS_PER_TOKEN_LOW, CHARS_PER_TOKEN_HIGH],
            "caveat": "estimates only; no provider tokenizer is bundled",
        },
        "price_per_mtok_input": price_in,
        "components": components,
        "total_tokens_per_full_pass": total,
        "inline_caps_chars": INLINE_CAPS,
        "scenarios": scenarios(components, price_in),
    }
    return result


def scenarios(components, price_in):
    def tokens_of(prefix):
        return sum(c["tokens"] for c in components if c["component"].startswith(prefix))

    contract = max(
        (c["tokens"] for c in components if c["feature"] == "Provider global instructions"),
        default=0,
    )
    brief = tokens_of("Measured launch brief") or (
        tokens_of("Launch brief scaffold (detailed") + tokens_of("Agent rules")
    )
    launch = brief + contract
    queue_message = tokens_of("Queue agent envelope") + contract

    def cost(tokens):
        return round(tokens / 1_000_000 * price_in, 6)

    return {
        "single_agent_launch": {"tokens": launch, "cost_usd": cost(launch)},
        "single_queue_message": {"tokens": queue_message, "cost_usd": cost(queue_message)},
        "workday_10_launches_20_messages": {
            "tokens": launch * 10 + queue_message * 20,
            "cost_usd": cost(launch * 10 + queue_message * 20),
        },
    }


def render_report(result):
    lines = [
        "# Focus Queue token audit",
        "",
        f"Estimator: {result['estimator']['method']} "
        f"(bounds chars/{result['estimator']['bounds'][0]:g}–chars/{result['estimator']['bounds'][1]:g}); "
        "local counting only, no model calls.",
        f"Input price: ${result['price_per_mtok_input']:g} per million tokens.",
        "",
        "| Component | Feature | Frequency | Chars | Tokens (est) |",
        "|---|---|---|---:|---:|",
    ]
    for c in result["components"]:
        lines.append(
            f"| {c['component']} | {c['feature']} | {c['frequency']} | "
            f"{c['chars']:,} | {c['tokens']:,} |"
        )
    lines += ["", "## Scenarios", "",
              "| Scenario | Tokens | Cost (USD) |", "|---|---:|---:|"]
    for name, s in result["scenarios"].items():
        lines.append(f"| {name} | {s['tokens']:,} | ${s['cost_usd']:.6f} |")
    lines.append("")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=str(Path(__file__).parents[1]))
    parser.add_argument("--task", help="task ID for a live brief measurement")
    parser.add_argument("--subtask", help="subtask ID for a live brief measurement")
    parser.add_argument("--session-bin", help="path to focus-queue-session")
    parser.add_argument("--price-in", type=float, default=3.0,
                        help="USD per million input tokens (default 3.0)")
    parser.add_argument("--json-output", help="write raw results JSON here")
    parser.add_argument("--report-output", help="write markdown report here")
    args = parser.parse_args(argv)

    result = audit(
        args.repo_root, task=args.task, subtask=args.subtask,
        session_bin=args.session_bin, price_in=args.price_in,
    )
    report = render_report(result)
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(result, indent=2) + "\n")
    if args.report_output:
        Path(args.report_output).write_text(report)
    if not args.json_output and not args.report_output:
        print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
