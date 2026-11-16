import AppKit
import WebKit

/// A web view for looking at pages: visual zoom and right-drag panning.
///
/// Zoom uses WebKit magnification, which scales what is drawn without changing
/// the page's layout viewport, so media queries and canvas viewports stay
/// honest. A right-button drag pans by sending the page scroll-wheel events at
/// the cursor, so it moves the document or whatever scroll area is under the
/// pointer, exactly like a trackpad would. A right click without a drag still
/// opens the normal context menu.
final class ZoomableWebView: WKWebView {
    static let zoomRange: ClosedRange<CGFloat> = 0.25...4
    static let zoomStep: CGFloat = 1.25
    /// Movement under this many points is a click, not a drag.
    static let dragThreshold: CGFloat = 3

    var onMagnificationChange: ((CGFloat) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        allowsMagnification = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func zoomIn() { setZoom(magnification * Self.zoomStep) }
    func zoomOut() { setZoom(magnification / Self.zoomStep) }
    func resetZoom() { setZoom(1) }

    func setZoom(_ value: CGFloat) {
        let clamped = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, value))
        setMagnification(clamped, centeredAt: NSPoint(x: bounds.midX, y: bounds.midY))
        onMagnificationChange?(magnification)
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onMagnificationChange?(magnification)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let window else { return super.rightMouseDown(with: event) }
        let start = event.locationInWindow
        var last = start
        var dragging = false
        while let next = window.nextEvent(matching: [.rightMouseDragged, .rightMouseUp]) {
            if next.type == .rightMouseUp { break }
            let point = next.locationInWindow
            if !dragging {
                guard hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold else { continue }
                dragging = true
                NSCursor.closedHand.push()
            }
            pan(dx: point.x - last.x, dy: point.y - last.y, at: point)
            last = point
        }
        if dragging { NSCursor.pop() } else { super.rightMouseDown(with: event) }
    }

    /// Moves the content with the pointer: a drag right or down reveals what is
    /// left or above. `dx`/`dy` are window points (y up).
    func pan(dx: CGFloat, dy: CGFloat, at windowPoint: NSPoint) {
        guard dx != 0 || dy != 0, let window,
              let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: Int32((-dy).rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)
        else { return }
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        scroll.location = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
        if let wheel = NSEvent(cgEvent: scroll) { scrollWheel(with: wheel) }
    }
}

/// Hosts a `ZoomableWebView` with a small floating −/percent/+ control in the
/// bottom-right corner. Clicking the percentage resets to 100%.
final class ZoomableWebContainer: NSView {
    let webView: ZoomableWebView
    private let label = NSButton(title: "100%", target: nil, action: nil)

    init(configuration: WKWebViewConfiguration) {
        webView = ZoomableWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        let minus = Self.button(symbol: "minus.magnifyingglass", help: "Zoom out")
        let plus = Self.button(symbol: "plus.magnifyingglass", help: "Zoom in")
        minus.target = self; minus.action = #selector(zoomOut)
        plus.target = self; plus.action = #selector(zoomIn)
        label.target = self; label.action = #selector(resetZoom)
        label.isBordered = false
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.toolTip = "Reset zoom to 100%"
        label.setAccessibilityLabel("Reset zoom")
        label.widthAnchor.constraint(equalToConstant: 42).isActive = true

        let stack = NSStackView(views: [minus, label, plus])
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 8
        bar.layer?.masksToBounds = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        addSubview(bar)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        webView.onMagnificationChange = { [weak self] value in self?.showZoom(value) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func button(symbol: String, help: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    private func showZoom(_ value: CGFloat) { label.title = "\(Int((value * 100).rounded()))%" }
    @objc private func zoomIn() { webView.zoomIn() }
    @objc private func zoomOut() { webView.zoomOut() }
    @objc private func resetZoom() { webView.resetZoom() }
}
