# Repository agent instructions

## Interaction safety

- Do not run UI automation by default. This includes simulated mouse or keyboard
  input, Accessibility-driven clicks, opening and closing Settings, moving app
  windows between displays, or changing the user's active application.
- UI automation is opt-in. Run it only when the user explicitly requests it for
  the current task and sets `ECC_FOCUS_QUEUE_UI_TESTS=1` for that run.
- Keep UI automation code available, but skip it when the opt-in variable is
  absent.
- Prefer headless verification such as `swift test`, Python unit tests, syntax
  checks, process inspection, and persisted-state inspection.
- Installing or restarting ECC Focus Queue is allowed when needed to deliver a
  requested app change, but do not manipulate the pointer to validate it.

## Task session association

- As soon as the relevant ECC ticket ID is known, run
  `/Users/hira/.local/bin/focus-queue-session attach <TICKET-ID>` from the
  agent's WezTerm pane. Repeat this when switching to a different ticket.
- Registration reads the provider session ID and WezTerm pane directly from
  the agent environment. Do not search transcript history unless direct
  registration is unavailable.
- After association, ECC Focus Queue owns the terminal labels. Keep the window
  title exactly equal to the ticket ID. A shared task tmux session uses one
  stable WezTerm tab label, `<TICKET-ID> · tmux`. Keep tmux pane presentation
  plain: no Focus Queue pane-border label row or status padding beyond the
  managed usage bar and native tmux window tabs. A direct terminal without
  shared tmux may use `<TICKET-ID> · <Provider> · <last 6 session UUID characters>`.
  Do not run `tabname` again or otherwise overwrite those labels after attachment.

## Delivery checkpoints

- After a requested application change passes its appropriate tests, commit the
  cohesive repository changes before reporting completion. Do not leave verified
  work only in the working tree.
- Feature agents must not install or replace the shared app from isolated
  branches. Commit and hand off the branch for review. Only the clean canonical
  integration checkout at the current `origin/main` commit may install the
  shared app, restart it, and verify its executable hash and process start time.
- An assigned agent workspace is immutable. Refresh metadata only for the same
  path; create a new agent assignment for a different checkout.
- Push commits only when the user explicitly requests remote delivery or the
  active task already includes it.
