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

`swift test --filter AgentRoutingTests` passes 5 tests. The suite covers opt-in configuration compatibility, read-only repository-scoped inspection, literal provider model/effort arguments and injected paths, one-time route claims, and registered recovery receipts.

`python3 -m unittest Tests.test_codex_entry` passes 48 tests. The shell entry routes only fresh, unassigned interactive agents when opted in; resumes, assigned runtimes, noninteractive commands, utilities, and nested successors retain their existing paths.

## Workflow sanity

Pending.
