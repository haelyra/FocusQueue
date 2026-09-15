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
            "Confirm ECC Focus Queue is enabled in System Settings > Privacy & Security > Accessibility, then click Focus again."
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

struct TerminalFocusTarget: Equatable, Sendable {
    let applicationName: String
    let windowID: Int
    let paneID: Int
    let windowTitle: String
}

@MainActor
final class TerminalFocusModeController {
    private weak var queuePanel: NSPanel?
    private var backdropWindows: [FocusBackdropWindow] = []
    private var controlPanel: FocusControlPanel?
    private var focusedWindow: TerminalFocusWindow?
    private let accessibility = TerminalFocusAccessibility()
    private var activeOperation: TerminalFocusOperation?
    private var focusedApplication: NSRunningApplication?
    private var preferredWindowFrame: CGRect?
    private var isMovingFocusedWindow = false

    private(set) var isActive = false
    var stateDidChange: ((Bool) -> Void)?

    init(queuePanel: NSPanel) {
        self.queuePanel = queuePanel
    }

    func begin(
        target: TerminalFocusTarget,
        targetScreen: NSScreen?
    ) async throws {
        clearFocusMode(revealQueue: false)
        let operation = TerminalFocusOperation()
        activeOperation = operation

        do {
            guard requestAccessibilityPermission() else {
                throw TerminalFocusModeError.accessibilityPermissionRequired
            }
            guard let application = try await waitForFrontmostApplication(
                named: target.applicationName, operation: operation
            ) else {
                throw TerminalFocusModeError.applicationUnavailable(target.applicationName)
            }

            // WezTerm has already activated target.paneID in target.windowID. Selecting only
            // the frontmost app's focused AX window preserves that exact activation; enumerating
            // windows by the task title can pick a sibling agent window with the same title.
            try operation.checkCancellation()
            guard let window = try await accessibility.waitForFocusedWindow(
                processIdentifier: application.processIdentifier,
                titleHint: target.windowTitle, operation: operation
            ) else {
                throw TerminalFocusModeError.focusedWindowUnavailable
            }
            let currentFrame = try await accessibility.frame(of: window, operation: operation)
            try operation.checkCancellation()
            let screen = targetScreen ?? screen(containingAXFrame: currentFrame) ?? NSScreen.main
            guard let screen else { throw TerminalFocusModeError.windowFrameUnavailable }

            let targetFrame = TerminalFocusGeometry.centeredFrame(
                currentFrame: currentFrame,
                visibleFrame: axFrame(fromAppKitFrame: screen.visibleFrame)
            )

            focusedWindow = window
            focusedApplication = application
            preferredWindowFrame = currentFrame
            try await accessibility.place(window: window, from: currentFrame, to: targetFrame, operation: operation)
            try await accessibility.raise(window: window, processIdentifier: application.processIdentifier, operation: operation)
            let placedFrame = try await accessibility.frame(of: window, operation: operation)
            let focusedWindowNumber = try await accessibility.windowNumber(
                ownedBy: application.processIdentifier,
                matchingAXFrame: placedFrame, operation: operation
            )
            try operation.checkCancellation()
            showFocusChrome(on: screen, belowWindowNumber: focusedWindowNumber)
            isActive = true
            stateDidChange?(true)
            queuePanel?.orderFrontRegardless()
            if focusedWindowNumber == nil {
                try await accessibility.raise(window: window, processIdentifier: application.processIdentifier, operation: operation)
                try operation.checkCancellation()
                queuePanel?.orderFrontRegardless()
            }
        } catch is CancellationError {
            if activeOperation === operation { clearFocusMode(revealQueue: false) }
        } catch {
            if activeOperation === operation { clearFocusMode(revealQueue: true) }
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

    private func waitForFrontmostApplication(
        named applicationName: String, operation: TerminalFocusOperation
    ) async throws -> NSRunningApplication? {
        for _ in 0..<40 {
            try operation.checkCancellation()
            if let application = NSWorkspace.shared.frontmostApplication,
               self.application(application, matches: applicationName) {
                return application
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func application(_ application: NSRunningApplication, matches name: String) -> Bool {
        if application.bundleIdentifier == "com.github.wez.wezterm",
           name.caseInsensitiveCompare("WezTerm") == .orderedSame {
            return true
        }
        return application.localizedName?.caseInsensitiveCompare(name) == .orderedSame
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

    private func showControls(on screen: NSScreen) {
        let canSwitchDisplay = NSScreen.screens.count > 1
        let size = CGSize(width: canSwitchDisplay ? 84 : 44, height: 44)
        let frame = CGRect(
            x: screen.visibleFrame.midX - (size.width / 2),
            y: screen.visibleFrame.maxY - size.height - 12,
            width: size.width,
            height: size.height
        ).integral
        let panel = FocusControlPanel(
            frame: frame,
            canSwitchDisplay: canSwitchDisplay,
            onSwitchDisplay: { [weak self] in self?.moveFocusedWindowToNextDisplay() },
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

    private func moveFocusedWindowToNextDisplay() {
        guard !isMovingFocusedWindow, let operation = activeOperation else { return }
        isMovingFocusedWindow = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if activeOperation === operation { isMovingFocusedWindow = false }
            }
            do {
                try await cycleFocusedWindowToNextDisplay(operation: operation)
            } catch is CancellationError {
                return
            } catch {
                NSSound.beep()
            }
        }
    }

    private func cycleFocusedWindowToNextDisplay(operation: TerminalFocusOperation) async throws {
        try operation.checkCancellation()
        guard isActive,
              let window = focusedWindow,
              let application = focusedApplication else {
            throw TerminalFocusModeError.focusedWindowUnavailable
        }
        let screens = NSScreen.screens
        let currentFrame = try await accessibility.frame(of: window, operation: operation)
        try operation.checkCancellation()
        guard let target = TerminalFocusGeometry.nextDisplayTarget(
            currentWindowFrame: currentFrame,
            preferredWindowFrame: preferredWindowFrame ?? currentFrame,
            screenFrames: screens.map { axFrame(fromAppKitFrame: $0.frame) },
            visibleScreenFrames: screens.map { axFrame(fromAppKitFrame: $0.visibleFrame) }
        ) else {
            return
        }

        try await accessibility.place(window: window, from: currentFrame, to: target.frame, operation: operation)
        try await accessibility.raise(window: window, processIdentifier: application.processIdentifier, operation: operation)
        try operation.checkCancellation()
        positionControls(on: screens[target.screenIndex])
        queuePanel?.orderFrontRegardless()
    }

    private func positionControls(on screen: NSScreen) {
        guard let controlPanel else { return }
        let frame = CGRect(
            x: screen.visibleFrame.midX - (controlPanel.frame.width / 2),
            y: screen.visibleFrame.maxY - controlPanel.frame.height - 12,
            width: controlPanel.frame.width,
            height: controlPanel.frame.height
        ).integral
        controlPanel.setFrame(frame, display: true, animate: true)
        controlPanel.orderFrontRegardless()
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
        activeOperation?.cancel()
        activeOperation = nil
        removeFocusChrome()
        focusedWindow = nil
        focusedApplication = nil
        preferredWindowFrame = nil
        isMovingFocusedWindow = false
        let wasActive = isActive
        isActive = false
        if wasActive { stateDidChange?(false) }

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
        canSwitchDisplay: Bool,
        onSwitchDisplay: @escaping @MainActor () -> Void,
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
            canSwitchDisplay: canSwitchDisplay,
            onSwitchDisplay: onSwitchDisplay,
            onDismiss: onDismiss
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class FocusControlView: NSVisualEffectView {
    private let onSwitchDisplay: @MainActor () -> Void
    private let onDismiss: @MainActor () -> Void

    init(
        canSwitchDisplay: Bool,
        onSwitchDisplay: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.onSwitchDisplay = onSwitchDisplay
        self.onDismiss = onDismiss
        super.init(frame: .zero)

        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        let switchDisplayButton = NSButton(
            image: NSImage(
                systemSymbolName: "display.2",
                accessibilityDescription: "Move focused terminal to the next display"
            ) ?? NSImage(),
            target: self,
            action: #selector(didChooseSwitchDisplay)
        )
        switchDisplayButton.bezelStyle = .circular
        switchDisplayButton.controlSize = .regular
        switchDisplayButton.contentTintColor = .white
        switchDisplayButton.toolTip = "Move focused terminal to the next display"
        switchDisplayButton.setAccessibilityLabel("Move focused terminal to the next display")
        switchDisplayButton.isEnabled = canSwitchDisplay

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

        let buttons = canSwitchDisplay ? [switchDisplayButton, closeButton] : [closeButton]
        let stack = NSStackView(views: buttons)
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
        if canSwitchDisplay {
            NSLayoutConstraint.activate([
                switchDisplayButton.widthAnchor.constraint(equalToConstant: 32),
                switchDisplayButton.heightAnchor.constraint(equalToConstant: 32),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func didChooseSwitchDisplay() {
        onSwitchDisplay()
    }

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
