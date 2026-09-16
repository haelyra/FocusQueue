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

  private func height<V: View>(of view: V) -> CGFloat {
    let host = NSHostingView(rootView: view.frame(width: 150))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
  }
}
