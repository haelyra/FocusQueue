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
      if let reason = state.takeIgnoredReason() {
        NSLog("New task hotkey: Right Command + Shift ignored (%@)", reason)
      }
      return
    }
    if state.update(keyCode: event.keyCode, flags: event.modifierFlags) != nil {
      onTrigger()
    }
    if let reason = state.takeIgnoredReason() {
      NSLog("New task hotkey: Right Command + Shift ignored (%@)", reason)
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
  /// Modifiers of the chord that fired; the chord re-arms once an event shows none of them held.
  private var firedModifiers: NSEvent.ModifierFlags = []
  /// Right Command + Shift is common in shortcuts (⌘⇧Z, ⌘⇧4), so it fires on
  /// release and only when nothing else was typed while it was held.
  private var commandTapPending = false

  /// Why the last Right Command + Shift chord ended without firing; nil if none.
  /// The monitor logs it so a miss in the field leaves evidence.
  private(set) var ignoredReason: String?

  /// Option + Shift fires once per full press and re-arms on full release.
  func update(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Trigger? {
    // Key-ups can go missing: a Command tap fires on release, and the app
    // activates at that instant. Every event carries the full modifier state, so
    // drop anything it no longer shows as held.
    if !flags.contains(.command) { rightCommandDown = false }
    if !flags.contains(.option) { rightOptionDown = false }
    if !flags.contains(.shift) { shiftDown = false }
    if fired, flags.intersection(firedModifiers).isEmpty { fired = false }
    switch keyCode {
    case 61: rightOptionDown = flags.contains(.option)
    case 54:
      if flags.contains(.command) {
        // A press of a key still recorded as down means its key-up was lost.
        if rightCommandDown { fired = false; commandTapPending = false }
        rightCommandDown = true
      }
    case 56, 60: shiftDown = flags.contains(.shift)
    default: break
    }
    if rightOptionDown && shiftDown {
      commandTapPending = false
      if fired { return nil }
      fired = true
      firedModifiers = [.option, .shift]
      return .optionShift
    }
    if rightCommandDown && shiftDown {
      // Any other modifier joining turns the tap into some other shortcut.
      let clean = flags.intersection([.option, .control]).isEmpty
      commandTapPending = !fired && clean
      if !clean { ignoredReason = "another modifier joined" }
      return nil
    }
    guard commandTapPending else { return nil }
    commandTapPending = false
    fired = true
    firedModifiers = [.command, .shift]
    return .commandShift
  }

  func noteKeyDown() {
    if commandTapPending { ignoredReason = "a key was typed while held" }
    commandTapPending = false
  }

  func takeIgnoredReason() -> String? {
    defer { ignoredReason = nil }
    return ignoredReason
  }
}
