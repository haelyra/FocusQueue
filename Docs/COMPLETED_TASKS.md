# Completed task handling

## Current behavior

The dashboard remains the canonical source. The queue treats `resolved` and
`cancelled` tickets as completed, shows tasks completed on the current local day
in the Completed tab, and pages older completed tickets into the same tab on
demand.

Until the dashboard emits a dedicated completion timestamp, the app uses
`updatedAt` as the best available completion date. If `completedAt` is present,
it takes precedence. The app does not copy completed tickets into its local
state or mutate their source records.

## Cleanup after completion

Completion is final. When a task becomes `resolved` or `cancelled` (in the app
or through `focus-queue-session task status`), `TaskCompletionCleanup` runs:

1. Kills the task's tmux sessions (`fq-task-<id>` and its agents' sessions),
   even mid-turn. Provider transcripts survive for later resume.
2. Deletes regenerated build output (`.build`, `node_modules`, …), archives
   uncommitted work as a snapshot commit and unmerged commits under
   `refs/focus-queue/archive/<branch>`, then moves each worktree to
   `<repo>/.worktrees/.trash/` with a JSON manifest.
3. Deletes the task's local branches. A remote branch of the same name is
   deleted only when its work is already in the base branch (ancestor,
   patch-equivalent, or squash-merged).
4. Moves `archive/` and `maintenance-history/` to `<support>/trash/`. The plan,
   agent log, task data, and `context.json` stay for the Completed tab.

Staged items are purged 7 days later. Reopening an agent recreates its branch
from the archive ref or the base branch. The app only cleans tasks completed in
the last 24 hours; older completions wait for the reviewed
`focus-queue-session cleanup --completed --dry-run`, then the same command
without `--dry-run`. A task whose cleanup needs attention stays in the
Completed tab with the message and a retry link.

## Supported canonical completion fields

Dashboard producers can retain completed tickets and include:

```json
{
  "status": "resolved",
  "completedAt": "2026-08-30T18:42:00Z",
  "completion": {
    "outcome": "Short human-readable result",
    "reason": "resolved",
    "resolutionPrs": [1234],
    "evidence": ["path-or-url"],
    "completedBy": "user-or-agent-id"
  }
}
```

`cancelled` tasks should use the same timestamp and completion object, with a
clear cancellation reason. Reopened tasks should clear `completedAt` and append
the prior completion event to a durable history rather than overwriting it.

The Completed tab keeps the source-backed task details expandable, including
steps, PRs, links, and any supplied completion facts. It does not infer a reason,
outcome, evidence, or PR relationship when the dashboard omits one.

## Archive and pagination direction

Keep recent completed tasks in the dashboard response. When volume becomes
large, expose an archive ordered by `(completedAt, id)` with cursor pagination.
The app can then replace its current in-memory paging with source-backed page
loads without changing the Completed tab design. Ticket IDs must remain stable
across active, completed, archived, and reopened states.

Local state should continue to hold only UI preferences and review artifacts.
Completion authority and historical task data belong to the canonical dashboard
or its archive.
