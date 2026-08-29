# ECC Focus Queue

A local-only macOS operator panel that projects a JSON task dashboard into an
always-on-top, all-Spaces queue. The starter configuration reads Hira's ECC
dashboard, but the app is a standalone personal tool and is not part of ECC.

## What works

- Native SwiftUI and AppKit floating panel with upper-left, upper-right, and
  active-display center placement.
- Layered translucent surfaces with a lightly frosted outer panel, more opaque
  notification cards, a fixed top-five focus list, and one bottom control for
  the daily checklist and remaining queue.
- A stationary panel with placement controlled from the menu bar rather than by
  accidental background dragging.
- A full-height screen-edge layout with scrolling for expanded details and the
  remaining queue.
- Login launch through a per-user LaunchAgent, plus a menu-bar recovery menu.
- Two-second dashboard refresh with source errors shown without discarding the
  last good snapshot.
- Daily routines stored locally and reset by local calendar day.
- Priority-sorted, expandable ticket cards with source-backed steps, PR state,
  evidence links, next action, and definition of done.
- WezTerm lookup by worktree, pane focus, and tab creation when no pane matches.
- Restart-safe completion requests. A checkbox asks a bounded named Hermes
  session to verify evidence and never directly edits the ticket status.
- Atomic local state and bounded verifier logs under Application Support.

## Build and install

```bash
swift test
Scripts/install.sh
```

The app installs at `/Users/hira/Applications/ECC Focus Queue.app`. Its login
item is `/Users/hira/Library/LaunchAgents/com.haelyra.ecc-focus-queue.plist`.
Runtime files live under
`/Users/hira/Library/Application Support/ECC Focus Queue/`.

## Desktop and menu-bar management

Installation also creates `/Users/hira/Desktop/ECC Focus Queue.app`, a Desktop
launcher that points to the installed app. Double-click it to launch the queue
after quitting or to reveal the existing panel. The checklist icon in the macOS
menu bar provides Show, Hide, Restart, placement, Open Config, and Quit actions.
The Desktop item is a launcher, so the installed app and its login service keep
one canonical location under the user's Applications and LaunchAgents folders.

## Configuration

Edit `~/Library/Application Support/ECC Focus Queue/config.json` and use the
menu-bar item's **Open Config** command. `Config/config.example.json` is a
copyable generic template; `Config/ecc.config.json` is the local ECC starter.
All process arguments are passed directly to `Process`; task content is never
assembled into a shell command.

The expected dashboard object has a top-level `tickets` array. Ticket fields
consumed by the app are `id`, `title`, `category`, `priority`, `status`,
`summary`, `next`, `doneWhen`, `updatedAt`, `worktree`, `resolutionPrs`, `prs`,
`links`, and optional `steps`.

## Completion authority

Checking a ticket creates a local review record and starts:

```text
hermes chat --quiet --continue ecc-focus-queue-verifier --create-if-missing \
  --in /Users/hira/Documents/ECC --source tool --checkpoints \
  --max-turns 24 --run-budget 120 --query-file <local-prompt>
```

There is no `--yolo`, no network listener, and no dashboard mutation in the app.
The task disappears only when a later dashboard refresh reports `resolved` or
`cancelled`.

## Uninstall

Run `Scripts/uninstall.sh`. It moves the app and LaunchAgent to the Trash and
preserves local config, state, review artifacts, and logs.
