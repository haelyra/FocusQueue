# Workspace map: first functional draft

The Central plan now has a Map tab. It shows the selected task’s registered workspaces, assigned agents, canonical plan, and Git paths in expandable columns. The existing queue and task conversation remain in place.

## User flow

1. Open a task’s Central plan, then select Map.
2. Expand workspace and folder nodes to move from outer directory to deeper file paths.
3. Search by agent name, path, or summary. Use Needs attention for blocked, stale, or unreported agents; use Changed files for modified, added, renamed, deleted, and untracked paths. These two filters are mutually exclusive.
4. Select an item to inspect its location, evidence, progress summary, and observation age. Discuss adds this context to the existing chat draft without sending it.
5. Double-click or use Open to visit the folder, agent, or file. Keyboard focus plus Return selects an item; the same Open button is available in the inspector.

Workspace/folder opening uses Finder. Agent opening reuses task session routing. Markdown opens in the embedded plan. HTML uses the default browser, PDFs/images use their registered viewer. Code defaults to read-only Neovim in a new WezTerm window, using literal argument arrays with `-R -M --`. Map preferences also offer VS Code. Missing editors or files produce an error instead of silently choosing a writable editor. The Neovim flags are an inspection preference, not an enforced filesystem access boundary.

## Modular implementation

- `Sources/FocusQueueMap/`: versioned Codable snapshot, read-only Git collector, deterministic bounded layout, validated file actions, and private atomic snapshot cache. Depends on the existing core process runner and context types.
- `Sources/FocusQueueMapCLI/`: standalone `focus-queue-map` helper using that same collector. It reads task context, registered state, and pending registrations without acknowledging them or writing canonical task state.
- `Sources/ECCFocusQueue/WorkspaceMapModel.swift` and `WorkspaceMapView.swift`: presentation and native actions. The existing plan view adds a small tab switch and passes task selection, file navigation, and chat-draft callbacks.
- `Scripts/build-app.sh`: packages and signs the helper alongside the existing session helper. The existing installer copies the complete bundle, so its transaction logic is unchanged.

The app calls the shared collector directly rather than launching another process for JSON transport. Scripts can call the standalone executable to get the same schema. There is no new always-on service or provider-specific instrumentation.

## Script entry point

From this worktree:

```sh
swift build --product focus-queue-map
Scripts/focus-queue-map snapshot ECC-123
Scripts/focus-queue-map snapshot ECC-123 --output /tmp/workspace-map.json
```

Replace ECC-123 with a task that has saved context. `FOCUS_QUEUE_SUPPORT_DIR` selects another context store. The wrapper uses a local debug/release build, then the helper bundled in the installed user application. Scripts outside the repository can invoke `~/Applications/ECC Focus Queue.app/Contents/MacOS/focus-queue-map` directly. No new global command is installed over an existing user file.

Snapshots contain `schemaVersion`, `taskID`, `generatedAt`, `nodes`, `warnings`, and `omittedPaths`. Each node has a typed `kind`, stable ID, parent reference, source evidence, optional location, and optional agent state or Git status. Parent relationships encode physical containment except agent assignment and the external central-plan reference. The UI renders agent assignment connectors as dashed lines. Input/output edges and agent-authored grouping are reserved for the later phase.

## Facts, freshness, and limits

- Git proves workspace boundaries and changed paths. Files explicitly say that their individual owner is unknown. Subtask summaries describe reported work; they do not imply file access.
- Working reports become stale after five minutes, with missing heartbeats and significant future clock skew also shown as stale. Completed reports remain completed. Unbound registrations show unknown activity. A stale registration cannot take over the progress of a reassigned subtask.
- Only locations recorded on the selected task or its sessions are scanned. The canonical plan remains outside worktree containment when it lives in the task store. Other-task and unregistered agents are outside this first draft’s scope.
- The map refreshes about every five seconds while visible and cancels collection when dismissed. Tracked file lists are cached for thirty seconds; Git status refreshes each pass. Quiet renamed/deleted tracked paths can remain in that cached list until its next refresh, and opening a missing path gives a refresh message.
- Git commands have five-second deadlines, optional locks disabled, and a two-megabyte output bound. Truncated output is rejected. Each workspace contributes at most 400 file paths, with changed paths prioritized. Directory ancestors are included, while the renderer displays at most 100 nodes at a time. The hidden/omitted counts explain those limits.
- Snapshots are saved atomically with private permissions under the task’s `workspace-map/snapshot.json`. Failed scans retain prior observations and their original age. If a saved complete map exists, the view keeps that last successful map when a source fails and displays the failure. Partial maps never overwrite the durable last successful cache.
- Linked-worktree IDs derive from the Git metadata directory and remain stable across `git worktree move`. Moving the whole repository, including its Git metadata directory, currently changes those IDs.
- All file openings validate the node ID and registered root, reject escaping symlinks, and check existence. Deleted files remain visible as Git evidence but cannot be opened.

## Validation and remaining review

Headless tests cover Git parsing and actual repositories, linked-worktree moves, Unicode/spaces, stale and absent reports, clock skew, session reassignment, unknown authorship, layout/filter stability, malformed snapshots, failed refreshes, cache preservation, path traversal, escaping symlinks, deleted files, and Neovim argument handling. The app compiles with the new native view. UI automation remains disabled under the repository policy, so actual pointer interaction, rendered appearance, and opening applications still need manual review.

Validation on 2026-09-14: all 205 Swift tests and 127 Python tests passed. Shell syntax and Git whitespace checks passed. A CLI smoke test against this worktree produced 154 nodes in an 89,294-byte JSON snapshot in 0.175 seconds for a cold collection. JSON export to a path containing spaces, private output permissions, missing arguments, invalid task IDs, and missing context were checked. This single-workspace measurement does not establish fleet-scale or rendered selection performance.

This build implements the Workspace lens. Handoffs, fleet scope, file-level declarations, provider tool hooks, agent-designed presentation rules, configurable PDF rendering for Markdown, and semantic changes since last visit remain follow-up features described in the design study. The Changed files filter reflects current Git status rather than claiming a visit history.
