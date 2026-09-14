<!-- fq-architecture: {"id":"ui","title":"Queue and document presentation","sources":[{"path":"Sources/ECCFocusQueue/QueueViewModel.swift","sha256":"0e00a3d87aee0382f7d0987e1bd520c242021a3915f639d9fcd81940ccb86fab"},{"path":"Sources/ECCFocusQueue/FocusQueueApp.swift","sha256":"711c96182c44a67bbdbf3ddb3bd21b1591a6a93d9d8211bf044ff846937be732"},{"path":"Sources/ECCFocusQueue/PlanCanvasView.swift","sha256":"b5c9d8a1710aadfaf54322e3015762e089781e95c501ce2501b5af892ce3b470"},{"path":"Sources/ECCFocusQueue/AgentUpdateView.swift","sha256":"2cfab300baa0263b764935c4e921b3bf43333a65034f5bbc0e12b6c08a955e06"},{"path":"Sources/ECCFocusQueue/MarkdownBrowser.swift","sha256":"0776d96bcc658b9404f612c03b59553aa8f64735a53a8082fad7b0d12f8e937d"}]} -->

# Queue and document presentation

The observable view model coordinates queue state and presentation; AppKit owns the floating window and its actual bounds. Plan documents and agent updates are distinct inspectors with different user intents.

## Follow the code

- [QueueViewModel.swift](../../Sources/ECCFocusQueue/QueueViewModel.swift): opens the requested inspector, coordinates refreshes and async task actions, and persists local decisions.
- [FocusQueueApp.swift](../../Sources/ECCFocusQueue/FocusQueueApp.swift), `AppDelegate`: owns panel sizing, Dock behavior, display placement, and menu-bar integration. Collapsing must reduce the actual window hitbox as well as SwiftUI content.
- [PlanCanvasView.swift](../../Sources/ECCFocusQueue/PlanCanvasView.swift): keeps document tabs, draft editing, and task conversation together. Embedded WebKit rendering disables document-authored JavaScript, installs app-owned selection and diagram scripts in an isolated content world, and avoids rerendering unchanged input.
- [MarkdownBrowser.swift](../../Sources/ECCFocusQueue/MarkdownBrowser.swift), `EmbeddedDocumentLink`: routes local document links through an app scheme, validates destinations, and normalizes Markdown paths.
- [AgentUpdateView.swift](../../Sources/ECCFocusQueue/AgentUpdateView.swift): presents the selected update, verifier output, context links, and a task-scoped response field.

## Boundaries and checks

Source-backed updates should open their relevant content, not a generic plan. View identity and async cancellation matter when switching tasks. Headless document, geometry, and model tests are the default; UI automation requires explicit task opt-in.

Summary semantics are unverified after generation. Window and notification interactions still need real-user validation before a public release.
