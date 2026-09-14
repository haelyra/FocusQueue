<!-- fq-architecture: {"id":"ui","title":"Queue and document presentation","sources":[{"path":"Sources/ECCFocusQueue/QueueView.swift","sha256":"673c80ec70c6dce24a7b233d8dbf921d0a98e78f554382f0e463ca2215ac819d"},{"path":"Sources/ECCFocusQueue/QueueViewModel.swift","sha256":"8f08dacbdb71af1bf767bc301f559c0e423832ec23ba6834e50ef13f42cb5e9b"},{"path":"Sources/ECCFocusQueue/AgentLaunchLog.swift","sha256":"a99e91a96cb8738584c6c723024598b733c3d3d8f4678813373a92fed5864a12"},{"path":"Sources/ECCFocusQueue/FocusQueueApp.swift","sha256":"711c96182c44a67bbdbf3ddb3bd21b1591a6a93d9d8211bf044ff846937be732"},{"path":"Sources/ECCFocusQueue/PlanCanvasView.swift","sha256":"b5c9d8a1710aadfaf54322e3015762e089781e95c501ce2501b5af892ce3b470"},{"path":"Sources/ECCFocusQueue/AgentUpdateView.swift","sha256":"e9ef1000f47c252815c298fe5d3b55741cee6b426f0e66ea3b8a37c7c49efa8f"},{"path":"Sources/ECCFocusQueue/TerminalBrowserView.swift","sha256":"e0f72499a25edbf36e78d6d44879c31c17a682e9ac060bf1f98e06369af491fe"},{"path":"Sources/ECCFocusQueue/MarkdownBrowser.swift","sha256":"0776d96bcc658b9404f612c03b59553aa8f64735a53a8082fad7b0d12f8e937d"}]} -->

# Queue and document presentation

The observable view model coordinates queue state and presentation; AppKit owns the floating window and its actual bounds. Plan documents and agent updates are distinct inspectors with different user intents.

## Follow the code

- [QueueViewModel.swift](../../Sources/ECCFocusQueue/QueueViewModel.swift): opens the requested inspector, coordinates refreshes and async task actions, and persists local decisions.
- [QueueView.swift](../../Sources/ECCFocusQueue/QueueView.swift): presents named agent rows, explicit actions, and labeled status indicators. Status combines text, icon, and color so unread completion and agent activity remain distinct.
- [TerminalBrowserView.swift](../../Sources/ECCFocusQueue/TerminalBrowserView.swift): lists live panes, filters terminal metadata, and exposes progress while an exact pane is activated.
- [AgentLaunchLog.swift](../../Sources/ECCFocusQueue/AgentLaunchLog.swift): retains bounded, private JSON Lines events for each launch phase without recording provider prompts.
- [FocusQueueApp.swift](../../Sources/ECCFocusQueue/FocusQueueApp.swift), `AppDelegate`: owns panel sizing, Dock behavior, display placement, and menu-bar integration. Collapsing must reduce the actual window hitbox as well as SwiftUI content.
- [PlanCanvasView.swift](../../Sources/ECCFocusQueue/PlanCanvasView.swift): keeps document tabs, draft editing, and task conversation together. Embedded WebKit rendering disables document-authored JavaScript, installs app-owned selection and diagram scripts in an isolated content world, and avoids rerendering unchanged input.
- [MarkdownBrowser.swift](../../Sources/ECCFocusQueue/MarkdownBrowser.swift), `EmbeddedDocumentLink`: routes local document links through an app scheme, validates destinations, and normalizes Markdown paths.
- [AgentUpdateView.swift](../../Sources/ECCFocusQueue/AgentUpdateView.swift): presents the selected update, verifier output, context links, and a task-scoped response field.

## Boundaries and checks

Source-backed updates should open their relevant content, not a generic plan. View identity and async cancellation matter when switching tasks. Headless document, geometry, and model tests are the default; UI automation requires explicit task opt-in.

Summary semantics are unverified after generation. Window and notification interactions still need real-user validation before a public release.
