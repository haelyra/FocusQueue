# Managed session continuity

Status: local tmux and direct-terminal lifecycles implemented and headlessly verified on September 14, 2026. Remote host enrollment and cloud synchronization remain future work.

Focus Queue uses the user's installed and signed-in provider CLI under the user's subscription. It does not use provider APIs or API billing.

## Current contract

Every agent started from Focus Queue has a descriptive subtask title. **Keep this agent running in tmux** is checked by default when tmux is installed. Managed creation has ordered phases:

1. Start the provider process in a uniquely named tmux session.
2. Persist the exact tmux server PID, creation time, session name, pane ID, pane PID, TTY and executable on the subtask.
3. Open or focus a WezTerm client attached to that saved runtime.
4. Add the provider conversation ID later when the running provider registers from inside that managed pane. Registration from unrelated terminal panes is refused.

When the checkbox is off, Focus Queue starts the provider once in a new WezTerm window and stores its exact pane ID and mux socket. Clicking the subtask can focus that pane while it remains open. Closing the pane ends the live runtime, and recall never creates a replacement.

Persisting the runtime before opening WezTerm prevents a terminal transport failure from orphaning a live agent. The subtask remains visible and clicking its title retries the client attachment.

Shell aliases and provider wrappers can replace the initial pane process during startup. Focus Queue therefore waits up to 30 seconds and requires three consecutive matching observations of the tmux server, pane process and terminal device. A successful tmux creation is never described as a stopped agent merely because those fields are still settling. Each phase is retained in a structured per-subtask launch log that is available from the document icon beside the subtask.

Recall verifies every saved tmux identity field. If a matching client is already open, Focus Queue activates its exact pane. Otherwise it starts only `tmux attach-session` for the saved session. Closing that client does not stop the provider process.

Recall never scans transcripts, invokes `codex resume` or `claude --resume`, starts another provider process, or substitutes a shell in the home directory. A missing or changed runtime is shown as ended. Entries without an app-created saved runtime cannot be opened from the current queue.

## Data ownership

Current operational state stays in local files. The durable library retains task, subtask, provider session, assignment, central plan, documentation and execution-locator history when the current queue is cleared. Clearing entries does not terminate processes. Process termination requires a separate deliberate action.

The provider conversation ID is historical metadata. It can help a future explicit successor workflow, but it is insufficient proof that a process, checkout, credentials, tool state or uncommitted work still exists.

## Same-host and remote access

On the original Mac, `focus-queue-session tmux attach <name>` connects another terminal client to the same process. Ordinary SSH over an authenticated network can run the same command on that host. The host and tmux server must still be alive.

A future cloud hub should synchronize identity and routing metadata while leaving execution with the user's CLI:

| Record | Required fields |
| --- | --- |
| Host | Stable enrolled host ID, public key, account or environment identity, last observation |
| Managed runtime | Runtime ID, host ID, tmux server identity, session and pane identity, process start identity, state |
| Agent session | Durable session ID, provider, provider conversation ID if observed, task and subtask assignment |
| Workspace | Repository identity, host-local worktree path, branch, commit and dirty-state evidence |
| Documents | Central plans, guides, architecture cards, revisions and content hashes |

Cloud clients may request attachment through an enrolled online host. They must not claim a live process based only on synchronized metadata. Host reboot, tmux server death and destroyed cloud machines end the current runtime.

## Later successor workflow

Restarting an ended provider conversation is outside the current recall contract. If added later, it should be an explicit **Start successor from saved context** action that creates a new managed runtime and links it to the ended session. It must verify the provider account, checkout mapping and available provider history before launching. Failure stays visible and does not create a blank terminal.

## Verification

The automated suite covers incomplete tmux startup receipts, wrapper process replacement, exact runtime persistence, existing-client focus, detached-client reattachment, direct-pane focus, closed direct-pane rejection, task mismatch rejection, structured diagnostics, and absence of provider resume or replacement commands. A gated live-provider sanity check starts the user's actual Codex command through `TaskAgentLauncher`, closes one headless tmux client, opens a second, confirms the same process, and removes only its unique test session.
