# Focus Queue agent contract

Task identity, writer isolation, a brief plan, and an append-only log form the core agent handoff. Global Codex guidance supplements these controls; it cannot enforce filesystem permissions for arbitrary external agents.

## New Agent and resume

New Agent automatically creates an owned branch/worktree from the selected checkout's committed HEAD. Managed paths live beside the canonical repository under `<repository>-worktrees/<task>/agents/<agent-id>`; Application Support stores task metadata and evidence, never a coding checkout. Local edits remain in the source and are excluded from the new workspace. The sheet shows this explicitly; there is no worktree toggle. The model retains explicit existing-workspace and strict-clean APIs for compatibility. Resuming a saved agent reuses its exact assigned workspace and provider UUID.

Resume rechecks transient provider ownership up to four times while a process starts or exits. An unresolved final scan still prevents a duplicate process.

Every new app launch includes a compact task ID, agent ID, workspace, plan/log pointers, and reporting instructions. Detailed task initialization remains optional. An empty prompt asks the agent to prepare context and wait, rather than starting the whole task. Low-level launches that explicitly suppress all prompts and saved-conversation resumes remain prompt-free.

Task-associated agents share one `fq-task-<task-id>` tmux session with one exact pane per agent. Shell launches persist their provisional queue row before starting, save the exact pane reference afterward, and notify the app at both boundaries. The managed usage bar follows the active pane and remains session-owned when another agent exits. Unassigned launches stay in isolated `fq-codex-*` sessions until placement is unambiguous.

## Documents and reports

- `plan.md`: goal, scope, success criteria, implementation outline, current focus, next step, and links. Read on association and before edits. Exclude decision history and verbose evidence.
- `agent-log.md`: timestamped decisions, configuration, progress detail, research/evidence links, and handoffs. Read relevant entries on demand. Append with `focus-queue-session log <TASK-ID> <AGENT-ID> "entry"`.
- Supporting artifacts: store beside task context and link from the plan or log. Context lives outside disposable worktrees.
- Structured state: use helper commands for progress, result, attention, and verified completion. Preserve user queue order, cleared subtasks, and other agents' identities.

Preparing task context creates missing documents and outlines empty plans without replacing authored content. Log appends use the same cross-process task lock as state changes. They never re-save the central plan or overwrite task state. Symbolic-link log destinations are rejected. Existing historical plans are preserved until a deliberate archival migration.

The installable, coworker-shareable Codex payload is [CODEX_GLOBAL_INSTRUCTIONS.md](../Config/CODEX_GLOBAL_INSTRUCTIONS.md). App installation replaces only its marked global block and preserves personal instructions. The [entry guide](CODEX_TMUX_ENTRY.md) covers fresh shell setup, role selection, missing-data behavior, enforcement boundaries and recovery.

## Management boundaries

Agents explain their assignment and configuration briefly, then report at meaningful milestones. A lightweight orchestrator maintains authorized context and behavior, reconciles records, and answers questions. Coding, agent deployment, merging, remote delivery, priority changes, and destructive cleanup require their own authority.

Response-ready, assignment-complete, merged, and cleaned are separate states. The deterministic reconciler reacts to semantic state changes and runs a slow recovery sweep, using a per-task lease and changed-only audit receipts. It repairs missing context documents, explains incomplete fields, and rechecks eligible completed workspaces after merge. Existing task closure and agent removal also check runtime inactivity under the same lease. Cleanup uses repository identity markers, exact inode checks and a no-follow rename. After a final cleanliness check, it retains the checkout at a recoverable sibling and moves the exact Git administration directory out of the active registry. It never recursively deletes checkout files. Missing ownership, uncertain process discovery, active agents, locked worktrees, submodule metadata, dirty or ignored files, changed identities and unmerged commits retain the registered worktree. Shell-created external worktrees remain retained for review; broad document deletion stays disabled.

The configured entry persists launch intent before starting Codex. Task/session/label metadata can remain provisional; unknown identities never authorize resume or cleanup. New interactive coding starts and forks in committed repositories get a separate worktree; read-only research/orchestration and explicit existing-workspace modes retain their checkout and record the policy. Noninteractive calls are tracked in their existing checkout. A native-executable bypass remains discoverable on a best-effort basis rather than an OS-wide launch gate.

## Verification

Run `swift test`, Python regression tests, and the opt-in headless `ECC_FOCUS_QUEUE_LIVE_AGENT_TESTS=1 swift test --filter liveManagedProviderSanity`. The live test exercises actual Codex launch through the model, automatic isolation from a dirty source, compact/detailed prompts, exact session identity, detach/reopen, and stopped-session resume. Stop the production app during live fixtures so its external-session observer cannot import fixture agents. UI automation still requires its separate explicit opt-in.
