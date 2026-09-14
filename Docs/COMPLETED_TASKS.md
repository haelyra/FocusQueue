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
