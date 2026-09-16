# Workspace maps and document panes

Central plan includes a reusable task map and side document panes. The map has Typical, Context, and Agent views over one snapshot. The active spacing and activity contract is documented in [spacing rules](spacing-rules.md).

## User flow

1. Open a task's Central plan, then Map. Typical shows task context, worktree/repo groups, agents, and representative outputs.
2. Click an agent to focus its current reported work and important previous outputs. Click blank space or Typical to return. Changed files shows recorded writes for that agent.
3. Use the gray expansion/collapse controls to inspect a representative. Typical stays within five columns and ten rows. Expanded keeps five columns, opens every available relevant branch up to the item limit, and grows into a vertically scrolling canvas.
4. Repo context initially exposes AGENTS.md and README.md as bordered clickable entries. Other known context gets a normal collapsible node only when it has contents. Expanded also opens the collected repository hierarchy inside its worktree. Group-level lines replace individual context-file-to-agent lines.
5. File clicks open side document tabs and their task-aware conversations. The central conversation collapses while its request continues. Hiding the side pane restores it.
6. The document metadata strip shows location, type, size, modification date, and Show in Finder. Code uses selectable plain text. Markdown uses the neutral plan theme and rendered task checkboxes. Existing static HTML/PDF/image previews remain available.

Hovering for a second or right-clicking a map card reveals its full path. Every root except the task workspace prints its location on the card. Worktree outlines are visibly named; multiple worktrees are numbered and stacked vertically. Fit width preserves vertical scrolling. View changes use a 0.28-second transition and honor Reduce Motion. Map folder launching remains disconnected; its dormant helper is retained for a possible future explicit action.

## Reusable components

- `MapSnapshot`: versioned nodes, physical containment, evidence, and typed relationships. Schema v2 supports context groups, document headings, links, instances, and agent ancestry. The reader accepts v1 snapshots.
- `WorkspaceCollector`: read-only Git collection plus task context, declared scope, recorded activity, Markdown source grouping, and declared resources. Runs away from the main actor.
- `MapTree` and `MapCompactLayout`: reusable presentation tree, bounded normal view, vertically growing expanded view, overflow representatives, collapse state, focused branches, and stable visual identities. Multiple visual copies of a physical file retain distinct presentation identities.
- `MapDiagram`: Codable cards, containers, connections, and geometry. Its legacy forest helper remains available to older clients.
- `MapEdgeRouter`: orthogonal routing with card avoidance and crossing penalties. Clear adjacent-rank routes take a fast path; feedback can use outside row channels.
- `WorkspaceMapProjection`: task-specific grouping, repository previews, activity prioritization, and context/agent selection.
- `InteractiveMapCanvas`: renders diagrams with callbacks. It owns no collector, task context, provider integration, or document opener.
- `WorkspaceMapModel`: view state, visible-snapshot refresh, expansion and navigation.
- `DocumentPaneState`, `SideDocumentPane`, and `DocumentConversation`: tab identity, previews, and independent conversations that survive view dismissal.

For a new in-app map, supply a `MapTree` to `MapCompactLayout`, route its `MapDiagram`, and pass the result to `InteractiveMapCanvas`. Keep collection and navigation in the caller. A future project collector can combine namespaced task/workspace/session records and reuse these components.

## Script entry points

```sh
swift build --product focus-queue-map
Scripts/focus-queue-map snapshot TASK-ID --output /tmp/snapshot.json
Scripts/focus-queue-map diagram TASK-ID --view typical --output /tmp/diagram.json
Scripts/focus-queue-map diagram TASK-ID --view agent --agent SESSION-ID --retrospective
Scripts/focus-queue-map diagram TASK-ID --view agent --agent SESSION-ID --focus GROUP-ID
Scripts/focus-queue-map scope TASK-ID SUBTASK-ID --input /context.md --output /Feature.swift
Scripts/focus-queue-map resources TASK-ID --import /path/to/resources.json
Scripts/focus-queue-map activity TASK-ID --import /path/to/activity.json
```

`FOCUS_QUEUE_SUPPORT_DIR` selects the task store. The installed app bundles the same helper. Scope declarations replace previous intended input/output paths for an exact session. Activity imports merge recent per-path reads and writes into exact-session history. Subagent reports include their parent session and provider. See the [activity example](activity.example.json) and [resource example](resources.example.json); both contain fictional placeholders.

## Evidence and limits

Git establishes worktree boundaries and changed paths, without identifying the responsible agent. Scope establishes intended files. Activity records establish reported reads and writes. Provided instructions are not proof that a model has read or retained them. Ranking prioritizes current work, then explicit importance and recency, then declared output fallback. Retrospective view includes reported writes only.

Tmux persistence is an attribute on an agent card. It never creates a durable infrastructure node. Other durable instances use explicit resource declarations with optional evidence documents and dependency/feedback relationships. The map does not probe, launch, deploy, or stop those instances.

Collection runs while the map is mounted and its window is visible, unminimized, and unobscured. Hidden maps retain the last snapshot. Git output/time and baseline file counts are bounded. Markdown indexing reads up to twenty files of 128 KB each, caches their metadata, and adds at most 400 source/heading nodes. It does not fetch URLs. The document viewer enforces its existing text and static-preview size limits.

Activity imports retain at most 500 path/operation records per session and 100 reported instances per task. A separate nonblocking activity lock protects atomic merges; a busy producer retries. No report content executes, and no model call or prompt injection is needed for collection. Provider event capture remains a separate integration described in the [tracking plan](tracking-plan.md). Files changed before reporting began are not reconstructed from ambiguous shared Git state.

Validation covers the geometry budget, four-connection rule, parent collapse and drill-in, line/card separation, history ranking and session isolation, subagent ancestry, document conversations, and collector failures. CLI smoke checks use a temporary Git repository and support store. Native interaction and transition appearance are left for manual assessment; no UI automation is run.
