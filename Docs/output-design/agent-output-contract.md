# Agent Output Contract

Rules for every report you give the user: completions, stage transitions, and
status answers. These rules exist because the user manages several agents in
parallel and reads your output cold, under time pressure. Optimize for a reader
who scans, not a reader who studies.

## Report structure

Produce these sections in this order. You may omit a section only by writing
`N/A — <reason>`. Never drop a section silently.

**0. Stage badge** — one line, always:

```
[Stage: <stage>] [Task: <ticket-id or short name>] [Artifact: <what proves the stage>]
```

Stages: `backlog` → `idea` → `planning` → `implementation` → `testing` →
`refinement` → `deployment` → `qa` → `deployed-verification`.
Derive the stage from artifacts that exist (spec, plan, diff, test results),
never from what you intend to do.

**Task status follows report stage.** For a registered Focus Queue task, update
the canonical task status immediately before a report when its status bucket
changes:

- `backlog` is the default. Do not run a status command before active work.
- `idea` through `deployment` map to `in-progress`. Run
  `focus-queue-session task status "$FOCUS_QUEUE_TASK_ID" in-progress`.
- `qa` and `deployed-verification` map to `qa`. Run
  `focus-queue-session task status "$FOCUS_QUEUE_TASK_ID" qa`.
- If the precise stage is unavailable, use `in-progress`. If a more specific
  update fails, retry once with `in-progress`; report a second failure instead
  of claiming the status changed.

Skip the command when no task ID exists or the mapped status has not changed.
The stage badge remains evidence-derived even if the status update fails.

**1. BLUF** — 1–2 sentences. The result, plus the one thing the user must know
or do. Written for someone reopening this session cold: no assumed context.

**2. What / Why / How** — one paragraph, ≤100 words total:

- *What changed*: exact paths with line numbers, IDs, values. Never
  abstractions — `Config/ecc.config.json:14`, not "the config".
- *Why*: the line connecting this change to the user's request.
- *How we know*: evidence — the command run and what it returned
  ("swift test: 47 pass, 0 fail"). Never a prose assertion of success.

**3. Decision log** — one entry per major step, design choice, or functional
change. Skip trivia. Each entry:

- **What** was decided.
- **Why** — the reasoning; name rejected alternatives when they existed.
- **How verified** — evidence, or `not verified — planned in <stage>`.

Justification is mandatory. If you cannot verify something, say so and name
the stage that will close it. Never fill the gap silently.

**4. Big-picture fit** — default `N/A`. Include only when the change touches
architecture, multiple subsystems, or deviates from the plan. Then state why it
integrates correctly: checklists run, invariants preserved, constraints checked
against the spec. Per-step justifications in §3 usually cover the rest.

**5. QA instructions** — the fastest way for the user to verify this in
production-like conditions: exact commands, what to observe, expected result.
Scale to the task. "Tell me if the layout reads right" is valid for a visual
tweak; a pipeline change gets startup commands and expected output.

**6. Next steps** — what remains before done, concerns, discoveries that open
new routes, and the decision the user faces next. Omit only when the task is
verifiably complete and the evidence is in §2.

## Language rules

1. One idea per sentence. ≤25 words. Active voice: "I changed X", never
   "X was changed".
2. Lead words carry information: every heading, bullet, and paragraph starts
   with the operative content. No "Overview", no "Details", no throat-clearing.
3. Lists over prose. Number steps, bullet options.
4. Each fact stated once. No filler, no restating the request, no self-praise,
   no "great question".
5. Concrete referents always: `path/to/file.swift:42`, ticket IDs, exact
   values.
6. Define components before mechanism when the reader may not have them in
   mind.
7. One structural table or diagram when ≥3 parts interact. Never repeat its
   content in prose.
8. Every correctness claim attaches evidence or an explicit "not verified"
   marker. Banned without evidence: "works", "done", "should be fixed".
9. Confidence is binary and evidence-bound: "tested" or "not tested". No "I'm
   fairly confident", no five-point scales.
10. Output renders as terminal Markdown: shallow structure, no deep nesting,
    cite code as `path:line`.

## Worked example

A mid-size bug fix, shown complete. Match this shape.

```
[Stage: implementation → testing] [Task: ECC-214 session-attach] [Artifact: swift test 12/12 pass]

**BLUF:** Session attach no longer drops the WezTerm pane label when the task
name contains spaces; 12/12 attach tests pass. Run the QA steps below to
confirm in your live terminal.

**What / Why / How:** `Scripts/focus_queue_session.py:88` now shlex-quotes the
title before writing the WezTerm label; `Tests/test_focus_queue_session.py:34`
adds three regression cases. This fixes ECC-214: attaching to a task named
"Focus Queue Rework" silently kept the old label. Evidence:
`python3 -m pytest Tests/test_focus_queue_session.py` → 12 passed, 0 failed.

**Decision log:**
1. **Quote at write time, not parse time.** Sanitize in `set_tab_label`.
   The parse path is shared with tmux, where unquoted titles are valid;
   quoting at write time fixes all callers. Rejected: fixing the parser
   (breaks tmux), banning spaces (changes UX). Verified by the regression
   tests. Not verified: label behavior on a detached tmux session —
   planned in the testing stage.

**Big-picture fit:** N/A — single-call-site fix, no interface changes.

**QA:** 1. From a WezTerm pane:
`python3 Scripts/focus_queue_session.py attach ECC-214`.
2. Expected: tab label updates even with spaces in the task name.
3. `detach` restores the default label.

**Next steps:** Testing stage closes the detached-tmux gap above, then
commit. If QA shows the label unchanged, send me `wezterm cli list` output —
that distinguishes a quoting failure from a pane-ID mismatch.
```

Note what the example does: every correctness claim has evidence or a named
gap; the gap names the stage that closes it; `N/A` carries a reason; QA is
executable by a cold reader; next steps include a diagnostic branch.
