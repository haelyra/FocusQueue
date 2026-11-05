# Launch handoff: macOS private beta

TL;DR: Install and first-run setup now support a fresh macOS account. New agents can run inside tmux and reconnect through ordinary SSH over Tailscale. macOS Terminal is the default and needs no install. Ghostty and WezTerm are optional; WezTerm adds pane browsing. Treat this as a private beta candidate until the manual connection and distribution gates below pass.

## The recovered work and current support

Inspected September 13, 2026. The additional `feat/agent-workspace-map` worktree contains an uncommitted visual agent-map study. The setup preview, remote-recall design and broader application work were already in the main checkout. This handoff continues that checkout and preserves the other worktree. Other agents' concurrent changes remain uncommitted and were included in the combined headless verification.

| Capability | Implemented now | Qualification limit |
| --- | --- | --- |
| Install and upgrade | Current-user paths, staged bundle verification, retained backups, failure rollback, ownership manifest, optional login and Desktop shortcut | Hard interruption recovery uses the retained recovery map; clean-account GUI behavior still needs a manual pass |
| First-run wizard | Empty queue or existing dashboard, workspace validation, terminal detection, helper installation, optional tmux path, saved-config backup, reopening from Settings | Provider login and connector accounts remain separate |
| WezTerm | Native agent launch, pane discovery, labels and exact tmux client focus or reattachment | Real provider login and terminal appearance require manual qualification |
| tmux | Checked-by-default New Agent option, dedicated server, create/list/attach, startup identity retry, task registration from tmux | Execution remains on the original Mac; host reboot and server death end running processes |
| Direct terminal | Optional New Agent mode stores and focuses one exact WezTerm pane without provider reconstruction | Closing the terminal ends the live agent; no SSH reconnect or replacement process |
| SSH over Tailscale | Local/SSH reconnect commands, strict known-host checking, keepalives, no agent forwarding | Cross-device login has not been exercised; no remote host enrollment or cross-host migration |
| Terminal.app, iTerm2, Ghostty, kitty | Run the session helper inside their shells to create and attach tmux sessions | Native desktop pane discovery and focus are not implemented or claimed |
| VS Code / Cursor | Same command-line path inside an integrated terminal | Editor pane control remains unimplemented |

The local Tailscale CLI reports `Running` and online. TCP port 22 accepts a local connection. These checks establish local prerequisites, not SSH authentication or connectivity from another device.

tmux preserves server-side processes when clients detach while the host and tmux server remain alive. Reboot requires a separate conversation recovery path. [tmux maintainer documentation](https://github.com/tmux/tmux/wiki/Getting-Started).

The standard Tailscale macOS app uses macOS Remote Login for ordinary incoming SSH. Tailscale's own SSH server supports Linux and the open-source macOS daemon variant. [Tailscale platform requirements](https://tailscale.com/docs/features/tailscale-ssh).

## Install, configure and reconnect

Source builders use Swift 6.2+ and Python 3.9+ on macOS 14+. Run `Scripts/install.sh`; add `--login` and `--desktop` only for those optional features. Existing settings and integration choices are retained. `--check` validates an already built bundle without changing files or services. Mail and scheduled agents are no longer provisioned by base installation.

For the packaged app, drag it into Applications and open it. Native setup needs neither Python nor Xcode. The optional managed installer in the ZIP uses Python. In **Settings > Open setup wizard**, choose a workspace and dashboard and install the helper if needed. Setup detects an optional tmux executable. Each New Agent launch can use tmux or run directly. Existing entries without a saved app-created runtime are retained only as history.

From any terminal on the host:

```sh
"$HOME/.local/bin/focus-queue-session" tmux start my-work --cwd /path/to/workspace
"$HOME/.local/bin/focus-queue-session" tmux list
"$HOME/.local/bin/focus-queue-session" tmux attach my-work
```

Append `-- codex` or `-- claude` to `tmux start` to start a provider directly. Detach with Ctrl-b, then d. Add the helper directory to PATH for the short `focus-queue-session` commands used in agent prompts.

On the second device, connect to the same tailnet and verify SSH access and the host key for the Mac's account. Generate its reconnect command on the host:

```sh
"$HOME/.local/bin/focus-queue-session" tmux ssh-command user@my-mac my-work
```

The wizard's **Connect from another location** disclosure also lists persistent sessions and copies reconnect commands. A missing session produces an error; attach never starts a replacement agent. App Recall additionally verifies the saved provider conversation in the recorded tmux pane.

## Verification and remaining release gates

Headless coverage includes first-run and restart behavior, invalid dashboards, retained configuration, installer conflicts and rollback, manifest-scoped uninstall, exact tmux execution and provider ownership, client disconnect and server death, and literal shell metacharacters. Real tmux tests use disposable servers and synthetic processes. No UI automation or live provider run was used.

Final local results: 191 Swift tests and 127 Python tests passed. The optimized 0.3.0 app bundle builds and its ad hoc signature verifies. The real bundle passed isolated install, upgrade and uninstall under a second-user fixture with spaces in its path. The beta ZIP checksum verifies. Version 0.3.0 is installed and running locally; installed app/helper bytes match the release bundle, and configuration and ingestion-file hashes are unchanged. The previous installation is retained under the app's Application Support backups directory.

`Scripts/package-release.sh` creates an architecture-specific ZIP and SHA-256 checksum. The bundle includes the session helper, generic configuration example and Ink's license. Default builds are ad hoc signed. Optional Developer ID signing uses `ECC_FOCUS_QUEUE_SIGN_IDENTITY`; notarization, stapling and downloaded-artifact Gatekeeper validation remain release requirements. The new GitHub Actions workflow has not yet run remotely.

Before public launch, complete the second-device SSH test, a fresh macOS account's visual setup and permission pass, Developer ID/notarization, optional connector account lifecycle and agent permission enforcement, and product privacy/license/support decisions. Intel is unqualified until its own execution pass. The current local artifact targets Apple Silicon.

Do next: open the wizard, enable tmux for a new test agent, and reconnect to that same session from another device over the tailnet.
