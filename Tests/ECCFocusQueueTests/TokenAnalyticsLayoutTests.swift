import AppKit
import FocusQueueCore
import Foundation
import SwiftUI
import Testing

@testable import ECCFocusQueue

@Suite("Token analytics layout")
@MainActor
struct TokenAnalyticsLayoutTests {
  @Test("The native range picker includes and selects one day")
  func nativeOneDayPicker() throws {
    let hosting = NSHostingView(rootView: TokenAnalyticsView(
      supportDirectory: URL(fileURLWithPath: "/tmp"), sessions: [], scrolls: false,
      rangeDays: 1, close: {}).frame(width: 560))
    hosting.frame = NSRect(x: 0, y: 0, width: 560, height: hosting.fittingSize.height)
    hosting.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap(descendants)
    }
    let picker = try #require(descendants(hosting).compactMap { $0 as? NSSegmentedControl }.first)
    #expect((0..<picker.segmentCount).map { picker.label(forSegment: $0) } == ["1 day", "7 days", "14 days", "30 days"])
    #expect(picker.selectedSegment == 0)
    if let output = ProcessInfo.processInfo.environment["FOCUS_QUEUE_RENDER_DIR"],
       let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
      hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(to:
        URL(fileURLWithPath: output).appendingPathComponent("analytics-native-one-day.png"))
    }
  }

  @Test("The page fits the analytics inspector without horizontal scrolling",
        arguments: [CGFloat(560), CGFloat(750)], [1, 14])
  func fitsInspectorWidth(width: CGFloat, rangeDays: Int) throws {
    let today = TokenUsageDay.key(Date())
    let usage = TokenBreakdown(uncachedInput: 2_000, cacheRead: 4_000_000, cacheWrite: 90_000, output: 40_000)
    let agents = [
      AgentSessionUsage(id: "a", ticketID: "FOC-001", provider: "claude", label: "Long agent", turns: 120,
                        firstContext: 48_000, peakContext: 180_000, contextWindow: 200_000,
                        totals: usage, daily: [today: usage]),
      AgentSessionUsage(id: "b", ticketID: "FOC-002", provider: "codex", label: "Short agent", turns: 30,
                        firstContext: 28_000, peakContext: 90_000, contextWindow: 258_400,
                        totals: usage, daily: [today: usage]),
    ]
    let events = [
      PromptUsageEvent(source: "agent_launch", component: "task_plan", provider: "claude",
                       characters: 8_000, runID: "launch"),
      PromptUsageEvent(source: "placement", component: "system_instructions", characters: 6_000, runID: "p"),
      PromptUsageEvent(source: "placement", component: "provider_usage", provider: "claude",
                       actualInputTokens: 2, actualOutputTokens: 340, cachedInputTokens: 8_800,
                       runID: "p", scope: "provider"),
    ]
    let renderer = ImageRenderer(content: TokenAnalyticsView(
      supportDirectory: URL(fileURLWithPath: "/tmp"), sessions: [], scrolls: false,
      events: events, agents: agents, rangeDays: rangeDays, close: {}
    ).frame(width: width))
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    #expect(image.size.width <= width + 0.5)
    #expect(image.size.height > 1_000)
    if let output = ProcessInfo.processInfo.environment["FOCUS_QUEUE_RENDER_DIR"],
       let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
      try bitmap.representation(using: .png, properties: [:])?.write(to:
        URL(fileURLWithPath: output).appendingPathComponent("analytics-\(rangeDays)-day-\(Int(width)).png"))
    }
  }

  @Test("One-day analytics includes only the current local calendar day")
  func oneDayUsesLocalMidnight() throws {
    let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let now = try Date("2026-10-30T01:00:00Z", strategy: .iso8601)
    let yesterday = try Date("2026-10-29T06:59:59Z", strategy: .iso8601)
    let today = try Date("2026-10-29T07:00:00Z", strategy: .iso8601)
    let events = [yesterday, today, now].enumerated().map { index, date in
      PromptUsageEvent(source: "document_chat", component: "provider_usage", actualTotalTokens: 10,
                       runID: "run-\(index)", scope: "provider", timestamp: date)
    }
    let usage = TokenBreakdown(output: 20)
    let agent = AgentSessionUsage(id: "a", ticketID: "FOC-093", provider: "codex", label: "Agent",
      turns: 2, firstContext: 10, peakContext: 10, contextWindow: 200_000, totals: usage + usage,
      daily: ["2026-10-28": usage, "2026-10-29": usage])
    let ranges = AnalyticsRange.build(events: events, agents: [agent], now: now, timeZone: zone)
    let day = try #require(ranges[1])
    #expect(day.days == ["2026-10-29"])
    #expect(day.measured.map(\.runID) == ["run-1", "run-2"])
    #expect(day.agents.first?.1.total == 20)
    #expect(day.agentPoints.reduce(0) { $0 + $1.tokens } == 20)
    #expect(day.stepPoints.reduce(0) { $0 + $1.tokens } == 20)
    #expect(ranges[7]?.measured.count == 3)
    #expect(ranges[7]?.agents.first?.1.total == 40)
    #expect(Set(ranges.keys) == Set([1, 7, 14, 30]))
  }

  @Test("Claude usage counts cached prompt tokens as input")
  func normalizesClaudeInput() {
    let claude = PromptUsageEvent(source: "placement", component: "provider_usage", provider: "claude",
                                  actualInputTokens: 2, actualOutputTokens: 347, actualTotalTokens: 349,
                                  cachedInputTokens: 8_817, runID: "r", scope: "provider")
    let codex = PromptUsageEvent(source: "queue_chat", component: "provider_usage", provider: "codex",
                                 actualInputTokens: 154_532, actualOutputTokens: 736,
                                 cachedInputTokens: 119_552, runID: "c", scope: "provider")
    #expect(claude.reportedInputTokens == 8_819)
    #expect(claude.reportedTotalTokens == 9_166)
    #expect(codex.reportedInputTokens == 154_532)
    #expect(PromptUsageSummary(events: [claude]).actualTokens == 9_166)
  }
}
