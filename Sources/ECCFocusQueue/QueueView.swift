import AppKit
import FocusQueueCore
import Foundation
import SwiftUI

struct QueueView: View {
  let model: QueueViewModel
  @State private var showsMoreTasks = false
  @State private var showsPastCompletedTasks = false
  @State private var visiblePastCompletedCount = 0
  @State private var screen: QueueScreen = .queue
  @State private var selectedTab: QueueTab = .focus
  @State private var focusDropIsTargeted = false
  @State private var restButtonDropIsTargeted = false
  @State private var restSectionDropIsTargeted = false
  @State private var queueAgentDraft = ""

  private let completedPageSize = 12

  private var focusTickets: [DashboardTicket] { Array(model.openTickets.prefix(5)) }

  private var remainingTickets: [DashboardTicket] { Array(model.openTickets.dropFirst(5)) }

  private var visiblePastCompletedTickets: [DashboardTicket] {
    Array(model.pastCompletedTickets.prefix(visiblePastCompletedCount))
  }

  var body: some View {
    HStack(spacing: 12) {
      if model.isDailyReportPresented, model.windowPlacement == .upperRight {
        DailyReportView(model: model)
        Divider()
      }
      queuePane
        .frame(
          minWidth: 380,
          idealWidth: 440,
          maxWidth: model.isDailyReportPresented ? 440 : .infinity
        )
      if model.isDailyReportPresented, model.windowPlacement != .upperRight {
        Divider()
        DailyReportView(model: model)
      }
    }
    .padding(12).frame(minWidth: 380, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
      .panelSurface(radius: 30).preferredColorScheme(
        model.appearance == .dark ? .dark : .light
      ).environment(\.queueAccentStyle, model.accentStyle).tint(
        QueueAccentPalette.color(.info, style: model.accentStyle)
      )
      .onChange(of: model.requestedReportTaskID) { _, taskID in
        guard let taskID else { return }
        screen = .queue
        if model.dashboard.tickets.first(where: { $0.id == taskID })?.isCompleted == true {
          selectedTab = .completed
          showsPastCompletedTasks = true
          visiblePastCompletedCount = max(visiblePastCompletedCount, completedPageSize)
        } else {
          selectedTab = .focus
          if model.openTickets.dropFirst(5).contains(where: { $0.id == taskID }) {
            showsMoreTasks = true
          }
        }
        model.clearRequestedReportTask()
      }
  }

  @ViewBuilder private var queuePane: some View {
    Group {
      if model.isPanelCollapsed {
        compactHeader
      } else if screen == .settings {
        QueueSettingsView(model: model) {
          withAnimation(.easeInOut(duration: 0.18)) { screen = .queue }
        }
      } else {
        queueContent
      }
    }
  }

  private var queueContent: some View {
    VStack(spacing: 10) {
      header
      if model.pendingDailyReportApproval != nil {
        missedReportApprovalBanner
      }
      queueTabs
      switch selectedTab {
      case .focus:
        activeQueueContent
      case .completed:
        completedQueueContent
      case .agent:
        QueueAgentChatView(model: model, draft: $queueAgentDraft)
      }
    }
  }

  private var activeQueueContent: some View {
    VStack(spacing: 10) {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          todayFocusSection

          if showsMoreTasks {
            additionalQueue.transition(.opacity.combined(with: .move(edge: .bottom)))
          }
        }.padding(.horizontal, 2).padding(.vertical, 2)
      }.scrollIndicators(.automatic)

      if !remainingTickets.isEmpty || !model.config.dailyRoutines.isEmpty { moreButton }
    }
  }

  private var todayFocusSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeading(
        title: focusDropIsTargeted ? "Drop to Today's focus" : "Today's focus",
        detail: "Top \(focusTickets.count)"
      )

      if focusTickets.isEmpty {
        ContentUnavailableView(
          "Queue is clear", systemImage: "checkmark.circle",
          description: Text("No open tasks are present in the dashboard.")
        ).frame(maxWidth: .infinity).notificationSurface(radius: 18)
      } else {
        ForEach(focusTickets) { ticket in TicketCard(ticket: ticket, model: model) }
      }
    }
    .dropDestination(for: String.self) { ticketIDs, _ in
      moveTicketsToToday(ticketIDs)
    } isTargeted: {
      focusDropIsTargeted = $0
    }
    .overlay {
      if focusDropIsTargeted {
        RoundedRectangle(cornerRadius: 20)
          .stroke(.tint, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
          .allowsHitTesting(false)
      }
    }
  }

  private var completedQueueContent: some View {
    VStack(spacing: 10) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          SectionHeading(
            title: "Completed today",
            detail: "\(model.completedTodayTickets.count)"
          )

          if model.completedTodayTickets.isEmpty {
            ContentUnavailableView(
              "Nothing completed today",
              systemImage: "checkmark.circle",
              description: Text("Resolved and cancelled dashboard tasks will appear here.")
            ).frame(maxWidth: .infinity).notificationSurface(radius: 18)
          } else {
            ForEach(model.completedTodayTickets) { ticket in
              CompletedTicketCard(ticket: ticket, open: model.open)
            }
          }

          if showsPastCompletedTasks {
            SectionHeading(
              title: "Earlier completions",
              detail: "\(model.pastCompletedTickets.count)"
            ).padding(.top, 4)

            ForEach(visiblePastCompletedTickets) { ticket in
              CompletedTicketCard(ticket: ticket, open: model.open)
            }

            if visiblePastCompletedCount < model.pastCompletedTickets.count {
              HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Loading more completed tasks…").foregroundStyle(.secondary)
              }.font(.system(size: 12)).frame(maxWidth: .infinity).padding(.vertical, 10)
                .onAppear { loadNextCompletedPage() }
            }
          }
        }.padding(.horizontal, 2).padding(.vertical, 2)
      }.scrollIndicators(.automatic)

      if !model.pastCompletedTickets.isEmpty { completedMoreButton }
    }
  }

  private var queueTabs: some View {
    Picker("Queue section", selection: $selectedTab) {
      Text("Focus \(model.openTickets.count)").tag(QueueTab.focus)
      Text("Completed \(model.completedTodayTickets.count)").tag(QueueTab.completed)
      Text("Queue chat").tag(QueueTab.agent)
    }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Queue section")
  }

  private var compactHeader: some View {
    HStack(spacing: 10) {
      Text("ECC Focus Queue").font(.system(size: 19, weight: .bold, design: .rounded))
      Spacer()
      monitorButton
      Button {
        model.setPanelCollapsed(false)
      } label: {
        Image(systemName: "rectangle.expand.vertical").font(.system(size: 13, weight: .semibold))
      }.buttonStyle(.plain).frame(width: 40, height: 40).accessibilityLabel(
        "Expand ECC Focus Queue"
      ).help("Expand queue")
    }.padding(.horizontal, 15).frame(height: 58).notificationSurface(radius: 18)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 7) {
        Circle().fill(
          QueueAccentPalette.color(
            model.loadError == nil ? .success : .warning, style: model.accentStyle)
        ).frame(width: 7, height: 7)
        syncLabel
        Spacer()
        monitorButton
        Button {
          if model.dailyReport == nil {
            Task { await model.reloadDailyReport() }
          }
          model.toggleDailyReport()
        } label: {
          Image(systemName: model.isDailyReportPresented ? "doc.text.fill" : "doc.text")
            .font(.system(size: 13, weight: .semibold))
        }.buttonStyle(.plain).minimumHitTarget(width: 46, height: 46).accessibilityLabel(
          model.isDailyReportPresented ? "Close daily report" : "Open daily report"
        ).help("Daily message report")
        Button {
          withAnimation(.easeInOut(duration: 0.18)) { screen = .settings }
        } label: {
          Image(systemName: "gearshape.fill").font(.system(size: 13, weight: .semibold))
        }.buttonStyle(.plain).frame(width: 40, height: 40).accessibilityLabel(
          "Open ECC Focus Queue settings"
        ).help("Settings")
        Button {
          Task { await model.refresh(forceRecurringPRProgress: true) }
        } label: {
          Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
        }.buttonStyle(.plain).frame(width: 40, height: 40).disabled(model.isRefreshing)
          .accessibilityLabel("Refresh task dashboard").help("Refresh now")
        Button {
          model.setPanelCollapsed(true)
        } label: {
          Image(systemName: "rectangle.compress.vertical").font(
            .system(size: 13, weight: .semibold))
        }.buttonStyle(.plain).frame(width: 40, height: 40).accessibilityLabel(
          "Collapse ECC Focus Queue to its title"
        ).help("Collapse queue")
      }
      HStack(alignment: .firstTextBaseline) {
        Text("ECC Focus Queue").font(.system(size: 21, weight: .bold, design: .rounded))
        Spacer()
        Text(headerCountLabel).font(
          .system(size: 12, weight: .semibold).monospacedDigit()
        ).foregroundStyle(.secondary)
      }
      if let error = model.loadError {
        Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12))
          .foregroundStyle(.orange).lineLimit(2)
      }
    }.padding(.horizontal, 15).padding(.vertical, 11).notificationSurface(radius: 18)
  }

  private var missedReportApprovalBanner: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("Today’s report was missed", systemImage: "clock.badge.exclamationmark")
        .font(.system(size: 13, weight: .bold))
      Text("The scheduled time passed while this computer was unavailable. Run it now?")
        .font(.system(size: 12)).foregroundStyle(.secondary)
      HStack {
        Button("Run report") { model.respondToDailyReportApproval(run: true) }
          .buttonStyle(.borderedProminent)
        Button("Not today") { model.respondToDailyReportApproval(run: false) }
          .buttonStyle(.bordered)
      }
    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .notificationSurface(radius: 18)
  }

  @ViewBuilder private var syncLabel: some View {
    if let lastSync = model.lastSync {
      Text("Synced \(lastSync.formatted(date: .omitted, time: .shortened))")
    } else if model.isRefreshing {
      Text("Waiting for Documents access")
    } else {
      Text("Waiting for dashboard")
    }
  }

  private var additionalQueue: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !model.config.dailyRoutines.isEmpty {
        SectionHeading(
          title: "Daily checklist",
          detail: "\(model.completedRoutineCount)/\(model.config.dailyRoutines.count)")
        VStack(spacing: 1) {
          ForEach(model.config.dailyRoutines) { routine in
            RoutineRow(
              routine: routine, isComplete: model.routineIsComplete(routine.id),
              toggle: { model.toggleRoutine(routine.id) },
              open: { if let url = routine.url { model.open(url) } })
          }
        }.notificationSurface(radius: 16)
      }

      if !remainingTickets.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          SectionHeading(
            title: restSectionDropIsTargeted ? "Drop to Rest of queue" : "Rest of queue",
            detail: "\(remainingTickets.count)"
          )
          ForEach(remainingTickets) { ticket in TicketCard(ticket: ticket, model: model) }
        }
        .dropDestination(for: String.self) { ticketIDs, _ in
          moveTicketsToRest(ticketIDs)
        } isTargeted: {
          restSectionDropIsTargeted = $0
        }
        .overlay {
          if restSectionDropIsTargeted {
            RoundedRectangle(cornerRadius: 20)
              .stroke(.tint, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
              .allowsHitTesting(false)
          }
        }
      }
    }
  }

  private var moreButton: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.22)) { showsMoreTasks.toggle() }
    } label: {
      HStack(spacing: 9) {
        Image(systemName: showsMoreTasks ? "chevron.up" : "chevron.down").font(
          .system(size: 12, weight: .bold))
        Text(
          restButtonDropIsTargeted
            ? (showsMoreTasks ? "Drop to Today's focus" : "Drop to Rest of queue")
            : (showsMoreTasks ? "Show only top five" : moreButtonLabel)
        ).font(
          .system(size: 14, weight: .semibold))
        Spacer()
        Text(showsMoreTasks ? "" : "\(remainingTickets.count) more").font(
          .system(size: 12, weight: .semibold).monospacedDigit()
        ).foregroundStyle(
          .secondary)
      }.padding(.horizontal, 15).frame(height: 52).contentShape(Rectangle())
    }.buttonStyle(.plain).notificationSurface(radius: 16)
      .dropDestination(for: String.self) { ticketIDs, _ in
        showsMoreTasks ? moveTicketsToToday(ticketIDs) : moveTicketsToRest(ticketIDs)
      } isTargeted: {
        restButtonDropIsTargeted = $0
      }
      .overlay {
        if restButtonDropIsTargeted {
          RoundedRectangle(cornerRadius: 16)
            .stroke(.tint, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .allowsHitTesting(false)
        }
      }
      .accessibilityLabel(
      showsMoreTasks ? "Show only top five tasks" : "View more tasks")
  }

  private var moreButtonLabel: String {
    remainingTickets.isEmpty ? "View daily checklist" : "View more tasks"
  }

  private var completedMoreButton: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.22)) {
        showsPastCompletedTasks.toggle()
        visiblePastCompletedCount = showsPastCompletedTasks
          ? min(completedPageSize, model.pastCompletedTickets.count)
          : 0
      }
    } label: {
      HStack(spacing: 9) {
        Image(systemName: showsPastCompletedTasks ? "chevron.up" : "clock.arrow.circlepath")
          .font(.system(size: 12, weight: .bold))
        Text(showsPastCompletedTasks ? "Show today only" : "View past completed")
          .font(.system(size: 14, weight: .semibold))
        Spacer()
        if !showsPastCompletedTasks {
          Text("\(model.pastCompletedTickets.count) past")
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }.padding(.horizontal, 15).frame(height: 52).contentShape(Rectangle())
    }.buttonStyle(.plain).notificationSurface(radius: 16).accessibilityLabel(
      showsPastCompletedTasks ? "Show only tasks completed today" : "View past completed tasks"
    )
  }

  private var headerCountLabel: String {
    switch selectedTab {
    case .focus: "\(model.openTickets.count) active"
    case .completed: "\(model.completedTodayTickets.count) today"
    case .agent: model.isQueueAgentResponding ? "Codex working" : "Codex ready"
    }
  }

  private func loadNextCompletedPage() {
    guard showsPastCompletedTasks else { return }
    visiblePastCompletedCount = min(
      visiblePastCompletedCount + completedPageSize,
      model.pastCompletedTickets.count
    )
  }

  private func moveTicketsToRest(_ ticketIDs: [String]) -> Bool {
    var handled = false
    for ticketID in ticketIDs {
      handled = model.moveTicketToRest(ticketID) || handled
    }
    if handled {
      withAnimation(.easeInOut(duration: 0.22)) { showsMoreTasks = true }
    }
    return handled
  }

  private func moveTicketsToToday(_ ticketIDs: [String]) -> Bool {
    var handled = false
    for ticketID in ticketIDs {
      handled = model.moveTicketToToday(ticketID) || handled
    }
    return handled
  }

  private var monitorButton: some View {
    Button {
      model.switchMonitor()
    } label: {
      Image(systemName: "display.2").font(.system(size: 13, weight: .semibold))
    }.buttonStyle(.plain).frame(width: 40, height: 40).disabled(!model.canSwitchMonitor)
      .accessibilityLabel("Move ECC Focus Queue to the next display")
      .help(monitorButtonHelp)
  }

  private var monitorButtonHelp: String {
    model.canSwitchMonitor
      ? "Move queue to next display" : "Connect another display to move the queue"
  }
}

private enum QueueScreen {
  case queue
  case settings
}

private enum QueueTab: Hashable {
  case focus
  case completed
  case agent
}

private struct QueueAgentChatView: View {
  let model: QueueViewModel
  @Binding var draft: String
  @FocusState private var composerIsFocused: Bool

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 10) {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 9) {
              ForEach(model.queueChatMessages) { message in
                messageRow(message).id(message.id)
              }
              if model.isQueueAgentResponding {
                HStack(spacing: 9) {
                  ProgressView().controlSize(.small)
                  Text("Codex is checking the queue…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                  Spacer()
                }
                .padding(.horizontal, 13).padding(.vertical, 11)
                .notificationSurface(radius: 16)
                .id("queue-agent-progress")
              }
            }
            .padding(.horizontal, 2).padding(.vertical, 2)
          }
          .scrollIndicators(.automatic)
          .onChange(of: model.queueChatMessages.count) { _, _ in
            scrollToBottom(using: proxy)
          }
          .onChange(of: model.isQueueAgentResponding) { _, _ in
            scrollToBottom(using: proxy)
          }
        }

        HStack(alignment: .bottom, spacing: 8) {
          TextField(
            "Ask about order or request a task change",
            text: $draft,
            axis: .vertical
          )
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .lineLimit(1...100)
          .frame(
            height: composerHeight(
              availableWidth: geometry.size.width,
              availableHeight: geometry.size.height
            ),
            alignment: .topLeading
          )
          .padding(.horizontal, 13).padding(.vertical, 11)
          .notificationSurface(radius: 16)
          .overlay {
            RoundedRectangle(cornerRadius: 16)
              .stroke(
                composerIsFocused ? Color.accentColor.opacity(0.8) : Color.clear,
                lineWidth: 1.5
              )
              .allowsHitTesting(false)
          }
          .focused($composerIsFocused)
          .onSubmit(send)
          .accessibilityLabel("Message the Codex Queue agent")

          Button(action: send) {
            Image(systemName: "arrow.up.circle.fill")
              .font(.system(size: 24, weight: .semibold))
              .frame(width: 42, height: 42)
          }
          .buttonStyle(.plain)
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.isQueueAgentResponding)
          .accessibilityLabel("Send message to Codex Queue agent")
        }
      }
    }
    .task { focusComposer() }
    .onChange(of: model.isQueueAgentResponding) { _, isResponding in
      if !isResponding { focusComposer() }
    }
  }

  @ViewBuilder
  private func messageRow(_ message: QueueChatMessage) -> some View {
    HStack {
      if message.role == .user { Spacer(minLength: 40) }
      Text(message.text)
        .font(.system(size: 13))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 13).padding(.vertical, 10)
        .background(message.role == .user ? Color.accentColor.opacity(0.16) : Color.clear)
        .notificationSurface(radius: 16)
      if message.role == .agent { Spacer(minLength: 40) }
    }.accessibilityElement(children: .combine)
  }

  private func send() {
    let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, !model.isQueueAgentResponding else { return }
    draft = ""
    model.sendQueueAgentMessage(message)
  }

  private func composerHeight(availableWidth: CGFloat, availableHeight: CGFloat) -> CGFloat {
    let textWidth = max(80, availableWidth - 76)
    let content = draft.isEmpty ? " " : draft
    let bounds = (content as NSString).boundingRect(
      with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: NSFont.systemFont(ofSize: 13)]
    )
    let contentHeight = ceil(bounds.height) + 22
    let maximumHeight = max(120, availableHeight * 0.7)
    return min(max(42, contentHeight), maximumHeight)
  }

  private func focusComposer() {
    Task { @MainActor in
      await Task.yield()
      composerIsFocused = true
    }
  }

  private func scrollToBottom(using proxy: ScrollViewProxy) {
    Task { @MainActor in
      await Task.yield()
      if model.isQueueAgentResponding {
        proxy.scrollTo("queue-agent-progress", anchor: .bottom)
      } else if let last = model.queueChatMessages.last {
        proxy.scrollTo(last.id, anchor: .bottom)
      }
    }
  }
}

private struct DailyReportView: View {
  let model: QueueViewModel

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Daily message report")
            .font(.system(size: 21, weight: .bold, design: .rounded))
          if let report = model.dailyReport {
            Text(reportTimestamp(report.finishedAt))
              .font(.system(size: 12)).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button {
          Task { await model.reloadDailyReport() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }.buttonStyle(.plain).minimumHitTarget(width: 46, height: 46)
          .disabled(model.isDailyReportRunning).accessibilityLabel("Reload daily report")
        Button {
          model.setDailyReportPresented(false)
        } label: {
          Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
        }.buttonStyle(.plain).minimumHitTarget(width: 46, height: 46)
          .accessibilityLabel("Close daily report")
      }.padding(.horizontal, 14).padding(.vertical, 10).notificationSurface(radius: 18)

      if model.isDailyReportRunning {
        HStack(spacing: 9) {
          ProgressView().controlSize(.small)
          Text("Checking new messages and creating linked tasks…")
            .font(.system(size: 12, weight: .medium))
          Spacer()
        }.padding(13).notificationSurface(radius: 16)
      } else if let message = model.dailyReportRunMessage {
        Label(message, systemImage: model.dailyReportLoadError == nil ? "info.circle" : "exclamationmark.triangle")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(model.dailyReportLoadError == nil ? Color.secondary : Color.orange)
          .padding(13).frame(maxWidth: .infinity, alignment: .leading)
          .notificationSurface(radius: 16)
      }

      ScrollView {
        if let report = model.dailyReport {
          VStack(alignment: .leading, spacing: 12) {
            summaryCard(report)
            ForEach(report.platforms) { platform in
              platformCard(platform)
            }
            if !report.errors.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                Label("Incomplete coverage", systemImage: "exclamationmark.triangle.fill")
                  .font(.system(size: 13, weight: .bold)).foregroundStyle(.orange)
                ForEach(report.errors, id: \.self) { error in
                  Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                }
              }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .notificationSurface(radius: 18)
            }
          }.padding(.horizontal, 2).padding(.vertical, 2)
        } else if let error = model.dailyReportLoadError {
          ContentUnavailableView(
            "Report unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text(error)
          ).frame(maxWidth: .infinity).notificationSurface(radius: 18)
        } else {
          ContentUnavailableView(
            "No daily report yet",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Run a comprehensive report or wait for the next scheduled time.")
          ).frame(maxWidth: .infinity).notificationSurface(radius: 18)
        }
      }.scrollIndicators(.automatic)

      Button("Run comprehensive report", systemImage: "arrow.triangle.2.circlepath") {
        model.runComprehensiveDailyReport()
      }.buttonStyle(.borderedProminent).disabled(model.isDailyReportRunning)
    }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
  }

  private func summaryCard(_ report: DailyReportDocument) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(report.status.rawValue.capitalized, systemImage: statusIcon(report.status))
          .font(.system(size: 12, weight: .bold))
        Spacer()
        Text(report.mode == .recheck ? "Recheck" : "Unseen only")
          .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
      }
      Text(report.summary).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 18) {
        reportMetric(
          title: "New",
          value: report.platforms.reduce(0) { $0 + $1.newCount }.formatted()
        )
        reportMetric(
          title: "Checked",
          value: report.platforms.reduce(0) { $0 + $1.checkedCount }.formatted()
        )
        reportMetric(title: "Tokens", value: report.usage?.totalTokens.formatted() ?? "Unknown")
        reportMetric(title: "Target", value: report.tokenBudget.formatted())
      }
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .notificationSurface(radius: 18)
  }

  private func reportMetric(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.system(size: 15, weight: .bold).monospacedDigit())
      Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.5)
        .foregroundStyle(.secondary)
    }
  }

  private func platformCard(_ platform: DailyReportPlatformSection) -> some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 9) {
        if platform.messages.isEmpty {
          Text("No new messages required review.")
            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 4)
        } else {
          ForEach(platform.messages) { message in
            messageDisclosure(message)
          }
        }
        if platform.alreadyProcessedCount > 0 || platform.deferredCount > 0 {
          Text(
            "\(platform.alreadyProcessedCount) previously checked · \(platform.deferredCount) deferred"
          ).font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }.padding(.top, 10)
    } label: {
      HStack {
        Text(platform.platform.displayName).font(.system(size: 14, weight: .bold))
        Text(platform.status.uppercased()).font(.system(size: 9, weight: .bold))
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(platform.newCount) new · \(platform.checkedCount) checked")
          .font(.system(size: 11, weight: .semibold).monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }.padding(14).notificationSurface(radius: 18)
  }

  private func messageDisclosure(_ message: DailyReportMessage) -> some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 8) {
        Text(message.summary).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        if let reason = message.unavailableReason {
          Label(reason, systemImage: "link.badge.plus")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        HStack(spacing: 10) {
          if let url = message.url {
            Button("Open message", systemImage: "arrow.up.right.square") {
              model.open(url)
            }.buttonStyle(.link)
          }
          ForEach(message.tasks) { task in
            Button(task.id, systemImage: "checklist") {
              model.revealReportTask(task.id)
            }.buttonStyle(.link).help(task.title)
          }
        }
      }.padding(.top, 8)
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        Text(message.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
        if let timestamp = message.timestamp {
          Text(reportTimestamp(timestamp)).font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
    }.padding(10).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
  }

  private func statusIcon(_ status: DailyReportStatus) -> String {
    switch status {
    case .success: "checkmark.circle.fill"
    case .partial: "exclamationmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .skipped: "minus.circle.fill"
    }
  }

  private func reportTimestamp(_ value: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    return date?.formatted(date: .abbreviated, time: .shortened) ?? value
  }
}

private struct QueueSettingsView: View {
  let model: QueueViewModel
  let close: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        Button(action: close) {
          Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
        }.buttonStyle(.plain).frame(width: 40, height: 40).accessibilityLabel(
          "Back to ECC Focus Queue")
        Text("Settings").font(.system(size: 21, weight: .bold, design: .rounded))
        Spacer()
        Text("ECC Focus Queue").font(.system(size: 12, weight: .semibold)).foregroundStyle(
          .secondary)
      }.padding(.horizontal, 14).padding(.vertical, 10).notificationSurface(radius: 18)

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          settingsSection(
            title: "Appearance", detail: "Dark uses your WezTerm #1A1D23 background color."
          ) {
            Picker("Appearance", selection: appearanceBinding) {
              Label("Light", systemImage: "sun.max.fill").tag(QueueAppearance.light)
              Label("Dark", systemImage: "moon.stars.fill").tag(QueueAppearance.dark)
            }.pickerStyle(.segmented).labelsHidden()
          }

          settingsSection(
            title: "Accent colors", detail: "Changes status, priority, sync, and review colors."
          ) {
            Picker("Accent colors", selection: accentStyleBinding) {
              ForEach(QueueAccentStyle.allCases) { style in
                Text(style.displayName).tag(style)
              }
            }.pickerStyle(.segmented).labelsHidden()
          }

          settingsSection(
            title: "Screen location",
            detail: "Choose the queue's horizontal position or move it to the next display."
          ) {
            VStack(alignment: .leading, spacing: 10) {
              Picker("Screen location", selection: placementBinding) {
                Text("Left").tag(QueueWindowPlacement.upperLeft)
                Text("Center").tag(QueueWindowPlacement.center)
                Text("Right").tag(QueueWindowPlacement.upperRight)
              }.pickerStyle(.segmented).labelsHidden()

              Button("Move queue to next display", systemImage: "display.2") {
                model.switchMonitor()
              }.buttonStyle(.bordered).disabled(!model.canSwitchMonitor)
                .help(
                  model.canSwitchMonitor
                    ? "Move queue to next display"
                    : "Connect another display to move the queue"
                )
            }
          }

          settingsSection(
            title: "Daily message report",
            detail:
              "Runs once per day. The target limits message input conservatively, while the report records exact Codex usage."
          ) {
            VStack(alignment: .leading, spacing: 12) {
              DatePicker(
                "Run time",
                selection: dailyReportTimeBinding,
                displayedComponents: .hourAndMinute
              )

              Stepper(
                value: dailyReportTokenBinding,
                in: 10_000...1_000_000,
                step: 5_000
              ) {
                HStack {
                  Text("Token consumption target")
                  Spacer()
                  Text(model.config.dailyReport.maximumTokens.formatted())
                    .monospacedDigit().foregroundStyle(.secondary)
                }
              }

              VStack(alignment: .leading, spacing: 7) {
                Text("Platforms").font(.system(size: 12, weight: .semibold))
                  .foregroundStyle(.secondary)
                ForEach(DailyReportPlatform.allCases) { platform in
                  Toggle(
                    platform.displayName,
                    isOn: Binding(
                      get: { model.config.dailyReport.enabledPlatforms.contains(platform) },
                      set: { model.setDailyReportPlatform(platform, enabled: $0) }
                    )
                  )
                }
              }

              Button("Run comprehensive report", systemImage: "arrow.triangle.2.circlepath") {
                model.runComprehensiveDailyReport()
              }.buttonStyle(.borderedProminent).disabled(model.isDailyReportRunning)

              if model.isDailyReportRunning {
                HStack(spacing: 8) {
                  ProgressView().controlSize(.small)
                  Text("Checking enabled platforms…")
                }.font(.system(size: 12)).foregroundStyle(.secondary)
              } else if let message = model.dailyReportRunMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
              }
            }
          }

          settingsSection(
            title: "Management",
            detail: "The Desktop launcher and menu-bar checklist remain available."
          ) {
            Button("Open advanced configuration", systemImage: "doc.badge.gearshape") {
              model.openConfiguration()
            }.buttonStyle(.bordered)
          }
        }.padding(.horizontal, 2).padding(.vertical, 2)
      }.scrollIndicators(.automatic)

      Spacer(minLength: 0)
    }
  }

  private var appearanceBinding: Binding<QueueAppearance> {
    Binding(get: { model.appearance }, set: { model.setAppearance($0) })
  }

  private var placementBinding: Binding<QueueWindowPlacement> {
    Binding(get: { model.windowPlacement }, set: { model.placeWindow($0) })
  }

  private var accentStyleBinding: Binding<QueueAccentStyle> {
    Binding(get: { model.accentStyle }, set: { model.setAccentStyle($0) })
  }

  private var dailyReportTimeBinding: Binding<Date> {
    Binding(
      get: {
        Calendar.current.date(
          bySettingHour: model.config.dailyReport.scheduleHour,
          minute: model.config.dailyReport.scheduleMinute,
          second: 0,
          of: Date()
        ) ?? Date()
      },
      set: { date in
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        model.setDailyReportSchedule(
          hour: components.hour ?? 8,
          minute: components.minute ?? 0
        )
      }
    )
  }

  private var dailyReportTokenBinding: Binding<Int> {
    Binding(
      get: { model.config.dailyReport.maximumTokens },
      set: { model.setDailyReportMaximumTokens($0) }
    )
  }

  private func settingsSection<Content: View>(
    title: String, detail: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      Text(title).font(.system(size: 16, weight: .bold))
      Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
      content()
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).notificationSurface(radius: 18)
  }
}

private struct SectionHeading: View {
  let title: String
  let detail: String
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack {
      Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.7)
      Spacer()
      Text(detail).font(.system(size: 11, weight: .semibold).monospacedDigit())
    }.foregroundStyle(.secondary).padding(.horizontal, 11).frame(height: 27).background(
      QueuePalette.component(for: colorScheme), in: Capsule()
    ).overlay {
      Capsule().stroke(QueuePalette.componentBorder(for: colorScheme), lineWidth: 0.6)
    }
  }
}

private struct RoutineRow: View {
  let routine: DailyRoutine
  let isComplete: Bool
  let toggle: () -> Void
  let open: () -> Void
  @Environment(\.queueAccentStyle) private var accentStyle

  var body: some View {
    HStack(spacing: 9) {
      Button(action: toggle) {
        Image(systemName: isComplete ? "checkmark.circle.fill" : "circle").foregroundStyle(
          isComplete ? QueueAccentPalette.color(.success, style: accentStyle) : Color.secondary
        ).font(
          .system(size: 18))
      }.buttonStyle(.plain).frame(minWidth: 36, minHeight: 36).accessibilityLabel(
        isComplete ? "Mark \(routine.title) incomplete" : "Mark \(routine.title) complete"
      ).accessibilityHint("This daily state stays on this computer and resets tomorrow.").help(
        isComplete ? "Mark incomplete" : "Mark complete for today")

      Text(routine.title).font(.system(size: 15, weight: .medium)).strikethrough(
        isComplete, color: .secondary
      ).foregroundStyle(
        isComplete ? .secondary : .primary
      ).frame(maxWidth: .infinity, alignment: .leading)

      if routine.url != nil {
        Button(action: open) { Image(systemName: "arrow.up.right.square").font(.caption) }
          .buttonStyle(.borderless).frame(minWidth: 36, minHeight: 36)
          .accessibilityLabel("Open \(routine.title)").help("Open queue")
      }
    }.padding(.horizontal, 12).padding(.vertical, 5)
  }
}

private struct CompletedTicketCard: View {
  let ticket: DashboardTicket
  let open: (String) -> Void

  @Environment(\.queueAccentStyle) private var accentStyle

  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: statusIcon)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(statusColor)
        .frame(width: 28, height: 30)
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .top, spacing: 8) {
          Text(ticket.title).font(.system(size: 15, weight: .semibold)).lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(ticket.id).font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary).fixedSize()
        }
        if !ticket.summary.isEmpty {
          Text(ticket.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
        }
        HStack(spacing: 7) {
          StatusPill(text: ticket.status, color: statusColor)
          Text(ticket.completionDay ?? "Date unavailable")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
          Spacer()
          if let destination = ticket.links.first?.url ?? ticket.prs.first?.url {
            Button {
              open(destination)
            } label: {
              Image(systemName: "arrow.up.right.square")
            }.buttonStyle(.borderless).accessibilityLabel("Open completion evidence for \(ticket.id)")
          }
        }
      }
    }.padding(.horizontal, 13).padding(.vertical, 11).notificationSurface(radius: 18)
      .accessibilityElement(children: .contain)
  }

  private var statusColor: Color {
    ticket.status.lowercased() == "cancelled"
      ? .secondary
      : QueueAccentPalette.color(.success, style: accentStyle)
  }

  private var statusIcon: String {
    ticket.status.lowercased() == "cancelled" ? "xmark.circle.fill" : "checkmark.circle.fill"
  }
}

private struct TicketCard: View {
  let ticket: DashboardTicket
  let model: QueueViewModel
  @State private var showsAgentPicker = false
  @Environment(\.queueAccentStyle) private var accentStyle

  private var review: CompletionRequest? { model.latestReview(for: ticket.id) }
  private var isChecked: Bool { model.ticketIsChecked(ticket) }
  private var recurringProgress: RecurringPullRequestProgress? {
    model.recurringPRProgress(for: ticket.id)
  }
  private var recurringProgressError: String? {
    model.recurringPRProgressError(for: ticket.id)
  }
  private var agentSessions: [TaskAgentSession] { model.agentSessions(for: ticket.id) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      summary
      agentControls
      if showsAgentPicker {
        AgentSessionPicker(
          ticket: ticket,
          model: model,
          onClose: { showsAgentPicker = false }
        )
        .padding(.horizontal, 14).padding(.bottom, 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
      if model.isExpanded(ticket.id) {
        Divider().opacity(0.45).padding(.horizontal, 14)
        details.padding(.top, 11).transition(.opacity.combined(with: .move(edge: .top)))
      }
    }.notificationSurface(radius: 18)
      .draggable(ticket.id)
      .accessibilityHint("Drag this task between Today's focus and Rest of queue.")
  }

  private var summary: some View {
    HStack(alignment: .top, spacing: 11) {
      VStack(spacing: 1) {
        Button {
          if !isChecked { model.requestCompletion(for: ticket) }
        } label: {
          Image(systemName: isChecked ? "checkmark.circle.fill" : "circle").font(
            .system(size: 20, weight: .medium)
          ).foregroundStyle(checkColor)
        }.buttonStyle(.plain).disabled(review?.status == .running).frame(width: 40, height: 36)
          .accessibilityLabel(
            "Request completion review for \(ticket.id)"
          ).accessibilityHint("Queues Codex evidence review without directly closing the task.")
          .help("Queue an evidence-based Codex completion review")

        Button {
          toggleExpansion()
        } label: {
          Image(systemName: model.isExpanded(ticket.id) ? "chevron.up" : "chevron.down").font(
            .system(size: 12, weight: .bold)
          ).foregroundStyle(
            .secondary
          ).frame(width: 44, height: 40).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(
          model.isExpanded(ticket.id)
            ? "Hide details for \(ticket.id)" : "Show details for \(ticket.id)")
      }

      Button(action: toggleExpansion) {
        VStack(alignment: .leading, spacing: 7) {
          HStack(alignment: .top, spacing: 10) {
            Text(ticket.title).font(.system(size: 16, weight: .semibold)).lineLimit(3).frame(
              maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
              Text(summaryProgressLabel).font(
                .system(size: 12, weight: .semibold).monospacedDigit()
              ).foregroundStyle(.secondary).fixedSize()
              Text(ticket.id).font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(priorityColor).fixedSize()
            }
          }
          HStack(spacing: 6) {
            if recurringProgress?.openCount == 0 {
              StatusPill(text: "No open PRs", color: .secondary)
            } else {
              StatusPill(text: ticket.priority, color: priorityColor)
            }
            StatusPill(text: ticket.status, color: statusColor)
            if ticket.isRecurringPullRequestTask {
              StatusPill(
                text: "Recurring daily",
                color: QueueAccentPalette.color(.info, style: accentStyle)
              )
            }
            if let review { ReviewPill(status: review.status) }
          }
          if ticket.isRecurringPullRequestTask {
            RecurringPRProgressSummary(
              progress: recurringProgress,
              error: recurringProgressError
            )
          }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel(
        "\(ticket.title), \(summaryProgressLabel), \(ticket.id)"
      ).accessibilityHint(
        model.isExpanded(ticket.id) ? "Hides task details." : "Shows task details."
      ).help(model.isExpanded(ticket.id) ? "Hide task details" : "Show task details")
    }.padding(.horizontal, 13).padding(.vertical, 11)
  }

  private func toggleExpansion() {
    withAnimation(.easeInOut(duration: 0.18)) {
      model.setExpanded(!model.isExpanded(ticket.id), ticketID: ticket.id)
    }
  }

  private var agentControls: some View {
    HStack(spacing: 7) {
      if agentSessions.count > 1 {
        Menu {
          ForEach(agentSessions) { session in
            Button("\(session.tabTitle) · \(session.sessionID)") {
              model.viewAgent(session, for: ticket)
            }
          }
        } label: {
          Label("View Agent", systemImage: "terminal")
        }
        .menuStyle(.button)
        .accessibilityLabel("Choose an agent for \(ticket.id)")
        .accessibilityHint("Lists attached sessions by terminal tab name and session ID.")
        .accessibilityIdentifier("view-agent-\(ticket.id)")
      } else {
        Button("View Agent", systemImage: "terminal") {
          guard let session = agentSessions.first else { return }
          model.viewAgent(session, for: ticket)
        }
        .buttonStyle(.bordered)
        .disabled(agentSessions.isEmpty)
        .accessibilityLabel("View agent for \(ticket.id)")
        .accessibilityHint(
          agentSessions.isEmpty
            ? "Attach an agent before viewing it."
            : "Focuses the agent terminal, or resumes the saved conversation if it is not running."
        )
        .accessibilityIdentifier("view-agent-\(ticket.id)")
      }

      Button("Attach Agent", systemImage: "person.crop.circle.badge.plus") {
        withAnimation(.easeInOut(duration: 0.18)) {
          showsAgentPicker.toggle()
        }
      }
      .buttonStyle(.bordered)
      .accessibilityLabel("Attach an agent to \(ticket.id)")
      .accessibilityHint("Shows running Codex and Claude sessions that can be attached to this task.")
      .accessibilityIdentifier("attach-agent-\(ticket.id)")
      .help("Choose, attach, or remove an agent session")

      Spacer()
    }
    .controlSize(.regular)
    .padding(.horizontal, 14).padding(.bottom, 10)
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 10) {
      if ticket.isRecurringPullRequestTask {
        RecurringPRResolutionDetails(
          progress: recurringProgress,
          error: recurringProgressError,
          open: model.open
        )
      }
      DetailBlock(title: "Summary", text: ticket.summary)
      if let next = ticket.next, !next.isEmpty { DetailBlock(title: "Next", text: next) }
      if let doneWhen = ticket.doneWhen, !doneWhen.isEmpty {
        DetailBlock(title: "Done when", text: doneWhen)
      }

      if !ticket.steps.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          DetailLabel(text: "Progress")
          ForEach(ticket.steps) { step in
            HStack(alignment: .top, spacing: 7) {
              Image(systemName: stepIcon(step.status)).foregroundStyle(stepColor(step.status))
                .frame(width: 14)
              VStack(alignment: .leading, spacing: 2) {
                Text(step.label).font(.system(size: 13))
                ForEach(step.evidence, id: \.self) { evidence in
                  Button {
                    model.open(evidence)
                  } label: {
                    Text(URL(fileURLWithPath: evidence).lastPathComponent).font(.system(size: 12))
                      .lineLimit(1)
                  }.buttonStyle(.link).accessibilityLabel(
                    "Open evidence \(URL(fileURLWithPath: evidence).lastPathComponent)")
                }
              }
            }
          }
        }
      }

      if !ticket.prs.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          DetailLabel(text: "Pull requests")
          ForEach(ticket.prs) { pullRequest in
            Button {
              model.open(pullRequest.url)
            } label: {
              HStack(spacing: 6) {
                Image(
                  systemName: pullRequest.isMerged
                    ? "checkmark.arrow.trianglehead.branch" : "arrow.triangle.branch")
                Text("#\(pullRequest.number) \(pullRequest.title)").lineLimit(2)
                Spacer()
                Text(pullRequest.state?.lowercased() ?? "").foregroundStyle(.secondary)
              }.font(.system(size: 13))
            }.buttonStyle(.plain).accessibilityLabel(
              "Open pull request \(pullRequest.number): \(pullRequest.title)")
          }
        }
      }

      if !ticket.links.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          DetailLabel(text: "Evidence and links")
          ForEach(ticket.links) { link in
            Button {
              model.open(link.url)
            } label: {
              Label(link.label, systemImage: linkIcon(link.type)).font(.system(size: 13)).lineLimit(
                2
              ).frame(
                maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).accessibilityLabel("Open \(link.label)")
          }
        }
      }

      if let review {
        ReviewDetail(review: review, retry: { model.retryReview(for: ticket) }, open: model.open)
      }

      if let message = model.actionMessages[ticket.id] {
        Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
      }

    }.padding(.horizontal, 14).padding(.bottom, 14)
  }

  private var checkColor: Color {
    switch review?.status {
    case .running: QueueAccentPalette.color(.info, style: accentStyle)
    case .pending: QueueAccentPalette.color(.warning, style: accentStyle)
    case .accepted: QueueAccentPalette.color(.success, style: accentStyle)
    default: .secondary
    }
  }

  private var priorityColor: Color {
    if recurringProgress?.openCount == 0 { return .secondary }
    return switch ticket.priority.lowercased() {
    case "critical": QueueAccentPalette.color(.danger, style: accentStyle)
    case "high": QueueAccentPalette.color(.warning, style: accentStyle)
    case "medium": QueueAccentPalette.color(.info, style: accentStyle)
    default: .secondary
    }
  }

  private var summaryProgressLabel: String {
    guard ticket.isRecurringPullRequestTask else { return ticket.progressLabel }
    guard let recurringProgress else { return "Loading PRs" }
    guard recurringProgress.dailyTarget > 0 else { return "0 today" }
    return "\(recurringProgress.resolvedToday.count)/\(recurringProgress.dailyTarget) today"
  }

  private var statusColor: Color {
    switch ticket.status.lowercased() {
    case "blocked": QueueAccentPalette.color(.danger, style: accentStyle)
    case "in-progress": QueueAccentPalette.color(.info, style: accentStyle)
    case "backlog": .secondary
    default: QueueAccentPalette.color(.success, style: accentStyle)
    }
  }

  private func stepIcon(_ status: String) -> String {
    switch status.lowercased() {
    case "done": "checkmark.circle.fill"
    case "in-progress": "circle.lefthalf.filled"
    case "blocked": "exclamationmark.octagon.fill"
    default: "circle"
    }
  }

  private func stepColor(_ status: String) -> Color {
    switch status.lowercased() {
    case "done": QueueAccentPalette.color(.success, style: accentStyle)
    case "in-progress": QueueAccentPalette.color(.info, style: accentStyle)
    case "blocked": QueueAccentPalette.color(.danger, style: accentStyle)
    default: .secondary
    }
  }

  private func linkIcon(_ type: String?) -> String {
    switch type?.lowercased() {
    case "github": "arrow.triangle.branch"
    case "plan": "doc.text"
    case "file": "folder"
    default: "link"
    }
  }
}

private struct RecurringPRProgressSummary: View {
  let progress: RecurringPullRequestProgress?
  let error: String?

  @Environment(\.queueAccentStyle) private var accentStyle

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let progress {
        if progress.dailyTarget == 0 {
          HStack(spacing: 7) {
            Image(systemName: "pause.circle.fill")
            Text("No open pull requests. Daily target paused at zero.")
          }
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
        } else {
          progressLine(
            title: "Today",
            completed: progress.resolvedToday.count,
            target: progress.dailyTarget,
            fraction: progress.dailyFraction,
            color: QueueAccentPalette.color(.info, style: accentStyle)
          )
          progressLine(
            title: "This week",
            completed: progress.resolvedThisWeek.count,
            target: progress.weeklyTarget,
            fraction: progress.weeklyFraction,
            color: QueueAccentPalette.color(.success, style: accentStyle)
          )
          Text("\(progress.openCount) open PRs · target refreshes every five minutes")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
      } else if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
      } else {
        HStack(spacing: 7) {
          ProgressView().controlSize(.small)
          Text("Loading recurring PR progress…")
        }.font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
    .padding(.top, 2)
  }

  private func progressLine(
    title: String,
    completed: Int,
    target: Int,
    fraction: Double,
    color: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(title).font(.system(size: 11, weight: .semibold))
        Spacer()
        Text("\(completed)/\(target)")
          .font(.system(size: 11, weight: .bold).monospacedDigit())
      }.foregroundStyle(.secondary)
      ProgressView(value: fraction)
        .progressViewStyle(.linear)
        .tint(color)
        .accessibilityLabel("\(title) pull request resolution progress")
        .accessibilityValue("\(completed) of \(target)")
    }
  }
}

private struct RecurringPRResolutionDetails: View {
  let progress: RecurringPullRequestProgress?
  let error: String?
  let open: (String) -> Void

  @State private var showsResolvedToday = false
  @State private var showsEarlierThisWeek = false

  private var earlierThisWeek: [PullRequestResolution] {
    guard let progress else { return [] }
    let todayIDs = Set(progress.resolvedToday.map(\.id))
    return progress.resolvedThisWeek.filter { !todayIDs.contains($0.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      DetailLabel(text: "Recurring PR goal")
      if let progress {
        DisclosureGroup(isExpanded: $showsResolvedToday) {
          resolutionList(
            progress.resolvedToday,
            emptyMessage: "No pull requests have been resolved today."
          )
        } label: {
          disclosureLabel("Resolved today", count: progress.resolvedToday.count)
        }

        DisclosureGroup(isExpanded: $showsEarlierThisWeek) {
          resolutionList(
            earlierThisWeek,
            emptyMessage: "No earlier resolutions this week."
          )
        } label: {
          disclosureLabel("Earlier this week", count: earlierThisWeek.count)
        }
      } else if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 12)).foregroundStyle(.orange)
      } else {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Loading GitHub activity…")
        }.font(.system(size: 12)).foregroundStyle(.secondary)
      }
    }
    .padding(11)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
  }

  private func disclosureLabel(_ title: String, count: Int) -> some View {
    HStack {
      Text(title).font(.system(size: 13, weight: .semibold))
      Spacer()
      Text("\(count)").font(.system(size: 12, weight: .bold).monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func resolutionList(_ resolutions: [PullRequestResolution], emptyMessage: String)
    -> some View
  {
    if resolutions.isEmpty {
      Text(emptyMessage).font(.system(size: 12)).foregroundStyle(.secondary)
        .padding(.top, 7)
    } else {
      VStack(spacing: 5) {
        ForEach(resolutions) { resolution in
          Button {
            open(resolution.url)
          } label: {
            HStack(alignment: .top, spacing: 8) {
              Image(
                systemName: resolution.isMerged
                  ? "checkmark.arrow.trianglehead.branch" : "xmark.circle"
              )
              .foregroundStyle(resolution.isMerged ? Color.green : Color.secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text("#\(resolution.number) \(resolution.title)")
                  .font(.system(size: 12, weight: .medium)).lineLimit(3)
                Text(resolutionDetail(resolution))
                  .font(.system(size: 10)).foregroundStyle(.secondary)
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
          .accessibilityLabel("Open pull request \(resolution.number): \(resolution.title)")
        }
      }.padding(.top, 6)
    }
  }

  private func resolutionDetail(_ resolution: PullRequestResolution) -> String {
    let disposition = resolution.isMerged ? "Merged" : "Closed"
    guard let rawDate = resolution.resolvedAt,
      let date = ISO8601DateFormatter().date(from: rawDate)
    else {
      return disposition
    }
    return "\(disposition) \(date.formatted(date: .abbreviated, time: .shortened))"
  }
}

private struct AgentSessionPicker: View {
  let ticket: DashboardTicket
  let model: QueueViewModel
  let onClose: () -> Void

  @State private var runningAgents: [RunningAgentSession] = []
  @State private var isLoading = true
  @State private var attachingAgentID: String?
  @State private var loadError: String?
  @State private var removalHintSessionID: String?

  private var attachedAgents: [TaskAgentSession] { model.agentSessions(for: ticket.id) }
  private var unattachedRunningAgents: [RunningAgentSession] {
    let attached = Set(attachedAgents.map { "\($0.provider.rawValue):\($0.sessionID)" })
    return runningAgents.filter { !attached.contains("\($0.provider.rawValue):\($0.sessionID)") }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 9) {
        Image(systemName: "person.crop.circle.badge.checkmark").font(
          .system(size: 16, weight: .semibold))
        VStack(alignment: .leading, spacing: 2) {
          Text("Agent sessions").font(.system(size: 16, weight: .bold))
          Text("View, attach, or remove agents for \(ticket.id)")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          Task { await loadAgents() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }.buttonStyle(.plain).frame(width: 32, height: 32)
          .disabled(isLoading || attachingAgentID != nil)
          .accessibilityLabel("Refresh running agents")
          .help("Refresh running agents")
        Button {
          onClose()
        } label: {
          Image(systemName: "xmark")
        }.buttonStyle(.plain).frame(width: 32, height: 32)
          .disabled(attachingAgentID != nil)
          .accessibilityLabel("Close agent picker")
          .help("Close agent picker")
      }

      if !attachedAgents.isEmpty {
        VStack(alignment: .leading, spacing: 7) {
          Text("Attached").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
          ForEach(attachedAgents) { session in
            attachedAgentRow(session)
          }
          if let removalHintSessionID {
            Text("Double-click the trash button to remove session \(removalHintSessionID).")
              .font(.system(size: 11)).foregroundStyle(.secondary)
          }
        }
        Divider().opacity(0.5)
      }

      Text("Attach another running agent")
        .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)

      if isLoading {
        HStack(spacing: 9) {
          ProgressView().controlSize(.small)
          Text("Finding Codex and Claude sessions in WezTerm…").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 70)
      } else if let loadError {
        VStack(alignment: .leading, spacing: 9) {
          Label(loadError, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
          Button("Try again") { Task { await loadAgents() } }.buttonStyle(.bordered)
        }.font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
      } else if unattachedRunningAgents.isEmpty {
        ContentUnavailableView(
          "No unattached agents found",
          systemImage: "person.crop.circle.badge.questionmark",
          description: Text("Start Codex or Claude in WezTerm, then refresh this list.")
        ).frame(maxWidth: .infinity, minHeight: 110)
      } else {
        VStack(spacing: 7) {
          ForEach(unattachedRunningAgents) { agent in
            runningAgentRow(agent)
          }
        }.padding(.vertical, 1)
      }
    }.padding(12).frame(maxWidth: .infinity)
      .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1)
      }
      .task { await loadAgents() }
  }

  private func attachedAgentRow(_ session: TaskAgentSession) -> some View {
    HStack(spacing: 8) {
      Button {
        model.viewAgent(session, for: ticket)
      } label: {
        HStack(spacing: 10) {
          Image(systemName: "terminal").font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary).frame(width: 22)
          VStack(alignment: .leading, spacing: 3) {
            Text("\(session.tabTitle) · \(session.sessionID)")
              .font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
            Text("\(session.provider.displayName) · \(displayPath(session.workingDirectory))")
              .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityLabel(
          "View \(session.provider.displayName) agent, \(session.tabTitle), session \(session.sessionID)"
        )

      Image(systemName: "trash")
        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
        .frame(width: 34, height: 34).contentShape(Rectangle())
        .onTapGesture(count: 2) {
          removalHintSessionID = nil
          model.removeAgent(session, from: ticket)
        }
        .onTapGesture(count: 1) { removalHintSessionID = session.sessionID }
        .accessibilityElement()
        .accessibilityLabel("Remove session \(session.sessionID)")
        .accessibilityHint("Double-click to remove this agent from the task")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.removeAgent(session, from: ticket) }
        .help("Double-click to remove this agent from the task")
    }.padding(.horizontal, 10).padding(.vertical, 8)
      .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
  }

  private func runningAgentRow(_ agent: RunningAgentSession) -> some View {
    Button {
      attachingAgentID = agent.id
      Task {
        if await model.attachAgent(agent, to: ticket) {
          await loadAgents()
        }
        attachingAgentID = nil
      }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "link.badge.plus").font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.secondary).frame(width: 22)
        VStack(alignment: .leading, spacing: 3) {
          Text("\(agent.tabTitle) · \(agent.sessionID)")
            .font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
          Text("\(agent.provider.displayName) · \(displayPath(agent.workingDirectory))")
            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
        if attachingAgentID == agent.id {
          ProgressView().controlSize(.small)
        } else if agent.pane.isActive == true {
          Circle().fill(Color.green).frame(width: 7, height: 7).help("Active pane")
        }
      }.padding(.horizontal, 11).padding(.vertical, 9).contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(attachingAgentID != nil)
      .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
      .accessibilityLabel(
        "Attach \(agent.provider.displayName) agent, \(agent.tabTitle), session \(agent.sessionID)"
      )
  }

  private func loadAgents() async {
    isLoading = true
    defer { isLoading = false }
    loadError = nil
    do {
      runningAgents = try await model.availableAgents()
    } catch {
      runningAgents = []
      loadError = error.localizedDescription
    }
  }

  private func displayPath(_ path: String) -> String {
    path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
  }
}

private struct DetailLabel: View {
  let text: String

  var body: some View {
    Text(text.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.4).foregroundStyle(
      .secondary)
  }
}

private struct DetailBlock: View {
  let title: String
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      DetailLabel(text: title)
      Text(text).font(.system(size: 13)).textSelection(.enabled).fixedSize(
        horizontal: false, vertical: true)
    }
  }
}

private struct StatusPill: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text.replacingOccurrences(of: "-", with: " ").uppercased()).font(
      .system(size: 10, weight: .bold)
    ).tracking(0.3).foregroundStyle(color).padding(
      .horizontal, 7
    ).padding(.vertical, 3).background(color.opacity(0.12), in: Capsule())
  }
}

private struct ReviewPill: View {
  let status: CompletionReviewStatus
  @Environment(\.queueAccentStyle) private var accentStyle

  var body: some View { StatusPill(text: status.rawValue, color: color) }

  private var color: Color {
    switch status {
    case .pending: QueueAccentPalette.color(.warning, style: accentStyle)
    case .running: QueueAccentPalette.color(.info, style: accentStyle)
    case .needsWork: QueueAccentPalette.color(.warning, style: accentStyle)
    case .accepted: QueueAccentPalette.color(.success, style: accentStyle)
    case .failed: QueueAccentPalette.color(.danger, style: accentStyle)
    }
  }
}

private struct ReviewDetail: View {
  let review: CompletionRequest
  let retry: () -> Void
  let open: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      DetailLabel(text: "Completion review")
      if let summary = review.summary, !summary.isEmpty {
        Text(summary).font(.system(size: 13)).lineLimit(6).fixedSize(
          horizontal: false, vertical: true)
      } else {
        Text(
          review.status == .running
            ? "Codex is reviewing source evidence…" : "Queued for Codex review."
        ).font(.system(size: 13)).foregroundStyle(
          .secondary)
      }
      HStack(spacing: 7) {
        if [.failed, .needsWork].contains(review.status) {
          Button("Review again", action: retry).buttonStyle(.link).accessibilityLabel(
            "Review completion again")
        }
        if let logPath = review.logPath {
          Button("Open log") { open(logPath) }.buttonStyle(.link).accessibilityLabel(
            "Open completion review log")
        }
      }.font(.system(size: 13))
    }.accessibilityElement(children: .contain)
  }
}

private struct NotificationSurfaceModifier: ViewModifier {
  let radius: CGFloat
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content.background {
      RoundedRectangle(cornerRadius: radius, style: .continuous).fill(
        QueuePalette.component(for: colorScheme))
    }.clipShape(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
    ).overlay {
      RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(
        QueuePalette.componentBorder(for: colorScheme), lineWidth: 0.75)
    }.shadow(color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.13), radius: 8, x: 0, y: 3)
  }
}

private struct MinimumHitTargetModifier: ViewModifier {
  @ScaledMetric(relativeTo: .body) private var minimumWidth: CGFloat = 44
  @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 44

  init(width: CGFloat = 44, height: CGFloat = 44) {
    _minimumWidth = ScaledMetric(wrappedValue: width, relativeTo: .body)
    _minimumHeight = ScaledMetric(wrappedValue: height, relativeTo: .body)
  }

  func body(content: Content) -> some View {
    let cornerRadius = min(minimumWidth, minimumHeight) * 0.28
    content
      .frame(minWidth: minimumWidth, minHeight: minimumHeight)
      .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }
}

private struct PanelSurfaceModifier: ViewModifier {
  let radius: CGFloat
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content.background {
      RoundedRectangle(cornerRadius: radius, style: .continuous).fill(
        QueuePalette.panel(for: colorScheme))
    }.clipShape(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
    ).overlay {
      RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(
        QueuePalette.panelBorder(for: colorScheme), lineWidth: 2)
    }
  }
}

private enum QueuePalette {
  static let wezTermBackground = Color(red: 26 / 255, green: 29 / 255, blue: 35 / 255)
  static let lightComponent = Color(red: 240 / 255, green: 242 / 255, blue: 245 / 255)

  static func component(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? wezTermBackground : lightComponent
  }

  static func componentBorder(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.white.opacity(0.13) : Color.white.opacity(0.72)
  }

  static func panel(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? wezTermBackground.opacity(0.80) : Color.white.opacity(0.29)
  }

  static func panelBorder(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.white.opacity(0.20) : Color.gray.opacity(0.5)
  }
}

private enum QueueAccentRole {
  case danger
  case warning
  case info
  case success
}

private extension View {
  func minimumHitTarget(width: CGFloat = 44, height: CGFloat = 44) -> some View {
    modifier(MinimumHitTargetModifier(width: width, height: height))
  }
}

private enum QueueAccentPalette {
  static func color(_ role: QueueAccentRole, style: QueueAccentStyle) -> Color {
    switch style {
    case .monochrome:
      return .secondary
    case .muted:
      switch role {
      case .danger: return Color(red: 0.73, green: 0.42, blue: 0.45)
      case .warning: return Color(red: 0.72, green: 0.55, blue: 0.34)
      case .info: return Color(red: 0.39, green: 0.59, blue: 0.68)
      case .success: return Color(red: 0.39, green: 0.62, blue: 0.50)
      }
    case .pastel:
      switch role {
      case .danger: return Color(red: 0.95, green: 0.57, blue: 0.64)
      case .warning: return Color(red: 0.96, green: 0.72, blue: 0.43)
      case .info: return Color(red: 0.49, green: 0.70, blue: 0.95)
      case .success: return Color(red: 0.49, green: 0.79, blue: 0.60)
      }
    case .vibrant:
      switch role {
      case .danger: return .red
      case .warning: return .orange
      case .info: return .blue
      case .success: return .green
      }
    }
  }
}

private struct QueueAccentStyleKey: EnvironmentKey {
  static let defaultValue = QueueAccentStyle.vibrant
}

extension EnvironmentValues {
  fileprivate var queueAccentStyle: QueueAccentStyle {
    get { self[QueueAccentStyleKey.self] }
    set { self[QueueAccentStyleKey.self] = newValue }
  }
}

extension View {
  fileprivate func notificationSurface(radius: CGFloat) -> some View {
    modifier(NotificationSurfaceModifier(radius: radius))
  }

  fileprivate func panelSurface(radius: CGFloat) -> some View {
    modifier(PanelSurfaceModifier(radius: radius))
  }
}
