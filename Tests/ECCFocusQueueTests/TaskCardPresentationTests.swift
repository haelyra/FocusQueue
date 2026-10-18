import AppKit
import FocusQueueCore
import SwiftUI
import Testing

@testable import ECCFocusQueue

@Suite("Task card presentation")
@MainActor
struct TaskCardPresentationTests {
  @Test("New and hard-deadline indicators render at readable intrinsic sizes")
  func indicatorLayout() {
    let badge = NSHostingView(rootView: NewTaskBadge())
    badge.layoutSubtreeIfNeeded()
    #expect(badge.fittingSize.width > 30)
    #expect(badge.fittingSize.height > 12)
    #expect(NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) != nil)

    let ticket = DashboardTicket(
      id: "FOC-023", title: "Task", status: "open", summary: "", dueDate: "2026-10-24")
    let pill = NSHostingView(rootView: TaskDeadlinePill(ticket: ticket))
    pill.layoutSubtreeIfNeeded()
    #expect(pill.fittingSize.width > 60)
    #expect(pill.fittingSize.height > 12)
    #expect(NSImage(systemSymbolName: "calendar", accessibilityDescription: nil) != nil)
  }
}
