# Focus Queue agent contract

Task identity, writer isolation, a brief plan, and an append-only log form the core agent handoff. Global Codex guidance supplements these controls; it cannot enforce filesystem permissions for arbitrary external agents.

## New Agent and resume

New Agent automatically creates an owned branch/worktree from the selected checkout's committed HEAD. Local edits remain in the source and are excluded from the new workspace. The sheet shows this explicitly; there is no worktree toggle. The model retains explicit existing-workspace and strict-clean APIs for compatibility. Resuming a saved agent reuses its workspace and exact provider UUID.

Resume rechecks transient provider ownership up to four times while a process starts or exits. An unresolved final scan still prevents a duplicate process.

Every new app launch includes a compact task ID, agent ID, workspace, plan/log pointers, and reporting instructions. Detailed task initialization remains optional. An empty prompt asks the agent to prepare context and wait, rather than starting the whole task. Low-level launches that explicitly suppress all prompts and saved-conversation resumes remain prompt-free.

## Documents and reports

- `plan.md`: goal, scope, success criteria, implementation outline, current focus, next step, and links. Read on association and before edits. Exclude decision history and verbose evidence.
- `agent-log.md`: timestamped decisions, configuration, progress detail, research/evidence links, and handoffs. Read relevant entries on demand. Append with `focus-queue-session log <TASK-ID> <AGENT-ID> "entry"`.
- Supporting artifacts: store beside task context and link from the plan or log. Context lives outside disposable worktrees.
- Structured state: use helper commands for progress, result, attention, and verified completion. Preserve user queue order, cleared subtasks, and other agents' identities.

Preparing task context creates missing documents without replacing authored files. Log appends use the same cross-process task lock as state changes. They never re-save the central plan or overwrite task state. Symbolic-link log destinations are rejected. Existing historical plans are preserved until a deliberate archival migration.

## Management boundaries

Agents explain their assignment and configuration briefly, then report at meaningful milestones. A lightweight orchestrator maintains authorized context and behavior, reconciles records, and answers questions. Coding, agent deployment, merging, remote delivery, priority changes, and destructive cleanup require their own authority.

Response-ready, assignment-complete, merged, and cleaned are separate states. Existing guarded cleanup remains conservative; this change does not install a merge watcher or enable broad document deletion. Automatic external-agent worktree enforcement, merge-triggered reconciliation, and role-aware read-only launches remain proposed follow-up work.

## Verification

Run `swift test`, Python regression tests, and the opt-in headless `ECC_FOCUS_QUEUE_LIVE_AGENT_TESTS=1 swift test --filter liveManagedProviderSanity`. The live test exercises actual Codex launch through the model, automatic isolation from a dirty source, compact/detailed prompts, exact session identity, detach/reopen, and stopped-session resume. Stop the production app during live fixtures so its external-session observer cannot import fixture agents. UI automation still requires its separate explicit opt-in.
