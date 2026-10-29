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

  @Test("Opaque mode uses fully opaque panel surfaces")
  func opaquePanelSurfaces() throws {
    let dark = try #require(NSColor(QueuePalette.panel(for: .dark, opaqueBackgrounds: true))
      .usingColorSpace(.deviceRGB))
    let light = try #require(NSColor(QueuePalette.panel(for: .light, opaqueBackgrounds: true))
      .usingColorSpace(.deviceRGB))

    #expect(dark.alphaComponent == 1)
    #expect(light.alphaComponent == 1)
    #expect(dark.brightnessComponent < NSColor(QueuePalette.component(for: .dark)).brightnessComponent)
    #expect(light.redComponent == 1)
    #expect(light.greenComponent == 1)
    #expect(light.blueComponent == 1)
  }
}

private final class PanelEdgeProbeView: NSView {}

private struct PanelEdgeProbe: NSViewRepresentable {
  let probe: PanelEdgeProbeView

  func makeNSView(context: Context) -> PanelEdgeProbeView { probe }
  func updateNSView(_ nsView: PanelEdgeProbeView, context: Context) {}
}
