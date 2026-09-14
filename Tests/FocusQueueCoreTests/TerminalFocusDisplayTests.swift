import CoreGraphics
import Testing

@testable import FocusQueueCore

@Test("Terminal focus cycles displays and restores the preferred window size")
func terminalFocusCyclesDisplays() throws {
  let screenFrames = [
    CGRect(x: -1_200, y: 0, width: 1_200, height: 900),
    CGRect(x: 0, y: 100, width: 1_000, height: 800),
  ]
  let visibleFrames = [
    CGRect(x: -1_200, y: 0, width: 1_200, height: 900),
    CGRect(x: 0, y: 100, width: 1_000, height: 800),
  ]
  let preferredFrame = CGRect(x: -1_100, y: 40, width: 1_600, height: 1_200)

  let second = try #require(TerminalFocusGeometry.nextDisplayTarget(
    currentWindowFrame: CGRect(x: -1_100, y: 40, width: 900, height: 700),
    preferredWindowFrame: preferredFrame,
    screenFrames: screenFrames,
    visibleScreenFrames: visibleFrames
  ))
  #expect(second.screenIndex == 1)
  #expect(second.frame == CGRect(x: 80, y: 164, width: 840, height: 672))

  let first = try #require(TerminalFocusGeometry.nextDisplayTarget(
    currentWindowFrame: second.frame,
    preferredWindowFrame: preferredFrame,
    screenFrames: screenFrames,
    visibleScreenFrames: visibleFrames
  ))
  #expect(first.screenIndex == 0)
  #expect(first.frame == CGRect(x: -1_104, y: 72, width: 1_008, height: 756))
}
