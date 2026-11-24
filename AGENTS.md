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

- Terminal agents (tmux or WezTerm): as soon as the task ID is known, run
  `focus-queue-session attach <TASK-ID>` from the agent's pane, and again after
  switching tasks. Inside a managed pane the task and agent IDs come from
  `$FOCUS_QUEUE_TASK_ID` and `$FOCUS_QUEUE_SUBTASK_ID` and may be omitted.
- T3 Code agents do not attach. Focus Queue binds each one to its T3 thread at
  launch, and its brief names the task and agent IDs to pass to every
  `focus-queue-session` command. The CLI also finds the agent from
  `$T3CODE_THREAD_ID`; an attach from a T3 agent is a no-op, never a second agent.
- Report with `progress`, `log`, `result` and `complete`. `focus-queue-session
  rules` prints the full agent procedure. Never edit `state.json` or task
  `context.json` by hand.
- After association, Focus Queue owns terminal labels. Do not run `tabname` or
  otherwise overwrite them.

## T3 Code runtime

- The design lives in `Docs/Architecture/t3-runtime.md`; user-facing behavior is
  in the README's "T3 Code runtime (beta)" section.
- Unit tests must never contact T3 Code. Use the fakes in
  `Tests/FocusQueueCoreTests/T3TestSupport.swift` and the captured fixtures in
  `Tests/Fixtures/T3/`.
- Contacting a real T3 Code server is opt-in: `Scripts/t3_contract_probe.py`
  and `ECC_FOCUS_QUEUE_LIVE_T3_TESTS=1` for `T3LiveIntegrationTests`. Both need
  the user to approve Full access in T3 Code first; never approve it for them.
- Re-running the probe rewrites the fixtures. Review the diff for personal data
  (names, paths, remotes, other projects) before committing it.
- A branch build of the app crashes under `swift run` because it is not an app
  bundle. To try one by hand, build it with `Scripts/build-app.sh` and open
  `dist/Focus Queue.app` with `FOCUS_QUEUE_SUPPORT_DIR` pointing at a scratch
  folder. That is not an install; the installation rules below still apply.

## Delivery checkpoints

- Requested app changes include automatic canonical integration, remote delivery,
  installation, restart, and verification. Continue through those steps after
  feature verification; a feature-branch handoff alone does not complete delivery.
- After a requested application change passes its appropriate tests, commit the
  cohesive repository changes before reporting completion. Do not leave verified
  work only in the working tree.
- Feature agents must not install or replace the shared app from isolated
  branches. Commit and hand off the branch for review. Only the clean canonical
  integration checkout at the current `origin/main` commit may install the
  shared app, restart it, and verify its executable hash and process start time.
- Integration agents must fetch first, require a clean canonical checkout, and
  preserve ancestry. Use a fast-forward-only update when possible or an explicit
  reviewed merge. Never reset `main` to another branch, rewrite published
  history, force-push, delete `main`, or bypass repository push guards. If the
  remote advances, fetch and review it before retrying. Verify remote `main`
  equals local `main` after pushing and before building or installing.
- An assigned agent workspace is immutable. Refresh metadata only for the same
  path; create a new agent assignment for a different checkout.
- Push commits only when the user explicitly requests remote delivery or the
  active task already includes it.
