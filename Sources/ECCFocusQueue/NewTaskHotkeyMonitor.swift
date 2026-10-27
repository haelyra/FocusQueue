import AppKit

/// Fires on Right Option + Shift (as soon as both are down) and on a Right
/// Command + Shift tap (on release, when no other key was pressed meanwhile).
/// Modifier events cost a bitmask check; key-downs only cancel a pending tap.
@MainActor
final class NewTaskHotkeyMonitor {
  var onTrigger: () -> Void = {}

  private var globalMonitor: Any?
  private var localMonitor: Any?
  private let state = HotkeyComboState()

  func start() {
    guard globalMonitor == nil else { return }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
      [weak self] event in Task { @MainActor in self?.handle(event) }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
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

  func handle(_ event: NSEvent) {
    guard event.type == .flagsChanged else {
      state.noteKeyDown()
      return
    }
    if state.update(keyCode: event.keyCode, flags: event.modifierFlags) != nil {
      onTrigger()
    }
  }
}

/// Testable new-task combo detector, independent of NSEvent.
/// keyCode 61 = right Option, 54 = right Command, 56/60 = left/right Shift.
final class HotkeyComboState {
  enum Trigger: Equatable {
    case optionShift
    case commandShift
  }

  private(set) var rightOptionDown = false
  private(set) var rightCommandDown = false
  private(set) var shiftDown = false
  private var fired = false
  /// Right Command + Shift is common in shortcuts (⌘⇧Z, ⌘⇧4), so it fires on
  /// release and only when nothing else was typed while it was held.
  private var commandTapPending = false

  /// Option + Shift fires once per full press and re-arms on full release.
  func update(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Trigger? {
    switch keyCode {
    case 61: rightOptionDown = flags.contains(.option)
    case 54: rightCommandDown = flags.contains(.command)
    case 56, 60: shiftDown = flags.contains(.shift)
    default: break
    }
    defer { if !rightOptionDown && !rightCommandDown && !shiftDown { fired = false } }
    if rightOptionDown && shiftDown {
      commandTapPending = false
      if fired { return nil }
      fired = true
      return .optionShift
    }
    if rightCommandDown && shiftDown {
      // Any other modifier joining turns the tap into some other shortcut.
      commandTapPending = !fired && flags.intersection([.option, .control]).isEmpty
      return nil
    }
    guard commandTapPending else { return nil }
    commandTapPending = false
    fired = true
    return .commandShift
  }

  func noteKeyDown() {
    commandTapPending = false
  }
}
