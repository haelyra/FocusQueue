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

## Proposed canonical fields

Future dashboard producers should retain completed tickets and add:

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

## Archive and pagination direction

Keep recent completed tasks in the dashboard response. When volume becomes
large, expose an archive ordered by `(completedAt, id)` with cursor pagination.
The app can then replace its current in-memory paging with source-backed page
loads without changing the Completed tab design. Ticket IDs must remain stable
across active, completed, archived, and reopened states.

Local state should continue to hold only UI preferences and review artifacts.
Completion authority and historical task data belong to the canonical dashboard
or its archive.
