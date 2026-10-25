import AppKit

/// Fires once per Right Option + Shift press. Uses flagsChanged monitors only:
/// events arrive solely on modifier transitions, so idle cost is zero and the
/// handler is a bitmask check.
@MainActor
final class NewTaskHotkeyMonitor {
  var onTrigger: () -> Void = {}

  private var globalMonitor: Any?
  private var localMonitor: Any?
  private let state = HotkeyComboState()

  func start() {
    guard globalMonitor == nil else { return }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
      [weak self] event in Task { @MainActor in self?.handle(event) }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
      [weak self] event in
      Task { @MainActor in self?.handle(event) }
      return event
    }
  }

  func stop() {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil
    localMonitor = nil
  }

  private func handle(_ event: NSEvent) {
    if state.update(keyCode: event.keyCode, flags: event.modifierFlags) {
      onTrigger()
    }
  }
}

/// Testable Right Option + Shift edge detector, independent of NSEvent.
/// keyCode 61 = right Option, 56/60 = left/right Shift.
final class HotkeyComboState {
  private(set) var rightOptionDown = false
  private(set) var shiftDown = false
  private var fired = false

  /// Returns true exactly once per full combo press; re-arms on full release.
  func update(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
    switch keyCode {
    case 61: rightOptionDown = flags.contains(.option)
    case 56, 60: shiftDown = flags.contains(.shift)
    default: break
    }
    let combo = rightOptionDown && shiftDown
    if combo && !fired { fired = true; return true }
    if !rightOptionDown && !shiftDown { fired = false }
    return false
  }
}
