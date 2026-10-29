import AppKit
import SwiftUI
import Testing

@testable import ECCFocusQueue

@Suite("Queue chrome layout")
@MainActor
struct QueueChromeLayoutTests {
  @Test("Queue chrome uses compact outer spacing")
  func compactQueueChrome() {
    #expect(QueueChromeMetrics.sectionSpacing == 4)
  }

  @Test("Token analytics opens beside Settings with enough room for its breakdown columns")
  func tokenAnalyticsInspectorWidth() {
    let layout = QueueInspectorLayout.analytics
    #expect(layout.preferredWidth(compactWidth: 440) == 1_240)
    #expect(layout.minimumWidth - 440 - 49 >= 600)
    #expect(layout.maximumWidth > QueueInspectorLayout.closed.maximumWidth)
  }
}
