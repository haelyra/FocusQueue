# Focus Queue project UI TDD record

Date: 2026-09-18

## Scope

- Rename the displayed product to Focus Queue while retaining storage and service compatibility.
- Add project selection and project-scoped task creation.
- Persist the preferred collapse behavior.
- Move notifications and new-task controls into the requested locations.
- Disable automatic daily reports without removing manual reports or history.
- Rename task titles through a double-click interaction and update live projections.

## RED

`swift test --filter QueueViewModelTests` initially failed to compile because project configuration, dashboard mutation, report enablement, and minimization preference APIs did not exist.

A focused legacy-configuration test then failed because assigning the existing `dashboardPath` and `workspacePath` fields did not update the selected project. This exposed a compatibility regression before integration.

Reviewer-driven concurrency tests then exposed that the Swift dashboard writer's lock did not coordinate with the Python morning reconciler. Matching contract tests failed until both writers used the same adjacent dashboard lock path and `flock` protocol.

The project-creation tests initially failed to compile because the transaction and CLI did not exist. Write-boundary, interrupted-recovery, concurrent-creation, destination-symlink, tampered-manifest, permissions, and cross-project-duplicate tests then failed against successive incomplete implementations before each guard was added.

The notification follow-up first failed to compile because there was no bounded popover height or attention-only notification projection. This captured both regressions before the inline feed was replaced.

## GREEN

- Added atomic dashboard create and rename operations with concurrent-edit detection and unknown-field preservation.
- Added project migration, selection, scoped queue order, and globally unique generated task IDs.
- Added persisted automatic-report and minimization settings.
- Added view-model integration coverage for project switching, creation, rename propagation, collapse behavior, and report disabling.
- Added packaging tests for the renamed bundle and verified legacy installation migration.
- Serialized Swift and Python dashboard mutations through the shared `.<dashboard>.focus-queue.lock` contract, including matching cross-language path tests.
- Added a recoverable multi-file project transaction and `projects list|create|recover` CLI. It preserves unknown JSON fields, current project selection, source queue order, exact rollback bytes, and private file permissions.
- Taught Queue Chat the verified project workflow and reload the external project catalog without restarting.
- Tightened the queue chrome and top-screen gap, removed the terminal counter from the header, and retained it in Settings.
- Replaced the inline notification feed with a bounded scrollable popover. Ordinary agent results and completions remain available in task context but no longer count as notifications; questions, failures, review issues, cleanup issues, and enabled report attention remain.

## Verification

- `swift test`: 368 tests in 39 suites passed, with two opt-in UI interaction tests skipped by repository policy.
- `swift test --enable-code-coverage`: 368 tests in 39 suites passed. `ProjectTransaction.swift` reached 90.0% line coverage; the shared persistence and queue-order paths reached 91.8% and 99.1%.
- `python3 -m unittest discover -s Tests -p 'test_*.py' -v`: 187 tests passed.
- The built `focus-queue-session` executable completed an isolated create/list/move workflow for ECC-035 and ECC-044, including unknown-field preservation, exact source removal, separate queue order, repeat-operation failure, and no-op recovery.
- Queue-view-model integration verified that Queue Chat sees a newly created project without restarting and that only actionable agent updates enter the notification projection.
- Release app build and code signing completed successfully.
- The release `focus-queue-map` executable was exercised against a temporary two-project configuration. Listing and moving tasks followed `selectedProjectID`, wrote separate project order files, and retained the first project's order after switching projects.
- Swift-to-Swift mutation serialization, the shared Swift/Python lock path, and recovery rollback rechecking all have focused regression coverage.
- UI automation was not run because `ECC_FOCUS_QUEUE_UI_TESTS=1` was not set. The notification popover's size cap, scroll container inputs, attention filtering, and frame geometry are covered headlessly. Installed-app hash and process-time verification remain part of post-commit delivery.
