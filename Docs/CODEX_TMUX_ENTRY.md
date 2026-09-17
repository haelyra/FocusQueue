# Codex shell entry

Normal interactive `codex`, `codex resume` and `codex fork` launches can start in Focus Queue's managed tmux server. The existing usage-bar wrapper and its flags stay in use. The original alias stays in the shell configuration for recovery.

The entry preserves command arguments exactly, including prompts with quotes or line breaks. It starts tmux in the caller's directory and lets Codex apply `--cd` itself, so a relative `--cd` path is not applied twice. Commands such as `exec`, `review`, `help`, `login`, completion generation and version checks keep their existing behavior. Piped and redirected invocations also pass through unchanged.

An existing `TMUX` environment keeps the current terminal. `FOCUS_QUEUE_RUNTIME_MODE=terminal` preserves the app's direct-terminal setting. `FOCUS_QUEUE_CODEX_TMUX=off` is a shell-level opt-out. The integration installs a zsh function and invokes the existing usage wrapper through Bash; it never adds a recursive executable named `codex` to `PATH`.

## Resume and tracking

An explicit resume UUID is checked with `focus-queue-session runtime locate codex <UUID>`. A verified running conversation opens its existing managed pane. A direct-terminal conversation or uncertain process identity prevents a second launch and reports where to continue. From inside an existing tmux session, a running conversation is reported instead of nesting an attachment.

Resumes use deterministic tmux names and a private launch receipt protected by a file lock. The receipt compares the full server/pane/process/TTY reference against `tmux list`, which includes every pane. This prevents a second resume while process discovery is still catching up. An unconfirmed launch keeps its intent record and requires recall before another attempt. A previously restored shell remains intact.

Resume pickers and named sessions keep Codex's normal selection behavior. Their exact conversation ID becomes known to Focus Queue through provider lifecycle events or process discovery. The pre-launch duplicate guard applies to explicit UUID resumes.

The installer merges native Codex hooks for `SessionStart`, `UserPromptSubmit`, `Stop`, `SessionEnd`, `SubagentStart` and `SubagentStop`. Each forwards its JSON event directly to `register-event`; identity registration needs no model response. Codex requires review of new or changed hook definitions in `/hooks`. The integration does not alter trust records, managed requirements or hook-trust bypass flags. [Official hook documentation](https://learn.chatgpt.com/docs/hooks)

Process discovery remains available before hooks are trusted. When the CLI arguments identify a prompt unambiguously, the entry also writes a private launch metadata record with the exact tmux reference and at most 4096 prompt characters. Discovery can use that label only after validating the current reference. Unknown options or ambiguous positional input leave the label generic.

## Install and recovery

The app bundle includes both installer and entry scripts under its shell resources. The installer accepts an absolute existing usage-wrapper path and explicit flags. For the current usage-bar setup, the selected flag is `--yolo`; it is preserved from the existing alias rather than introduced as a new default.

Run the installer with `--check` to preview its destinations, then run the same arguments without `--check` to install. Installation appends one marked source block to `.zshrc`, installs the entry under the application's support directory, and merges the hook entries while retaining unrelated definitions. Existing files are backed up and a failed install rolls back changes. Re-running the installer with the same settings makes no changes.

New shells load the function automatically. Existing shells can source the updated shell configuration. To return to the old alias, remove the marked Focus Queue source block and start a new shell. Backups contain the original files and a recovery manifest. Data and launch receipts remain available.

The headless test module covers argument routing, exact resume reuse, uncertain and unconfirmed launch rejection, restored-shell preservation, wrapper/flag retention, metadata parsing, merge-safe installation, real zsh sourcing, rollback and symlink refusal. Installed Codex 0.154.0 was checked through its local help output for resume and fork syntax.
