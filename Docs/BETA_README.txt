Focus Queue 0.3.5 public beta

Requires an Apple silicon Mac with macOS 14 or later, Homebrew and at least one agent
CLI (Claude Code, Codex or Kimi Code) signed in with your own subscription. macOS
Terminal is all you need; Ghostty and WezTerm are optional. Full steps:
https://github.com/haelyra/FocusQueue#install-beta-testers

This beta has an ad hoc signature and is not notarized. Clear the download flag
before installing, and only for a ZIP downloaded from github.com/haelyra/FocusQueue.

INSTALL
From the folder that holds this archive's "Focus Queue Beta" folder:
  xattr -dr com.apple.quarantine "Focus Queue Beta"
  "Focus Queue Beta/Install.command" --desktop

Install.command first adds what is missing: it opens Apple's Command Line Tools
installer (git, python3; run Install.command again when it finishes), and uses
Homebrew to install tmux and the GitHub CLI (gh). Without Homebrew it prints how to
install it and continues. Its JSON result lists each tool under "prerequisites".

It adds Focus Queue's agent instructions, as one marked block, to ~/.claude/CLAUDE.md
and ~/.codex/AGENTS.md, keeping your own text in those files. A block that an older
version put in ~/Documents/CLAUDE.md or ~/Documents/AGENTS.md moves there.

It installs the app to ~/Applications, and the focus-queue-session helper and Q chat
launchers to ~/.local/bin. It preserves your existing configuration and keeps backups
before replacing a previous version. It does not need GitHub access. Use --check for a
read-only preflight, --login for launch at login, and --desktop for a Desktop shortcut.
Existing login and shortcut choices are retained.

The first launch opens a walkthrough: choose your terminal and agent, sign in, then
create a project. Settings > Projects > Open setup wizard reopens setup at any time.
The wizard's Install command-line helper button reinstalls a missing helper without
editing your shell profiles. Add $HOME/.local/bin to PATH or use its full path.

Lasting instructions in a prompt, such as "end every reply with a fish emoji", are
saved to the project's data.md so later agents follow them. Turn this off in
Settings > Task placement > Save durable facts from prompts.

PERSISTENT SESSIONS
In setup, enable Keep new agents running in tmux and select the tmux executable.
New agents start on a dedicated server named ecc-focus-queue. Existing terminals
are not moved. Reconnect returns to the running process while the host and server
remain alive. Reboot or server termination ends that process.

From any local terminal:
  "$HOME/.local/bin/focus-queue-session" tmux start my-work --cwd /path/to/workspace
  "$HOME/.local/bin/focus-queue-session" tmux list
  "$HOME/.local/bin/focus-queue-session" tmux attach my-work

Detach with Ctrl-b, then d. To start a provider directly, append -- codex or
-- claude to the start command. Explicit task registration still requires the
provider's session identity, discovered from its process or environment.

REMOTE ACCESS
Sessions stay on the original Mac. Connect both devices to the same tailnet.
Configure macOS Remote Login and SSH authentication for your account. Verify the
Mac's SSH host key from the other device before using generated reconnect commands.
The standard Tailscale Mac app uses ordinary SSH over Tailscale. The Tailscale SSH
server feature has different platform requirements. Setup does not change either
device's SSH configuration, keys, Tailscale enrollment or network access rules.

Run on the host to generate a command for the other device:
  "$HOME/.local/bin/focus-queue-session" tmux ssh-command user@my-mac my-work

You can also list sessions and copy commands in Setup > Connect from another
location. Generated commands require a known host key, disable agent forwarding,
and preserve other attached clients. Remote host enrollment, cross-host process
migration and automatic recovery after reboot are future work.

RECOVERY AND UNINSTALL
Managed installation retains prior files and a recovery.json map under
Library/Application Support/ECC Focus Queue/backups/. Ordinary install failures
restore prior files automatically. A hard interruption may require restoring the
paths listed in the retained recovery map before retrying installation.
Uninstall.command --check previews removal. Uninstall.command moves only verified,
manifest-owned installation files to a retained backup. Task data, configuration,
history, tmux sessions and companion services are preserved. For drag installations,
move the app to Trash; manage any separately installed helper yourself.

QUALIFICATION LIMITS
Automated checks are headless. Cross-device Tailscale/SSH connectivity, visual setup,
macOS permission prompts and provider authentication require a manual beta pass.
Public launch also needs signing/notarization, account setup and permission-boundary
work for optional agent/connector features, plus privacy, license and support policy.
