# ECC-035 automatic agent routing TDD record

## Journeys

1. A router reads the initial request, runs `route inspect`, receives repository-matched task choices and canonical context paths without creating task or agent records, then chooses explicit parameters.
2. The router runs `route start` once. Focus Queue creates or associates the task and named subtask, provisions its workspace, starts the provider in the task tmux session, opens the configured terminal, and records every recovery locator.
3. The successor registers its real provider conversation UUID. Only then does the result authorize the router to exit.
4. After terminal loss, tmux reattaches the exact pane. After tmux loss, the saved provider UUID and workspace produce one exact resume command.

## Acceptance

- Automatic routing is opt-in and legacy configuration decodes with it disabled.
- Inspection is fast, deterministic, repository-scoped, and does not mutate dashboards or task contexts.
- Start selections preserve provider, model, effort, provider version, prompt digest, project/task/subtask identity, workspace, branch, tmux locator, terminal locator, and injected context paths.
- Provider arguments remain literal and aliases/functions still work.
- The startup receipt is concise JSON and registration updates it with the real provider conversation UUID.
- macOS Terminal uses the same verified tmux attach path without UI automation.
- A failed or replayed handoff cannot create a duplicate provider process.

## RED

`swift test --filter AgentRoutingTests` fails because the opt-in configuration, route coordinator/store, launch configuration, startup receipt/store, and provider model/effort arguments do not exist. This is the expected pre-implementation failure.

## GREEN

`swift test --filter AgentRoutingTests` passes 6 tests. The suite covers opt-in configuration compatibility, read-only repository-scoped inspection, cross-prefix dashboard ownership, literal provider model/effort arguments and injected paths, one-time route claims, and registered recovery receipts.

`python3 -m unittest Tests.test_codex_entry` passes 49 tests. The shell entry routes only fresh, unassigned interactive agents when opted in; resumes, assigned runtimes, noninteractive commands, utilities, and nested successors retain their existing paths.

The complete repository suites pass: 408 Swift tests and 223 Python tests. `AgentRouting.swift` has 87.13% region, 87.18% function, and 98.26% line coverage under the focused suite.

Installed inspection exposed a legacy cross-prefix case: ECC-035 is owned by the Focus Queue dashboard despite its `ECC` prefix. RED `f17c353` captured the failure. The locator now searches all active project dashboards and accepts exactly one owner instead of guessing from the task ID prefix; the focused regression passes.

The first isolated live launch stopped safely before provider creation because Swift recorded `/tmp` while Python canonicalized the same macOS path to `/private/tmp`. RED `c6e87a1` captures the alias mismatch. Repository identity comparison now requires equal resolved paths, device IDs, and inode IDs; the focused check and all 49 shell-entry tests pass.

## Workflow sanity

The installed two-command workflow passed against an isolated support directory and the already trusted ECC Focus Queue repository:

- `route inspect` returned `SAN-901`, the repository, project plan, task plan/context/log paths, source Codex UUID, source WezTerm pane/socket, and exact existing/new-task command templates without creating an agent.
- `route start` created one isolated worktree and branch, one task-owned tmux pane, and one successor. It returned `registered`, `routerAction: exit`, and real Codex UUID `01a0c5d2-5fff-7871-80c1-b06082ccd2d9` in 3.7 seconds.
- The successor read the injected capsule/plans, registered the same UUID, verified its workspace/branch, wrote no source files, and reported `SANITY_OK`.
- Replaying the identical start command returned the same receipt with `replayed: true`; the task still had exactly one pane.
- After killing the owned test pane, the receipt's saved resume locator restarted the exact UUID in a new managed pane. `runtime locate` proved the same conversation, task, subtask, tmux session, and full prior transcript.
- Cleanup verified a clean worktree and merged base, stopped the test pane, removed the worktree and branch, and moved both temporary fixtures to Trash.

An intentionally untrusted temporary repository reached Codex's native trust confirmation before inference. Routing stopped with one owned pane and no duplicate; the fixture was cleanly removed. This is an expected provider safety gate, not bypassed by Focus Queue.
