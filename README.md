# Focus Queue

A macOS operator panel that projects a local JSON task dashboard into an
always-on-top, all-Spaces queue. First launch offers a setup wizard with an empty
queue or an existing workspace. New Agent offers a checked-by-default tmux option so sessions can be reattached from
another device through SSH over Tailscale while execution stays on the original Mac. It can also launch a terminal-owned session without tmux.

Focus Queue is in public beta. See [the beta handoff](Docs/LAUNCH_BETA.md)
for compatibility, reconnect instructions and remaining launch gates.

## Install (beta testers)

These steps were tested on a clean macOS 26.6 Apple silicon Mac.

### 1. Requirements

- An Apple silicon Mac (M1 or later) with macOS 14 or later. The beta build is arm64 only.
- [Homebrew](https://brew.sh). The installer uses it to add tmux, and the GitHub CLI
  (`gh`) for beta reports, if they are missing. If Apple's Command Line Tools (`git`,
  `python3`) are missing, the installer opens Apple's installer; run it again afterwards.
- Nothing extra for your terminal. Focus Queue uses macOS Terminal by default. Ghostty and
  WezTerm also work if you already have them.
- At least one agent CLI on your own subscription. Claude Code:
  ```sh
  curl -fsSL https://claude.ai/install.sh | bash
  ```
  Codex and Kimi Code also work. You can sign in from the app's walkthrough.

### 2. Download and install

1. Download `FocusQueue-0.3.5-beta-arm64.zip` from the
   [latest release](https://github.com/haelyra/FocusQueue/releases).
2. In Terminal, unpack it and run the installer:
   ```sh
   cd ~/Downloads
   ditto -x -k FocusQueue-0.3.5-beta-arm64.zip .
   xattr -dr com.apple.quarantine "Focus Queue Beta"
   "Focus Queue Beta/Install.command" --desktop
   ```
   The beta is not notarized yet. The `xattr` line clears the download flag so macOS
   lets the app open. Run it only on a ZIP you downloaded from this repository.

The installer puts the app in `~/Applications/Focus Queue.app`, the
`focus-queue-session` helper and Q chat launchers in `~/.local/bin`, and a Desktop shortcut. It does not
need GitHub access. Add `--login` to start Focus Queue at login, or `--check` for a
read-only preflight.

### 3. First launch

Focus Queue opens as a panel and a menu-bar item. The walkthrough guides you through:

1. Choosing your terminal (pick Ghostty if you followed step 1).
2. Choosing your default agent and signing in to its subscription.
3. Creating your first project: a name, a 2 to 5 letter task prefix, and a working folder.
4. Launching your first agent from **+**: type what you want and press ⌘↩.

Open **Settings** (gear) > **Projects** > **Open setup wizard** later to change the
workspace, terminal or tmux path. The wizard's **Install command-line helper**
reinstalls `focus-queue-session` if it is missing.

Lasting instructions in a prompt, such as "end every reply with a 🐡", are saved to
that project's `data.md`, so every later agent in the project follows them. Turn this
off under **Settings** > **Task placement** > **Save durable facts from prompts**.

### Update or uninstall

- **Update:** from 0.3.2 on, open **Settings** > **Updates** and click **Install update** when a new release is
  offered. Older versions: download the newer ZIP and repeat step 2. Your projects, tasks and settings are kept.
- **Uninstall:** run `"Focus Queue Beta/Uninstall.command"`. It moves the installed
  files to a backup and leaves your task data in place.

Report bugs and feedback in [GitHub Issues](https://github.com/haelyra/FocusQueue/issues),
or from the info (ⓘ) menu in the app.

## Projects

The project menu switches complete queue workspaces. Each project owns its dashboard,
workspace, optional Git repository, and 2 to 5 character task prefix. Focus Queue
uses `FOC-###`; the built-in fallback project uses `OTH-###`. Selection survives
relaunch and scopes tasks, completed history, notifications, ordering, and queue chat.

**Settings > Projects** adds or edits a project. Repository aliases can identify
other clones or forks. A manual Codex launch is matched from its Git common directory,
so a launch from a project checkout or one of its worktrees is routed to that project.
An unmatched launch goes to **Other** instead of being left untracked.

Every launch receives a private placement capsule under the Focus Queue support
directory. The launcher and app use it to share only the resolved project, task,
workspace, tmux identity, and plan pointers. Project source and worktrees remain next
to the configured repository, never under Application Support.

## Document questions

New document chats default to **Ephemeral reader**. It answers questions using the
selected document, task summary, central plan, and recent chat messages. Each turn
starts fresh without the creating agent's conversation or queue-management prompt.
The reader can read and search; it cannot edit files. Codex uses `gpt-6-luna` at low
effort, Claude uses `haiku`, and Kimi uses `kimi-code/k3.1-pro-highspeed`.

Choose a different provider, model, or effort before sending. **Use creator's model**
copies the author's model settings while keeping the reader's fresh context and
tool limits. **Creating agent fork** continues the live author's conversation in
a separate fork, and **New agent** retains the general agent workflow. Existing
chats keep their recipient; **Clear Chat** lets you choose another one.

The headless live reader check uses three provider requests to verify document/task
context, tool-based reading, and edit refusal:

```sh
ECC_FOCUS_QUEUE_LIVE_DOCUMENT_TESTS=1 swift test --filter liveDocumentReaderSanity
```

Set `ECC_FOCUS_QUEUE_DOCUMENT_PROVIDER=claude` or `kimi` to check those providers.
This check does not open or control the app UI.

## Reliable session recall

New tmux agents share one session per task. **Sessions** shows a live pane map with
drag-and-drop swaps, worktree grouping and manual layout control. Automatic layout
uses the terminal's actual size, keeps up to four readable panes together and adds
tmux tabs when needed. Pinned tmux-resurrect and tmux-continuum are bundled for
automatic layout saves, including while detached. See the [session organizer](Docs/TMUX_ORGANIZER.md)
for controls, terminal options and recovery limits, and the [roadmap](Docs/FOCUS_QUEUE_ROADMAP.md)
for the remaining project and orchestration work.

Codex sessions started outside **New Agent** are also detected by their exact
process-owned session UUID. Clear task associations join the task's agent list;
ambiguous sessions appear under **Agents to place** in the terminal browser. Its
queue-header count makes unplaced agents visible. Assigning a task keeps the
conversation and preserves your queue order. Cleared assignments stay cleared
until you explicitly attach the session again.
The optional [Codex shell entry](Docs/CODEX_TMUX_ENTRY.md) starts interactive
Codex sessions in tmux while retaining existing command flags and the usage bar.
The [Claude shell entry](Docs/CLAUDE_TMUX_ENTRY.md) provides the same routing
for `claude`, with hook-based session registration as its canonical identity
path.

With **Open in tmux** checked, Focus Queue saves the exact runtime before opening
its terminal view. Closing the view leaves tmux running. Direct launches save the
WezTerm pane and socket. Clicking an agent focuses the live runtime; when that
runtime is confirmed closed, the app starts `codex resume <session-id>` or
`claude --resume <session-id>` in its saved workspace through your login-shell
command preferences. Initialization is never replayed during resume. A stopped
tmux agent without a saved provider conversation requires a fresh assignment. Ambiguous
transport failures do not create duplicate processes.

Each assignment records its workspace path, repository, branch, base commit,
worktree ownership, and previous workspace locations independently of the task's
current workspace. **Create worktree** creates a separate branch for that agent
from the selected checkout's exact commit. A dirty source requires committing
first or choosing the existing checkout. Branch mismatches on resume require an
explicit workspace correction instead of silently switching another agent's branch.

Task cards keep **Subtasks** and **Agents** in separate disclosures. Each subtask
and each agent has its own three-dot menu. Removing an agent preserves its subtask,
provider conversation ID, and workspace history. Deleting a subtask removes its
exclusive agents after confirmation while preserving the archived task-context
snapshot; shared agents remain attached to their other assignments. Completed
agents leave the active list automatically and verified runtimes are closed.
Cleanup retains dirty, ignored, unmerged, or shared worktrees; clean merged
app-owned worktrees can be removed while branches and context remain recoverable.
**Mark as complete…** records a confirmed completion and leaves the parent task
unchanged.

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
verdict, verifier output, task conversation, and context links. Opening an update
acknowledges only its own completed subtask.

The info button to the right of Settings opens help: documentation, the GitHub
repository, the walkthrough replay, and **Send feedback…**. Feedback opens a
prefilled GitHub issue from `.github/ISSUE_TEMPLATE/feedback.yml`, which labels
every report `feedback` and `triage`. Destinations live in `QueueHelpLinks`
(`Sources/ECCFocusQueue/QueueHelpMenu.swift`); an unset link shows as coming soon.

Click a task title to view its associated sessions. Descriptions start collapsed
for existing tasks and expanded for new unviewed tasks. A **NEW** badge beside the
title marks a task created after Focus Queue first loaded its project dashboard
and clears once you open, expand, or inspect the task. Right-click **View details**
for dates, agent counts, activity, and usage metadata. The full task-details
disclosure sits below the agents. **View Central Plan** is a bordered button, and
**Context, evidence & links** appears near the task description. Local Markdown
links open reusable document tabs inside the plan viewer. The **Type** menu opens
the agent's response so pending changes and failures remain visible.

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

Marking a task complete closes its open completion-tracked work items, then resolves it
in the dashboard. Cleanup archives first and removes only
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

**New Agent** on a task immediately opens a promptless Codex conversation in a
new isolated worktree and that task's shared tmux session. The first submitted
prompt replaces its generated `Agent N` identity with a short title and
one-sentence description. The configured agent sheet retains its wrapping work
description editor, initialization checkbox, expandable preview, and planned
workspace and branch. Turning initialization off sends no provider prompt.

Initialized agents are instructed to call `focus-queue-session review-push
<TASK-ID> <SUBTASK-ID>` before an authorized push. The read-only orchestrator scan
returns a commit-specific receipt and concrete correction instructions. Rejection
returns a failing status to the calling agent, which must correct its changes and
retry. A checkout change during review invalidates acceptance. This is an agent
workflow gate; it does not install or replace Git hooks or grant push permission.
Use `focus-queue-session workspace <TASK-ID> <SUBTASK-ID> <absolute-path>` only to
record the first workspace or refresh metadata for that exact path. Workspace
ownership is immutable after assignment; create a new agent for a different
checkout.

Feature branches are development lanes, not deployment lanes. Agents commit and
hand off their branches for review. After merge and remote synchronization, a
clean checkout at the exact `origin/main` revision may build and replace the
shared app. The bundle carries signed source provenance, and the installer
rejects missing, dirty, older, divergent, feature-branch, or foreign-repository
builds before stopping the installed app. During local development the app uses
ad-hoc signing, so this is an accidental-overwrite guard, not a defense against
a malicious same-user process. Public releases must use a CI-produced Developer
ID signed and notarized artifact.

See [Git delivery safety](Docs/GIT_DELIVERY_SAFETY.md) for the authoritative
checkout, integration, branch-protection, and recovery rules.

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
- Verified read-only Queue chat access through the selected Apple Mail or Gmail
  provider, including search and full-message read. Apple Mail also supports an
  explicit open operation. Gmail uses provider-native OAuth and automatic token
  refresh without Apple Mail, Apple Events, or Full Disk Access. Every displayed
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
- Clicking an agent's descriptive subtask title focuses and centers the activated
  window or resumes the saved provider conversation after that runtime ends.
  **Manage agents** removes associations while retaining assignment and conversation history.
- Restart-safe completion requests. A checkbox asks a bounded Codex run
  session to verify evidence and never directly edits the ticket status.
- Atomic local state and bounded verifier logs under Application Support.

## Queue ordering and chat

The queue offers five ordering modes. **Recent activity**, the default, puts tasks
created or worked on by an agent (a prompt or agent output) in the last two days
first, newest first, and orders every other task by priority. **Recent interaction** puts the tasks whose
agents you prompted most recently first, using provider hooks or, when hooks are
off, prompts read from the Codex and Claude transcripts. **Recent output** uses the
latest actual agent output,
**Triage deadlines** orders by hard and relative deadlines, and **Manual order**
uses your saved sequence. Activity modes use deadline triage for the remaining
tasks. Drag a task onto the upper or lower half of another card, or use the card
menu's Move actions, to switch to Manual order. Moving a task preserves the
relative order of all other tasks. **Restore default order** clears that override
and returns to Recent activity.

Hard due dates stay visible on cards. Open non-recurring tasks without one receive
a rough triage target from the latest activity plus 1 day for critical, 2 for high,
4 for medium, or 7 for low priority. Relative targets appear only in task details
and are not commitments. Right-click **View details** for start and due dates,
agent counts, activity, and available usage data; token totals say **Not recorded**
when no source-backed aggregate exists. New tasks arrive with a **NEW** badge and
an expanded description. Existing descriptions start collapsed, and viewing or
expanding a task clears the badge.

Today's focus displays the first five tasks; Rest of queue displays the rest.
Click the Today's focus heading to search every task in the selected project;
completed tasks follow open ones. Results filter on each keystroke; when no task
holds every keyword, the search retries with close spellings and synonyms. A
code matches with or without its prefix, dash, or leading zeros: `FOC-018`,
`foc 18`, and `18` all find FOC-018. A word that is exactly a status or priority,
such as `blocked`, `in-progress`, or `high`, filters by that field; two values
of one field are alternatives. `status:` (or `is:`) and `priority:` (or `p:`)
accept part of a value, and `status:open` or `status:done` select open or
completed tasks. Esc or the clear button closes the search; clicking elsewhere
drops the cursor and closes an empty one.
Saved positions and the selected ordering mode survive refreshes and restarts.

The orchestrator can reorder tasks at your request using the same local order:

```sh
focus-queue-session queue list
focus-queue-session queue move ECC-035 top
focus-queue-session queue move ECC-029 after ECC-035
focus-queue-session queue reset
```

Order is stored separately under Application Support in `queue-order/order.json`.
The app reloads it automatically. Queue chat has write access to that directory.
The helper uses a lock and atomic writes so app and agent changes share the latest
order without overwriting other app state. Existing deferred ordering is retained
until you move a task or restore triage sorting.

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

## Completed agent terminals

Completing an assignment never stops, replaces, or archives its agent. The
provider keeps running in its pane with its output visible, and its workspace
is retained. Only an explicit action closes a runtime: archiving the agent, or
resolving or cancelling the task. Panes left by older builds that showed a
completion message and resume command are still recognized and protected.

A completed agent stays under **Work items** with a green **New result** status
until you open it. Once seen, it moves to **Completed items**. A new prompt typed
into its terminal returns it to Work items as Working. Task progress counts
also wait until every result is seen.

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

The `focusQueueProjects` array defines each named dashboard and workspace, while
`focusQueueSelectedProjectID` records the working project. Existing configurations with only
`dashboardPath` and `workspacePath` migrate to one selected project without moving
their files. Unrelated legacy `projects` metadata is preserved when settings are saved.

The `dailyReport` object sets `enabled`, `scheduleHour`, `scheduleMinute`,
`maximumTokens`, and `enabledPlatforms`. Disabling it stops automatic and missed-run
processing while keeping manual runs and report history available. The report engine
is Python plus JSON so its scheduling,
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
`summary`, `next`, `doneWhen`, `updatedAt`, optional `createdAt`, optional
`dueDate` and `dueDateSource`, optional `completedAt`, optional `completion`
facts (`outcome`, `reason`, `resolutionPrs`, `evidence`, and `completedBy`),
`worktree`, `resolutionPrs`, `prs`, `links`, and optional `steps`. Hard due dates
come from these canonical fields or an explicit user edit; relative triage
targets are computed locally and never written back as hard deadlines. Completed
cards keep the same expandable source-backed details as open cards; absent
completion facts are not inferred or written by the app. Recurring tasks may also
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
the selected Apple Mail or Gmail provider, and new ECC GitHub issues. The running Focus
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
