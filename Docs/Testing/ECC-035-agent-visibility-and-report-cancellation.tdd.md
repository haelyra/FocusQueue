# ECC-035 Agent Visibility and Report Cancellation TDD Evidence

## User journeys

- Subtasks open expanded so their complete titles and details are immediately readable.
- An assignment's agent count always matches the visible agent cards beneath it.
- Legacy combined assignment and runtime records migrate without losing session identity.
- A running daily report has a Cancel button that stops the owned worker process.
- A cancelled report is retained as interrupted, never completed or failed.

## RED and GREEN evidence

| Guarantee | Test | RED evidence | GREEN evidence |
| --- | --- | --- | --- |
| New subtasks start expanded | `defaultExpansion` | `637061c` failed because disclosure state defaulted to collapsed | Active and archived rows now share the expanded default |
| Count and cards use the same agents | `visibleLinkedAgentPresentation` | `637061c` reproduced a removed agent counted without a card | Both surfaces use `SubtaskAgentPresentation` |
| Legacy assignment and runtime state separate safely | `legacyCombinedAssignmentMigration` | `637061c` reproduced a combined record | `38c2e9c` and `07e811e` migrate only schema 1 contexts and retain runtime identity |
| Cancellation is single-shot and reusable | `coordinatorCancellation`, `dailyReportCancellationState` | `1469cd9` did not compile because the coordinator and cancellation state did not exist | The app owns one cancellable report task and resets after it exits |
| Cancellation history remains truthful | `cancelledRun` | `96b58b7` did not compile because an interrupted final phase could not be recorded | Cancellation transitions the active receipt to `interrupted` |
| Assignment metadata cannot block runtime cleanup | `workspaceSafety` | The added assignment fixture retained the child worktree as if another agent owned it | Assignment-only records are excluded from cleanup ownership and sharing checks |

## Implementation result

- Active and archived subtasks start expanded. Collapsing remains an explicit per-row action.
- Counts and nested agent cards derive from the same visible linked-agent collection.
- Provider cards use valid, distinct Codex and Claude symbols with stronger card contrast.
- Schema 1 contexts split each legacy combined record into an assignment parent and runtime child. Schema 2 prevents repeat migration.
- App-owned daily-report execution covers manual, scheduled, chat, and approval entry points. Cancel cooperatively terminates the Python process through the existing process runner and escalates after its bounded grace period when needed.
- Cancellation is available from the queue notification, report view, and settings view. Repeated clicks are disabled while cancellation is pending.
- App termination also cancels an active report task. Cancellation before process launch is checked after settings persistence.
- Managed worktree cleanup applies only to runtime records, not assignment metadata that references the same workspace.

## Verification and coverage

- Focused cancellation, history, presentation, migration, and workspace lifecycle tests passed.
- `swift test --enable-code-coverage`: 278 tests passed in 29 suites. One live app interaction test was skipped under the repository's explicit UI opt-in policy.
- `python3 -m unittest discover -s Tests -p 'test_*.py'`: 128 tests passed.
- Repository-wide Swift line coverage is 50.65%. Directly changed core files are 95.59% for `DailyReportHistory.swift`, 91.53% for `TaskWorktreeManager.swift`, and 88.64% for `TaskContext.swift`. The SwiftUI executable baseline remains lower, while the new coordinator, model state, title expansion, agent presentation, and symbol contracts have direct headless tests.
- Pointer and keyboard automation was not run because `ECC_FOCUS_QUEUE_UI_TESTS=1` was not set.

## ECC-035 persisted-state validation

- The context is schema version 2 with seven assignment records and seven linked runtime records.
- Every runtime has a valid assignment parent. The blocked assignment resolves to exactly one visible agent.
- Legacy clipped sentence fragments were renamed through `focus-queue-session rename` to concise titles such as `Test Monitor Switching`, `Verify Multi-Display Focus`, and `Restore Terminal Focus Controls`.

## Commit evidence

- `637061c` RED: default expansion and agent presentation regressions.
- `38c2e9c` GREEN: legacy assignment and runtime separation.
- `07e811e` refinement: schema-gated migration.
- `1469cd9` RED: daily-report cancellation contracts.
- `96b58b7` RED: interrupted history, archived expansion, and workspace cleanup edges.
- `ab101ba` GREEN: report cancellation, interrupted persistence, expanded archives, and safe workspace cleanup.

