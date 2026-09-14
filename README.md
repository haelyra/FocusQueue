# ECC Focus Queue

A macOS operator panel that projects a local JSON task dashboard into an
always-on-top, all-Spaces queue. First launch offers a setup wizard with an empty
queue or an existing workspace. New Agent offers a checked-by-default tmux option so sessions can be reattached from
another device through SSH over Tailscale while execution stays on the original Mac. It can also launch a terminal-owned session without tmux.

The current target is a private macOS beta. See [the beta handoff](Docs/LAUNCH_BETA.md)
for compatibility, installation, reconnect instructions and remaining public-launch gates.

## Reliable session recall

With **Keep this agent running in tmux** checked, Focus Queue creates the agent inside its dedicated tmux server and stores
the exact server, session, pane and process identity on the named subtask before
opening a terminal view. Closing WezTerm disconnects the view while the tmux
process continues. Clicking the subtask focuses an existing attached client or
opens a new client attached to that exact runtime. With the option unchecked,
Focus Queue stores the exact WezTerm pane and socket; closing that terminal ends the live session.

Recall does not run `codex resume`, scan provider transcripts, or open a blank
shell. Entries without an app-created saved runtime explain that they cannot be
reopened. A stopped or replaced runtime identity also fails closed. Provider session
IDs remain useful history metadata after the provider reports them, but they do
not authorize process reconstruction.

New launches write structured phase-by-phase diagnostics under
`Application Support/ECC Focus Queue/logs/agent-launches`. The document icon beside
each named subtask opens its launch log. tmux launch confirmation waits for the
user's shell and provider wrapper to settle, then requires three identical pane
process observations before saving the runtime.

For read-only diagnostics outside a terminal pane:

```sh
focus-queue-session diagnose ECC-035
```

The diagnostic reports the responding socket, observed panes, saved directories,
and verified live associations. It neither opens terminals nor reads message
content. Heartbeat activity and live process availability are separate facts;
subtask cards show when progress was last reported.

## Shipping preparation

Agent updates open their own detail panel with the full recorded summary, completion
verdict, verifier output, task conversation, and context links. The notification
keeps the event visible while acknowledging only its own completed subtask.

Click a task title to view its associated sessions. The task-details disclosure
sits below the agents. **View Central Plan** is a bordered button, and **Context,
evidence & links** appears near the task summary. Local Markdown links open
reusable document tabs inside the plan viewer. The **Type** menu opens the agent's
response so pending changes and failures remain visible.

**Browse terminals** lists open WezTerm windows and panes, supports filtering, and
checks the selected pane before activating it. Bulk terminal closure remains a
release follow-up because a saved transcript cannot recover every running program
or unsaved shell state.

Telegram currently reads an agent conversation archive. Personal inbox access and
account switching require a separate authenticated connector. The optional active
archive reader and offline connector diagnostic have fixture coverage; local
archive access still needs verification. Public release preparation also includes
portable setup, installer recovery, host-enforced agent permissions, signing,
clean-account validation, and support policies.

## Task orchestration

Tasks now lead with a short explanation, an expandable **Central plan**, progress,
and named subtask rows. Click a subtask to focus or resume its agent; use **New
agent** to choose an assignment and provider. **Attach** can associate an existing
session with an unassigned subtask. Right-click a subtask to rename it. Its working
indicator requires a fresh progress report and expires after five minutes; a green
dot indicates an unread completion. Task type menus support ordinary tasks, long
running work, subtasks, and customer concerns requiring human review.

The central Markdown plan renders inside the expanded panel with a task-specific
orchestrator conversation beside it, extending inward across the screen. Drag the
divider to balance document and chat widths. Supporting plans are available from the document
menu. In view mode, highlight plan text and begin typing to move that selection and
the first typed character into the orchestrator composer. Click or keyboard-activate
a Mermaid diagram to select its source as context. The selection remains visible as
a removable context card and is retained with the sent conversation. Heading links
scroll within the document; local Markdown links reuse document tabs, and validated
external links continue through the app opener.

Mermaid uses the same pinned renderer as ECC Plan Canvas and falls back to its readable
source when rendering is unavailable. Set `ECC_PLAN_CANVAS_MERMAID_URL` to an HTTPS or
loopback mirror when required. Plan-authored JavaScript remains disabled; the selection
bridge and optional renderer run in WebKit's isolated app content world.

Plans, conversation history, saved edit drafts, subtask state, and snapshots
live under Application Support in `tasks/<ticket-id>/`. Each task worktree has a
`.focus-queue/<ticket-id>/` pointer and live plan link. The central store survives
worktree removal; each plan remains accessible from completed tasks. Conflicting
editor and agent changes preserve the draft for reconciliation.

With initialization enabled, agents receive the context location and these short progress commands at launch:

```text
focus-queue-session context ECC-035
focus-queue-session add ECC-035 codex "Implement report history"
focus-queue-session progress ECC-035 <subtask-id> working "History persistence verified"
focus-queue-session complete ECC-035 <subtask-id> "Implemented; focused tests passed"
```

Manual completion starts the bounded verifier for the task or subtask. Missing
evidence stays visible in the queue. Cleanup archives first and removes only
app-created, clean, merged worktrees with all subtasks complete. Ignored private
files, changed branches, and unmerged commits block removal. Existing user-owned
workspaces and Git branches are retained. Merge through the repository's review
process before retrying a blocked cleanup.

Daily run status appears above the queue, including failures and unread reports.
The report panel and Settings both provide history, execution receipts, and recent
logs. Viewing old reports leaves the latest unread notification intact. Run state
survives restart and checks the worker lock before declaring interruption.

Mail diagnostics distinguish true Apple Events approval denial from mailbox scope,
timeouts, and sandbox process-inspection errors. The approved identity is **ECC
Focus Mail Reader**; legacy applet or Python permission entries are separate.

See [the redesign plan](Docs/ORCHESTRATION_PLAN.md) for architecture, acceptance
checks, implementation decisions, and public-launch follow-ups.

New agent uses your zsh or bash interactive login shell, including your provider
aliases, functions, flags, and terminal wrappers. The optional shell diagnostic
can inspect known profile declarations without executing them. Base installation
does not inspect shell profiles. Bash follows its normal login-profile rules;
other shells currently fall back to zsh.

Turn off **Send task initialization prompt** to open a normal interactive session
without submitting a message. The task worktree and context access remain set up,
and the prompt choice is remembered both in the dialog and for that subtask's
future opens. Background reports and completion checks keep their bounded
execution settings, independent of interactive aliases.

## What works

- Native SwiftUI and AppKit floating panel with upper-left, upper-right, and
  active-display center placement.
- A highly translucent outer panel with fully opaque notification cards, a
  top-five focus list, and one bottom control for the daily checklist and
  remaining queue. Tasks can be dragged between Today's focus and Rest of queue,
  with the override stored only on this Mac.
- Persisted Light and WezTerm-matched Dark appearances, plus Muted, Pastel, No
  Color, and Vibrant accent palettes for status, priority, sync, and review
  indicators.
- A quick settings screen for appearance, accent palette, left, center, or
  right placement, and the daily report schedule, platforms, and token budget.
- An interactive daily message report that expands inward from the queue edge.
  It shows per-platform new and checked counts, expandable message summaries,
  source and task links, the overall run summary, and exact observed Codex token
  use. A processed-message ledger prevents routine runs from classifying the
  same message twice.
- Missed schedules create one durable approval request for the day and a macOS
  notification with **Run report** and **Not today** actions. The approval is
  also shown inside the queue when the app opens.

The current local build delivers the approval notification to the Mac. Phone
delivery needs a chosen push provider or companion client, neither of which is
configured in this repository. The versioned JSON approval file is the portable
handoff contract for that future relay, so phone support will not require a
rewrite of the scheduler or report engine.
- A collapse control that shrinks the actual window and hitbox to a 52×44 FQ
  button, plus native minimization to the Dock and Dock reopen.
- A stationary panel with placement controlled from the menu bar rather than by
  accidental background dragging.
- The last display is stored by its stable macOS display identifier. Startup and
  monitor-change checks restore that display when connected, otherwise use the
  main display, and always clamp the panel inside the visible frame.
- A full-height screen-edge layout with scrolling for expanded details and the
  remaining queue.
- Login launch through a per-user LaunchAgent, plus a menu-bar recovery menu.
- Two-second dashboard refresh with source errors shown without discarding the
  last good snapshot.
- Daily routines stored locally and reset by local calendar day.
- Priority-sorted, expandable ticket cards with source-backed steps, PR state,
  evidence links, next action, and definition of done.
- A Completed tab for today's resolved and cancelled tasks, with lazily paged
  access to older completions and a documented path to a source-backed archive.
- A Queue chat tab backed by the persistent `ecc-focus-queue-codex-v1` Codex
  thread. It can explain order, answer task questions, and perform explicitly
  requested wording or link changes before the dashboard refreshes. Unsent
  drafts survive tab changes for the life of the app, and the composer grows
  upward for long messages while preserving transcript space.
- Verified read-only Queue chat access to `haley@ecc.tools`, including search,
  full-message read, and explicit Apple Mail open operations. Every displayed
  mail answer must match a fresh local proof receipt containing the connector,
  account, operation, retrieval time, and stable message identifiers. Missing
  or stale evidence causes the entire answer to be withheld.
- Recurring weekly PR-resolution tasks use live GitHub CLI activity for a
  progress-first card. The daily target adapts from zero through 5, 10, or 15,
  the weekly target spans five workdays, and resolved PR disclosures include
  merged or closed details. A zero backlog moves the task to the bottom locally.
- Local `vscode://file` links are normalized before opening. Markdown files are
  rendered as styled HTML in the default browser, while PDFs are sent to Preview
  with Safari or the system default used as fallbacks.
- WezTerm lookup by ticket label and exact worktree, with ambiguous matches
  rejected instead of focusing an unrelated pane.
- Clicking an agent's subtask raises and glides the selected WezTerm window to the center
  of the full display, keeping the task list visible and interactive. One
  full-screen dimming window is ordered below the terminal and queue and above
  the rest of the desktop, avoiding seams around either foreground window.
  Clicking the backdrop, the floating close control, or **Exit Terminal Focus**
  in the menu bar exits terminal focus.
- The queue header's display button moves the queue itself to the next connected
  display. The selected terminal remains on its current display.
- Agents register themselves with
  `focus-queue-session attach <TICKET-ID>`. The helper reads the provider
  session ID, app-created runtime, and working directory directly from the agent
  environment, labels the exact terminal, and immediately notifies the running app. A
  task can retain multiple agents, displayed through readable named assignments.
- Clicking an agent's descriptive subtask title focuses or reattaches the exact
  saved runtime. Direct sessions can be focused only while their original pane remains open. The app never substitutes a blank terminal or a provider
  history command. **Manage agents** can remove one association or clear the
  current agent queue after its state has been retained in durable history.
- Restart-safe completion requests. A checkbox asks a bounded Codex run
  session to verify evidence and never directly edits the ticket status.
- Atomic local state and bounded verifier logs under Application Support.

## Queue ordering and chat

The app, not an agent, computes the normal open-task order by priority, then
`updatedAt`, then task ID. A drag from Today's focus to Rest of queue creates a
local deferred-task override without changing priority in the canonical
dashboard. Dragging that task back removes the override and restores canonical
ordering.

Queue chat resumes a bounded, named Codex thread with the current visible order
and local overrides in its prompt. Questions are read-only by default. Codex is
allowed to edit the canonical dashboard only when the message directly requests
the exact change, such as rewording a field or adding a link. It is instructed
not to resolve or cancel tasks or invent completion evidence. Mail questions use
the ECC `focus-mail` connector, never Himalaya. The app independently verifies
the current-turn proof before displaying a mail response.

Queue chat can also run the report for selected platforms, for example “Run my
daily report for Discord and email.” The app recognizes that narrow imperative,
runs the report worker itself with allowlisted arguments, and displays only the
exact report ID and date returned by the host process. Message text cannot
self-attest a successful run. Rechecking a processed message requires an
explicit, non-negated request.
Selected-platform chat runs remain in report history, return in chat, and stay
available in the panel for that app session. They do not replace the persisted
latest comprehensive report used by the once-a-day scheduler.

## Build and install

```bash
swift test
Scripts/install.sh
```

Source installation requires Swift 6.2 or later and Python 3.9 or later on macOS 14+.
The installer targets the current user's Applications and `.local/bin` directories,
preserves configuration, stages and verifies the new bundle, retains backups, and
restores prior files if installation or startup fails. `Scripts/install.sh --check`
performs a read-only preflight of an already built bundle. Use `--login` for a login
LaunchAgent and `--desktop` for a shortcut. Existing choices are retained on upgrade.
Mail and scheduled-agent installation are separate developer workflows.

`zsh Scripts/package-release.sh` creates a private-beta ZIP and SHA-256 checksum.
The packaged app can be dragged into Applications and needs neither Xcode nor Python
for its native setup wizard. Its optional managed installer uses Python.
Builds use an ad hoc signature unless `ECC_FOCUS_QUEUE_SIGN_IDENTITY` is supplied.
Developer ID signing alone does not complete notarization or public qualification.

The first launch requests Documents-folder access so the app can read the local
dashboard. The first use of **View Agent** requests Accessibility access so
the app can center and raise the selected WezTerm window. The local build uses
a stable designated requirement so both permissions survive later app rebuilds.
The local WezTerm configuration exposes explicit mux window titles to macOS
Accessibility so the app can select the ticket-labeled native window precisely.

## Desktop and menu-bar management

Installation with `--desktop` creates a Desktop launcher pointing to the installed
app. Double-click it to launch the queue
after quitting or to reveal the existing panel. The checklist icon in the macOS
menu bar provides Show, Hide, Restart, placement, Open Config, and Quit actions.
While terminal focus is active, it also provides **Exit Terminal Focus**.
The Desktop item is a launcher, so the installed app and its login service keep
one canonical location under the user's Applications and LaunchAgents folders.

## Configuration

Use **Settings > Open setup wizard** to choose a workspace, validate the dashboard,
review terminal capabilities, install the session helper, and opt into tmux for new
agents. Existing settings are backed up before saving. The wizard can list persistent
sessions and copy SSH reconnect commands. It does not enroll Tailscale devices or
configure SSH access. Advanced settings live in the current user's Application Support
directory. The example configuration is a generic template; the ECC configuration
remains a developer-specific fixture and is not seeded by installation.
All process arguments are passed directly to `Process`; task content is never
assembled into a shell command.

The `dailyReport` object sets `scheduleHour`, `scheduleMinute`, `maximumTokens`,
and `enabledPlatforms`. The report engine is Python plus JSON so its scheduling,
deduplication, task linkage, and approval contracts can be reused by a future
Windows host. Swift is limited to the current macOS panel and notification
bridge. The token budget is enforced conservatively before classification;
because the Codex CLI reports final usage only after a turn, an unexpected
overage is recorded prominently in the report rather than hidden.
Successful report history is retained for 90 days. The deduplication ledger
keeps only stable source identifiers and report metadata, not message bodies.
Raw live-run source bundles exist only in a crash-recovery journal and are
deleted after the report commits.

The expected dashboard object has a top-level `tickets` array. Ticket fields
consumed by the app are `id`, `title`, `category`, `priority`, `status`,
`summary`, `next`, `doneWhen`, `updatedAt`, optional `completedAt`, optional
`completion` facts (`outcome`, `reason`, `resolutionPrs`, `evidence`, and
`completedBy`), `worktree`, `resolutionPrs`, `prs`, `links`, and optional
`steps`. Completed cards keep the same expandable source-backed details as open
cards; absent completion facts are not inferred or written by the app. Recurring tasks may also
set `taskType` to `recurring` and provide `recurrence.kind`,
`recurrence.cadence`, and `recurrence.repository`. Weekly PR-resolution titles
remain compatible when this metadata has not been emitted yet.

## Completion authority

Checking a ticket creates a local review record and starts:

```text
focus-queue-codex run --workspace /Users/hira/Documents/ECC \
  --prompt-file <local-prompt> --timeout 120 --sandbox workspace-write \
  --label ecc-focus-queue-codex-verifier
```

There is no `--yolo` or network listener. The completion checkbox path does not
mutate the dashboard. A task disappears only when a later dashboard refresh
reports `resolved` or `cancelled`; Queue chat can edit other canonical fields
only after an explicit user request.

## Focus Queue agent

The dedicated Codex Queue harness performs a read-first daily reconciliation
across the ECC Discord server, the configured Telegram archive transport,
`haley@ecc.tools` through Apple Mail, and new ECC GitHub issues. The running Focus
Queue app starts it at the configured local time from an installed automation copy; the old
standalone LaunchAgent and Hermes cron are paused. It
refreshes deterministic PR facts before a read-only Codex classification step
and applies only schema-valid, source-linked task proposals. External replies
and source-system mutations remain disabled. See
[`Docs/FOCUS_QUEUE_AGENT.md`](Docs/FOCUS_QUEUE_AGENT.md) for coverage,
permissions, safety rules, and operator commands.

## Uninstall

Run `Scripts/uninstall.sh --check` to preview, then `Scripts/uninstall.sh` to move
verified, manifest-owned installation files into a retained backup. Modified or
unrecognized files are preserved and reported. Configuration, task data, history,
logs, tmux sessions and separately installed companion services remain available.
