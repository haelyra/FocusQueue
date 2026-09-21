# ECC-035 Deterministic Session Recall TDD Evidence

## User journey

- A clicked running agent opens the exact saved tmux pane from its saved workspace.
- A clicked stopped agent resumes the exact saved provider conversation UUID once, in a new task-owned tmux pane, from the same workspace.
- A legacy pane whose live provider UUID differs from the clicked record is never opened as that agent.
- Managed recall opens a fresh terminal view with the exact tmux attach command in either WezTerm or macOS Terminal.
- The user's login-shell `codex` function, default flags, Focus Queue intake, and managed usage bar remain in the launch path.

## RED and GREEN evidence

| Guarantee | Test | RED evidence | GREEN evidence |
| --- | --- | --- | --- |
| Managed WezTerm recall does not depend on a discoverable mux socket | `managedRecallStartsFreshWezTermProcess` | `024d6a0` failed with “WezTerm opened without a usable connection” | `141640a` launches a fresh WezTerm process with the exact tmux attach argv |
| macOS Terminal receives the same exact attach recipe without shell interpolation | `managedRecallStartsMacTerminalCommandFile` | `024d6a0` had no Terminal recall implementation | `141640a` creates a private, self-removing command file; `zsh -n` validates it and the test verifies mode `0700` |
| Stopped Codex recall preserves UUID and workspace | `exactCodexResumeRecipe` | The prior recall path did not test native resume argv | `141640a` verifies `resume UUID --cd workspace --add-dir context` through the user's login shell |
| A legacy pane cannot impersonate the clicked conversation | `legacyTmuxConversationMismatch` | The prior path opened the saved pane without comparing its live provider UUID | `141640a` rejects the mismatched pane and resumes only the clicked UUID in a task-owned pane |
| Terminal selection cannot silently fall back to a direct WezTerm launch | `macTerminalRequiresTmux` | The prior setup allowed an incompatible direct runtime choice | `141640a` rejects the choice before any launch side effect |
| The full installed provider path survives creation, detach, reopen, stop, and resume | `liveManagedProviderSanity` | The first run exposed an invalid hexadecimal test ticket and the installed entry rejected it | A valid numeric test ticket completed all four workspace and initialization variants with four unique UUIDs and exact resumes |

## Implementation result

- Managed recall no longer discovers or reuses arbitrary WezTerm mux sockets. It verifies and selects the saved tmux pane, then opens a fresh terminal client using one exact attach recipe.
- WezTerm uses `open -na ... --args start --always-new-process -- <tmux argv>`.
- macOS Terminal uses a private one-use `.command` file containing only shell-quoted fixed argv. The file deletes itself before attaching.
- Before opening a managed runtime, the app compares the live provider UUID with the clicked record. A mismatch fails closed for modern task panes. A mismatched legacy pane is not opened and the exact saved UUID is resumed once in a new task-owned pane.
- Stopped Codex conversations use the user's login-shell command with the exact native UUID and saved workspace. Existing aliases, default flags, Focus Queue intake, and usage-bar behavior remain active.

## Verification and coverage

- `swift test`: 402 tests passed in 40 suites; two repository-defined live or UI tests were skipped without their opt-in variables.
- `python3 -m unittest discover -s Tests -p 'test_*.py'`: 221 tests passed.
- Focused Swift coverage ran 17 recall tests. `ManagedTerminalLauncher.swift` reached 80.77% region, 100% function, and 93.75% line coverage.
- `ECC_FOCUS_QUEUE_LIVE_AGENT_TESTS=1 swift test --filter liveManagedProviderSanity`: four variants passed. Each created a unique provider UUID, returned `SANITY_OK`, reopened the exact saved pane after detach, resumed the unchanged UUID after stop, retained the exact workspace, saved isolated persistence state, and preserved the legacy sibling session.
- Pointer and keyboard automation was not run because `ECC_FOCUS_QUEUE_UI_TESTS=1` was not set. Repository policy requires that explicit opt-in.

## Commit evidence

- `024d6a0` RED: deterministic WezTerm and macOS Terminal recall contracts.
- `141640a` GREEN: exact managed recall, provider-identity validation, stopped-session resume, setup constraints, and focused coverage.
- The live fixture correction is committed with this evidence after the real installed-provider sanity run exposed its invalid ticket format.
