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
    #expect(SubtaskDisclosureState.defaultExpanded)
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

  @Test("Last output age uses compact deterministic boundaries")
  func compactLastOutputAge() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    #expect(AgentOutputAgeFormatter.string(from: now.addingTimeInterval(-59), relativeTo: now) == "now")
    #expect(AgentOutputAgeFormatter.string(from: now.addingTimeInterval(-60), relativeTo: now) == "1m ago")
    #expect(AgentOutputAgeFormatter.string(from: now.addingTimeInterval(-1_800), relativeTo: now) == "30m ago")
    #expect(AgentOutputAgeFormatter.string(from: now.addingTimeInterval(-12_600), relativeTo: now) == "3.5h ago")
    #expect(AgentOutputAgeFormatter.string(from: now.addingTimeInterval(-86_400), relativeTo: now) == "1 day ago")
    #expect(AgentOutputAgeFormatter.string(from: now.addingTimeInterval(-172_800), relativeTo: now) == "2 days ago")
    #expect(AgentOutputAgeFormatter.string(from: now.addingTimeInterval(60), relativeTo: now) == "now")
  }

  @Test("Last output timestamp migrates from result time without using heartbeat")
  func legacyLastOutputTimestamp() {
    let heartbeatAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let resultAt = heartbeatAt.addingTimeInterval(-600)
    let outputAt = heartbeatAt.addingTimeInterval(-60)

    var legacy = TaskSubtask(
      title: "Legacy agent", status: .completed, lastHeartbeatAt: heartbeatAt)
    legacy.resultAt = resultAt
    #expect(AgentOutputTimestamp.value(for: legacy) == resultAt)

    var current = legacy
    current.lastOutputAt = outputAt
    #expect(AgentOutputTimestamp.value(for: current) == outputAt)

    var heartbeatOnly = TaskSubtask(
      title: "Heartbeat only", status: .working, lastHeartbeatAt: heartbeatAt)
    heartbeatOnly.resultAt = nil
    #expect(AgentOutputTimestamp.value(for: heartbeatOnly) == nil)
  }

  @Test("Production agent status renders output age beside the status chip")
  func agentStatusSeparatesLastOutputAge() {
    let view = AgentStatusCluster(
      status: .working,
      hasUnreadCompletion: true,
      isOpening: false,
      issue: nil,
      lastOutputAt: Date().addingTimeInterval(-1_800))
      .frame(width: 220, height: 44)
    let host = NSHostingView(rootView: view)
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.width > 0)
    #expect(host.fittingSize.height >= 44)
    let overflow = NSHostingView(rootView: VerticalOverflowIcon())
    overflow.layoutSubtreeIfNeeded()
    #expect(overflow.fittingSize.width >= 18)
    #expect(overflow.fittingSize.height >= 22)
    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
      let appearance = try! #require(NSAppearance(named: appearanceName))
      var contrast = 0.0
      appearance.performAsCurrentDrawingAppearance {
        let dot = NSColor.secondaryLabelColor.usingColorSpace(.deviceRGB)!
        let background = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)!
        let dotComponents = [dot.redComponent, dot.greenComponent, dot.blueComponent]
        let backgroundComponents = [
          background.redComponent, background.greenComponent, background.blueComponent,
        ]
        let effective = zip(dotComponents, backgroundComponents).map {
          $0 * dot.alphaComponent + $1 * (1 - dot.alphaComponent)
        }
        contrast = zip(effective, backgroundComponents).map { abs($0 - $1) }.max() ?? 0
      }
      #expect(contrast > 0.2)
    }
  }

  private func height<V: View>(of view: V) -> CGFloat {
    let host = NSHostingView(rootView: view.frame(width: 150))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
  }
}
