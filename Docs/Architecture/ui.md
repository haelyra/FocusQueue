<!-- fq-architecture: {"id":"ui","title":"Queue and document presentation","sources":[{"path":"Sources/ECCFocusQueue/QueueView.swift","sha256":"c2ea8da8864eeaa2a720bbb976a97635351d55a78378930fb2e0f5c971c3ff02"},{"path":"Sources/ECCFocusQueue/QueueViewModel.swift","sha256":"b27d2cbd7d8b6116866e0321e4075117d421f0f33fa318d9b478e619c07c48c8"},{"path":"Sources/ECCFocusQueue/AgentLaunchLog.swift","sha256":"112c11f967b19ff9b71c001376784f122bedbebc1ec079cc7deb8679e1a23a64"},{"path":"Sources/ECCFocusQueue/FocusQueueApp.swift","sha256":"3574eeaeaed5da0b3fc6274c87120220d3d66430c2b73c748c8f084df7519f13"},{"path":"Sources/ECCFocusQueue/PlanCanvasView.swift","sha256":"04d8a8bb0f015409f408d0237d7dfe2db641222d84ca30beee58ef57b2f2312d"},{"path":"Sources/ECCFocusQueue/QueueInspectorLayout.swift","sha256":"4a3084fa76dfabdca2c3dd1cda18bd6116decaff1bc8c95b88e35c3b77c705ad"},{"path":"Sources/ECCFocusQueue/AgentUpdateView.swift","sha256":"e9ef1000f47c252815c298fe5d3b55741cee6b426f0e66ea3b8a37c7c49efa8f"},{"path":"Sources/ECCFocusQueue/TerminalBrowserView.swift","sha256":"e0f72499a25edbf36e78d6d44879c31c17a682e9ac060bf1f98e06369af491fe"},{"path":"Sources/ECCFocusQueue/MarkdownBrowser.swift","sha256":"0776d96bcc658b9404f612c03b59553aa8f64735a53a8082fad7b0d12f8e937d"}]} -->

# Queue and document presentation

The observable view model coordinates queue state and presentation; AppKit owns the floating window and its actual bounds. Plan documents and agent updates are distinct inspectors with different user intents.

## Follow the code

- [QueueViewModel.swift](../../Sources/ECCFocusQueue/QueueViewModel.swift): opens the requested inspector, coordinates refreshes and async task actions, and persists local decisions.
- [QueueView.swift](../../Sources/ECCFocusQueue/QueueView.swift): presents expandable named-agent rows, action menus, completed-subtask archives, and labeled status indicators. Queue chat can occupy its tab or an adjacent inspector while preserving one conversation draft.
- [TerminalBrowserView.swift](../../Sources/ECCFocusQueue/TerminalBrowserView.swift): lists live panes, filters terminal metadata, and exposes progress while an exact pane is activated.
- [AgentLaunchLog.swift](../../Sources/ECCFocusQueue/AgentLaunchLog.swift): retains bounded, private JSON Lines events for each launch phase without recording provider prompts.
- [FocusQueueApp.swift](../../Sources/ECCFocusQueue/FocusQueueApp.swift), `AppDelegate`: owns panel sizing, Dock behavior, display placement, and menu-bar integration. Collapsing must reduce the actual window hitbox as well as SwiftUI content.
- [QueueInspectorLayout.swift](../../Sources/ECCFocusQueue/QueueInspectorLayout.swift): defines the compact, chat, report, and plan widths used when the AppKit panel expands inward.
- [PlanCanvasView.swift](../../Sources/ECCFocusQueue/PlanCanvasView.swift): keeps document tabs, draft editing, and task conversation together. Embedded WebKit rendering disables document-authored JavaScript, installs app-owned selection and diagram scripts in an isolated content world, and avoids rerendering unchanged input.
- [MarkdownBrowser.swift](../../Sources/ECCFocusQueue/MarkdownBrowser.swift), `EmbeddedDocumentLink`: routes local document links through an app scheme, validates destinations, and normalizes Markdown paths.
- [AgentUpdateView.swift](../../Sources/ECCFocusQueue/AgentUpdateView.swift): presents the selected update, verifier output, context links, and a task-scoped response field.

## Boundaries and checks

Source-backed updates should open their relevant content, not a generic plan. View identity and async cancellation matter when switching tasks. Headless document, geometry, and model tests are the default; UI automation requires explicit task opt-in.

Summary semantics are unverified after generation. Window and notification interactions still need real-user validation before a public release.
