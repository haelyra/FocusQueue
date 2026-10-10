<!-- BEGIN ECC FOCUS QUEUE AGENT CONTRACT v1 -->
## Focus Queue agent contract

- When `$FOCUS_QUEUE_ROUTER` is `1`, act only as an intake router. For the user's first objective, run `focus-queue-session route inspect --prompt "<complete objective>" --cwd "$PWD" --provider claude`. The packet lists every selectable project in `projects`, and `inferredProjectID` already follows a project the objective names (its ID, name, prefix, or a ticket ID like ECC-041) ahead of the launch directory. Choose the matching existing task only when the objective is the same work; otherwise choose the project the objective names — never accept `other` when a configured project clearly matches — and a concise new task title. Then run exactly one `focus-queue-session route start <routeID>` command with `--task <ID>` or `--project <ID> --task-title <TITLE>`, plus `--title`, `--description`, `--provider`, and any explicitly chosen `--model`, `--effort`, `--repository`, or `--workspace` values. Unknown options are rejected as errors, and a failed start rolls back its ticket, so fix the reported problem and retry the same route ID. Do not edit source or duplicate the handoff. Exit only when the result says `registered` and `routerAction` is `exit`; otherwise report the returned recovery locator and remain available.
- Backend interface quick reference (JSON on stdout, errors exit 1): `attach <TASK-ID>` registers this pane and is mandatory before any work; `identify <TASK> <SUBTASK> <title> <description>`; `progress <TASK> <SUBTASK> queued|working|idle|blocked "<summary>"`; `complete <TASK> <SUBTASK> "<summary>"`; `attention <TASK> <AGENT> approval|question|interrupted|incomplete|failed "<summary>"`; `result <TASK> <AGENT> "<summary>"`; `log <TASK> <AGENT> "<entry>"`; `context <TASK>` and `plan <TASK>` read task state; `task rename|priority|status` mutate ticket fields; `runtime locate <provider> <session-uuid>` checks whether a saved session is alive; `diagnose <TASK>` and `reconcile <TASK>` repair records. Never hand-edit `state.json`, `config.json`, or a `dashboard.json`: cached state overwrites direct edits and malformed JSON fails the whole queue load. The full backend contract lives at Docs/BACKEND_INTERFACE.md in the ECCFocusQueue repository.
- Start agents through the installed `claude` shell entry. It records a launch, creates an isolated coding worktree when possible, resolves project/task placement, and starts the managed tmux pane before Claude. Read the JSON file at `$FOCUS_QUEUE_AGENT_CONTEXT` before source edits. If it is unset or missing, run `focus-queue-session placement --prompt "<objective>"` from the intended repository and use the returned capsule. Stop source edits when its status is `blocked-conflict`.
- Trust capsule paths and IDs instead of guessing from transcripts. Missing fields may remain empty. A task with no repository match belongs to the `Other` project. Never invent a provider session UUID, reuse another writer's checkout, silently stash/reset user work, or work from Focus Queue's Application Support directory. Resume with the recorded agent and workspace.
- Claude Code does not export `CLAUDE_SESSION_ID` to the shell. The installed lifecycle hooks register this session by forwarding each hook event's `session_id` to Focus Queue; treat that hook registration as the identity source. If hooks are absent and this pane is unregistered, associate it manually with `focus-queue-session attach` using the `$FOCUS_QUEUE_TASK_ID` and `$FOCUS_QUEUE_SUBTASK_ID` values from the environment.
- Registration is mandatory and comes before any other work. Immediately at startup, run `focus-queue-session attach <TICKET-ID>` (the `$FOCUS_QUEUE_TASK_ID` value when set). If no ticket is known yet, run `focus-queue-session placement --prompt "<initial prompt>"` from the intended repository and then `identify` once the task and agent IDs are known, so the queue shows a prompt-derived title instead of a provider code. Do not begin source edits until registration succeeds; the record must name the task, the provider session, the tmux session for a managed pane, and the worktree plus branch for an isolated workspace.
- Treat an assigned agent workspace as immutable. A metadata refresh may keep the same path; work in another checkout requires a new agent assignment. Never retarget a running or saved agent to a different worktree.
- A promptless app agent starts with a generated `Agent N` label and no user prompt. On its first substantive user prompt, before source edits, give it a concise 2 to 6 word title and a brief one-sentence description by running `focus-queue-session identify "$FOCUS_QUEUE_TASK_ID" "$FOCUS_QUEUE_SUBTASK_ID" "<title>" "<description>"` exactly once. Do not replace an already descriptive or user-edited title. Provider hooks may perform the same update first; if so, preserve it.
- Task descriptions exist so a returning reader understands the purpose at a glance. Whenever you create, route, or update a task description or summary, answer what, why, and how directly: 1-2 sentences each for what the task is, why it matters, and how it is done. Never open with commit hashes, branch names, or internal terms the reader has no context for.
- Read `projectPlanPath` for concise project-specific practices and `taskPlanPath` for the task goal, scope, success criteria, outline, current focus, and next step. Create a brief missing plan and keep it current. Put decisions, detailed progress, evidence links, and handoffs in `taskLogPath` using `focus-queue-session log`; do not put decision history in the central plan.
- Use Focus Queue helper commands for progress, attention, results, and association. Preserve queue order, dismissed sessions, cleared subtasks, other agents' records, and concurrent changes. The orchestrator reconciles exceptions and cleanup; it is not required for normal placement or task creation.
- Before committing or asking the user to test, run the affected workflow's sanity test plus appropriate automated checks. Report concrete results and limitations. Follow repository delivery rules, and push only when authorized. Cleanup requires an inactive agent, a fully clean owned worktree, and proof that its branch was merged. Never force-remove a worktree.
- Integration agents must fetch the remote, require a clean canonical integration checkout, and preserve ancestry. Use a fast-forward-only update when the reviewed commit descends from the integration branch; otherwise create an explicit reviewed merge. Never reset the integration branch to another branch, copy a worktree over it, rebase published integration history, force-push it, or bypass repository push guards. If the remote advances, fetch and review the new commits before integrating again. After a push, verify the remote integration ref equals the local commit before building or installing.
- Never install a shared application build from a feature worktree. Commit and hand off feature work; only a clean canonical integration checkout at the current remote integration commit may replace the shared installation.
- Focus Queue owns labels after task association. A task uses one shared tmux session with one pane per agent, a managed usage bar, and native tmux window tabs. Do not add pane-spacing decoration or overwrite managed labels with `tabname`.

<!-- BEGIN ECC FOCUS QUEUE OUTPUT CONTRACT v1 -->
## Report format for user-facing output

Scope: these rules apply only to reports you write for the user in the
terminal — completions, stage transitions, and status answers. They do not
apply to router turns (`$FOCUS_QUEUE_ROUTER=1`), QChat conversation, or the
one-line summaries passed to `focus-queue-session` helper commands. The user
manages several agents in parallel and reads your reports cold, under time
pressure. Optimize for a reader who scans, not a reader who studies.

Produce these sections in this order. You may omit a section only by writing
`N/A — <reason>`. Never drop a section silently.

**0. Stage badge** — one line, always:

```
[Stage: <stage>] [Task: <ticket-id or short name>] [Artifact: <what proves the stage>]
```

Stages: `idea` → `planning` → `implementation` → `testing` → `refinement` →
`deployment` → `deployed-verification`. Derive the stage from artifacts that
exist (spec, plan, diff, test results), never from what you intend to do.

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

### Language rules

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

### Worked example

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
<!-- END ECC FOCUS QUEUE OUTPUT CONTRACT v1 -->
<!-- END ECC FOCUS QUEUE AGENT CONTRACT v1 -->
