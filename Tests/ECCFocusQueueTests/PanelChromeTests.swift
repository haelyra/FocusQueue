import AppKit
import SwiftUI
import Testing

@testable import ECCFocusQueue

@Suite("Panel chrome alignment")
@MainActor
struct PanelChromeTests {
  @Test("Expanded panel content reaches the draggable window top edge")
  func expandedContentFillsWindowFrame() throws {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 780),
      styleMask: [
        .titled, .resizable, .miniaturizable, .nonactivatingPanel, .fullSizeContentView,
      ],
      backing: .buffered,
      defer: false
    )
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true

    let probe = PanelEdgeProbeView()
    let hostingView = NSHostingView(rootView: FullFramePanelContent {
      PanelEdgeProbe(probe: probe)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    })
    hostingView.sizingOptions = []
    panel.contentView = hostingView
    panel.layoutIfNeeded()
    hostingView.layoutSubtreeIfNeeded()

    #expect(hostingView.safeAreaInsets.top > 0)
    #expect(probe.frame.maxY == hostingView.bounds.maxY)
  }
}

private final class PanelEdgeProbeView: NSView {}

private struct PanelEdgeProbe: NSViewRepresentable {
  let probe: PanelEdgeProbeView

  func makeNSView(context: Context) -> PanelEdgeProbeView { probe }
  func updateNSView(_ nsView: PanelEdgeProbeView, context: Context) {}
}
