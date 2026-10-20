import AppKit
import FocusQueueCore
import SwiftUI
import Testing

@testable import ECCFocusQueue

@Suite("Subtask presentation")
@MainActor
struct SubtaskPresentationTests {
  @Test("Shared creator provider selection restores each provider's settings")
  func providerSelectionRestoresProviderSettings() {
    let codex = AgentLaunchPreset(
      provider: .codex, model: "gpt-6", effort: "high",
      workspacePolicy: .existingCheckout, useTmux: false, includePrompt: false,
      pluginOverrides: ["codex-plugin": true])
    let claude = AgentLaunchPreset(
      provider: .claude, model: "sonnet", effort: "medium",
      pluginOverrides: ["claude-plugin": false])
    let kimi = AgentLaunchPreset(provider: .kimi, model: "kimi-code/k3", effort: "high")

    let selectedClaude = AgentLaunchOptions.preset(
      selecting: .claude, from: codex, lastLaunch: claude)
    #expect(selectedClaude.provider == .claude)
    #expect(selectedClaude.model == "sonnet")
    #expect(selectedClaude.effort == "medium")
    #expect(selectedClaude.pluginOverrides == ["claude-plugin": false])

    let selectedKimi = AgentLaunchOptions.preset(
      selecting: .kimi, from: selectedClaude, lastLaunch: kimi)
    #expect(selectedKimi.provider == .kimi)
    #expect(selectedKimi.model == "kimi-code/k3")
    #expect(selectedKimi.effort == "high")
    #expect(selectedKimi.pluginOverrides == nil)
    #expect(selectedKimi.workspacePolicy == .existingCheckout)
    #expect(selectedKimi.useTmux == false)
    #expect(selectedKimi.includePrompt == false)
    #expect(AgentLaunchOptions.preset(
      selecting: .kimi, from: selectedKimi, lastLaunch: claude) == selectedKimi)
  }

  @Test("Agent providers use distinct available icons")
  func providerIcons() {
    #expect(AgentProvider.codex.symbolName != AgentProvider.claude.symbolName)
    for provider in AgentProvider.allCases {
      #expect(
        NSImage(systemSymbolName: provider.symbolName, accessibilityDescription: nil) != nil,
        "Missing system symbol for \(provider.displayName)")
    }
  }

  @Test("Provider marks are centered, theme-tinted templates")
  @MainActor
  func providerLogos() throws {
    for provider in AgentProvider.allCases {
      let image = ProviderLogo.image(for: provider, size: 12)
      #expect(image.size.height == 12)
      #expect(image.size.width >= 12 && image.size.width <= 12 * ProviderLogo.maxWidthRatio + 1)
      #expect(image.isTemplate)
      let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
      var columns: [Int] = [], rows: [Int] = []
      for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
          columns.append(x); rows.append(y)
        }
      }
      let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
      let minX = try #require(columns.min()), maxX = try #require(columns.max())
      let minY = try #require(rows.min()), maxY = try #require(rows.max())
      // The ink fills the box on at least one axis and sits centered on both.
      #expect(maxX - minX + 1 >= width - 2 || maxY - minY + 1 >= height - 2)
      #expect(abs((minX + maxX + 1) - width) <= 2)
      #expect(abs((minY + maxY + 1) - height) <= 2)
    }
    // The Claude mascot keeps its eye holes (even-odd fill).
    let claude = try #require(ProviderLogo.image(for: .claude, size: 48).tiffRepresentation
      .flatMap(NSBitmapImageRep.init(data:)))
    let scale = CGFloat(claude.pixelsHigh) / 48
    func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
      claude.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? 0
    }
    // 24x15 mascot at 60x37.5pt (2.5x): viewBox (6.7, 9.5) is the left eye.
    #expect(alpha(6.7 * 2.5, (9.5 - 5) * 2.5 + 5.25) < 0.1)
    #expect(alpha(12 * 2.5, (9.5 - 5) * 2.5 + 5.25) > 0.9)
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
    #expect(overflow.fittingSize.width >= 20)
    #expect(overflow.fittingSize.height >= 24)

    let rendered = NSHostingView(rootView: ZStack {
      Color.black
      Menu {
        Button("Inspect") {}
      } label: {
        VerticalOverflowIcon()
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(width: 44, height: 44)
    }.frame(width: 44, height: 44))
    rendered.frame = NSRect(x: 0, y: 0, width: 44, height: 44)
    rendered.layoutSubtreeIfNeeded()
    let bitmap = try! #require(rendered.bitmapImageRepForCachingDisplay(in: rendered.bounds))
    rendered.cacheDisplay(in: rendered.bounds, to: bitmap)
    var brightestPixel = 0.0
    for x in 0..<bitmap.pixelsWide {
      for y in 0..<bitmap.pixelsHigh {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        brightestPixel = max(brightestPixel,
          [color.redComponent, color.greenComponent, color.blueComponent].max() ?? 0)
      }
    }
    // The native Menu applies control antialiasing, but the foreground dots
    // must remain visibly near-white instead of disappearing into the row.
    #expect(brightestPixel > 0.75)
  }

  private func height<V: View>(of view: V) -> CGFloat {
    let host = NSHostingView(rootView: view.frame(width: 150))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
  }
}
