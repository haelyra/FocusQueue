import AppKit
import FocusQueueCore
import Foundation
import SwiftUI
import Testing

@testable import ECCFocusQueue

@Suite("Token analytics layout")
@MainActor
struct TokenAnalyticsLayoutTests {
  @Test("The page fits the analytics inspector without horizontal scrolling",
        arguments: [CGFloat(560), CGFloat(750)])
  func fitsInspectorWidth(width: CGFloat) throws {
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
      events: events, agents: agents, close: {}
    ).frame(width: width))
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    #expect(image.size.width <= width + 0.5)
    #expect(image.size.height > 1_000)
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
