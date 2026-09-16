import AppKit
import FocusQueueCore
import SwiftUI
import Testing

@testable import ECCFocusQueue

@Suite("Subtask presentation")
@MainActor
struct SubtaskPresentationTests {
  @Test("Agent providers use distinct available icons")
  func providerIcons() {
    #expect(AgentProvider.codex.symbolName != AgentProvider.claude.symbolName)
    for provider in AgentProvider.allCases {
      #expect(
        NSImage(systemSymbolName: provider.symbolName, accessibilityDescription: nil) != nil,
        "Missing system symbol for \(provider.displayName)")
    }
  }

  @Test("Expanded subtask titles reveal more lines than collapsed titles")
  func expandedTitleHeight() {
    let title = "Verify that every long subtask title remains readable when its details are expanded"
    let collapsed = height(of: SubtaskTitleLabel(title: title, isExpanded: false))
    let expanded = height(of: SubtaskTitleLabel(title: title, isExpanded: true))
    #expect(expanded > collapsed)
  }

  @Test("Subtasks start expanded and collapse only after an explicit toggle")
  func defaultExpansion() {
    var disclosure = SubtaskDisclosureState()
    #expect(disclosure.isExpanded("existing-subtask"))
    #expect(disclosure.isExpanded("new-subtask"))

    disclosure.toggle("existing-subtask")
    #expect(!disclosure.isExpanded("existing-subtask"))
    #expect(disclosure.isExpanded("new-subtask"))

    disclosure.toggle("existing-subtask")
    #expect(disclosure.isExpanded("existing-subtask"))
  }

  @Test("Agent indicator and cards use the same visible linked agents")
  func visibleLinkedAgentPresentation() {
    var visible = TaskSubtask(
      id: "visible", title: "Visible agent", sessionID: "active-session", status: .blocked)
    visible.parentSubtaskID = "assignment"
    var removedUnread = TaskSubtask(
      id: "removed", title: "Removed agent", sessionID: "old-session", status: .completed)
    removedUnread.parentSubtaskID = "assignment"
    removedUnread.agentRemovedAt = Date()
    removedUnread.completionUnread = true

    let presentation = SubtaskAgentPresentation(linkedAgents: [visible, removedUnread])
    #expect(presentation.count == 1)
    #expect(presentation.agents.map(\.id) == ["visible"])
  }

  private func height<V: View>(of view: V) -> CGFloat {
    let host = NSHostingView(rootView: view.frame(width: 150))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
  }
}
