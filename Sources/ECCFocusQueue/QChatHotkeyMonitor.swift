import AppKit

/// Fires on Right Option + / or Right Command + /. An NSEvent global monitor
/// cannot consume the keystroke, so the frontmost app would type "÷" or run its
/// own ⌘/ command; a session event tap swallows it instead. The tap needs Accessibility trust, which the new task hotkey and
/// terminal focus already rely on.
@MainActor
final class QChatHotkeyMonitor {
  var onTrigger: () -> Void = {}

  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private let matcher = QChatHotkeyMatcher()

  var isRunning: Bool { tap != nil }

  /// Returns false when macOS refuses the tap, which means Accessibility is not granted.
  @discardableResult func start() -> Bool {
    guard tap == nil else { return true }
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: CGEventMask(mask), callback: qchatHotkeyTapCallback,
      userInfo: Unmanaged.passUnretained(self).toOpaque())
    else { return false }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    self.tap = tap
    self.source = source
    return true
  }

  func stop() {
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    tap = nil
    source = nil
  }

  /// Returns true when the event should reach the frontmost app.
  fileprivate func handle(type: CGEventType, keyCode: UInt16, flags: UInt64, isRepeat: Bool) -> Bool {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      // macOS disables slow or interrupted taps; turn it back on.
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return true
    case .keyDown, .keyUp:
      let decision = matcher.decide(
        isKeyDown: type == .keyDown, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
      if decision == .trigger { onTrigger() }
      return decision == .pass
    default:
      return true
    }
  }
}

/// The tap runs on the main run loop, so the callback is already main-thread.
private func qchatHotkeyTapCallback(
  proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let monitor = Unmanaged<QChatHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
  let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
  let flags = event.flags.rawValue
  let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
  let passes = MainActor.assumeIsolated {
    monitor.handle(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
  }
  return passes ? Unmanaged.passUnretained(event) : nil
}

/// Testable Right Option / Right Command + / matcher, independent of CGEvent.
/// keyCode 44 = the ANSI "/" key position.
final class QChatHotkeyMatcher {
  enum Decision: Equatable {
    case pass
    case trigger
    /// Consumed without firing: key repeats and the matching key-up.
    case swallow
  }

  static let slashKeyCode: UInt16 = 44
  /// NX_DEVICERALTKEYMASK / NX_DEVICERCMDKEYMASK: set only while that right-side key is down.
  static let rightOptionDeviceMask: UInt64 = 0x40
  static let rightCommandDeviceMask: UInt64 = 0x10
  private static let alternate = CGEventFlags.maskAlternate.rawValue
  private static let command = CGEventFlags.maskCommand.rawValue
  private static let otherModifiers = CGEventFlags.maskControl.rawValue
    | CGEventFlags.maskShift.rawValue

  private var swallowsKeyUp = false

  func decide(isKeyDown: Bool, keyCode: UInt16, flags: UInt64, isRepeat: Bool) -> Decision {
    guard keyCode == Self.slashKeyCode else { return .pass }
    guard isKeyDown else {
      // Hide the release only when the press was ours, even if Option lifted first.
      defer { swallowsKeyUp = false }
      return swallowsKeyUp ? .swallow : .pass
    }
    let option = flags & Self.alternate != 0
    let command = flags & Self.command != 0
    // Exactly one of Option or Command, and it must be the right-hand key.
    let isCombo = option != command && flags & Self.otherModifiers == 0
      && flags & (option ? Self.rightOptionDeviceMask : Self.rightCommandDeviceMask) != 0
    guard isCombo else { return .pass }
    swallowsKeyUp = true
    return isRepeat ? .swallow : .trigger
  }
}
