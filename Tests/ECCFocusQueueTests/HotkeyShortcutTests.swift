import AppKit
import Carbon.HIToolbox
import Testing
@testable import ECCFocusQueue

@Suite("Hotkey recording")
@MainActor
struct HotkeyShortcutTests {
  @Test("Minimization defaults to the Command comma Carbon shortcut")
  func minimizationDefault() throws {
    let shortcut = try #require(HotkeyAction.toggleMinimization.defaultShortcut)
    #expect(shortcut.keyCode == UInt16(kVK_ANSI_Comma))
    #expect(shortcut.carbonModifiers == UInt32(cmdKey))
    #expect(shortcut.displayString == "⌘,")
    #expect(HotkeyAction.newTask.defaultShortcut == nil)
    #expect(HotkeyAction.qchat.defaultShortcut == nil)
  }

  @Test("A combo with Command, Option, or Control records with its layout label")
  func recordsCombo() {
    let result = HotkeyShortcut.record(keyCode: UInt16(kVK_ANSI_N), flags: [.control, .option], characters: "n")
    guard case .recorded(let shortcut) = result else { Issue.record("Expected a recording, got \(result)"); return }
    #expect(shortcut.displayString == "⌃⌥N")
    #expect(shortcut.carbonModifiers == UInt32(controlKey | optionKey))
  }

  @Test("Escape cancels, plain and Shift-only keys are rejected, function keys may stand alone")
  func recordingRules() {
    #expect(HotkeyShortcut.record(keyCode: UInt16(kVK_Escape), flags: [], characters: "\u{1b}") == .cancelled)
    guard case .rejected = HotkeyShortcut.record(keyCode: UInt16(kVK_ANSI_A), flags: [], characters: "a") else {
      Issue.record("A plain letter must not record"); return
    }
    guard case .rejected = HotkeyShortcut.record(keyCode: UInt16(kVK_ANSI_A), flags: [.shift], characters: "A") else {
      Issue.record("Shift alone must not record"); return
    }
    guard case .recorded(let function) = HotkeyShortcut.record(keyCode: UInt16(kVK_F13), flags: [], characters: nil) else {
      Issue.record("A function key alone should record"); return
    }
    #expect(function.displayString == "F13")
    guard case .recorded(let space) = HotkeyShortcut.record(keyCode: UInt16(kVK_Space), flags: [.command, .shift], characters: " ") else {
      Issue.record("Space with modifiers should record"); return
    }
    #expect(space.displayString == "⇧⌘Space")
    // Caps Lock and other non-modifier flags never leak into the stored combo.
    guard case .recorded(let filtered) = HotkeyShortcut.record(keyCode: UInt16(kVK_ANSI_K), flags: [.command, .capsLock], characters: "k") else {
      Issue.record("Expected a recording"); return
    }
    #expect(filtered.modifierFlags == .command)
  }

  @Test("A recorded combo registers as a system hot key and unregisters cleanly")
  func systemRegistration() {
    // An unlikely combo so the test never collides with a real shortcut.
    let shortcut = HotkeyShortcut(keyCode: UInt16(kVK_F19),
      modifiers: NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue, keyLabel: "F19")
    let center = GlobalHotKeyCenter.shared
    #expect(center.register(shortcut, for: .qchat) {} == nil)
    #expect(center.isRegistered(.qchat))
    center.unregister(.qchat)
    #expect(!center.isRegistered(.qchat))
  }
}
