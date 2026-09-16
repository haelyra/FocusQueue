<!-- fq-architecture: {"id":"ui","title":"Queue and document presentation","sources":[{"path":"Sources/ECCFocusQueue/QueueView.swift","sha256":"fc641610179a65a323c328a8bb5f8bcbe874dcf78b00f1d410c054f8331a7370"},{"path":"Sources/ECCFocusQueue/QueueViewModel.swift","sha256":"6400cee20810610d31ddced6848d03b75f417d161ede51404d409c0b0e734b11"},{"path":"Sources/ECCFocusQueue/AgentLaunchLog.swift","sha256":"112c11f967b19ff9b71c001376784f122bedbebc1ec079cc7deb8679e1a23a64"},{"path":"Sources/ECCFocusQueue/FocusQueueApp.swift","sha256":"3dcf9544c4a138a21d2060e63fc3db57892f3df282ce4713522f5e7db27b4cec"},{"path":"Sources/ECCFocusQueue/PlanCanvasView.swift","sha256":"3f3f8e14581714f149a378153035f884a23b5004e309f5217496274456cceedc"},{"path":"Sources/ECCFocusQueue/AgentUpdateView.swift","sha256":"4d41f5110fbe7dac9df4418ee4b0caa2b1607547bbf6a4e6fda90af8056e655c"},{"path":"Sources/ECCFocusQueue/TerminalBrowserView.swift","sha256":"e0f72499a25edbf36e78d6d44879c31c17a682e9ac060bf1f98e06369af491fe"},{"path":"Sources/ECCFocusQueue/MarkdownBrowser.swift","sha256":"0776d96bcc658b9404f612c03b59553aa8f64735a53a8082fad7b0d12f8e937d"}]} -->

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
