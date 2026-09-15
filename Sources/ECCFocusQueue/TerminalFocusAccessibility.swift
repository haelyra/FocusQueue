import AppKit
import ApplicationServices

/// Invalidation crosses the main actor and the accessibility worker. It prevents an
/// older suspended focus request from moving windows or restoring dismissed chrome.
final class TerminalFocusOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }
}

/// The immutable reference travels between actors; only TerminalFocusAccessibility
/// sends messages through it. AppKit window and display state stays on the main actor.
struct TerminalFocusWindow: @unchecked Sendable {
    fileprivate let element: AXUIElement
}

struct TerminalFocusPlacement: Equatable, Sendable {
    let resize: Bool
    let reposition: Bool

    init(from current: CGRect, to target: CGRect) {
        resize = current.size != target.size
        reposition = current.origin != target.origin
    }
}

actor TerminalFocusAccessibility {
    private let messagingTimeout: Float = 0.25

    func waitForFocusedWindow(
        processIdentifier: pid_t, titleHint: String?, operation: TerminalFocusOperation
    ) async throws -> TerminalFocusWindow? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        for _ in 0..<30 {
            try operation.checkCancellation()
            guard ContinuousClock.now < deadline else { return nil }
            if let window = focusedWindow(in: application) {
                if let titleHint,
                   windowTitle(window)?.localizedCaseInsensitiveContains(titleHint) != true {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                return reference(window)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    func frame(of window: TerminalFocusWindow, operation: TerminalFocusOperation) throws -> CGRect {
        try operation.checkCancellation()
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window.element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window.element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
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

    func place(
        window: TerminalFocusWindow, from current: CGRect, to target: CGRect,
        operation: TerminalFocusOperation
    ) throws {
        try operation.checkCancellation()
        let placement = TerminalFocusPlacement(from: current, to: target)
        if placement.resize {
            var size = target.size
            guard let value = AXValueCreate(.cgSize, &size),
                  AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, value) == .success else {
                throw TerminalFocusModeError.windowMoveFailed
            }
        }
        try operation.checkCancellation()
        if placement.reposition {
            var position = target.origin
            guard let value = AXValueCreate(.cgPoint, &position),
                  AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, value) == .success else {
                throw TerminalFocusModeError.windowMoveFailed
            }
        }
    }

    func raise(
        window: TerminalFocusWindow, processIdentifier: pid_t,
        operation: TerminalFocusOperation
    ) throws {
        try operation.checkCancellation()
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        try operation.checkCancellation()
        guard AXUIElementPerformAction(window.element, kAXRaiseAction as CFString) == .success else {
            throw TerminalFocusModeError.windowMoveFailed
        }
    }

    func windowNumber(
        ownedBy processIdentifier: pid_t, matchingAXFrame target: CGRect,
        operation: TerminalFocusOperation
    ) throws -> Int? {
        try operation.checkCancellation()
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return windows.compactMap { info -> (number: Int, distance: CGFloat)? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { return nil }
            let distance = abs(bounds.minX - target.minX) + abs(bounds.minY - target.minY)
                + abs(bounds.width - target.width) + abs(bounds.height - target.height)
            return (number, distance)
        }.filter { $0.distance <= 12 }.min { $0.distance < $1.distance }?.number
    }

    private func reference(_ element: AXUIElement) -> TerminalFocusWindow {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return TerminalFocusWindow(element: element)
    }

    private func focusedWindow(in application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func windowTitle(_ window: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &value
        ) == .success else { return nil }
        return value as? String
    }
}
