# Focus Queue agent contract

Task identity, writer isolation, a brief plan, and an append-only log form the core agent handoff. Global Codex guidance supplements these controls; it cannot enforce filesystem permissions for arbitrary external agents.

## New Agent and resume

New Agent and the installed `codex` shell entry automatically create an owned branch/worktree from the selected checkout's committed HEAD. New managed paths live under the canonical repository at `<repository>/.worktrees/<task>/agents/<agent-id>` when the task is known, with provisional isolated paths permitted during placement. Recorded legacy sibling worktrees remain resumable at their immutable paths. Application Support stores task metadata and evidence, never a coding checkout. Local edits remain in the source and are excluded from the new workspace. There is no worktree toggle. Resuming a saved agent reuses its exact assigned workspace and provider UUID.

The first recorded workspace path is immutable for that agent. Same-path updates
may enrich Git metadata, but a different checkout requires a new agent assignment.
This prevents a running writer from following another task into a newly created
worktree.

Automatic agent routing is an opt-in setup preference. When enabled, a fresh, unassigned interactive Codex starts as a short-lived router in the current terminal. `focus-queue-session route inspect` saves the complete initial prompt and returns a compact repository-matched packet with project, existing task choices, and canonical context paths. The router interprets that packet and calls `focus-queue-session route start` with an explicit existing task or new project task, subtask title and description, provider, model, effort, repository, and workspace policy. Assigned launches and resumes bypass routing, which prevents successor recursion.

The queue's Router agent composer is an explicit routing request and does not depend on the automatic shell-interception preference. It atomically reserves one active router, then starts a fresh unassigned Codex headlessly in the selected project's repository. A prompt-bound, one-use capability authorizes exactly one inspection and start from that tmux identity; composer routes always use an isolated workspace. Only the registered successor opens a terminal. The intermediate router remains detached until the startup receipt records the completed handoff, then closes. An unresolved route stays visible across app restarts through its exact saved runtime, route, or startup receipt, and the app never retries it automatically.

`route start` claims its route UUID before changing the dashboard or starting a provider, so replay cannot create a second process. It creates or associates the task, provisions the isolated worktree, writes the task and subtask records, creates the placement capsule, starts the provider in the task-owned tmux pane, opens a fresh WezTerm or macOS Terminal client, discovers the real provider conversation UUID, and writes one concise JSON startup receipt. A successful result authorizes router exit only after registration. macOS Terminal uses tmux because it has no direct pane API; closing the router's user-opened Terminal window remains a user action because Focus Queue does not automate Terminal UI.

Resume rechecks transient provider ownership up to four times while a process starts or exits. An unresolved final scan still prevents a duplicate process.

The app's one-click New Agent launch passes no positional prompt to the provider, so Codex opens at an empty input. Task and agent identity remain in the launch environment. On the first substantive prompt, the provider event hook deterministically replaces a generated `Agent N` label with a short title and one-sentence description; the global agent contract provides the `identify` command as a hook-independent fallback. A user-edited or already descriptive identity is never overwritten. Detailed task initialization remains optional for configured launches, and saved-conversation resumes remain prompt-free.

Task-associated agents share one `fq-task-<task-id>` tmux session with one exact pane per agent and at most four active agents in each native tmux window tab. Additional agents create another window inside the same session. Shell launches persist a launch receipt, resolve placement, persist a provisional queue row, save the exact pane reference afterward, and notify the app at each boundary. Each pane's top border leads with its agent name and carries its own managed usage bar, so neighboring agents show independent quota and context readings, and one agent exiting never removes the bar for its neighbors. Explicit model and effort choices remain on the agent record and are reused for exact resume. A launch without a task objective stays in its project's inbox and an isolated `fq-codex-*` session until placement is unambiguous.

## Placement capsule

The placement resolver is local deterministic code in `focus-queue-session`, not an orchestrator or an LLM. It evaluates saved session ownership, explicit task identity, project task prefix, and Git repository identity in that order. Normal launches call it automatically. An agent can recover missing placement with `focus-queue-session placement --prompt "<objective>"` from its intended repository.

Each launch receives `FOCUS_QUEUE_AGENT_CONTEXT`, pointing to a private JSON capsule at `~/Library/Application Support/ECC Focus Queue/tracking/placements/<launch-uuid>.json`. The capsule lives outside Git because it must exist before a task is known, survive branch/worktree cleanup, and be shared by the launcher, app, hooks, and agent without polluting a repository. Writes are private and atomic. The capsule contains only routing context: project, task, agent, provider session when known, workspace, branch, tmux identity, and plan/log pointers.

Projects own unique 2 to 5 character task prefixes. Focus Queue uses `FOC-###`; the reserved `Other` project uses `OTH-###`. Repository matching selects a configured project. If no project matches, task creation uses Other instead of leaving project ownership empty. Conflicting task and repository evidence produces `blocked-conflict` and prevents the launch from starting source work. Normal placement does not call the orchestrator; reconciliation can correct exceptions later.

## Documents and reports

- Project `plan.md`: concise project-only practices, commands, and repeated mistake-prevention rules. Read from the capsule's `projectPlanPath`.
- Task `plan.md`: goal, scope, success criteria, implementation outline, current focus, next step, and links. Read on association and before edits. Exclude decision history and verbose evidence.
- `agent-log.md`: timestamped decisions, configuration, progress detail, research/evidence links, and handoffs. Read relevant entries on demand. Append with `focus-queue-session log <TASK-ID> <AGENT-ID> "entry"`.
- Supporting artifacts: store beside task context and link from the plan or log. Context lives outside disposable worktrees.
- Structured state: use helper commands for progress, result, attention, and verified completion. Preserve user queue order, cleared subtasks, and other agents' identities.

Preparing task context creates missing documents and outlines empty plans without replacing authored content. Log appends use the same cross-process task lock as state changes. They never re-save the central plan or overwrite task state. Symbolic-link log destinations are rejected. Existing historical plans are preserved until a deliberate archival migration.

The installable, coworker-shareable Codex payload is [CODEX_GLOBAL_INSTRUCTIONS.md](../Config/CODEX_GLOBAL_INSTRUCTIONS.md). App installation replaces only its marked global block and preserves personal instructions. The [entry guide](CODEX_TMUX_ENTRY.md) covers fresh shell setup, role selection, missing-data behavior, enforcement boundaries and recovery. The Claude equivalents are [CLAUDE_GLOBAL_INSTRUCTIONS.md](../Config/CLAUDE_GLOBAL_INSTRUCTIONS.md), merged into `~/.claude/CLAUDE.md`, and the [Claude entry guide](CLAUDE_TMUX_ENTRY.md), whose hook payload is the canonical session-identity path because Claude Code does not export `CLAUDE_SESSION_ID` to the shell.

## Management boundaries

Agents explain their assignment and configuration briefly, then report at meaningful milestones. A lightweight orchestrator maintains authorized context and behavior, reconciles records, and answers questions. Coding, agent deployment, merging, remote delivery, priority changes, and destructive cleanup require their own authority.

Response-ready, assignment-complete, merged, and cleaned are separate states. The deterministic reconciler reacts to semantic state changes and runs a slow recovery sweep, using a per-task lease and changed-only audit receipts. It repairs missing context documents, explains incomplete fields, and rechecks eligible completed workspaces after merge. Existing task closure and agent removal also check runtime inactivity under the same lease. Cleanup uses repository identity markers, exact inode checks and a no-follow rename. After a final cleanliness check, it retains the checkout at a recoverable sibling and moves the exact Git administration directory out of the active registry. It never recursively deletes checkout files. Missing ownership, uncertain process discovery, active agents, locked worktrees, submodule metadata, dirty or ignored files, changed identities and unmerged commits retain the registered worktree. Shell-created external worktrees remain retained for review; broad document deletion stays disabled.

Implemented, reviewed, merged, installed, and released are also separate states.
Feature agents commit in their owned branches and hand off for review. They never
replace the shared application. The shared installer accepts only a signed,
clean build from the current remote integration revision and refuses older,
divergent, dirty, feature-branch, or mismatched-repository artifacts before it
stops the running app or mutates installation files.

Local ad-hoc signing protects bundle integrity and prevents accidental sibling
branch installs. It does not authenticate a publisher against a malicious
same-user process. Public release artifacts require protected CI, Developer ID
signing, and notarization.

The configured entry persists launch intent before starting Codex. Task/session/label metadata can remain provisional; unknown identities never authorize resume or cleanup. New interactive coding starts and forks in committed repositories get a separate worktree; read-only research/orchestration and explicit existing-workspace modes retain their checkout and record the policy. Noninteractive calls are tracked in their existing checkout. A native-executable bypass remains discoverable on a best-effort basis rather than an OS-wide launch gate.

Automatic startup receipts live at `logs/agent-startups/<TASK-ID>/<agent-id>.json`. They record the prompt digest and byte count rather than duplicating prompt text, plus source-router identity, project/task/subtask metadata, provider/version/model/effort, workspace and Git identity, tmux executable/server/session/pane/TTY and attach command, terminal selection, placement capsule, project plan, task plan, task context, task log, and sanitized launch arguments. Registration adds the real provider conversation UUID and exact resume command. The full initial prompt remains in the route intent and subtask context.

## Stale agent cleanup

Manual ("Clean up stale agents…" in the Today's focus menu) and opt-in automatic (`autoArchiveStaleAgents`, at most one sweep per 24 hours) cleanup only ever archive agents and close their runtimes. Nothing is deleted: archived agents stay recallable under Archived agents with provider resume, workspace, and conversation intact. An agent is a cleanup candidate only when all five criteria hold:

1. It is visible (not already archived).
2. No live process owns it, proven through the same maintenance inspection used for worktree cleanup; uncertain ownership retains the agent.
3. It is either interrupted, or idle with its output already seen (no unread completion).
4. Its last activity (heartbeat or result, falling back to the earliest recorded timestamp) is older than 5 days.
5. It is not queued or working, has no unread result, and the user has not retained it by opening the completed runtime.

## Verification

Run `swift test`, Python regression tests, and the opt-in headless `ECC_FOCUS_QUEUE_LIVE_AGENT_TESTS=1 swift test --filter liveManagedProviderSanity`. The live test exercises actual Codex launch through the model, automatic isolation from a dirty source, compact/detailed prompts, exact session identity, detach/reopen, and stopped-session resume. Stop the production app during live fixtures so its external-session observer cannot import fixture agents. UI automation still requires its separate explicit opt-in.
