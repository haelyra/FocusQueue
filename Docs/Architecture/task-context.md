<!-- fq-architecture: {"id":"task-context","title":"Central plans and task context","sources":[{"path":"Sources/FocusQueueCore/TaskContext.swift","sha256":"e09ff2c1b0b120b11878198d680140415064059b9970145c8bdee896fdb8920a"},{"path":"Sources/FocusQueueCore/TaskWorktreeManager.swift","sha256":"27692b596396c2e8c3649b1b468afa4b5daae112b8da10512a0403314cc0612a"},{"path":"Sources/FocusQueueCore/AgentRegistrationInbox.swift","sha256":"4d1264c19c74ee8ca9bbe73faefe94a0d5c36fbf0f1ff02e94d8065a30056d6e"}]} -->

# Central plans and task context

Each task has a canonical plan and structured context. Worktree references lead back to that context so multiple agents can share decisions without maintaining competing plan copies.

## Follow the code

- [TaskContext.swift](../../Sources/FocusQueueCore/TaskContext.swift), `TaskContextStore`: validates task paths, serializes mutations with an advisory lock, saves atomically, and archives snapshots. Each subtask can retain an optional assignment explanation that appears in its agent prompt. Agent removal snapshots the assignment before and after deletion so a user-visible promise to retain history matches persisted behavior. `savePlan` compares an expected baseline when supplied so concurrent plan edits can be rejected for reconciliation.
- `TaskSessionBinding` reads explicit provider/session environment data and prevents a retained subtask environment from silently attaching to a different task.
- [TaskWorktreeManager.swift](../../Sources/FocusQueueCore/TaskWorktreeManager.swift): handles task worktree selection and lifecycle policy. Inspect its actual checks before any cleanup or reuse change.
- [AgentRegistrationInbox.swift](../../Sources/FocusQueueCore/AgentRegistrationInbox.swift): carries pane/session association into the app.

## Boundaries and checks

`installWorktreeReference` preserves existing reference files and rejects symbolic-link task context directories. A subtask heartbeat, unread completion update, verifier verdict, and task closure are separate states. Preserve those distinctions when modifying progress or notification behavior. Start with `TaskContextTests` and the task-session binding tests.

Summary semantics are unverified after generation. Recheck conflict, archive, and worktree rules whenever their source hashes change.
