import AppKit
import SwiftUI
import Testing

@testable import ECCFocusQueue

@Suite("Notification layout")
@MainActor
struct NotificationLayoutTests {
  @Test("Queue chrome uses compact outer spacing and a readable yellow notification badge")
  func compactQueueChrome() {
    #expect(QueueChromeMetrics.sectionSpacing == 4)
    #expect(QueueChromeMetrics.notificationBadgeFill == NSColor.systemYellow)
    #expect(QueueChromeMetrics.notificationBadgeForeground == NSColor.black)
    #expect(QueueChromeMetrics.notificationPopoverHeight(for: 1) == 96)
    #expect(QueueChromeMetrics.notificationPopoverHeight(for: 10) == 280)
  }

  @Test("Swipe affordance does not stretch a notification into the available panel height",
    arguments: [CGFloat(380), CGFloat(600)])
  func contentDeterminesHeight(width: CGFloat) throws {
    let card = VStack(alignment: .leading, spacing: 4) {
      Text("The agent completed its assignment").font(.system(size: 12, weight: .semibold))
      Text("ECC-035 · Notification spacing").font(.system(size: 11))
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    let baseline = ImageRenderer(content: card)
    baseline.proposedSize = ProposedViewSize(width: width, height: 600)
    let expected = try #require(baseline.cgImage)

    for height in [CGFloat(300), CGFloat(600), CGFloat(900)] {
      let renderer = ImageRenderer(content: SwipeToClearNotification(onClear: {}) { card })
      renderer.proposedSize = ProposedViewSize(width: width, height: height)
      let actual = try #require(renderer.cgImage)
      #expect(actual.height == expected.height,
        "Notification must retain its content height when the panel has extra room")
      #expect(actual.width == expected.width)
    }
  }
}
