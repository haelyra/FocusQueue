import AppKit
import FocusQueueCore
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
    /// On map-like pages the scroll wheel zooms around the pointer instead of
    /// scrolling; scrollbars and right-drag still move the view.
    var wheelZooms = false

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        allowsMagnification = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func zoomIn() { setZoom(magnification * Self.zoomStep) }
    func zoomOut() { setZoom(magnification / Self.zoomStep) }
    func resetZoom() { setZoom(1) }

    /// Buttons zoom around the middle of the view.
    func setZoom(_ value: CGFloat) { zoom(to: value, keeping: NSPoint(x: bounds.midX, y: bounds.midY)) }

    override func scrollWheel(with event: NSEvent) {
        guard wheelZooms, event.scrollingDeltaY != 0 else { return super.scrollWheel(with: event) }
        // Trackpads report fine pixel deltas; mouse wheels report coarse lines.
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.006 : 0.08
        zoom(to: (zoomTarget ?? magnification) * exp(event.scrollingDeltaY * sensitivity),
             keeping: convert(event.locationInWindow, from: nil))
    }

    // WebKit's own `centeredAt:` does not keep content under the pointer (zooming
    // in jumped to the top-left), so zoom anchors itself: read the scroll
    // offset, apply the magnification, then scroll so the same page point is
    // under the same view point. Steps that arrive mid-zoom are coalesced.
    private var zoomTarget: CGFloat?
    private var zoomAnchor = NSPoint.zero
    private var isZooming = false

    func zoom(to value: CGFloat, keeping viewPoint: NSPoint) {
        zoomTarget = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, value))
        zoomAnchor = viewPoint
        if !isZooming { applyPendingZoom() }
    }

    private func applyPendingZoom() {
        guard let target = zoomTarget else { isZooming = false; return }
        zoomTarget = nil
        let old = magnification
        guard abs(target - old) > 0.0001 else { return applyPendingZoom() }
        isZooming = true
        // Page scroll offsets count from the top-left.
        let px = zoomAnchor.x, py = isFlipped ? zoomAnchor.y : bounds.height - zoomAnchor.y
        callAsyncJavaScript("return [window.scrollX, window.scrollY]", arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            let offset = ((try? result.get()) as? [Double]) ?? [0, 0]
            let pageX = offset[0] + px / old, pageY = offset[1] + py / old
            self.setMagnification(target, centeredAt: .zero)
            self.callAsyncJavaScript(
                "window.scrollTo(x, y)", arguments: ["x": pageX - px / target, "y": pageY - py / target],
                in: nil, in: .defaultClient
            ) { [weak self] _ in
                guard let self else { return }
                self.onMagnificationChange?(self.magnification)
                self.applyPendingZoom()
            }
        }
    }

    /// Scrolls so the element is centered horizontally at the top. Runs in the
    /// app's content world, so it works on pages whose own scripts are off.
    func reveal(elementID: String) {
        callAsyncJavaScript(
            "document.getElementById(id)?.scrollIntoView({block: 'start', inline: 'center'})",
            arguments: ["id": elementID], in: nil, in: .defaultClient)
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
        // super: a pan must scroll even where the wheel zooms.
        if let wheel = NSEvent(cgEvent: scroll) { super.scrollWheel(with: wheel) }
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

/// Recognizes pages written by `ProjectMapGenerator` from their generator tag,
/// so copies of a map (for example in a task's evidence folder) behave the same.
enum ProjectMapPage {
    static let generatorTag = #"<meta name="generator" content="Focus Queue project map">"#

    /// What a project map click asks for.
    enum Action: String { case locate, launch, prompt }

    static func taskURL(_ taskID: String, action: Action = .locate, provider: String? = nil) -> URL? {
        guard taskID.range(of: #"^[A-Za-z][A-Za-z0-9]*-[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "focusqueue"; components.host = "task"; components.path = "/" + taskID.uppercased()
        var query: [URLQueryItem] = []
        if action != .locate { query.append(URLQueryItem(name: "action", value: action.rawValue)) }
        if let provider, AgentProvider(rawValue: provider) != nil { query.append(URLQueryItem(name: "provider", value: provider)) }
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    static func taskID(from url: URL) -> String? { request(from: url)?.task }

    /// `focusqueue://task/<ID>[?action=launch|prompt][&provider=claude]`.
    static func request(from url: URL) -> (task: String, action: Action, provider: AgentProvider?)? {
        guard url.scheme == "focusqueue", url.host == "task" else { return nil }
        let id = url.lastPathComponent
        guard taskURL(id) != nil else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let action = items.first { $0.name == "action" }?.value.flatMap(Action.init(rawValue:)) ?? .locate
        let provider = items.first { $0.name == "provider" }?.value.flatMap(AgentProvider.init(rawValue:))
        return (id.uppercased(), action, provider)
    }

    static func isMap(_ url: URL) -> Bool {
        guard url.isFileURL, ["html", "htm"].contains(url.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2_048)) ?? Data()
        return String(decoding: head, as: UTF8.self).contains(generatorTag)
    }
}
