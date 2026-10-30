import AppKit
import Charts
import FocusQueueCore
import Foundation
import SwiftUI

/// Token usage from local files only: the app's prompt counters and the
/// providers' own session transcripts. No model is called to render this view.
struct TokenAnalyticsView: View, Equatable {
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.supportDirectory == rhs.supportDirectory && lhs.scrolls == rhs.scrolls
  }
  let supportDirectory: URL
  let sessions: [AgentTranscriptUsage.Session]
  /// Off only when rendering the whole page to an image.
  var scrolls = true
  let close: () -> Void

  @State private var events: [PromptUsageEvent]
  @State private var agents: [AgentSessionUsage]
  @State private var ranges: [Int: AnalyticsRange]
  @State private var didLoad = false
  @State private var isLoading = false
  @State private var rangeDays = 14
  @State private var selectedAgentDay: String?
  @State private var selectedStepDay: String?

  init(supportDirectory: URL, sessions: [AgentTranscriptUsage.Session], scrolls: Bool = true,
       events: [PromptUsageEvent] = [], agents: [AgentSessionUsage] = [], close: @escaping () -> Void) {
    self.supportDirectory = supportDirectory
    self.sessions = sessions
    self.scrolls = scrolls
    self.close = close
    _events = State(initialValue: events)
    _agents = State(initialValue: agents)
    _ranges = State(initialValue: events.isEmpty && agents.isEmpty ? [:] : AnalyticsRange.build(events: events, agents: agents))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      if scrolls {
        ScrollView(.vertical) { content }
      } else {
        content
      }
    }
    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    .onAppear { if scrolls && !didLoad { didLoad = true; reload() } }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 16) {
      explanation
      Text("Snapshot taken when opened. Reopen to update. Calls show reported usage / attempts; attempts without reports may have failed or been stopped.")
        .font(.caption).foregroundStyle(.secondary)
      summaryTiles
      agentDailyCard
      stepDailyCard
      perAgentCard
      contextCard
      componentCard
      Text(PromptUsageMetrics.file(in: supportDirectory).path)
        .font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Header and explanation

  private var header: some View {
    HStack(spacing: 10) {
      Button(action: close) { Image(systemName: "chevron.left") }
        .buttonStyle(.plain).accessibilityLabel("Back to settings").help("Back to settings")
      Text("Token analytics").font(.title2.bold())
      if isLoading { ProgressView().controlSize(.small) }
      Spacer()
      Picker("Range", selection: $rangeDays) {
        Text("7 days").tag(7)
        Text("14 days").tag(14)
        Text("30 days").tag(30)
      }
      .pickerStyle(.segmented).labelsHidden().fixedSize()
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
  }

  private var explanation: some View {
    card {
      Text("Where these numbers come from").font(.headline)
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
        GridRow {
          Text("Actual").bold()
          Text("Tokens the provider reported. Agent sessions come from Claude and Codex transcripts on this Mac; app steps come from each model call's usage report. Actual counts include cached tokens the model re-reads on every turn.")
        }
        GridRow {
          Text("Focus Queue text").bold()
          Text("An estimate (characters ÷ 4) of only the text Focus Queue adds. It is one part of the actual input, so it is always smaller.")
        }
        GridRow {
          Text("CLI prompt & other").bold()
          Text("Actual input minus Focus Queue text: the CLI's own system prompt, tool definitions, and instruction files Focus Queue does not measure.")
        }
      }
      .font(.callout).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var summaryTiles: some View {
    let active = agentsInRange
    let agentTotal = active.reduce(0) { $0 + $1.1.total }
    let stepTotal = stepRows.compactMap(\.actualTotal).reduce(0, +)
    let starts = agents.map(\.firstContext).filter { $0 > 0 }
    return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
      tile("Agent tokens · \(rangeDays)d", compact(agentTotal), "\(active.count) active agents")
      tile("Average per agent · \(rangeDays)d", compact(active.isEmpty ? 0 : agentTotal / active.count),
           "All-time average \(compact(agents.isEmpty ? 0 : agents.reduce(0) { $0 + $1.totals.total } / agents.count))")
      tile("Average starting context", compact(starts.isEmpty ? 0 : starts.reduce(0, +) / starts.count),
           "First model turn of an agent")
      tile("App model calls · \(rangeDays)d", compact(stepTotal), "Placement, chat, reports, reviews")
    }
  }

  // MARK: Daily usage

  private var agentDailyCard: some View {
    let points = ranges[rangeDays]?.agentPoints ?? []
    return card {
      sectionTitle("Daily agent usage", "All tracked agent sessions, by how the provider processed the tokens.")
      if points.allSatisfy({ $0.tokens == 0 }) {
        empty("No agent transcript usage in this range.")
      } else {
        Chart {
          ForEach(points) { point in
            BarMark(x: .value("Day", shortDay(point.day)), y: .value("Tokens", point.tokens))
              .foregroundStyle(by: .value("Kind", point.series))
          }
          if let selectedAgentDay {
            RuleMark(x: .value("Day", selectedAgentDay))
              .foregroundStyle(.secondary.opacity(0.4))
              .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                tooltip(day: selectedAgentDay, points: points)
              }
          }
        }
        .chartForegroundStyleScale(domain: TokenKind.allCases.map(\.title),
                                   range: TokenKind.allCases.map(\.color))
        .chartXSelection(value: $selectedAgentDay)
        .chartYAxis { compactYAxis }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 220)
      }
    }
  }

  private var stepDailyCard: some View {
    let reported = TokenStep.modelCalls
    let points = ranges[rangeDays]?.stepPoints ?? []
    return card {
      sectionTitle("Daily usage by app step", "Actual tokens for each model call Focus Queue makes on its own.")
      if points.allSatisfy({ $0.tokens == 0 }) {
        empty("No reported model calls in this range.")
      } else {
        Chart {
          ForEach(points.filter { $0.tokens > 0 }) { point in
            BarMark(x: .value("Day", shortDay(point.day)), y: .value("Tokens", point.tokens))
              .foregroundStyle(by: .value("Step", point.series))
          }
          if let selectedStepDay {
            RuleMark(x: .value("Day", selectedStepDay))
              .foregroundStyle(.secondary.opacity(0.4))
              .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                tooltip(day: selectedStepDay, points: points)
              }
          }
        }
        .chartXScale(domain: days.map(shortDay))
        .chartForegroundStyleScale(domain: reported.map(\.title), range: reported.map(\.color))
        .chartXSelection(value: $selectedStepDay)
        .chartYAxis { compactYAxis }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 200)
      }
      stepTable
    }
  }

  private var stepTable: some View {
    Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 7) {
      GridRow {
        Text("Step").gridColumnAlignment(.leading)
        Text("Calls")
        Text("Actual total")
        Text("Actual / run")
        Text("Focus Queue text / run")
      }
      .font(.caption.bold()).foregroundStyle(.secondary)
      Divider().gridCellUnsizedAxes(.horizontal)
      ForEach(stepRows) { row in
        GridRow {
          HStack(spacing: 6) {
            Circle().fill(row.step.color).frame(width: 8, height: 8)
            Text(row.step.title)
          }
          .help(row.step.detail)
          Text(row.step.actualNote == "—" ? "\(row.runs) / \(row.attempts)" : row.attempts.formatted())
          Text(row.actualTotal.map(compact) ?? row.step.actualNote)
            .foregroundStyle(row.actualTotal == nil ? .secondary : .primary)
          Text(row.actualAverage.map(compact) ?? "—")
          Text(row.estimatedAverage > 0 ? compact(row.estimatedAverage) : "—")
        }
        .font(.callout.monospacedDigit())
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Per agent

  private var perAgentCard: some View {
    let ranked = agentsInRange.sorted { $0.1.total > $1.1.total }
    let top = Array(ranked.prefix(8))
    let average = ranked.isEmpty ? 0 : ranked.reduce(0) { $0 + $1.1.total } / ranked.count
    return card {
      sectionTitle("Average per agent", "Total tokens one agent session uses, from its transcript.")
      providerTable
      if !top.isEmpty {
        HStack(alignment: .firstTextBaseline) {
          Text("Largest agents · last \(rangeDays) days").font(.subheadline.bold())
          Spacer()
          Text("Dashed line: average \(compact(average)) across \(ranked.count) agents")
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        Chart {
          ForEach(top, id: \.0.id) { agent, usage in
            BarMark(x: .value("Tokens", usage.total), y: .value("Agent", agentLabel(agent)))
              .foregroundStyle(providerColor(agent.provider))
              .annotation(position: .trailing) {
                Text(compact(usage.total)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
              }
          }
          RuleMark(x: .value("Average", average))
            .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .chartXAxis { compactXAxis }
        .frame(height: CGFloat(top.count) * 28 + 40)
      }
    }
  }

  private var providerTable: some View {
    let groups = Dictionary(grouping: agents, by: \.provider).sorted { $0.key < $1.key }
    return Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 7) {
      GridRow {
        Text("Provider").gridColumnAlignment(.leading)
        Text("Agents")
        Text("Avg total")
        Text("Avg turns")
        Text("Avg start")
        Text("Avg peak")
      }
      .font(.caption.bold()).foregroundStyle(.secondary)
      Divider().gridCellUnsizedAxes(.horizontal)
      ForEach(groups, id: \.key) { provider, rows in
        GridRow {
          HStack(spacing: 6) {
            Circle().fill(providerColor(provider)).frame(width: 8, height: 8)
            Text(provider.capitalized)
          }
          Text(rows.count.formatted())
          Text(compact(rows.reduce(0) { $0 + $1.totals.total } / rows.count))
          Text((rows.reduce(0) { $0 + $1.turns } / rows.count).formatted())
          Text(compact(rows.reduce(0) { $0 + $1.firstContext } / rows.count))
          Text(compact(rows.reduce(0) { $0 + $1.peakContext } / rows.count))
        }
        .font(.callout.monospacedDigit())
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Context windows

  private var contextCard: some View {
    let launch = launchBreakdown
    let calls = callBreakdown
    return card {
      sectionTitle("Context window breakdown",
                   "What fills the model's context. Bars are averages across runs. \"Other\" is everything the CLI loads that Focus Queue does not measure, such as its own prompt, tool definitions, and the user's instruction files.")
      Text("Agent's first turn").font(.subheadline.bold())
      if launch.isEmpty {
        empty("No agent transcripts to measure yet.")
      } else {
        Chart(launch) { part in
          BarMark(x: .value("Tokens", part.tokens), y: .value("Provider", part.group))
            .foregroundStyle(by: .value("Part", part.series))
        }
        .chartForegroundStyleScale(domain: ContextPart.launchOrder.map(\.title),
                                   range: ContextPart.launchOrder.map(\.color))
        .chartXAxis { compactXAxis }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: CGFloat(Set(launch.map(\.group)).count) * 34 + 50)
      }

      Text("Context growth during a session").font(.subheadline.bold()).padding(.top, 6)
      growthChart

      Text("App model calls: average prompt per run").font(.subheadline.bold()).padding(.top, 6)
      if calls.isEmpty {
        empty("No reported model calls yet.")
      } else {
        Chart(calls) { part in
          BarMark(x: .value("Tokens", part.tokens), y: .value("Step", part.group))
            .foregroundStyle(by: .value("Part", part.series))
        }
        .chartForegroundStyleScale(domain: ContextPart.callOrder.map(\.title),
                                   range: ContextPart.callOrder.map(\.color))
        .chartXAxis { compactXAxis }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: CGFloat(Set(calls.map(\.group)).count) * 30 + 50)
      }
    }
  }

  private var growthChart: some View {
    let groups = Dictionary(grouping: agents, by: \.provider).sorted { $0.key < $1.key }
    let rows = groups.flatMap { provider, rows -> [ContextSlice] in
      let count = max(1, rows.count)
      return [
        ContextSlice(group: provider.capitalized, series: "Starting context",
                     tokens: rows.reduce(0) { $0 + $1.firstContext } / count),
        ContextSlice(group: provider.capitalized, series: "Peak context",
                     tokens: rows.reduce(0) { $0 + $1.peakContext } / count),
      ]
    }
    let order = ["Starting context", "Peak context"]
    let windows = groups.map { provider, rows in
      "\(provider.capitalized) " + Set(rows.map(\.contextWindow)).sorted().map(compact).joined(separator: " or ")
    }.joined(separator: " · ")
    return Group {
      if rows.isEmpty {
        empty("No agent transcripts to measure yet.")
      } else {
        Chart(rows) { row in
          BarMark(x: .value("Tokens", row.tokens), y: .value("Provider", row.group))
            .foregroundStyle(by: .value("Measure", row.series))
            .position(by: .value("Measure", row.series), axis: .vertical)
            .annotation(position: .trailing) {
              Text(compact(row.tokens)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .chartForegroundStyleScale(domain: order,
                                   range: [Palette.slot(0), Palette.slot(1)])
        .chartXAxis { compactXAxis }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: CGFloat(groups.count) * 50 + 50)
        Text("Context windows: \(windows). Peak is the largest single turn, averaged across agents.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Component detail

  private var componentCard: some View {
    let components = launchComponents
    let commands = commandComponents
    return card {
      sectionTitle("Focus Queue text by component",
                   "Estimated tokens (characters ÷ 4) that each piece of app text adds.")
      if components.isEmpty && commands.isEmpty { empty("No component measurements in this range.") }
      if !components.isEmpty {
        Text("Agent launch prompt · average per launch").font(.subheadline.bold())
        componentBars(components)
      }
      if !commands.isEmpty {
        Text("Commands agents run · average output per call").font(.subheadline.bold()).padding(.top, 4)
        componentBars(commands)
      }
    }
  }

  /// Average estimated tokens per launch for each launch prompt component.
  private var launchComponents: [(String, Int)] {
    let launch = measured.filter { $0.source == "agent_launch" }
    let runs = max(1, Set(launch.compactMap(\.runID)).count)
    let groups = Dictionary(grouping: launch, by: \.component)
    let rows: [(String, Int)] = groups.map { key, rows in
      (key, rows.reduce(0) { $0 + $1.estimatedInputTokens } / runs)
    }
    return rows.sorted { $0.1 > $1.1 }
  }

  /// Average output per call for each command, labelled with its call count.
  private var commandComponents: [(String, Int)] {
    let groups = Dictionary(grouping: measured.filter { $0.source == "agent_command" }, by: \.component)
    let rows: [(String, Int, Int)] = groups.map { key, rows in
      (key, rows.count, rows.reduce(0) { $0 + $1.estimatedInputTokens } / max(1, rows.count))
    }
    return rows.sorted { $0.1 * $0.2 > $1.1 * $1.2 }.map { ("\($0.0) (\($0.1)×)", $0.2) }
  }

  private func componentBars(_ rows: [(String, Int)]) -> some View {
    let maximum = max(1, rows.map(\.1).max() ?? 1)
    return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
      ForEach(rows, id: \.0) { label, tokens in
        GridRow {
          Text(label.replacingOccurrences(of: "_", with: " ")).lineLimit(1).truncationMode(.middle)
            .help(label)
          GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 3).fill(Palette.slot(0))
              .frame(width: max(2, geometry.size.width * CGFloat(tokens) / CGFloat(maximum)))
          }
          .frame(height: 10)
          Text(compact(tokens)).monospacedDigit().frame(minWidth: 48, alignment: .trailing)
        }
        .font(.callout)
      }
    }
  }

  // MARK: Derived data

  private var days: [String] { ranges[rangeDays]?.days ?? [] }
  private var measured: [PromptUsageEvent] { ranges[rangeDays]?.measured ?? [] }
  private var agentsInRange: [(AgentSessionUsage, TokenBreakdown)] { ranges[rangeDays]?.agents ?? [] }
  private var stepRows: [StepRow] { ranges[rangeDays]?.steps ?? [] }

  private var launchBreakdown: [ContextSlice] {
    let launches = events.filter { $0.source == "agent_launch" && $0.runID != nil }
    return Dictionary(grouping: agents, by: \.provider).sorted { $0.key < $1.key }.flatMap { provider, rows in
      let first = rows.reduce(0) { $0 + $1.firstContext } / max(1, rows.count)
      let mine = launches.filter { $0.provider == provider }
      let runs = max(1, Set(mine.compactMap(\.runID)).count)
      let files = mine.filter { $0.scope == "provider_file_estimate" }
        .reduce(0) { $0 + $1.estimatedInputTokens } / runs
      let app = mine.filter { $0.scope != "provider_file_estimate" }
        .reduce(0) { $0 + $1.estimatedInputTokens } / runs
      let group = provider.capitalized
      return [
        ContextSlice(group: group, series: ContextPart.focusQueue.title, tokens: min(app, first)),
        ContextSlice(group: group, series: ContextPart.instructionFiles.title, tokens: min(files, max(0, first - app))),
        ContextSlice(group: group, series: ContextPart.provider.title, tokens: max(0, first - app - files)),
      ]
    }
  }

  private var callBreakdown: [ContextSlice] {
    TokenStep.modelCalls.flatMap { step -> [ContextSlice] in
      let rows = measured.filter { $0.source == step.source }
      let reports = rows.filter { $0.scope == "provider" && $0.reportedInputTokens != nil }
      guard !reports.isEmpty else { return [] }
      let input = reports.compactMap(\.reportedInputTokens).reduce(0, +) / reports.count
      let output = reports.compactMap(\.actualOutputTokens).reduce(0, +) / reports.count
      let app = min(input, PromptUsageSummary(events: rows).estimatedAverage)
      return [
        ContextSlice(group: step.title, series: ContextPart.focusQueue.title, tokens: app),
        ContextSlice(group: step.title, series: ContextPart.provider.title, tokens: input - app),
        ContextSlice(group: step.title, series: ContextPart.output.title, tokens: output),
      ]
    }
  }

  private func reload() {
    isLoading = true
    let support = supportDirectory
    let sessions = sessions
    Task.detached(priority: .userInitiated) {
      let events = PromptUsageMetrics.load(in: support)
      let agents = AgentTranscriptUsage.scan(sessions)
      let ranges = AnalyticsRange.build(events: events, agents: agents)
      await MainActor.run {
        self.ranges = ranges
        self.events = events
        self.agents = agents
        self.isLoading = false
      }
    }
  }

  // MARK: Building blocks

  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10, content: content)
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
  }

  private func sectionTitle(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.headline)
      Text(subtitle).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title2.bold().monospacedDigit())
      Text(detail).font(.caption2).foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
  }

  private func empty(_ text: String) -> some View {
    Text(text).font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
  }

  private func tooltip(day: String, points: [DayPoint]) -> some View {
    let rows = points.filter { shortDay($0.day) == day && $0.tokens > 0 }
    return VStack(alignment: .leading, spacing: 3) {
      Text("\(day) · \(compact(rows.reduce(0) { $0 + $1.tokens }))").font(.caption.bold())
      ForEach(rows) { row in
        Text("\(row.series): \(compact(row.tokens))").font(.caption2.monospacedDigit())
      }
    }
    .padding(8)
    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
  }

  private var compactYAxis: some AxisContent {
    AxisMarks(position: .leading) { value in
      AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
      AxisValueLabel { if let tokens = value.as(Int.self) { Text(compact(tokens)) } }
    }
  }

  private var compactXAxis: some AxisContent {
    AxisMarks { value in
      AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
      AxisValueLabel { if let tokens = value.as(Int.self) { Text(compact(tokens)) } }
    }
  }

  private func shortDay(_ key: String) -> String {
    let parts = key.split(separator: "-")
    guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return key }
    return "\(month)/\(day)"
  }

  private func agentLabel(_ agent: AgentSessionUsage) -> String {
    "\(agent.ticketID) · \(agent.id.suffix(6))"
  }

  private func providerColor(_ provider: String) -> Color {
    switch provider {
    case "claude": Palette.slot(1)
    case "codex": Palette.slot(0)
    default: Palette.slot(2)
    }
  }
}

/// Abbreviates token counts: 950, 48K, 1.2M, 3.4B.
func compact(_ value: Int) -> String {
  let number = Double(value)
  switch abs(number) {
  case 1_000_000_000...: return String(format: "%.1fB", number / 1_000_000_000)
  case 1_000_000...: return String(format: "%.1fM", number / 1_000_000)
  case 10_000...: return String(format: "%.0fK", number / 1_000)
  case 1_000...: return String(format: "%.1fK", number / 1_000)
  default: return value.formatted()
  }
}

/// Preaggregated once off the UI thread. Scrolling and chart selection never scan events.
private struct AnalyticsRange {
  let days: [String]
  let measured: [PromptUsageEvent]
  let agents: [(AgentSessionUsage, TokenBreakdown)]
  let steps: [StepRow]
  let agentPoints: [DayPoint]
  let stepPoints: [DayPoint]

  static func build(events: [PromptUsageEvent], agents: [AgentSessionUsage]) -> [Int: Self] {
    let byDay = Dictionary(grouping: events.filter { $0.runID != nil }, by: { TokenUsageDay.key($0.timestamp) })
    return Dictionary(uniqueKeysWithValues: [7, 14, 30].map { count in
      let days = TokenUsageDay.recent(count)
      let measured = days.flatMap { byDay[$0] ?? [] }
      let bySource = Dictionary(grouping: measured, by: \.source)
      let active = agents.compactMap { agent -> (AgentSessionUsage, TokenBreakdown)? in
        let total = days.reduce(TokenBreakdown()) { $0 + (agent.daily[$1] ?? TokenBreakdown()) }
        return total.total > 0 ? (agent, total) : nil
      }
      let steps = TokenStep.all.map { step in
        let summary = PromptUsageSummary(events: bySource[step.source] ?? [])
        return StepRow(step: step, runs: summary.reportedRuns, attempts: summary.runs,
                       actualTotal: summary.actualTokens, actualAverage: summary.actualAverage,
                       estimatedAverage: summary.estimatedAverage)
      }
      let agentPoints = days.flatMap { day in TokenKind.allCases.map { kind in
        DayPoint(day: day, series: kind.title,
                 tokens: active.reduce(0) { $0 + kind.value($1.0.daily[day] ?? TokenBreakdown()) })
      } }
      let stepPoints = days.flatMap { day in
        let totals = Dictionary(grouping: byDay[day] ?? [], by: \.source).mapValues {
          $0.compactMap(\.reportedTotalTokens).reduce(0, +)
        }
        return TokenStep.modelCalls.map { DayPoint(day: day, series: $0.title, tokens: totals[$0.source] ?? 0) }
      }
      return (count, Self(days: days, measured: measured, agents: active, steps: steps,
                          agentPoints: agentPoints, stepPoints: stepPoints))
    })
  }
}

private struct DayPoint: Identifiable {
  let day: String
  let series: String
  let tokens: Int
  var id: String { "\(day)|\(series)" }
}

private struct ContextSlice: Identifiable {
  let group: String
  let series: String
  let tokens: Int
  var id: String { "\(group)|\(series)" }
}

private struct StepRow: Identifiable {
  let step: TokenStep
  let runs: Int
  let attempts: Int
  let actualTotal: Int?
  let actualAverage: Int?
  let estimatedAverage: Int
  var id: String { step.source }
}

private enum TokenKind: CaseIterable {
  case cacheRead, cacheWrite, uncachedInput, output

  var title: String {
    switch self {
    case .cacheRead: "Cache read"
    case .cacheWrite: "Cache write"
    case .uncachedInput: "Uncached input"
    case .output: "Output"
    }
  }

  var color: Color {
    switch self {
    case .cacheRead: Palette.slot(0)
    case .cacheWrite: Palette.slot(1)
    case .uncachedInput: Palette.slot(2)
    case .output: Palette.slot(3)
    }
  }

  func value(_ usage: TokenBreakdown) -> Int {
    switch self {
    case .cacheRead: usage.cacheRead
    case .cacheWrite: usage.cacheWrite
    case .uncachedInput: usage.uncachedInput
    case .output: usage.output
    }
  }
}

private enum ContextPart {
  case focusQueue, instructionFiles, provider, output

  static let launchOrder: [ContextPart] = [.focusQueue, .instructionFiles, .provider]
  static let callOrder: [ContextPart] = [.focusQueue, .provider, .output]

  var title: String {
    switch self {
    case .focusQueue: "Focus Queue text"
    case .instructionFiles: "AGENTS.md / CLAUDE.md files"
    case .provider: "CLI system prompt, tools & other"
    case .output: "Model output"
    }
  }

  var color: Color {
    switch self {
    case .focusQueue: Palette.slot(0)
    case .instructionFiles: Palette.slot(2)
    case .provider: Palette.slot(1)
    case .output: Palette.slot(3)
    }
  }
}

private struct TokenStep {
  let source: String
  let title: String
  let detail: String
  let color: Color
  /// Shown instead of an actual total when the step's tokens live inside agent sessions.
  var actualNote = "—"

  static let all: [TokenStep] = [
    TokenStep(source: "agent_launch", title: "Agent launch prompt",
              detail: "Launch brief, plans, data, and instruction files an agent starts with. Counted inside agent session totals.",
              color: .secondary, actualNote: "in agent totals"),
    TokenStep(source: "agent_command", title: "Agent commands",
              detail: "Output of focus-queue-session commands an agent runs. Counted inside agent session totals.",
              color: .secondary, actualNote: "in agent totals"),
  ] + modelCalls

  static let modelCalls: [TokenStep] = [
    TokenStep(source: "placement", title: "Task placement",
              detail: "Matches a new request to an open task or proposes a new one.", color: Palette.slot(0)),
    TokenStep(source: "queue_chat", title: "Queue Chat",
              detail: "App instructions and queue state sent with each Queue Chat message.", color: Palette.slot(1)),
    TokenStep(source: "document_chat", title: "Document chat",
              detail: "Quoted documents, plan, and history sent with a document question.", color: Palette.slot(2)),
    TokenStep(source: "extraction", title: "data.md extraction",
              detail: "Reviews a prompt for durable facts to save.", color: Palette.slot(3)),
    TokenStep(source: "daily_report", title: "Daily report",
              detail: "Classifies dashboard state and source messages for the report.", color: Palette.slot(4)),
    TokenStep(source: "daily_report_deep_pass", title: "Daily report deep pass",
              detail: "Re-checks candidate tasks with their source material.", color: Palette.slot(5)),
    TokenStep(source: "completion_review", title: "Completion review",
              detail: "Past runs of the removed completion review.", color: Palette.slot(6)),
    TokenStep(source: "push_review", title: "Push review",
              detail: "Reads a diff before an agent pushes.", color: Palette.slot(7)),
  ]
}

/// The validated categorical palette, stepped separately for light and dark.
enum Palette {
  private static let light: [UInt32] = [0x2a78d6, 0xeb6834, 0x1baf7a, 0xeda100, 0xe87ba4, 0x008300, 0x6250d6, 0xe34948]
  private static let dark: [UInt32] = [0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181, 0x008300, 0x9085e9, 0xe66767]

  static func slot(_ index: Int) -> Color {
    let lightValue = light[index % light.count], darkValue = dark[index % dark.count]
    return Color(nsColor: NSColor(name: nil) { appearance in
      let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkValue : lightValue
      return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                     blue: CGFloat(value & 0xff) / 255, alpha: 1)
    })
  }
}
