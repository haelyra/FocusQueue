import CoreGraphics
import Testing

@testable import ECCFocusQueue

@Suite("Right Option + / QChat hotkey matching")
struct QChatHotkeyMatcherTests {
  private let slash = QChatHotkeyMatcher.slashKeyCode
  private let rightOption = CGEventFlags.maskAlternate.rawValue
    | QChatHotkeyMatcher.rightOptionDeviceMask
  /// NX_DEVICELALTKEYMASK
  private let leftOption = CGEventFlags.maskAlternate.rawValue | 0x20

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
    for extra in [CGEventFlags.maskShift, .maskCommand, .maskControl] {
      #expect(matcher.decide(isKeyDown: true, keyCode: slash, flags: rightOption | extra.rawValue,
                             isRepeat: false) == .pass)
    }
  }
}
