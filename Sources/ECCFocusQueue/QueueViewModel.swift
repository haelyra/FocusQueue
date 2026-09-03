import AppKit
import FocusQueueCore
import Foundation
import Observation

enum QueueChatRole: Sendable {
  case user
  case agent
}

struct QueueChatMessage: Identifiable, Sendable {
  let id = UUID()
  let role: QueueChatRole
  let text: String
}

@MainActor
@Observable
final class QueueViewModel {
  private(set) var config: AppConfiguration
  private(set) var dashboard = DashboardDocument(tickets: [])
  private(set) var localState = LocalState()
  private(set) var lastSync: Date?
  private(set) var sourceModificationDate: Date?
  private(set) var loadError: String?
  private(set) var isRefreshing = false
  private(set) var isPanelCollapsed = false
  private(set) var canSwitchMonitor = false
  private(set) var actionMessages: [String: String] = [:]
  private(set) var recurringPRProgressByTicketID: [String: RecurringPullRequestProgress] = [:]
  private(set) var recurringPRProgressErrors: [String: String] = [:]
  private(set) var queueChatMessages: [QueueChatMessage] = [
    QueueChatMessage(
      role: .agent,
      text:
        "I’m the Codex Queue agent. The app orders tasks by priority and recency, plus your local drag overrides. I can search and read the ECC Discord server and search, read, and explicitly open haley@ecc.tools through verified read-only connectors. Source answers are withheld unless the app validates fresh retrieval evidence. Ask why something is ordered, give explicit canonical instructions, clarify wording, or request link and task-field changes."
    )
  ]
  private(set) var isQueueAgentResponding = false
  var expandedTicketIDs: Set<String> = []

  @ObservationIgnored private let paths: AppPaths
  @ObservationIgnored private let configurationRepository: any ConfigurationLoading
  @ObservationIgnored private let dashboardRepository: any DashboardLoading
  @ObservationIgnored private let stateStore: any LocalStateStoring
  @ObservationIgnored private let reviewArtifacts: ReviewArtifactStore
  @ObservationIgnored private let terminalController: any WezTermControlling
  @ObservationIgnored private let verifier: any CompletionVerifying
  @ObservationIgnored private let queueAgent: any QueueAgentChatting
  @ObservationIgnored private let pullRequestQueueLoader: any PullRequestQueueLoading
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var reviewTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var windowSaveTask: Task<Void, Never>?
  @ObservationIgnored private var queueChatTask: Task<Void, Never>?
  @ObservationIgnored private var lastRecurringPRRefresh: Date?
  @ObservationIgnored private var bootstrapped = false

  @ObservationIgnored var placementHandler: ((QueueWindowPlacement) -> Void)?
  @ObservationIgnored var monitorSwitchHandler: (() -> Void)?
  @ObservationIgnored var collapseHandler: ((Bool) -> Void)?
  @ObservationIgnored var terminalFocusHandler: (
    @MainActor (String, String?) async throws -> Void
  )?
  @ObservationIgnored var quitHandler: (() -> Void)?

  init(
    paths: AppPaths = .live(),
    configurationRepository: (any ConfigurationLoading)? = nil,
    dashboardRepository: any DashboardLoading = JSONDashboardRepository(),
    stateStore: (any LocalStateStoring)? = nil,
    reviewArtifacts: ReviewArtifactStore? = nil,
    terminalController: any WezTermControlling = WezTermController(),
    verifier: any CompletionVerifying = CodexCompletionVerifier(),
    queueAgent: any QueueAgentChatting = CodexQueueAgent(),
    pullRequestQueueLoader: any PullRequestQueueLoading = GitHubPullRequestQueueLoader()
  ) {
    self.paths = paths
    self.config = .eccDefault()
    self.configurationRepository =
      configurationRepository
      ?? JSONConfigurationRepository(url: paths.configurationFile)
    self.dashboardRepository = dashboardRepository
    self.stateStore = stateStore ?? JSONLocalStateStore(url: paths.stateFile)
    self.reviewArtifacts = reviewArtifacts ?? ReviewArtifactStore(directory: paths.reviewsDirectory)
    self.terminalController = terminalController
    self.verifier = verifier
    self.queueAgent = queueAgent
    self.pullRequestQueueLoader = pullRequestQueueLoader
  }

  var openTickets: [DashboardTicket] {
    let ordered = DashboardOrdering.openTickets(
      in: dashboard.tickets,
      deferredTicketIDs: localState.deferredTicketIDs
    )
    let noBacklogIDs = Set(
      recurringPRProgressByTicketID.compactMap { ticketID, progress in
        progress.openCount == 0 ? ticketID : nil
      }
    )
    return ordered.filter { !noBacklogIDs.contains($0.id) }
      + ordered.filter { noBacklogIDs.contains($0.id) }
  }

  var completedTickets: [DashboardTicket] {
    dashboard.tickets
      .filter(\.isCompleted)
      .sorted {
        if $0.completionTimestamp != $1.completionTimestamp {
          return ($0.completionTimestamp ?? "") > ($1.completionTimestamp ?? "")
        }
        return $0.id > $1.id
      }
  }

  var completedTodayTickets: [DashboardTicket] {
    let today = Self.dayFormatter.string(from: Date())
    return completedTickets.filter { $0.completionDay == today }
  }

  var pastCompletedTickets: [DashboardTicket] {
    let today = Self.dayFormatter.string(from: Date())
    return completedTickets.filter { $0.completionDay != today }
  }

  var blockedTicketCount: Int {
    openTickets.filter { $0.status.lowercased() == "blocked" }.count
  }

  var completedRoutineCount: Int {
    localState.completedRoutineIDs.intersection(Set(config.dailyRoutines.map(\.id))).count
  }

  var configurationURL: URL { paths.configurationFile }
  var windowSnapshot: WindowSnapshot? { localState.window }
  var appearance: QueueAppearance { localState.appearance ?? .light }
  var accentStyle: QueueAccentStyle { localState.accentStyle ?? .vibrant }
  var windowPlacement: QueueWindowPlacement {
    localState.window?.placement ?? config.defaultPlacement
  }

  func bootstrap() async {
    guard !bootstrapped else { return }
    bootstrapped = true
    do {
      config = try await configurationRepository.loadOrCreate(default: .eccDefault())
      localState = try await stateStore.load()
      resetDailyRoutinesIfNeeded()
      recoverInterruptedReviews()
      try await stateStore.save(localState)
      await refresh(forceRecurringPRProgress: true)
      startRefreshLoop()
      resumePendingReviews()
    } catch {
      loadError = error.localizedDescription
    }
  }

  func refresh(forceRecurringPRProgress: Bool = false) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let dashboardURL = URL(fileURLWithPath: config.dashboardPath)
      async let document = dashboardRepository.load(from: dashboardURL)
      async let modificationDate = dashboardRepository.modificationDate(at: dashboardURL)
      dashboard = try await document
      pruneDeferredTickets()
      sourceModificationDate = try await modificationDate
      lastSync = Date()
      loadError = nil
      await refreshRecurringPRProgressIfNeeded(force: forceRecurringPRProgress)
    } catch {
      loadError = error.localizedDescription
    }
  }

  func isExpanded(_ ticketID: String) -> Bool {
    expandedTicketIDs.contains(ticketID)
  }

  func setExpanded(_ expanded: Bool, ticketID: String) {
    if expanded {
      expandedTicketIDs.insert(ticketID)
    } else {
      expandedTicketIDs.remove(ticketID)
    }
  }

  func recurringPRProgress(for ticketID: String) -> RecurringPullRequestProgress? {
    recurringPRProgressByTicketID[ticketID]
  }

  func recurringPRProgressError(for ticketID: String) -> String? {
    recurringPRProgressErrors[ticketID]
  }

  @discardableResult
  func moveTicketToRest(_ ticketID: String) -> Bool {
    guard dashboard.tickets.contains(where: { $0.id == ticketID && $0.isOpen }) else {
      return false
    }
    localState.deferredTicketIDs.removeAll { $0 == ticketID }
    localState.deferredTicketIDs.append(ticketID)
    actionMessages[ticketID] = "Moved to Rest of queue on this Mac."
    persistLocalState()
    return true
  }

  @discardableResult
  func moveTicketToToday(_ ticketID: String) -> Bool {
    guard localState.deferredTicketIDs.contains(ticketID) else { return false }
    localState.deferredTicketIDs.removeAll { $0 == ticketID }
    actionMessages[ticketID] = "Restored to Today's focus using canonical priority."
    persistLocalState()
    return true
  }

  func sendQueueAgentMessage(_ rawMessage: String) {
    let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, !isQueueAgentResponding else { return }

    queueChatMessages.append(QueueChatMessage(role: .user, text: message))
    isQueueAgentResponding = true
    let visibleOrder = openTickets.map(\.id)
    let deferredTicketIDs = localState.deferredTicketIDs
    queueChatTask = Task { [weak self] in
      guard let self else { return }
      defer { self.isQueueAgentResponding = false }
      do {
        let reply = try await self.queueAgent.send(
          message: message,
          dashboardPath: self.config.dashboardPath,
          workspace: self.config.workspacePath,
          visibleOrder: visibleOrder,
          deferredTicketIDs: deferredTicketIDs,
          configuration: self.config.verifier
        )
        self.queueChatMessages.append(QueueChatMessage(role: .agent, text: reply.message))
        await self.refresh()
      } catch {
        self.queueChatMessages.append(
          QueueChatMessage(role: .agent, text: error.localizedDescription)
        )
      }
    }
  }

  func routineIsComplete(_ id: String) -> Bool {
    localState.completedRoutineIDs.contains(id)
  }

  func toggleRoutine(_ id: String) {
    if localState.completedRoutineIDs.contains(id) {
      localState.completedRoutineIDs.remove(id)
    } else {
      localState.completedRoutineIDs.insert(id)
    }
    persistLocalState()
  }

  func latestReview(for ticketID: String) -> CompletionRequest? {
    localState.completionRequests
      .filter { $0.ticketID == ticketID }
      .max { $0.requestedAt < $1.requestedAt }
  }

  func ticketIsChecked(_ ticket: DashboardTicket) -> Bool {
    guard ticket.isOpen else { return true }
    guard let review = latestReview(for: ticket.id) else { return false }
    return [.pending, .running, .accepted].contains(review.status)
  }

  func requestCompletion(for ticket: DashboardTicket) {
    guard ticket.isOpen else { return }
    if let review = latestReview(for: ticket.id), [.pending, .running].contains(review.status) {
      actionMessages[ticket.id] = "Completion review is already \(review.status.rawValue)."
      return
    }

    let id = UUID()
    let requestURL = reviewArtifacts.requestURL(for: id)
    let request = CompletionRequest(ticketID: ticket.id, requestFilePath: requestURL.path)
    localState.completionRequests.append(request)
    actionMessages[ticket.id] = "Completion review queued. The dashboard is unchanged."
    persistLocalState()
    scheduleReview(requestID: request.id)
  }

  func retryReview(for ticket: DashboardTicket) {
    guard let review = latestReview(for: ticket.id),
      [.failed, .needsWork].contains(review.status)
    else {
      requestCompletion(for: ticket)
      return
    }
    updateReview(review.id) {
      $0.status = .pending
      $0.summary = nil
      $0.updatedAt = Date()
    }
    persistLocalState()
    scheduleReview(requestID: review.id)
  }

  func focusTerminal(for ticket: DashboardTicket) {
    let directory = ticket.worktree ?? config.workspacePath
    actionMessages[ticket.id] = "Finding a matching WezTerm pane…"
    Task {
      do {
        let result = try await terminalController.focusOrSpawn(
          directory: directory,
          taskID: ticket.id,
          configuration: config.wezTerm
        )
        if let terminalFocusHandler {
          try await terminalFocusHandler(
            config.wezTerm.applicationName,
            result.paneID == nil ? nil : ticket.id
          )
        }
        actionMessages[ticket.id] =
          "\(result.message) The queue stays available beside the terminal."
      } catch {
        actionMessages[ticket.id] = error.localizedDescription
      }
    }
  }

  func agentSessions(for ticketID: String) -> [TaskAgentSession] {
    localState.agentSessions
      .filter { $0.ticketID == ticketID }
      .sorted {
        ($0.tabTitle.localizedCaseInsensitiveCompare($1.tabTitle) == .orderedAscending)
          || ($0.tabTitle.caseInsensitiveCompare($1.tabTitle) == .orderedSame
            && $0.sessionID < $1.sessionID)
      }
  }

  func availableAgents() async throws -> [RunningAgentSession] {
    try await terminalController.listRunningAgents(configuration: config.wezTerm)
  }

  func attachAgent(_ agent: RunningAgentSession, to ticket: DashboardTicket) async -> Bool {
    actionMessages[ticket.id] = "Attaching the selected \(agent.provider.displayName) agent…"
    do {
      try await terminalController.attach(
        paneID: agent.pane.paneID,
        taskID: ticket.id,
        configuration: config.wezTerm
      )
      let attached = TaskAgentSession(
        ticketID: ticket.id,
        provider: agent.provider,
        sessionID: agent.sessionID,
        tabTitle: agent.tabTitle,
        workingDirectory: agent.workingDirectory,
        windowID: agent.pane.windowID,
        tabID: agent.pane.tabID,
        paneID: agent.pane.paneID
      )
      if let index = localState.agentSessions.firstIndex(where: {
        $0.ticketID == ticket.id
          && $0.provider == agent.provider
          && $0.sessionID == agent.sessionID
      }) {
        var updated = attached
        updated = TaskAgentSession(
          id: localState.agentSessions[index].id,
          ticketID: updated.ticketID,
          provider: updated.provider,
          sessionID: updated.sessionID,
          tabTitle: updated.tabTitle,
          workingDirectory: updated.workingDirectory,
          windowID: updated.windowID,
          tabID: updated.tabID,
          paneID: updated.paneID
        )
        localState.agentSessions[index] = updated
      } else {
        localState.agentSessions.append(attached)
      }
      persistLocalState()
      actionMessages[ticket.id] =
        "Attached \(agent.provider.displayName) session \(agent.sessionID) to \(ticket.id)."
      return true
    } catch {
      actionMessages[ticket.id] = error.localizedDescription
      return false
    }
  }

  func viewAgent(_ session: TaskAgentSession, for ticket: DashboardTicket) {
    actionMessages[ticket.id] = "Finding \(session.provider.displayName) session \(session.sessionID)…"
    Task {
      do {
        let result = try await terminalController.focusOrResume(
          session: session,
          taskID: ticket.id,
          configuration: config.wezTerm
        )
        if let index = localState.agentSessions.firstIndex(where: { $0.id == session.id }) {
          localState.agentSessions[index].paneID = result.paneID
          persistLocalState()
        }
        if let terminalFocusHandler {
          try await terminalFocusHandler(
            config.wezTerm.applicationName,
            result.paneID == nil ? nil : session.terminalWindowTitle
          )
        }
        actionMessages[ticket.id] =
          "\(result.message) The queue stays available beside the terminal."
      } catch {
        actionMessages[ticket.id] = error.localizedDescription
      }
    }
  }

  func removeAgent(_ session: TaskAgentSession, from ticket: DashboardTicket) {
    guard localState.agentSessions.contains(where: { $0.id == session.id }) else { return }
    localState.agentSessions.removeAll { $0.id == session.id }
    persistLocalState()
    actionMessages[ticket.id] =
      "Removed \(session.provider.displayName) session \(session.sessionID) from this task."
  }

  func availableTerminals() async throws -> [WezTermPane] {
    try await terminalController.listAttachablePanes(configuration: config.wezTerm)
  }

  func attachTerminal(_ pane: WezTermPane, to ticket: DashboardTicket) async -> Bool {
    actionMessages[ticket.id] = "Attaching the selected WezTerm tab…"
    do {
      try await terminalController.attach(
        paneID: pane.paneID,
        taskID: ticket.id,
        configuration: config.wezTerm
      )
      actionMessages[ticket.id] =
        "Attached \(pane.attachmentDisplayName) to \(ticket.id). Focus terminal will reuse it."
      return true
    } catch {
      actionMessages[ticket.id] = error.localizedDescription
      return false
    }
  }

  func open(_ rawValue: String) {
    guard let url = ResourceLocator.url(for: rawValue) else { return }
    if url.isFileURL {
      switch url.pathExtension.lowercased() {
      case "md", "markdown":
        do {
          try MarkdownBrowser.open(url)
        } catch {
          loadError = "Could not open Markdown file: \(error.localizedDescription)"
        }
        return
      case "pdf":
        Self.openPDF(url)
        return
      default:
        break
      }
    }
    NSWorkspace.shared.open(url)
  }

  func openConfiguration() {
    NSWorkspace.shared.open(paths.configurationFile)
  }

  func placeWindow(_ placement: QueueWindowPlacement) {
    placementHandler?(placement)
  }

  func switchMonitor() {
    monitorSwitchHandler?()
  }

  func setCanSwitchMonitor(_ canSwitchMonitor: Bool) {
    self.canSwitchMonitor = canSwitchMonitor
  }

  func setAppearance(_ appearance: QueueAppearance) {
    localState.appearance = appearance
    persistLocalState()
  }

  func setAccentStyle(_ accentStyle: QueueAccentStyle) {
    localState.accentStyle = accentStyle
    persistLocalState()
  }

  func setPanelCollapsed(_ collapsed: Bool) {
    isPanelCollapsed = collapsed
    collapseHandler?(collapsed)
  }

  func quit() {
    quitHandler?()
  }

  func saveWindow(_ snapshot: WindowSnapshot) {
    localState.window = snapshot
    windowSaveTask?.cancel()
    windowSaveTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled, let self else { return }
      do {
        try await self.stateStore.save(self.localState)
      } catch {
        self.loadError = "Could not save window position: \(error.localizedDescription)"
      }
    }
  }

  private func startRefreshLoop() {
    refreshTask?.cancel()
    let interval = config.refreshIntervalSeconds
    refreshTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled, let self else { return }
        await self.refresh()
      }
    }
  }

  private func resetDailyRoutinesIfNeeded() {
    let today = Self.dayFormatter.string(from: Date())
    if localState.routineDate != today {
      localState.routineDate = today
      localState.completedRoutineIDs = []
    }
  }

  private func refreshRecurringPRProgressIfNeeded(force: Bool) async {
    let tickets = dashboard.tickets.filter { $0.isOpen && $0.isRecurringPullRequestTask }
    let activeIDs = Set(tickets.map(\.id))
    recurringPRProgressByTicketID = recurringPRProgressByTicketID.filter {
      activeIDs.contains($0.key)
    }
    recurringPRProgressErrors = recurringPRProgressErrors.filter { activeIDs.contains($0.key) }
    guard !tickets.isEmpty else { return }

    if !force, let lastRecurringPRRefresh,
      Date().timeIntervalSince(lastRecurringPRRefresh) < 300
    {
      return
    }
    lastRecurringPRRefresh = Date()
    let closedSince = Self.dayFormatter.string(from: Self.startOfCurrentWeek)

    for ticket in tickets {
      guard let repository = ticket.pullRequestRepository else {
        recurringPRProgressErrors[ticket.id] =
          "Add a GitHub repository link to load recurring PR progress."
        continue
      }
      do {
        let snapshot = try await pullRequestQueueLoader.load(
          repository: repository,
          closedSince: closedSince
        )
        recurringPRProgressByTicketID[ticket.id] = RecurringPullRequestProgress(
          snapshot: snapshot
        )
        recurringPRProgressErrors[ticket.id] = nil
      } catch {
        recurringPRProgressErrors[ticket.id] = error.localizedDescription
      }
    }
  }

  private func pruneDeferredTickets() {
    let openIDs = Set(dashboard.tickets.lazy.filter(\.isOpen).map(\.id))
    var seen: Set<String> = []
    let validIDs = localState.deferredTicketIDs.filter {
      openIDs.contains($0) && seen.insert($0).inserted
    }
    guard validIDs != localState.deferredTicketIDs else { return }
    localState.deferredTicketIDs = validIDs
    persistLocalState()
  }

  private func recoverInterruptedReviews() {
    for index in localState.completionRequests.indices
    where localState.completionRequests[index].status == .running {
      localState.completionRequests[index].status = .pending
      localState.completionRequests[index].summary =
        "Recovered after the app stopped during review."
      localState.completionRequests[index].updatedAt = Date()
    }
  }

  private func resumePendingReviews() {
    for request in localState.completionRequests where request.status == .pending {
      scheduleReview(requestID: request.id)
    }
  }

  private func scheduleReview(requestID: UUID) {
    guard reviewTasks[requestID] == nil else { return }
    reviewTasks[requestID] = Task { [weak self] in
      await self?.runReview(requestID: requestID)
    }
  }

  private func runReview(requestID: UUID) async {
    defer { reviewTasks[requestID] = nil }
    guard var request = localState.completionRequests.first(where: { $0.id == requestID }) else {
      return
    }
    request.status = .running
    request.updatedAt = Date()
    replaceReview(request)
    do {
      try await reviewArtifacts.writeRequest(request)
      try await stateStore.save(localState)
      let result = try await verifier.verify(
        ticketID: request.ticketID,
        requestFile: URL(fileURLWithPath: request.requestFilePath),
        workspace: config.workspacePath,
        configuration: config.verifier
      )
      let logURL = try await reviewArtifacts.writeLog(result.log, for: request.id)
      await refresh()
      let canonicalTicket = dashboard.tickets.first { $0.id == request.ticketID }
      request.status =
        canonicalTicket?.isOpen == false
        ? .accepted
        : (result.succeeded ? .needsWork : .failed)
      request.summary = result.summary
      request.logPath = logURL.path
      request.updatedAt = Date()
      replaceReview(request)
      try await reviewArtifacts.writeRequest(request)
      try await stateStore.save(localState)
      actionMessages[request.ticketID] =
        request.status == .accepted
        ? "Canonical state confirms completion."
        : "Review finished; the task remains open in canonical state."
    } catch {
      request.status = .failed
      request.summary = error.localizedDescription
      request.updatedAt = Date()
      replaceReview(request)
      try? await reviewArtifacts.writeRequest(request)
      try? await stateStore.save(localState)
      actionMessages[request.ticketID] = "Completion review failed: \(error.localizedDescription)"
    }
  }

  private func updateReview(_ id: UUID, mutation: (inout CompletionRequest) -> Void) {
    guard let index = localState.completionRequests.firstIndex(where: { $0.id == id }) else {
      return
    }
    mutation(&localState.completionRequests[index])
  }

  private func replaceReview(_ request: CompletionRequest) {
    guard let index = localState.completionRequests.firstIndex(where: { $0.id == request.id })
    else { return }
    localState.completionRequests[index] = request
  }

  private func persistLocalState() {
    let snapshot = localState
    Task {
      do {
        try await stateStore.save(snapshot)
      } catch {
        loadError = "Could not save local state: \(error.localizedDescription)"
      }
    }
  }

  private static func openPDF(_ url: URL) {
    let workspace = NSWorkspace.shared
    guard let preview = workspace.urlForApplication(withBundleIdentifier: "com.apple.Preview")
    else {
      openPDFInBrowser(url)
      return
    }
    workspace.open(
      [url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
      if error != nil {
        DispatchQueue.main.async {
          openPDFInBrowser(url)
        }
      }
    }
  }

  private static func openPDFInBrowser(_ url: URL) {
    let workspace = NSWorkspace.shared
    guard let safari = workspace.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
      workspace.open(url)
      return
    }
    workspace.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
  }

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = .current
    formatter.locale = .current
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static var startOfCurrentWeek: Date {
    Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start
      ?? Calendar.current.startOfDay(for: Date())
  }
}

private extension WezTermPane {
  var attachmentDisplayName: String {
    for value in [tabTitle, title, windowTitle] {
      if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "“\(value)”"
      }
    }
    return "WezTerm pane \(paneID)"
  }
}
