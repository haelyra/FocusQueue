import FocusQueueCore
import Foundation
import SwiftUI

/// Local counters for each Focus Queue prompt stage. No model is called to render this view.
struct TokenAnalyticsView: View {
  let supportDirectory: URL
  let close: () -> Void
  @State private var events: [PromptUsageEvent] = []

  private let stages: [(String, String, String)] = [
    ("placement", "1. Task placement",
     "The placement agent compares a new request with open tasks and suggests an existing task or a new one."),
    ("agent_launch", "2. Agent launch and plan context",
     "What a task agent receives at startup: its launch brief, central and project plans, scoped data, and applicable AGENTS.md or CLAUDE.md instructions."),
    ("agent_command", "3. Agent requested commands",
     "Text returned by focus-queue-session commands run inside an agent, such as rules, plan, brief, context, and JSON receipts."),
    ("queue_chat", "4. Queue Chat",
     "The app's instructions and queue state wrapped around each message sent to central Queue Chat."),
    ("document_chat", "5. Document chat",
     "The chat wrapper plus quoted document, plan, instruction files, and recent conversation sent with a document question."),
    ("extraction", "6. data.md extraction",
     "The automatic extractor that reviews a user prompt for durable facts and proposes where to save them."),
    ("daily_report", "7. Daily report",
     "The report classifier's prompt, including instructions, dashboard state, and selected source messages."),
    ("daily_report_deep_pass", "8. Daily report deep pass",
     "A follow-up classification of candidate tasks using their supporting source material.")
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
      ScrollView([.vertical, .horizontal]) {
        VStack(alignment: .leading, spacing: 18) {
          Text("Estimated tokens = characters ÷ 4. These counts describe text sent or returned at each step; daily report prompts include source content. Provider usage comes from the CLI when available. Estimates and provider totals overlap, so do not add them together. Missing reports are excluded from actual averages.")
            .font(.caption).foregroundStyle(.secondary)
          HStack(spacing: 12) {
            metric("Measured runs", value: Set(measured.compactMap(\.runID)).count.formatted())
            metric("Estimated measured text", value: measured.filter { $0.scope != "provider" }
              .reduce(0) { $0 + $1.estimatedInputTokens }.formatted())
            metric("Provider reports", value: measured.filter { $0.scope == "provider" }.count.formatted())
          }
          if measured.isEmpty {
            Text("No pipeline measurements yet. New agent and chat activity will appear here.")
              .font(.caption).foregroundStyle(.secondary)
          }
          ForEach(stages, id: \.0) { stage in
            let rows = measured.filter { $0.source == stage.0 }
            stageView(stage.1, description: stage.2, source: stage.0, events: rows)
          }
          Text("Token sources by day").font(.headline)
          if days.isEmpty { Text("No daily measurements yet").foregroundStyle(.secondary) }
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
          Text("Instruction-file counts estimate what a provider loads from the agent's folder ancestry. Command counts estimate output returned to the agent. Historical events without run IDs are omitted from these averages.")
            .font(.caption).foregroundStyle(.secondary)
          Text(PromptUsageMetrics.file(in: supportDirectory).path)
            .font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .frame(minWidth: 720, maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(14)
    .onAppear(perform: reload)
  }

  private func stageView(_ title: String, description: String, source: String,
                         events rows: [PromptUsageEvent]) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title).font(.headline)
      Text(description).font(.caption).foregroundStyle(.secondary)
      summary("Stage total", events: rows)
      if PromptUsageSummary(events: rows).reportedRuns > 0 {
        let usage = PromptUsageSummary(events: rows)
        Text("Reported input \(usage.reportedInputTokens.formatted()) · output \(usage.reportedOutputTokens.formatted()) · cached input \(usage.cachedInputTokens.formatted()) · \(usage.reportedRuns) reported runs")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(Array(Set(rows.filter { $0.scope != "provider" }.map(\.component))).sorted(), id: \.self) { component in
        summary(component.replacingOccurrences(of: "_", with: " "),
                events: rows.filter { $0.component == component },
                detail: componentDescription(source: source, component: component))
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
  }

  private func summary(_ label: String, events rows: [PromptUsageEvent],
                       detail: String? = nil) -> some View {
    let value = PromptUsageSummary(events: rows)
    return HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(label).fontWeight(.medium).textSelection(.enabled)
        if let detail { Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
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

  private func componentDescription(source: String, component: String) -> String {
    if component.hasSuffix(" · output_contract") {
      return "The structured response format section in this instruction file."
    }
    if component.hasSuffix(" · other_instructions") {
      return "The remaining guidance in this instruction file, counted separately from its response format."
    }
    return switch component {
    case "system_instructions": "Fixed instructions given to the placement or extraction model."
    case "candidate_tasks_and_wrapper": "Open task candidates and formatting around the new request."
    case "catalog_and_wrapper": "Available data destinations and formatting around the user prompt."
    case "project_plan": "The project's plan.md text included in the task agent's first prompt."
    case "task_plan": "The task's central plan.md text included in the agent's first prompt."
    case "task_data": "Task-level data.md facts included in the launch prompt."
    case "project_data": "Project-level data.md facts included in the launch prompt."
    case "user_data": "User-level data.md facts included in the launch prompt."
    case "brief_and_rules": "The assignment, task rules, and launch text outside the separately counted files."
    case "app_context": source == "queue_chat"
      ? "Queue Chat's app instructions and queue snapshot, excluding the typed message."
      : "Document Chat's app instructions, excluding the quoted sources and typed request."
    case "document_sources_plan_and_history": "Quoted source files, plan, and recent messages, excluding the typed request."
    case "full_prompt": "The complete report prompt, including source messages and app instructions."
    case "rules": "Output of focus-queue-session rules when an agent requests it."
    case "brief": "Output of focus-queue-session brief when an agent requests it."
    case "plan": "Output of focus-queue-session plan when an agent requests it."
    case "context": "Output of focus-queue-session context when an agent requests it."
    default: "Output returned by this Focus Queue command to an agent."
    }
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
