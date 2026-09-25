# Task session organizer

New agents share one tmux session per task. Each native tmux window tab contains at most four active agent panes. The app opens one terminal view onto that task and recalls an agent by its pane identity, even after rearranging panes or closing the terminal view.

## Using it

1. Open a task and choose **New Agent**, keeping **Open in tmux** enabled.
2. Choose **Sessions** in task details, or the terminal button in the queue.
3. Click a pane to open its agent. Drag it onto another pane to swap them, including across the task's tabs. The context menu offers the same swaps without dragging.
4. Use **Arrange to fit** for automatic sizing, or **Keep my layout** for manual control. Resizing a terminal pane border also selects manual control.
5. **Copy attach command** lets the same session open in an existing terminal, IDE terminal or SSH connection to this Mac.

The pane map reflects tmux's current layout. Worktree grouping changes the list inside the selected task. Other terminals remain available in a separate browser.

## Layout and recall

```mermaid
flowchart TD
    Task[Task] --> Session[One tmux session]
    Session --> Tab1[Tab 1: up to four readable panes]
    Session --> Tab2[Additional tabs as needed]
    Tab1 --> AgentA[Agent and saved conversation]
    Tab1 --> AgentB[Agent and saved conversation]
    Terminal[Terminal window or IDE] --> Session
    App[App pane map] --> Session
```

The layout uses terminal cells and places at most four panes per tab. One to four panes use all available cells; agent five starts a second tab, agent nine starts a third, and so on. Extra panes use native tmux tabs, which remain available in terminals without native tabs.

Available height excludes the actual configured status-bar rows. Creating a task session also works when the server already contains older per-agent sessions.

Focus Queue currently keeps tmux presentation deliberately plain. tmux has no per-pane status rows, so each pane carries its managed usage bar in its bottom pane border — the only surface tmux formats per pane. The border line combines the bold task title with a compact single-line rendering of that pane's own agent (quota windows, context window, ticket), refreshed on the status timer. Panes without a registered agent show only the plain task title. The session status bar keeps one row of native tmux window tabs, and extra left/right status text is disabled; the border row is absorbed by tmux exactly like the former top title banner, so the layout math reserves no extra row. Terminal.app shows the same per-pane bars for managed sessions because tmux draws them. Agent names remain available in the app's session map and in nonvisual pane metadata.

Client attachment and resize hooks invoke the helper. A size-and-pane signature avoids repeating unchanged layouts. A task lock serializes launches, rearrangement and swaps across the app and helper. Reflow preserves the selected pane and never starts an agent process. Explicit removal kills only its verified pane and compacts the remaining automatic tabs. Automatic completion replaces the provider with its exact resume message, tags that shell as completed, and moves it to a separate completion tab so it does not consume active-agent capacity. Reopening the conversation replaces that completion shell with one new tracked agent pane. A user arrangement remains in effect until automatic layout is selected again.

Pane identity includes the server, session creation time, pane ID, process PID and TTY. Closing an agent kills only that verified pane. An unresolved launch receipt blocks duplicate starts and permits recovery of the original pane. A runtime belonging to another task cannot be opened through a misbound task record.

Existing direct WezTerm sessions and older per-agent tmux sessions remain available. They are not moved automatically. New launches use the task grouping model.

tmux can move or link a window between sessions only when both sessions use the same tmux server socket. Focus Queue does not merge live sessions because that would change durable session ownership and can make saved pane references ambiguous. It creates the task-owned session before the first agent and adds every later agent as another pane/window inside that session. Legacy per-agent sessions stay recallable through the compatibility path.

## Saved layouts

Pinned tmux-resurrect and tmux-continuum sources ship inside the application, including their licenses. Saves run every five minutes while detached, and on terminal detach. **Save now** and **Restore saved layout** are available in the session browser. Configuration is scoped to Focus Queue's tmux server.

Restore recreates shells, folders and layout. A reboot ends old agent processes. Open an agent from its task to resume its saved provider conversation in a new pane; restored shells remain available. An agent without a recorded provider conversation requires a fresh assignment. The app does not replay its old initial prompt.

See [persistence design](TMUX_PERSISTENCE.md) for snapshot retention, upstream pins and storage.

## Open-source options evaluated

| Project | What it offers | Fit here |
| --- | --- | --- |
| [tmux](https://github.com/tmux/tmux) | Stable pane IDs, mouse resizing, client size events, join/swap commands and control mode | Runtime and layout authority; the native app supplies task context. |
| [tmux-ui-manager](https://github.com/binara-sachin/tmux-ui-manager) | Mouse-capable popup with drag-and-drop moves between windows and sessions | Useful optional terminal UI and interaction reference. It is not bundled; its unrestricted cross-session moves need ownership integration first. |
| [iTerm2](https://github.com/gnachman/iTerm2) and its [tmux integration](https://iterm2.com/documentation-tmux-integration.html) | Native terminal windows and tabs backed by tmux control mode | Strong option for native terminal manipulation. Users can attach from iTerm2; the app still uses WezTerm for automatic desktop opening. |
| [sesh](https://github.com/joshmedeski/sesh) | Fast session selection and directory-oriented navigation | Useful optional keyboard workflow. It does not supply the app's task and pane model. |

The shipped drag-and-drop interaction lives in SwiftUI and uses verified tmux swap commands. No extra terminal manager or terminal replacement is required.

## Verification and boundaries

Headless tests use disposable tmux servers for pane overflow, reflow, identity retention, selection, manual layout, launch uncertainty, and save/restore. Existing app and Python tests cover launch, workspace, completion and document regressions. UI automation remains opt-in; real mouse interactions and monitor dragging require manual assessment.

For a persistent local smoke test using the actual login shell and installed aliases:

```sh
Scripts/sanity-task-tmux.sh start TEST
Scripts/sanity-task-tmux.sh remove TEST 4
Scripts/sanity-task-tmux.sh reopen TEST 4
Scripts/sanity-task-tmux.sh status TEST
```

The script leaves `fq-task-test` running. `open TEST` or `start TEST --open` opens WezTerm only when `ECC_FOCUS_QUEUE_UI_TESTS=1` is set for that run. `cleanup TEST` removes only the exact owned sanity session.

The existing-server launch regression is covered by creating an unrelated legacy session before the first task pane. Provider sanity checks must verify an actual Codex session UUID and readiness, rather than treating a live shell or usage-wrapper PID as success. Run the live-agent test suite before committing launch changes or handing them over for manual assessment.

```sh
ECC_FOCUS_QUEUE_LIVE_AGENT_TESTS=1 swift test --filter liveManagedProviderSanity
```

This runs the same New Agent model action for all four worktree and initialization combinations with the installed Codex command. It checks a real response, exact UUID capture, detach/reopen, stopped-conversation resume, and isolated persistence. Only terminal rendering is replaced by a headless tmux control client; mouse/keyboard automation stays disabled.

The project hierarchy, worktree lifecycle automation, broader hotkeys and orchestrator policy enforcement remain in the [roadmap](FOCUS_QUEUE_ROADMAP.md).
