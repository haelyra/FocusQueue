import AppKit
import FocusQueueCore
import Foundation
import SwiftUI

enum QueueChromeMetrics {
  static let sectionSpacing: CGFloat = 4
}

struct QueueView: View {
  let model: QueueViewModel
  @State private var showsMoreTasks = false
  @State private var showsPastCompletedTasks = false
  @State private var showsArchivedSubtasks = false
  @State private var visiblePastCompletedCount = 0
  @State private var screen: QueueScreen = .queue
  @State private var selectedTab: QueueTab = .focus
  @State private var focusDropIsTargeted = false
  @State private var restButtonDropIsTargeted = false
  @State private var restSectionDropIsTargeted = false
  @State private var queueAgentDraft = ""
  @State private var taskAgentDrafts: [String: String] = [:]
  @State private var showsSessions = false
  @State private var showsFeedback = false
  @State private var updateDrafts: [String: String] = [:]
  @State private var settingsTarget: QueueSettingsTarget?
  @State private var showsStaleAgentCleanupConfirmation = false
  /// Counted when the cleanup is requested. Scanning every task's agents in
  /// the body ran on each render and dominated queue redraws.
  @State private var staleAgentCandidateCount = 0
  @AppStorage("agentViewEnabled") private var agentViewEnabled = false
  @AppStorage(OpaqueBackgroundsPreference.defaultsKey) private var opaqueBackgroundsEnabled = false
  @State private var isTaskSearchActive = false
  @State private var taskSearchQuery = ""
  @State private var taskSearchCache = TaskSearchCache()
  @FocusState private var taskSearchIsFocused: Bool

  private let completedPageSize = 12
  /// Broad one-letter queries can match most of the queue; rendering every
  /// card would stall typing, so results stop here until the query narrows.
  private let taskSearchResultLimit = 30

  private var focusTickets: [DashboardTicket] { Array(model.openTickets.prefix(5)) }

  private var remainingTickets: [DashboardTicket] { Array(model.openTickets.dropFirst(5)) }

  private var isFilteringTasks: Bool {
    isTaskSearchActive && !taskSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var visiblePastCompletedTickets: [DashboardTicket] {
    Array(model.pastCompletedTickets.prefix(visiblePastCompletedCount))
  }

  var body: some View {
    Group {
      if model.isPanelCollapsed { compactHeader }
      else if model.isTopTaskOnly { topTaskPanel }
      else { expandedPanel }
    }
    .preferredColorScheme(model.appearance == .dark ? .dark : .light)
    .environment(\.queueAccentStyle, model.accentStyle)
    .environment(\.opaqueBackgroundsEnabled, opaqueBackgroundsEnabled)
    .onChange(of: model.queueChatFocusRequest) { _, _ in
      // Same as the side-panel button: the QChat tab would duplicate the side chat.
      screen = .queue
      if selectedTab == .agent { selectedTab = .focus }
    }
    .onChange(of: model.requiresProviderSignIn) { _, required in
      if required { model.setPanelMode(.expanded) }
    }
    .sheet(isPresented: $showsSessions) { SessionBrowserView(model: model) }
    .sheet(isPresented: $showsFeedback) { FeedbackSheet() }
    .sheet(item: Binding(
      get: { model.newTaskRequest },
      set: { if $0 == nil { model.clearNewTaskRequest() } }
    )) { request in
      TaskCreatorSheet(
        model: model, projectID: request.projectID,
        autofocusPrompt: request.autofocusPrompt)
    }
    .sheet(item: Binding(get: { model.launchDiagnostics }, set: { model.launchDiagnostics = $0 })) { log in
      VStack(alignment: .leading, spacing: 12) {
        Text("Launch diagnostics").font(.headline)
        Text(log.title).foregroundStyle(.secondary)
        ScrollView([.horizontal, .vertical]) {
          Text(log.text).font(.system(.body, design: .monospaced))
            .textSelection(.enabled).padding(8)
        }
        Button("Done") { model.launchDiagnostics = nil }
          .keyboardShortcut(.cancelAction)
      }.padding(20).frame(minWidth: 560, minHeight: 360)
    }
    .sheet(isPresented: Binding(get: { model.isSetupPresented }, set: { model.isSetupPresented = $0 })) {
      SetupWizardView(model: model)
    }
  }

  private var expandedPanel: some View {
    HStack(spacing: 12) {
      if model.isInspectorPresented, model.windowPlacement == .upperRight {
        inspector
        Divider()
      }
      queuePane
        .frame(minWidth: 380, idealWidth: 440, maxWidth: model.isInspectorPresented ? 440 : .infinity)
      if model.isInspectorPresented, model.windowPlacement != .upperRight {
        Divider()
        inspector
      }
    }
    .padding(12).frame(minWidth: 380, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
      .overlayPreferenceValue(WalkthroughAnchorKey.self) { anchors in
        if let progress = model.walkthrough {
          WalkthroughOverlay(model: model, progress: progress, anchors: anchors)
        }
      }
      .overlay { if model.requiresProviderSignIn { ProviderSignInGate(model: model) } }
      .environment(\.walkthroughTicketID, model.walkthrough == nil ? nil : model.walkthroughTicket?.id)
      .onChange(of: model.walkthrough?.step) { _, step in showWalkthroughStep(step) }
      .onChange(of: model.walkthrough == nil ? nil : model.walkthroughSnapshot) { _, _ in
        model.checkWalkthroughGoal()
      }
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
          if isTaskSearchActive { closeTaskSearch() }
          if model.openTickets.dropFirst(5).contains(where: { $0.id == taskID }) {
            showsMoreTasks = true
          }
        }
        model.clearRequestedReportTask()
      }
  }

  @ViewBuilder private var inspector: some View {
    if model.isTokenAnalyticsPresented {
      TokenAnalyticsView(supportDirectory: AppPaths.live().supportDirectory,
                         sessions: model.tokenAnalyticsSessions) {
        model.setTokenAnalyticsPresented(false)
      }
      .equatable()
      .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
    } else if model.isQueueChatInspectorPresented {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("Queue chat", systemImage: "bubble.left.and.bubble.right")
            .font(.headline)
          Spacer()
          Button { model.setQueueChatInspectorPresented(false) } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain)
          .minimumHitTarget()
          .accessibilityLabel("Close Queue chat side panel")
          .help("Close Queue chat side panel")
        }
        QueueAgentChatView(
          model: model, draft: $queueAgentDraft, focusRequest: model.queueChatFocusRequest)
      }
      .frame(minWidth: 320, idealWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
    } else if let update = model.presentedAgentUpdate {
      AgentUpdateView(model: model, update: update, draft: Binding(
        get: { updateDrafts[update.id] ?? "" }, set: { updateDrafts[update.id] = $0 }
      )).id(update.id)
    } else if model.isDailyReportPresented {
      DailyReportView(model: model)
    } else if model.isDocumentViewerPresented {
      DocumentViewerInspector(model: model)
    } else if let ticket = model.presentedPlanTicket {
      PlanCanvasView(model: model, ticket: ticket, chatDraft: Binding(
        get: { taskAgentDrafts[ticket.id] ?? "" },
        set: { taskAgentDrafts[ticket.id] = $0 }
      )).id(ticket.id)
    }
  }

  /// Puts the queue screen and tab a walkthrough step points at on screen.
  private func showWalkthroughStep(_ step: WalkthroughStep?) {
    guard let step else { return }
    switch step.screen {
    case .settings:
      settingsTarget = nil
      withAnimation(.easeInOut(duration: 0.18)) { screen = .settings }
    case .queue:
      if screen == .settings { withAnimation(.easeInOut(duration: 0.18)) { screen = .queue } }
      if step.presentation != .card, step != .qchat, selectedTab != .focus { selectedTab = .focus }
    }
  }

  @ViewBuilder private var queuePane: some View {
    Group {
      if model.isPanelCollapsed {
        compactHeader
      } else if model.isTopTaskOnly {
        topTaskPanel
      } else if screen == .settings {
        QueueSettingsView(
          model: model,
          focusedSection: settingsTarget,
          openSessions: { showsSessions = true },
          openAnalytics: { model.setTokenAnalyticsPresented(true) }
        ) {
          model.setTokenAnalyticsPresented(false)
          withAnimation(.easeInOut(duration: 0.18)) { screen = .queue }
        }
      } else {
        queueContent
      }
    }
  }

  private var queueContent: some View {
    VStack(spacing: QueueChromeMetrics.sectionSpacing) {
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
        QueueAgentChatView(
          model: model, draft: $queueAgentDraft, focusRequest: model.queueChatFocusRequest)
      }
    }
  }

  private var dailyReportHeaderIcon: some View {
    let indicator = model.dailyReportHeaderIndicator
    return ZStack(alignment: .topTrailing) {
      if indicator == .running {
        ProgressView().controlSize(.small).frame(width: 16, height: 16)
          .transition(.opacity)
      } else {
        Image(systemName: model.isDailyReportPresented ? "doc.text.fill" : "doc.text")
          .font(.system(size: 13, weight: .semibold))
          .transition(.opacity)
      }
      if indicator == .ready || indicator == .needsAttention {
        Image(systemName: indicator == .ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(
            QueueAccentPalette.color(indicator == .ready ? .success : .warning, style: model.accentStyle)
          )
          .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1))
          .offset(x: 5, y: -4)
          .transition(.scale.combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.18), value: indicator)
  }

  private var dailyReportHeaderAccessibilityLabel: String {
    if model.isDailyReportPresented { return "Close daily report" }
    switch model.dailyReportHeaderIndicator {
    case .running: return "Daily report is running. Open daily report"
    case .ready: return "Daily report is ready. Open daily report"
    case .needsAttention: return "Daily report needs attention. Open daily report"
    case .none: return "Open daily report"
    }
  }

  private var dailyReportHeaderHelp: String {
    switch model.dailyReportHeaderIndicator {
    case .running: return "Daily message report is running"
    case .ready: return "Daily message report finished. Click to read it"
    case .needsAttention: return "Daily message report finished with issues. Click to review"
    case .none: return "Daily message report"
    }
  }

  private var activeQueueContent: some View {
    VStack(spacing: 10) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            todayFocusSection.id("active-queue-top")

            if showsMoreTasks, !isFilteringTasks {
              additionalQueue.transition(.opacity.combined(with: .move(edge: .bottom)))
            }
          }.padding(.horizontal, 2).padding(.vertical, 2)
        }.scrollIndicators(.automatic)
          .onChange(of: model.queueScrollSnapshot) { previous, current in
            guard !isFilteringTasks, current.shouldScrollToTop(from: previous) else { return }
            proxy.scrollTo("active-queue-top", anchor: .top)
          }
      }

      if !isFilteringTasks, !remainingTickets.isEmpty || !model.visibleRoutines.isEmpty { moreButton }
    }
  }

  private var todayFocusSection: some View {
    // Searches the whole project queue, not only the top five. Completed tasks
    // follow open ones so a code or a closed status still finds its task.
    let search = isFilteringTasks
      ? taskSearchCache.result(for: model.openTickets + model.completedTickets, query: taskSearchQuery) : nil
    let shownTickets = search.map { Array($0.tickets.prefix(taskSearchResultLimit)) } ?? focusTickets
    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        focusHeading(resultCount: search?.tickets.count)
          .walkthroughAnchor(.search)
        Menu {
          ForEach(QueueActivitySortMode.allCases.filter { $0 != .manual }) { mode in
            Button { model.setQueueActivitySortMode(mode) } label: {
              if model.queueActivitySortMode == mode {
                Label(mode.displayName, systemImage: "checkmark")
              } else {
                Text(mode.displayName)
              }
            }
          }
          Divider()
          Button {
            agentViewEnabled.toggle()
          } label: {
            Label(
              agentViewEnabled ? "Task view" : "Agent view",
              systemImage: agentViewEnabled ? "rectangle.stack" : "person.2")
          }
          Button("Clean up stale agents…") {
            staleAgentCandidateCount = model.staleAgentCandidates().count
            showsStaleAgentCleanupConfirmation = true
          }
          Button("Restore default order") { model.resetQueueOrder() }
        } label: { Image(systemName: "arrow.up.arrow.down") }
          .menuStyle(.borderlessButton).fixedSize()
          .accessibilityLabel("Queue view and ordering")
      }
      if let search {
        if let caption = taskSearchCaption(search, shown: shownTickets.count) {
          Text(caption).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else if !agentViewEnabled {
        Text(model.queueActivitySortCaption)
          .font(.caption).foregroundStyle(.secondary)
      }

      if let search, search.tickets.isEmpty {
        ContentUnavailableView.search(text: taskSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
          .frame(maxWidth: .infinity).notificationSurface(radius: 18)
      } else if shownTickets.isEmpty {
        ContentUnavailableView(
          "Queue is clear", systemImage: "checkmark.circle",
          description: Text("No open tasks are present in \(model.showsAllProjects ? "any project" : model.selectedProject?.name ?? "the selected project").")
        ).frame(maxWidth: .infinity).notificationSurface(radius: 18)
      } else if agentViewEnabled {
        agentViewList(for: shownTickets)
      } else if search != nil {
        let completedIDs = Set(model.completedTickets.map(\.id))
        ForEach(shownTickets) { ticket in
          if completedIDs.contains(ticket.id) {
            CompletedTicketCard(ticket: ticket, model: model)
          } else {
            TicketCard(ticket: ticket, model: model)
          }
        }
      } else {
        ForEach(shownTickets) { ticket in TicketCard(ticket: ticket, model: model) }
      }
    }
    .onChange(of: taskSearchIsFocused) { _, focused in
      if !focused, !isFilteringTasks { closeTaskSearch() }
    }
    .confirmationDialog(
      "Clean up stale agents?",
      isPresented: $showsStaleAgentCleanupConfirmation,
      titleVisibility: .visible
    ) {
      Button("Archive \(staleAgentCandidateCount) stale \(staleAgentCandidateCount == 1 ? "agent" : "agents")") {
        Task { await model.cleanupStaleAgents() }
      }
      .disabled(staleAgentCandidateCount == 0)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        staleAgentCandidateCount == 0
          ? "No agents currently match. Candidates are interrupted or idle agents with no live process, no unseen output, and no activity in 5 days."
          : "These agents are interrupted or idle with no live process and no activity in 5 days. Archiving keeps them recallable under Archived agents with provider resume."
      )
    }
  }

  /// The heading doubles as the search entry point: clicking it swaps the
  /// capsule for a search field scoped to the selected project.
  @ViewBuilder
  private func focusHeading(resultCount: Int?) -> some View {
    if isTaskSearchActive {
      TaskSearchField(
        query: $taskSearchQuery, isFocused: $taskSearchIsFocused,
        prompt: (model.showsAllProjects ? "Search all tasks" : "Search \(model.projectScopeName) tasks")
          + " · code, status, priority",
        resultCount: resultCount, endEditing: endTaskSearchEditing, close: closeTaskSearch)
    } else if agentViewEnabled {
      focusHeadingButton(title: "Today's focus", detail: "\(agentViewAgentCount(for: focusTickets)) agents")
    } else {
      focusHeadingButton(title: focusDropIsTargeted ? "Drop to Today's focus" : "Today's focus", detail: nil)
      .dropDestination(for: String.self) { ticketIDs, _ in
        moveTicketsToToday(ticketIDs)
      } isTargeted: { focusDropIsTargeted = $0 }
    }
  }

  private func focusHeadingButton(title: String, detail: String?) -> some View {
    Button(action: openTaskSearch) { FocusSearchHeading(title: title, detail: detail) }
      .buttonStyle(.plain)
      .accessibilityLabel([title, detail, "Search tasks"].compactMap { $0 }.joined(separator: ". "))
      .help(model.showsAllProjects ? "Search all tasks" : "Search \(model.projectScopeName) tasks")
  }

  private func taskSearchCaption(_ search: TaskSearchResult, shown: Int) -> String? {
    var parts: [String] = []
    if !search.filters.isEmpty {
      let fields = [TaskSearchFilter.Field.priority, .status].compactMap { field -> String? in
        let values = search.filters.filter { $0.field == field }.map(\.label)
        return values.isEmpty ? nil : "\(field.rawValue.capitalized) \(values.joined(separator: " or "))"
      }
      parts.append("Filtered by " + fields.joined(separator: " · "))
    }
    if case .approximate(let suggestion) = search.match {
      parts.append(suggestion.map { "No exact matches · showing results for \u{201C}\($0)\u{201D}" }
        ?? "No exact matches · showing similar tasks")
    }
    if shown < search.tickets.count {
      parts.append("Showing \(shown) of \(search.tickets.count) · keep typing to narrow")
    }
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
  }

  private func openTaskSearch() {
    isTaskSearchActive = true
    Task { @MainActor in
      await Task.yield()
      taskSearchIsFocused = true
    }
  }

  /// A click outside the field drops the cursor. An empty search also returns
  /// to the heading; typed results stay so their cards remain clickable.
  private func endTaskSearchEditing() {
    if isFilteringTasks { taskSearchIsFocused = false } else { closeTaskSearch() }
  }

  private func closeTaskSearch() {
    taskSearchQuery = ""
    taskSearchIsFocused = false
    isTaskSearchActive = false
  }

  private struct AgentViewGroup: Identifiable {
    let ticket: DashboardTicket
    let agents: [TaskSubtask]
    var id: String { ticket.id }
  }

  /// Tasks with their agents, most recent output, input request, or prompt first.
  private func agentViewGroups(for tickets: [DashboardTicket]) -> [AgentViewGroup] {
    let groups = tickets.map { ticket in
      (group: ticket, items: model.taskItems(for: ticket.id).filter { $0.hasAgent && $0.agentRemovedAt == nil })
    }
    return AgentViewOrdering.grouped(groups, groupActivity: { model.taskContexts[$0.id]?.lastPromptAt }) { agent in
      AgentViewOrdering.activityDate(
        lastOutputAt: agent.lastOutputAt, resultAt: agent.resultAt, lastPromptAt: agent.lastPromptAt,
        attention: agent.attention, lastHeartbeatAt: agent.lastHeartbeatAt)
    }.map { AgentViewGroup(ticket: $0.group, agents: $0.items) }
  }

  private func agentViewAgentCount(for tickets: [DashboardTicket]) -> Int {
    agentViewGroups(for: tickets).reduce(0) { $0 + $1.agents.count }
  }

  @ViewBuilder
  private func agentViewList(for tickets: [DashboardTicket]) -> some View {
    let groups = agentViewGroups(for: tickets)
    if groups.isEmpty {
      Text("No agents yet")
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      ForEach(groups) { group in
        AgentTaskCard(ticket: group.ticket, agents: group.agents, model: model)
      }
    }
  }

  private var completedQueueContent: some View {
    VStack(spacing: 10) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          if completedSubtaskCount > 0 {
            archivedSubtasksSection
          }

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
              CompletedTicketCard(ticket: ticket, model: model)
            }
          }

          if showsPastCompletedTasks {
            SectionHeading(
              title: "Earlier completions",
              detail: "\(model.pastCompletedTickets.count)"
            ).padding(.top, 4)

            ForEach(visiblePastCompletedTickets) { ticket in
              CompletedTicketCard(ticket: ticket, model: model)
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
    HStack(spacing: 6) {
      Button {
        model.requestNewTask()
      } label: {
        Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
      }
      .buttonStyle(.bordered)
      .minimumHitTarget()
      .accessibilityLabel("New task in \(model.selectedProject?.name ?? "selected project")")
      .help("Add a task to \(model.selectedProject?.name ?? "the selected project")")
      .disabled(model.selectedProject == nil)
      .walkthroughAnchor(.newTask)

      // AppKit re-measures segmented labels on every layout pass. Plain strings
      // keep that measuring from re-reading and re-observing the model.
      let focusLabel = "Focus \(model.openTickets.count)"
      let completedLabel = "Completed \(model.completedTodayTickets.count)"
      Picker("Queue section", selection: $selectedTab) {
        Text(focusLabel).tag(QueueTab.focus)
        Text(completedLabel).tag(QueueTab.completed)
        Text("QChat").tag(QueueTab.agent)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("Queue section")
      .walkthroughAnchor(.qchat)
      .onChange(of: selectedTab) { _, tab in
        if tab == .agent, model.isQueueChatInspectorPresented {
          model.setQueueChatInspectorPresented(false)
        }
      }

      Button {
        if selectedTab == .agent { selectedTab = .focus }
        model.toggleQueueChatInspector()
      } label: {
        Image(
          systemName: model.isQueueChatInspectorPresented
            ? "rectangle.righthalf.inset.filled" : "arrow.right.to.line.compact"
        )
        .font(.system(size: 13, weight: .semibold))
      }
      .buttonStyle(.bordered)
      .minimumHitTarget()
      .accessibilityLabel(
        model.isQueueChatInspectorPresented
          ? "Close Queue chat beside the task queue" : "Open Queue chat beside the task queue"
      )
      .help(
        model.isQueueChatInspectorPresented
          ? "Close side-by-side Queue chat" : "Keep the task queue visible beside Queue chat"
      )
    }
  }

  private var completedSubtaskTickets: [DashboardTicket] {
    model.projectTickets.filter { ticket in
      model.focusSubtasks(for: ticket.id).contains { model.isCompletionSeen($0, ticketID: ticket.id) }
    }
  }

  private var completedSubtaskCount: Int {
    completedSubtaskTickets.reduce(0) { count, ticket in
      count + model.focusSubtasks(for: ticket.id).filter { model.isCompletionSeen($0, ticketID: ticket.id) }.count
    }
  }

  private var archivedSubtasksSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeading(title: "Archived subtasks", detail: "\(completedSubtaskCount)")
      DisclosureGroup(isExpanded: $showsArchivedSubtasks) {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(completedSubtaskTickets) { ticket in
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 4) {
                Text("\(ticket.id) ·")
                RenamableTaskTitle(
                  ticket: ticket, model: model, size: 11, weight: .semibold,
                  maximumLines: 2)
              }
              .foregroundStyle(.secondary)
              ForEach(model.focusSubtasks(for: ticket.id).filter { model.isCompletionSeen($0, ticketID: ticket.id) }) {
                subtask in
                ArchivedSubtaskRow(ticket: ticket, subtask: subtask, model: model)
              }
            }
          }
        }
        .padding(.top, 8)
      } label: {
        Label(
          showsArchivedSubtasks ? "Hide completed subtasks" : "Show completed subtasks",
          systemImage: "archivebox"
        )
        .font(.system(size: 13, weight: .semibold))
      }
      .padding(12)
      .notificationSurface(radius: 14)
      .accessibilityHint("Completed subtasks retain their explanations and agent history.")
    }
  }

  private var compactHeader: some View {
    Button { model.setPanelCollapsed(false) } label: {
      VStack(spacing: 1) {
        Text("FQ").font(.system(size: 15, weight: .bold, design: .rounded))
        Text("\(model.openTickets.count)").font(.system(size: 10, weight: .medium).monospacedDigit())
      }.frame(width: 52, height: 44).contentShape(Rectangle())
    }.buttonStyle(.plain).notificationSurface(radius: 12)
      .accessibilityLabel("Expand Focus Queue: \(model.selectedProject?.name ?? "no project"), \(model.openTickets.count) tasks")
      .help("\(model.selectedProject?.name ?? "Focus Queue") · \(model.openTickets.count) tasks")
      .contextMenu {
        Button("Fully minimize", systemImage: "minus") {
          model.minimize(using: .dock)
        }
        Button("Show top task", systemImage: "rectangle.topthird.inset.filled") {
          model.minimize(using: .topTask)
        }
      }
  }

  private var topTaskPanel: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        Circle().fill(
          QueueAccentPalette.color(
            model.loadError == nil ? .success : .warning, style: model.accentStyle)
        ).frame(width: 7, height: 7)
        Text("Top task").font(.system(size: 13, weight: .bold))
        Text("\(model.openTickets.count) tasks")
          .font(.system(size: 10, weight: .semibold).monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        Button { model.setPanelMode(.expanded) } label: {
          Image(systemName: "rectangle.expand.vertical")
        }
        .buttonStyle(.plain).minimumHitTarget(width: 32, height: 32)
        .accessibilityLabel("Show full task queue").help("Show full queue")
        Button { model.setPanelMode(.collapsed) } label: {
          Image(systemName: "rectangle.compress.vertical")
        }
        .buttonStyle(.plain).minimumHitTarget(width: 32, height: 32)
        .accessibilityLabel("Collapse Focus Queue to FQ").help("Collapse to FQ")
      }

      if let ticket = model.openTickets.first {
        Button {
          model.setPanelMode(.expanded)
          model.openPlan(for: ticket)
        } label: {
          VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
              Text(ticket.id).font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
              Spacer()
              StatusPill(text: ticket.status, color: Color.accentColor)
            }
            RenamableTaskTitle(
              ticket: ticket, model: model, size: 16, weight: .semibold,
              maximumLines: 2)
            if !ticket.summary.isEmpty {
              Text(ticket.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
              Text(ticket.priority.capitalized).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
              Spacer()
              Label("Open task", systemImage: "chevron.right")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
          }
          .padding(13).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .notificationSurface(radius: 16)
        .help("Open \(ticket.id) and its plan")
      } else {
        ContentUnavailableView("Queue is clear", systemImage: "checkmark.circle")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .panelSurface(radius: 22)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline) {
        Menu {
          Button {
            Task { await model.selectAllProjects() }
          } label: {
            if model.showsAllProjects {
              Label("All", systemImage: "checkmark")
            } else {
              Text("All")
            }
          }
          Divider()
          ForEach(model.projects) { project in
            Button {
              Task { _ = await model.selectProject(id: project.id) }
            } label: {
              if !model.showsAllProjects, project.id == model.selectedProject?.id {
                Label(project.name, systemImage: "checkmark")
              } else {
                Text(project.name)
              }
            }
          }
        } label: {
          HStack(spacing: 5) {
            Text(model.showsAllProjects ? "All" : (model.selectedProject?.name ?? "Select project"))
              .font(.system(size: 19, weight: .bold, design: .rounded))
            Image(systemName: "chevron.down")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(.secondary)
          }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Working project: \(model.projectScopeName)")
        .help("Choose the working project; All shows every project including Other")
        Spacer()
        Text(headerCountLabel).font(
          .system(size: 11, weight: .semibold).monospacedDigit()
        ).foregroundStyle(.secondary)
      }
      HStack(spacing: 6) {
        Circle().fill(
          QueueAccentPalette.color(
            model.loadError == nil ? .success : .warning, style: model.accentStyle)
        ).frame(width: 7, height: 7)
        syncLabel.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
          .lineLimit(1).minimumScaleFactor(0.8)
        Spacer()
        monitorButton
        pinWindowButton
        Button {
          if model.dailyReport == nil {
            Task { await model.reloadDailyReport() }
          }
          model.openDailyReportFromHeader()
        } label: {
          dailyReportHeaderIcon
        }.buttonStyle(.plain).minimumHitTarget(width: 30, height: 34).accessibilityLabel(
          dailyReportHeaderAccessibilityLabel
        ).help(dailyReportHeaderHelp)
        Button {
          settingsTarget = nil
          withAnimation(.easeInOut(duration: 0.18)) { screen = .settings }
        } label: {
          Image(systemName: "gearshape.fill").font(.system(size: 13, weight: .semibold))
        }.buttonStyle(.plain).minimumHitTarget(width: 30, height: 34).accessibilityLabel(
          "Open Focus Queue settings"
        ).help("Settings")
        QueueHelpMenu(sendFeedback: { showsFeedback = true }, replayWalkthrough: {
          withAnimation(.snappy) { model.startWalkthrough() }
        })
        .minimumHitTarget(width: 30, height: 34)
        .walkthroughAnchor(.help)
        Button {
          model.performPreferredMinimization()
        } label: {
          Image(systemName: "rectangle.compress.vertical").font(
            .system(size: 13, weight: .semibold))
        }.buttonStyle(.plain).minimumHitTarget(width: 30, height: 34).accessibilityLabel(
          "Minimize Focus Queue using the saved option"
        ).help(model.minimizationHelp)
          .walkthroughAnchor(.minimize)
          .contextMenu {
            Button("Fully minimize", systemImage: "minus") {
              model.minimize(using: .dock)
            }
            Button("Minimize to FQ", systemImage: "rectangle.compress.vertical") {
              model.minimize(using: .fq)
            }
            Button("Show top task", systemImage: "rectangle.topthird.inset.filled") {
              model.minimize(using: .topTask)
            }
          }
      }
      if let error = model.loadError {
        Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12))
          .foregroundStyle(.orange).lineLimit(2)
      }
      if let error = model.durableHistoryError {
        HStack(alignment: .top) {
          Label(error, systemImage: "externaldrive.badge.exclamationmark")
            .font(.system(size: 12)).foregroundStyle(.orange).lineLimit(3)
          Spacer()
          Button("Retry history") { model.retryDurableHistory() }
            .buttonStyle(.bordered).controlSize(.small)
        }
      }
    }.padding(.horizontal, 12).padding(.vertical, 8).notificationSurface(radius: 16)
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
    LazyVStack(alignment: .leading, spacing: 10) {
      if !model.visibleRoutines.isEmpty {
        SectionHeading(
          title: "Daily checklist",
          detail: "\(model.completedRoutineCount)/\(model.visibleRoutines.count)")
        VStack(spacing: 1) {
          ForEach(model.visibleRoutines) { routine in
            RoutineRow(
              routine: routine, isComplete: model.routineIsComplete(routine.id),
              toggle: { model.toggleRoutine(routine.id) },
              open: { if let url = routine.url { model.open(url) } })
          }
        }.notificationSurface(radius: 16)
      }

      if !remainingTickets.isEmpty {
        LazyVStack(alignment: .leading, spacing: 10) {
          if agentViewEnabled {
            SectionHeading(
              title: "Rest of queue",
              detail: "\(agentViewAgentCount(for: remainingTickets)) agents"
            )
            agentViewList(for: remainingTickets)
          } else {
            SectionHeading(
              title: restSectionDropIsTargeted ? "Drop to Rest of queue" : "Rest of queue",
              detail: "\(remainingTickets.count)"
            )
            .dropDestination(for: String.self) { ticketIDs, _ in
              moveTicketsToRest(ticketIDs)
            } isTargeted: { restSectionDropIsTargeted = $0 }
            ForEach(remainingTickets) { ticket in TicketCard(ticket: ticket, model: model) }
          }
        }
      }
    }
  }

  @ViewBuilder private var moreButton: some View {
    if agentViewEnabled {
      moreButtonCore
    } else {
      moreButtonCore
        .dropDestination(for: String.self) { ticketIDs, _ in
          moveTicketsToRest(ticketIDs)
        } isTargeted: {
          restButtonDropIsTargeted = $0
          if $0 { showsMoreTasks = true }
        }
        .overlay {
          if restButtonDropIsTargeted {
            RoundedRectangle(cornerRadius: 16)
              .stroke(.tint, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
              .allowsHitTesting(false)
          }
        }
    }
  }

  private var moreButtonCore: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.22)) { showsMoreTasks.toggle() }
    } label: {
      HStack(spacing: 9) {
        Image(systemName: showsMoreTasks ? "chevron.up" : "chevron.down").font(
          .system(size: 12, weight: .bold))
        Text(
          restButtonDropIsTargeted && !agentViewEnabled
            ? "Drop after the top five"
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
    case .focus: "\(model.openTickets.count) active tasks"
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

  private var pinWindowButton: some View {
    Button {
      model.toggleWindowPin()
    } label: {
      Image(systemName: model.isWindowPinned ? "pin.fill" : "pin")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(model.isWindowPinned ? Color.accentColor : Color.secondary)
    }.buttonStyle(.plain).minimumHitTarget(width: 30, height: 34)
      .accessibilityLabel("Pin to window")
      .accessibilityValue(model.isWindowPinned ? "On" : "Off")
      .help(model.isWindowPinned
        ? "Unpin window to use screen placement"
        : "Pin to window: keep the queue at its current position")
  }

  private var monitorButton: some View {
    Button {
      model.switchMonitor()
    } label: {
      Image(systemName: "display.2").font(.system(size: 13, weight: .semibold))
    }.buttonStyle(.plain).minimumHitTarget(width: 30, height: 34).disabled(!model.canSwitchMonitor)
      .accessibilityLabel("Move Focus Queue to the next display")
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

enum QueueSettingsTarget: Hashable {
  case connectors
}

private enum CardCompletionPhase {
  case idle, checked, minimized
}

private enum QueueTab: Hashable {
  case focus
  case completed
  case agent
}

struct QueueAgentChatView: View {
  let model: QueueViewModel
  @Binding var draft: String
  var title: String? = nil
  var ticketID: String? = nil
  var canvasSelection: Binding<PlanCanvasSelection?>? = nil
  var focusRequest = 0
  @FocusState private var composerIsFocused: Bool
  @State private var showsClearConfirmation = false
  @Environment(\.colorScheme) private var colorScheme

  private var messages: [QueueChatMessage] { model.chatMessages(ticketID: ticketID) }
  private var isRespondingHere: Bool {
    model.isQueueAgentResponding && model.respondingTicketID == ticketID
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 10) {
        chatSettingsBar
        if ticketID == nil {
          Text(model.showsAllProjects ? "All projects" : "All projects · Active: \(model.projectScopeName)")
            .font(.caption).foregroundStyle(.secondary)
        }
        QueueChatTranscript(
          messages: messages,
          emptyText: "Discuss this task, refine its success criteria, or ask for a plan update. Decisions stay with the task.",
          agentLabel: ticketID == nil ? "QCHAT" : "ORCHESTRATOR",
          progressText: isRespondingHere ? "\(model.defaultAgentProvider.displayName) is checking the queue" : nil)

        QueueChatComposer(
          draft: $draft,
          isFocused: $composerIsFocused,
          focusRequest: focusRequest,
          maxHeight: composerMaxHeight(geometry.size.height),
          placeholder: ticketID == nil ? "Ask about order or request a task change" : "Discuss this task or update its plan",
          accessibilityLabel: "Message the queue agent",
          isResponding: isRespondingHere,
          canSend: !model.isQueueAgentResponding && !model.reportIsRunning,
          sendLabel: "Send message to queue agent",
          stopLabel: "Stop the queue agent response",
          notice: model.reportIsRunning ? "Chat resumes when the daily report finishes. Your draft stays here." : nil,
          selection: canvasSelection?.wrappedValue,
          clearSelection: { canvasSelection?.wrappedValue = nil },
          clearSelectionLabel: "Clear plan canvas selection",
          onSend: send,
          onStop: model.cancelQueueAgentMessage)
      }
    }
    .task { focusComposer() }
    .onChange(of: model.isQueueAgentResponding) { _, isResponding in
      if !isResponding { focusComposer() }
    }
    .onChange(of: focusRequest) { _, _ in focusComposer() }
  }

  private var chatSettingsBar: some View {
    QueueChatSettingsBar {
      if let title {
        Label(title, systemImage: "terminal")
          .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        let provider = model.defaultAgentProvider
        QueueChatAgentMenus(
          provider: provider,
          model: model.config.chatModel(for: provider),
          effort: model.config.chatEffort(for: provider),
          modelChoices: model.agentModelChoices(for: provider),
          setProvider: model.setDefaultAgentProvider,
          setModel: { model.setChatModel($0, for: provider) },
          setEffort: { model.setChatEffort($0, for: provider) })
        Spacer(minLength: 0)
        Button("Clear Chat") { showsClearConfirmation = true }
          .font(.caption)
          .foregroundStyle(.secondary)
          .buttonStyle(.plain)
          .help("Erase this conversation and start a fresh session")
      }
    }
    .confirmationDialog(
      "Clear this conversation?",
      isPresented: $showsClearConfirmation,
      titleVisibility: .visible
    ) {
      Button("Clear Conversation", role: .destructive) {
        model.clearQueueChat(ticketID: ticketID)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "The transcript is erased and the next message starts a fresh \(model.defaultAgentProvider.displayName) session."
      )
    }
  }

  private func send() {
    let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, !model.isQueueAgentResponding else { return }
    let selection = canvasSelection?.wrappedValue
    if model.sendQueueAgentMessage(message, ticketID: ticketID, canvasSelection: selection) {
      draft = ""
      canvasSelection?.wrappedValue = nil
    }
  }

  private func composerMaxHeight(_ paneHeight: CGFloat) -> CGFloat {
    max(120, paneHeight * 0.7)
  }

  private func focusComposer() {
    Task { @MainActor in
      await Task.yield()
      composerIsFocused = true
    }
  }
}

/// NSTextView-backed composer: Return sends, Shift/Option+Return inserts a
/// newline, and the view grows with its content up to the cap before scrolling.
struct QueueChatComposerTextView: NSViewRepresentable {
  @Binding var text: String
  var isFocused: FocusState<Bool>.Binding
  /// Each new value makes the text view first responder directly. The FocusState
  /// above is not attached to a focusable view, so setting it again is a no-op.
  var focusRequest = 0
  var maxHeight: CGFloat
  var onSend: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, isFocused: isFocused)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = QueueChatComposerNSTextView()
    textView.onSend = onSend
    textView.delegate = context.coordinator
    textView.isRichText = false
    textView.drawsBackground = false
    textView.font = NSFont.systemFont(ofSize: 13)
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? QueueChatComposerNSTextView else { return }
    textView.onSend = onSend
    if textView.string != text {
      textView.string = text
      textView.scrollToEndOfDocument(nil)
    }
    if isFocused.wrappedValue, scrollView.window?.firstResponder != textView {
      DispatchQueue.main.async {
        scrollView.window?.makeFirstResponder(textView)
      }
    }
    if focusRequest != context.coordinator.lastFocusRequest {
      context.coordinator.lastFocusRequest = focusRequest
      textView.focusWhenInWindow()
    }
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: NSScrollView, context: Context
  ) -> CGSize? {
    guard let textView = nsView.documentView as? NSTextView,
          let layoutManager = textView.layoutManager,
          let container = textView.textContainer
    else { return nil }
    layoutManager.ensureLayout(for: container)
    let contentHeight = ceil(layoutManager.usedRect(for: container).height)
    return CGSize(
      width: proposal.width ?? 100,
      height: min(max(20, contentHeight), maxHeight)
    )
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    /// Starts at zero so a chat created by a focus request still takes focus.
    var lastFocusRequest = 0
    private var text: Binding<String>
    private var isFocused: FocusState<Bool>.Binding

    init(text: Binding<String>, isFocused: FocusState<Bool>.Binding) {
      self.text = text
      self.isFocused = isFocused
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
    }

    func textDidEndEditing(_ notification: Notification) {
      isFocused.wrappedValue = false
    }
  }
}

final class QueueChatComposerNSTextView: NSTextView {
  var onSend: (() -> Void)?
  private var focusesOnWindowAttach = false

  /// A freshly opened side chat is not in a window on its first update; focus lands on attach.
  func focusWhenInWindow() {
    guard let window else { focusesOnWindowAttach = true; return }
    DispatchQueue.main.async { window.makeFirstResponder(self) }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard focusesOnWindowAttach, let window else { return }
    focusesOnWindowAttach = false
    DispatchQueue.main.async { window.makeFirstResponder(self) }
  }

  override func keyDown(with event: NSEvent) {
    // 36 = Return, 76 = keypad Enter
    guard event.keyCode == 36 || event.keyCode == 76 else {
      super.keyDown(with: event)
      return
    }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers.contains(.shift) || modifiers.contains(.option) {
      insertText("\n", replacementRange: selectedRange())
    } else {
      onSend?()
    }
  }
}

struct QueueChatMessageRow: View {
  let message: QueueChatMessage
  /// The label above agent messages; user messages read "YOU".
  let agentLabel: String
  @Environment(\.colorScheme) private var colorScheme
  @State private var didCopy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 6) {
        Label(
          message.role == .agent ? agentLabel : "YOU",
          systemImage: message.role == .agent ? "terminal" : "person.crop.circle"
        )
        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(message.text, forType: .string)
          didCopy = true
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
          }
        } label: {
          Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Copy message")
        .help("Copy message text")
      }
      if let selection = message.canvasSelection {
        HStack(spacing: 6) {
          Image(systemName: selection.kind.systemImage)
          Text([selection.kind.title, selection.readableLocation].compactMap { $0 }.joined(separator: " · "))
          Text(selection.compactExcerpt).lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
      }
      ChatMarkdownView(message.text)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 15).padding(.vertical, 14)
    .background(Self.surface(for: message.role, colorScheme: colorScheme))
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.primary.opacity(0.11)).frame(height: 1)
    }
    .textSelection(.enabled)
    .accessibilityElement(children: .contain)
  }

  static func surface(for role: QueueChatRole, colorScheme: ColorScheme) -> Color {
    if colorScheme == .dark { return Color(white: role == .agent ? 0.14 : 0.20) }
    return Color(white: role == .agent ? 0.985 : 0.935)
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
          .disabled(model.reportIsRunning).accessibilityLabel("Reload daily report").help("Reload latest report")
        Button {
          model.setDailyReportPresented(false)
        } label: {
          Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
        }.buttonStyle(.plain).minimumHitTarget(width: 46, height: 46)
          .accessibilityLabel("Close daily report").help("Collapse daily report")
      }.padding(.horizontal, 14).padding(.vertical, 10).notificationSurface(radius: 18)

      if model.reportIsRunning {
        HStack(spacing: 9) {
          ProgressView().controlSize(.small)
          Text("Checking new messages and creating linked tasks…")
            .font(.system(size: 12, weight: .medium))
          Spacer()
          Button(
            model.isDailyReportCancellationRequested ? "Cancelling…" : "Cancel",
            action: model.cancelDailyReport
          )
          .buttonStyle(.bordered)
          .disabled(model.isDailyReportCancellationRequested)
        }.padding(13).notificationSurface(radius: 16)
      } else if let message = model.dailyReportRunMessage {
        Label(message, systemImage: model.dailyReportRunFailed ? "exclamationmark.triangle" : "info.circle")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(model.dailyReportRunFailed ? Color.orange : Color.secondary)
          .padding(13).frame(maxWidth: .infinity, alignment: .leading)
          .notificationSurface(radius: 16)
      }

      ScrollView {
        DisclosureGroup("Report history and run logs") {
          DailyReportHistoryView(snapshot: model.reportHistory, onSelectReport: model.selectHistoricalReport)
            .padding(.vertical, 8)
        }.padding(12).notificationSurface(radius: 14)
        if let error = model.reportHistoryError {
          Text(error).font(.caption).foregroundStyle(.orange)
        }
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
      }.buttonStyle(.borderedProminent).disabled(model.reportIsRunning)
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
          title: "Read",
          value: report.platforms.reduce(0) { $0 + $1.collectedCount }.formatted()
        )
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
          Text(
            platform.collectedCount == 0
              ? "No messages were read from this source."
              : "Nothing new needed review."
          )
          .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 4)
        } else {
          ForEach(platform.messages) { message in
            messageDisclosure(message)
          }
        }
        let skipped = platform.triagedAwayCount ?? 0
        if platform.alreadyProcessedCount > 0 || platform.deferredCount > 0 || skipped > 0 {
          Text(
            "\(skipped) skipped as promotional · \(platform.alreadyProcessedCount) previously checked · \(platform.deferredCount) deferred"
          ).font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }.padding(.top, 10)
    } label: {
      HStack {
        Text(platform.platform.displayName).font(.system(size: 14, weight: .bold))
        Text(platform.status.uppercased()).font(.system(size: 9, weight: .bold))
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(platform.collectedCount) read · \(platform.newCount) new · \(platform.checkedCount) checked")
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

struct QueueSettingsView: View {
  let model: QueueViewModel
  let focusedSection: QueueSettingsTarget?
  let openSessions: () -> Void
  let openAnalytics: () -> Void
  let close: () -> Void
  @AppStorage(OpaqueBackgroundsPreference.defaultsKey) private var opaqueBackgroundsEnabled = false

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        Button(action: close) {
          Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
        }.buttonStyle(.plain).minimumHitTarget(width: 46, height: 46).accessibilityLabel(
          "Back to Focus Queue").help("Return to the task queue")
        Text("Settings").font(.system(size: 21, weight: .bold, design: .rounded))
        Spacer()
        Text("Focus Queue").font(.system(size: 12, weight: .semibold)).foregroundStyle(
          .secondary)
      }.padding(.horizontal, 14).padding(.vertical, 10).notificationSurface(radius: 18)

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if focusedSection == .connectors { connectorDiagnosticsSection }

          settingsSection(title: "Updates", detail: "Install new Focus Queue beta releases from GitHub.") {
            AppUpdateSection()
          }

          groupHeading("Projects")
          settingsSection(
            title: "Projects",
            detail: "Choose a project to see its settings and files. Open a file to read it beside settings with its project chat."
          ) {
            VStack(alignment: .leading, spacing: 10) {
              ProjectSettingsSection(model: model)
              Button("Open setup wizard", systemImage: "wand.and.stars") {
                model.isSetupPresented = true
              }.buttonStyle(.bordered)
            }
            .walkthroughAnchor(.projectSettings)
          }

          groupHeading("Agents")
          settingsSection(
            title: "Sign-in",
            detail: "Agents run through each provider's own CLI and your subscription. Check who is signed in, or sign in to another provider."
          ) {
            VStack(alignment: .leading, spacing: 10) {
              WalkthroughSignInContent(model: model)
              Toggle("Report failed sign-ins to the beta tracker", isOn: Binding(
                get: { model.reportsSignInFailures }, set: { model.setReportsSignInFailures($0) }))
              Text("When a sign-in fails, Focus Queue files a GitHub issue with the error, the CLI version, and your Mac and app versions. Paths, emails and tokens are removed. Issues on this repository are public.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          settingsSection(
            title: "Default agent",
            detail: "New agents and quick launches start with this provider and its default model unless you pick another one. The + task creator uses it when no agent has been launched yet."
          ) {
            VStack(alignment: .leading, spacing: 10) {
              Picker("Provider", selection: Binding(
                get: { model.defaultAgentProvider },
                set: { model.setDefaultAgentProvider($0) }
              )) {
                ForEach(AgentProvider.allCases, id: \.self) { provider in
                  provider.label().tag(provider)
                }
              }.pickerStyle(.segmented).labelsHidden()
              Picker("Default model", selection: Binding(
                get: { model.defaultAgentModel(for: model.defaultAgentProvider) ?? "" },
                set: { model.setDefaultAgentModel($0, for: model.defaultAgentProvider) }
              )) {
                ForEach(model.agentModelChoices(for: model.defaultAgentProvider)) { choice in
                  Text(choice.label).tag(choice.model ?? "")
                }
              }
              Picker("Default effort", selection: Binding(
                get: { model.defaultAgentEffort(for: model.defaultAgentProvider) ?? "" },
                set: { model.setDefaultAgentEffort($0, for: model.defaultAgentProvider) }
              )) {
                ForEach(AppConfiguration.agentEffortLevels(for: model.defaultAgentProvider), id: \.self) { effort in
                  Text(effort).tag(effort)
                }
              }
              Text("New agents start with this model and effort. You can change both for each launch.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          settingsSection(
            title: "Task placement",
            detail: "fq places each new agent with one small model call through your own subscription CLI: it joins a matching open task or creates a titled one. A ticket ID in the prompt skips the call."
          ) {
            VStack(alignment: .leading, spacing: 12) {
              PlacementSettingsView(model: model)
              Divider()
              settingToggle(
                "Save durable facts from prompts",
                detail: "After each agent prompt, a background model call saves lasting preferences and deferred requirements to project or task data.",
                isOn: Binding(
                  get: { model.dataPlacementEnabled },
                  set: { model.setDataPlacementEnabled($0) }))
            }
          }
          settingsSection(
            title: "Agent lifecycle",
            detail: "Automatic steps Focus Queue takes as agents go stale or are escalated."
          ) {
            VStack(alignment: .leading, spacing: 12) {
              settingToggle(
                "Automatically archive stale agents",
                detail: "Once a day, archive interrupted or idle agents with no live process, no unseen output, and no activity in 5 days. They stay recallable under Archived agents.",
                isOn: Binding(
                  get: { model.config.autoArchiveStaleAgents },
                  set: { model.setAutoArchiveStaleAgents($0) }))
              settingToggle(
                "Launch agents for escalated messages",
                detail: "When message ingestion escalates a task with no live agent, start one automatically. When off, requests wait until this is turned back on.",
                isOn: Binding(
                  get: { model.config.agentEscalationAutoLaunch },
                  set: { model.setAgentEscalationAutoLaunch($0) }))
            }
          }
          settingsSection(
            title: "Agent terminals",
            detail: "Each task runs its agents as panes in one shared tmux session."
          ) {
            VStack(alignment: .leading, spacing: 12) {
              TerminalAppSetting(model: model)
              Divider()
              Stepper(value: Binding(
                get: { model.agentsPerWindow },
                set: { model.setAgentsPerWindow($0) }
              ), in: 1...12) {
                HStack {
                  Text("Agent panes per window tab")
                  Spacer()
                  Text("\(model.agentsPerWindow)").monospacedDigit().foregroundStyle(.secondary)
                }
              }
              VStack(alignment: .leading, spacing: 3) {
                HStack {
                  Text("Agent usage bar")
                  Spacer()
                  featureBadge("Coming soon")
                }
                Text("Live quota and context rows below each managed task window.")
                  .font(.caption).foregroundStyle(.secondary)
              }
              Button(action: openSessions) {
                Label("Browse sessions", systemImage: "rectangle.stack")
              }
              .buttonStyle(.bordered)
              .help("Active task sessions and saved sessions you can recall")
            }
          }

          groupHeading("Window and shortcuts")
          settingsSection(
            title: "Appearance",
            detail: "Dark uses your WezTerm #1A1D23 background color. Accent colors change status, priority, sync, and review colors."
          ) {
            VStack(alignment: .leading, spacing: 10) {
              Picker("Appearance", selection: appearanceBinding) {
                Label("Light", systemImage: "sun.max.fill").tag(QueueAppearance.light)
                Label("Dark", systemImage: "moon.stars.fill").tag(QueueAppearance.dark)
              }.pickerStyle(.segmented).labelsHidden()
              Picker("Accent colors", selection: accentStyleBinding) {
                ForEach(QueueAccentStyle.allCases) { style in
                  Text(style.displayName).tag(style)
                }
              }.pickerStyle(.segmented).labelsHidden()
              DisclosureGroup("Advanced") {
                settingToggle(
                  "Opaque backgrounds",
                  detail: "Replace translucent and blurred surfaces with solid dark gray or white backgrounds.",
                  isOn: $opaqueBackgroundsEnabled
                )
                .padding(.top, 8)
              }
            }
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
            title: "Keyboard shortcuts",
            detail: "Global hotkeys that work from any app. Click a shortcut, then press a new combo with ⌘, ⌥, or ⌃. Reset returns to the default shortcut."
          ) {
            VStack(alignment: .leading, spacing: 14) {
              hotkeyRow(.newTask,
                detail: "Opens a new task with the prompt focused. Press again to cancel it.",
                isOn: Binding(
                  get: { model.newTaskHotkeyEnabled },
                  set: { model.setNewTaskHotkeyEnabled($0) }))
              hotkeyRow(.qchat,
                detail: "Opens QChat beside the queue with the message box focused for voice typing. Press again to close it.",
                isOn: Binding(
                  get: { model.qchatHotkeyEnabled },
                  set: { model.setQChatHotkeyEnabled($0) }))
              hotkeyRow(.toggleMinimization,
                detail: "Toggles the full queue and your preferred minimized view (FQ, top task, or Dock).",
                isOn: Binding(
                  get: { model.toggleMinimizationHotkeyEnabled },
                  set: { model.setToggleMinimizationHotkeyEnabled($0) }))
            }
          }

          groupHeading("Daily reports")
          settingsSection(
            title: "Daily message report",
            badge: "Experimental",
            detail:
              "Summarizes your messages across connected platforms. Off by default; when on, it runs once a day. Manual reports and history remain available."
          ) {
            VStack(alignment: .leading, spacing: 12) {
              Toggle(
                "Run a report every day",
                isOn: Binding(
                  get: { model.config.dailyReport.enabled },
                  set: { model.setDailyReportsEnabled($0) }
                )
              )

              DatePicker(
                "Run time",
                selection: dailyReportTimeBinding,
                displayedComponents: .hourAndMinute
              ).disabled(!model.config.dailyReport.enabled)

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

              Picker("Agent", selection: Binding(
                get: { model.config.dailyReport.agentProvider },
                set: { model.setDailyReportAgentProvider($0) }
              )) {
                Text("Follow default provider").tag(AgentProvider?.none)
                ForEach(AgentProvider.allCases, id: \.self) { provider in
                  provider.label()
                    .tag(AgentProvider?.some(provider))
                }
              }
              if let sweepProvider = model.config.dailyReport.agentProvider {
                Picker("Model", selection: Binding(
                  get: { model.config.dailyReport.agentModel ?? "" },
                  set: { model.setDailyReportAgentModel($0) }
                )) {
                  ForEach(model.agentModelChoices(for: sweepProvider)) { choice in
                    Text(choice.label).tag(choice.model ?? "")
                  }
                }
                Picker("Effort", selection: Binding(
                  get: { model.config.dailyReport.agentEffort ?? "" },
                  set: { model.setDailyReportAgentEffort($0) }
                )) {
                  Text("Default").tag("")
                  ForEach(AppConfiguration.agentEffortLevels(for: sweepProvider), id: \.self) { effort in
                    Text(effort).tag(effort)
                  }
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
              }.buttonStyle(.borderedProminent).disabled(model.reportIsRunning)

              DisclosureGroup("Past reports and logs") {
                DailyReportHistoryView(snapshot: model.reportHistory) { report in
                  model.selectHistoricalReport(report)
                }.padding(.top, 10)
              }.task { await model.reloadReportHistory() }

              if model.reportIsRunning {
                HStack(spacing: 8) {
                  ProgressView().controlSize(.small)
                  Text("Checking enabled platforms…")
                  Spacer()
                  Button(
                    model.isDailyReportCancellationRequested ? "Cancelling…" : "Cancel",
                    action: model.cancelDailyReport
                  )
                  .buttonStyle(.bordered)
                  .disabled(model.isDailyReportCancellationRequested)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
              } else if let message = model.dailyReportRunMessage {
                Text(message).font(.system(size: 12))
                  .foregroundStyle(model.dailyReportRunFailed ? Color.orange : Color.secondary)
              }
            }
          }

          if focusedSection != .connectors { connectorDiagnosticsSection }

          groupHeading("Tools")
          settingsSection(
            title: "Diagnostics",
            detail: "Inspect token use and live app activity, or open the configuration file for options that have no control here."
          ) {
            VStack(alignment: .leading, spacing: 12) {
              Button(action: openAnalytics) {
                Label("Token analytics", systemImage: "chart.bar.xaxis")
              }
              .buttonStyle(.bordered)
              .help("Local prompt and agent token measurements")
              settingToggle(
                "Show Program Log window",
                detail: "A separate live debugging window. Its contents start fresh each time Focus Queue launches.",
                isOn: Binding(
                  get: { model.isProgramLogWindowVisible },
                  set: { model.setProgramLogWindowVisible($0) }))
              Button("Open advanced configuration", systemImage: "doc.badge.gearshape") {
                model.openConfiguration()
              }.buttonStyle(.bordered)
            }
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

  private var connectorDiagnosticsSection: some View {
    settingsSection(
      title: "Connector diagnostics",
      detail:
        "Check each report platform's local setup without reading messages. Authentication and live access are not tested."
    ) {
      VStack(alignment: .leading, spacing: 10) {
        if model.reportHasFailure {
          Label(model.reportAttentionMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(
              horizontal: false, vertical: true)
        }

        Button(
          model.connectorDiagnostics == nil ? "Check connector setup" : "Check again",
          systemImage: "stethoscope"
        ) {
          model.runConnectorDiagnostics()
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isDiagnosingConnectors)

        if model.isDiagnosingConnectors {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking local connector configuration…")
          }.font(.system(size: 12)).foregroundStyle(.secondary)
        }

        if let error = model.connectorDiagnosticsError {
          Label(error, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(
              horizontal: false, vertical: true)
        }

        if let snapshot = model.connectorDiagnostics {
          if snapshot.configurationPresent == false {
            Label("No ingestion.json yet, so every source needs setup. Each row lists its next step.",
              systemImage: "info.circle")
              .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Create ingestion.json", systemImage: "doc.badge.plus") {
              if model.createStarterIngestionConfiguration() { model.runConnectorDiagnostics() }
            }
            .buttonStyle(.bordered)
            .help("Write a starter file with your dashboard and blank source settings")
          }
          VStack(spacing: 8) {
            ForEach(DailyReportPlatform.allCases) { platform in
              ConnectorDiagnosticRow(
                platform: platform,
                diagnostic: snapshot.diagnostic(for: platform)
              )
            }
          }
          if let checkedAt = model.connectorDiagnosticsCheckedAt {
            Text("Checked \(checkedAt.formatted(date: .omitted, time: .shortened)) · configuration only")
              .font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }

        if !model.reportHistory.standardError.isEmpty {
          DisclosureGroup("Latest report error log") {
            Text(model.reportHistory.standardError)
              .font(.system(size: 10, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 7)
          }
          .font(.system(size: 12, weight: .semibold))
        }
      }
    }
    .id(QueueSettingsTarget.connectors)
  }

  private func groupHeading(_ title: String) -> some View {
    Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.7)
      .foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 6)
      .accessibilityAddTraits(.isHeader)
  }

  /// A toggle with its explanation underneath, for cards that hold several toggles.
  private func settingToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Toggle(title, isOn: isOn)
      Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func hotkeyRow(_ action: HotkeyAction, detail: String, isOn: Binding<Bool>) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Toggle(action.title, isOn: isOn)
        Spacer()
        HotkeyRecorderField(model: model, action: action).disabled(!isOn.wrappedValue)
      }
      Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func featureBadge(_ text: String) -> some View {
    Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
      .padding(.horizontal, 7).padding(.vertical, 2)
      .background(.primary.opacity(0.07), in: Capsule())
  }

  private func settingsSection<Content: View>(
    title: String, badge: String? = nil, detail: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(spacing: 8) {
        Text(title).font(.system(size: 16, weight: .bold))
        if let badge { featureBadge(badge) }
      }
      Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
      content()
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).notificationSurface(radius: 18)
  }
}

/// Which desktop terminal opens agent panes. The choice applies to the next
/// agent opened; windows already open stay where they are.
private struct TerminalAppSetting: View {
  let model: QueueViewModel
  @State private var installed: Set<ManagedTerminalApp> = []

  private var selected: ManagedTerminalApp { model.config.wezTerm.terminalApp }
  private var hasTmux: Bool {
    (model.config.tmuxExecutable ?? SetupEnvironment.executable("tmux"))
      .map { FileManager.default.isExecutableFile(atPath: $0) } ?? false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Terminal app")
      Picker("Terminal app", selection: Binding(
        get: { selected },
        set: { model.setManagedTerminal($0) }
      )) {
        ForEach(ManagedTerminalApp.allCases) { Text($0.displayName).tag($0) }
      }.pickerStyle(.segmented).labelsHidden()
      Text("\(selected.summary) Your own \(selected.displayName) settings apply. Takes effect the next time you open an agent.")
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if !installed.contains(selected) {
        HStack(spacing: 6) {
          Label("\(selected.displayName) is not installed.", systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
          if let url = selected.downloadURL {
            Link("Get it", destination: url).font(.caption.weight(.semibold))
          }
        }
      } else if selected.requiresTmux && !hasTmux {
        Label("\(selected.displayName) needs tmux. Install it with brew install tmux.",
          systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      }
    }
    .onAppear {
      installed = Set(ManagedTerminalApp.allCases.filter {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil
      })
    }
  }
}

private struct SectionHeading: View {
  let title: String
  let detail: String

  var body: some View {
    HStack {
      Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.7)
      Spacer()
      Text(detail).font(.system(size: 11, weight: .semibold).monospacedDigit())
    }.foregroundStyle(.secondary).modifier(SectionCapsule())
  }
}

private struct SectionCapsule: ViewModifier {
  var isHighlighted = false
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content.padding(.horizontal, 11).frame(height: 27).background(
      QueuePalette.component(for: colorScheme), in: Capsule()
    ).overlay {
      if isHighlighted {
        Capsule().stroke(.tint, lineWidth: 1)
      } else {
        Capsule().stroke(QueuePalette.componentBorder(for: colorScheme), lineWidth: 0.6)
      }
    }
  }
}

/// Today's focus heading with a search icon on the trailing edge, signalling
/// that a click opens task search.
private struct FocusSearchHeading: View {
  let title: String
  let detail: String?

  var body: some View {
    HStack(spacing: 8) {
      Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.7)
      if let detail {
        Text(detail.uppercased()).font(.system(size: 10, weight: .semibold).monospacedDigit())
          .tracking(0.5).foregroundStyle(.tertiary)
      }
      Spacer(minLength: 8)
      Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
    }
    .foregroundStyle(.secondary).modifier(SectionCapsule()).contentShape(Capsule())
  }
}

private struct TaskSearchField: View {
  @Binding var query: String
  var isFocused: FocusState<Bool>.Binding
  let prompt: String
  let resultCount: Int?
  let endEditing: () -> Void
  let close: () -> Void

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
      TextField(prompt, text: $query)
        .textFieldStyle(.plain).font(.system(size: 12))
        .focused(isFocused)
        .onKeyPress(.escape) {
          close()
          return .handled
        }
        .accessibilityLabel("Search tasks")
        .help("Type words, a code such as FOC-018 or 18, a status such as backlog, or a priority such as high. status: and priority: accept part of a value.")
      if let resultCount {
        Text("\(resultCount)").font(.system(size: 11, weight: .semibold).monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityLabel("\(resultCount) matching \(resultCount == 1 ? "task" : "tasks")")
      }
      Button(action: close) { Image(systemName: "xmark.circle.fill") }
        .buttonStyle(.plain).foregroundStyle(.tertiary)
        .accessibilityLabel("Close search")
        .help("Close search (Esc)")
    }
    .modifier(SectionCapsule(isHighlighted: isFocused.wrappedValue))
    .background(OutsideClickMonitor(isActive: isFocused.wrappedValue, onOutsideClick: endEditing))
  }
}

/// While active, reports clicks that land outside this view and the window
/// losing key status. AppKit keeps a text field's cursor through clicks on
/// non-editable content, so the search field needs this to end editing.
struct OutsideClickMonitor: NSViewRepresentable {
  let isActive: Bool
  let onOutsideClick: () -> Void

  func makeNSView(context: Context) -> MonitorView { MonitorView() }

  func updateNSView(_ view: MonitorView, context: Context) {
    view.onOutsideClick = onOutsideClick
    view.isActive = isActive
  }

  final class MonitorView: NSView {
    var onOutsideClick: () -> Void = {}
    var isActive = false {
      didSet { if isActive != oldValue { refresh() } }
    }
    private var clickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    var isMonitoring: Bool { clickMonitor != nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      refresh()
    }

    /// Observation only: clicks pass through to the field and its buttons.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func refresh() {
      stop()
      guard isActive, let window else { return }
      clickMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
      ) { [weak self] event in
        MainActor.assumeIsolated { self?.handleClick(at: event.locationInWindow, in: event.window) }
        return event
      }
      resignObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.onOutsideClick() }
      }
    }

    func handleClick(at locationInWindow: NSPoint, in eventWindow: NSWindow?) {
      guard let window, eventWindow === window,
        !bounds.contains(convert(locationInWindow, from: nil)) else { return }
      window.makeFirstResponder(nil)
      onOutsideClick()
    }

    private func stop() {
      if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
      if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
      clickMonitor = nil
      resignObserver = nil
    }
  }
}

/// Reuses the word index until the task list changes and the last result
/// until the query changes, so re-renders between keystrokes cost nothing.
private final class TaskSearchCache {
  private var tickets: [DashboardTicket] = []
  private var index = TaskSearchIndex([])
  private var query: String?
  private var result = TaskSearchResult(tickets: [], match: .none)

  func result(for tickets: [DashboardTicket], query: String) -> TaskSearchResult {
    if tickets != self.tickets {
      self.tickets = tickets
      index = TaskSearchIndex(tickets)
      self.query = nil
    }
    if query != self.query {
      self.query = query
      result = index.search(query)
    }
    return result
  }
}

struct RenamableTaskTitle: View {
  let ticket: DashboardTicket
  let model: QueueViewModel
  let size: CGFloat
  let weight: Font.Weight
  let maximumLines: Int
  var openAction: (() -> Void)? = nil
  var openHint: String? = nil
  var detailsAction: (() -> Void)? = nil
  @State private var isRenaming = false
  @State private var draft = ""

  var body: some View {
    Text(ticket.title)
      .font(.system(size: size, weight: weight))
      .lineLimit(maximumLines)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .onTapGesture { openAction?() }
      .highPriorityGesture(TapGesture(count: 2).onEnded { beginRename() })
      .contextMenu {
        if let detailsAction {
          Button("View details", systemImage: "info.circle", action: detailsAction)
          Divider()
        }
        Button("Rename task", systemImage: "pencil") { beginRename() }
      }
      .accessibilityAction(named: "Rename task", beginRename)
      .help(openHint ?? (openAction == nil
        ? "Double-click to rename this task"
        : "Click to open this task's terminal. Double-click to rename the task."))
      .alert("Rename task", isPresented: $isRenaming) {
        TextField("Task title", text: $draft)
        Button("Save") {
          Task { _ = await model.renameTask(ticket, to: draft) }
        }
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("The updated title will be used everywhere this task is currently shown.")
      }
  }

  private func beginRename() {
    draft = ticket.title
    isRenaming = true
  }
}

private struct ConnectorDiagnosticRow: View {
  let platform: DailyReportPlatform
  let diagnostic: ConnectorDiagnostic?

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .foregroundStyle(color)
          .frame(width: 18)
        Text(platform.displayName).font(.system(size: 13, weight: .semibold))
        Spacer()
        Text(diagnostic?.statusLabel ?? "Not checked")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(color)
      }
      if let diagnostic {
        Text(diagnostic.nextStep)
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 9)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
  }

  private var color: Color {
    switch diagnostic?.status {
    case "configured_unverified": .blue
    case "limited": .orange
    case "setup_required": .orange
    case .some: .secondary
    case nil: .secondary
    }
  }

  private var icon: String {
    switch platform {
    case .discord: "bubble.left.and.bubble.right"
    case .telegram: "paperplane"
    case .email: "envelope"
    case .github: "chevron.left.forwardslash.chevron.right"
    case .gmail: "envelope.badge"
    case .slack: "number"
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
      }.buttonStyle(.plain).minimumHitTarget().accessibilityLabel(
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
          .buttonStyle(.borderless).minimumHitTarget()
          .accessibilityLabel("Open \(routine.title)").help("Open queue")
      }
    }.padding(.horizontal, 12).padding(.vertical, 5)
  }
}

struct CompletedTicketCard: View {
  let ticket: DashboardTicket
  let model: QueueViewModel

  @Environment(\.queueAccentStyle) private var accentStyle

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      summary
      Button { model.openPlan(for: ticket) } label: {
        Label("Central plan and history", systemImage: "doc.text")
          .font(.system(size: 12, weight: .medium))
          .frame(maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(.plain).padding(.horizontal, 14).padding(.bottom, 12)
        .help("Read the retained plan and conversation for this completed task")
      if model.isExpanded(ticket.id) {
        Divider().opacity(0.45).padding(.horizontal, 14)
        details.padding(.top, 11).transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .notificationSurface(radius: 18)
    .accessibilityElement(children: .contain)
  }

  private var summary: some View {
    HStack(alignment: .top, spacing: 11) {
      VStack(spacing: 1) {
        Image(systemName: statusIcon)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(statusColor)
          .frame(width: 28, height: 30)
          .minimumHitTarget()
          .contentShape(Rectangle())
          .contextMenu {
            Button("Mark as incomplete", systemImage: "arrow.uturn.backward.circle") {
              markIncomplete()
            }
          }
          .accessibilityLabel("Completed task checkbox for \(ticket.id)")
          .accessibilityHint("Right-click to mark this task incomplete and return it to Focus.")
          .accessibilityAction(named: "Mark as incomplete", markIncomplete)

        Menu {
          Button("Mark as incomplete", systemImage: "arrow.uturn.backward.circle") {
            markIncomplete()
          }
        } label: {
          VerticalOverflowIcon()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .minimumHitTarget()
        .accessibilityLabel("More options for completed task \(ticket.id)")
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .top, spacing: 8) {
          RenamableTaskTitle(
            ticket: ticket, model: model, size: 15, weight: .semibold,
            maximumLines: 3, openAction: toggleExpansion,
            openHint: model.isExpanded(ticket.id)
              ? "Hide completed task details" : "Show completed task details")
          Text(ticket.id).font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary).fixedSize()
        }
        if !ticket.summary.isEmpty {
          Button(action: toggleExpansion) {
            Text(ticket.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
          }
          .buttonStyle(.plain)
        }
        if let message = model.closureMessages[ticket.id] {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
          Button("Retry cleanup") { model.retryCleanup(for: ticket) }
            .buttonStyle(.link).font(.system(size: 11))
        }
        Button(action: toggleExpansion) {
          HStack(spacing: 7) {
            StatusPill(text: ticket.status, color: statusColor)
            if ticket.progressLabel.lowercased() != ticket.status.lowercased() {
              Text(ticket.progressLabel).font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Text(ticket.completionDay ?? "Date unavailable")
              .font(.system(size: 11, weight: .medium).monospacedDigit())
              .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: model.isExpanded(ticket.id) ? "chevron.up" : "chevron.down")
              .font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 13).padding(.vertical, 11)
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 10) {
      completionDetails

      if !ticket.summary.isEmpty { DetailBlock(title: "Summary", text: ticket.summary) }
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
                  Button { model.open(evidence, ticketID: ticket.id) } label: {
                    Text(evidenceName(evidence)).font(.system(size: 12)).lineLimit(1)
                  }
                  .buttonStyle(.link)
                  .accessibilityLabel("Open evidence \(evidenceName(evidence))")
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
            Button { model.open(pullRequest.url) } label: {
              HStack(spacing: 6) {
                Image(
                  systemName: pullRequest.isMerged
                    ? "checkmark.arrow.trianglehead.branch" : "arrow.triangle.branch")
                Text("#\(pullRequest.number) \(pullRequest.title)").lineLimit(2)
                Spacer()
                Text(pullRequest.state?.lowercased() ?? "").foregroundStyle(.secondary)
              }.font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open pull request \(pullRequest.number): \(pullRequest.title)")
          }
        }
      }

      if !evidenceLinks.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          DetailLabel(text: "Evidence and links")
          ForEach(evidenceLinks) { link in
            Button { model.open(link.url, ticketID: ticket.id) } label: {
              Label(link.label, systemImage: linkIcon(link.type)).font(.system(size: 13)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).accessibilityLabel("Open \(link.label)")
          }
        }
      }
    }.padding(.horizontal, 14).padding(.bottom, 14)
  }

  private var completionDetails: some View {
    VStack(alignment: .leading, spacing: 5) {
      DetailLabel(text: "Completion")
      completionField(label: "Status", value: ticket.status)
      if let completionDate = ticket.completionDateLabel {
        completionField(label: "Closed", value: completionDate)
      }
      if let reason = ticket.completion?.reason, !reason.isEmpty {
        completionField(label: "Reason", value: reason)
      }
      if let outcome = ticket.completion?.outcome, !outcome.isEmpty {
        completionField(label: "Outcome", value: outcome)
      }
      if let completedBy = ticket.completion?.completedBy, !completedBy.isEmpty {
        completionField(label: "Completed by", value: completedBy)
      }
      if let resolutionPrs = ticket.completion?.resolutionPrs, !resolutionPrs.isEmpty {
        completionField(label: "Resolution PRs", value: resolutionPrs.map { "#\($0)" }.joined(separator: ", "))
      }
      if let evidence = ticket.completion?.evidence, !evidence.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          Text("Completion evidence").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
          ForEach(evidence, id: \.self) { item in
            Button { model.open(item, ticketID: ticket.id) } label: {
              Text(evidenceName(item)).font(.system(size: 12)).lineLimit(1)
            }.buttonStyle(.link).accessibilityLabel("Open completion evidence \(evidenceName(item))")
          }
        }
      }
    }
  }

  private func completionField(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func toggleExpansion() {
    withAnimation(.easeInOut(duration: 0.18)) {
      model.setExpanded(!model.isExpanded(ticket.id), ticketID: ticket.id)
    }
  }

  private func markIncomplete() {
    Task { _ = await model.markTaskIncomplete(ticket) }
  }

  private var statusColor: Color {
    ticket.status.lowercased() == "cancelled"
      ? .secondary
      : QueueAccentPalette.color(.success, style: accentStyle)
  }

  private var statusIcon: String {
    ticket.status.lowercased() == "cancelled" ? "xmark.circle.fill" : "checkmark.circle.fill"
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

  private var evidenceLinks: [DashboardLink] {
    model.taskContexts[ticket.id]?.evidenceLinks(ticket.links) ?? ticket.links
  }

  private func linkIcon(_ type: String?) -> String {
    switch type?.lowercased() {
    case "github": "arrow.triangle.branch"
    case "plan": "doc.text"
    case "file": "folder"
    default: "link"
    }
  }

  private func evidenceName(_ evidence: String) -> String {
    guard let url = ResourceLocator.url(for: evidence), !url.lastPathComponent.isEmpty else {
      return evidence
    }
    return url.lastPathComponent
  }
}

struct SubtaskTitleLabel: View {
  let title: String
  let isExpanded: Bool
  var fontSize: CGFloat = 13

  var body: some View {
    Text(title)
      .font(.system(size: fontSize, weight: .semibold))
      .lineLimit(isExpanded ? nil : 2)
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct SubtaskDisclosureState: Equatable {
  static let defaultExpanded = true
  private var collapsedIDs: Set<String> = []

  func isExpanded(_ subtaskID: String) -> Bool {
    Self.defaultExpanded && !collapsedIDs.contains(subtaskID)
  }

  mutating func toggle(_ subtaskID: String) {
    if collapsedIDs.contains(subtaskID) { collapsedIDs.remove(subtaskID) }
    else { collapsedIDs.insert(subtaskID) }
  }
}

struct SubtaskAgentPresentation: Equatable {
  let agents: [TaskSubtask]

  init(linkedAgents: [TaskSubtask]) {
    agents = linkedAgents.filter(\.isAgentVisible)
  }

  var count: Int { agents.count }
}

private struct SubtaskEditorSheet: View {
  let subtask: TaskSubtask
  let save: (String, String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var explanation: String

  init(subtask: TaskSubtask, save: @escaping (String, String) -> Void) {
    self.subtask = subtask
    self.save = save
    _title = State(initialValue: subtask.title)
    _explanation = State(initialValue: subtask.assignmentDescription.isEmpty
      ? (subtask.initialPrompt ?? "") : subtask.assignmentDescription)
  }

  private var trimmedTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedExplanation: String {
    explanation.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Edit work item").font(.title2.weight(.semibold))
      VStack(alignment: .leading, spacing: 6) {
        Text("Title").font(.headline)
        TextField("Short, readable title", text: $title)
          .accessibilityLabel("Work item title")
        Text("Keep the title brief. Put the complete assignment in the description.")
          .font(.caption).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("Brief work description").font(.headline)
        TextEditor(text: $explanation)
          .font(.body)
          .frame(minHeight: 120)
          .padding(6)
          .overlay(RoundedRectangle(cornerRadius: 7).stroke(.secondary.opacity(0.3)))
          .accessibilityLabel("Work item description")
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          save(trimmedTitle, explanation)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(trimmedTitle.isEmpty || trimmedExplanation.isEmpty)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 500)
  }
}

private struct ArchivedSubtaskRow: View {
  let ticket: DashboardTicket
  let subtask: TaskSubtask
  let model: QueueViewModel
  @State private var isExpanded = SubtaskDisclosureState.defaultExpanded
  @State private var confirmsDeletion = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 7) {
        Button { isExpanded.toggle() } label: {
          HStack(alignment: .top, spacing: 7) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(.secondary)
              .frame(width: 12, height: 18)
            VStack(alignment: .leading, spacing: 3) {
              SubtaskTitleLabel(title: subtask.title, isExpanded: isExpanded, fontSize: 12)
              Text("Completed subtask")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") completed subtask \(subtask.title)")

        Menu {
          Button("Delete subtask…", systemImage: "trash", role: .destructive) {
            confirmsDeletion = true
          }
        } label: {
          VerticalOverflowIcon()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .minimumHitTarget()
        .accessibilityLabel("More options for completed subtask \(subtask.title)")
      }
      if isExpanded {
        Text(subtask.assignmentDescription.isEmpty
          ? (subtask.initialPrompt ?? "No explanation added.") : subtask.assignmentDescription)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
    .padding(9)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    .confirmationDialog(
      "Delete this completed subtask?", isPresented: $confirmsDeletion,
      titleVisibility: .visible
    ) {
      Button("Delete subtask and linked agents", role: .destructive) {
        model.deleteSubtask(subtask, from: ticket)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The archived task context remains available for recovery.")
    }
  }
}

private struct TicketCard: View {
  let ticket: DashboardTicket
  let model: QueueViewModel
  @State private var showsContext = false
  @State private var reorderDropIsTargeted = false
  @State private var cardHeight: CGFloat = 1
  @State private var showsNewAgent = false
  @State private var agentTargetSubtask: TaskSubtask?
  @State private var showsSubtasks = true
  @State private var showsCompletedSubtasks = false
  @State private var subtaskDisclosure = SubtaskDisclosureState()
  @State private var showsAgentCreator = false
  @State private var editingSubtask: TaskSubtask?
  @State private var completingSubtask: TaskSubtask?
  @State private var deletingSubtask: TaskSubtask?
  @State private var isCollapsedToTitle = false
  @State private var showsTaskDetails = false
  @State private var completionPhase = CardCompletionPhase.idle
  @AppStorage("newAgentProvider") private var storedNewAgentProvider: AgentProvider?
  @Environment(\.queueAccentStyle) private var accentStyle
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.walkthroughTicketID) private var walkthroughTicketID

  private var isWalkthroughTicket: Bool { walkthroughTicketID == ticket.id }

  private var newAgentProvider: AgentProvider {
    model.preferredNewAgentProvider(stored: storedNewAgentProvider)
  }

  private var isChecked: Bool { !ticket.isOpen || completionPhase != .idle }
  private var isMinimized: Bool { completionPhase == .minimized }
  private var recurringProgress: RecurringPullRequestProgress? {
    model.recurringPRProgress(for: ticket.id)
  }
  private var recurringProgressError: String? {
    model.recurringPRProgressError(for: ticket.id)
  }

  private var newAgentModelChoices: [AgentModelChoice] {
    let configured = model.config.agentModelChoices
    return configured.isEmpty ? AppConfiguration.defaultAgentModelChoices : configured
  }

  private var newAgentChoiceProviders: [AgentProvider] {
    var providers: [AgentProvider] = []
    for choice in newAgentModelChoices where !providers.contains(choice.provider) {
      providers.append(choice.provider)
    }
    return providers
  }

  @ViewBuilder
  private var newAgentModelMenuContent: some View {
    ForEach(newAgentChoiceProviders, id: \.self) { provider in
      Text(provider.displayName)
        .font(.system(size: 11, weight: .semibold))
        .disabled(true)
      ForEach(newAgentModelChoices.filter { $0.provider == provider }) { choice in
        Button("  \(choice.label)") {
          model.launchDefaultAgent(
            for: ticket, provider: choice.provider, model: choice.model, effort: choice.effort)
        }
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      summary
        .walkthroughAnchor(.taskCard, isEnabled: isWalkthroughTicket)
      if !isCollapsedToTitle {
        taskOverview
        agentControls
        Button(action: toggleCardDisclosure) {
          HStack {
            Text(model.isExpanded(ticket.id) ? "Hide task details" : "Task details")
            Spacer()
            Image(systemName: model.isExpanded(ticket.id) ? "chevron.up" : "chevron.down")
          }.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14)
            .frame(minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(model.isExpanded(ticket.id) ? "Collapse" : "Expand") \(ticket.id) details")
        if model.isExpanded(ticket.id) {
          Divider().opacity(0.45).padding(.horizontal, 14)
          details.padding(.top, 11).transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
    }.notificationSurface(radius: 18)
      .sheet(isPresented: $showsNewAgent) {
        NewTaskAgentView(ticket: ticket, model: model, targetSubtask: agentTargetSubtask)
      }
      .sheet(isPresented: $showsAgentCreator) {
        TaskAgentCreatorSheet(model: model, ticket: ticket)
      }
      .sheet(item: $editingSubtask) { subtask in
        SubtaskEditorSheet(subtask: subtask) { title, explanation in
          model.updateSubtask(
            subtask, for: ticket, title: title, explanation: explanation)
        }
      }
      .confirmationDialog(
        "Mark this work item complete?",
        isPresented: Binding(
          get: { completingSubtask != nil }, set: { if !$0 { completingSubtask = nil } }),
        titleVisibility: .visible
      ) {
        Button("Mark work item complete") {
          if let subtask = completingSubtask { model.overrideCompletion(subtask, for: ticket) }
          completingSubtask = nil
        }
        Button("Cancel", role: .cancel) { completingSubtask = nil }
      } message: {
        Text("The agent's conversation and workspace stay available.")
      }
      .confirmationDialog(
        "Delete this work item?",
        isPresented: Binding(
          get: { deletingSubtask != nil }, set: { if !$0 { deletingSubtask = nil } }),
        titleVisibility: .visible
      ) {
        Button("Delete work item", role: .destructive) {
          if let subtask = deletingSubtask { model.deleteSubtask(subtask, from: ticket) }
          deletingSubtask = nil
        }
        Button("Cancel", role: .cancel) { deletingSubtask = nil }
      } message: {
        Text("The archived task context remains available for recovery.")
      }
      .draggable(ticket.id)
      .background {
        GeometryReader { geometry in
          Color.clear.onAppear { cardHeight = geometry.size.height }
            .onChange(of: geometry.size.height) { _, height in cardHeight = height }
        }
      }
      .dropDestination(for: String.self) { ids, point in
        guard ids.count == 1, let id = ids.first, id != ticket.id else { return false }
        return model.moveTicket(id, to: point.y < cardHeight / 2 ? .before(ticket.id) : .after(ticket.id))
      } isTargeted: { reorderDropIsTargeted = $0 }
      .overlay {
        if reorderDropIsTargeted {
          RoundedRectangle(cornerRadius: 18).stroke(.tint, lineWidth: 2).allowsHitTesting(false)
        }
      }
      .popover(isPresented: $showsTaskDetails, arrowEdge: .trailing) {
        TaskDetailsView(ticket: ticket, model: model) { showsTaskDetails = false }
      }
      .contextMenu { moreOptionsMenuContent }
      .accessibilityAction(named: "View details", openTaskDetails)
      .accessibilityAction(named: "Move up") { moveOnePosition(up: true) }
      .accessibilityAction(named: "Move down") { moveOnePosition(up: false) }
      .accessibilityHint("Drag to reorder. Drop on the upper half of a task to place it before, or the lower half to place it after.")
      // Pinning the measured height first lets the collapse animate from a
      // concrete value; the negative padding absorbs the list's 10 pt spacing.
      .fixedSize(horizontal: false, vertical: completionPhase != .idle)
      .scaleEffect(isMinimized && !reduceMotion ? 0.3 : 1, anchor: .top)
      .opacity(isMinimized ? 0 : 1)
      .frame(height: completionPhase == .idle ? nil : isMinimized ? 0 : cardHeight, alignment: .top)
      .padding(.bottom, isMinimized ? -10 : 0)
      .allowsHitTesting(!isMinimized)
  }

  /// The ••• menu and the card's right-click menu share these actions.
  @ViewBuilder
  private var moreOptionsMenuContent: some View {
    Button("View details", systemImage: "info.circle") { openTaskDetails() }
    Button(
      model.isTicketPinned(ticket.id) ? "Unpin" : "Pin",
      systemImage: model.isTicketPinned(ticket.id) ? "pin.slash" : "pin"
    ) {
      Task { await model.setTicketPinned(ticket, pinned: !model.isTicketPinned(ticket.id)) }
    }
    Divider()
    Button("Mark as complete", systemImage: "checkmark.circle") { completeWithAnimation() }
    .disabled(isChecked)
    Button("Archive without completion", systemImage: "archivebox") {
      Task { _ = await model.archiveWithoutCompletion(ticket) }
    }
    .disabled(!ticket.isOpen)
    Divider()
    Button("Move to top") { model.moveTicket(ticket.id, to: .top) }
    Button("Move up") { moveOnePosition(up: true) }
      .disabled(model.openTickets.first?.id == ticket.id)
    Button("Move down") { moveOnePosition(up: false) }
      .disabled(model.openTickets.last?.id == ticket.id)
    Button("Move to bottom") { model.moveTicket(ticket.id, to: .bottom) }
  }

  /// Holds the green check briefly, then shrinks the card out of the Focus
  /// list while the task resolves. A failed completion restores the card.
  private func completeWithAnimation() {
    guard ticket.isOpen, completionPhase == .idle else { return }
    withAnimation(.spring(duration: 0.3, bounce: 0.4)) { completionPhase = .checked }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(650))
      withAnimation(.easeIn(duration: reduceMotion ? 0.2 : 0.4)) { completionPhase = .minimized }
      if await model.completeTicket(ticket) { return }
      withAnimation(.easeOut(duration: 0.25)) { completionPhase = .idle }
    }
  }

  private func moveOnePosition(up: Bool) {
    let ids = model.openTickets.map(\.id)
    guard let index = ids.firstIndex(of: ticket.id) else { return }
    let target = index + (up ? -1 : 1)
    guard ids.indices.contains(target) else { return }
    model.moveTicket(ticket.id, to: up ? .before(ids[target]) : .after(ids[target]))
  }

  private var summary: some View {
    HStack(alignment: .top, spacing: 11) {
      VStack(spacing: 1) {
        Button(action: completeWithAnimation) {
          Image(systemName: isChecked ? "checkmark.circle.fill" : "circle").font(
            .system(size: 20, weight: .medium)
          ).foregroundStyle(checkColor)
            .contentTransition(.symbolEffect(.replace))
            .scaleEffect(completionPhase == .checked ? 1.15 : 1)
        }.buttonStyle(.plain).disabled(isChecked).minimumHitTarget()
          .accessibilityLabel(isChecked ? "\(ticket.id) is complete" : "Mark \(ticket.id) complete")
          .help("Mark this task complete")
          .walkthroughAnchor(.completeTask, isEnabled: isWalkthroughTicket)

        Button {
          withAnimation(.easeInOut(duration: 0.18)) { isCollapsedToTitle.toggle() }
        } label: {
          Image(systemName: isCollapsedToTitle ? "chevron.right" : "chevron.down")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .minimumHitTarget()
        .accessibilityLabel(isCollapsedToTitle ? "Expand task \(ticket.id)" : "Collapse task \(ticket.id)")
        .accessibilityHint(isCollapsedToTitle
          ? "Expands the task card to show its details."
          : "Collapses the task card to its title and status.")
        .help(isCollapsedToTitle ? "Expand task" : "Collapse task to title only")
      }
      .contextMenu {
        Button("Mark as complete", systemImage: "checkmark.circle") { completeWithAnimation() }
        .disabled(isChecked)
        Button("Archive without completion", systemImage: "archivebox") {
          Task { _ = await model.archiveWithoutCompletion(ticket) }
        }
        .disabled(!ticket.isOpen)
      }

      VStack(alignment: .leading, spacing: 7) {
        HStack(alignment: .top, spacing: 10) {
          HStack(alignment: .firstTextBaseline, spacing: 5) {
            RenamableTaskTitle(
              ticket: ticket, model: model, size: 16, weight: .semibold,
              maximumLines: 3,
              openAction: { model.openTaskAgents(for: ticket) },
              openHint: "Click to open this task's terminal. Double-click to rename the task.",
              detailsAction: openTaskDetails)
            if model.isNewTicket(ticket.id) { NewTaskBadge() }
            if isCollapsedToTitle, !model.newOutputs(for: ticket.id).isEmpty {
              NewOutputsBadge(count: model.newOutputs(for: ticket.id).count)
            }
          }
          VStack(alignment: .trailing, spacing: 1) {
            Menu { moreOptionsMenuContent } label: {
              Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 20)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More options for \(ticket.id)")
            .help("View details, complete, archive, pin, or move this task")
            Text(ticket.id).font(.system(size: 12, weight: .bold, design: .monospaced))
              .foregroundStyle(priorityColor).fixedSize()
          }
        }
        HStack(spacing: 6) {
          if recurringProgress?.openCount == 0 {
            StatusPill(text: "No open PRs", color: .secondary)
          } else {
            Menu {
              ForEach(TaskFieldChoices.priorities, id: \.self) { priority in
                Button {
                  Task { await model.setTaskPriority(ticket, to: priority) }
                } label: {
                  if ticket.priority.caseInsensitiveCompare(priority) == .orderedSame {
                    Label(priority.capitalized, systemImage: "checkmark")
                  } else {
                    Text(priority.capitalized)
                  }
                }
              }
            } label: {
              StatusPill(text: ticket.priority, color: priorityColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Priority: \(ticket.priority)")
            .help("Change task priority")
          }
          if ticket.isOpen {
            Menu {
              ForEach(TaskFieldChoices.statusOptions(current: ticket.status), id: \.self) { status in
                Button {
                  Task { await model.setTaskStatus(ticket, to: status) }
                } label: {
                  if TaskFieldChoices.normalizedStatus(ticket.status) == status {
                    Label(TaskFieldChoices.statusLabel(status), systemImage: "checkmark")
                  } else {
                    Text(TaskFieldChoices.statusLabel(status))
                  }
                }
              }
            } label: {
              StatusPill(text: TaskFieldChoices.statusLabel(ticket.status), color: statusColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Status: \(TaskFieldChoices.statusLabel(ticket.status))")
            .help("Change task status")
          } else {
            StatusPill(text: ticket.status, color: statusColor)
          }
          if ticket.isRecurringPullRequestTask {
            StatusPill(
              text: "Recurring daily",
              color: QueueAccentPalette.color(.info, style: accentStyle)
            )
          }
          if TaskTriagePolicy.hasHardDeadline(ticket) { TaskDeadlinePill(ticket: ticket) }
        }
        if !isCollapsedToTitle, !ticket.briefSummary.isEmpty {
          Text(ticket.briefSummary).font(.system(size: 13)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([
          ticket.title,
          model.isNewTicket(ticket.id) ? "New unviewed task" : nil,
          ticket.id,
          TaskTriagePolicy.hasHardDeadline(ticket) ? "Hard due date \(ticket.dueDate ?? "")" : nil,
        ].compactMap { $0 }.joined(separator: ", "))
    }.padding(.horizontal, 13).padding(.vertical, 11)
  }

  private func toggleCardDisclosure() {
    withAnimation(.easeInOut(duration: 0.18)) {
      model.setExpanded(!model.isExpanded(ticket.id), ticketID: ticket.id)
    }
  }

  private func openTaskDetails() {
    model.markTicketViewed(ticket.id)
    showsTaskDetails = true
  }

  private var agentControls: some View {
    VStack(alignment: .leading, spacing: 7) {
      let items = model.taskItems(for: ticket.id)
      // An unseen result stays a work item; seeing it moves the item to Completed.
      let activeItems = items.filter { !model.isCompletionSeen($0, ticketID: ticket.id) }
      let completedItems = items.filter { model.isCompletionSeen($0, ticketID: ticket.id) }
      let archivedAgents = model.archivedAgents(for: ticket.id)

      DisclosureGroup(isExpanded: $showsSubtasks) {
        ForEach(activeItems) { item in taskItemRow(item) }
        if activeItems.isEmpty {
          Text("No active agents").font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !completedItems.isEmpty {
          DisclosureGroup(
            "Completed agents (\(completedItems.count))",
            isExpanded: $showsCompletedSubtasks
          ) {
            ForEach(completedItems) { item in taskItemRow(item) }
          }
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .padding(.top, 4)
        }
        HStack(spacing: 4) {
          Button("New Agent", systemImage: "person.badge.plus") {
            model.launchDefaultAgent(for: ticket, provider: newAgentProvider)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(ticket.isCompleted || model.launchingTaskIDs.contains(ticket.id))
          .help("Start \(newAgentProvider.displayName) now in a new isolated worktree and this task's shared tmux session")
          Button { showsAgentCreator = true } label: {
            Image(systemName: "chevron.down")
              .font(.system(size: 10, weight: .bold))
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(ticket.isCompleted || model.launchingTaskIDs.contains(ticket.id))
          .accessibilityLabel("New agent options")
          .help("Write a prompt and choose the provider, model, and workspace for the new agent")
        }
        .padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { newAgentModelMenuContent }
      } label: {
        HStack {
          Text("Agents (\(activeItems.count))")
          Spacer()
          let tracked = items.filter(\.tracksCompletion)
          if !tracked.isEmpty {
            Text("\(completedItems.filter(\.tracksCompletion).count)/\(tracked.count) done")
              .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
          }
        }
      }
      .font(.system(size: 12, weight: .semibold))
      .contextMenu {
        Menu {
          if archivedAgents.isEmpty {
            Button("No archived agents") {}
              .disabled(true)
          } else {
            ForEach(archivedAgents) { agent in
              Button("Restore and open \(agent.title)", systemImage: "arrow.uturn.backward.circle") {
                model.openSubtask(agent, for: ticket, showResult: false)
              }
            }
          }
        } label: {
          Label("Archived agents (\(archivedAgents.count))", systemImage: "archivebox")
        }
      }
      .help("Right-click to restore archived agents")

      if let message = model.actionMessages[ticket.id] {
        if model.agentSessionIssue(for: ticket.id) != nil {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11)).foregroundStyle(
              QueueAccentPalette.color(.danger, style: accentStyle)
            )
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } else {
          Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
      }
      if let message = model.closureMessages[ticket.id] {
        Text(message).font(.system(size: 12)).foregroundStyle(.orange)
        Button("Review cleanup") { model.retryCleanup(for: ticket) }.buttonStyle(.link)
      }
    }.controlSize(.regular)
    .padding(.horizontal, 14).padding(.bottom, 10)
  }

  @ViewBuilder
  private func taskItemRow(_ item: TaskSubtask) -> some View {
    if item.hasAgent {
      TaskAgentRow(agent: item, ticket: ticket, model: model)
        .id("work-item-\(ticket.id)-\(item.id)")
    } else {
      subtaskRow(item).id("work-item-\(ticket.id)-\(item.id)")
    }
  }

  private var taskOverview: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 6) {
        Button { model.openPlan(for: ticket) } label: {
          Label("View Central Plan", systemImage: "doc.text")
            .frame(maxWidth: .infinity)
        }
        .help("Read or edit the central plan alongside the task orchestrator")
        Button { showsContext.toggle() } label: {
          Label("View Context", systemImage: "folder")
            .frame(maxWidth: .infinity)
        }
        .help("Preview this task's files, evidence, and links")
        .popover(isPresented: $showsContext, arrowEdge: .trailing) {
          TaskContextGridView(ticket: ticket, model: model) { showsContext = false }
            .frame(width: 360, height: 460)
        }
      }
      .buttonStyle(.bordered).controlSize(.regular)
      .font(.system(size: 12, weight: .semibold))
      .walkthroughAnchor(.planAndContext, isEnabled: isWalkthroughTicket)
      let newOutputs = model.newOutputs(for: ticket.id)
      if !newOutputs.isEmpty {
        NewOutputsPanel(ticketID: ticket.id, outputs: newOutputs, model: model) { showsContext = true }
      }
      if ticket.isRecurringPullRequestTask {
        RecurringPRProgressSummary(progress: recurringProgress, error: recurringProgressError)
      }
    }.padding(.horizontal, 14).padding(.bottom, 10)
  }

  private func subtaskRow(_ subtask: TaskSubtask) -> some View {
    let isExpanded = subtaskDisclosure.isExpanded(subtask.id)
    let rawExplanation: String? = subtask.assignmentDescription.isEmpty
      ? subtask.initialPrompt : subtask.assignmentDescription
    let explanation = rawExplanation?.trimmingCharacters(in: .whitespacesAndNewlines)
    return VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .top, spacing: 7) {
        Button {
          subtaskDisclosure.toggle(subtask.id)
        } label: {
          HStack(alignment: .top, spacing: 7) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(.secondary)
              .frame(width: 12, height: 18)
            VStack(alignment: .leading, spacing: 3) {
              SubtaskTitleLabel(title: subtask.title, isExpanded: isExpanded)
              Text("\(subtask.status.rawValue.capitalized) · Ready to start")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") work item \(subtask.title)")

        Menu {
          Button("Edit title and description", systemImage: "pencil") {
            Task { @MainActor in
              try? await Task.sleep(for: .milliseconds(100))
              editingSubtask = subtask
            }
          }
          if subtask.status != .completed {
            Button("Start agent", systemImage: "person.badge.plus") {
              agentTargetSubtask = subtask
              showsNewAgent = true
            }
            Button("Review completion", systemImage: "checkmark.seal") {
              model.requestSubtaskCompletion(subtask, for: ticket)
            }
            Button("Mark as complete…", systemImage: "checkmark.circle") {
              completingSubtask = subtask
            }
          }
          Divider()
          Button("Delete work item…", systemImage: "trash", role: .destructive) {
            deletingSubtask = subtask
          }
        } label: {
          VerticalOverflowIcon()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .minimumHitTarget()
        .accessibilityLabel("More options for work item \(subtask.title)")
        .help("Edit, complete, start an agent, or delete this work item")
      }

      if isExpanded {
        if let explanation, !explanation.isEmpty, explanation != subtask.title {
          Text(explanation)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        } else {
          Text("No explanation added.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        if subtask.status != .completed {
          Button("Start agent", systemImage: "person.badge.plus") {
            agentTargetSubtask = subtask
            showsNewAgent = true
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(model.launchingTaskIDs.contains(ticket.id) || ticket.isCompleted)
        }
      }
    }
    .padding(9)
    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
    .padding(.vertical, 2)
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 10) {
      if ticket.isRecurringPullRequestTask {
        RecurringPRResolutionDetails(
          progress: recurringProgress,
          error: recurringProgressError,
          open: { model.open($0, ticketID: ticket.id) }
        )
      }
      if !ticket.summary.isEmpty {
        DetailBlock(title: "Description", text: ticket.summary)
      }
      if let next = ticket.next, !next.isEmpty { DetailBlock(title: "Next", text: next) }
      if let doneWhen = ticket.doneWhen, !doneWhen.isEmpty {
        DetailBlock(title: "Done when", text: doneWhen)
      }

      DisclosureGroup("Work item history") {
        ForEach(model.focusSubtasks(for: ticket.id).filter(\.tracksCompletion)) { subtask in
          VStack(alignment: .leading, spacing: 5) {
            Text("\(subtask.title) · \(subtask.status.rawValue)")
            if let workspace = subtask.workspace {
              Text("\(workspace.path) · \(workspace.branch ?? "unknown branch")").font(.caption).textSelection(.enabled)
            }
            if subtask.status != .completed {
              HStack {
                if !subtask.isAssignmentOnly {
                  Button("Open agent") { model.openSubtask(subtask, for: ticket) }
                }
                Button("Override: mark complete") { model.overrideCompletion(subtask, for: ticket) }
              }
            }
          }.padding(.vertical, 4)
        }
      }

      if let maintenance = model.maintenanceReceipts[ticket.id] {
        DisclosureGroup("Tracking and workspace checks") {
          ForEach(maintenance.notes, id: \.self) { Text($0).font(.caption) }
          ForEach(model.subtasks(for: ticket.id).filter { !$0.isAssignmentOnly }) { agent in
            VStack(alignment: .leading, spacing: 3) {
              Text(agent.title.isEmpty ? "Agent awaiting details" : agent.title).font(.caption.bold())
              Text(maintenance.agentStates[agent.id] ?? "Tracking details pending.").font(.caption)
              Text(agent.workspace?.path ?? "Workspace not recorded yet.").font(.caption).textSelection(.enabled)
            }
          }
        }
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
                    model.open(evidence, ticketID: ticket.id)
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

      if !evidenceLinks.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          DetailLabel(text: "Evidence and links")
          ForEach(evidenceLinks) { link in
            Button {
              model.open(link.url, ticketID: ticket.id)
            } label: {
              Label(link.label, systemImage: linkIcon(link.type)).font(.system(size: 13)).lineLimit(
                2
              ).frame(
                maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).accessibilityLabel("Open \(link.label)")
          }
        }
      }

      if let message = model.actionMessages[ticket.id] {
        Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
      }

    }.padding(.horizontal, 14).padding(.bottom, 14)
  }

  private var checkColor: Color {
    isChecked ? QueueAccentPalette.color(.success, style: accentStyle) : .secondary
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

  private var statusColor: Color {
    switch ticket.status.lowercased() {
    case "blocked": QueueAccentPalette.color(.danger, style: accentStyle)
    case "in-progress": QueueAccentPalette.color(.info, style: accentStyle)
    case "testing", "review", "qa-in-progress", "qa", "draft-pr":
      QueueAccentPalette.color(.warning, style: accentStyle)
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

  private var evidenceLinks: [DashboardLink] {
    model.taskContexts[ticket.id]?.evidenceLinks(ticket.links) ?? ticket.links
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

private struct AgentRowLabel: View {
  let agent: TaskSubtask
  let ticket: DashboardTicket
  let model: QueueViewModel
  let isOpening: Bool
  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      if isOpening {
        ProgressView().controlSize(.mini).frame(width: 20, height: 20)
      } else {
        agent.provider.iconImage(size: 13)
          .frame(width: 24, height: 24)
          .foregroundStyle(.primary)
          .background(Color.primary.opacity(0.08), in: Circle())
      }
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          Text(agent.title)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(2)
          Spacer(minLength: 3)
          AgentStatusCluster(
            status: model.effectiveStatus(for: agent),
            hasUnreadCompletion: agent.completionUnread,
            isOpening: isOpening,
            issue: model.agentSessionError(for: agent, ticketID: ticket.id),
            attention: agent.attention,
            lastOutputAt: AgentOutputTimestamp.value(for: agent),
            pausedAt: agent.isPaused ? agent.pausedAt : nil)
        }
        Text(agent.workDescription)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(2)
        if let progressSummary {
          Text(progressSummary)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    }
  }

  private var progressSummary: String? {
    let summary = agent.progressSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !summary.isEmpty,
      summary.localizedCaseInsensitiveCompare(agent.workDescription) != .orderedSame
    else { return nil }
    return summary
  }
}

/// One agent in a task card: status, title, and progress, with an overflow
/// menu. Shared by the task card and the Agent view's task cards.
private struct TaskAgentRow: View {
  let agent: TaskSubtask
  let ticket: DashboardTicket
  let model: QueueViewModel
  @State private var isEditing = false
  @State private var isConfirmingCompletion = false
  @State private var isConfirmingArchive = false

  private var isOpening: Bool { model.isOpening(agent, ticketID: ticket.id) }

  var body: some View {
    HStack(spacing: 7) {
      Button { model.openSubtask(agent, for: ticket) } label: {
        AgentRowLabel(agent: agent, ticket: ticket, model: model, isOpening: isOpening)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isOpening)
      .accessibilityLabel(
        isOpening
          ? "Finding and opening \(agent.title)"
          : "Open \(agent.title), \(agent.attention?.label ?? model.effectiveStatus(for: agent).rawValue)"
      )
      .help("Focus or resume this agent in its saved workspace")

      if model.canPause(agent) {
        AgentPauseButton(
          agent: agent, isChanging: model.isChangingPause(agent, ticketID: ticket.id),
          pause: { model.pauseAgent(agent, for: ticket) },
          resume: { model.resumeAgent(agent, for: ticket) })
        .disabled(isOpening)
      }

      Menu {
        Button("Open agent", systemImage: "terminal") {
          model.openSubtask(agent, for: ticket)
        }
        .disabled(isOpening)
        Button("Edit title and description", systemImage: "pencil") {
          isEditing = true
        }
        if agent.status != .completed {
          Button("Mark as complete…", systemImage: "checkmark.circle") {
            isConfirmingCompletion = true
          }
        }
        Button("View deployment logs", systemImage: "doc.text.magnifyingglass") {
          model.openLaunchDiagnostics(for: agent)
        }
        .disabled(!model.hasLaunchDiagnostics(for: agent))
        Divider()
        Button("Archive agent…", systemImage: "archivebox") {
          isConfirmingArchive = true
        }
      } label: {
        VerticalOverflowIcon()
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .minimumHitTarget()
      .accessibilityLabel("More options for agent \(agent.title)")
      .help("Open, edit, complete, inspect, or archive this agent")
    }
    .padding(9)
    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
    }
    .padding(.vertical, 2)
    .sheet(isPresented: $isEditing) {
      SubtaskEditorSheet(subtask: agent) { title, explanation in
        model.updateSubtask(agent, for: ticket, title: title, explanation: explanation)
      }
    }
    .confirmationDialog(
      "Mark this agent complete?", isPresented: $isConfirmingCompletion, titleVisibility: .visible
    ) {
      Button("Mark agent complete") { model.overrideCompletion(agent, for: ticket) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This changes only the selected agent record.")
    }
    .confirmationDialog(
      "Archive this agent?", isPresented: $isConfirmingArchive, titleVisibility: .visible
    ) {
      Button("Archive agent") { model.archiveAgent(agent, from: ticket) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The live pane will close. The work item, conversation, and workspace stay available under Archived agents.")
    }
  }
}

/// Pause stops the agent's running turn with Esc; Resume asks the same
/// conversation to continue. Both act on the agent's managed tmux pane.
private struct AgentPauseButton: View {
  let agent: TaskSubtask
  let isChanging: Bool
  let pause: () -> Void
  let resume: () -> Void

  var body: some View {
    Button { agent.isPaused ? resume() : pause() } label: {
      Group {
        if isChanging {
          ProgressView().controlSize(.mini)
        } else {
          Image(systemName: agent.isPaused ? "play.fill" : "pause.fill")
            .font(.system(size: 11, weight: .semibold))
        }
      }
      .frame(width: 22, height: 22)
      .background(Color.primary.opacity(0.08), in: Circle())
    }
    .buttonStyle(.plain)
    .minimumHitTarget()
    .disabled(isChanging)
    .accessibilityLabel(agent.isPaused ? "Resume agent \(agent.title)" : "Pause agent \(agent.title)")
    .help(agent.isPaused
      ? "Resume: ask this agent to continue where it stopped, in the same conversation"
      : "Pause: stop this agent's current turn (Esc) and keep its conversation open for Resume")
  }
}

/// The Agent view's task card: the task card's frame holding only the task
/// title and its agents.
private struct AgentTaskCard: View {
  let ticket: DashboardTicket
  let agents: [TaskSubtask]
  let model: QueueViewModel
  @State private var showsLinks = false
  @AppStorage("newAgentProvider") private var storedNewAgentProvider: AgentProvider?

  private var newAgentProvider: AgentProvider {
    model.preferredNewAgentProvider(stored: storedNewAgentProvider)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 8) {
        RenamableTaskTitle(
          ticket: ticket, model: model, size: 16, weight: .semibold,
          maximumLines: 3,
          openAction: { model.openTaskAgents(for: ticket) },
          openHint: "Click to open this task's terminal. Double-click to rename the task.")
        Menu {
          Button("View Central Plan", systemImage: "doc.text") { model.openPlan(for: ticket) }
          Button("View Context", systemImage: "folder") { showsLinks = true }
          Button("New Agent", systemImage: "person.badge.plus") {
            model.launchDefaultAgent(for: ticket, provider: newAgentProvider)
          }
          .disabled(model.launchingTaskIDs.contains(ticket.id) || ticket.isCompleted)
        } label: {
          VerticalOverflowIcon()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .minimumHitTarget()
        .accessibilityLabel("More options for task \(ticket.id)")
        .help("Open the plan or context, or start a new agent")
      }
      .padding(.horizontal, 13).padding(.top, 11).padding(.bottom, 7)

      VStack(alignment: .leading, spacing: 0) {
        ForEach(agents) { agent in
          TaskAgentRow(agent: agent, ticket: ticket, model: model)
        }
      }
      .padding(.horizontal, 14).padding(.bottom, 10)
    }
    .notificationSurface(radius: 18)
    .popover(isPresented: $showsLinks, arrowEdge: .trailing) {
      TaskContextGridView(ticket: ticket, model: model) { showsLinks = false }
        .frame(width: 360, height: 460)
    }
  }
}

struct AgentStatusIndicator: View {
  let status: TaskSubtaskStatus
  let hasUnreadCompletion: Bool
  let isOpening: Bool
  let issue: String?
  var attention: AgentAttention? = nil
  var pausedAt: Date? = nil

  @Environment(\.queueAccentStyle) private var accentStyle

  var body: some View {
    HStack(spacing: 5) {
      if isOpening {
        ProgressView().controlSize(.mini)
      } else {
        Image(systemName: icon)
      }
      Text(statusLabel)
    }
    .font(.system(size: 10, weight: .semibold))
    .foregroundStyle(color)
    .padding(.horizontal, 7).padding(.vertical, 4)
    .background(color.opacity(0.12), in: Capsule())
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Agent status: \(statusLabel)")
    .help(issue ?? helpText)
  }

  private var statusLabel: String {
    if isOpening { return "Opening" }
    if issue != nil { return "Problem" }
    if pausedAt != nil { return "Paused" }
    if let attention { return attention.label }
    if status == .blocked { return "Problem" }
    // A busy agent reads as Working; an earlier unread result is only noted.
    if status == .working { return hasUnreadCompletion ? "Working · New" : "Working" }
    if hasUnreadCompletion { return "New result" }
    switch status {
    case .working: return "Working"
    case .completed: return "Done"
    case .queued: return "Queued"
    case .idle: return "No recent update"
    case .blocked: return "Issue"
    }
  }

  private var icon: String {
    if issue != nil { return "exclamationmark.circle.fill" }
    if pausedAt != nil { return "pause.circle.fill" }
    if let attention { return attention.icon }
    if status == .blocked { return "exclamationmark.circle.fill" }
    if hasUnreadCompletion && status != .working { return "circle.fill" }
    switch status {
    case .working: return "circle.fill"
    case .completed: return "checkmark.circle"
    case .queued: return "clock"
    case .idle: return "minus.circle"
    case .blocked: return "exclamationmark.circle.fill"
    }
  }

  private var color: Color {
    if isOpening { return QueueAccentPalette.color(.info, style: accentStyle) }
    if issue != nil { return QueueAccentPalette.color(.danger, style: accentStyle) }
    if pausedAt != nil { return QueueAccentPalette.color(.info, style: accentStyle) }
    if attention?.isProblem == true {
      return QueueAccentPalette.color(.danger, style: accentStyle)
    }
    if attention != nil { return QueueAccentPalette.color(.warning, style: accentStyle) }
    if hasUnreadCompletion && status != .working { return QueueAccentPalette.color(.success, style: accentStyle) }
    if status == .blocked { return QueueAccentPalette.color(.danger, style: accentStyle) }
    switch status {
    case .working: return QueueAccentPalette.color(.warning, style: accentStyle)
    case .completed:
      return hasUnreadCompletion
        ? QueueAccentPalette.color(.success, style: accentStyle)
        : .secondary
    case .queued, .idle: return .secondary
    case .blocked: return QueueAccentPalette.color(.danger, style: accentStyle)
    }
  }

  private var helpText: String {
    if let pausedAt {
      return "Paused \(AgentOutputAgeFormatter.string(from: pausedAt, relativeTo: Date())). "
        + "The conversation stays open in its pane. Provider prompt caches expire after minutes to about an hour, "
        + "so the first turn after a longer pause re-reads the conversation at full input cost."
    }
    switch status {
    case .working:
      return hasUnreadCompletion
        ? "The agent is working again. Its earlier result has not been opened here."
        : "The agent's transcript or progress reports show it is mid-turn."
    case .completed:
      return hasUnreadCompletion
        ? "The agent finished and has output to review. Opening it moves it to Completed items."
        : "The agent finished and its output has been viewed."
    case .queued: return "The agent is waiting to start."
    case .idle: return "The agent is waiting for input, or its transcript has gone quiet."
    case .blocked: return "The agent reported a blocker or session problem."
    }
  }
}

struct AgentStatusCluster: View {
  let status: TaskSubtaskStatus
  let hasUnreadCompletion: Bool
  let isOpening: Bool
  let issue: String?
  var attention: AgentAttention? = nil
  var lastOutputAt: Date? = nil
  var pausedAt: Date? = nil

  var body: some View {
    HStack(spacing: 8) {
      AgentStatusIndicator(
        status: status,
        hasUnreadCompletion: hasUnreadCompletion,
        isOpening: isOpening,
        issue: issue,
        attention: attention,
        pausedAt: pausedAt)
      if let lastOutputAt {
        AgentOutputAgeLabel(outputAt: lastOutputAt)
      }
    }
    .fixedSize()
  }
}

struct AgentOutputAgeLabel: View {
  let outputAt: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { timeline in
      Text(AgentOutputAgeFormatter.string(from: outputAt, relativeTo: timeline.date))
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        .fixedSize()
        .accessibilityLabel(
          "Last output \(AgentOutputAgeFormatter.string(from: outputAt, relativeTo: timeline.date))")
    }
  }
}

enum AgentOutputAgeFormatter {
  static func string(from outputAt: Date, relativeTo now: Date) -> String {
    let elapsed = max(0, now.timeIntervalSince(outputAt))
    if elapsed < 60 { return "now" }
    if elapsed < 3_600 { return "\(max(1, Int(elapsed / 60)))m ago" }
    if elapsed < 86_400 {
      let tenths = Int((elapsed / 360).rounded())
      let hours = tenths / 10
      let remainder = tenths % 10
      return remainder == 0 ? "\(hours)h ago" : "\(hours).\(remainder)h ago"
    }
    let days = max(1, Int(elapsed / 86_400))
    return "\(days) \(days == 1 ? "day" : "days") ago"
  }
}

enum AgentOutputTimestamp {
  static func value(for agent: TaskSubtask) -> Date? {
    agent.lastOutputAt ?? agent.resultAt
  }
}

struct VerticalOverflowIcon: View {
  var body: some View {
    Image(systemName: "ellipsis")
      .symbolRenderingMode(.monochrome)
      .font(.system(size: 16, weight: .bold))
      .foregroundStyle(Color.white)
      .rotationEffect(.degrees(90))
      .frame(width: 20, height: 24)
      .compositingGroup()
      .shadow(color: .black.opacity(0.55), radius: 0.75, y: 0.5)
      .zIndex(10)
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

  @State private var confirmingClear = false

  private var attachedAgents: [TaskAgentSession] {
    model.visibleAgents(for: ticket.id).compactMap { model.session(for: $0, ticketID: ticket.id) }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 9) {
        Image(systemName: "person.crop.circle.badge.checkmark").font(
          .system(size: 16, weight: .semibold))
        VStack(alignment: .leading, spacing: 2) {
          Text("Agent sessions").font(.system(size: 16, weight: .bold))
          Text("Focus Queue managed sessions for \(ticket.id)")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Remove all") { confirmingClear = true }
          .buttonStyle(.bordered).controlSize(.small)
          .help("Remove current agents while retaining their subtasks and history")
        Button {
          onClose()
        } label: {
          Image(systemName: "xmark")
        }.buttonStyle(.plain).minimumHitTarget()
          .accessibilityLabel("Close agent picker")
          .help("Close agent picker")
      }

      if !attachedAgents.isEmpty {
        VStack(alignment: .leading, spacing: 7) {
          Text("Attached").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
          ForEach(attachedAgents) { session in
            attachedAgentRow(session)
          }
        }
        Divider().opacity(0.5)
      } else {
        ContentUnavailableView(
          "No managed agents",
          systemImage: "terminal",
          description: Text("Start a new agent from this task and give it a descriptive subtask title.")
        ).frame(maxWidth: .infinity, minHeight: 110)
      }
    }.padding(12).frame(maxWidth: .infinity)
      .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1)
      }
      .confirmationDialog("Remove every agent from \(ticket.id)?", isPresented: $confirmingClear, titleVisibility: .visible) {
        Button("Remove all agents from this task", role: .destructive) {
          model.clearAgentQueue(for: ticket)
          onClose()
        }
      } message: {
        Text("This removes current agents and closes verified runtimes. Subtasks, conversations, and workspace history are retained.")
      }
  }

  private func attachedAgentRow(_ session: TaskAgentSession) -> some View {
    HStack(spacing: 8) {
      Button {
        model.viewAgent(session, for: ticket)
      } label: {
        HStack(spacing: 10) {
          if model.isOpening(session) {
            ProgressView().controlSize(.small).frame(width: 22)
          } else {
            Image(systemName: "terminal").font(.system(size: 15, weight: .semibold))
              .foregroundStyle(.secondary).frame(width: 22)
          }
          VStack(alignment: .leading, spacing: 3) {
            Text(agentTitle(session))
              .font(.system(size: 12, weight: .semibold)).lineLimit(2)
            Text(agentPurpose(session))
              .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            if session.tmux != nil {
              Label("Persistent tmux session", systemImage: "network")
                .font(.caption2).foregroundStyle(.secondary)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
        .disabled(model.isOpening(session))
        .accessibilityLabel(
          model.isOpening(session)
            ? "Opening agent \(agentTitle(session))"
            : "View agent \(agentTitle(session))"
        )

      Button { model.archiveAgent(session, from: ticket) } label: {
        Image(systemName: "archivebox").font(.system(size: 13, weight: .semibold))
      }.buttonStyle(.plain).minimumHitTarget()
        .accessibilityLabel("Archive agent \(agentTitle(session))")
        .help("Archive this agent and retain its conversation and workspace")
    }.padding(.horizontal, 10).padding(.vertical, 8)
      .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
  }

  private func agentTitle(_ session: TaskAgentSession) -> String {
    model.subtasks(for: ticket.id).first { $0.id == session.subtaskID }?.title
      ?? session.tabTitle
  }

  private func agentPurpose(_ session: TaskAgentSession) -> String {
    model.subtasks(for: ticket.id).first { $0.id == session.subtaskID }?.workDescription
      ?? "Managed agent session"
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

private struct NotificationSurfaceModifier: ViewModifier {
  let radius: CGFloat
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content.clipShape(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
    ).background {
      RoundedRectangle(cornerRadius: radius, style: .continuous).fill(
        QueuePalette.component(for: colorScheme))
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.13), radius: 8, x: 0, y: 3)
    }.overlay {
      RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(
        QueuePalette.componentBorder(for: colorScheme), lineWidth: 0.75)
    }
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
  @Environment(\.opaqueBackgroundsEnabled) private var opaqueBackgroundsEnabled

  func body(content: Content) -> some View {
    content.background {
      RoundedRectangle(cornerRadius: radius, style: .continuous).fill(
        QueuePalette.panel(for: colorScheme, opaqueBackgrounds: opaqueBackgroundsEnabled))
    }.clipShape(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
    ).overlay {
      RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(
        QueuePalette.panelBorder(for: colorScheme), lineWidth: 2)
    }
  }
}

enum QueuePalette {
  static let wezTermBackground = Color(red: 26 / 255, green: 29 / 255, blue: 35 / 255)
  static let lightComponent = Color(red: 240 / 255, green: 242 / 255, blue: 245 / 255)

  static func component(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? wezTermBackground : lightComponent
  }

  static func componentBorder(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.white.opacity(0.13) : Color.white.opacity(0.72)
  }

  static func panel(for colorScheme: ColorScheme, opaqueBackgrounds: Bool = false) -> Color {
    if opaqueBackgrounds {
      return OpaqueBackgroundPalette.replacementSurface(for: colorScheme)
    }
    return colorScheme == .dark ? wezTermBackground.opacity(0.80) : Color.white.opacity(0.29)
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
  func notificationSurface(radius: CGFloat) -> some View {
    modifier(NotificationSurfaceModifier(radius: radius))
  }

  fileprivate func panelSurface(radius: CGFloat) -> some View {
    modifier(PanelSurfaceModifier(radius: radius))
  }
}
