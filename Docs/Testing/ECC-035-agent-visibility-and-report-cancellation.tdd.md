# ECC-035 Agent Visibility and Report Cancellation TDD Evidence

## User journeys

- Subtasks open expanded so their complete titles and details are immediately readable.
- An assignment's agent count always matches the visible agent cards beneath it.
- Legacy combined assignment and runtime records migrate without losing session identity.
- A running daily report has a Cancel button that stops the owned worker process.
- A report worker recovered after an app restart remains gated and cancellable.
- A cancelled report is retained as interrupted, never completed or failed.
- App installation deploys the exact reviewed automation payload atomically with the app.
- Install and uninstall transactions cannot overlap or replace an unverified automation tree.

## RED and GREEN evidence

| Guarantee | Test | RED evidence | GREEN evidence |
| --- | --- | --- | --- |
| New subtasks start expanded | `defaultExpansion` | `637061c` failed because disclosure state defaulted to collapsed | Active and archived rows now share the expanded default |
| Count and cards use the same agents | `visibleLinkedAgentPresentation` | `637061c` reproduced a removed agent counted without a card | Both surfaces use `SubtaskAgentPresentation` |
| Legacy assignment and runtime state separate safely | `legacyCombinedAssignmentMigration` | `637061c` reproduced a combined record | `38c2e9c` and `07e811e` migrate only schema 1 contexts and retain runtime identity |
| Cancellation is single-shot and reusable | `coordinatorCancellation`, `dailyReportCancellationState` | `1469cd9` did not compile because the coordinator and cancellation state did not exist | The app owns one cancellable report task and resets after it exits |
| Cancellation history remains truthful | `cancelledRun` | `96b58b7` did not compile because an interrupted final phase could not be recorded | Cancellation transitions the active receipt to `interrupted` |
| Assignment metadata cannot block runtime cleanup | `workspaceSafety` | The added assignment fixture retained the child worktree as if another agent owned it | Assignment-only records are excluded from cleanup ownership and sharing checks |
| Recovered workers remain controllable | `recoveredDailyReportCancellation`, `workerCancellationRequest`, `test_persisted_cancel_request_stops_a_recovered_worker` | `ef633e0` did not compile or failed because no worker control protocol or recovered UI state existed | The lock-owning worker publishes a private token and watches for the matching cancellation request |
| Cancellation stops descendants | `test_process_group_cleanup_terminates_a_stubborn_grandchild` | `ef633e0` left a SIGTERM-resistant grandchild running | Worker cleanup verifies the process group and escalates the entire group to `SIGKILL` after the grace period |
| Cleanup rejects directory replacement | `workspaceReplacementSafety` | `e5e8b52` reached Git removal after the validated directory was replaced | Cleanup revalidates inode, worktree root, Git directory, and common repository immediately before removal |
| Automation ownership is unambiguous | `test_automation_digest_distinguishes_file_boundaries` | `dd1e328` reproduced a digest collision between different file layouts | The manifest uses a versioned, length-prefixed tree digest with per-file content hashes |
| Only reviewed automation is installed | `test_automation_payload_rejects_missing_extra_and_symlink_entries` | `dd1e328` accepted missing, extra, and symlinked payload entries | Preflight and staged-copy validation require the exact eight regular automation files |
| Install and uninstall are serialized | `test_uninstall_uses_the_installation_lock` | `dd1e328` allowed uninstall while the install lock was held | Both mutating transactions use the same nonblocking installation lock |
| Existing automation ownership upgrades safely | `test_upgrade_accepts_and_replaces_a_verified_legacy_automation_digest` | `9c4f363` reproduced a safe install being rejected after the digest format changed | Exact-file validation precedes legacy verification, and the replacement manifest records the canonical algorithm |
| Legacy checksums remain unambiguous | `test_legacy_automation_digest_rejects_nul_content` | `ed5fea1` showed an algorithm-less manifest accepting delimiter-bearing file content | Legacy verification accepts only the NUL-free payload format emitted by the shipped release |

## Implementation result

- Active and archived subtasks start expanded. Collapsing remains an explicit per-row action.
- Counts and nested agent cards derive from the same visible linked-agent collection.
- Provider cards use valid, distinct Codex and Claude symbols with stronger card contrast.
- Schema 1 contexts split each legacy combined record into an assignment parent and runtime child. Schema 2 prevents repeat migration.
- App-owned daily-report execution covers manual, scheduled, chat, and approval entry points. Cancel cooperatively terminates the Python process through the existing process runner and escalates after its bounded grace period when needed.
- Cancellation is available from the queue notification, report view, and settings view. Repeated clicks are disabled while cancellation is pending.
- Recovered workers publish an unguessable run token in the private runtime directory. A relaunched app can request cancellation without signaling an unvalidated PID, while new launches remain gated on the live lock.
- App termination writes the same cancellation request and cancels the active task. Cancellation before process launch is checked after settings persistence.
- Python blocks `SIGTERM` while publishing each child process, then terminates and verifies the complete process group. User cancellation does not write failed retry metadata.
- Managed worktree cleanup applies only to runtime records, not assignment metadata that references the same workspace.
- Managed cleanup pins device, inode, worktree Git directory, and common repository identity, then rechecks them after archival and immediately before Git removal.
- The installer packages the app and its exact eight-file automation payload in one manifest-owned transaction. Its canonical digest distinguishes file boundaries, staged symlinks are preserved and rejected, and uninstall shares the installation lock.

## Verification and coverage

- Focused cancellation, history, presentation, migration, and workspace lifecycle tests passed.
- `swift test --enable-code-coverage`: 281 tests passed in 29 suites. One live app interaction test was skipped under the repository's explicit UI opt-in policy.
- `python3 -m unittest discover -s Tests -p 'test_*.py'`: 136 tests passed.
- Repository-wide Swift line coverage is 50.95%. Directly changed core files are 94.09% for `DailyReportHistory.swift`, 90.18% for `TaskWorktreeManager.swift`, and 88.64% for `TaskContext.swift`. The SwiftUI executable baseline remains lower, while the new coordinator, model state, title expansion, agent presentation, and symbol contracts have direct headless tests.
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
- `ef633e0` RED: recovered cancellation, descendant teardown, and cancellation metadata contracts.
- `74e6135` GREEN: persisted worker control, recovered-run gating, and full process-group teardown.
- `e5e8b52` RED: managed directory replacement during cleanup.
- `1717990` GREEN: inode and Git-identity revalidation before removal.
- `6e7e858` refinement: safe handling when a short-lived process group exits before escalation.
- `5a5958e` RED: installation must update and roll back app-owned automation with the app.
- `48fb8fd` GREEN: staged automation installation, ownership manifest, and rollback coverage.
- `dd1e328` RED: digest collision, exact payload, and install/uninstall serialization regressions.
- `bdf2d8b` GREEN: canonical automation ownership and shared mutation locking.
- `9c4f363` RED: verified legacy automation could not upgrade to the canonical digest format.
- `0628f40` GREEN: exact-payload legacy verification followed by a canonical replacement manifest.
- `ed5fea1` RED: ambiguous delimiter-bearing legacy automation content was accepted.
- `9fd8718` GREEN: legacy verification rejects NUL-bearing content before hashing.
