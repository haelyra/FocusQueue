import AppKit
import SwiftUI

@MainActor final class MapVisibilityHandle {
    weak var window: NSWindow?
    var isVisible: Bool { window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false }
}

/// Observation only. It never changes focus, window placement, or visibility.
struct MapVisibilityProbe: NSViewRepresentable {
    let handle: MapVisibilityHandle
    func makeNSView(context: Context) -> Probe { Probe(handle: handle) }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.handle = handle }
    final class Probe: NSView {
        var handle: MapVisibilityHandle
        init(handle: MapVisibilityHandle) { self.handle = handle; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); handle.window = window }
    }
}
