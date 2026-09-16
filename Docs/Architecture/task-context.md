<!-- fq-architecture: {"id":"task-context","title":"Central plans and task context","sources":[{"path":"Sources/FocusQueueCore/TaskContext.swift","sha256":"9552dd9f1cf7f746ef899ba8c92189e430f40bcb443ae381615989daed522ae1"},{"path":"Sources/FocusQueueCore/TaskWorktreeManager.swift","sha256":"e5b10955995275b3c4d25429f786f89bd18d911ee325e23dac122595adb34642"},{"path":"Sources/FocusQueueCore/AgentRegistrationInbox.swift","sha256":"4d1264c19c74ee8ca9bbe73faefe94a0d5c36fbf0f1ff02e94d8065a30056d6e"},{"path":"Sources/FocusQueueCore/SubtaskAssignments.swift","sha256":"fc6e20c19a52042a4b9025f089c11ac8c9195de80cf1ba4e815b17a75d88bec7"},{"path":"Sources/FocusQueueCore/AgentActivityObserver.swift","sha256":"de2c89ce1935c51ca8efd3268b55c9a2fb37f6323c7ebe4ab3a01aba2be31939"}]} -->

# Central plans and task context

Each task has a canonical plan and structured context. Worktree references lead back to that context so multiple agents can share decisions without maintaining competing plan copies.

## Follow the code

- [TaskContext.swift](../../Sources/FocusQueueCore/TaskContext.swift), `TaskContextStore`: validates task paths, serializes mutations with an advisory lock, saves atomically, and archives snapshots. Agent removal records a timestamp independently of subtask status and retains conversation identity and workspace history. Completion overrides are explicit persisted events. Each agent workspace records its path, branch, base commit, and ownership; guarded cleanup removes only clean, merged app-owned worktrees. `savePlan` compares an expected baseline when supplied so concurrent plan edits can be rejected for reconciliation.
- `TaskSessionBinding` reads explicit provider/session environment data and prevents a retained subtask environment from silently attaching to a different task.
- [TaskWorktreeManager.swift](../../Sources/FocusQueueCore/TaskWorktreeManager.swift): handles task worktree selection and lifecycle policy. Inspect its actual checks before any cleanup or reuse change.
- [AgentRegistrationInbox.swift](../../Sources/FocusQueueCore/AgentRegistrationInbox.swift): carries pane/session association into the app.

## Subtask focus and agent associations

The queue lists root assignments, ordered by active work, blocked or waiting work, idle work, queued work, and completed work. Each assignment contains its associated agents. An empty assignment remains visible with a New agent action. New subtask agent creates a blank prompt with a suggested workspace; task initialization starts unchecked and is independent of completion tracking.

Context storage remains backward compatible with legacy combined assignment/runtime records. New UI launches save an assignment with `isAssignmentOnly: true` and separate runtime records with `parentSubtaskID`. `associatedSubtaskIDs` permits one agent to handle additional assignments. Only orchestrator review boundaries combine shared work; `mergedIntoSubtaskID` keeps old IDs addressable and original records retain their workspace and conversation history. Native conversation identity is scoped by provider. The durable library records current session-to-assignment links independently of terminal locators.

Removing an agent preserves the assignment. Completing an assignment retires its runtime, but its unread result remains available until viewed or dismissed. Acknowledgement checks the result version so opening an older response cannot dismiss a newer one. Explicitly reopening a completed conversation does not restart its assignment or trigger repeated automatic retirement.

`AgentActivityObserver` reads bounded structured event tails for an already registered provider conversation. It distinguishes responses, questions, interruptions, and errors without treating a response as verified assignment completion. Terminal inspection identifies confirmed closed runtimes and recognizable approval controls; transport failures do not imply termination. Providers can report `attention` and `result` through the session helper. Unrecognized provider events retain the last known state instead of inventing a status.

## Boundaries and checks

`installWorktreeReference` preserves existing reference files and rejects symbolic-link task context directories. A subtask heartbeat, unread completion update, verifier verdict, and task closure are separate states. Preserve those distinctions when modifying progress or notification behavior. Start with `TaskContextTests` and the task-session binding tests.

Summary semantics are unverified after generation. Recheck conflict, archive, and worktree rules whenever their source hashes change.
