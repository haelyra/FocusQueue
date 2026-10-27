import AppKit
import Testing

@testable import ECCFocusQueue

@Suite("New task hotkey combo detection")
struct HotkeyComboStateTests {
  private let rightOption: UInt16 = 61
  private let leftOption: UInt16 = 58
  private let leftShift: UInt16 = 56
  private let rightShift: UInt16 = 60
  private let rightCommand: UInt16 = 54
  private let leftCommand: UInt16 = 55

  @Test("Option first, then Shift, fires once Shift lands")
  func optionFirstFires() {
    let state = HotkeyComboState()
    #expect(state.update(keyCode: rightOption, flags: [.option]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.option, .shift]) == .optionShift)
  }

  @Test("Shift first, then right Option, fires once Option lands")
  func shiftFirstFires() {
    let state = HotkeyComboState()
    #expect(state.update(keyCode: rightShift, flags: [.shift]) == nil)
    #expect(state.update(keyCode: rightOption, flags: [.option, .shift]) == .optionShift)
  }

  @Test("Repeated flagsChanged while held do not refire")
  func heldComboFiresOnce() {
    let state = HotkeyComboState()
    #expect(state.update(keyCode: rightOption, flags: [.option]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.option, .shift]) == .optionShift)
    #expect(state.update(keyCode: leftShift, flags: [.option, .shift]) == nil)
    #expect(state.update(keyCode: rightOption, flags: [.option, .shift]) == nil)
  }

  @Test("Re-arms only after both modifiers release")
  func reArmsOnFullRelease() {
    let state = HotkeyComboState()
    #expect(state.update(keyCode: rightOption, flags: [.option]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.option, .shift]) == .optionShift)

    // Shift releases but Option stays held: still considered pressed.
    #expect(state.update(keyCode: leftShift, flags: [.option]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.option, .shift]) == nil)

    // Full release re-arms; pressing the combo again fires.
    #expect(state.update(keyCode: leftShift, flags: [.option]) == nil)
    #expect(state.update(keyCode: rightOption, flags: []) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.shift]) == nil)
    #expect(state.update(keyCode: rightOption, flags: [.option, .shift]) == .optionShift)
  }

  @Test("Left Option never fires")
  func leftOptionNeverFires() {
    let state = HotkeyComboState()
    #expect(state.update(keyCode: leftOption, flags: [.option]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.option, .shift]) == nil)
    #expect(state.update(keyCode: leftOption, flags: [.option, .shift]) == nil)
  }

  @Test("A Right Command + Shift tap fires once, on release")
  func commandShiftTapFiresOnRelease() {
    let state = HotkeyComboState()
    #expect(state.update(keyCode: rightCommand, flags: [.command]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command, .shift]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command]) == .commandShift)
    #expect(state.update(keyCode: rightCommand, flags: []) == nil)
  }

  @Test("Releasing Command first also completes the tap")
  func commandReleasedFirst() {
    let state = HotkeyComboState()
    #expect(state.update(keyCode: leftShift, flags: [.shift]) == nil)
    #expect(state.update(keyCode: rightCommand, flags: [.command, .shift]) == nil)
    #expect(state.update(keyCode: rightCommand, flags: [.shift]) == .commandShift)
    #expect(state.update(keyCode: leftShift, flags: []) == nil)
  }

  @Test("A key typed during Right Command + Shift is a shortcut, not a tap")
  func commandShiftShortcutDoesNotFire() {
    let state = HotkeyComboState()
    #expect(state.update(keyCode: rightCommand, flags: [.command]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command, .shift]) == nil)
    state.noteKeyDown()  // e.g. ⌘⇧Z
    #expect(state.update(keyCode: leftShift, flags: [.command]) == nil)
    #expect(state.update(keyCode: rightCommand, flags: []) == nil)

    // The next clean tap still works.
    #expect(state.update(keyCode: rightCommand, flags: [.command]) == nil)
    #expect(state.update(keyCode: rightShift, flags: [.command, .shift]) == nil)
    #expect(state.update(keyCode: rightShift, flags: [.command]) == .commandShift)
  }

  @Test("Re-pressing Shift while Command stays held does not refire")
  func commandHeldDoesNotRefire() {
    let state = HotkeyComboState()
    #expect(state.update(keyCode: rightCommand, flags: [.command]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command, .shift]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command]) == .commandShift)
    #expect(state.update(keyCode: leftShift, flags: [.command, .shift]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command]) == nil)
  }

  @Test("Left Command + Shift and Right Command + Shift + Option never fire")
  func otherCommandChordsNeverFire() {
    let state = HotkeyComboState()
    #expect(state.update(keyCode: leftCommand, flags: [.command]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command, .shift]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command]) == nil)
    #expect(state.update(keyCode: leftCommand, flags: []) == nil)

    #expect(state.update(keyCode: rightCommand, flags: [.command]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command, .shift]) == nil)
    #expect(state.update(keyCode: leftOption, flags: [.command, .shift, .option]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command, .option]) == nil)
  }

  @Test("A Command key-up lost while the sheet opens does not block the next tap")
  func lostCommandReleaseHeals() {
    let state = HotkeyComboState()
    // Tap 1 fires on the Shift release; the app activates right then and the Command key-up never arrives.
    #expect(state.update(keyCode: rightCommand, flags: [.command]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command, .shift]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command]) == .commandShift)

    // Tap 2 must still fire.
    #expect(state.update(keyCode: rightCommand, flags: [.command]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command, .shift]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command]) == .commandShift)
    #expect(state.update(keyCode: rightCommand, flags: []) == nil)
  }

  @Test("Lost Shift and Command key-ups both heal on the next tap")
  func lostBothReleasesHeal() {
    let state = HotkeyComboState()
    #expect(state.update(keyCode: rightCommand, flags: [.command]) == nil)
    #expect(state.update(keyCode: rightShift, flags: [.command, .shift]) == nil)
    #expect(state.update(keyCode: rightShift, flags: [.command]) == .commandShift)
    // Neither key-up arrives; the next tap starts from a fresh Command press.
    #expect(state.update(keyCode: rightCommand, flags: [.command]) == nil)
    #expect(state.update(keyCode: rightShift, flags: [.command, .shift]) == nil)
    #expect(state.update(keyCode: rightShift, flags: [.command]) == .commandShift)
  }

  @Test("A Command tap after a lost Option release still fires")
  func lostOptionReleaseDoesNotBlockCommand() {
    let state = HotkeyComboState()
    #expect(state.update(keyCode: rightOption, flags: [.option]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.option, .shift]) == .optionShift)
    // Both key-ups lost; the next event already shows Command alone.
    #expect(state.update(keyCode: rightCommand, flags: [.command]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command, .shift]) == nil)
    #expect(state.update(keyCode: leftShift, flags: [.command]) == .commandShift)
  }
}
