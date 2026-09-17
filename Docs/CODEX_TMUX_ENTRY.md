# Codex shell entry

Normal interactive `codex`, `codex resume` and `codex fork` launches can start in Focus Queue's managed tmux server. The existing usage-bar wrapper and its flags stay in use. The original alias stays in the shell configuration for recovery.

The entry preserves prompts, quoting and provider options while normalizing `--cd` to the resolved workspace. New interactive coding agents in committed Git repositories receive an isolated worktree from the selected HEAD. Source edits remain untouched and excluded from that snapshot. Research/orchestrator roles (`FOCUS_QUEUE_AGENT_ROLE=research` or `orchestrator`) and explicitly approved `FOCUS_QUEUE_WORKSPACE_MODE=existing` retain their directory. Non-Git and unborn repositories remain usable with an isolation warning; agents must resolve shared-writer safety before editing.

Agent launches, including `exec`, `review`, piped starts and terminal/tmux opt-outs, must persist a private launch receipt before provider execution. Noninteractive invocations keep their existing checkout and record that policy. Help, login, completion and version checks remain utility calls. A missing task, label, model or native session UUID leaves a provisional tracked record. An unwritable tracking store prevents launch with a visible error.

An existing `TMUX` environment keeps the current terminal. `FOCUS_QUEUE_RUNTIME_MODE=terminal` preserves the app's direct-terminal setting. `FOCUS_QUEUE_CODEX_TMUX=off` is a shell-level opt-out. The integration installs a zsh function and invokes the existing usage wrapper through Bash; it never adds a recursive executable named `codex` to `PATH`.

## Resume and tracking

An explicit resume UUID is checked with `focus-queue-session runtime locate codex <UUID>`. A verified running conversation opens its existing managed pane. A direct-terminal conversation or uncertain process identity prevents a second launch and reports where to continue. From inside an existing tmux session, a running conversation is reported instead of nesting an attachment.

Resumes use deterministic tmux names and a private launch receipt protected by a file lock. The receipt compares the full server/pane/process/TTY reference against `tmux list`, which includes every pane. This prevents a second resume while process discovery is still catching up. An unconfirmed launch keeps its intent record and requires recall before another attempt. A previously restored shell remains intact.

Resume pickers and named sessions keep Codex's normal selection behavior. Their exact conversation ID becomes known to Focus Queue through provider lifecycle events or process discovery. The pre-launch duplicate guard applies to explicit UUID resumes.

The default installation uses process discovery and verified launch metadata for tracking. It leaves native hook files unchanged, so installing the shell entry does not introduce a Codex hook-review prompt.

Provisional records live under `tracking/launches`; exact native writer-lock identity resolves them through verified pane identity or PID ancestry plus process start time. Working directory alone never binds a conversation. The unassigned inbox shows incomplete receipts and their reason while identity is pending. Closed short-lived calls can retain an unresolved receipt if discovery missed their native UUID. Explicit UUID resumes look up the recorded workspace across tasks and refuse ambiguous or missing saved workspaces instead of creating replacements.

This enforcement covers the configured entry point and app launcher. Invoking the native executable by absolute path bypasses a shell function. Process discovery and the global agent contract cover that route on a best-effort basis; the app does not claim an operating-system-wide execution or file-write sandbox. Child-agent lifecycle hooks remain optional because enabling them requires Codex trust review.

Native lifecycle hooks are an explicit option through `--install-hooks`. This merges hooks for `SessionStart`, `UserPromptSubmit`, `Stop`, `SessionEnd`, `SubagentStart` and `SubagentStop`. Each forwards its JSON event directly to `register-event`; identity registration needs no model response. New or changed hooks trigger Codex's interactive trust-review modal before an initial prompt can run. Choose this option when ready to review and trust the definitions through `/hooks`. The integration leaves trust records, managed requirements and hook-trust bypass flags unchanged. [Official hook documentation](https://learn.chatgpt.com/docs/hooks)

When the CLI arguments identify a prompt unambiguously, the entry writes a private launch metadata record with the exact tmux reference and at most 4096 prompt characters. Discovery can use that label only after validating the current reference. Unknown options or ambiguous positional input leave the label generic. This tracking path works independently of native hook installation and trust.

## Install and recovery

The app bundle includes both installer and entry scripts under its shell resources. The installer accepts an absolute existing usage-wrapper path and explicit flags. For the current usage-bar setup, the selected flag is `--yolo`; it is preserved from the existing alias rather than introduced as a new default.

Run the installer with `--check` to preview its destinations, then run the same arguments without `--check` to install. Default installation appends one marked source block to `.zshrc` and installs the entry under the application's support directory. Adding `--install-hooks` also merges native hook definitions while retaining unrelated entries. Existing files are backed up and a failed install rolls back changes. Re-running the installer with the same settings makes no changes. A later default install retains any hook definitions already present.

App updates refresh an already configured, recognized entry script without changing its source block, wrapper, flags or native hook trust. A fresh machine still needs the shell setup above because the existing usage wrapper and approved flags are user-specific.

The exact shareable global instruction payload is [CODEX_GLOBAL_INSTRUCTIONS.md](../Config/CODEX_GLOBAL_INSTRUCTIONS.md). App installation merges its marked block into the default `~/.codex/AGENTS.md`, preserving personal text outside it. Incomplete or duplicate markers stop installation for review. Backups and rollback cover the prompt; uninstall retains it and shell settings rather than deleting personal configuration. A custom `CODEX_HOME` or higher-priority override requires the same block in that installation's effective instruction file. Restart existing Codex conversations to load updated instructions.

For a coworker testing the prompt now: copy the whole marked payload into their effective global instructions once, retain their own personal sections, then start a fresh session. The prompt guides behavior; install the app/helper and shell entry to test enforced pre-launch tracking.

## Lightweight maintenance

Semantic task/agent changes trigger a deterministic, per-task leased pass; a 60-second recovery sweep catches missed changes and merges. No model runs per launch. The pass repairs missing or empty plans and logs, explains incomplete criteria, and writes changed findings to `maintenance.json` with content-addressed audit receipts. Repeated unchanged findings do not create repeated receipts. Task details expose the findings in a collapsed tracking/workspace section. Corrupt neighboring task files are skipped during discovery but remain strict blockers for destructive cleanup.

`focus-queue-session reconcile <TASK-ID>` runs the same maintenance path. Add `--no-cleanup` to repair context and save findings without removing workspaces. Both commands write context/receipts. Completed assignments are evaluated separately from response readiness, merge and cleanup. Only fully owned, clean, merged, inactive app-managed worktrees are automatically removed; their branches and canonical documents stay. A partial provider-process scan retains work, including clean merged work. Shell-created external worktrees currently retain their launch ownership receipt for review rather than being automatically deleted. Superseded document archival is an explicit orchestrator action, never a heuristic deletion sweep. Priority changes, task closure, merges, pushes and paid-agent launches require separate authority.

New shells load the function automatically. Existing shells can source the updated shell configuration. To return to the old alias, remove the marked Focus Queue source block and start a new shell. Backups contain the original files and a recovery manifest. Data and launch receipts remain available.

The headless test module covers argument routing, exact resume reuse, uncertain and unconfirmed launch rejection, restored-shell preservation, wrapper/flag retention, metadata parsing, default installation without hook-file access, explicit hook opt-in and preservation, real zsh sourcing, rollback and symlink refusal. Installed Codex 0.154.0 was checked through its local help output for resume and fork syntax.
