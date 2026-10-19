# ECC-035 Router composer interactions TDD record

> **Deprecated (FOC-026, 2026-10-19).** The in-app Router composer and these view-model tests were removed; the + task creator replaces it. The core `QueueObjectiveRouter` types and CLI composer branches remain unreachable from the UI until a later cleanup.

## Journeys

1. A user writes a multiline objective. Shift+Return inserts a newline and Return submits it.
2. For three seconds after submission, Cancel prevents any Router launch and restores the exact text, including line breaks and trailing spaces.
3. After the undo window, one Router launches. If the agent paraphrases its instruction while calling `route inspect`, Focus Queue still authorizes and routes the original submitted objective.
4. Router and task-agent tmux sessions support mouse scrolling and retain 50,000 lines of history.

## RED

Commit `b1b2ed6` added regressions before the implementation:

- Router keyboard and cancellation tests did not compile because the interaction APIs did not exist.
- The authorization test failed because the paraphrased prompt digest did not equal the submitted prompt digest.
- The live tmux test reported `mouse off` and a 2,000-line history limit.

## GREEN

Commit `1823914` implements the behavior:

| Journey | Automated evidence |
| --- | --- |
| Shift+Return and Return | `routerComposerKeyboardSemantics` |
| Cancel and exact draft restore | `cancelRouterObjectiveWithinUndoWindow` |
| Launch after the undo window | `routerObjectiveStartsAfterUndoWindow` |
| Original prompt survives a Router paraphrase | `authorizedComposerUsesOriginalObjective` and the detached Router CLI workflow |
| Scrollable managed terminals | `scrollbackDefaults` and the real task-agent tmux workflow |

The focused run passed 53 tests in five suites. Changed core files reached 82.24% to 93.61% line coverage: `QueueObjectiveRouter.swift` 82.24%, `Tmux.swift` 83.60%, `TmuxOrganizer.swift` 88.86%, and `AgentRouting.swift` 93.61%. `QueueViewModel.swift` is a broad application model, so the focused run reports 17.68% file-wide line coverage while directly executing both new undo paths. SwiftUI view-body coverage is not available in the headless suite. UI automation remained disabled as required; the pure keyboard mapping and model behavior are tested without pointer or keyboard simulation.

All 277 Python tests pass. The full 466-test Swift run reached two unrelated failures: a heartbeat timing assertion that passed on immediate isolated rerun, and `concurrentEvents`, which fails identically on the unchanged integration baseline `8011d18`. The affected 53-test change suite remains fully green.

## Workflow sanity

The detached Router workflow deliberately paraphrases the saved objective before invoking the installed-style CLI. The created route intent contains the original multiline submission, proving that authorization no longer depends on exact agent wording. Real detached Router and task tmux sessions report `mouse on` and a 50,000-line history limit. The cancellation test waits beyond the undo deadline and verifies that the Router launch count remains zero and the exact draft is returned.
