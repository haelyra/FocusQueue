import AppKit
import ApplicationServices
import FocusQueueCore

enum TerminalFocusModeError: Error, LocalizedError {
    case accessibilityPermissionRequired
    case applicationUnavailable(String)
    case focusedWindowUnavailable
    case windowFrameUnavailable
    case windowMoveFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            "Confirm ECC Focus Queue is enabled in System Settings > Privacy & Security > Accessibility, then click View Agent again."
        case .applicationUnavailable(let name):
            "\(name) did not become available after the terminal was activated."
        case .focusedWindowUnavailable:
            "The active WezTerm window could not be identified."
        case .windowFrameUnavailable:
            "The active WezTerm window position could not be read."
        case .windowMoveFailed:
            "The active WezTerm window could not be centered."
        }
    }
}

@MainActor
final class TerminalFocusModeController {
    private weak var queuePanel: NSPanel?
    private var backdropWindows: [FocusBackdropWindow] = []
    private var controlPanel: FocusControlPanel?

    private(set) var isActive = false
    var stateDidChange: ((Bool) -> Void)?

    init(queuePanel: NSPanel) {
        self.queuePanel = queuePanel
    }

    func begin(
        applicationName: String,
        windowTitleHint: String?,
        targetScreen: NSScreen?
    ) async throws {
        clearFocusMode(revealQueue: false)

        guard requestAccessibilityPermission() else {
            throw TerminalFocusModeError.accessibilityPermissionRequired
        }
        guard let application = await waitForApplication(named: applicationName) else {
            throw TerminalFocusModeError.applicationUnavailable(applicationName)
        }

        application.activate(options: [.activateAllWindows])
        guard let window = await waitForWindow(
            of: application,
            titleHint: windowTitleHint
        ) else {
            throw TerminalFocusModeError.focusedWindowUnavailable
        }
        let currentFrame = try frame(of: window)
        let screen = targetScreen ?? screen(containingAXFrame: currentFrame) ?? NSScreen.main
        guard let screen else { throw TerminalFocusModeError.windowFrameUnavailable }

        let targetFrame = TerminalFocusGeometry.centeredFrame(
            currentFrame: currentFrame,
            visibleFrame: axFrame(fromAppKitFrame: screen.visibleFrame)
        )

        do {
            try await animate(window: window, from: currentFrame, to: targetFrame)
            try raise(window: window, application: application, activateApplication: true)
            let focusedWindowNumber = windowNumber(
                ownedBy: application.processIdentifier,
                matchingAXFrame: try frame(of: window)
            )
            showFocusChrome(on: screen, belowWindowNumber: focusedWindowNumber)
            isActive = true
            stateDidChange?(true)
            queuePanel?.orderFrontRegardless()
            if focusedWindowNumber == nil {
                try raise(window: window, application: application, activateApplication: true)
                queuePanel?.orderFrontRegardless()
            }
        } catch {
            clearFocusMode(revealQueue: true)
            throw error
        }
    }

    func dismiss() {
        clearFocusMode(revealQueue: true)
    }

    func queuePanelFrameDidChange() {
        guard isActive else { return }
        queuePanel?.orderFrontRegardless()
    }

    private func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func waitForApplication(named applicationName: String) async -> NSRunningApplication? {
        for _ in 0..<40 {
            if let application = runningApplication(named: applicationName) { return application }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func runningApplication(named applicationName: String) -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           application(frontmost, matches: applicationName) {
            return frontmost
        }
        if applicationName.caseInsensitiveCompare("WezTerm") == .orderedSame,
           let application = NSRunningApplication.runningApplications(
               withBundleIdentifier: "com.github.wez.wezterm"
           ).first {
            return application
        }
        return NSWorkspace.shared.runningApplications.first {
            application($0, matches: applicationName)
        }
    }

    private func application(_ application: NSRunningApplication, matches name: String) -> Bool {
        if application.bundleIdentifier == "com.github.wez.wezterm",
           name.caseInsensitiveCompare("WezTerm") == .orderedSame {
            return true
        }
        return application.localizedName?.caseInsensitiveCompare(name) == .orderedSame
    }

    private func waitForWindow(
        of application: NSRunningApplication,
        titleHint: String?
    ) async -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        for attempt in 0..<30 {
            if let titleHint {
                if let titledWindow = window(in: applicationElement, matching: titleHint) {
                    return titledWindow
                }
                if attempt >= 5, let focusedWindow = focusedWindow(in: applicationElement) {
                    return focusedWindow
                }
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            if let focusedWindow = focusedWindow(in: applicationElement) { return focusedWindow }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func focusedWindow(in application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
            let value
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func window(in application: AXUIElement, matching titleHint: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
            let windows = value as? [AXUIElement]
        else {
            return nil
        }

        let normalizedHint = titleHint.lowercased()
        return windows.first { window in
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window,
                kAXTitleAttribute as CFString,
                &titleValue
            ) == .success,
                let title = titleValue as? String
            else {
                return false
            }
            return title.lowercased().contains(normalizedHint)
        }
    }

    private func frame(of window: AXUIElement) throws -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
            AXUIElementCopyAttributeValue(
                window,
                kAXSizeAttribute as CFString,
                &sizeValue
            ) == .success,
            let positionValue,
            let sizeValue
        else {
            throw TerminalFocusModeError.windowFrameUnavailable
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            throw TerminalFocusModeError.windowFrameUnavailable
        }
        return CGRect(origin: position, size: size)
    }

    private func animate(window: AXUIElement, from start: CGRect, to end: CGRect) async throws {
        let steps = 18
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let eased = 1 - pow(1 - progress, 3)
            let frame = CGRect(
                x: interpolate(start.minX, end.minX, eased),
                y: interpolate(start.minY, end.minY, eased),
                width: interpolate(start.width, end.width, eased),
                height: interpolate(start.height, end.height, eased)
            )
            try set(frame: frame, for: window)
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func set(frame: CGRect, for window: AXUIElement) throws {
        var size = frame.size
        var position = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &position),
              AXUIElementSetAttributeValue(
                  window,
                  kAXSizeAttribute as CFString,
                  sizeValue
              ) == .success,
              AXUIElementSetAttributeValue(
                  window,
                  kAXPositionAttribute as CFString,
                  positionValue
              ) == .success else {
            throw TerminalFocusModeError.windowMoveFailed
        }
    }

    private func raise(
        window: AXUIElement,
        application: NSRunningApplication,
        activateApplication: Bool
    ) throws {
        if activateApplication {
            let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetAttributeValue(
                applicationElement,
                kAXFrontmostAttribute as CFString,
                kCFBooleanTrue
            )
        }
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
            throw TerminalFocusModeError.windowMoveFailed
        }
    }

    private func showBackdrops(belowWindowNumber focusedWindowNumber: Int?) {
        for screen in NSScreen.screens {
            let window = FocusBackdropWindow(frame: screen.frame) { [weak self] in
                self?.dismiss()
            }
            window.alphaValue = 0
            if let focusedWindowNumber {
                window.order(.below, relativeTo: focusedWindowNumber)
            } else {
                window.orderFrontRegardless()
            }
            backdropWindows.append(window)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for window in backdropWindows {
                window.animator().alphaValue = 1
            }
        }
    }

    private func showFocusChrome(on screen: NSScreen, belowWindowNumber focusedWindowNumber: Int?) {
        showBackdrops(belowWindowNumber: focusedWindowNumber)
        showControls(on: screen)
    }

    private func windowNumber(ownedBy processIdentifier: pid_t, matchingAXFrame target: CGRect) -> Int? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        return windowInfo.compactMap { info -> (number: Int, distance: CGFloat)? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == processIdentifier,
                (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                )
            else {
                return nil
            }

            let distance = abs(bounds.minX - target.minX)
                + abs(bounds.minY - target.minY)
                + abs(bounds.width - target.width)
                + abs(bounds.height - target.height)
            return (number, distance)
        }
        .filter { $0.distance <= 12 }
        .min { $0.distance < $1.distance }?
        .number
    }

    private func showControls(on screen: NSScreen) {
        let size = CGSize(width: 44, height: 44)
        let frame = CGRect(
            x: screen.visibleFrame.midX - (size.width / 2),
            y: screen.visibleFrame.maxY - size.height - 12,
            width: size.width,
            height: size.height
        ).integral
        let panel = FocusControlPanel(
            frame: frame,
            onDismiss: { [weak self] in self?.dismiss() }
        )
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        controlPanel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func removeFocusChrome() {
        let windows = backdropWindows
        backdropWindows.removeAll()
        let controls = controlPanel
        controlPanel = nil
        windows.forEach { $0.orderOut(nil) }
        controls?.orderOut(nil)
    }

    private func clearFocusMode(revealQueue: Bool) {
        removeFocusChrome()
        isActive = false
        stateDidChange?(false)

        if revealQueue {
            queuePanel?.orderFrontRegardless()
        }
    }

    private func screen(containingAXFrame frame: CGRect) -> NSScreen? {
        let appKitFrame = appKitFrame(fromAXFrame: frame)
        return NSScreen.screens
            .map { ($0, $0.frame.intersection(appKitFrame).area) }
            .max { $0.1 < $1.1 }?
            .0
    }

    private func axFrame(fromAppKitFrame frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryScreenTop - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func appKitFrame(fromAXFrame frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryScreenTop - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private var primaryScreenTop: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
        start + ((end - start) * progress)
    }
}

private final class FocusBackdropWindow: NSWindow {
    init(frame: CGRect, onDismiss: @escaping @MainActor () -> Void) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = NSColor(calibratedWhite: 0.015, alpha: 0.64)
        hasShadow = false
        level = .normal
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = FocusBackdropView(onDismiss: onDismiss)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FocusControlPanel: NSPanel {
    init(
        frame: CGRect,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Terminal Focus Controls"
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = FocusControlView(
            onDismiss: onDismiss
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class FocusControlView: NSVisualEffectView {
    private let onDismiss: @MainActor () -> Void

    init(
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)

        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        let closeButton = NSButton(
            image: NSImage(
                systemSymbolName: "xmark",
                accessibilityDescription: "Exit terminal focus"
            ) ?? NSImage(),
            target: self,
            action: #selector(didChooseDismiss)
        )
        closeButton.bezelStyle = .circular
        closeButton.controlSize = .regular
        closeButton.contentTintColor = .white
        closeButton.toolTip = "Exit terminal focus"
        closeButton.setAccessibilityLabel("Exit terminal focus")

        let stack = NSStackView(views: [closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func didChooseDismiss() {
        onDismiss()
    }
}

private final class FocusBackdropView: NSView {
    private let onDismiss: @MainActor () -> Void
    private let acceptsDismissalAfter = ProcessInfo.processInfo.systemUptime + 0.5

    init(onDismiss: @escaping @MainActor () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard ProcessInfo.processInfo.systemUptime >= acceptsDismissalAfter else { return }
        Task { @MainActor in onDismiss() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}
