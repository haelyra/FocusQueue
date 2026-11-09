# ECC Focus Queue — Backend Interface Guide for Agents

**Audience:** AI agents (Codex, Claude, Kimi), the orchestrator, and any external program that needs to interact with ECC Focus Queue without the UI.

**Purpose:** This is the complete command-level contract for the app's backend interface: every CLI command, every data file, every environment variable, and — critically — the *correct* way to register tasks, agents, and sessions so the app stays consistent. It ends with a failure analysis and a list of missing commands and hardening proposals.

Sources: `Sources/FocusQueueSession/main.swift`, `Sources/FocusQueueCore/*`, `Sources/ECCFocusQueue/*`, `Scripts/focus_queue_*.py`, `Config/*.json`, `Docs/AGENT_CONTRACT.md`, `Docs/ACTION_BOUNDARIES.md`, `Docs/REMOTE_SESSION_RECALL.md`, `Docs/DATA_BACKFILL_AUDIT.md`.

---

## 1. Architecture at a glance

There is **no daemon API, no URL scheme, no XPC, no AppleScript**. The entire backend interface is:

1. **One Swift CLI binary** — `focus-queue-session` (installed at `~/.local/bin/focus-queue-session`, also inside the app bundle at `Contents/MacOS/focus-queue-session`). This is the authoritative mutation path. All output is pretty-printed JSON on stdout; errors go to stderr with exit 1.
2. **Python harness CLIs** — `focus-queue-codex`, `focus-queue-claude`, `focus-queue-kimi`, `focus-queue-report`, plus connector CLIs (`focus-mail`, `focus-discord`, …).
3. **A shared file tree** under the support directory, guarded by `flock` lock files.
4. **Two distributed notifications** the app listens for.

### 1.1 The support directory

Everything roots at:

```
~/Library/Application Support/ECC Focus Queue/
```

overridable with `FOCUS_QUEUE_SUPPORT_DIR` (used by tests to isolate state). Key layout:

| Path | Contents |
|---|---|
| `config.json` | `AppConfiguration` — projects, providers, verifier, daily report |
| `state.json` | `LocalState` — UI state **and `agentSessions[]`** (session registry) |
| `tasks/<TICKET>/context.json` | `TaskContext` — subtasks, workspaces, tmux refs, per-task state |
| `tasks/<TICKET>/plan.md` | Task plan (Markdown) |
| `tasks/<TICKET>/agent-log.md` | Append-only agent log |
| `user/data.md`, `projects/<id>/data.md` | Saved user and project facts; created blank with the project's plan, at install, and at app start, then delivered to every agent in the project (see `data-event`) |
| `tracking/data-delivery/<sha256>` | Digest of the shared data each provider session last received; pruned after 30 days |
| `tasks/<TICKET>/data.md` | Cached task facts and test data; created blank at task initialization and shown in the task's Evidence and links, map Context slots, capsule, and agent prompts |
| `tasks/<TICKET>/archive/snapshot-*` | Context snapshots (max 100) |
| `agent-registrations/<sha256>.json` | Session registration inbox |
| `external-agent-sessions/<sha256>.json` | Hook registration receipts |
| `tracking/placements/<launch-uuid>.json` | Placement capsules |
| `tracking/launches/`, `tracking/resolutions/` | Intake receipts, launch→session resolution |
| `agent-routes/` | Retired: route intents from the removed Router agent (nothing reads them) |
| `queue-order/order[-<b64 project>].json` | Queue ordering per project |
| `logs/agent-startups/<TASK>/<subtask>.json` | Retired: startup receipts from the removed Router agent |
| `library/` | Durable cross-device history |
| `ingestion/` | Daily-report state, reports, launch requests |
| `<dashboardPath>` (outside support dir) | Per-project `dashboard.json` — the ticket list |

The live dashboard is at `config.json`'s `dashboardPath` (currently `/Users/hira/Documents/ECC/ecc-dashboard/data/dashboard.json`), **not** inside the support dir.

### 1.2 Locking discipline

All writers — Swift and Python — take advisory `flock` locks:

- `.<filename>.focus-queue.lock` next to any locked file (dashboards, config)
- `tasks/<TICKET>/.lock` for per-task context mutations
- `queue-order/order.lock`, `agent-registrations/.inbox.lock`

**Any program that writes these files without taking the same locks risks torn reads and lost updates against the app.** Writes must also be atomic (`write temp → rename`), mode 0600, and **never through a symlink** — symlinks are treated as hostile and rejected almost everywhere.

### 1.3 How the app notices changes

- `com.haelyra.ecc-focus-queue.agent-registration` — posted by every `focus-queue-session` mutation; the app imports pending registrations and refreshes.
- `com.haelyra.focus-queue.project-catalog-change` — posted by `projects create`; the app reloads `config.json`.

Everything else is **polled**: dashboards and task contexts are re-read when mtime/size/inode changes (2 s tick while the panel is visible, 30 s hidden, forced re-read every 60 s). **Direct edits to `config.json` are ignored until restart** (or a project-catalog notification), and **direct edits to `state.json` are worse than ignored** — the app holds a cached copy in memory and will overwrite your edits on its next save.

---

## 2. The environment contract

Agents receive and consume identity through environment variables. These are the backbone of registration — if they are missing or stale, registration silently degrades.

| Variable | Set by | Meaning |
|---|---|---|
| `FOCUS_QUEUE_SUPPORT_DIR` | launcher/tests | Support dir override |
| `FOCUS_QUEUE_TASK_ID` | managed launch | Ticket this agent belongs to |
| `FOCUS_QUEUE_SUBTASK_ID` | managed launch | Subtask (agent slot) ID |
| `FOCUS_QUEUE_LAUNCH_ID` | entry wrapper | Launch UUID → placement capsule path |
| `FOCUS_QUEUE_AGENT_CONTEXT` | entry wrapper | Direct path to the placement capsule JSON |
| `FOCUS_QUEUE_TMUX_NAME` | managed tmux | Owning tmux session name |
| `FOCUS_QUEUE_PROJECT_ID` | queue commands | Scope guard for `queue` mutations |
| `FOCUS_QUEUE_PROVIDER` | entry wrapper | `codex` / `claude` / `kimi` |
| `CODEX_THREAD_ID` / `CODEX_SESSION_ID` | Codex runtime | Provider session UUID |
| `CLAUDE_CODE_SESSION_ID` (or an explicit `CLAUDE_SESSION_ID`) | Claude Code runtime | Provider session UUID; managed panes strip both |
| `WEZTERM_PANE`, `WEZTERM_UNIX_SOCKET` | WezTerm | Terminal pane identity |
| `TMUX`, `TMUX_PANE` | tmux | tmux identity |

**Known gap:** there is no `KIMI_SESSION_ID`-style variable in the session-binding code. Kimi panes cannot be identified from env alone; Kimi must register through hooks (`register-event`). The `attach` usage text claims Kimi support it cannot deliver from env (`main.swift:17`, `TaskContext.swift:14-25`).

---

## 3. `focus-queue-session` — command reference

Canonical usage string lives at `Sources/FocusQueueSession/main.swift:16`. Every command below emits JSON.

Inside a managed pane, `attach`, `context`, and `plan` may omit `<TASK>`; `progress`, `complete`, `attention`, `result`, `log`, `identify`, `review-push`, and `workspace` may omit `<TASK> <SUBTASK>`. Omitted IDs default to `$FOCUS_QUEUE_TASK_ID` and `$FOCUS_QUEUE_SUBTASK_ID`. `focus-queue-session rules` prints the agent rules that launch briefs no longer repeat (plain text, not JSON).

### 3.1 Session registration (use these, in this order)

**`focus-queue-session attach <TASK-ID>`**
The mandatory first command for any agent that knows its ticket. Reads the provider session UUID from env (`CODEX_THREAD_ID`/`CODEX_SESSION_ID`, or `CLAUDE_SESSION_ID`/`CLAUDE_CODE_SESSION_ID`; when both providers' IDs are inherited, `FOCUS_QUEUE_PROVIDER` decides), registers the current WezTerm/tmux pane into `state.json.agentSessions`, sets the terminal label (`<Task name>` or `<Task name> · tmux`), and posts the registration notification.

Output keys: `status, registrationID, provider, sessionID, taskID, subtaskID, agentID, parentSessionID, placementPath`.

Pitfalls:
- Fails with `missingSessionIdentity` if the env session ID is absent **or not a UUID** (Kimi ULIDs fail here — use `register-event` instead).
- Correctly ignores a stale inherited `FOCUS_QUEUE_SUBTASK_ID` — re-attach after switching tickets, every time.
- **Does not validate that the ticket exists on a dashboard.** Attaching to a typo'd ticket registers a session for a task that doesn't exist.
- A Codex sub-agent thread (rollout `session_meta` marks `source.subagent`, `thread_source: subagent`, or `parent_thread_id`) registers nothing: attach returns `status: "subagent"` with `parentSessionID` and the inherited `taskID`/`subtaskID`, and exits 0. `register-event` and app process discovery likewise never add an agent row for a Codex sub-agent, so one Codex session stays one agent.

**`focus-queue-session register-event --provider codex|claude|kimi [--task <TASK-ID>]`**
The hook-ingestion path; reads **one JSON `ExternalAgentEvent` from stdin** (≤1 MB, oversized → exit 1). This is how provider hooks (SessionStart, UserPromptSubmit, SubagentStart/Stop, ProcessDiscovery) register identity. Payload (snake_case):

```json
{
  "session_id": "<uuid; required>",
  "cwd": "/absolute/path; required",
  "hook_event_name": "SessionStart",
  "prompt": "optional first prompt",
  "agent_id": "optional",
  "parent_session_id": "optional",
  "focus_queue_discovered_subagent": false
}
```

A non-UUID `session_id` is accepted but degrades the record to a non-provider identity. Malformed JSON → exit 1.

**`focus-queue-session status-event --provider codex|claude|kimi`**
The status-hook path; reads one provider hook payload from stdin (≤1 MB), prints nothing, and always exits 0, so a failure never reaches the agent. It finds the agent whose saved provider session equals `session_id`. The inherited `FOCUS_QUEUE_TASK_ID`/`FOCUS_QUEUE_SUBTASK_ID` are a fast path, used only when that agent's session matches, so a nested launch never updates its parent. The app reads the change on its next refresh (2 s while visible). A top-level `UserPromptSubmit` also starts background data extraction for the agent's project (from `FOCUS_QUEUE_AGENT_CONTEXT`, else the dashboard that owns `FOCUS_QUEUE_TASK_ID`) unless `data-placement off` is set. Every app launch carries this hook, so extraction does not depend on the optional global `register-event` hook; when both report a prompt, a one-time claim under `extraction-claims/` keeps it to one model call.

| Hook event | Status |
|---|---|
| `UserPromptSubmit` | Working; clears the unread result; reopens a completed agent |
| `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `TurnStarted` (not from a sub-agent, `agent_id` set) | Working |
| `PermissionRequest`; `Notification` `permission_prompt` | Needs approval |
| `Notification` `elicitation_dialog` | Question |
| `Stop` | New result, summary `last_assistant_message` |
| `StopFailure` | Failed, or quota exhausted for `rate_limit`/`billing_error` |
| `Interrupt` (Codex, Kimi) | Interrupted |

App-launched Claude agents receive these hooks through the launch's single `--settings` value (Claude reads only the last one), which also carries `disableAllHooks: false` so the agent reports status even when the user's settings turn hooks off. The user's settings files are not changed. Codex and Kimi keep transcript tracking: Codex hooks require a trust review this integration does not bypass, and Kimi's `wire.jsonl` already records turns, approvals, and interrupts. A live Codex pane whose tmux title starts with Codex's braille spinner counts as a running turn.

While the latest status came from a hook and the pane is live, Working lasts until a turn end is reported (up to four hours), instead of the one-hour live-pane limit for transcript-only agents. Claude sends no hook for Esc or for answering an approval: the transcript's interrupt marker covers Esc, and an approval dialog that disappears from the pane returns the agent to Working.

**`focus-queue-session identify <TASK-ID> <SUBTASK-ID> <title> <description>`**
Sets/replaces the agent's display title and assignment description. Hook-independent fallback for naming an `Agent N` slot.

### 3.2 Placement

**`focus-queue-session placement [--prompt <text>] [--task <ID>] [--launch <UUID>] [--cwd <path>] [--no-create]`**
Runs the deterministic placement resolver and writes a capsule to `tracking/placements/<launch-uuid>.json`. The capsule (`AgentPlacementCapsule`) is the agent's source of truth: `projectID, projectDataPath, userDataPath, taskPrefix, taskID?, agentID?, provider, workspacePath, branch?, tmuxName?, tmuxPaneID?, projectPlanPath, taskPlanPath?, taskLogPath?, taskDataPath?, status (placed|project-inbox|blocked-conflict)`.

**Rule: read your capsule (`$FOCUS_QUEUE_AGENT_CONTEXT`) before any source edit. Stop on `blocked-conflict`.**

### 3.3 Router agent (removed)

The Router agent, its `route inspect` / `route start` commands, the in-app composer, and the `automaticAgentRouting` setting were removed on 2026-10-19 (FOC-026). Placement replaces them: `fq` and the + task creator classify the prompt with one small-model call, then join an open task or create a titled one (§9). Agents started by the router keep `launchConfiguration.routeID`, which still names their placement capsule.

### 3.4 Task mutations

**`task create <PROJECT-ID> <title> <summary>`** — creates a backlog task in the named active project through the locked dashboard repository. It chooses the next project ID, returns the existing open task for an exact title and summary replay, and initializes its task context.

**`data place <user|project|task> <target-id> <fact>`** — appends one short fact to `user/data.md`, `projects/<id>/data.md`, or `tasks/<ID>/data.md`. The command verifies active project or open task identity, limits the fact to 200 characters and two sentences, rejects symlink destinations, and returns `{scope,targetID,path,added}`. An identical line returns `added: false`. Use `task create` for deferred work; the extractor calls these commands after validating the model proposal. New projects get an empty `data.md`. **`data-placement on|off|status`** switches prompt extraction; it is on unless the user turned it off.

**`data ensure`** — creates empty `user/data.md` and `projects/<id>/data.md` files for every active project. It preserves existing contents and returns `{created,existing}` path lists. The installer runs it, and every path that prepares a project plan creates the same files, so a manual run is only needed to repair a catalog. Append concise facts with `data place user user "<fact>"` or `data place project <id> "<fact>"`; this command only creates the files.

**`data show <PROJECT-ID>`** — prints the project's saved user and project facts in the form a launch brief inlines them, or nothing when there are none. The Codex entry passes them to a launch as `developer_instructions`, unless the brief already carries them or the user set their own.

**`data-event --provider claude`** — the shared-data hook. It reads one hook payload from stdin, always exits 0, and prints Claude `additionalContext` JSON when the session has not seen the current facts. It runs synchronously on `UserPromptSubmit` and on `SessionStart` for `clear|compact`, in every app and shell launch. A prompt that already contains the facts, such as a launch brief, counts as delivered. Other providers read saved facts through their brief, launch arguments, or the capsule's `userDataPath` and `projectDataPath`, so a running Codex or Kimi agent sees a new fact at its next launch.

**`task rename <TASK-ID> <title...>`** — revision-checked rename.
**`task priority <TASK-ID> critical|high|medium|low`** — validated enum.
**`task status <TASK-ID> <status>`** — ⚠ **accepts any string.** No enum validation. A typo (`complted`) writes successfully and the ticket just stays "open" forever. See §8.
`resolved` and `cancelled` are final: the command then runs completion cleanup (below) and reports its summary as `cleanup`.

**`task link <TASK-ID> <url> <label> [type]`** — appends an evidence link to the ticket under the dashboard lock with a revision check. A link whose URL is already present is left unchanged. Use this instead of hand-editing `links`.

These mutations go through `JSONDashboardRepository` with optimistic-concurrency revision checks, duplicate-ID rejection, and type-safe re-encoding — this is what hand-editing `dashboard.json` bypasses.

There is no `task show` or generic `task set <field>`.

### 3.5 Queue ordering

**`queue list` · `queue reset` · `queue move <TASK-ID> top|bottom|before <ID>|after <ID>` · `queue reorder <TASK-ID>...`**
Scoped by `FOCUS_QUEUE_PROJECT_ID`. Writes `queue-order/order-<b64(project)>.json` under `order.lock`. `queue reset` restores priority order. Emits `{"order": [...]}`.

### 3.6 Subtask (agent) lifecycle

These manage the per-agent slots inside `tasks/<TICKET>/context.json`:

| Command | Purpose |
|---|---|
| `add <TASK> <codex\|claude\|kimi> <title> <description>` | Create a queued subtask (title ≤200, description ≤2000 chars) |
| `rename <TASK> <SUBTASK> <title>` | Rename a subtask |
| `identify <TASK> <SUBTASK> <title> <description>` | Set title + assignment description |
| `progress <TASK> <SUBTASK> <queued\|working\|idle\|blocked> <summary>` | Heartbeat/status update (validated enum) |
| `complete <TASK> <SUBTASK> <summary>` | Mark completed with result summary |
| `attention <TASK> <AGENT> <approval\|question\|interrupted\|incomplete\|failed> <summary>` | Flag the agent as needing the user |
| `result <TASK> <AGENT> <summary>` | Record a result without completing |
| `archive-agent <TASK> <SUBTASK>` | Archive a finished agent slot |
| `pause <TASK> <SUBTASK>` | Press Esc in the agent's managed tmux pane to stop its turn, then record `pausedAt` (status idle). Refuses agents without a managed pane or still at a folder-trust prompt |
| `resume <TASK> <SUBTASK>` | Paste a short continue prompt into the same conversation and clear `pausedAt` (status working). A later typed prompt also clears the pause |
| `associate <TASK> <AGENT> <SUBTASK>` | Link a registered session to a subtask |
| `log <TASK> <AGENT> <entry>` | Append-only entry to `agent-log.md` (task-locked, concurrency-safe) |
| `context <TASK>` | Dump the full `TaskContext` JSON plus derived `agentLogPath` and `dataPath` |
| `plan <TASK>` | Print `plan.md` |
| `workspace <TASK> <SUBTASK> <abs-path>` | Record the agent's workspace (immutable once set — first write wins) |
| `review-push <TASK> <SUBTASK>` | Gated push review; exit 1 if rejected |
| `agents clear --all` | ⚠ Wipes **all** agent sessions/subtasks/registrations. No confirmation, processes keep running untracked. |

### 3.7 Runtime diagnostics & repair

| Command | Purpose |
|---|---|
| `runtime locate <provider> <session-id>` | Is this provider session alive? → `status (running\|stopped\|unknown), processID, tmux identity` |
| `runtime repair <TASK> <SUBTASK>` | Repair a broken runtime record |
| `diagnose <TASK>` | Read-only WezTerm/socket inspection; reports zero panes when WezTerm is not installed |
| `reconcile <TASK> [--no-cleanup]` | Repair task documents, write a receipt |
| `cleanup <TASK> [--dry-run]` | Completion cleanup for one task: kill its tmux sessions, archive unmerged or uncommitted work under `refs/focus-queue/archive/`, stage its worktrees in `.worktrees/.trash`, delete its local branches and merged remote branches, stage `archive/` and `maintenance-history/`. Writes `tasks/<TASK>/cleanup.json`. |
| `cleanup --completed [--orphans] [--dry-run]` | Backfill: run completion cleanup for every resolved or cancelled ticket; `--orphans` also retires managed worktrees and `focus-queue/*` branches no open ticket owns (a worktree any process uses is kept). Every project dashboard must load. |
| `cleanup --purge` | Delete staged items whose 7-day `purgeAfter` has passed. The app purges at most every 6 hours. |
| `architecture <TASK> [repository-path]` | Generate/update architecture docs |

### 3.8 Projects

**`projects list` · `projects recover` · `projects create --id <id> --name <name> --workspace <abs-path> --from <project-id> --task <TASK-ID> [--task ...]`**
`create` is transactional and posts the project-catalog-change notification so the running app reloads `config.json`. This is the *only* safe way to add a project while the app runs.

**`development <PROJECT-ID> show | link <TASK-ID> <step-id|none> [module] | unlink <TASK-ID> | step <step-id> <pending|inProgress|done|accepted> | phase <planning|phase0|implementation|prerelease|release> | sync`**
Locked edits of `projects/<id>/development.json`, the per-project development process (FOC-117). Every write is one read-modify-write under the project file lock; a malformed file throws and is never overwritten. `link` records a *human* link (a step from any phase, or `none` for work outside the process) that the steward never overrides; the task must exist in that project's dashboard. `step … accepted` is the human acceptance; accepting the last step of a phase advances the phase. `sync` runs the same steward pass the app runs.

The process updates itself outside agent sessions:
1. **Task status (no model).** On each app refresh (at most every 30 s), an open linked task makes its step active; when every linked task is closed the step is done and linked modules are implemented. Automatic updates only raise a step, never accept it, and a human reset to pending holds.
2. **Steward (placement model).** When a project's *signature* changes (a new unlinked task, a new Markdown file in the project folder or `modules/`, a module, or the phase), the app runs `focus_queue_placement.py develop` once (at most every 120 s; failures retry after 30 min). The prompt carries the step catalog, unlinked tasks, and file headings. The reply proposes links and step evidence, which the app validates and applies. It uses the placement provider, model, and effort, and Settings › Placement › model off disables it. Usage is recorded under the `development` source.
3. **Agents** get at most one brief line naming their own step's phase rule (`Development process (Phase 0, step Scaffolding & environment): …`), or none when the task is linked outside the process.

### 3.9 Library (durable history)

`library migrate | status | task <TASK-ID> | document <TASK-ID> <file.md> [guide|architecture|reference] | export <dest> | restore <src>` — append-mostly cross-device history under `library/`.

### 3.10 tmux

`tmux list | panes <name> | save | restore | persistence | arrange <name> | manual <name> | reflow <name> [--server s] | start <name> [--cwd dir] [-- cmd...] | start-agent <TASK> <AGENT> [--cwd dir] -- cmd... | attach <name> [--pane %N] | attach-reference <json> [--task T --agent A] | reference <name> <%pane> [--task T --agent A] --server s | ssh-command <user@host> <name>`

Managed agent sessions are named `fq-<subtaskID>` on the dedicated `ecc-focus-queue` tmux server; task-shared sessions are `fq-task-<task-id>`; unmanaged inbox sessions are `fq-codex-*` / `fq-claude-*`. `attach*` ends in `execv` and requires a TTY.

### 3.11 Misc

**`intake-changed`** — emits `{"status":"notified"}` and posts the change notification.

---

## 4. Provider harness CLIs

Installed at `~/.local/bin/focus-queue-codex|claude|kimi`. All three share one contract: global `--runtime <dir>`, subcommands `chat | run | reset`, timeout validated to 10–900 s (exit 2 on invalid), failures exit 1 with `<Provider> Queue harness failed: ...`.

**`chat --session <name> --workspace <dir> --prompt-file <path> [--timeout 120] [--model M] [--effort E] [--context-dir D] [--writable-dir D]*`**
Persistent per-session conversation. Session map at `<runtime>/sessions.json` under `sessions.lock`; stale sessions auto-retry with a fresh session. Default runtimes: `agent-claude/`, `agent/`, `agent-kimi/` under the support dir.

**`run --workspace <dir> --prompt-file <path> [--sandbox read-only|workspace-write] [--output-schema <json>] [--usage-file <path>] [--disable-tools] [--model M] [--effort E] [--label L]`**
One-shot headless run. With `--output-schema`, the reply is validated against the schema with one correction retry; the validated JSON is printed. `--usage-file` receives token counts. Every run writes prompt-free `<runtime>/latest-run.json` diagnostics.

**`reset --session <name>`** — drop a saved session id.

Harness-specific sharp edges:

- **Kimi:** `--effort` is parsed and silently dropped; `--disable-tools` cannot actually disable Kimi tools (prompt contract only).
- **Claude:** `--sandbox read-only` without `--disable-tools` still runs with tools enabled (`--permission-mode bypassPermissions`). "read-only" is only the sandbox flag.
- **`--label`** is parsed but never used in both Codex and Claude harnesses — silent no-op.
- Several scripts hardcode `/Users/hira/...` defaults — not portable.

## 5. Reporting & connector CLIs

**`focus-queue-report`** (`Scripts/focus_queue_morning.py`) — the ingestion pipeline:

```
focus-queue-report {collect|dry-run|run|mail-snapshot}
  [--config PATH] [--runtime PATH] [--platform discord|telegram|email|github]*
  [--trigger scheduled|manual|chat] [--comprehensive] [--recheck]
  [--agent-provider codex|claude|kimi] [--agent-model M] [--agent-effort E]
```

- `collect` — gather, print, no writes. `dry-run` — classify and count proposals, no writes.
- `run` — validate proposals against `Config/task-proposals.schema.json` and apply them to the dashboard under the shared lock. Exit 0 ok, 2 if any source failed, 1 on error.
- This is currently **the only validated task-creation path** — the schema enforces `title, projectID, category, priority, summary, next, doneWhen, sourceKeys, sourceLinks` on every new task.

**Connectors:** `focus-mail` (`authorize|status|search|read|open`), `focus-discord` (`status|channels|search|read`), `focus_queue_gmail.py`, `focus_queue_connectors.py` (readiness report), `focus_queue_data_audit.py` (read-only structural inventory of `tasks/<TICKET>/` — checks exactly the fields that are often missing: `ticketID, title, summary, updatedAt, worktreePath, planPath, subtasks, successCriteria`).

**`focus-queue-map`** — `snapshot <TASK>`, `diagram <TASK> [--view typical|context|agent]`, `scope <TASK> <SUBTASK> ...`, `resources --import`, `activity --import`. Task node/relation maps and Mermaid diagrams.

---

## 6. Data schemas (what "correct" looks like)

### 6.1 Dashboard ticket (`dashboard.json` → `tickets[]`)

```json
{
  "id": "FOC-123",                    // required; unique across ALL project dashboards (case-insensitive)
  "projectID": "focus-queue",
  "title": "...",                     // defaults to id if missing — always set it
  "category": "Bug",                  // Inbox|Bug|Feature|Maintenance|Community|Security
  "priority": "high",                 // critical|high|medium|low (default medium)
  "status": "backlog",                // default backlog; "resolved"/"cancelled" (case-insensitive) = closed
  "summary": "What/why/how...",       // default "" — see §7.1
  "next": "next concrete action",
  "doneWhen": "verifiable completion condition",
  "updatedAt": "ISO-8601",
  "worktree": "...", "completion": {...}, "resolutionPrs": [], "prs": [], "links": [], "steps": []
}
```

Decode is lenient on missing fields but **strict on types**: `"prs": "x"` or `"steps": {}` fails decoding of the *entire dashboard* and the queue view errors out. A **duplicate ticket ID** in any dashboard fails the whole load. Unknown vocabulary strings (`status: "weird"`) pass decode and silently sort last.

### 6.2 Task context (`tasks/<TICKET>/context.json`)

`TaskContext` (`schemaVersion: 2`): `ticketID, title, summary, successCriteria, planPath, worktreePath?, repositoryPath?, branch?, baseBranch?, managedWorktree, subtasks[], projectID?, projectName?, updatedAt`.

Each `TaskSubtask`: `id (uuid), title, assignmentDescription, provider, sessionID?, status (queued|working|idle|blocked|completed), progressSummary, workspace?{path, repositoryPath, branch?, baseBranch?, baseCommit?, managed, ...}, tmux?, runtimeMode? (tmux|terminal), initialPrompt?, attention?, resultSummary?, launchConfiguration?{launchID?, routeID? (legacy), model?, effort?, pluginOverrides?}, ...`.

**Closed vocabularies throw on unknown values:** a hand-edited `status: "done"` or `provider: "gpt"` in `context.json` makes the *whole context file fail to load*. Missing fields are repaired with defaults on read — which is exactly why hand-written tasks "sort of work" but lack crucial pieces.

### 6.3 Session registry (`state.json` → `agentSessions[]`)

`TaskAgentSession{id, ticketID, provider, sessionID, tabTitle, taskTitle?, workingDirectory, windowID?, tabID?, paneID?, subtaskID?, tmux?}`. Upserted by (provider, sessionID). Written only by `attach`/`register-event` — **never edit `state.json` by hand** (the app's cached copy will overwrite you).

### 6.4 Task proposal schema (ingestion path)

`Config/task-proposals.schema.json`: `newTasks[]` requires `title, projectID, category, priority, summary, next, doneWhen, sourceKeys[1-20], sourceLinks[1-10]`. ⚠ `updates[].ticketId` is hardcoded to `^ECC-[0-9]{3,}$` even though projects use their own prefixes (FOC-, OTH-, …) — a live schema bug.

---

## 7. Correct workflows (recipes)

### 7.1 Creating a task the right way

The validated creation paths are **the + task creator** in the app, **`fq` / `focus-queue-session placement --prompt <text>`** (creates a task when no open task matches; see §9), and **the ingestion pipeline** (schema-validated proposals). Everything else is a hand-edit of `dashboard.json`.

Every task description/summary must answer **what, why, and how** — 1–2 sentences each, no leading commit hashes, branch names, or internal jargon. A complete task also carries: `projectID`, `priority`, `category`, `summary`, `next`, `doneWhen`, and — once worked — `worktreePath`, `branch`, `plan.md`, and at least one well-formed subtask.

If you must write `dashboard.json` directly (you shouldn't — see §8): take `.<name>.focus-queue.lock`, preserve unknown keys and `queue-order`, write atomically, keep types exact, and never reuse or duplicate an ID across dashboards.

### 7.2 Registering an agent on a task

1. **Immediately at startup:** `focus-queue-session attach "$FOCUS_QUEUE_TASK_ID"` (or the known ticket ID). Repeat after switching tickets. Never run `tabname` or overwrite labels afterward.
2. If no ticket is known: `focus-queue-session placement --prompt "<initial prompt>"` from the intended repo, then follow the capsule; `identify` once IDs exist.
3. Read `$FOCUS_QUEUE_AGENT_CONTEXT` (placement capsule) before editing source. Stop on `blocked-conflict`.
4. The registration record must name: task, provider session UUID, tmux session (managed panes), and worktree + branch (isolated workspaces). The first recorded workspace is immutable; resuming reuses the exact workspace and provider UUID.
5. Heartbeat with `progress`, log with `log`, finish with `complete <TASK> <SUBTASK> "<summary>"`.

---

## 8. Failure analysis — where this structure breaks

These are the concrete mechanisms behind the "tasks written incorrectly", "session recall fails", and "tmux sessions lost" issues.

### 8.1 Task creation bypasses validation

The app validates writes made *through* `JSONDashboardRepository` (revision check, duplicate-ID rejection, type-safe re-encode). But **no CLI command creates a ticket**, so agents and the orchestrator hand-edit `dashboard.json`, which gets only *read-time* validation:

- Missing fields silently default (`title`←id, `priority`←medium, `status`←backlog, `summary`←"") — the task "exists" but is hollow: no what/why/how, no `next`, no `doneWhen`.
- Wrong types kill the entire dashboard load, not just the one ticket.
- `worktreePath` was absent in **19 of 39** audited task contexts (`Docs/DATA_BACKFILL_AUDIT.md`) — and the audit concluded provider/session/path correlation **cannot be reconstructed from data alone** afterward. Data written wrong at creation is permanently unrecoverable.
- The audit tool (`focus_queue_data_audit.py`) already knows the required field set — but nothing *enforces* it at write time.

### 8.2 `state.json` and `config.json` are unsafe external-write targets

`state.json` edits are overwritten by the app's in-memory cache. `config.json` edits are ignored until restart and then silently lost on the next settings save (only unknown keys survive). Any agent "fixing" registration by editing `state.json` is racing the app and will lose.

### 8.3 Session recall is intentionally narrow — and the gaps show

Recall verifies the full saved tmux identity (server PID, creation time, session name, pane ID/PID, TTY) plus matching provider UUID. It **never** scans transcripts, runs `codex resume`/`claude --resume`, or starts a replacement. So recall fails whenever:

- the tmux server rebooted (resurrect restores shells, but they never get the live-agent marker back),
- pane IDs were reused or the terminal transport died mid-launch,
- the provider UUID was never captured (short-lived calls that closed before discovery),
- the record was written by hand and is missing `tmux`, `paneID`, or `sessionID` fields.

`runtime locate` is the honest probe here — but there is no `session resume` command that rebinds a *known-good* provider UUID to a *new* pane/worktree. That gap is why recalling sessions "occasionally" fails and no one can fix it from the CLI.

### 8.4 tmux lifecycle traps

- Reboot/server death ends all agents; restored shells are not agents.
- Duplicate-resume guards compare full server/pane/process/TTY references; an unconfirmed launch blocks retries forever until the startup sweep (30 s) completes-or-fails it.
- `/tmp` vs `/private/tmp` canonicalization and cross-prefix task ownership both broke routing historically — fixed, but they show how identity comparisons are brittle at every seam.

### 8.5 Validation inconsistencies in the CLI itself

- `task status` accepts any string (priority is validated; status is not).
- `agents clear --all` destroys all registration records with no confirmation and leaves processes running untracked.
- Kimi cannot `attach` from env (no UUID env var) though the usage text implies it can.
- The proposal schema's `ticketId` is hardcoded to `ECC-` while projects have their own prefixes.
- ~~Repository identity embedded the macOS device number, breaking agent creation and session recall after every reboot/remount~~ — **fixed**: identity comparison is device-tolerant (path + inode decide), and the managed-root marker self-heals. (2026-10-09)

### 8.6 The orchestrator's authority problem

Per `Docs/ACTION_BOUNDARIES.md`, the queue-chat orchestrator now has real mutation capability, but **ordinary questions share the write-capable path** — there is no typed request authority (`answer` vs `proposeTaskEdit` vs `applyTaskEdit`). Combined with §8.1 (no validated `task create`), the orchestrator can currently only mutate fields by hand-editing JSON with partial validation. That is precisely the configuration that produces malformed tasks.

---

## 9. Missing commands — suggested additions

Ordered by impact. Each is designed to close a failure mode from §8.

**Tier 1 — close the task-creation hole**

1. **`task create --project <ID> --title <T> --summary <S> --next <N> --done-when <D> [--priority p] [--category c] [--description-file path]`**
   The single most important missing command. Allocates the next `<PREFIX>-<n>` ID under the dashboard lock, validates the full field set through `JSONDashboardRepository`, **requires** `summary` (what/why/how), `next`, and `doneWhen` (refuse hollow tasks), creates `tasks/<ID>/` with a scaffolded `context.json` + `plan.md`, and emits the ticket JSON. This makes the correct path the easy path.
2. **`task show <TASK-ID> [--json]`** — read one ticket + its context completeness. Today agents must parse two files to know a task's state.
3. **`task set <TASK-ID> <field> <value>` / `task edit`** — generic field mutation with per-field validation (enums for status/priority/category, ISO dates, URL shapes for links), so the orchestrator can "change fields" without hand-editing JSON. Fix `task status` to validate against the known vocabulary (or document the app's free-form statuses as an enum).
4. **`task validate <TASK-ID> [--repair]`** — check a ticket + context against the same field list `focus_queue_data_audit.py` uses (`title, summary, successCriteria, worktreePath, planPath, subtasks…`); `--repair` fills only safe defaults and reports what it could not infer. Never invent content — report, don't fabricate.

**Tier 2 — session recall and agent inventory**

5. **`sessions list [--task <ID>] [--provider p]`** — dump `agentSessions[]` + subtask correlation. Currently there is no read path for the registry.
6. **`session resume <TASK-ID> <SUBTASK-ID> [--new-pane]`** — the recall command: verify provider UUID + workspace via `runtime locate`, rebind to a fresh tmux pane, update the session record, emit the resume command it used. Encodes the REMOTE_SESSION_RECALL rules in one place instead of relying on every agent to remember them.
7. **`doctor [--task <ID>]`** — whole-system health: orphaned sessions (recorded but `runtime locate` = stopped), subtasks with sessions but no workspace, tasks with agents but no `worktreePath`. Read-only; exit code = number of problem classes found.
8. **`attach` should verify the ticket exists** on some dashboard and warn (or refuse without `--force`) when it doesn't.

**Tier 3 — robustness & guardrails**

9. **Audit every hand-rolled parser** for unknown flags — silent drops turn typos into misprovisioned agents.
10. **`agents clear --all` needs `--yes` + a pre-flight count**, and should optionally terminate or detach the running processes it untracks.
11. **Kimi session identity**: add a `KIMI_SESSION_ID` env binding (or document hooks as the only path and fix the `attach` usage text).
12. **Generalize the proposal schema `ticketId` pattern** to `^[A-Z][A-Z0-9]{1,4}-[0-9]{3,}$` (matching `ProjectCatalog`'s prefix rule).
13. **`config reload`** command that posts the catalog-change notification (or a new config-change notification) so external config edits become safe-ish.
14. **`--label` should either work or be removed** from the harness CLIs; Kimi's `--effort`/`--disable-tools` should error instead of silently no-op'ing.

---

## 10. Hardening recommendations

**Make the CLI the only write path, then make the CLI strict.**

1. **Schema-enforce at write, not just read.** Every mutation that can produce a task/subtask/session record should go through the same validated repository path the app uses. The current asymmetry (strict app writes, lenient hand writes, repair-on-read) guarantees drift.
2. **Refuse hollow tasks.** `summary` (what/why/how), `next`, and `doneWhen` should be required at creation. A task without them is debt that the backfill audit proved cannot be repaid from data alone.
3. **Receipts for everything.** Placement capsules already key each launch by UUID. Extend the same pattern to `task create`, `attach`, and `session resume`: idempotent, UUID-keyed, replayable. Idempotency is what makes orchestrator retries safe.
4. **Correlation at creation, not reconstruction.** Every subtask record should be born with `sessionID`, `tmux` reference, and `workspace` (path+branch+baseCommit) filled by the launch path — the launch already knows all three. Registration completeness is already *checked* (`registrationIssue` on handoffs); it should be *blocking* for managed launches.
5. **Typed authority for the orchestrator.** Implement the `ACTION_BOUNDARIES.md` proposal: read-only answers must not share the write path. Mutations should be proposed, validated, then applied — with the proposal itself schema-checked.
6. **One lock discipline, enforced.** Provide a tiny `focus-queue-session exec-lock <path> -- cmd...` (or document the lock paths as part of the contract) so any external writer can't bypass `flock` accidentally.
7. **Ship `doctor` in CI of the data**: run the audit + doctor on a schedule; a queue that knows it's degraded beats one that silently is.

---

## 11. Quick reference card

```
# Registration (mandatory, first thing)
focus-queue-session attach <TASK-ID>
focus-queue-session identify <TASK> <SUBTASK> "<title>" "<what/why/how>"

# Lifecycle (inside a managed pane the IDs may be omitted: progress working "summary")
focus-queue-session progress  <TASK> <SUBTASK> working "summary"
focus-queue-session log       <TASK> <AGENT>   "entry"
focus-queue-session attention <TASK> <AGENT>   question "summary"
focus-queue-session complete  <TASK> <SUBTASK> "result summary"

# Placement (no ticket yet)
focus-queue-session placement --prompt "<objective>" --cwd "$PWD"

# Task fields (validated)
focus-queue-session task rename   <TASK-ID> <title...>
focus-queue-session task priority <TASK-ID> critical|high|medium|low
focus-queue-session task status   <TASK-ID> <status>     # ⚠ unvalidated

# Development process (projects that enable it)
focus-queue-session development <PROJECT-ID> show|sync
focus-queue-session development <PROJECT-ID> link <TASK-ID> <step-id|none> [module]

# Diagnostics
focus-queue-session context <TASK> | plan <TASK> | diagnose <TASK>
focus-queue-session runtime locate <provider> <session-uuid>
focus-queue-session reconcile <TASK>

# Never do
#  ✗ hand-edit state.json            (app cache overwrites you)
#  ✗ hand-edit config.json           (ignored until restart, then lost)
#  ✗ write dashboards without the lock and full schema
#  ✗ create tasks without summary/next/doneWhen
```

## 9. `fq` dispatcher and task placement

**`fq <codex|claude> [provider args...]`** (`Scripts/focus_queue_fq.py`, installed as `~/.local/bin/fq` by both entry installers) places the launch in a task, then execs the provider's existing entry script with all provider arguments unchanged. A resolved or created task is forced through `FOCUS_QUEUE_TASK_ID` (the same channel managed launches use). Plain `codex`/`claude` shell functions never go through `fq`. The dispatcher reads the installed `shell/<provider>.zsh` to reuse the configured usage wrapper and default flags. Either shell-entry installer installs `fq` with both providers' entry scripts beside it; once `fq` exists, every app install (`Scripts/install.sh`) refreshes `focus_queue_fq.py`, `focus_queue_placement.py`, and `focus_queue_claude_entry.py`, and stops without writing if any of them has local edits. Settings → Task placement edits the placement keys below. It prints one stderr line per decision:

- `[fq] placing with claude/haiku against 73 open tasks…` before a model call (about 2–4 s).
- `[fq] placed → <TASK-ID> (<backend>: <rationale>[, confidence 0.90])` for a ticket in the prompt or a confident model match.
- `[fq] created → <TASK-ID> “<title>” (claude/haiku: model-new, …)` for new work. `fq` creates the task through `focus-queue-session placement --launch <new UUID> --cwd <cwd> --prompt <prompt>` (with this launch's and any parent agent's identity variables removed), then applies the model's title with `task rename`. A rename failure keeps the task under its prompt-derived title.
- `[fq] unplaced (<rationale>) — launching untracked-by-task` when nothing resolved; the entry script's own intake then decides, as in phase 1.

**`python3 Scripts/focus_queue_placement.py classify --prompt "..." --cwd "..." [--task ECC-123] [--provider claude|codex|kimi] [--json]`**. Without `--provider` it is heuristic only. Resolution order:

1. Explicit `--task` → `task`, confidence 1.0, rationale `explicit`. No model call.
2. `<taskPrefix>-<digits>` (case-insensitive, prefixes from the config's projects) in the prompt that exists in app state (any project's `dashboardPath` tickets or `tasks/<ID>/`) → `task`, confidence 0.95, rationale `prompt-ticket`. No model call.
3. With a provider, a prompt, and the model backend enabled: one model call. The candidates are the open tasks (status not `resolved`/`cancelled`/`done`/`completed`/`archived`) that `placement` would accept for this directory: the launch project's tasks first, then projects without a repository, newest first, at most 120. The model returns `{taskID|null, confidence, title, reason}`. A listed task at or above `placementConfidenceThreshold` → `task`, rationale `model-match`. Otherwise → `new-task` with the model's `title`, the launch project (or `other`), rationale `model-new`, and `nearestTaskID` when a weak match existed. An unlisted task, a missing title, malformed output, a non-zero exit, or a timeout is a model error: classification continues with step 4 and reports `modelError`.
4. cwd inside a configured `repositoryPath` (or a git top-level matching one) → `project-inbox`, confidence 0.6, rationale `cwd-project`.
5. cwd in any other git repo → `inbox`, confidence 0.2, rationale `unmapped-repo`.
6. Otherwise → `inbox`, confidence 0.1, rationale `no-signal`.

Output JSON: `{status, taskID?, projectID?, confidence, rationale, backend: "heuristic"|"model", latencyMs, model?, title?, reason?, nearestTaskID?, modelError?}`. `classify` always exits 0 on success; usage errors exit 2 on stderr. Config is read from `<support>/config.json` (`focusQueueProjects` or the repository-catalog `projects` shape), overridable with `FOCUS_QUEUE_PLACEMENT_CONFIG` and `FOCUS_QUEUE_SUPPORT_DIR`.

**Model calls use subscription CLIs, never API keys.** The provider binary comes from the launch's `PATH` (override: `FOCUS_QUEUE_PLACEMENT_<PROVIDER>_EXECUTABLE`) and runs in a private temporary directory, in its own process group, with `FOCUS_QUEUE_*` and provider session variables removed so it cannot register as an agent:

| Provider | Invocation | Isolation |
|---|---|---|
| Claude | `claude -p --model <m> --effort <e> --tools "" --strict-mcp-config --setting-sources "" --no-session-persistence --output-format json --json-schema <schema>`; prompt on stdin | No tools, MCP, settings, hooks, or transcript |
| Codex | `codex exec -m <m> -c model_reasoning_effort=<e> --sandbox read-only --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check --output-schema <file> -o <file> -`; prompt on stdin | No plugins, hooks, rules, or session file |
| Kimi | `kimi -m <m> -p <prompt>`; the last JSON object in the reply is used | No effort flag; Kimi keeps a session record |

Measured on this machine (2026-10-19), 51 labeled launches (31 from real history, 20 synthetic) against about 72 open tasks:

| Backend | Correct | Joined an unrelated task | Latency p50 / p95 |
|---|---|---|---|
| Heuristic (phase 1) | 34/51 — never matches an open task without a ticket ID | 0 | 2 ms / 15 ms |
| Claude `haiku`, effort low, threshold 0.85 | 41/51 | 0 (all 6 counted false matches joined a duplicate of the same work already in the queue) | 3.2 s / 5.4 s |
| Codex `gpt-6-luna`, effort low | 33/51 | 0 wrong-task; 16 false matches | 3.6 s / 47 s (often over the 20 s budget) |

Kimi highspeed placed a single live follow-up correctly in 6.2 s; it was not run on the full set because every `kimi -p` call leaves a session record. Raising the threshold from 0.6 to 0.85 cut false matches from 13 to 2–6 per run at the cost of 2–3 follow-ups scored 0.80–0.82 becoming new tasks.

**+ task creator** — the app runs the same `classify --provider <p> --json` from its bundle (`Contents/Resources/shell/focus_queue_placement.py`, falling back to the installed `shell/` copy) with `FOCUS_QUEUE_SUPPORT_DIR` and each provider's resolved executable, because a GUI app inherits launchd's short `PATH`. The model reply also carries `summary` (card description) and `priority` (`critical|high|medium|low`); an invalid value is dropped, never fatal. A `status: task` reply is offered as "add an agent to the matching task" before any ticket is written. With no user priority and no model priority, the creator asks for one instead of defaulting.

**Placement ledger** — every `classify` appends one row to `<support>/placement-ledger.sqlite` (override: `FOCUS_QUEUE_PLACEMENT_LEDGER`), table `placements`: `id INTEGER PK`, `timestamp TEXT` (ISO8601 UTC), `backend`, `status`, `task_id`, `project_id`, `confidence REAL`, `rationale`, `prompt_excerpt` (first 200 chars), `cwd`, `latency_ms REAL`, `model` (`provider/model`), `title`, `error` (the model error, if any). Phase-1 ledgers gain the last three columns in place. Ledger failures warn on stderr and never block classification.

**Config keys** (`AppConfiguration` round-trips all of them; both `Config/ecc.config.json` and `Config/config.example.json` list the defaults):

| Key | Default | Meaning |
|---|---|---|
| `placementModelEnabled` | `true` | `false` restores phase-1 heuristics for `fq` |
| `placementProvider` | launched provider | Run every placement call on `claude`, `codex`, or `kimi` |
| `placementModels` | `{"claude": "haiku", "codex": "gpt-6-luna", "kimi": "kimi-code/kimi-for-coding-highspeed"}` | Per-provider model; a missing provider uses its default |
| `placementEfforts` | `{"claude": "low", "codex": "low"}` | Per-provider effort (`low`…`max`); Kimi ignores it |
| `placementConfidenceThreshold` | `0.85` | Minimum confidence to join an existing task; lower confidence creates a new task |
| `placementTimeoutSeconds` | `20` | Model call budget (1–120) before falling back |
| `agentsPerWindow` | `4` | Task-window pane capacity (`TmuxPaneLayout.maximumPanes`, clamped to 1–12) |

**Evaluation** — `python3 Scripts/focus_queue_placement_eval.py build --support <support dir> --out cases.jsonl` labels real launch prompts by the task they ended in (a task's first prompt is a new-work case with that task hidden; later prompts are existing-task cases). `run --provider <p> --cases cases.jsonl [--cases more.jsonl]` replays them against the real dashboards and prints accuracy by case kind, error types (`false-match`, `missed-match`, `wrong-task`, `fallback`), and latency next to the heuristic baseline. Cases contain real prompts; keep them out of the repository.

*Generated 2026-10-09 from repository sources. Command grammar is authoritative at `Sources/FocusQueueSession/main.swift:16`; when this document and the usage string disagree, the usage string wins.*
