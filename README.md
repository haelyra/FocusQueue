# ECC Focus Queue

A local-only macOS operator panel that projects a JSON task dashboard into an
always-on-top, all-Spaces queue. The starter configuration reads Hira's ECC
dashboard, but the app is a standalone personal tool and is not part of ECC.

## What works

- Native SwiftUI and AppKit floating panel with upper-left, upper-right, and
  active-display center placement.
- A highly translucent outer panel with fully opaque notification cards, a
  fixed top-five focus list, and one bottom control for the daily checklist and
  remaining queue.
- Persisted Light and WezTerm-matched Dark appearances, plus Muted, Pastel, No
  Color, and Vibrant accent palettes for status, priority, sync, and review
  indicators.
- A quick settings screen for appearance, accent palette, and left, center, or
  right placement.
- A collapse control that shrinks the real window to the ECC Focus Queue title
  and restores the full-height panel from the same screen edge.
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
- Local `vscode://file` links are normalized before opening, with PDFs sent to
  Preview and Safari or the system default used as fallbacks.
- WezTerm lookup by ticket label and exact worktree, with ambiguous matches
  rejected instead of focusing an unrelated pane.
- **Focus terminal** raises and glides the selected WezTerm window to the center
  of the queue's display, hides the queue, and dims every region outside the
  terminal. A floating **Switch Monitor** button cycles the focused terminal
  through connected displays and rebuilds the backdrop around it. Clicking the
  backdrop, the floating close control, or **Exit Terminal Focus** in the menu
  bar returns to the queue.
- When no pane is associated, Focus terminal creates a new WezTerm window in
  the exact task directory and labels its tab with the ticket ID.
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

The first launch requests Documents-folder access so the app can read the local
dashboard. The first use of **Focus terminal** requests Accessibility access so
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
