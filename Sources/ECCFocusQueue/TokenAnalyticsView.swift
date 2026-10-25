import FocusQueueCore
import Foundation
import SwiftUI

/// Local counters for each Focus Queue prompt stage. No model is called to render this view.
struct TokenAnalyticsView: View {
  let supportDirectory: URL
  let close: () -> Void
  @State private var events: [PromptUsageEvent] = []

  private let stages: [(String, String)] = [
    ("placement", "1. Task placement"),
    ("agent_launch", "2. Agent launch and plan context"),
    ("agent_command", "3. Agent requested commands"),
    ("queue_chat", "4. Queue Chat"),
    ("document_chat", "5. Document chat"),
    ("extraction", "6. data.md extraction"),
    ("daily_report", "7. Daily report"),
    ("daily_report_deep_pass", "8. Daily report deep pass")
  ]

  private var measured: [PromptUsageEvent] { events.filter { $0.runID != nil } }
  private var days: [String] {
    Array(Set(measured.map { day($0.timestamp) })).sorted(by: >)
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
          Text("Prompt context is estimated from characters ÷ 4. Provider usage is reported by the CLI when available; some runs report only a total. These columns overlap and should not be added together. Missing usage reports are excluded from actual averages.")
            .font(.caption).foregroundStyle(.secondary)
          HStack(spacing: 12) {
            metric("Measured runs", value: Set(measured.compactMap(\.runID)).count.formatted())
            metric("Estimated context", value: measured.filter { $0.scope != "provider" }
              .reduce(0) { $0 + $1.estimatedInputTokens }.formatted())
            metric("Provider reports", value: measured.filter { $0.scope == "provider" }.count.formatted())
          }
          ForEach(stages, id: \.0) { stage in
            let rows = measured.filter { $0.source == stage.0 }
            if !rows.isEmpty { stageView(stage.1, events: rows) }
          }
          if days.isEmpty { Text("No pipeline measurements yet").foregroundStyle(.secondary) }
          Text("Token sources by day").font(.headline)
          ForEach(days, id: \.self) { date in
            let daily = measured.filter { day($0.timestamp) == date }
            VStack(alignment: .leading, spacing: 7) {
              Text(date).font(.subheadline.bold())
              ForEach(stages, id: \.0) { stage in
                let rows = daily.filter { $0.source == stage.0 }
                if !rows.isEmpty {
                  HStack(spacing: 8) {
                    GeometryReader { geometry in
                      let maximum = max(1, stages.map { candidate in
                        PromptUsageSummary(events: daily.filter { $0.source == candidate.0 }).estimatedTokens
                      }.max() ?? 1)
                      RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
                        .frame(width: max(2, geometry.size.width * CGFloat(PromptUsageSummary(events: rows).estimatedTokens)
                          / CGFloat(maximum)))
                    }.frame(width: 70, height: 10)
                    summary(stage.1, events: rows)
                  }
                }
              }
            }
          }
          Text("Instruction file counts are estimates of provider loaded files. Command output counts are estimates of text returned to an agent. Historical events without run IDs are omitted from these averages.")
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

  private func stageView(_ title: String, events rows: [PromptUsageEvent]) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.headline)
      summary("Stage total", events: rows)
      if PromptUsageSummary(events: rows).reportedRuns > 0 {
        let usage = PromptUsageSummary(events: rows)
        Text("Reported input \(usage.reportedInputTokens.formatted()) · output \(usage.reportedOutputTokens.formatted()) · cached input \(usage.cachedInputTokens.formatted()) · \(usage.reportedRuns) reported runs")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(Array(Set(rows.filter { $0.scope != "provider" }.map(\.component))).sorted(), id: \.self) { component in
        summary(component.replacingOccurrences(of: "_", with: " "),
                events: rows.filter { $0.component == component })
      }
    }
  }

  private func summary(_ label: String, events rows: [PromptUsageEvent]) -> some View {
    let value = PromptUsageSummary(events: rows)
    return HStack(spacing: 8) {
      Text(label).lineLimit(1).help(label).frame(maxWidth: .infinity, alignment: .leading)
      Text("\(value.runs) runs").frame(width: 65, alignment: .trailing)
      Text("est \(value.estimatedTokens.formatted())").frame(width: 95, alignment: .trailing)
      Text("avg \(value.estimatedAverage.formatted())").frame(width: 85, alignment: .trailing)
      if let actual = value.actualTokens, let average = value.actualAverage {
        Text("actual \(actual.formatted()) · avg \(average.formatted())")
          .frame(width: 175, alignment: .trailing)
      } else {
        Text("actual —").frame(width: 175, alignment: .trailing)
      }
    }
    .font(.caption.monospacedDigit())
  }

  private func day(_ date: Date) -> String {
    date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
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
}
