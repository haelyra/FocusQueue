# Workspace map and document panes

The Central plan has a Map tab and a reusable side document pane. The queue remains visible. The map groups file hierarchy into context, agents, and declared outputs; the document pane supports reading and discussing linked files without replacing the central plan or stopping its conversation.

## User flow

1. Open a task’s Central plan. The panel expands to a more comfortable default width, assigning about 74% of its inspector to the document and 26% to chat. Drag the divider to adjust it.
2. In Map, Typical shows repository context and grouped agent outputs by default. Shared context is drawn once per workspace; parents share their children’s vertical span instead of each consuming a row. Use Other files or the folder controls to browse additional paths.
3. Select an agent to highlight its input/output files and arrows. Dashed arrows represent provided or declared context, and green arrows represent declared outputs. No output arrow is invented from Git status alone.
4. Click a file in the map or a link in the central plan to open the side document pane. Further links become tabs in that pane. Markdown is rendered, source files are read-only text, and HTML/PDF/images/web links use a static embedded viewer. Local Obsidian and VS Code file links resolve into the same pane.
5. The central chat automatically collapses when a document opens. Its request and draft remain alive. The side pane opens a separate document chat with the task, central plan, selected document, and applicable ancestor AGENTS.md files as context.
6. Hide the document pane to restore the central chat. Tabs and document chat objects remain retained. Closing a tab does not cancel its running request. Each document has a distinct persistent transcript, provider session name, and harness runtime directory.

Folder launching is disconnected from the map. Its Finder implementation remains as a commented, unreachable helper for a future explicit action. The previous external Neovim/VS Code opening method is also retained but is no longer connected to file clicks.

The plan’s Markdown and Mermaid rendering use neutral gray backgrounds. Decorative gradients are removed. Task lists render disabled checked/unchecked controls while fenced and inline code examples remain literal. The map uses a more opaque neutral surface than the surrounding pane.

## Modular implementation

- `Sources/FocusQueueMap/`: versioned Codable snapshot, read-only Git collector, deterministic bounded layout, validated file actions, and private atomic snapshot cache. Depends on the existing core process runner and context types.
- `Sources/FocusQueueMapCLI/`: standalone `focus-queue-map` helper using that same collector. It reads task context, registered state, and pending registrations without acknowledging them or writing canonical task state.
- `Sources/ECCFocusQueue/WorkspaceMapModel.swift` and `WorkspaceMapView.swift`: presentation and selection. `WorkspaceMapProjection` uses the reusable `MapDiagram` template for physical hierarchy and view selection. `DocumentPaneState`, `SideDocumentPane`, and `DocumentConversation` own side-by-side reading and independent chat. The existing plan view adds a small tab switch and passes task selection, file navigation, and chat-draft callbacks.
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

Snapshots contain `schemaVersion`, `taskID`, `generatedAt`, `nodes`, `warnings`, and `omittedPaths`. Each node has a typed `kind`, stable ID, parent reference, source evidence, optional location, and optional agent state or Git status. Parent relationships encode physical containment and assignment. Optional typed `relations` encode provided/declared inputs, declared outputs, dependencies, and feedback. Old snapshots without relationships remain readable. Agent-authored grouping remains a later phase.

## Reporting actual input/output scope

The collector always includes the registered central plan and applicable AGENTS.md files as provided context. This means they are part of the assignment; it does not prove the model read or retained them. Agent-specific inputs and outputs come from explicit declarations:

```sh
Scripts/focus-queue-map scope ECC-123 SUBTASK-ID --input Docs/brief.md --output Sources/Feature.swift
Scripts/focus-queue-map scope ECC-123 SUBTASK-ID --clear
```

Replace the task and subtask IDs with a real assignment. Repeat the path flags for multiple files. Relative paths resolve in the registered worktree. Each declaration replaces the previous one and is bound to the provider session, so reassignment cannot inherit another agent’s scope. The CLI stores independent private files under the task’s `workspace-map/scopes/` directory. New agent initialization prompts describe this reporting step when the installed map helper is available. Existing agents can use the command without restarting. There is no transcript scraping or inferred per-agent authorship from Git changes.

## Facts, freshness, and limits

- Working reports become stale after five minutes. Missing heartbeats and substantial clock skew are explicit; completed reports remain completed.
- Git proves workspace boundaries and changed paths. Its files remain unattributed until an agent declares scope. Declared output means intended scope, not proof of completed production.
- Collection runs about every five seconds while the map is visible, caches tracked files for thirty seconds, bounds Git output and execution time, and prioritizes changed paths within a 400-file-per-workspace baseline. Explicit context paths are included even when untracked or outside that baseline.
- The flow renderer caps visible instances at 180 and reserves agent positions before filling in large context trees. Shared context appears once within a workspace; a file used as both input and output has two visual instances with one physical identity. Other files are available through the directory browser.
- Cache writes are atomic and private. Failed scans retain the last successful observation and its original age. Partial maps do not replace the durable complete cache.
- File preview routes resolve registered locations and reject escaping symlinks. Missing output files report that they are unavailable instead of opening another application.
- Text previews are limited to 2 MB; other local previews to 20 MB. Document chat includes bounded fresh excerpts and the central plan/instruction paths so the agent can inspect further as needed. Page scripts are disabled in the static resource viewer.
- Document conversations are retained by the queue model, independent of view lifetime. Separate harness runtime directories avoid the legacy shared session lock serializing central and document requests. The task context directory remains available to the document agent.
- Linked-worktree identity survives `git worktree move`; moving the repository’s Git metadata itself still changes its identity.

## Validation and remaining review

Headless tests cover layout spacing and overlap, shared context, read/write projections, agent highlighting, scope reassignment, CLI declarations, tab identity and restoration, conversation persistence and independent replies, runtime lock isolation, path handling, and existing collection failure cases. WebKit is checked without a window for actual checkbox state and neutral computed background color. UI automation remains disabled; pointer behavior and the native visual composition remain for manual review.

Fleet-wide scope, provider tool-event adapters, agent-authored presentation rules, and semantic changes since last visit remain follow-up work. Current input/output scope is explicit, while Changed files continues to mean current Git status.

## Reusable template and view projections (schema v2)

The active renderer now uses `MapDiagram`, `WorkspaceMapProjection`, and `InteractiveMapCanvas`. `MapDiagram` is a Codable geometry contract with cards, containers, directed edges, a bounded leaf-packing forest, and deterministic positions. Its containment tree is separate from its potentially cyclic dependency/feedback edges. `WorkspaceMapProjection` applies task semantics and expansion rules. `InteractiveMapCanvas` accepts the diagram and callbacks with no task collector or provider dependency. `MapFlowLayout` remains a legacy API for existing callers; it is no longer used by the application.

Typical is the initial view. Click the Focus Queue node or context workspace header for Context; click an agent for Agent view. The three shared task context slots stay outside workspace boxes. Typical shows repository-level inputs and folded output folders. Expanded exposes five or fewer file children; more than five remain behind a folder expansion control. Agent view includes its individual inputs and outputs, with external inputs outside its worktree container. Markdown source headings become expandable representatives for inline links and HTTP autolinks. Fenced examples and image links are omitted. General Markdown parsing, including all reference-link syntax, remains a follow-up.

The diagram uses a 180-card limit, compressed single-child directory chains, and a width-fitting option. Context sources and declared scope remain facts in the snapshot; expansion changes their presentation only. Declarations older than 30 minutes are hidden from execution projections unless Include older scope is on. This does not claim per-file read/write activity. See [the tracking research and adapter plan](tracking-plan.md).

Collection runs only while the map is mounted and its host window is visible, unminimized, and unobscured. Hidden views keep their last snapshot. Markdown indexing caches file modification metadata, reads at most 20 inputs of 128 KB each, and adds at most 400 source/heading nodes per snapshot. No URLs are fetched during collection.

The metadata strip below document tabs provides the path, file type, size, modified date, and explicit Show in Finder action. Map folder launching remains disconnected. Hovering for one second or using a context menu exposes a map item's path or URL. Code files use plain text previews.

### CLI diagram and resource entry points

```sh
Scripts/focus-queue-map diagram TASK-ID --view typical --output /tmp/map-diagram.json
Scripts/focus-queue-map diagram TASK-ID --view context --output /tmp/context-diagram.json
Scripts/focus-queue-map diagram TASK-ID --view agent --agent SUBTASK-ID --expanded
Scripts/focus-queue-map resources TASK-ID --import /path/to/resources.json
```

Resource imports atomically replace the task's private resource manifest after validating task identity and graph endpoints. The manifest supports stable durable instances, optional registered workspace and evidence-document location, and explicit `dependency`, `feedback`, and `handoff` edges. Resource endpoints use `resource:<id>`; agent endpoints use `agent:<subtaskID>`; existing collected path endpoints use `file:<absolute path>`. The [example manifest](resources.example.json) is fictional and requires replacing all placeholders. Nothing is launched, probed, or automatically stopped by importing it.

Saved tmux instance identities are also included from recorded subtask state. Recorded and declared resources are labeled with unverified availability; they persist independently of recent file scope. Snapshot schema v2 adds context, heading, link, and resource node kinds plus general relationship types. The reader still accepts v1 snapshots.

### Adding another in-app map

A small map can directly compose the shared template instead of creating another layout engine:

```swift
var diagram = MapDiagram(limit: 80)
let source = MapNode(id: "source", parentID: nil, kind: .document,
                     label: "Brief", evidence: "Registered document")
let output = MapNode(id: "output", parentID: nil, kind: .resource,
                     label: "Build", evidence: "Recorded result")
diagram.add(source, x: 16, y: 16, role: "Input")
diagram.add(output, x: 224, y: 16, role: "Output")
diagram.connect(source.id, output.id, kind: "dependency")
diagram.finish()
```

Pass that value to `InteractiveMapCanvas` with a card-building closure and a container-selection callback. Use `forest(nodes:roots:prefix:x:y:role:hidden:)` for directory-like containment. Keep data collection and navigation outside the renderer; place any task/project-specific visibility policy in a projection. `MapSnapshot.validated()` checks canonical task snapshots, while the independent `MapDiagram` can represent other kinds of in-app maps without requiring a task queue root.

This revision passed 228 Swift tests and 127 Python tests. A temporary CLI fixture additionally checked scope registration, import validation and preservation on failure, tmux identity capture, source indexing, graph endpoint integrity, and non-overlapping diagrams in all three views. CLI operations on that small fixture averaged about 0.2 seconds. Native pointer/hover interactions remain for manual assessment; no UI automation was run.
