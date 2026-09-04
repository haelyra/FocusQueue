# ECC Focus Queue

A local-only macOS operator panel that projects a JSON task dashboard into an
always-on-top, all-Spaces queue. The starter configuration reads Hira's ECC
dashboard, but the app is a standalone personal tool and is not part of ECC.

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
- A collapse control that shrinks the real window to the ECC Focus Queue title
  and restores the full-height panel from the same screen edge.
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
- **View Agent** raises and glides the selected WezTerm window to the center
  of the full display, keeping the task list visible and interactive. One
  full-screen dimming window is ordered below the terminal and queue and above
  the rest of the desktop, avoiding seams around either foreground window.
  Clicking the backdrop, the floating close control, or **Exit Terminal Focus**
  in the menu bar exits terminal focus.
- The queue header's display button moves the queue itself to the next connected
  display. The selected terminal remains on its current display.
- Agents register themselves with
  `focus-queue-session attach <TICKET-ID>`. The helper reads the provider
  session ID, WezTerm pane, and working directory directly from the agent
  environment, labels the tab, and immediately notifies the running app. A
  task can retain multiple agents, and its picker lists each tab title followed
  by the full session ID.
- **Attach Agent** uses a fast process scan as a recovery path for sessions that
  were started before registration was installed or whose registration was
  missed. It correlates WezTerm panes and OS processes by TTY, then reads each
  process's open transcript or session lock to recover the exact session UUID.
- **View Agent** focuses the pane that owns the saved session UUID. If that
  conversation is no longer running, it opens a new WezTerm window in the saved
  directory and invokes `codex resume <session-id>` or
  `claude --resume <session-id>`. Agent associations can be removed with a
  deliberate double-click on their trash controls.
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

The app installs at `/Users/hira/Applications/ECC Focus Queue.app`. Its login
item is `/Users/hira/Library/LaunchAgents/com.haelyra.ecc-focus-queue.plist`.
Runtime files live under
`/Users/hira/Library/Application Support/ECC Focus Queue/`.

The first launch requests Documents-folder access so the app can read the local
dashboard. The first use of **View Agent** requests Accessibility access so
the app can center and raise the selected WezTerm window. The local build uses
a stable designated requirement so both permissions survive later app rebuilds.
The local WezTerm configuration exposes explicit mux window titles to macOS
Accessibility so the app can select the ticket-labeled native window precisely.

## Desktop and menu-bar management

Installation also creates `/Users/hira/Desktop/ECC Focus Queue.app`, a Desktop
launcher that points to the installed app. Double-click it to launch the queue
after quitting or to reveal the existing panel. The checklist icon in the macOS
menu bar provides Show, Hide, Restart, placement, Open Config, and Quit actions.
While terminal focus is active, it also provides **Exit Terminal Focus**.
The Desktop item is a launcher, so the installed app and its login service keep
one canonical location under the user's Applications and LaunchAgents folders.

## Configuration

Edit `~/Library/Application Support/ECC Focus Queue/config.json` and use the
menu-bar item's **Open Config** command. `Config/config.example.json` is a
copyable generic template; `Config/ecc.config.json` is the local ECC starter.
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
`summary`, `next`, `doneWhen`, `updatedAt`, optional `completedAt`, `worktree`,
`resolutionPrs`, `prs`, `links`, and optional `steps`. Recurring tasks may also
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

Run `Scripts/uninstall.sh`. It moves the app and LaunchAgent to the Trash and
preserves local config, state, review artifacts, and logs.
