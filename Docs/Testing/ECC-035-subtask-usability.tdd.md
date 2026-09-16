# ECC-035 Subtask Usability TDD Evidence

## Source and user journeys

Source: [ECC-035 central plan](</Users/hira/Library/Application Support/ECC Focus Queue/tasks/ECC-035/plan.md>).

- As a user, I can edit a subtask from its options menu without the app appearing frozen.
- As a user, I see short, readable generated titles while the full assignment remains available.
- As a user, I can expand a subtask to read its complete title.
- As a user, I can distinguish Codex and Claude agents by visible provider icons.
- As a user, a title edit cannot erase concurrent agent progress or a newer edit.

## RED and GREEN evidence

| Guarantee | Test | RED evidence | GREEN evidence |
| --- | --- | --- | --- |
| Generated names are concise titles and truncate normal prose only at word boundaries | `generatedAgentNamesAreReadableTitles`, `generatedAgentNamesRespectWordBoundaries` | `swift test --filter generatedAgentNames` failed with four expectations: 80-character sentence fragments, Markdown markers, and mid-word truncation | The same filtered command passed both tests |
| Title edits publish immediately and preserve concurrent durable agent state | `optimisticSubtaskEditing` | The targeted test failed because status, progress summary, and session ID reverted to stale values | `swift test --filter 'generatedAgentNames|optimisticSubtaskEditing|SubtaskPresentationTests'` passed five tests |
| Expanded titles use more vertical space | `expandedTitleHeight` | Compile-time RED: `SubtaskTitleLabel` did not exist | The headless `NSHostingView` layout test passed |
| Providers have distinct, available icons | `providerIcons` | Compile-time RED: `AgentProvider.symbolName` did not exist | Both provider symbols resolved through AppKit and the test passed |

## Implementation result

- Prompt-derived names remove common request boilerplate and Markdown prefixes, stop at the first sentence, retain at most six normal words or 56 characters, preserve tokens such as `ECC035`, `iOS`, and `tmux`, and never return an empty title.
- The subtask edit action uses an item-driven sheet after menu tracking has ended. It publishes title and explanation changes optimistically while the durable write runs.
- Durable edits mutate only title and explanation. Per-subtask tasks serialize rapid edits, stale completions cannot replace newer UI state, and concurrent progress, session, result, and association fields remain intact.
- Active and archived subtask rows share a multiline title view. Expanded titles have no line limit.
- Codex and Claude rows use distinct built-in system symbols. The invalid `rectangle.expand.horizontal` symbol was replaced with an available symbol.

## Verification and coverage

- `swift test --enable-code-coverage`: 269 tests passed in 28 suites. Three repository-defined opt-in interaction tests were skipped.
- `python3 -m unittest discover -s Tests -p 'test_*.py'`: 128 tests passed.
- Swift coverage report: 51.61% repository-wide line coverage. The broad SwiftUI executable baseline remains below 80%; directly changed core files were 85.71% for `Models.swift` and 88.57% for `TaskContext.swift`. `QueueViewModel.swift` was 63.43%, while the relevant edit path is exercised by an integration test. SwiftUI layout and symbol behavior are exercised headlessly.
- Pointer and keyboard automation was not run because `ECC_FOCUS_QUEUE_UI_TESTS=1` was not set, as required by repository policy.

## Commit evidence

- `1e02c6f` RED: unreadable generated-title reproducer.
- `2003f65` GREEN: concise title generation.
- `ed507b0` RED: responsive edit, expansion, and icon contracts.
- `854fd1a` GREEN: item-driven editing, optimistic UI, expanded wrapping, and provider icons.
- `b439b88` RED: concurrent durable-state preservation.
- `0bb3043` GREEN: field-scoped, token-correlated persistence.
- `03f8a26` refinement: serialized rapid edits and delayed menu-to-sheet handoff.

## Known gap

The original three-dot interaction was not pointer-driven in this run because UI automation was not opted in. The menu now exits before presenting one item-driven editor sheet, and the underlying layout, persistence, and concurrency paths are covered headlessly.
