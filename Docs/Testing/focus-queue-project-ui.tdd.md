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

## GREEN

- Added atomic dashboard create and rename operations with concurrent-edit detection and unknown-field preservation.
- Added project migration, selection, scoped queue order, and globally unique generated task IDs.
- Added persisted automatic-report and minimization settings.
- Added view-model integration coverage for project switching, creation, rename propagation, collapse behavior, and report disabling.
- Added packaging tests for the renamed bundle and verified legacy installation migration.
- Serialized Swift and Python dashboard mutations through the shared `.<dashboard>.focus-queue.lock` contract, including matching cross-language path tests.

## Verification

- `swift test`: 350 tests in 38 suites passed.
- `python3 -m unittest discover -s Tests -p 'test_*.py'`: 184 tests passed.
- Release app build and code signing completed successfully.
- The release `focus-queue-map` executable was exercised against a temporary two-project configuration. Listing and moving tasks followed `selectedProjectID`, wrote separate project order files, and retained the first project's order after switching projects.
- Swift-to-Swift mutation serialization, the shared Swift/Python lock path, and recovery rollback rechecking all have focused regression coverage.
- UI automation was not run because repository policy requires explicit opt-in. UI interactions are covered through view-model integration tests and the installed app is verified by binary hash and process start time during delivery.
