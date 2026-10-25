import FocusQueueCore
import Foundation
import SwiftUI

/// Debug view for local counters. Reading this file never invokes an agent.
struct TokenAnalyticsView: View {
  let supportDirectory: URL
  let close: () -> Void
  @State private var events: [PromptUsageEvent] = []

  private var prompts: [PromptUsageEvent] { events.filter { $0.characters > 0 } }
  private var providerRuns: [PromptUsageEvent] { events.filter { $0.actualInputTokens != nil } }
  private var automaticPrompts: Int {
    prompts.filter { !["agent_launch", "queue_chat"].contains($0.source) }.count
  }
  private var bySource: [(String, Int)] {
    Dictionary(grouping: prompts, by: { $0.source + " · " + $0.component })
      .map { ($0.key, $0.value.reduce(0) { $0 + $1.estimatedInputTokens }) }
      .sorted { $0.1 > $1.1 }
  }
  private var byDay: [(String, Int)] {
    Dictionary(grouping: prompts) { event in
      event.timestamp.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }.map { ($0.key, $0.value.reduce(0) { $0 + $1.estimatedInputTokens }) }
      .sorted { $0.0 < $1.0 }
  }
  private var byProvider: [(String, Int)] {
    Dictionary(grouping: providerRuns, by: { $0.provider ?? "unknown" })
      .map { ($0.key, $0.value.compactMap(\.actualInputTokens).reduce(0, +)) }
      .sorted { $0.1 > $1.1 }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Button(action: close) { Image(systemName: "chevron.left") }
          .buttonStyle(.plain).accessibilityLabel("Back to settings")
        Text("Token analytics").font(.title2.bold())
        Spacer()
        Button("Refresh", systemImage: "arrow.clockwise") { reload() }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          HStack(spacing: 12) {
            metric("Prompt events", value: prompts.count.formatted())
            metric("Estimated input", value: prompts.reduce(0) { $0 + $1.estimatedInputTokens }.formatted())
            metric("Automatic calls", value: automaticPrompts.formatted())
            metric("Usage reports", value: providerRuns.count.formatted())
          }
          Text("Prompt estimates use characters ÷ 4. Provider totals include provider context and tool traffic, so do not add them to prompt estimates.")
            .font(.caption).foregroundStyle(.secondary)
          chart("Estimated prompt tokens by source", rows: bySource)
          chart("Estimated prompt tokens by day", rows: byDay)
          if !providerRuns.isEmpty {
            chart("Reported provider input tokens", rows: byProvider)
            HStack(spacing: 12) {
              metric("Provider input", value: providerRuns.compactMap(\.actualInputTokens).reduce(0, +).formatted())
              metric("Provider output", value: providerRuns.compactMap(\.actualOutputTokens).reduce(0, +).formatted())
            }
          }
          Text("Local metadata only. Prompts and message bodies are not saved here.")
            .font(.caption).foregroundStyle(.secondary)
          Text(PromptUsageMetrics.file(in: supportDirectory).path)
            .font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(14)
    .onAppear(perform: reload)
  }

  private func reload() { events = PromptUsageMetrics.load(in: supportDirectory) }

  private func metric(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title3.bold().monospacedDigit())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
  }

  private func chart(_ title: String, rows: [(String, Int)]) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.headline)
      if rows.isEmpty { Text("No measurements yet").foregroundStyle(.secondary) }
      ForEach(rows, id: \.0) { row in
        HStack(spacing: 8) {
          Text(row.0.replacingOccurrences(of: "_", with: " "))
            .frame(width: 150, alignment: .leading).lineLimit(1).help(row.0)
          GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor)
              .frame(width: max(2, geometry.size.width * CGFloat(row.1) /
                CGFloat(max(1, rows.map(\.1).max() ?? 1))))
          }.frame(height: 14)
          Text(row.1.formatted()).monospacedDigit().frame(width: 70, alignment: .trailing)
        }.font(.caption)
      }
    }
  }
}
