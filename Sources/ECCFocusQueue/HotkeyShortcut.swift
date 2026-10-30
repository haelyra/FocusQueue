import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The global shortcuts a user can rebind. Each one starts on its built-in
/// shortcut; recording a combo replaces it until reset.
enum HotkeyAction: String, CaseIterable, Identifiable {
  case newTask, qchat, toggleMinimization

  var id: String { rawValue }

  var title: String {
    switch self {
    case .newTask: "New task"
    case .qchat: "QChat"
    case .toggleMinimization: "Toggle minimization"
    }
  }

  /// Carbon hot keys match either Command key, so left and right ⌘ both work.
  var defaultShortcut: HotkeyShortcut {
    let command = NSEvent.ModifierFlags.command.rawValue
    return switch self {
    case .newTask: HotkeyShortcut(keyCode: UInt16(kVK_ANSI_Period), modifiers: command, keyLabel: ".")
    case .qchat: HotkeyShortcut(keyCode: UInt16(kVK_ANSI_Slash), modifiers: command, keyLabel: "/")
    case .toggleMinimization: HotkeyShortcut(keyCode: UInt16(kVK_ANSI_Comma), modifiers: command, keyLabel: ",")
    }
  }

  var shortcutDefaultsKey: String { "\(rawValue)HotkeyShortcut" }
}

/// One recorded key combo. `keyLabel` is captured from the keyboard layout at
/// record time, so the display matches what the user pressed.
struct HotkeyShortcut: Codable, Equatable {
  var keyCode: UInt16
  /// `NSEvent.ModifierFlags` raw value limited to Command, Option, Control, and Shift.
  var modifiers: UInt
  var keyLabel: String

  static let allowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

  var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

  var displayString: String {
    let flags = modifierFlags
    var symbols = ""
    if flags.contains(.control) { symbols += "⌃" }
    if flags.contains(.option) { symbols += "⌥" }
    if flags.contains(.shift) { symbols += "⇧" }
    if flags.contains(.command) { symbols += "⌘" }
    return symbols + keyLabel
  }

  var carbonModifiers: UInt32 {
    let flags = modifierFlags
    var result: UInt32 = 0
    if flags.contains(.command) { result |= UInt32(cmdKey) }
    if flags.contains(.option) { result |= UInt32(optionKey) }
    if flags.contains(.control) { result |= UInt32(controlKey) }
    if flags.contains(.shift) { result |= UInt32(shiftKey) }
    return result
  }

  enum RecordingResult: Equatable {
    case recorded(HotkeyShortcut)
    case cancelled
    /// A key press that cannot be a global shortcut; the message says why.
    case rejected(String)
  }

  /// Decides what one key press during recording means. Escape alone cancels.
  /// Plain or Shift-only keys are rejected because they would steal typing;
  /// function keys may stand alone.
  static func record(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> RecordingResult {
    let modifiers = flags.intersection(allowedModifiers)
    if keyCode == UInt16(kVK_Escape), modifiers.isEmpty { return .cancelled }
    let isFunctionKey = functionKeyLabels[keyCode] != nil
    guard isFunctionKey || !modifiers.intersection([.command, .option, .control]).isEmpty else {
      return .rejected("Include ⌘, ⌥, or ⌃ so the shortcut does not take over normal typing.")
    }
    guard let label = label(keyCode: keyCode, characters: characters) else {
      return .rejected("That key cannot be used in a shortcut.")
    }
    return .recorded(HotkeyShortcut(keyCode: keyCode, modifiers: modifiers.rawValue, keyLabel: label))
  }

  private static let functionKeyLabels: [UInt16: String] = [
    UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
    UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
    UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
    UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15", UInt16(kVK_F16): "F16",
    UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18", UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
  ]

  private static let namedKeyLabels: [UInt16: String] = [
    UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥",
    UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_Escape): "⎋",
    UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑",
    UInt16(kVK_DownArrow): "↓", UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
    UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
  ]

  private static func label(keyCode: UInt16, characters: String?) -> String? {
    if let named = functionKeyLabels[keyCode] ?? namedKeyLabels[keyCode] { return named }
    guard let text = characters?.trimmingCharacters(in: .whitespacesAndNewlines),
      text.count == 1, let scalar = text.unicodeScalars.first,
      !CharacterSet.controlCharacters.contains(scalar)
    else { return nil }
    return text.uppercased()
  }
}

/// Registers recorded combos as system hot keys. The system consumes the
/// keystroke, so the frontmost app never sees it, and no Accessibility access
/// is needed.
@MainActor
final class GlobalHotKeyCenter {
  static let shared = GlobalHotKeyCenter()

  private var handlerInstalled = false
  private var registrations: [HotkeyAction: EventHotKeyRef] = [:]
  private var callbacks: [UInt32: () -> Void] = [:]
  private static let signature: OSType = 0x4651_484B  // "FQHK"

  /// Returns nil on success, or a message when macOS refuses the combo
  /// (usually because another app or the system already owns it).
  func register(_ shortcut: HotkeyShortcut, for action: HotkeyAction, handler: @escaping () -> Void) -> String? {
    unregister(action)
    installHandlerIfNeeded()
    let id = UInt32(HotkeyAction.allCases.firstIndex(of: action)! + 1)
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
      EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &reference)
    guard status == noErr, let reference else {
      return status == eventHotKeyExistsErr
        ? "\(shortcut.displayString) is already used by macOS or another app."
        : "\(shortcut.displayString) could not be registered (error \(status))."
    }
    registrations[action] = reference
    callbacks[id] = handler
    return nil
  }

  func unregister(_ action: HotkeyAction) {
    guard let reference = registrations.removeValue(forKey: action) else { return }
    UnregisterEventHotKey(reference)
    callbacks[UInt32(HotkeyAction.allCases.firstIndex(of: action)! + 1)] = nil
  }

  func isRegistered(_ action: HotkeyAction) -> Bool { registrations[action] != nil }

  fileprivate func fire(id: UInt32) { callbacks[id]?() }

  private func installHandlerIfNeeded() {
    guard !handlerInstalled else { return }
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), globalHotKeyHandler, 1, &spec, nil, nil)
    handlerInstalled = true
  }
}

/// Carbon delivers hot keys on the main event loop.
private func globalHotKeyHandler(
  _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event else { return OSStatus(eventNotHandledErr) }
  var hotKeyID = EventHotKeyID()
  let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
  guard status == noErr else { return status }
  let id = hotKeyID.id
  MainActor.assumeIsolated { GlobalHotKeyCenter.shared.fire(id: id) }
  return noErr
}

/// A Raycast-style shortcut field: click Record, press the combo, done.
/// Reset returns the action to its built-in shortcut.
struct HotkeyRecorderField: View {
  let model: QueueViewModel
  let action: HotkeyAction

  @State private var monitor: Any?
  @State private var liveModifiers: NSEvent.ModifierFlags = []
  @State private var message: String?

  private var isRecording: Bool { monitor != nil }
  private var shortcut: HotkeyShortcut { model.hotkeyShortcut(for: action) }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Button(action: toggleRecording) {
          Text(fieldText)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .frame(minWidth: 150)
            .foregroundStyle(isRecording ? Color.accentColor : .primary)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(isRecording ? "Recording \(action.title) shortcut" : "Record \(action.title) shortcut")
        .help(isRecording ? "Press the new shortcut, or Escape to cancel" : "Click, then press the shortcut you want")
        if model.hotkeyShortcuts[action] != nil, !isRecording {
          Button("Reset") {
            message = nil
            model.setHotkeyShortcut(nil, for: action)
          }.controlSize(.small).help("Use the default shortcut: \(action.defaultShortcut.displayString)")
        }
      }
      if let error = message ?? model.hotkeyErrors[action] {
        Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      }
    }
    .onDisappear(perform: stopRecording)
  }

  private var fieldText: String {
    if isRecording {
      let preview = HotkeyShortcut(keyCode: 0, modifiers: liveModifiers.intersection(HotkeyShortcut.allowedModifiers).rawValue,
        keyLabel: "").displayString
      return preview.isEmpty ? "Press shortcut…" : preview + "…"
    }
    return shortcut.displayString
  }

  private func toggleRecording() {
    if isRecording { stopRecording() } else { startRecording() }
  }

  private func startRecording() {
    message = nil
    liveModifiers = []
    model.isRecordingHotkey = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
      if event.type == .flagsChanged {
        liveModifiers = event.modifierFlags
        return event
      }
      switch HotkeyShortcut.record(keyCode: event.keyCode, flags: event.modifierFlags,
        characters: event.charactersIgnoringModifiers) {
      case .cancelled:
        stopRecording()
      case .rejected(let reason):
        message = reason
      case .recorded(let recorded):
        if let other = HotkeyAction.allCases.first(where: { $0 != action && model.hotkeyShortcut(for: $0) == recorded }) {
          message = "\(recorded.displayString) is already the \(other.title) shortcut."
        } else {
          model.setHotkeyShortcut(recorded, for: action)
          stopRecording()
        }
      }
      return nil
    }
  }

  private func stopRecording() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    liveModifiers = []
    model.isRecordingHotkey = false
  }
}
