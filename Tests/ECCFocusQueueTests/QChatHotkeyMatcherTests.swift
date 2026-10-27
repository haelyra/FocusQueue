import CoreGraphics
import Testing

@testable import ECCFocusQueue

@Suite("Right Option / Right Command + / QChat hotkey matching")
struct QChatHotkeyMatcherTests {
  private let slash = QChatHotkeyMatcher.slashKeyCode
  private let rightOption = CGEventFlags.maskAlternate.rawValue
    | QChatHotkeyMatcher.rightOptionDeviceMask
  /// NX_DEVICELALTKEYMASK
  private let leftOption = CGEventFlags.maskAlternate.rawValue | 0x20
  private let rightCommand = CGEventFlags.maskCommand.rawValue
    | QChatHotkeyMatcher.rightCommandDeviceMask
  /// NX_DEVICELCMDKEYMASK
  private let leftCommand = CGEventFlags.maskCommand.rawValue | 0x08

  @Test("Right Option + / fires and hides its key-up")
  func rightOptionSlashFires() {
    let matcher = QChatHotkeyMatcher()
    #expect(matcher.decide(isKeyDown: true, keyCode: slash, flags: rightOption, isRepeat: false) == .trigger)
    #expect(matcher.decide(isKeyDown: false, keyCode: slash, flags: rightOption, isRepeat: false) == .swallow)
  }

  @Test("Held key repeats are consumed without refiring")
  func repeatsAreSwallowed() {
    let matcher = QChatHotkeyMatcher()
    #expect(matcher.decide(isKeyDown: true, keyCode: slash, flags: rightOption, isRepeat: false) == .trigger)
    #expect(matcher.decide(isKeyDown: true, keyCode: slash, flags: rightOption, isRepeat: true) == .swallow)
  }

  @Test("Key-up is hidden even when Option lifts first")
  func keyUpAfterOptionRelease() {
    let matcher = QChatHotkeyMatcher()
    #expect(matcher.decide(isKeyDown: true, keyCode: slash, flags: rightOption, isRepeat: false) == .trigger)
    #expect(matcher.decide(isKeyDown: false, keyCode: slash, flags: 0, isRepeat: false) == .swallow)
    // The next plain slash release belongs to the frontmost app again.
    #expect(matcher.decide(isKeyDown: false, keyCode: slash, flags: 0, isRepeat: false) == .pass)
  }

  @Test("Left Option + / still types normally")
  func leftOptionPasses() {
    let matcher = QChatHotkeyMatcher()
    #expect(matcher.decide(isKeyDown: true, keyCode: slash, flags: leftOption, isRepeat: false) == .pass)
    #expect(matcher.decide(isKeyDown: false, keyCode: slash, flags: leftOption, isRepeat: false) == .pass)
  }

  @Test("Plain slash and other keys pass through")
  func otherKeysPass() {
    let matcher = QChatHotkeyMatcher()
    #expect(matcher.decide(isKeyDown: true, keyCode: slash, flags: 0, isRepeat: false) == .pass)
    #expect(matcher.decide(isKeyDown: true, keyCode: 0, flags: rightOption, isRepeat: false) == .pass)
  }

  @Test("Extra Shift, Command, or Control leaves the shortcut to the frontmost app")
  func extraModifiersPass() {
    let matcher = QChatHotkeyMatcher()
    for extra in [CGEventFlags.maskShift, .maskControl] {
      #expect(matcher.decide(isKeyDown: true, keyCode: slash, flags: rightOption | extra.rawValue,
                             isRepeat: false) == .pass)
    }
  }

  @Test("Right Command + / fires and hides its key-up")
  func rightCommandSlashFires() {
    let matcher = QChatHotkeyMatcher()
    #expect(matcher.decide(isKeyDown: true, keyCode: slash, flags: rightCommand, isRepeat: false) == .trigger)
    #expect(matcher.decide(isKeyDown: false, keyCode: slash, flags: rightCommand, isRepeat: false) == .swallow)
  }

  @Test("Left Command + / stays with the frontmost app, such as an editor's comment toggle")
  func leftCommandPasses() {
    let matcher = QChatHotkeyMatcher()
    #expect(matcher.decide(isKeyDown: true, keyCode: slash, flags: leftCommand, isRepeat: false) == .pass)
    #expect(matcher.decide(isKeyDown: false, keyCode: slash, flags: leftCommand, isRepeat: false) == .pass)
  }

  @Test("Option and Command together pass through")
  func optionAndCommandPass() {
    let matcher = QChatHotkeyMatcher()
    #expect(matcher.decide(isKeyDown: true, keyCode: slash, flags: rightOption | rightCommand,
                           isRepeat: false) == .pass)
    #expect(matcher.decide(isKeyDown: true, keyCode: slash, flags: rightOption | leftCommand,
                           isRepeat: false) == .pass)
  }
}
