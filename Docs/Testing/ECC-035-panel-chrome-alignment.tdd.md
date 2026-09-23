# ECC-035 panel chrome alignment TDD record

Date: 2026-09-18

## Source and user journey

The behavior came directly from the reported defect rather than a feature plan.

As a Focus Queue user, I want the visible top of the queue to coincide with the draggable
NSPanel top edge so that the graphic and its hitbox occupy the same position.

## RED

An AppKit diagnostic mounted the existing root in the same titled, full-size panel used by
the application. The content view filled all 780 points, while AppKit exposed a 32-point top
safe-area inset. The SwiftUI root respected that inset, placing the visible panel below the
window frame.

`swift test --filter PanelChromeTests` then failed to compile because the production
`FullFramePanelContent` boundary did not exist. This was the intended compile-time RED for
the missing full-frame behavior.

## GREEN

The application now wraps its queue root in `FullFramePanelContent`, which ignores only the
window container's top safe area. It does not change the NSPanel frame, draggable region, resize
constraints, or compact-mode geometry.

The same focused command passed with one test. The regression test mounts the production
wrapper in an offscreen real NSPanel, confirms AppKit still reports a positive titlebar safe
area, and confirms the rendered probe reaches the content view's exact top edge.

## Test specification

| Guarantee | Test or command | Type | Result |
|---|---|---|---|
| Visible content reaches the draggable window top even when AppKit supplies a titlebar safe area | `PanelChromeTests.expandedContentFillsWindowFrame` | AppKit integration | PASS |
| Existing Focus Queue behavior remains intact | `swift test` | Regression | PASS, 369 tests in 40 suites |
| Every executable line in the new full-frame wrapper ran | `swift test --enable-code-coverage --filter PanelChromeTests` plus `llvm-cov show` | Coverage | PASS, 6 of 6 executable wrapper lines covered |

## Known gap

Pointer-driven UI automation was not run because repository policy requires
`ECC_FOCUS_QUEUE_UI_TESTS=1`, which was not set. The affected layout workflow was exercised
headlessly with the actual NSPanel and NSHostingView types instead.
