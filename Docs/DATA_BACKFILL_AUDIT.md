# Local data backfill audit

Generated from a read only structural inventory of `/Users/hira/Library/Application Support/ECC Focus Queue` on 2026-09-13, after the schema import. Run it again with `python3 Scripts/focus_queue_data_audit.py`; use `--support-dir` for a fixture or another installation. The script emits field names and counts, never stored text.

## Observed sources

| Source | Shape | Observed |
| --- | --- | --- |
| `config.json` | JSON object | present; keys are inventoried by the script |
| `state.json` | JSON object | present; keys are inventoried by the script |
| `tasks/<ticket>/context.json` | JSON object | 39 task directories, all with valid current context JSON |
| `tasks/<ticket>/plan.md` | Markdown | 39 plans |
| `tasks/<ticket>/conversation.json` | JSON array | 2 conversations; script reports message counts only |
| `tasks/<ticket>/archive/snapshot-*/context.json` | JSON object | 76 archived snapshot directories, each with context and plan (152 files total) |
| `ingestion/reports/<day>/*.json` | JSON report documents | 4 days, 4 archived report files |
| `ingestion/latest-report.json` | JSON report document | present |
| `ingestion/report-presentation.json` | JSON presentation state | present |
| `ingestion/state.json` | JSON ingestion state | present |

`state.json` contains 23 persisted `agentSessions` records. The audit reports only counts of records carrying `ticketID`, `sessionID`, and `workingDirectory`; it does not print provider names, prompts, or transcript content. `ingestion/latest-report.json` is the current report source name used by the app; archived sources are `ingestion/reports/<day>/<run-id>.json`.

Six task contexts contain subtasks, with 18 subtask records total; all 18 carry an explicit `id` in the observed data. This is an identifier count only.

The support directory currently contains 1,038 files in total, including unrelated runtime logs, connector artifacts, schema library files, backups, and OS metadata. The audit counts these but does not parse their bodies. The earlier estimate of 194 archived snapshots is superseded by the exact count of 76 snapshot directories and 152 context/plan files.

## Recoverable metadata and gaps

Current task contexts expose the fields `ticketID`, `title`, `summary`, `updatedAt`, `planPath`, `subtasks`, and `successCriteria` for all 39 tasks. `worktreePath` is absent from 19 tasks: ECC-011, ECC-020, ECC-038, ECC-040, ECC-045, ECC-046, ECC-047, ECC-048, ECC-049, ECC-050, ECC-051, ECC-053, ECC-055, ECC-056, ECC-057, ECC-058, ECC-060, ECC-061, and ECC-062. Twenty tasks have a current `worktreePath`.

The two current conversations are recoverable as per task message counts, but this audit does not establish session identity, provider, or path provenance. Plans and context records provide ticket and task metadata. Archive snapshots can provide historical context field values, subject to matching the ticket and snapshot chronology. No backfill is performed here.

The audit cannot establish whether a missing worktree path still exists, whether an agent session is active, or whether a provider transcript corresponds to a task. It intentionally does not scan transcript bodies or claim recovery where no persisted evidence exists. Provider/session/path correlation requires a separate importer using explicitly associated metadata.

Missing `worktreePath` is an observed metadata gap, not automatically a defect: a task may intentionally use the repository default or have no managed worktree. The audit does not infer that distinction. Subtask records are counted and their explicit `id` presence is reported per task; no subtask text is emitted.

## Schema migration result

The live local migration result recorded zero warnings, 240 legacy files checked, zero legacy files changed, revision 1, and an unchanged repeat revision of 1. Its summary reported 61 tasks, 23 sessions, 59 assignments, 300 documents, and 300 document revisions, with schema version 1 and local storage mode. The migration backup source was `/Users/hira/Library/Application Support/ECC Focus Queue/backups/schema-20260913-194453-00b679a0`. The result also recorded 23 unknown accounts. These are migration result counts, not claims that all records are currently recoverable or active.
