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
            "Confirm ECC Focus Queue is enabled in System Settings > Privacy & Security > Accessibility, then click Focus terminal again."
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

    private(set) var isActive = false
    var stateDidChange: ((Bool) -> Void)?

    init(queuePanel: NSPanel) {
        self.queuePanel = queuePanel
    }

    func begin(applicationName: String, targetScreen: NSScreen?) async throws {
        clearBackdrops(revealQueue: false)

        guard requestAccessibilityPermission() else {
            throw TerminalFocusModeError.accessibilityPermissionRequired
        }
        guard let application = await waitForApplication(named: applicationName) else {
            throw TerminalFocusModeError.applicationUnavailable(applicationName)
        }

        application.activate(options: [.activateAllWindows])
        guard let window = await waitForFocusedWindow(of: application) else {
            throw TerminalFocusModeError.focusedWindowUnavailable
        }
        let currentFrame = try frame(of: window)
        let screen = targetScreen ?? screen(containingAXFrame: currentFrame) ?? NSScreen.main
        guard let screen else { throw TerminalFocusModeError.windowFrameUnavailable }

        let targetFrame = TerminalFocusGeometry.centeredFrame(
            currentFrame: currentFrame,
            visibleFrame: axFrame(fromAppKitFrame: screen.visibleFrame)
        )

        queuePanel?.orderOut(nil)
        do {
            try await animate(window: window, from: currentFrame, to: targetFrame)
            try raise(window: window, application: application)
            showBackdrops(around: appKitFrame(fromAXFrame: targetFrame), targetScreen: screen)
            isActive = true
            stateDidChange?(true)
            application.activate(options: [.activateAllWindows])
            try raise(window: window, application: application)
        } catch {
            clearBackdrops(revealQueue: true)
            throw error
        }
    }

    func dismiss() {
        clearBackdrops(revealQueue: true)
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

    private func waitForFocusedWindow(of application: NSRunningApplication) async -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        for _ in 0..<30 {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                applicationElement,
                kAXFocusedWindowAttribute as CFString,
                &value
            )
            if result == .success, let value {
                return (value as! AXUIElement)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
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

    private func raise(window: AXUIElement, application: NSRunningApplication) throws {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetAttributeValue(
            applicationElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
            throw TerminalFocusModeError.windowMoveFailed
        }
    }

    private func showBackdrops(around focusedFrame: CGRect, targetScreen: NSScreen) {
        for screen in NSScreen.screens {
            let aperture = screen.frame == targetScreen.frame ? focusedFrame : nil
            for region in TerminalFocusGeometry.backdropRegions(
                screenFrame: screen.frame,
                focusedFrame: aperture
            ) {
                let window = FocusBackdropWindow(frame: region) { [weak self] in
                    self?.dismiss()
                }
                window.alphaValue = 0
                window.orderFrontRegardless()
                backdropWindows.append(window)
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for window in backdropWindows {
                window.animator().alphaValue = 1
            }
        }
    }

    private func clearBackdrops(revealQueue: Bool) {
        let windows = backdropWindows
        backdropWindows.removeAll()
        isActive = false
        stateDidChange?(false)
        windows.forEach { $0.orderOut(nil) }

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
        level = .floating
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = FocusBackdropView(onDismiss: onDismiss)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FocusBackdropView: NSView {
    private let onDismiss: @MainActor () -> Void

    init(onDismiss: @escaping @MainActor () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
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
