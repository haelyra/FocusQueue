# Completed agent terminal verification

Automatic completion now replaces the verified provider runtime with a terminal
shell that reports completion and prints an exact provider UUID resume command.
Managed tmux keeps the same pane and window. Direct WezTerm creates the shell in
the same window before closing the verified provider pane. Explicit agent removal
keeps its existing close behavior.

Settings includes a default-on automatic exit toggle; missing configuration keys
migrate to enabled. Turning it off leaves completed runtimes running. Retained
completion records protect their workspace from automatic cleanup.

## Verification

- Final integrated Swift suite on delivered base 7838afd: 410 tests passed across 42 suites.
- Installer regression suite: 27 tests passed.
- The integration preserves the installed Gmail provider and program log; one
  stale Gmail prompt assertion now checks provider selection and the same
  prohibition on Himalaya.
- Final focused regression: 6 tests passed after the cleanup-record adjustment.
- Actual detached tmux workflow: started a disposable provider stand-in and sibling,
  invoked the production completion method, captured the completion message and
  exact UUID, verified the original pane remained live with a replacement shell,
  and verified the sibling remained live. The isolated test server was stopped.
- Both providers' resume commands were executed against capture functions with a
  workspace containing spaces, apostrophes, and shell metacharacters.
- Configuration migration, opt-out persistence, refresh without retirement, and
  re-enabling retirement passed in the app model.
- Workspace-retention guards passed with an otherwise inactive owner.
- Direct WezTerm split-pane arguments checked against the installed CLI help.

No pointer, keyboard, Accessibility, or live-window UI automation was performed.
Visual layout and the direct WezTerm window transition remain manual checks.
