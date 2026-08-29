import AppKit
import FocusQueueCore
import Foundation
import Observation

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
  private(set) var actionMessages: [String: String] = [:]
  var expandedTicketIDs: Set<String> = []

  @ObservationIgnored private let paths: AppPaths
  @ObservationIgnored private let configurationRepository: any ConfigurationLoading
  @ObservationIgnored private let dashboardRepository: any DashboardLoading
  @ObservationIgnored private let stateStore: any LocalStateStoring
  @ObservationIgnored private let reviewArtifacts: ReviewArtifactStore
  @ObservationIgnored private let terminalController: any WezTermControlling
  @ObservationIgnored private let verifier: any CompletionVerifying
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var reviewTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var windowSaveTask: Task<Void, Never>?
  @ObservationIgnored private var bootstrapped = false

  @ObservationIgnored var placementHandler: ((QueueWindowPlacement) -> Void)?
  @ObservationIgnored var collapseHandler: ((Bool) -> Void)?
  @ObservationIgnored var terminalFocusHandler: (@MainActor (String) async throws -> Void)?
  @ObservationIgnored var quitHandler: (() -> Void)?

  init(
    paths: AppPaths = .live(),
    configurationRepository: (any ConfigurationLoading)? = nil,
    dashboardRepository: any DashboardLoading = JSONDashboardRepository(),
    stateStore: (any LocalStateStoring)? = nil,
    reviewArtifacts: ReviewArtifactStore? = nil,
    terminalController: any WezTermControlling = WezTermController(),
    verifier: any CompletionVerifying = HermesCompletionVerifier()
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
  }

  var openTickets: [DashboardTicket] {
    dashboard.tickets
      .filter(\.isOpen)
      .sorted {
        if $0.priorityRank != $1.priorityRank {
          return $0.priorityRank < $1.priorityRank
        }
        if $0.updatedAt != $1.updatedAt {
          return ($0.updatedAt ?? "") > ($1.updatedAt ?? "")
        }
        return $0.id < $1.id
      }
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
      await refresh()
      startRefreshLoop()
      resumePendingReviews()
    } catch {
      loadError = error.localizedDescription
    }
  }

  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let dashboardURL = URL(fileURLWithPath: config.dashboardPath)
      async let document = dashboardRepository.load(from: dashboardURL)
      async let modificationDate = dashboardRepository.modificationDate(at: dashboardURL)
      dashboard = try await document
      sourceModificationDate = try await modificationDate
      lastSync = Date()
      loadError = nil
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
          try await terminalFocusHandler(config.wezTerm.applicationName)
        }
        actionMessages[ticket.id] =
          "\(result.message) Click the dimmed background to return to the queue."
      } catch {
        actionMessages[ticket.id] = error.localizedDescription
      }
    }
  }

  func open(_ rawValue: String) {
    guard let url = ResourceLocator.url(for: rawValue) else { return }
    if url.isFileURL, url.pathExtension.lowercased() == "pdf" {
      Self.openPDF(url)
      return
    }
    NSWorkspace.shared.open(url)
  }

  func openConfiguration() {
    NSWorkspace.shared.open(paths.configurationFile)
  }

  func placeWindow(_ placement: QueueWindowPlacement) {
    placementHandler?(placement)
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
}
