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
    #expect(QueueChromeMetrics.notificationPanelMinWidth == 300)
  }

  @Test("Notifications widen the panel like a side report instead of squeezing the queue")
  func notificationsInspectorWidth() {
    let layout = QueueInspectorLayout.notifications
    #expect(layout.preferredWidth(compactWidth: 440) == 1_020)
    // Queue column, divider, and padding still leave the list its minimum width.
    #expect(layout.minimumWidth - 440 - 49 >= QueueChromeMetrics.notificationPanelMinWidth)
    #expect(layout.minimumWidth > QueueInspectorLayout.closed.maximumWidth)
  }

  @Test("Token analytics opens beside Settings with enough room for its breakdown columns")
  func tokenAnalyticsInspectorWidth() {
    let layout = QueueInspectorLayout.analytics
    #expect(layout.preferredWidth(compactWidth: 440) == 1_240)
    #expect(layout.minimumWidth - 440 - 49 >= 600)
    #expect(layout.maximumWidth > QueueInspectorLayout.closed.maximumWidth)
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
