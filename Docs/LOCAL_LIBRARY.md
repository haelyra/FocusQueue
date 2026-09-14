# Local library schema and migration

Focus Queue now maintains a versioned local library alongside its existing task editing files. It gives tasks, subtasks, agent conversations, assignments, documents, revisions, and report runs durable IDs. This is the first implemented phase of the optional cloud architecture, dated 2026-09-13.

Agent execution continues through the user's installed, signed-in Codex or Claude CLI. New agents are started once inside an app-owned tmux session. Reopening attaches to that exact running session and never runs a provider history command. No new provider API integration, API key, model call, cloud database, or hosted execution service is needed for the library or architecture index. Moving devices requires access to the original live host; stopped sessions remain history until an explicit successor workflow is designed.

## What is stored

The app's support directory contains:

| Location | Purpose |
| --- | --- |
| `library/manifest.json` | Schema version 1, workspace UUID, revision, tasks, subtasks, sessions, assignments, repository mappings, execution locators, documents, report runs, change receipts, import warnings. |
| `library/blobs/<sha256>.md` or `.json` | Immutable retained document bytes. Revisions refer to relative paths, checksums, byte counts, and recording times. |
| `library-device.json` | This installation's UUID and provider installation namespaces. Kept outside exports so a restored installation gets a new identity. |
| Existing `state.json`, `tasks/`, `ingestion/` | Compatibility stores still used for current app editing, provider registration, and report workers. Migration preserves them. |

The library is the retained history store. Existing operational files remain the current editing interface in this phase. A future adapter can store the same durable identities in a synchronized service; cloud synchronization, conflict resolution, authentication, and remote execution are not implemented here.

Provider account references remain null unless supported evidence establishes an account identity. A provider session ID is scoped to the originating provider installation. Saved terminal pane IDs and directories are unverified execution hints. They never establish that an agent is running. Current task assignment and process activity are separate concepts.

`recordedAt` means the time Focus Queue retained evidence, not an invented historical start date. Reassignment closes the previous current assignment while retaining its record. Snapshot-only assignments have source `historical-context`; they are historical observations regardless of an absent end date. Deleted subtasks remain in history with `isCurrent: false`.

## Import and inspect

```sh
focus-queue-session library migrate
focus-queue-session library status
focus-queue-session library task ECC-035
focus-queue-session library document ECC-035 /absolute/path/to/user-guide.md guide
```

The explicit `library document` command retains a selected Markdown guide, architecture card, or reference under the task without moving or rewriting the original file.

The complete importer reads the configured dashboard, current task contexts and canonical central plans, archived context/plan snapshots, registered agent metadata, app conversations, review records, and archived/current daily reports. It uses saved session directories before task-level fallbacks, labels fallback provenance, and imports historical subtask session bindings without changing current progress.

It does not recursively copy provider transcript directories, shell configuration, credentials, connector payloads, or arbitrary repositories. Automatic plan import requires the task's canonical plan path. Missing, malformed, or out-of-scope files appear as warnings; successful sources can still be retained. Unknown facts stay unknown. Re-running unchanged input preserves IDs and manifest revision.

The app imports on startup and captures changed state, dashboard, task context, known plans, conversations, and reports afterward. It avoids archive/provider scans during ordinary polls. `Retry history` retries a failed import. CLI task updates also capture their changed context, and registrations record their own session without ending unrelated registrations.

App conversations merge by message UUID before the display cache is trimmed. If archival fails, the app saves all supplied messages in the existing conversation file and displays an error. Messages already lost before this feature cannot be reconstructed from the remaining 500-message cache.

## Export and restore

```sh
focus-queue-session library export /absolute/new/focus-queue-export
FOCUS_QUEUE_SUPPORT_DIR=/absolute/new/restore-location \
  focus-queue-session library restore /absolute/new/focus-queue-export
FOCUS_QUEUE_SUPPORT_DIR=/absolute/new/restore-location \
  focus-queue-session library status
```

Export includes one consistent manifest snapshot and every referenced blob, validated by checksum and relationships. It excludes credentials and the local installation identity. It retains historical device/path metadata, which is private information. Exports are local files, not automatic uploads.

Restore requires a fresh support location. It validates the schema, IDs, relationships, file paths, and checksums before accepting the copy. Existing destinations, corrupt data, and unsupported schema versions are refused. The source export remains unchanged. A new device identity prevents old terminal IDs from becoming trusted local locators.

This command restores the durable library. Rebuilding legacy dashboard/editing files from it, remapping repositories, and moving provider conversations are later steps. Restoring a library currently makes its records inspectable through the library commands; it does not launch agents or repopulate the operational queue automatically. Markdown bytes and source provenance are retained; resolving old absolute links and code references on a new device still requires repository mapping.

## Compact architecture context

Central plans, user guides, architectural explanations, and module cards are documents in the same system. The first implemented architecture feature is an authored set of compact cards plus a deterministic source-drift index:

```sh
focus-queue-session architecture ECC-035 /absolute/path/to/repository
```

The command reads `Docs/Architecture`, writes a bounded index under the task's context directory, and retains the cards/index in the library. It never overwrites authored cards or calls a model. Each card explains responsibilities, useful symbols, and boundaries, with links to source. Matching hashes mean the source is unchanged since the card's baseline; they do not prove that its explanation is correct.

Read the index first, then the relevant card, then only the source needed for the task. Source-backed summaries should help agent handoffs without copying whole files into every prompt. Automatic semantic extraction, agent-reviewed refresh, deeper symbol graphs, and cross-repository search are queued improvements.

## Remaining release work

- Make library-backed task/session/document history directly browsable in the app, then migrate operational editing behind the shared repository interface.
- Expose managed runtime health and ended-session history directly in the app.
- Add provider account identity verification and explicit local repository remapping.
- Add document-reference remapping for restored Markdown links and imported repositories.
- Measure manifest growth and conversation revision storage. Retained individual documents currently have a consistent 64 MiB read/write/import limit; oversize conversation archival falls back to the full operational file with a visible error. This first implementation uses atomic JSON plus immutable blobs; a disposable SQLite query index and more compact event storage can follow.
- Build enrolled-host SSH access to the same managed tmux runtime, then optional cloud synchronization with offline/conflict semantics.
- Add controlled GitHub publishing of central plans, guides, and architecture cards. Repository creation and publication remain explicit operations.
