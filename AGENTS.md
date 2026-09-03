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
