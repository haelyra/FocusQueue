<!-- fq-architecture: {"id":"persistence","title":"Local state and durable history","sources":[{"path":"Sources/FocusQueueCore/Persistence.swift","sha256":"0c561a836aa1371bd674c410f45662a63a9d9ae0193fbdce2a8a468418a5dc21"},{"path":"Sources/FocusQueueCore/DurableLibrary.swift","sha256":"5d303ade1642fa78fb2a74baa53a469b3403d7acd859edc3bdd2bea19ed08ba0"},{"path":"Sources/ECCFocusQueue/QueueConversationStore.swift","sha256":"f4b0c8b934fd8030348ede5f5cc441e33b56dde5498ca038e518548845760250"}]} -->

# Local state and durable history

The app keeps operational JSON state separate from its durable library. Operational files serve current UI and task workflows; the library records durable identities, assignment history, execution locations, and document revisions.

## Follow the code

- [Persistence.swift](../../Sources/FocusQueueCore/Persistence.swift), `SystemFileAccessor`: writes atomically and sets restrictive file permissions. `JSONLocalStateStore` caches loaded state inside its actor; it is not a general cross-process merge engine.
- [DurableLibrary.swift](../../Sources/FocusQueueCore/DurableLibrary.swift), `DurableLibraryStore`: reconciles legacy task/session records, captures documents and conversations, and supports local export/restore. The library schema has an explicit version; unsupported newer versions are rejected.
- [QueueConversationStore.swift](../../Sources/ECCFocusQueue/QueueConversationStore.swift), `save`: captures the supplied conversation in durable history before keeping a bounded active transcript. Revision tracking prevents an older suspended save from replacing a newer one. If capture fails, the canonical transcript keeps the supplied messages and surfaces an error.

## Boundaries and checks

Current assignment bindings are separate from historical snapshot observations; removed subtasks remain in history. Restore validates one captured manifest and its referenced blobs, assigns a new device identity, and leaves operational queue reconstruction for a later adapter.

Provider conversation identifiers do not establish provider account identity. Terminal pane IDs and filesystem locations are historical hints and need runtime verification. Review persistence, durable-library, and conversation-store tests before changing import, retention, or restore behavior.

Summary semantics are unverified after generation. Check the current schema and archive failure behavior in source before treating this card as authoritative.
