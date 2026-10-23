import AppKit
import Testing

@testable import ECCFocusQueue

@Suite("Right Option + Shift combo detection")
struct HotkeyComboStateTests {
  private let rightOption: UInt16 = 61
  private let leftOption: UInt16 = 58
  private let leftShift: UInt16 = 56
  private let rightShift: UInt16 = 60

  @Test("Option first, then Shift, fires once Shift lands")
  func optionFirstFires() {
    let state = HotkeyComboState()
    #expect(!state.update(keyCode: rightOption, flags: [.option]))
    #expect(state.update(keyCode: leftShift, flags: [.option, .shift]))
  }

  @Test("Shift first, then right Option, fires once Option lands")
  func shiftFirstFires() {
    let state = HotkeyComboState()
    #expect(!state.update(keyCode: rightShift, flags: [.shift]))
    #expect(state.update(keyCode: rightOption, flags: [.option, .shift]))
  }

  @Test("Repeated flagsChanged while held do not refire")
  func heldComboFiresOnce() {
    let state = HotkeyComboState()
    #expect(!state.update(keyCode: rightOption, flags: [.option]))
    #expect(state.update(keyCode: leftShift, flags: [.option, .shift]))
    #expect(!state.update(keyCode: leftShift, flags: [.option, .shift]))
    #expect(!state.update(keyCode: rightOption, flags: [.option, .shift]))
  }

  @Test("Re-arms only after both modifiers release")
  func reArmsOnFullRelease() {
    let state = HotkeyComboState()
    #expect(!state.update(keyCode: rightOption, flags: [.option]))
    #expect(state.update(keyCode: leftShift, flags: [.option, .shift]))

    // Shift releases but Option stays held: still considered pressed.
    #expect(!state.update(keyCode: leftShift, flags: [.option]))
    #expect(!state.update(keyCode: leftShift, flags: [.option, .shift]))

    // Full release re-arms; pressing the combo again fires.
    #expect(!state.update(keyCode: leftShift, flags: [.option]))
    #expect(!state.update(keyCode: rightOption, flags: []))
    #expect(!state.update(keyCode: leftShift, flags: [.shift]))
    #expect(state.update(keyCode: rightOption, flags: [.option, .shift]))
  }

  @Test("Left Option never fires")
  func leftOptionNeverFires() {
    let state = HotkeyComboState()
    #expect(!state.update(keyCode: leftOption, flags: [.option]))
    #expect(!state.update(keyCode: leftShift, flags: [.option, .shift]))
    #expect(!state.update(keyCode: leftOption, flags: [.option, .shift]))
  }
}
