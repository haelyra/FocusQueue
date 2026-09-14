# ECC Focus Queue module map

Start with the module matching the task, then follow its concrete source entry points. The cards contain recorded source checksums; run the explicit architecture index command to compare those baselines with the current checkout. Summary semantics remain unverified even when source checksums match.

| Module | Start here when changing |
| --- | --- |
| [Managed agent sessions](recall.md) | tmux identity, terminal clients, provider startup, or exact reattachment. |
| [Persistence](persistence.md) | Operational state, durable identities, document revisions, or conversation retention. |
| [Task context](task-context.md) | Central plans, subtask progress, agent registration, or worktree references. |
| [User interface](ui.md) | Inspectors, notifications, document tabs, or actual window geometry. |

The primary path is UI action → observable model → core operation → local persistence or verified terminal action → presented result. Central plans retain task decisions. The durable library retains longer-lived identities and revisions. tmux owns the live process; a terminal is a replaceable client view.

See the [card format and generation workflow](../ARCHITECTURE_CONTEXT.md) for budgets, exclusions, and baseline review rules. This index and the four module cards are authored documents; the generator does not overwrite them.
