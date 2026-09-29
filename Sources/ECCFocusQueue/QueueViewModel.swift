import AppKit
import FocusQueueCore
import Foundation
import Observation

enum QueueChatRole: String, Codable, Sendable {
  case user
  case agent
}

struct QueueChatMessage: Identifiable, Codable, Sendable {
  var id = UUID()
  let role: QueueChatRole
  let text: String
  let canvasSelection: PlanCanvasSelection?

  init(
    id: UUID = UUID(), role: QueueChatRole, text: String,
    canvasSelection: PlanCanvasSelection? = nil
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.canvasSelection = canvasSelection
  }
}

enum QueuePanelMode: Equatable {
  case expanded
  case topTask
  case collapsed
}

private struct PendingRouterSubmission {
  let id: UUID
  let draft: String
  let completion: (@MainActor (Bool) -> Void)?
}

private struct DashboardFileStamp: Equatable, Sendable {
  let modifiedAt: Date?
  let size: UInt64?
  let inode: UInt64?

  static func read(at url: URL) throws -> Self {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return Self(modifiedAt: attributes[.modificationDate] as? Date,
      size: (attributes[.size] as? NSNumber)?.uint64Value,
      inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
  }
}

@MainActor
@Observable
final class QueueViewModel {
  private(set) var config: AppConfiguration
  private(set) var dashboard = DashboardDocument(tickets: [])
  private(set) var localState = LocalState()
  private(set) var savedQueueOrder: [String]?
  private var queueOrderStore: QueueOrderStore {
    QueueOrderStore(root: paths.supportDirectory, projectID: config.selectedProjectID)
  }
  private(set) var lastSync: Date?
  private(set) var sourceModificationDate: Date?
  private(set) var loadError: String? {
    didSet { logChangedError(loadError, previous: oldValue, category: "Queue") }
  }
  private(set) var projectError: String? {
    didSet { logChangedError(projectError, previous: oldValue, category: "Projects") }
  }
  private(set) var isSavingProject = false
  private(set) var durableHistoryError: String? {
    didSet { logChangedError(durableHistoryError, previous: oldValue, category: "History") }
  }
  private(set) var configurationIsLoaded = false
  var isSetupPresented = false
  private(set) var setupError: String? {
    didSet { logChangedError(setupError, previous: oldValue, category: "Setup") }
  }
  private(set) var isRefreshing = false
  private(set) var dailyReport: DailyReportDocument?
  private(set) var latestDailyReport: DailyReportDocument?
  private(set) var dailyReportLoadError: String? {
    didSet { logChangedError(dailyReportLoadError, previous: oldValue, category: "Daily report") }
  }
  private(set) var isDailyReportPresented = false
  private(set) var isDailyReportRunning = false
  private(set) var isRecoveredDailyReportRunning = false
  private(set) var isDailyReportCancellationRequested = false
  private(set) var dailyReportRunMessage: String?
  private(set) var dailyReportRunFailed = false {
    didSet {
      if dailyReportRunFailed, let dailyReportRunMessage {
        programLog.record(dailyReportRunMessage, level: .error, category: "Daily report")
      }
    }
  }
  private(set) var pendingDailyReportApproval: DailyReportApprovalRequest?
  private(set) var requestedReportTaskID: String?
  private(set) var panelMode: QueuePanelMode = .expanded
  private(set) var canSwitchMonitor = false
  private(set) var actionMessages: [String: String] = [:] {
    didSet { logChangedMessages(actionMessages, previous: oldValue, categoryPrefix: "Task") }
  }
  private(set) var recurringPRProgressByTicketID: [String: RecurringPullRequestProgress] = [:]
  private(set) var recurringPRProgressErrors: [String: String] = [:] {
    didSet {
      for (ticketID, message) in recurringPRProgressErrors where oldValue[ticketID] != message {
        programLog.record(message, level: .error, category: "Pull request \(ticketID)")
      }
    }
  }
  private(set) var queueChatMessages: [QueueChatMessage] = [
    QueueChatMessage(
      role: .agent,
      text:
        "The Queue agent can explain your task order and help with explicitly requested task changes when configured. The app orders tasks by priority and recency, plus your local drag overrides. Optional message sources need separate account setup and verified retrieval evidence. Basic queue viewing and terminal setup work independently of this agent."
    )
  ]
  private(set) var isQueueAgentResponding = false
  private(set) var respondingTicketID: String?
  private(set) var taskChatMessages: [String: [QueueChatMessage]] = [:]
  private(set) var taskContexts: [String: TaskContext] = [:]
  private(set) var unassignedAgentRegistrations: [ExternalAgentRegistration] = []
  private(set) var externalAgentRegistrationError: String? {
    didSet {
      logChangedError(
        externalAgentRegistrationError,
        previous: oldValue,
        category: "Agent registration"
      )
    }
  }
  private(set) var maintenanceReceipts: [String: TaskMaintenanceReceipt] = [:]
  @ObservationIgnored private var maintenanceSignatures: [String: String] = [:]
  @ObservationIgnored private var lastMaintenanceAt: Date?
  @ObservationIgnored private let maintenanceEnabled: Bool
  private(set) var subtaskActivityRevision = 0
  private(set) var isQueueChatInspectorPresented = false
  private(set) var presentedAgentUpdate: QueueAgentUpdate?
  private(set) var presentedPlanTicketID: String?
  private(set) var presentedPlanURL: URL?
  private(set) var presentedPlanMarkdown = ""
  private(set) var isPlanLoading = false
  private(set) var planError: String? {
    didSet { logChangedError(planError, previous: oldValue, category: "Plan") }
  }
  private(set) var planEditDrafts: [String: PlanEditDraft] = [:]
  private(set) var launchingTaskIDs: Set<String> = []
  var isRoutingObjective: Bool {
    !pendingRouterSubmissions.isEmpty || !launchingRouterSubmissionIDs.isEmpty
  }
  var canCancelRouterObjective: Bool { !pendingRouterSubmissions.isEmpty }
  private(set) var routerStatus: String?
  private(set) var routerRecoveryPath: String?
  /// Every tracked one-shot router, oldest first; several objectives can be
  /// routed in parallel up to `QueueRouterRuntimeStore.maximumActiveRouters`.
  private(set) var routerRuntimes: [QueueRouterRuntime] = []
  /// The oldest tracked router, which the recovery UI opens.
  var routerRuntime: QueueRouterRuntime? { routerRuntimes.first }
  private(set) var routerRecoveryBlocked = false
  private(set) var routerCapacityRemaining = QueueRouterRuntimeStore.maximumActiveRouters
  /// Set when the launch-time startup-receipt sweep had to fail stuck routed
  /// agents; QueueView presents it as a hard alert.
  var startupRepairAlert: String?
  private(set) var openingSubtaskIDs: Set<String> = []
  private(set) var openingAgentSessionIDs: Set<String> = []
  private(set) var agentSessionErrors: [String: String] = [:] {
    didSet {
      for (key, message) in agentSessionErrors where oldValue[key] != message {
        programLog.record(message, level: .error, category: "Agent \(key)")
      }
    }
  }
  var launchDiagnostics: LaunchDiagnosticsPresentation?
  private(set) var closureMessages: [String: String] = [:] {
    didSet { logChangedMessages(closureMessages, previous: oldValue, categoryPrefix: "Cleanup") }
  }
  private(set) var reportHistory = DailyReportHistorySnapshot()
  private(set) var reportHistoryError: String? {
    didSet { logChangedError(reportHistoryError, previous: oldValue, category: "Report history") }
  }
  private(set) var connectorDiagnostics: ConnectorDiagnosticsSnapshot?
  private(set) var connectorDiagnosticsError: String? {
    didSet {
      logChangedError(
        connectorDiagnosticsError,
        previous: oldValue,
        category: "Connectors"
      )
    }
  }
  private(set) var connectorDiagnosticsCheckedAt: Date?
  private(set) var isDiagnosingConnectors = false
  var expandedTicketIDs: Set<String> = []

  @ObservationIgnored private let paths: AppPaths
  @ObservationIgnored private let programLog: ProgramLogStore
  @ObservationIgnored private let configurationRepository: any ConfigurationLoading
  @ObservationIgnored private let dailyReportRepository: any DailyReportStoring
  @ObservationIgnored private let dailyReportApprovalRepository: any DailyReportApprovalStoring
  @ObservationIgnored private let dashboardRepository: any DashboardManaging
  @ObservationIgnored private let stateStore: any LocalStateStoring
  @ObservationIgnored private let reviewArtifacts: ReviewArtifactStore
  @ObservationIgnored private let terminalController: any WezTermControlling
  @ObservationIgnored private let agentRegistrationInbox: AgentRegistrationInbox
  @ObservationIgnored private let verifier: any CompletionVerifying
  @ObservationIgnored private let queueAgent: any QueueAgentChatting
  @ObservationIgnored private let pullRequestQueueLoader: any PullRequestQueueLoading
  @ObservationIgnored private let taskContextStore: TaskContextStore
  @ObservationIgnored private let taskWorktreeManager = TaskWorktreeManager()
  @ObservationIgnored private let taskAgentLauncher: TaskAgentLauncher
  @ObservationIgnored private let objectiveRouter: any QueueObjectiveRouting
  @ObservationIgnored private let routerMonitorIntervalSeconds: Double
  @ObservationIgnored private let routerUndoWindowSeconds: Double
  @ObservationIgnored private let agentLaunchLogger: AgentLaunchLogger
  @ObservationIgnored private let reportHistoryRepository: JSONDailyReportHistoryRepository
  @ObservationIgnored private let conversationStore: QueueConversationStore
  @ObservationIgnored private let durableLibrary: DurableLibraryStore
  @ObservationIgnored private let connectorDiagnosticsRunner: any ProcessRunning
  @ObservationIgnored private var durableErrors: [String: String] = [:]
  @ObservationIgnored private var durableRetryAfter: [String: Date] = [:]
  @ObservationIgnored private var lastDurableState: LocalState?
  @ObservationIgnored private var lastDurableDashboard: DashboardDocument?
  @ObservationIgnored private var lastDurableReports: [String: DailyReportDocument] = [:]
  @ObservationIgnored private var lastDurableContexts: [String: TaskContext] = [:]
  @ObservationIgnored private var durableDocumentStamps: [String: DurableDocumentStamp] = [:]
  @ObservationIgnored private var lastContextRefresh: Date?
  @ObservationIgnored private var lastDashboardRead: Date?
  @ObservationIgnored private var lastDashboardStamp: DashboardFileStamp?
  @ObservationIgnored private var lastDurableContextScan: Date?
  @ObservationIgnored private var lastExternalRegistrationRefresh: Date?
  @ObservationIgnored private var reportStateSaveTask: Task<Void, Never>?
  @ObservationIgnored private var cleanupSignatures: [String: Date] = [:]
  @ObservationIgnored private var lastReportRefresh: Date?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var routerMonitorTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var routerLaunchTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var pendingRouterSubmissions: [UUID: PendingRouterSubmission] = [:]
  @ObservationIgnored private var pendingRouterSubmissionOrder: [UUID] = []
  @ObservationIgnored private var launchingRouterSubmissionIDs: Set<UUID> = []
  @ObservationIgnored private var reviewTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var windowSaveTask: Task<Void, Never>?
  @ObservationIgnored private var localStateSaveTask: Task<Void, Never>?
  @ObservationIgnored private var queueChatTask: Task<Void, Never>?
  @ObservationIgnored private var documentConversations: [String: DocumentConversation] = [:]
  @ObservationIgnored private var configurationSaveTask: Task<Void, Never>?
  @ObservationIgnored private var lastRecurringPRRefresh: Date?
  @ObservationIgnored private var bootstrapped = false
  @ObservationIgnored private(set) var bootstrapTail: Task<Void, Never>?
  @ObservationIgnored private var refreshInFlight = false
  @ObservationIgnored private var projectRefreshPending = false
  @ObservationIgnored private var lastActivityCheck = Date()
  @ObservationIgnored private let agentActivityObserver: AgentActivityObserver
  @ObservationIgnored private var quotaFallbackedSubtaskKeys: Set<String> = []
  @ObservationIgnored private var quotaFallbackAtByTicketID: [String: Date] = [:]
  @ObservationIgnored private var escalationAutoLaunchInFlight = false
  @ObservationIgnored private var routerProviders: [String: AgentProvider] = [:]
  @ObservationIgnored private var lastIdentityRefresh: Date?
  @ObservationIgnored private var lastManagedPresentationRefresh: Date?
  @ObservationIgnored private var panelVisible = true
  @ObservationIgnored private var subtaskEditTokens: [String: UUID] = [:]
  @ObservationIgnored private var subtaskEditTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var planPresentationID = UUID()
  @ObservationIgnored private var planReadID = UUID()
  @ObservationIgnored private var lastExternalAgentDiscovery: Date?
  @ObservationIgnored private var forcedIntakeReferenceKeys: Set<String> = []
  @ObservationIgnored private var labeledIntakeReferenceKeys: Set<String> = []
  @ObservationIgnored private let discoverExternalAgents: @Sendable () async throws -> [KnownProviderProcess]
  @ObservationIgnored private let providerExecutableAvailable: @Sendable (AgentProvider) -> Bool
  @ObservationIgnored private let labelTmuxPane: @Sendable (TmuxSessionReference, String) async -> Void
  @ObservationIgnored private let locateExistingAgent: @Sendable (AgentProvider, String) async throws -> KnownProviderProcess?
  @ObservationIgnored private let identifyManagedAgent: (@Sendable (TaskSubtask, WezTermConfiguration) async throws -> String?)?

  @ObservationIgnored var placementHandler: ((QueueWindowPlacement) -> Void)?
  @ObservationIgnored var monitorSwitchHandler: (() -> Void)?
  @ObservationIgnored var minimizeHandler: (() -> Void)?
  @ObservationIgnored var panelModeHandler: ((QueuePanelMode) -> Void)?
  @ObservationIgnored var reportVisibilityHandler: ((Bool) -> Void)?
  @ObservationIgnored var dailyReportRunHandler: (
    @MainActor (DailyReportRunRequest) async -> DailyReportDocument?
  )?
  @ObservationIgnored var dailyReportCancelHandler: (() -> Void)?
  @ObservationIgnored var dailyReportApprovalHandler: (@MainActor (Bool) async -> Void)?
  @ObservationIgnored var dailyReportsEnabledHandler: ((Bool) -> Void)?
  @ObservationIgnored var programLogVisibilityHandler: ((Bool) -> Void)?
  @ObservationIgnored var agentTerminalFocusHandler: (@MainActor (String, String) async throws -> Void)?
  @ObservationIgnored var terminalFocusHandler: (
    @MainActor (String, String?) async throws -> Void
  )?
  @ObservationIgnored var quitHandler: (() -> Void)?

  init(
    paths: AppPaths = .live(),
    programLog: ProgramLogStore = ProgramLogStore(),
    configurationRepository: (any ConfigurationLoading)? = nil,
    dailyReportRepository: (any DailyReportStoring)? = nil,
    dailyReportApprovalRepository: (any DailyReportApprovalStoring)? = nil,
    dashboardRepository: any DashboardManaging = JSONDashboardRepository(),
    stateStore: (any LocalStateStoring)? = nil,
    reviewArtifacts: ReviewArtifactStore? = nil,
    terminalController: any WezTermControlling = WezTermController(),
    agentRegistrationInbox: AgentRegistrationInbox? = nil,
    verifier: any CompletionVerifying = CodexCompletionVerifier(),
    queueAgent: any QueueAgentChatting = CodexQueueAgent(),
    pullRequestQueueLoader: any PullRequestQueueLoading = GitHubPullRequestQueueLoader(),
    taskAgentLauncher: TaskAgentLauncher = TaskAgentLauncher(),
    objectiveRouter: any QueueObjectiveRouting = QueueObjectiveRouter(),
    routerMonitorIntervalSeconds: Double = 2,
    routerUndoWindowSeconds: Double = 3,
    agentLaunchLogger: AgentLaunchLogger? = nil,
    connectorDiagnosticsRunner: any ProcessRunning = FoundationProcessRunner(),
    agentActivityObserver: AgentActivityObserver = AgentActivityObserver(),
    discoverExternalAgents: (@Sendable () async throws -> [KnownProviderProcess])? = nil,
    labelTmuxPane: @escaping @Sendable (TmuxSessionReference, String) async -> Void = { reference, title in
      _ = try? await TmuxController().label(reference, title: title)
    },
    maintenanceEnabled: Bool = true,
    identifyManagedAgent: (@Sendable (TaskSubtask, WezTermConfiguration) async throws -> String?)? = nil,
    providerExecutableAvailable: (@Sendable (AgentProvider) -> Bool)? = nil,
    locateExistingAgent: @escaping @Sendable (AgentProvider, String) async throws -> KnownProviderProcess? = { provider, sessionID in
      try await WezTermController().locateProviderProcess(provider: provider, sessionID: sessionID)
    }
  ) {
    self.paths = paths
    self.programLog = programLog
    self.maintenanceEnabled = maintenanceEnabled
    let processDiscovery = WezTermController()
    self.discoverExternalAgents = discoverExternalAgents ?? {
      try await processDiscovery.knownProviderProcesses().resolved
    }
    self.labelTmuxPane = labelTmuxPane
    self.identifyManagedAgent = identifyManagedAgent
    self.providerExecutableAvailable = providerExecutableAvailable ?? {
      SetupEnvironment.executable($0.executableName) != nil
    }
    self.locateExistingAgent = locateExistingAgent
    self.taskContextStore = TaskContextStore(root: paths.supportDirectory)
    self.reportHistoryRepository = JSONDailyReportHistoryRepository(runtimeDirectory: paths.ingestionRuntimeDirectory)
    self.conversationStore = QueueConversationStore(root: paths.supportDirectory)
    self.durableLibrary = DurableLibraryStore(root: paths.supportDirectory)
    self.config = SetupEnvironment.starter(supportDirectory: paths.supportDirectory)
    self.configurationRepository =
      configurationRepository
      ?? JSONConfigurationRepository(url: paths.configurationFile)
    self.dailyReportRepository =
      dailyReportRepository ?? JSONDailyReportRepository(url: paths.latestDailyReportFile)
    self.dailyReportApprovalRepository =
      dailyReportApprovalRepository
      ?? JSONDailyReportApprovalRepository(url: paths.dailyReportApprovalFile)
    self.dashboardRepository = dashboardRepository
    self.stateStore = stateStore ?? JSONLocalStateStore(url: paths.stateFile)
    self.reviewArtifacts = reviewArtifacts ?? ReviewArtifactStore(directory: paths.reviewsDirectory)
    self.terminalController = terminalController
    self.agentRegistrationInbox =
      agentRegistrationInbox ?? AgentRegistrationInbox(directory: paths.agentRegistrationsDirectory)
    self.verifier = verifier
    self.queueAgent = queueAgent
    self.pullRequestQueueLoader = pullRequestQueueLoader
    self.taskAgentLauncher = taskAgentLauncher
    self.objectiveRouter = objectiveRouter
    self.routerMonitorIntervalSeconds = max(0.01, routerMonitorIntervalSeconds)
    self.routerUndoWindowSeconds = max(0, routerUndoWindowSeconds)
    self.agentLaunchLogger = agentLaunchLogger
      ?? AgentLaunchLogger(supportDirectory: paths.supportDirectory)
    self.connectorDiagnosticsRunner = connectorDiagnosticsRunner
    self.agentActivityObserver = agentActivityObserver
  }

  var openTickets: [DashboardTicket] {
    allOpenTickets.filter { includesInProject($0) }
  }

  private var allOpenTickets: [DashboardTicket] {
    let baseline: [DashboardTicket]
    if let savedQueueOrder {
      baseline = QueueOrderStore.orderedTickets(dashboard.tickets, savedIDs: savedQueueOrder)
    } else {
      let ordered = DashboardOrdering.openTickets(
        in: dashboard.tickets,
        deferredTicketIDs: localState.deferredTicketIDs
      )
      let noBacklogIDs = Set(
        recurringPRProgressByTicketID.compactMap { ticketID, progress in
          progress.openCount == 0 ? ticketID : nil
        }
      )
      let closurePending = dashboard.tickets.filter { $0.isCompleted && closureMessages[$0.id] != nil }
      baseline = closurePending + ordered.filter { !noBacklogIDs.contains($0.id) }
        + ordered.filter { noBacklogIDs.contains($0.id) }
    }
    return QueueOrderStore.prioritizingRecentPrompts(
      baseline,
      lastPromptAtByTicketID: taskContexts.compactMapValues(\.lastPromptAt))
  }

  var completedTickets: [DashboardTicket] {
    projectTickets
      .filter { $0.isCompleted && closureMessages[$0.id] == nil }
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
    localState.completedRoutineIDs.intersection(Set(visibleRoutines.map(\.id))).count
  }

  var selectedProjectID: String? {
    config.selectedProjectID
  }
  var projectScopeName: String { selectedProject?.name ?? "No project" }
  var activeProjects: [ProjectDefinition] { config.projects.filter { $0.archivedAt == nil } }
  var projectTickets: [DashboardTicket] { dashboard.tickets }
  var hasUnassignedTasks: Bool { false }
  var visibleRoutines: [DailyRoutine] {
    config.dailyRoutines.filter { routine in
      guard let owner = routine.projectID else { return true }
      return owner == selectedProjectID
    }
  }
  func project(for ticket: DashboardTicket) -> ProjectDefinition? { selectedProject }
  func includesInProject(_ ticket: DashboardTicket) -> Bool { true }
  func revealProject(for ticketID: String) {}
  func defaultRepository(for ticket: DashboardTicket) -> String {
    let context = taskContexts[ticket.id]
    // New agents branch from the task's canonical project repository. An
    // existing agent worktree belongs only to that agent and must never become
    // the source checkout for the next one-click launch.
    return [context?.projectRepositoryPath, selectedProject?.repositoryPath,
            context?.repositoryPath, selectedProject?.workspacePath,
            ticket.worktree, context?.worktreePath]
      .compactMap { $0 }.first { !$0.isEmpty } ?? config.workspacePath
  }
  @discardableResult
  func saveProject(_ project: ProjectDefinition) async -> Bool {
    guard !isSavingProject else { return false }
    isSavingProject = true
    defer { isSavingProject = false }
    do {
      if project.id == ProjectCatalog.otherID, project.archivedAt != nil {
        throw TaskContextError.commandFailed("Other is the fallback project and cannot be archived.")
      }
      var next = config
      let isNew = next.projects.contains(where: { $0.id == project.id }) == false
      if let index = next.projects.firstIndex(where: { $0.id == project.id }) { next.projects[index] = project }
      else { next.projects.append(project) }
      _ = try next.validated()
      if isNew {
        var prepared = next
        guard prepared.selectProject(id: project.id) else {
          throw TaskContextError.commandFailed("The new project could not be selected.")
        }
        try SetupEnvironment.prepareWorkspace(configuration: prepared)
      }
      configurationSaveTask?.cancel()
      await configurationSaveTask?.value
      try await configurationRepository.save(next)
      config = next
      lastContextRefresh = nil
      await refresh()
      projectError = nil
      return true
    } catch { projectError = error.localizedDescription; return false }
  }
  @discardableResult
  func assignProject(_ projectID: String?, to ticketID: String) async -> Bool {
    projectError = "Move the task from its project dashboard after finishing active agent work."
    return false
  }
  func createTask(title: String, summary: String, projectID: String?) async -> Bool {
    await createTask(title: title, summary: summary, doneWhen: "", priority: "medium",
      projectID: projectID)
  }

  var configurationURL: URL { paths.configurationFile }
  var projects: [ProjectConfiguration] { config.projects }
  var selectedProject: ProjectConfiguration? { config.selectedProject }
  var windowSnapshot: WindowSnapshot? { localState.window }
  var appearance: QueueAppearance { localState.appearance ?? .light }
  var accentStyle: QueueAccentStyle { localState.accentStyle ?? .vibrant }
  var windowPlacement: QueueWindowPlacement {
    localState.window?.placement ?? config.defaultPlacement
  }

  var isPanelCollapsed: Bool { panelMode == .collapsed }
  var isTopTaskOnly: Bool { panelMode == .topTask }
  var minimizationPreference: QueueMinimizationPreference {
    localState.minimizationPreference
  }
  var hasRouterRecovery: Bool {
    (!routerRuntimes.isEmpty || routerRecoveryBlocked) && !isRoutingObjective
  }
  var canOpenRouterRecovery: Bool { !routerRuntimes.isEmpty && !isRoutingObjective }

  var terminalCount: Int {
    var identities = Set(localState.agentSessions.map {
      "\($0.provider.rawValue):\($0.sessionID.lowercased())"
    })
    identities.formUnion(unassignedAgentRegistrations.map {
      "\($0.provider.rawValue):\(($0.sessionID ?? $0.agentID ?? $0.id).lowercased())"
    })
    return identities.count
  }

  func bootstrap() async {
    guard !bootstrapped else { return }
    bootstrapped = true
    do {
      let firstRun = !FileManager.default.fileExists(atPath: paths.configurationFile.path)
      if firstRun { try SetupEnvironment.createStarterWorkspace(supportDirectory: paths.supportDirectory) }
      _ = try ProjectCreationTransaction(
        supportDirectory: paths.supportDirectory,
        configurationURL: paths.configurationFile
      ).recoverPending()
      config = try await configurationRepository.loadOrCreate(default: SetupEnvironment.starter(supportDirectory: paths.supportDirectory))
      isSetupPresented = firstRun || config.setupCompleted == false
      configurationIsLoaded = true
      localState = try await stateStore.load()
      localState.selectedProjectID = selectedProjectID
      await primePresentationFromDisk()
    } catch {
      loadError = error.localizedDescription
      if !configurationIsLoaded { isSetupPresented = true }
      return
    }
    // Router probes, tmux presentation, and process inspection can take many
    // seconds. Reconcile them after the panel already renders the saved queue.
    bootstrapTail = Task { @MainActor [weak self] in
      await self?.finishBootstrap()
    }
  }

  /// Read-only disk load so agent boxes render before any reconciliation runs.
  private func primePresentationFromDisk() async {
    let dashboardURL = URL(fileURLWithPath: config.dashboardPath)
    if let document = try? await dashboardRepository.load(from: dashboardURL) {
      dashboard = document
    }
    if let order = try? queueOrderStore.load() { savedQueueOrder = order }
    taskContexts = await availableTaskContexts()
  }

  /// Tolerant read-only contexts. Swap whole dictionaries so the panel never
  /// shows an empty queue while replacement data is still loading.
  private func availableTaskContexts() async -> [String: TaskContext] {
    let discovered = (try? await taskContextStore.loadAvailableForDiscovery()) ?? []
    return Dictionary(discovered.map { ($0.ticketID, $0) }, uniquingKeysWith: { _, last in last })
  }

  private func finishBootstrap() async {
    do {
      // Unstick routed startup receipts before recovering routers so their
      // outcomes resolve immediately instead of wedging router slots. A sweep
      // failure must not block the rest of bootstrap.
      if let repair = try? await AgentStartupRepair(root: paths.supportDirectory).run(),
         !repair.failedReceipts.isEmpty {
        let summaries = repair.failedReceipts.map {
          "\($0.taskID) (\($0.title.isEmpty ? $0.subtaskID : $0.title))"
        }.joined(separator: ", ")
        startupRepairAlert = "Routed agent startups that never finished were marked failed: \(summaries). Route the work again from the Router agent."
      }
      do {
        let routerStore = QueueRouterRuntimeStore(root: paths.supportDirectory)
        let recoveredRouters = try routerStore.activeRouters()
        for recoveredRouter in recoveredRouters {
          guard routerExecutableMatchesConfiguration(recoveredRouter) else {
            throw TaskContextError.commandFailed(
              "A saved router does not match the configured tmux executable.")
          }
          trackRouterRuntime(recoveredRouter, provider: nil)
          routerRecoveryPath = (try? routerStore.url(routerID: recoveredRouter.tmuxName).path)
            ?? routerStore.url.path
          routerStatus = recoveredRouters.count == 1
            ? "Recovered an unfinished router. Focus Queue will not start a duplicate."
            : "Recovered \(recoveredRouters.count) unfinished routers. Focus Queue will not start duplicates."
          let outcome = try await objectiveRouter.waitForOutcome(
            recoveredRouter, supportDirectory: paths.supportDirectory, timeoutSeconds: 0)
          if !applyRouterOutcome(outcome, for: recoveredRouter), case .waiting = outcome {
            startRouterMonitor(recoveredRouter)
          }
        }
      } catch {
        routerRecoveryBlocked = true
        routerRecoveryPath = QueueRouterRuntimeStore(root: paths.supportDirectory).url.path
        routerStatus = "Router recovery needs attention; new routing is blocked. \(error.localizedDescription)"
      }
      updateRouterCapacity()
      let projects = ProjectCatalog.ensuringOther(
        in: config.projects, supportDirectory: paths.supportDirectory)
      if projects != config.projects {
        config.projects = projects
        try await configurationRepository.save(config)
      }
      for project in config.projects {
        try ProjectCatalog.prepareFallbackStorage(for: project)
        _ = try ProjectContextStore(root: paths.supportDirectory).ensurePlan(for: project)
      }
      if let tmux = SetupEnvironment.executable("tmux"),
        config.tmuxExecutable != tmux
      {
        config.tmuxExecutable = tmux
        try await configurationRepository.save(config)
      }
      // Preserve the prior task associations before registration can move them.
      await captureDurableState(localState)
      if let saved = try await conversationStore.load(ticketID: nil), !saved.isEmpty {
        queueChatMessages = saved
      }
      isRecoveredDailyReportRunning = try await reportHistoryRepository.reconcileInactiveRuns()
      await reloadDailyReport()
      if config.dailyReport.enabled,
        let approval = try await dailyReportApprovalRepository.load(),
        approval.status == .pending,
        approval.reportDate == Self.dayFormatter.string(from: Date())
      {
        pendingDailyReportApproval = approval
      }
      await importAgentRegistrations()
      resetDailyRoutinesIfNeeded()
      recoverInterruptedReviews()
      try await stateStore.save(localState)
      await refresh(forceRecurringPRProgress: true)
      await reconcileDurableLibrary()
      startRefreshLoop()
      resumePendingReviews()
      programLog.record(
        "Ready with project \(selectedProject?.name ?? "Unknown").",
        category: "Lifecycle"
      )
    } catch {
      loadError = error.localizedDescription
    }
  }

  @discardableResult
  func reloadConfigurationFromDisk() async -> Bool {
    configurationSaveTask?.cancel()
    await configurationSaveTask?.value
    do {
      let reloaded = try await configurationRepository.loadOrCreate(
        default: SetupEnvironment.starter(supportDirectory: paths.supportDirectory))
      let selectionChanged = reloaded.selectedProjectID != config.selectedProjectID
        || reloaded.dashboardPath != config.dashboardPath
      if selectionChanged {
        let snapshot = try await dashboardRepository.loadSnapshot(
          from: URL(fileURLWithPath: reloaded.dashboardPath))
        config = reloaded
        closeAgentUpdate()
        closePlan()
        setQueueChatInspectorPresented(false)
        setDailyReportPresented(false)
        dashboard = snapshot.document
        savedQueueOrder = nil
        sourceModificationDate = nil
        lastDashboardStamp = nil
        lastDashboardRead = nil
        lastSync = nil
        taskContexts = await availableTaskContexts()
        maintenanceReceipts.removeAll()
        maintenanceSignatures.removeAll()
        cleanupSignatures.removeAll()
        recurringPRProgressByTicketID.removeAll()
        recurringPRProgressErrors.removeAll()
        expandedTicketIDs.removeAll()
        documentConversations.removeAll()
        lastContextRefresh = nil
        lastDurableDashboard = nil
        await captureDurableDashboard(snapshot.document)
      } else {
        config = reloaded
      }
      loadError = nil
      return true
    } catch {
      loadError = "Could not reload projects: \(error.localizedDescription)"
      return false
    }
  }

  func finishSetup(_ configuration: AppConfiguration) async -> Bool {
    configurationSaveTask?.cancel()
    await configurationSaveTask?.value
    do {
      try SetupEnvironment.prepareWorkspace(configuration: configuration)
      var updated = configuration
      updated.setupCompleted = true
      if updated.tmuxExecutable?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
        updated.tmuxExecutable = nil
        updated.persistentTerminals = false
      }
      if let executable = updated.tmuxExecutable,
        !FileManager.default.isExecutableFile(atPath: executable) {
        throw ProcessRunnerError.executableMissing(executable)
      }
      if FileManager.default.fileExists(atPath: paths.configurationFile.path) {
        let backup = paths.supportDirectory.appendingPathComponent("backups/setup-\(UUID().uuidString).json")
        try SystemFileAccessor().write(Data(contentsOf: paths.configurationFile), to: backup)
      }
      try await configurationRepository.save(updated)
      config = updated
      setupError = nil
      isSetupPresented = false
      if !configurationIsLoaded {
        bootstrapped = false
        await bootstrap()
      } else {
        await refresh()
      }
      return true
    } catch {
      setupError = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func selectProject(id: String) async -> Bool {
    guard config.selectedProjectID != id,
      let project = config.projects.first(where: { $0.id == id })
    else { return config.selectedProjectID == id }

    configurationSaveTask?.cancel()
    await configurationSaveTask?.value
    do {
      // Validate the destination before changing the persisted selection. A
      // damaged project must leave the current queue intact and selected.
      let snapshot = try await dashboardRepository.loadSnapshot(
        from: URL(fileURLWithPath: project.dashboardPath))
      var updated = config
      guard updated.selectProject(id: id) else { return false }
      try await configurationRepository.save(updated)
      config = updated
      programLog.record("Selected project \(project.name).", category: "Projects")

      closeAgentUpdate()
      closePlan()
      setQueueChatInspectorPresented(false)
      setDailyReportPresented(false)
      dashboard = snapshot.document
      loadError = nil
      savedQueueOrder = nil
      sourceModificationDate = nil
      lastDashboardStamp = nil
      lastDashboardRead = nil
      lastSync = nil
      taskContexts = await availableTaskContexts()
      maintenanceReceipts.removeAll()
      maintenanceSignatures.removeAll()
      cleanupSignatures.removeAll()
      recurringPRProgressByTicketID.removeAll()
      recurringPRProgressErrors.removeAll()
      expandedTicketIDs.removeAll()
      documentConversations.removeAll()
      lastContextRefresh = nil
      lastDurableDashboard = nil
      await captureDurableDashboard(snapshot.document)
      if refreshInFlight {
        projectRefreshPending = true
      } else {
        await refresh(forceRecurringPRProgress: true, userInitiated: true)
      }
      return loadError == nil
    } catch {
      loadError = "Could not switch projects: \(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  func createTask(
    title: String, summary: String, doneWhen: String, priority: String,
    projectID: String? = nil
  ) async -> Bool {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      loadError = "Give the task a readable title."
      return false
    }
    let targetID = projectID ?? config.selectedProjectID
    guard let project = config.projects.first(where: { $0.id == targetID }) else {
      loadError = "The selected project is no longer configured."
      return false
    }
    do {
      let url = URL(fileURLWithPath: project.dashboardPath)
      let snapshot = try await dashboardRepository.loadSnapshot(from: url)
      let otherDashboards = config.projects.filter { $0.id != project.id }.map {
        URL(fileURLWithPath: $0.dashboardPath)
      }
      var knownTickets = snapshot.document.tickets
      for otherDashboard in otherDashboards {
        knownTickets.append(contentsOf: try await dashboardRepository.load(from: otherDashboard).tickets)
      }
      let ticketID = Self.nextTicketID(
        project: project, projectTickets: snapshot.document.tickets, allTickets: knownTickets)
      let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedDoneWhen = doneWhen.trimmingCharacters(in: .whitespacesAndNewlines)
      let ticket = DashboardTicket(
        id: ticketID,
        title: title,
        projectID: project.id,
        category: project.name,
        priority: Self.allowedPriority(priority),
        status: "backlog",
        summary: String((trimmedSummary.isEmpty ? title : trimmedSummary).prefix(1_200)),
        next: "Clarify the next implementation step.",
        doneWhen: String(
          (trimmedDoneWhen.isEmpty
            ? "Confirm the requested behavior and record verification results."
            : trimmedDoneWhen).prefix(900)),
        updatedAt: Self.dayFormatter.string(from: Date())
      )
      let updated = try await dashboardRepository.createTicket(
        ticket, in: url, expectedRevision: snapshot.revision,
        checking: otherDashboards)
      if config.selectedProjectID == project.id {
        dashboard = updated.document
        await captureDurableDashboard(updated.document)
      }
      actionMessages[ticket.id] = "Task added to \(project.name)."
      programLog.record("Created task \(ticket.id): \(ticket.title)", category: "Tasks")
      loadError = nil
      return true
    } catch {
      loadError = "Could not create task: \(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  func renameTask(_ ticket: DashboardTicket, to title: String) async -> Bool {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, let project = selectedProject else {
      actionMessages[ticket.id] = "Give the task a readable title."
      return false
    }
    do {
      let projectID = project.id
      let url = URL(fileURLWithPath: project.dashboardPath)
      let snapshot = try await dashboardRepository.loadSnapshot(from: url)
      let updated = try await dashboardRepository.renameTicket(
        id: ticket.id, to: title, in: url, expectedRevision: snapshot.revision)
      let renamed = updated.document.tickets.first(where: { $0.id == ticket.id })
      if config.selectedProjectID == projectID {
        dashboard = updated.document
        if var liveContext = taskContexts[ticket.id] {
          liveContext.title = title
          taskContexts[ticket.id] = liveContext
        }
      }

      var contextRepairError: String?
      if let renamed {
        var contextExists = taskContexts[ticket.id] != nil
        if !contextExists {
          do {
            contextExists = try await taskContextStore.load(ticketID: ticket.id) != nil
          } catch {
            contextRepairError = error.localizedDescription
          }
        }
        if contextExists {
          do {
            let repaired = try await taskContextStore.ensureContext(ticket: renamed)
            if config.selectedProjectID == projectID {
              taskContexts[ticket.id] = repaired
              await captureDurableContexts(Array(taskContexts.values))
            }
          } catch {
            contextRepairError = error.localizedDescription
          }
        }
      }
      if config.selectedProjectID == projectID {
        await captureDurableDashboard(updated.document)
        actionMessages[ticket.id] = contextRepairError.map {
          "Task title updated. Context repair will retry: \($0)"
        } ?? "Task title updated."
        loadError = nil
      }
      return true
    } catch {
      actionMessages[ticket.id] = "Could not rename task: \(error.localizedDescription)"
      return false
    }
  }

  private static func nextTicketID(
    project: ProjectConfiguration,
    projectTickets: [DashboardTicket],
    allTickets: [DashboardTicket]
  ) -> String {
    func parse(_ tickets: [DashboardTicket]) -> [(String, Int, Int)] {
      tickets.compactMap { ticket -> (String, Int, Int)? in
        let parts = ticket.id.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, let number = Int(parts[1]) else { return nil }
        return (parts[0].uppercased(), number, parts[1].count)
      }
    }
    let allIDs = parse(allTickets)
    let prefix = project.taskPrefix
    let matching = allIDs.filter { $0.0 == prefix }
    let next = (matching.map { $0.1 }.max() ?? 0) + 1
    let width = max(3, matching.map { $0.2 }.max() ?? 0)
    return "\(prefix)-\(String(format: "%0\(width)d", next))"
  }

  private static func allowedPriority(_ rawValue: String) -> String {
    let value = rawValue.lowercased()
    return ["low", "medium", "high", "critical"].contains(value) ? value : "medium"
  }

  func refresh(forceRecurringPRProgress: Bool = false, userInitiated: Bool = false) async {
    guard !refreshInFlight else { return }
    refreshInFlight = true
    let showsActivity = userInitiated || lastSync == nil
    if showsActivity { isRefreshing = true }
    defer {
      refreshInFlight = false
      if showsActivity { isRefreshing = false }
      if projectRefreshPending {
        projectRefreshPending = false
        Task { @MainActor [weak self] in
          await self?.refresh(forceRecurringPRProgress: true, userInitiated: true)
        }
      }
    }
    do {
      let projectID = config.selectedProjectID
      let dashboardURL = URL(fileURLWithPath: config.dashboardPath)
      let now = Date()
      let stamp = try await Task.detached(priority: .utility) {
        try DashboardFileStamp.read(at: dashboardURL)
      }.value
      let needsDashboardRead = userInitiated || lastDashboardStamp != stamp
        || lastDashboardRead.map { now.timeIntervalSince($0) >= 60 } ?? true
      if needsDashboardRead {
        let updatedDashboard = try await dashboardRepository.load(from: dashboardURL)
        guard projectID == config.selectedProjectID else { return }
        if dashboard != updatedDashboard { dashboard = updatedDashboard }
        if lastDurableDashboard != updatedDashboard { await captureDurableDashboard(updatedDashboard) }
        lastDashboardStamp = stamp
        lastDashboardRead = now
      }
      guard projectID == config.selectedProjectID else { return }
      let updatedOrder = try queueOrderStore.load()
      if savedQueueOrder != updatedOrder { savedQueueOrder = updatedOrder }
      pruneDeferredTickets()
      if sourceModificationDate != stamp.modifiedAt { sourceModificationDate = stamp.modifiedAt }
      // The footer displays minute precision. Polling every two seconds does
      // not require republishing that unchanged label through the queue view.
      if lastSync == nil || Int(now.timeIntervalSince1970 / 60) != Int(lastSync!.timeIntervalSince1970 / 60) {
        lastSync = now
      }
      if loadError != nil { loadError = nil }
      resetDailyRoutinesIfNeeded()
      await importAgentRegistrations()
      await refreshTaskContexts()
      await consumeEscalationLaunchRequests()
      if panelVisible { await refreshExternalAgentRegistrations() }
      if maintenanceEnabled {
        let recoverySweep = lastMaintenanceAt == nil || Date().timeIntervalSince(lastMaintenanceAt!) >= 60
        if recoverySweep { lastMaintenanceAt = Date() }
        var dueTickets: [DashboardTicket] = []
        for ticket in dashboard.tickets {
          guard let context = taskContexts[ticket.id] else { continue }
          // Semantic events trigger a pass; frequent heartbeat timestamps do not.
          let signature = context.successCriteria + context.subtasks.map {
            [$0.id, $0.sessionID ?? "", $0.status.rawValue, $0.resultID ?? "", $0.workspace?.path ?? "",
             $0.agentRemovedAt == nil ? "visible" : "removed"].joined(separator: "|")
          }.joined(separator: "\n")
          guard recoverySweep || maintenanceSignatures[ticket.id] != signature else { continue }
          maintenanceSignatures[ticket.id] = signature
          dueTickets.append(ticket)
        }
        if !dueTickets.isEmpty {
          // One complete process snapshot covers every ticket's inspection pass.
          // An unresolved process means ownership is unknown, so the snapshot is
          // withheld and maintenance falls back to its own fail-closed check.
          let scan = try? await WezTermController().knownProviderProcesses(requireComplete: true)
          let maintenance = TaskMaintenance(root: paths.supportDirectory,
            processes: scan.flatMap { $0.unresolved.isEmpty ? $0.resolved : nil })
          for ticket in dueTickets {
            do {
              let receipt = try await maintenance.run(ticket: ticket)
              if maintenanceReceipts[ticket.id] != receipt { maintenanceReceipts[ticket.id] = receipt }
            } catch {
              maintenanceReceipts[ticket.id] = .init(ticketID: ticket.id,
                notes: ["Maintenance retained existing data: \(error.localizedDescription)"])
            }
          }
        }
      }
      await runStaleAgentSweepIfDue()
      if userInitiated || lastReportRefresh == nil || Date().timeIntervalSince(lastReportRefresh!) >= 30 {
        lastReportRefresh = Date()
        if !isDailyReportRunning {
          isRecoveredDailyReportRunning = try await reportHistoryRepository.reconcileInactiveRuns()
          if !isRecoveredDailyReportRunning { isDailyReportCancellationRequested = false }
        }
        await reloadDailyReport(preservingSelection: true)
      }
      await refreshRecurringPRProgressIfNeeded(force: forceRecurringPRProgress)
    } catch {
      if loadError != error.localizedDescription { loadError = error.localizedDescription }
      // A missing dashboard must not disable mandatory agent tracking.
      if panelVisible { await refreshExternalAgentRegistrations() }
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
  func moveTicket(_ ticketID: String, to placement: QueuePlacement) -> Bool {
    do {
      savedQueueOrder = try queueOrderStore.move(ticketID, to: placement,
        tickets: dashboard.tickets, fallbackIDs: allOpenTickets.filter(\.isOpen).map(\.id),
        visibleIDs: selectedProjectID.map { _ in Set(projectTickets.map(\.id)) })
      actionMessages[ticketID] = "Queue position saved on this Mac."
      return true
    } catch {
      actionMessages[ticketID] = error.localizedDescription
      return false
    }
  }

  func resetQueueOrder() {
    do {
      try queueOrderStore.reset()
      savedQueueOrder = []
    } catch { loadError = error.localizedDescription }
  }

  @discardableResult
  func moveTicketToRest(_ ticketID: String) -> Bool {
    let others = openTickets.filter { $0.isOpen && $0.id != ticketID }
    return moveTicket(ticketID, to: others.count > 5 ? .before(others[5].id) : .bottom)
  }

  @discardableResult
  func moveTicketToToday(_ ticketID: String) -> Bool {
    moveTicket(ticketID, to: .top)
  }

  @discardableResult
  func sendQueueAgentMessage(
    _ rawMessage: String, ticketID: String? = nil,
    canvasSelection: PlanCanvasSelection? = nil
  ) -> Bool {
    let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, !isQueueAgentResponding else { return false }
    guard !reportIsRunning else {
      dailyReportRunMessage = "Wait for the daily report to finish before editing the queue."
      return false
    }

    appendChat(
      QueueChatMessage(role: .user, text: message, canvasSelection: canvasSelection),
      ticketID: ticketID)
    isQueueAgentResponding = true
    respondingTicketID = ticketID
    if ticketID == nil,
      let reportRequest = DailyReportChatCommand.parse(
        message,
        enabledPlatforms: config.dailyReport.enabledPlatforms
      )
    {
      runDailyReportFromChat(reportRequest)
      return true
    }
    let visibleOrder = openTickets.map(\.id)
    let scopedTaskIDs = ticketID.map { [$0] } ?? projectTickets.map(\.id)
    let chatWorkspace = ticketID.flatMap { id in dashboard.tickets.first { $0.id == id }.map(defaultRepository) }
      ?? selectedProject?.repositoryPath ?? config.workspacePath
    let deferredTicketIDs = savedQueueOrder == nil ? localState.deferredTicketIDs.filter { scopedTaskIDs.contains($0) } : []
    let scopedMessage: String
    var agentConfiguration = config.verifier
    agentConfiguration.supportDirectory = paths.supportDirectory.path
    // Central QChat can inspect every configured project. Task chat retains its
    // task's project scope for task-specific helpers.
    agentConfiguration.projectScopeID = ticketID.map { id in
      dashboard.tickets.first { $0.id == id }?.projectID ?? selectedProjectID
    } ?? nil
    agentConfiguration.contextDirectory =
      paths.supportDirectory.appendingPathComponent("tasks").path
    let contextualMessage =
      canvasSelection?.orchestratorMessage(userRequest: message) ?? message
    if let ticketID, let context = taskContexts[ticketID] {
      agentConfiguration.sessionName = "ecc-focus-queue-task-\(ticketID.lowercased())"
      agentConfiguration.contextDirectory = context.contextDirectory.path
      let taskScope = "Task scope: \(ticketID). Read its central plan at \(context.planPath). "
      let contextScope = """
        Context folder: \(context.contextDirectory.path).
        Apply changes only when requested.

        """
      scopedMessage = taskScope + "Project: \(context.projectName ?? context.projectID ?? "Unassigned"). " + contextScope + contextualMessage
    } else {
      let catalog = config.projects.map { project in
        "- \(project.name) (\(project.id)): dashboard \(project.dashboardPath); workspace \(project.workspacePath)"
      }.joined(separator: "\n")
      let scope = "Selected project: \(projectScopeName) (\(selectedProjectID ?? ProjectCatalog.otherID)). Selected task IDs: \(projectTickets.map(\.id).joined(separator: ", ")).\nConfigured projects, all readable without changing the UI selection:\n\(catalog)\n"
      scopedMessage = scope + "Read the dashboard for the project named in the user's request. Preserve projectID and unknown fields on edits to the selected dashboard.\n\n" + contextualMessage
    }
    queueChatTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.isQueueAgentResponding = false
        self.respondingTicketID = nil
      }
      do {
        for id in scopedTaskIDs.filter({ self.taskContexts[$0] != nil }) {
          self.taskContexts[id] = try await self.taskContextStore.reconcileSubtasks(ticketID: id)
        }
        let reply = try await self.queueAgent.send(
          message: scopedMessage,
          dashboardPath: self.config.dashboardPath,
          workspace: chatWorkspace,
          visibleOrder: visibleOrder,
          deferredTicketIDs: deferredTicketIDs,
          configuration: agentConfiguration
        )
        self.appendChat(QueueChatMessage(role: .agent, text: reply.message), ticketID: ticketID)
        if await self.reloadConfigurationFromDisk() {
          await self.refresh()
        }
        await self.reloadPresentedPlan()
        if self.dailyReport == nil {
          await self.reloadDailyReport()
        }
      } catch {
        self.appendChat(
          QueueChatMessage(role: .agent, text: error.localizedDescription), ticketID: ticketID)
      }
    }
    return true
  }

  var isInspectorPresented: Bool {
    isQueueChatInspectorPresented || isDailyReportPresented || presentedPlanTicketID != nil
      || presentedAgentUpdate != nil
  }

  var presentedPlanTicket: DashboardTicket? {
    dashboard.tickets.first { $0.id == presentedPlanTicketID }
  }

  var reportNeedsAttention: Bool {
    reportIsRunning || reportHasFailure || dailyReportLoadError != nil || reportHistoryError != nil
      || reportAttentionDocument == nil || reportAttentionDocument.map { reportHistory.isUnread($0) } == true
      || reportAttentionDocument.map {
        ($0.reportDate ?? Self.dayFormatter.string(from: Self.reportDate($0.finishedAt)))
          != Self.dayFormatter.string(from: Date())
      } == true
  }

  var reportNotificationID: String {
    if let run = relevantFailedReportRun { return "daily-report-run:\(run.id)" }
    if reportIsRunning, let run = reportHistory.runs.first(where: { $0.phase == .running }) {
      return "daily-report-run:\(run.id)"
    }
    if let report = reportAttentionDocument { return "daily-report:\(report.runID)" }
    let day = Self.dayFormatter.string(from: Date())
    if dailyReportLoadError != nil || reportHistoryError != nil {
      return "daily-report-error:\(day)"
    }
    return "daily-report-missing:\(day)"
  }

  var showsReportNotification: Bool {
    config.dailyReport.enabled && reportNeedsAttention
      && !localState.dismissedNotificationIDs.contains(reportNotificationID)
  }

  var reportAttentionDocument: DailyReportDocument? {
    [latestDailyReport, reportHistory.reports.first].compactMap { $0 }.max {
      Self.reportDate($0.finishedAt) < Self.reportDate($1.finishedAt)
    }
  }

  var reportIsRunning: Bool {
    isDailyReportRunning || isRecoveredDailyReportRunning
      || reportHistory.runs.first?.phase == .running
  }

  var canCancelDailyReport: Bool {
    isDailyReportRunning || isRecoveredDailyReportRunning
  }

  var relevantFailedReportRun: DailyReportRunReceipt? {
    guard let run = reportHistory.runs.first, [.failed, .interrupted].contains(run.phase) else { return nil }
    if let report = reportAttentionDocument, Self.reportDate(report.finishedAt) > run.updatedAt { return nil }
    return run
  }

  var reportHasFailure: Bool { dailyReportRunFailed || relevantFailedReportRun != nil }

  var reportAttentionMessage: String {
    if reportIsRunning {
      return dailyReportRunMessage
        ?? reportHistory.runs.first(where: { $0.phase == .running })?.message
        ?? "Checking enabled platforms…"
    }
    return relevantFailedReportRun?.message ?? dailyReportLoadError ?? reportHistoryError
      ?? (reportAttentionDocument.map { "\($0.summary) Open to read report and logs." })
      ?? "Open report, run details, and logs"
  }

  var reportAttentionTitle: String {
    if reportIsRunning { return "Daily report is running" }
    if reportHasFailure, let latest = relevantFailedReportRun {
      return "Daily report \(latest.phase.rawValue)"
    }
    if dailyReportRunFailed { return "Daily report needs attention" }
    if dailyReportLoadError != nil || reportHistoryError != nil { return "Report could not be loaded" }
    if let dailyReport = reportAttentionDocument, reportHistory.isUnread(dailyReport) {
      return dailyReport.status == .success ? "Your daily report is ready" : "Daily report has incomplete coverage"
    }
    return "Daily report has not run today"
  }

  func reloadReportHistory() async {
    do {
      let updatedHistory = try await reportHistoryRepository.load()
      if reportHistory != updatedHistory { reportHistory = updatedHistory }
      if reportHistoryError != nil { reportHistoryError = nil }
      for report in updatedHistory.reports where lastDurableReports[report.runID] != report {
        let scope = "report-\(report.runID)"
        guard durableRetryAfter[scope].map({ $0 <= Date() }) ?? true else { continue }
        do {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.sortedKeys]
          try await durableLibrary.captureReport(data: encoder.encode(report), runID: report.runID)
          lastDurableReports[report.runID] = report
          recordDurableError(nil, scope: scope)
        } catch { recordDurableError(error, scope: scope) }
      }
    } catch {
      let message = "Could not load report history: \(error.localizedDescription)"
      if reportHistoryError != message { reportHistoryError = message }
    }
  }

  func selectHistoricalReport(_ report: DailyReportDocument) {
    dailyReport = report
    setDailyReportPresented(true)
  }

  func showLatestDailyReport() {
    if let report = reportAttentionDocument { dailyReport = report }
    setDailyReportPresented(true)
  }

  private static func reportDate(_ value: String) -> Date {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = parser.date(from: value) { return date }
    parser.formatOptions = [.withInternetDateTime]
    return parser.date(from: value) ?? .distantPast
  }

  private func markReportViewed() {
    guard let report = dailyReport, !reportHistory.viewedReportIDs.contains(report.runID) else { return }
    reportHistory.viewedReportIDs.insert(report.runID)
    Task {
      do {
        try await reportHistoryRepository.markViewed(runID: report.runID)
        await reloadReportHistory()
      } catch { reportHistoryError = error.localizedDescription }
    }
  }

  func documentConversation(for url: URL, ticketID: String) -> DocumentConversation? {
    guard let document = DocumentPaneLocation.normalized(url), let context = taskContexts[ticketID] else { return nil }
    let key = DocumentConversation.key(document: document, taskID: ticketID)
    if let existing = documentConversations[key] { return existing }
    let conversation = DocumentConversation(document: document, context: context, support: paths.supportDirectory,
      agent: queueAgent, configuration: config.verifier, dashboardPath: config.dashboardPath, workspace: config.workspacePath)
    documentConversations[key] = conversation
    return conversation
  }

  func chatMessages(ticketID: String?) -> [QueueChatMessage] {
    guard let ticketID else { return queueChatMessages }
    return taskChatMessages[ticketID] ?? []
  }

  private func appendChat(_ message: QueueChatMessage, ticketID: String?) {
    if let ticketID { taskChatMessages[ticketID, default: []].append(message) }
    else { queueChatMessages.append(message) }
    let snapshot = chatMessages(ticketID: ticketID)
    Task {
      do {
        try await conversationStore.save(snapshot, ticketID: ticketID)
        recordDurableError(nil, scope: "conversation-\(ticketID ?? "queue")")
      } catch let error as ConversationArchiveError {
        recordDurableError(error, scope: "conversation-\(ticketID ?? "queue")")
      } catch { loadError = "Could not save conversation: \(error.localizedDescription)" }
    }
  }

  private func refreshTaskContexts() async {
    guard lastContextRefresh == nil || Date().timeIntervalSince(lastContextRefresh!) >= 2 else { return }
    lastContextRefresh = Date()
    let tickets = dashboard.tickets
    let baseline = taskContexts
    let snapshot = await taskContextStore.refreshContexts(
      tickets: tickets, projects: selectedProject.map { [$0] } ?? [])
    var merged = taskContexts
    for (ticketID, context) in snapshot.contexts where merged[ticketID] == baseline[ticketID] {
      merged[ticketID] = context
    }
    // Foreground actions can change a context while the actor is polling. Keep
    // those newer values, and publish the remaining batch in one observation.
    if taskContexts != merged { taskContexts = merged }
    for (ticketID, error) in snapshot.errors {
      let message = "Task context: \(error)"
      if actionMessages[ticketID] != message { actionMessages[ticketID] = message }
    }
    for ticketID in snapshot.contexts.keys where actionMessages[ticketID]?.hasPrefix("Task context:") == true {
      actionMessages[ticketID] = nil
    }
    if lastManagedPresentationRefresh == nil
      || Date().timeIntervalSince(lastManagedPresentationRefresh!) >= 60 {
      lastManagedPresentationRefresh = Date()
      var presentationContexts = Dictionary(uniqueKeysWithValues:
        ((try? await taskContextStore.loadAvailableForDiscovery()) ?? []).map { ($0.ticketID, $0) })
      for context in taskContexts.values { presentationContexts[context.ticketID] = context }
      for context in presentationContexts.values where context.subtasks.contains(where: { $0.tmux != nil }) {
        try? await taskAgentLauncher.configureManagedPresentation(
          context: context, supportDirectory: paths.supportDirectory,
          usageBarEnabled: config.agentUsageBarEnabled)
      }
    }
    for ticket in tickets {
      guard snapshot.errors[ticket.id] == nil, let context = taskContexts[ticket.id] else { continue }
      if ticket.isCompleted, cleanupSignatures[ticket.id] != context.updatedAt {
        cleanupSignatures[ticket.id] = context.updatedAt
        await finalizeCompletedTask(ticket)
      } else if config.completionReviewEnabled, ticket.isOpen,
                ticket.queueTaskKind != .customerConcern,
                !context.focusSubtasks.filter(\.tracksCompletion).isEmpty, context.focusSubtasks.filter(\.tracksCompletion).allSatisfy({ $0.status == .completed }),
                !context.subtasks.contains(where: { $0.completionOverrideAt != nil }),
                !localState.completionRequests.contains(where: {
                  $0.ticketID == ticket.id && [.pending, .running].contains($0.status)
                }) {
        let trackedIDs = Set(context.focusSubtasks.filter(\.tracksCompletion).map(\.id))
        // Only progress on completed, tracked work can justify another review.
        // Blank agents and general context edits otherwise replay the same refusal.
        let lastCompletion = context.subtasks.filter {
          $0.status == .completed && !context.assignmentIDs(for: $0).isDisjoint(with: trackedIDs)
        }.compactMap(\.lastHeartbeatAt).max() ?? .distantPast
        if latestReview(for: ticket.id).map({ $0.requestedAt < lastCompletion }) ?? true {
          requestCompletion(for: ticket)
        }
      }
    }
    for ticket in tickets {
      for subtask in subtasks(for: ticket.id) where taskContexts[ticket.id]?.canAutomaticallyRetire(subtask) == true {
        await retireAgent(subtask, for: ticket, automatically: true)
      }
    }
    if panelVisible, lastIdentityRefresh == nil || Date().timeIntervalSince(lastIdentityRefresh!) >= 15 {
      lastIdentityRefresh = Date()
      let observed = tickets.flatMap { ticket in
        visibleAgents(for: ticket.id).map { (ticketID: ticket.id, subtask: $0) }
      }
      for entry in observed {
        if let events = try? await agentActivityObserver.events(for: entry.subtask) {
          for event in events {
            do {
              taskContexts[entry.ticketID] = try await taskContextStore.observeActivity(
                ticketID: entry.ticketID, subtaskID: entry.subtask.id, event: event)
              if case .attention(.quotaExhausted) = event.kind,
                 let ticket = tickets.first(where: { $0.id == entry.ticketID }) {
                await applyQuotaFallback(ticket: ticket, subtaskID: entry.subtask.id)
              }
            } catch { actionMessages[entry.ticketID] = error.localizedDescription }
          }
        }
      }
      let terminalSnapshot = await taskAgentLauncher.runtimeSnapshot(
        subtasks: observed.map(\.subtask), configuration: config.wezTerm)
      let attentions = await taskAgentLauncher.runtimeAttention(
        subtasks: observed.map(\.subtask), configuration: config.wezTerm, snapshot: terminalSnapshot)
      for entry in observed {
        guard let attention = attentions[entry.subtask.id],
             let latest = subtasks(for: entry.ticketID).first(where: { $0.id == entry.subtask.id }),
             latest.attention != attention else { continue }
        do {
          taskContexts[entry.ticketID] = try await taskContextStore.reportAttention(ticketID: entry.ticketID,
            subtaskID: entry.subtask.id, attention: attention,
            summary: attention == .approval ? "The agent is waiting for approval in its terminal." : "The terminal session ended before this subtask was completed. Click to resume.",
            expectedHeartbeat: entry.subtask.lastHeartbeatAt)
        } catch { actionMessages[entry.ticketID] = error.localizedDescription }
      }
      let unidentified = observed.filter { $0.subtask.sessionID == nil }
      if !unidentified.isEmpty {
        let identities = await taskAgentLauncher.identify(
          subtasks: unidentified.map(\.subtask), configuration: config.wezTerm, snapshot: terminalSnapshot)
        for entry in unidentified {
          guard let identity = identities[entry.subtask.id],
                subtasks(for: entry.ticketID).first(where: { $0.id == entry.subtask.id })?.isAgentVisible == true
          else { continue }
          do {
            taskContexts[entry.ticketID] = try await taskContextStore.recordAgentIdentity(ticketID: entry.ticketID,
              subtaskID: entry.subtask.id, sessionID: identity)
          } catch { actionMessages[entry.ticketID] = error.localizedDescription }
        }
      }
    }
    for session in localState.agentSessions { await bindSubtask(to: session) }
    let now = Date()
    if taskContexts.values.contains(where: { context in
      context.subtasks.contains { $0.effectiveStatus(now: lastActivityCheck) != $0.effectiveStatus(now: now) }
    }) { subtaskActivityRevision &+= 1 }
    lastActivityCheck = now
    await reloadPresentedPlan()
    let nowForDurability = Date()
    if taskContexts != baseline || lastDurableContextScan.map({ nowForDurability.timeIntervalSince($0) >= 30 }) ?? true {
      lastDurableContextScan = nowForDurability
      await captureDurableContexts(Array(taskContexts.values))
    }
    await captureDurableState(localState)
  }

  func openPlan(for ticket: DashboardTicket, sourceURL: URL? = nil) {
    revealProject(for: ticket.id)
    isQueueChatInspectorPresented = false
    presentedAgentUpdate = nil
    isDailyReportPresented = false
    presentedPlanTicketID = ticket.id
    presentedPlanURL = sourceURL
    presentedPlanMarkdown = ""
    isPlanLoading = true
    planError = nil
    let presentationID = UUID()
    planPresentationID = presentationID
    reportVisibilityHandler?(true)
    Task {
      do {
        taskContexts[ticket.id] = try await taskContextStore.ensureContext(ticket: ticket, project: project(for: ticket))
        guard planPresentationID == presentationID, presentedPlanTicketID == ticket.id else { return }
        await reloadPresentedPlan()
      } catch {
        guard planPresentationID == presentationID, presentedPlanTicketID == ticket.id else { return }
        isPlanLoading = false
        planError = error.localizedDescription
        return
      }
      // The document stays usable even when an auxiliary chat or draft file is damaged.
      do {
        if taskChatMessages[ticket.id] == nil {
          let saved = try await conversationStore.load(ticketID: ticket.id) ?? []
          if taskChatMessages[ticket.id] == nil { taskChatMessages[ticket.id] = saved }
        }
      } catch { actionMessages[ticket.id] = "Could not load task chat: \(error.localizedDescription)" }
      do {
        if planEditDrafts[ticket.id] == nil {
          let saved = try await conversationStore.loadPlanDraft(ticketID: ticket.id)
          if planEditDrafts[ticket.id] == nil { planEditDrafts[ticket.id] = saved }
        }
      } catch { actionMessages[ticket.id] = "Could not load your saved draft: \(error.localizedDescription)" }
    }
  }

  var agentUpdates: [QueueAgentUpdate] {
    var updates: [QueueAgentUpdate] = []
    for ticket in projectTickets {
      if let message = closureMessages[ticket.id] {
        updates.append(QueueAgentUpdate(id: "cleanup-\(ticket.id)", ticketID: ticket.id,
          title: "Task closure needs attention", summary: message, isCleanup: true))
      }
      let groups = Dictionary(grouping: localState.completionRequests.filter { $0.ticketID == ticket.id }) {
        $0.subtaskID.map { taskContexts[ticket.id]?.canonicalSubtaskID($0) ?? $0 } ?? ""
      }
      for reviews in groups.values {
        guard let review = reviews.max(by: { $0.requestedAt < $1.requestedAt }),
              [.failed, .needsWork].contains(review.status) else { continue }
        let subtask = completionSubtask(for: review)
        if review.subtaskID != nil, taskContexts[ticket.id] != nil {
          guard let subtask, subtask.status != .completed, subtask.agentRemovedAt == nil else { continue }
        }
        if ticket.isCompleted && review.subtaskID == nil { continue }
        updates.append(QueueAgentUpdate(id: review.id.uuidString, ticketID: ticket.id,
          title: subtask.map { "\($0.title) · Review needs attention" }
            ?? (review.status == .failed ? "Completion review failed" : "Completion needs more work"),
          summary: review.summary ?? "Completion evidence is incomplete. Review the agent output for details.",
          review: review, subtaskID: subtask?.id ?? review.subtaskID, date: review.updatedAt))
      }
      for subtask in subtasks(for: ticket.id) where subtask.completionUnread && subtask.completionOverrideAt == nil {
        updates.append(QueueAgentUpdate(id: "subtask-\(ticket.id)-\(subtask.id)", ticketID: ticket.id,
          title: "\(subtask.title) · \(subtask.status == .completed ? "Completed" : "New result")", summary: subtask.resultSummary ?? subtask.progressSummary,
          subtaskID: subtask.id, date: subtask.resultAt ?? subtask.lastHeartbeatAt ?? .distantPast, resultID: subtask.resultID))
      }
    }
    return updates
      .filter { !localState.dismissedNotificationIDs.contains($0.presentationID) }
      .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
  }

  var notificationAgentUpdates: [QueueAgentUpdate] {
    agentUpdates.filter { update in
      if update.review != nil || update.isCleanup { return true }
      guard let subtaskID = update.subtaskID else { return false }
      return taskContexts[update.ticketID]?.subtasks.first(where: { $0.id == subtaskID })?
        .attention != nil
    }
  }

  func openAgentUpdate(_ update: QueueAgentUpdate) {
    revealProject(for: update.ticketID)
    isQueueChatInspectorPresented = false
    presentedPlanTicketID = nil
    presentedPlanURL = nil
    isDailyReportPresented = false
    presentedAgentUpdate = update
    reportVisibilityHandler?(true)
    Task {
      do {
        // Only load once; a late disk read must not replace a newly arriving reply.
        if taskChatMessages[update.ticketID] == nil {
          let saved = try await conversationStore.load(ticketID: update.ticketID) ?? []
          if taskChatMessages[update.ticketID] == nil { taskChatMessages[update.ticketID] = saved }
        }
      } catch { actionMessages[update.ticketID] = error.localizedDescription }
    }
  }

  func closeAgentUpdate() {
    guard presentedAgentUpdate != nil else { return }
    presentedAgentUpdate = nil
    reportVisibilityHandler?(isInspectorPresented)
  }

  func acknowledgeAgentUpdate(_ update: QueueAgentUpdate) async {
    guard update.review == nil, let subtaskID = update.subtaskID else { return }
    do {
      taskContexts[update.ticketID] = try await taskContextStore.acknowledgeCompletion(
        ticketID: update.ticketID, subtaskID: subtaskID, expectedResultID: update.resultID,
        expectedHeartbeat: update.resultID == nil && update.date != .distantPast ? update.date : nil)
    } catch { actionMessages[update.ticketID] = error.localizedDescription }
  }

  func dismissAgentUpdate(_ update: QueueAgentUpdate) {
    localState.dismissedNotificationIDs.insert(update.presentationID)
    persistLocalState()
    if presentedAgentUpdate?.presentationID == update.presentationID { closeAgentUpdate() }
    guard update.review == nil, update.subtaskID != nil else { return }
    Task { await acknowledgeAgentUpdate(update) }
  }

  func dismissReportNotification() {
    localState.dismissedNotificationIDs.insert(reportNotificationID)
    persistLocalState()
  }

  func focusTerminalPane(_ pane: WezTermPane) async throws {
    try await terminalController.focusPane(pane, configuration: config.wezTerm)
  }

  func closePlan() {
    guard presentedPlanTicketID != nil else { return }
    presentedPlanTicketID = nil
    presentedPlanURL = nil
    isPlanLoading = false
    planPresentationID = UUID()
    reportVisibilityHandler?(isInspectorPresented)
  }

  func setQueueChatInspectorPresented(_ presented: Bool) {
    if presented {
      presentedAgentUpdate = nil
      presentedPlanTicketID = nil
      presentedPlanURL = nil
      isDailyReportPresented = false
    }
    isQueueChatInspectorPresented = presented
    reportVisibilityHandler?(isInspectorPresented)
  }

  func toggleQueueChatInspector() {
    setQueueChatInspectorPresented(!isQueueChatInspectorPresented)
  }

  func reloadPresentedPlan() async {
    guard let ticketID = presentedPlanTicketID else { return }
    let sourceURL = presentedPlanURL
    let presentationID = planPresentationID
    let readID = UUID()
    planReadID = readID
    do {
      let markdown: String
      if let sourceURL {
        markdown = try await Task.detached {
          try String(contentsOf: sourceURL, encoding: .utf8)
        }.value
      } else { markdown = try await taskContextStore.readPlan(ticketID: ticketID) }
      guard planPresentationID == presentationID, planReadID == readID,
        presentedPlanTicketID == ticketID, presentedPlanURL == sourceURL else { return }
      if isPlanLoading { isPlanLoading = false }
      if presentedPlanMarkdown != markdown { presentedPlanMarkdown = markdown }
      if planError != nil { planError = nil }
    } catch {
      guard planPresentationID == presentationID, planReadID == readID,
        presentedPlanTicketID == ticketID, presentedPlanURL == sourceURL else { return }
      if isPlanLoading { isPlanLoading = false }
      if planError != error.localizedDescription { planError = error.localizedDescription }
    }
  }

  func savePlan(_ markdown: String, expectedMarkdown: String, ticketID: String) async -> Bool {
    do {
      try await taskContextStore.savePlan(ticketID: ticketID, markdown: markdown, expectedMarkdown: expectedMarkdown)
      planEditDrafts[ticketID] = nil
      try await conversationStore.savePlanDraft(nil, ticketID: ticketID)
      await reloadPresentedPlan()
      if let context = taskContexts[ticketID] { await captureDurableContexts([context]) }
      return true
    } catch { planError = error.localizedDescription; return false }
  }

  func updatePlanDraft(_ markdown: String, baseline: String, ticketID: String) {
    let draft = PlanEditDraft(markdown: markdown, baseline: baseline)
    planEditDrafts[ticketID] = draft
    Task {
      do { try await conversationStore.savePlanDraft(draft, ticketID: ticketID) }
      catch { planError = "Could not save your draft: \(error.localizedDescription)" }
    }
  }

  func discardPlanDraft(ticketID: String) {
    planEditDrafts[ticketID] = nil
    Task {
      do { try await conversationStore.savePlanDraft(nil, ticketID: ticketID) }
      catch { planError = error.localizedDescription }
    }
  }

  func renameSubtask(_ subtask: TaskSubtask, for ticket: DashboardTicket, title: String) {
    Task {
      do {
        taskContexts[ticket.id] = try await taskContextStore.renameSubtask(ticketID: ticket.id, subtaskID: subtask.id, title: title)
        if let reference = subtask.tmux {
          await labelTmuxPane(reference, "\(subtask.provider.displayName): \(title)")
        }
      }
      catch { actionMessages[ticket.id] = error.localizedDescription }
    }
  }

  func updateSubtask(
    _ subtask: TaskSubtask, for ticket: DashboardTicket, title: String,
    explanation: String?
  ) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      actionMessages[ticket.id] = "Give the subtask a readable title."
      return
    }
    let trimmedExplanation = explanation?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedExplanation?.isEmpty == false else {
      actionMessages[ticket.id] = "Add a brief description of this work item."
      return
    }
    let updatedTitle = String(trimmedTitle.prefix(200))
    let updatedExplanation = String(trimmedExplanation!.prefix(2_000))
    let key = Self.subtaskKey(ticketID: ticket.id, subtaskID: subtask.id)
    let token = UUID()
    subtaskEditTokens[key] = token
    var previousFields: (title: String, explanation: String)?
    if var optimisticContext = taskContexts[ticket.id],
       let index = optimisticContext.subtasks.firstIndex(where: { $0.id == subtask.id }) {
      previousFields = (
        optimisticContext.subtasks[index].title,
        optimisticContext.subtasks[index].assignmentDescription)
      optimisticContext.subtasks[index].title = updatedTitle
      optimisticContext.subtasks[index].assignmentDescription = updatedExplanation
      optimisticContext.updatedAt = Date()
      taskContexts[ticket.id] = optimisticContext
    }
    actionMessages[ticket.id] = "Saving subtask…"
    let precedingEdit = subtaskEditTasks[key]
    subtaskEditTasks[key] = Task {
      await precedingEdit?.value
      do {
        _ = try await taskContextStore.renameSubtask(
          ticketID: ticket.id, subtaskID: subtask.id, title: updatedTitle,
          assignmentDescription: updatedExplanation)
        guard subtaskEditTokens[key] == token else { return }
        subtaskEditTokens[key] = nil
        subtaskEditTasks[key] = nil
        if let reference = subtask.tmux {
          await labelTmuxPane(reference, "\(subtask.provider.displayName): \(updatedTitle)")
        }
        actionMessages[ticket.id] = "Subtask updated."
      } catch {
        guard subtaskEditTokens[key] == token else { return }
        subtaskEditTokens[key] = nil
        subtaskEditTasks[key] = nil
        if var current = taskContexts[ticket.id],
           let index = current.subtasks.firstIndex(where: { $0.id == subtask.id }),
           current.subtasks[index].title == updatedTitle,
           current.subtasks[index].assignmentDescription == updatedExplanation,
           let previousFields {
          current.subtasks[index].title = previousFields.title
          current.subtasks[index].assignmentDescription = previousFields.explanation
          taskContexts[ticket.id] = current
        }
        actionMessages[ticket.id] = "Could not save the subtask: \(error.localizedDescription)"
      }
    }
  }

  func createSubtask(for ticket: DashboardTicket, title: String, explanation: String?) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      actionMessages[ticket.id] = "Give the subtask a readable title."
      return
    }
    let trimmedExplanation = explanation?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedExplanation?.isEmpty == false else {
      actionMessages[ticket.id] = "Add a brief description of this work item."
      return
    }
    Task {
      do {
        _ = try await taskContextStore.ensureContext(ticket: ticket, project: project(for: ticket))
        var assignment = TaskSubtask(
          title: String(trimmedTitle.prefix(200)),
          assignmentDescription: String(trimmedExplanation!.prefix(2_000)),
          status: .queued, runtimeMode: nil)
        assignment.isAssignmentOnly = false
        assignment.tracksCompletion = true
        taskContexts[ticket.id] = try await taskContextStore.upsertSubtask(
          ticketID: ticket.id, subtask: assignment)
        actionMessages[ticket.id] = "Subtask added. Add an agent when you are ready to start it."
      } catch { actionMessages[ticket.id] = error.localizedDescription }
    }
  }

  func deleteSubtask(_ subtask: TaskSubtask, from ticket: DashboardTicket) {
    let context = taskContexts[ticket.id]
    let targetID = context?.canonicalSubtaskID(subtask.id) ?? subtask.id
    let linkedAgents = context?.agents(for: targetID, includingRemoved: true) ?? []
    let exclusiveAgents = linkedAgents.filter { agent in
      guard let context else { return true }
      return context.assignmentIDs(for: agent).subtracting([targetID]).isEmpty
    }
    Task {
      for agent in exclusiveAgents {
        try? await taskAgentLauncher.closeRuntime(subtask: agent, configuration: config.wezTerm)
        localState.agentSessions.removeAll {
          $0.ticketID == ticket.id && ($0.subtaskID == agent.id
            || ($0.provider == agent.provider
              && $0.sessionID.caseInsensitiveCompare(agent.sessionID ?? "") == .orderedSame))
        }
      }
      do {
        taskContexts[ticket.id] = try await taskContextStore.removeSubtask(
          ticketID: ticket.id, subtaskID: subtask.id)
        persistLocalState()
        actionMessages[ticket.id] = "Subtask deleted."
      } catch { actionMessages[ticket.id] = error.localizedDescription }
    }
  }

  func changeTaskKind(_ kind: QueueTaskKind, for ticket: DashboardTicket) {
    guard kind != ticket.queueTaskKind else { return }
    guard !isQueueAgentResponding, !reportIsRunning else {
      actionMessages[ticket.id] = "Wait for the current agent or daily report to finish, then change the task type."
      return
    }
    openAgentUpdate(QueueAgentUpdate(id: "type-\(ticket.id)", ticketID: ticket.id,
      title: "Task type change", summary: "Requested type: \(kind.title). The agent response and resulting task type appear here."))
    let raw: String
    switch kind {
    case .task: raw = "task"
    case .longRunning: raw = "long-running"
    case .subtask: raw = "subtask"
    case .customerConcern: raw = "customer-concern"
    }
    sendQueueAgentMessage("Set the taskType field of \(ticket.id) to \(raw). Preserve its other fields.", ticketID: ticket.id)
  }

  func subtasks(for ticketID: String) -> [TaskSubtask] { taskContexts[ticketID]?.subtasks ?? [] }

  func hasLaunchDiagnostics(for subtask: TaskSubtask) -> Bool {
    FileManager.default.fileExists(
      atPath: agentLaunchLogger.url(subtaskID: subtask.id).path)
  }

  func openLaunchDiagnostics(for subtask: TaskSubtask) {
    let url = agentLaunchLogger.url(subtaskID: subtask.id)
    do {
      launchDiagnostics = LaunchDiagnosticsPresentation(
        title: subtask.title, text: try String(contentsOf: url, encoding: .utf8))
    } catch {
      launchDiagnostics = LaunchDiagnosticsPresentation(
        title: subtask.title, text: "Could not read launch diagnostics: \(error.localizedDescription)")
    }
  }

  private func recordAgentLaunch(
    _ subtask: TaskSubtask, ticketID: String, phase: String,
    outcome: String, message: String, details: [String: String] = [:]
  ) async {
    do {
      try await agentLaunchLogger.record(AgentLaunchLogEvent(
        timestamp: Date(), taskID: ticketID, subtaskID: subtask.id,
        provider: subtask.provider.rawValue,
        runtime: subtask.runtimeMode?.rawValue ?? "unknown",
        phase: phase, outcome: outcome, message: message, details: details))
    } catch {
      actionMessages[ticketID] =
        "\(actionMessages[ticketID] ?? message) Launch diagnostics could not be written: \(error.localizedDescription)"
    }
  }

  func effectiveStatus(for subtask: TaskSubtask) -> TaskSubtaskStatus {
    _ = subtaskActivityRevision
    return subtask.effectiveStatus()
  }

  func isOpening(_ subtask: TaskSubtask, ticketID: String) -> Bool {
    openingSubtaskIDs.contains(Self.subtaskKey(ticketID: ticketID, subtaskID: subtask.id))
  }

  func isOpening(_ session: TaskAgentSession) -> Bool {
    openingAgentSessionIDs.contains(Self.openingKey(for: session))
  }

  func agentSessionError(for subtask: TaskSubtask, ticketID: String) -> String? {
    agentSessionErrors[Self.subtaskKey(ticketID: ticketID, subtaskID: subtask.id)]
  }

  func agentSessionIssue(for ticketID: String) -> String? {
    visibleAgents(for: ticketID).compactMap {
      agentSessionErrors[Self.subtaskKey(ticketID: ticketID, subtaskID: $0.id)]
    }.first
  }

  func session(for subtask: TaskSubtask, ticketID: String) -> TaskAgentSession? {
    if let registered = agentSessions(for: ticketID).first(where: {
      $0.provider == subtask.provider && $0.sessionID.caseInsensitiveCompare(subtask.sessionID ?? "") == .orderedSame
    }) { return registered }
    // CLI-created subtasks can record a session before pane registration reaches the app.
    guard let sessionID = subtask.sessionID, let uuid = UUID(uuidString: sessionID),
          let context = taskContexts[ticketID],
          context.subtasks.contains(where: { $0.id == subtask.id && $0.provider == subtask.provider
            && $0.sessionID?.caseInsensitiveCompare(sessionID) == .orderedSame }) else { return nil }
    return TaskAgentSession(id: uuid, ticketID: ticketID, provider: subtask.provider,
      sessionID: sessionID, tabTitle: subtask.title,
      workingDirectory: subtask.workspace?.path ?? context.worktreePath ?? context.repositoryPath ?? context.projectRepositoryPath ?? config.workspacePath,
      subtaskID: subtask.id, tmux: subtask.tmux)
      .withContext(context, subtask: subtask, supportDirectory: paths.supportDirectory)
  }

  func proposedAgentWorktreePath(repositoryPath: String, ticketID: String, subtaskID: String) -> String {
    TaskWorktreeManager.agentDestination(repositoryPath: repositoryPath,
      ticketID: ticketID, subtaskID: subtaskID).path
  }

  func visibleAgents(for ticketID: String) -> [TaskSubtask] {
    subtasks(for: ticketID).filter { $0.hasAgent && $0.isAgentVisible }
  }

  func archivedAgents(for ticketID: String) -> [TaskSubtask] {
    subtasks(for: ticketID)
      .filter { !$0.isAssignmentOnly && $0.agentRemovedAt != nil }
      .sorted {
        ($0.agentRemovedAt ?? .distantPast) > ($1.agentRemovedAt ?? .distantPast)
      }
  }

  func focusSubtasks(for ticketID: String) -> [TaskSubtask] {
    taskContexts[ticketID]?.focusSubtasks ?? []
  }

  func taskItems(for ticketID: String) -> [TaskSubtask] {
    taskContexts[ticketID]?.taskItems ?? []
  }

  func agents(for subtask: TaskSubtask, ticketID: String) -> [TaskSubtask] {
    taskContexts[ticketID]?.agents(for: subtask.id) ?? []
  }

  private func acknowledgeViewedAgent(_ subtask: TaskSubtask, ticketID: String) async throws {
    guard subtask.completionUnread else { return }
    taskContexts[ticketID] = try await taskContextStore.acknowledgeCompletion(ticketID: ticketID,
      subtaskID: subtask.id, expectedResultID: subtask.resultID,
      expectedHeartbeat: subtask.resultID == nil ? subtask.lastHeartbeatAt : nil)
  }

  func openSubtask(_ subtask: TaskSubtask, for ticket: DashboardTicket, showResult: Bool = true) {
    guard !subtask.isAssignmentOnly else {
      actionMessages[ticket.id] = "Choose an agent below this subtask, or use New agent to start one."
      return
    }
    if showResult && subtask.status == .completed && subtask.agentRemovedAt != nil {
      openAgentUpdate(QueueAgentUpdate(id: "subtask-\(ticket.id)-\(subtask.id)", ticketID: ticket.id,
        title: "\(subtask.title) completed", summary: subtask.resultSummary ?? subtask.progressSummary,
        subtaskID: subtask.id, date: subtask.resultAt ?? subtask.lastHeartbeatAt ?? .distantPast, resultID: subtask.resultID))
      return
    }
    let key = Self.subtaskKey(ticketID: ticket.id, subtaskID: subtask.id)
    guard openingSubtaskIDs.insert(key).inserted else { return }
    agentSessionErrors[key] = nil
    let sessionKey = session(for: subtask, ticketID: ticket.id).map(Self.openingKey)
    if let sessionKey { openingAgentSessionIDs.insert(sessionKey) }
    launchingTaskIDs.insert(ticket.id)
    actionMessages[ticket.id] = "Opening \(subtask.title)…"
    Task {
      defer {
        launchingTaskIDs.remove(ticket.id)
        openingSubtaskIDs.remove(key)
        if let sessionKey { openingAgentSessionIDs.remove(sessionKey) }
      }
      do {
        if subtask.agentRemovedAt != nil {
          // Restoring the record itself is serialized by the context store.
          taskContexts[ticket.id] = try await taskContextStore.restoreAgent(ticketID: ticket.id, subtaskID: subtask.id)
        }
        let workspaceLease = try await TaskMaintenance.lease(ticketID: ticket.id, root: paths.supportDirectory)
        defer { workspaceLease.release() }
        if subtask.tmux != nil {
          do {
            let expectedIdentity = subtask.sessionID?.lowercased()
            let observedIdentity: String?
            if expectedIdentity == nil {
              observedIdentity = nil
            } else if let identifyManagedAgent {
              observedIdentity = try await identifyManagedAgent(subtask, config.wezTerm)
            } else {
              observedIdentity = try await taskAgentLauncher.identify(
                subtask: subtask, configuration: config.wezTerm)
            }
            if expectedIdentity == nil || observedIdentity?.lowercased() == expectedIdentity {
              _ = try await terminalController.openAgentRuntime(subtask, taskID: ticket.id, taskTitle: ticket.title, configuration: config.wezTerm)
              try await acknowledgeViewedAgent(subtask, ticketID: ticket.id)
              actionMessages[ticket.id] = "Opened \(subtask.title)."
              return
            }
            if subtask.tmux?.name.hasPrefix("fq-task-") == true, observedIdentity != nil {
              throw TaskContextError.commandFailed(
                "This task pane belongs to a different provider conversation. Focus Queue did not open or replace it.")
            }
            // A legacy pane can be shared by stale historical records. Never
            // attach it when its live provider UUID differs from this row.
            // Continue below and resume the clicked UUID in a new owned pane.
          } catch TmuxError.stopped { /* Resume the durable provider conversation below. */ }
        } else if subtask.terminalPaneID != nil {
          do {
            _ = try await terminalController.openAgentRuntime(subtask, taskID: ticket.id, taskTitle: ticket.title, configuration: config.wezTerm)
            try await agentTerminalFocusHandler?(config.wezTerm.applicationName, ticket.id)
            try await acknowledgeViewedAgent(subtask, ticketID: ticket.id)
            actionMessages[ticket.id] = "Opened \(subtask.title)."
            return
          } catch WezTermError.runtimeClosed { /* A confirmed closed pane can be replaced. */ }
        } else if subtask.runtimeMode == .tmux {
          if let executable = config.tmuxExecutable ?? SetupEnvironment.executable("tmux") {
            do {
              let runtime = try await TmuxController().inspectAgent(
                taskID: ticket.id, subtaskID: subtask.id, executable: executable)
              taskContexts[ticket.id] = try await taskContextStore.setManagedRuntime(
                ticketID: ticket.id, subtaskID: subtask.id, tmux: runtime)
              var recovered = subtask
              recovered.tmux = runtime
              _ = try await terminalController.openAgentRuntime(
                recovered, taskID: ticket.id, taskTitle: ticket.title,
                configuration: config.wezTerm)
              try await acknowledgeViewedAgent(subtask, ticketID: ticket.id)
              actionMessages[ticket.id] = "Opened \(subtask.title)."
              return
            } catch TmuxError.stopped { }
          }
        }
        // A missing or closed saved view does not prove the conversation stopped.
        // External terminals and IDEs may still own it. Only a complete, exact
        // provider process scan can authorize a new resume process.
        if let sessionID = subtask.sessionID,
          let running = try await locateExistingAgent(subtask.provider, sessionID) {
          throw TaskContextError.commandFailed(
            "This conversation is already running in \(running.cwd). Open its existing terminal. No second agent was started.")
        }
        guard var context = try await taskContextStore.load(ticketID: ticket.id) else {
          throw TaskContextError.missingContext(ticket.id)
        }
        var assignment = context.subtasks.first(where: { $0.id == subtask.id }) ?? subtask
        // Old records recover their original launch directory before inheriting a task default.
        if assignment.workspace == nil {
          let path = session(for: subtask, ticketID: ticket.id)?.workingDirectory
            ?? context.worktreePath ?? context.repositoryPath ?? context.projectRepositoryPath ?? config.workspacePath
          assignment.workspace = try await taskWorktreeManager.workspace(at: path)
          if let branch = context.branch, context.worktreePath == path { assignment.workspace?.branch = branch }
        }
        try await taskWorktreeManager.restoreIfNeeded(assignment.workspace!, ticketID: ticket.id,
          subtaskID: assignment.id, store: taskContextStore)
        try await taskWorktreeManager.validate(assignment.workspace!)
        assignment.agentRemovedAt = nil
        context = try await taskContextStore.upsertSubtask(ticketID: ticket.id, subtask: assignment)
        taskContexts[ticket.id] = context
        if assignment.runtimeMode == .tmux {
          guard let executable = config.tmuxExecutable ?? SetupEnvironment.executable("tmux") else {
            throw TmuxError.unavailable("Configure tmux or change the agent runtime before reopening.")
          }
          let runtime = try await taskAgentLauncher.startManagedSession(context: context, subtask: assignment,
            supportDirectory: paths.supportDirectory, tmuxExecutable: executable,
            usageBarEnabled: config.agentUsageBarEnabled)
          taskContexts[ticket.id] = try await taskContextStore.setManagedRuntime(
            ticketID: ticket.id, subtaskID: assignment.id, tmux: runtime)
          assignment.tmux = runtime
          _ = try await terminalController.openAgentRuntime(assignment, taskID: ticket.id, taskTitle: ticket.title, configuration: config.wezTerm)
        } else {
          assignment.runtimeMode = .terminal
          let receipt = try await taskAgentLauncher.launchDirect(context: context, subtask: assignment,
            configuration: config.wezTerm, supportDirectory: paths.supportDirectory)
          taskContexts[ticket.id] = try await taskContextStore.setDirectRuntime(
            ticketID: ticket.id, subtaskID: assignment.id, paneID: receipt.paneID, socketPath: receipt.socketPath)
          assignment.tmux = nil
          assignment.terminalPaneID = receipt.paneID
          assignment.terminalSocketPath = receipt.socketPath
          _ = try await terminalController.openAgentRuntime(assignment, taskID: ticket.id, taskTitle: ticket.title, configuration: config.wezTerm)
        }
        if assignment.runtimeMode == .terminal {
          try await agentTerminalFocusHandler?(config.wezTerm.applicationName, ticket.id)
        }
        try await acknowledgeViewedAgent(subtask, ticketID: ticket.id)
        actionMessages[ticket.id] = assignment.sessionID == nil ? "New agent opened in its assigned workspace." : "Resumed the saved agent conversation in its assigned workspace."
      } catch {
        agentSessionErrors[key] = error.localizedDescription
        actionMessages[ticket.id] = error.localizedDescription
      }
    }
  }

  /// A task-owned tmux session contains every live agent pane. Opening one
  /// saved pane restores or focuses that shared session without creating a
  /// separate WezTerm tab per agent.
  func openTaskAgents(for ticket: DashboardTicket) {
    let agents = visibleAgents(for: ticket.id)
    guard !agents.isEmpty else {
      actionMessages[ticket.id] = "This task has no agents to open."
      return
    }
    let managed = agents.filter { $0.tmux?.name.hasPrefix("fq-task-") == true }
    if let representative = managed.first,
       Set(managed.compactMap(\.tmux?.name)).count == 1 {
      actionMessages[ticket.id] =
        "Opening \(agents.count) agent\(agents.count == 1 ? "" : "s") in the shared tmux session…"
      openSubtask(representative, for: ticket, showResult: false)
      return
    }
    for agent in agents {
      openSubtask(agent, for: ticket, showResult: false)
    }
  }

  func routeObjective(
    _ rawObjective: String,
    completion: (@MainActor (Bool) -> Void)? = nil
  ) {
    let objective = rawObjective.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !objective.isEmpty else {
      routerStatus = "Describe the work you want routed."
      completion?(false)
      return
    }
    // Several one-shot routers can run in parallel; only the concurrency cap
    // (and an unreadable reservation store) rejects a new objective.
    let routerStore = QueueRouterRuntimeStore(root: paths.supportDirectory)
    let activeRouterCount: Int
    do {
      activeRouterCount = try routerStore.activeRouters().count
      routerRecoveryBlocked = false
    } catch {
      routerRecoveryBlocked = true
      routerRecoveryPath = routerStore.url.path
      routerStatus = "Router recovery needs attention; new routing is blocked. \(error.localizedDescription)"
      completion?(false)
      return
    }
    let reservedCount = activeRouterCount + pendingRouterSubmissions.count
      + launchingRouterSubmissionIDs.count
    guard reservedCount < QueueRouterRuntimeStore.maximumActiveRouters else {
      routerStatus = "Focus Queue already runs \(QueueRouterRuntimeStore.maximumActiveRouters) routers. Wait for one to finish before routing another objective."
      completion?(false)
      return
    }
    guard let project = selectedProject else {
      routerStatus = "Select a project before routing work."
      completion?(false)
      return
    }
    let repository = project.repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
    var isDirectory: ObjCBool = false
    guard repository.hasPrefix("/"),
          FileManager.default.fileExists(atPath: repository, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      routerStatus = "The selected project needs an available repository before routing work."
      completion?(false)
      return
    }
    guard let tmuxExecutable = config.tmuxExecutable ?? SetupEnvironment.executable("tmux"),
          FileManager.default.isExecutableFile(atPath: tmuxExecutable) else {
      routerStatus = "The router needs tmux. Configure an executable in Settings."
      completion?(false)
      return
    }
    let submissionID = UUID()
    pendingRouterSubmissions[submissionID] = PendingRouterSubmission(
      id: submissionID, draft: rawObjective, completion: completion)
    pendingRouterSubmissionOrder.append(submissionID)
    routerStatus = "Ready to route for \(project.name). Cancel within 3 seconds to undo."
    updateRouterCapacity()
    routerLaunchTasks[submissionID] = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: .seconds(self.routerUndoWindowSeconds))
      } catch {
        return
      }
      guard let pending = self.pendingRouterSubmissions.removeValue(forKey: submissionID)
      else { return }
      self.pendingRouterSubmissionOrder.removeAll { $0 == submissionID }
      self.routerLaunchTasks[submissionID] = nil
      self.launchingRouterSubmissionIDs.insert(submissionID)
      self.routerStatus = "Starting a router for \(project.name)…"
      self.updateRouterCapacity()
      await self.launchRouterObjective(
        objective, repository: repository, tmuxExecutable: tmuxExecutable,
        submissionID: submissionID, completion: pending.completion)
    }
  }

  @discardableResult
  func cancelRouterObjective() -> String? {
    guard let submissionID = pendingRouterSubmissionOrder.last,
          let pending = pendingRouterSubmissions.removeValue(forKey: submissionID)
    else { return nil }
    pendingRouterSubmissionOrder.removeLast()
    routerLaunchTasks[submissionID]?.cancel()
    routerLaunchTasks[submissionID] = nil
    routerStatus = "Routing cancelled. Your objective is ready to edit."
    updateRouterCapacity()
    pending.completion?(false)
    return pending.draft
  }

  private func launchRouterObjective(
    _ objective: String, repository: String, tmuxExecutable: String,
    submissionID: UUID, completion: (@MainActor (Bool) -> Void)?
  ) async {
    defer {
      launchingRouterSubmissionIDs.remove(submissionID)
      updateRouterCapacity()
    }
    do {
      let provider = defaultAgentProvider
      let runtime = try await objectiveRouter.launch(
        objective: objective, repositoryPath: repository,
        supportDirectory: paths.supportDirectory,
        tmuxExecutable: tmuxExecutable, shellPath: nil, provider: provider)
      trackRouterRuntime(runtime, provider: provider)
      routerStatus = "Router started. Waiting for the assigned agent…"
      let outcome = try await objectiveRouter.waitForOutcome(
        runtime, supportDirectory: paths.supportDirectory, timeoutSeconds: 120)
      let succeeded = applyRouterOutcome(outcome, for: runtime)
      if succeeded {
        completion?(true)
        await refresh(userInitiated: true)
      } else if case .waiting = outcome {
        startRouterMonitor(runtime, completion: completion)
      } else {
        completion?(false)
      }
    } catch let error as QueueRouterLaunchUnconfirmedError {
      if routerExecutableMatchesConfiguration(error.runtime) {
        trackRouterRuntime(error.runtime, provider: nil)
        routerRecoveryPath = routerRecoveryPath(for: error.runtime)
        routerStatus = error.localizedDescription
        startRouterMonitor(error.runtime, completion: completion)
      } else {
        routerRecoveryBlocked = true
        routerRecoveryPath = routerRecoveryPath(for: error.runtime)
        routerStatus = error.localizedDescription
        completion?(false)
      }
    } catch {
      routerStatus = error.localizedDescription
      completion?(false)
    }
  }

  private func routerRecoveryPath(for runtime: QueueRouterRuntime) -> String {
    let store = QueueRouterRuntimeStore(root: paths.supportDirectory)
    return (try? store.url(routerID: runtime.tmuxName).path) ?? store.url.path
  }

  private func trackRouterRuntime(_ runtime: QueueRouterRuntime, provider: AgentProvider?) {
    routerRuntimes.removeAll { $0.capability == runtime.capability }
    routerRuntimes.append(runtime)
    if let provider { routerProviders[runtime.capability] = provider }
    updateRouterCapacity()
  }

  private func untrackRouterRuntime(_ runtime: QueueRouterRuntime) {
    routerMonitorTasks[runtime.capability]?.cancel()
    routerMonitorTasks[runtime.capability] = nil
    routerRuntimes.removeAll { $0.capability == runtime.capability }
    routerProviders[runtime.capability] = nil
    if routerRuntimes.isEmpty {
      routerRecoveryBlocked = false
      routerRecoveryPath = nil
    }
    updateRouterCapacity()
  }

  private func isTrackingRouter(_ runtime: QueueRouterRuntime) -> Bool {
    routerRuntimes.contains { $0.capability == runtime.capability }
  }

  private func updateRouterCapacity() {
    let store = QueueRouterRuntimeStore(root: paths.supportDirectory)
    guard let activeCount = try? store.activeRouters().count else {
      routerCapacityRemaining = 0
      return
    }
    routerCapacityRemaining = max(
      0, QueueRouterRuntimeStore.maximumActiveRouters - activeCount
        - pendingRouterSubmissions.count - launchingRouterSubmissionIDs.count)
  }

  private func startRouterMonitor(
    _ runtime: QueueRouterRuntime,
    completion: (@MainActor (Bool) -> Void)? = nil
  ) {
    routerMonitorTasks[runtime.capability]?.cancel()
    routerMonitorTasks[runtime.capability] = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        try? await Task.sleep(for: .seconds(self.routerMonitorIntervalSeconds))
        guard !Task.isCancelled, self.isTrackingRouter(runtime) else { return }
        do {
          let outcome = try await self.objectiveRouter.waitForOutcome(
            runtime, supportDirectory: self.paths.supportDirectory,
            timeoutSeconds: 0)
          guard !Task.isCancelled, self.isTrackingRouter(runtime) else { return }
          if self.applyRouterOutcome(outcome, for: runtime) {
            completion?(true)
            await self.refresh(userInitiated: true)
            return
          }
          if case .failed = outcome {
            completion?(false)
            return
          }
        } catch {
          guard !Task.isCancelled, self.isTrackingRouter(runtime) else { return }
          self.routerStatus = "Router monitoring will retry. \(error.localizedDescription)"
        }
      }
    }
  }

  func openRouterRecovery() {
    guard let runtime = routerRuntimes.first else { return }
    guard routerExecutableMatchesConfiguration(runtime) else {
      routerRecoveryBlocked = true
      routerStatus = "Router recovery is blocked because its tmux executable no longer matches Settings."
      return
    }
    routerStatus = "Opening the existing router session…"
    Task {
      do {
        let reference = try await objectiveRouter.recoveryReference(
          runtime, supportDirectory: paths.supportDirectory)
        guard isTrackingRouter(runtime) else { return }
        let result = try await terminalController.openManagedRuntime(
          reference, taskID: "ROUTER",
          provider: routerProviders[runtime.capability] ?? defaultAgentProvider, taskTitle: "",
          configuration: config.wezTerm)
        guard isTrackingRouter(runtime) else { return }
        routerStatus = result.message
      } catch TmuxError.stopped {
        guard isTrackingRouter(runtime) else { return }
        let outcome = try? await objectiveRouter.waitForOutcome(
          runtime, supportDirectory: paths.supportDirectory, timeoutSeconds: 0)
        guard isTrackingRouter(runtime) else { return }
        if let outcome, applyRouterOutcome(outcome, for: runtime) { await refresh(userInitiated: true) }
        else if case .waiting(nil, nil) = outcome {
          untrackRouterRuntime(runtime)
          routerStatus = "The router stopped before creating a route. It is safe to submit again."
        } else {
          routerStatus = "The router terminal stopped, but its route is still unresolved. Use the recovery locator; Focus Queue will not start a duplicate."
        }
      } catch {
        guard isTrackingRouter(runtime) else { return }
        routerStatus = error.localizedDescription
      }
    }
  }

  @discardableResult
  private func applyRouterOutcome(
    _ outcome: QueueRouterOutcome, for runtime: QueueRouterRuntime
  ) -> Bool {
    switch outcome {
    case .registered(_, let taskID, _):
      untrackRouterRuntime(runtime)
      routerStatus = "Assigned to \(taskID). The agent terminal is opening."
      return true
    case .waiting(let routeID, let recoveryPath):
      if let recoveryPath { routerRecoveryPath = recoveryPath }
      let locator = routeID.map { " Route \($0)." } ?? ""
      routerStatus = "The router is still working; no duplicate was started.\(locator)"
      return false
    case .failed(let routeID, let recoveryPath, let message):
      if let recoveryPath { routerRecoveryPath = recoveryPath }
      routerStatus = "\(message) Route \(routeID)."
      return false
    }
  }

  private func routerExecutableMatchesConfiguration(_ runtime: QueueRouterRuntime) -> Bool {
    guard let configured = config.tmuxExecutable ?? SetupEnvironment.executable("tmux") else {
      return false
    }
    return URL(fileURLWithPath: configured).standardizedFileURL.path
      == URL(fileURLWithPath: runtime.tmuxExecutable).standardizedFileURL.path
  }

  func launchAgent(
    for ticket: DashboardTicket, title: String, provider: AgentProvider,
    repositoryPath: String, assignmentDescription: String = "",
    includePrompt: Bool = true, useTmux: Bool = true,
    createWorktree: Bool = true, initialPrompt: String? = nil, tracksCompletion: Bool = true,
    subtaskID: String = UUID().uuidString, allowProjectRepositoryMismatch: Bool = false,
    parentSubtaskID: String? = nil, createAssignment: Bool = false,
    modelName: String? = nil, effort: String? = nil,
    workspacePolicy: AgentWorkspacePolicy? = nil,
    completion: (@MainActor (Bool) -> Void)? = nil
  ) {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let suppliedDescription = assignmentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    let promptDescription = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let workDescription = String((suppliedDescription.isEmpty
      ? (promptDescription.isEmpty ? (includePrompt ? title : "") : promptDescription)
      : suppliedDescription).prefix(2_000))
    guard useTmux || config.wezTerm.applicationName.caseInsensitiveCompare("Terminal") != .orderedSame else {
      actionMessages[ticket.id] = "macOS Terminal requires tmux for reliable agent launch and recall. Configure tmux or select WezTerm."
      completion?(false)
      return
    }
    guard !title.isEmpty, launchingTaskIDs.insert(ticket.id).inserted else {
      completion?(false)
      return
    }
    actionMessages[ticket.id] = "Preparing task worktree and agent context…"
    Task {
      var assignment: TaskSubtask?
      var runtimeStarted = false
      var phase = "preparing the task workspace"
      defer {
        launchingTaskIDs.remove(ticket.id)
        completion?(runtimeStarted)
      }
      do {
        let context = try await taskContextStore.ensureContext(ticket: ticket, project: project(for: ticket))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repositoryPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
          throw TaskContextError.unsafeWorktree(
            "The saved workspace is missing: \(repositoryPath)")
        }
        if let project = project(for: ticket), !project.repositoryPath.isEmpty,
           !allowProjectRepositoryMismatch,
           try await !ProjectRepositoryResolver().matches(path: repositoryPath, project: project) {
          throw TaskContextError.commandFailed("This checkout could not be matched to \(project.name). Confirm the repository choice in New Agent before starting it.")
        }
        let previous = context.subtasks.first(where: { $0.id == subtaskID })
        let workspaceLease = try await TaskMaintenance.lease(ticketID: ticket.id, root: paths.supportDirectory)
        defer { workspaceLease.release() }
        guard previous?.tmux == nil, previous?.terminalPaneID == nil, previous?.sessionID == nil else {
          throw TaskContextError.commandFailed("This agent already has a saved session. Open it from the task to continue.")
        }
        var subtask = TaskSubtask(
          id: subtaskID, title: title, assignmentDescription: workDescription,
          provider: provider, includeInitializationPrompt: includePrompt,
          runtimeMode: useTmux ? .tmux : .terminal)
        subtask.initialPrompt = initialPrompt
        subtask.tracksCompletion = tracksCompletion
        let selectedModel = modelName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedEffort = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedModel?.isEmpty == false || selectedEffort?.isEmpty == false {
          subtask.launchConfiguration = AgentLaunchConfiguration(
            model: selectedModel?.isEmpty == false ? selectedModel : nil,
            effort: selectedEffort?.isEmpty == false ? selectedEffort : nil)
        }
        if let parentSubtaskID {
          guard let parent = context.subtasks.first(where: { $0.id == parentSubtaskID }), parent.status != .completed else {
            throw TaskContextError.commandFailed("This subtask is already completed or no longer exists.")
          }
          subtask.parentSubtaskID = context.canonicalSubtaskID(parentSubtaskID)
          subtask.tracksCompletion = false
        }
        subtask.workspace = try await taskWorktreeManager.provisionAgent(ticketID: ticket.id,
          subtaskID: subtask.id, path: repositoryPath,
          policy: workspacePolicy ?? (createWorktree ? .isolatedCleanCheckout : .existingCheckout),
          store: taskContextStore)
        if let previous {
          subtask.parentSubtaskID = previous.parentSubtaskID
          subtask.tracksCompletion = previous.tracksCompletion
          if subtask.launchConfiguration == nil {
            subtask.launchConfiguration = previous.launchConfiguration
          }
        }
        _ = createAssignment // Retained for source compatibility; new launches are one task item.
        assignment = subtask
        agentSessionErrors[
          Self.subtaskKey(ticketID: ticket.id, subtaskID: subtask.id)
        ] = nil
        taskContexts[ticket.id] = try await taskContextStore.upsertSubtask(ticketID: ticket.id, subtask: subtask)
        await recordAgentLaunch(
          subtask, ticketID: ticket.id, phase: "request", outcome: "accepted",
          message: "Focus Queue saved the named subtask and selected runtime mode.",
          details: ["worktree": subtask.workspace?.path ?? "", "branch": subtask.workspace?.branch ?? "detached",
                    "prompt": includePrompt ? "included" : "omitted"])
        if useTmux {
          phase = "starting the tmux process"
          guard let tmuxExecutable = config.tmuxExecutable ?? SetupEnvironment.executable("tmux") else {
            throw TmuxError.unavailable("tmux is unavailable. Uncheck Open in tmux to launch directly.")
          }
          let expectedName = try TmuxController.taskSessionName(taskID: ticket.id)
          actionMessages[ticket.id] =
            "Starting \(provider.displayName) in tmux session \(expectedName). Waiting for the final pane process before opening WezTerm…"
          await recordAgentLaunch(
            subtask, ticketID: ticket.id, phase: "tmux-create", outcome: "started",
            message: "Requested one new tmux session.",
            details: ["tmuxName": expectedName, "executable": tmuxExecutable])
          let tmux = try await taskAgentLauncher.startManagedSession(
            context: context, subtask: subtask, supportDirectory: paths.supportDirectory,
            includePrompt: includePrompt, tmuxExecutable: tmuxExecutable,
            usageBarEnabled: config.agentUsageBarEnabled)
          runtimeStarted = true
          phase = "saving the confirmed tmux process"
          taskContexts[ticket.id] = try await taskContextStore.setManagedRuntime(
            ticketID: ticket.id, subtaskID: subtask.id, tmux: tmux)
          if includePrompt {
            taskContexts[ticket.id] = try await taskContextStore.recordPrompt(ticketID: ticket.id)
          }
          subtask.tmux = tmux
          await recordAgentLaunch(
            subtask, ticketID: ticket.id, phase: "tmux-confirm", outcome: "succeeded",
            message: "tmux reported the same final pane process three times.",
            details: [
              "tmuxName": tmux.name, "serverPID": String(tmux.serverPID),
              "pane": tmux.paneID, "panePID": String(tmux.panePID), "terminal": tmux.tty,
            ])
          phase = "opening the WezTerm view"
          _ = try await terminalController.openAgentRuntime(
            subtask, taskID: ticket.id, taskTitle: ticket.title,
            configuration: config.wezTerm)
        } else {
          phase = "starting the direct WezTerm process"
          actionMessages[ticket.id] =
            "Starting \(provider.displayName) directly in a new WezTerm window…"
          let receipt = try await taskAgentLauncher.launchDirect(
            context: context, subtask: subtask, configuration: config.wezTerm,
            supportDirectory: paths.supportDirectory, includePrompt: includePrompt)
          runtimeStarted = true
          phase = "saving the direct WezTerm pane"
          taskContexts[ticket.id] = try await taskContextStore.setDirectRuntime(
            ticketID: ticket.id, subtaskID: subtask.id, paneID: receipt.paneID,
            socketPath: receipt.socketPath)
          if includePrompt {
            taskContexts[ticket.id] = try await taskContextStore.recordPrompt(ticketID: ticket.id)
          }
          await recordAgentLaunch(
            subtask, ticketID: ticket.id, phase: "direct-confirm", outcome: "succeeded",
            message: "WezTerm returned the exact pane created for the agent.",
            details: ["paneID": String(receipt.paneID), "socket": receipt.socketPath ?? "default"])
          phase = "opening the direct WezTerm view"
          _ = try await terminalController.openDirectRuntime(
            paneID: receipt.paneID, socketPath: receipt.socketPath,
            taskID: ticket.id, provider: provider, taskTitle: ticket.title,
            configuration: config.wezTerm)
        }
        await recordAgentLaunch(
          subtask, ticketID: ticket.id, phase: "ready", outcome: "succeeded",
          message: "The provider process and terminal view are ready.")
        actionMessages[ticket.id] = includePrompt
          ? "Opened \(provider.displayName) for \(title)\(useTmux ? " in tmux" : " directly"). Waiting for its first progress update."
          : "Opened \(provider.displayName) for \(title)\(useTmux ? " in tmux" : " directly") with an empty input, ready for your first prompt."
      } catch {
        if let subtask = assignment,
          case let TmuxError.startedButUnconfirmed(name, executable, attempts, lastDetail) = error
        {
          agentSessionErrors[
            Self.subtaskKey(ticketID: ticket.id, subtaskID: subtask.id)
          ] = error.localizedDescription
          runtimeStarted = true
          if let recovered = try? await taskContextStore.load(ticketID: ticket.id),
            let saved = recovered.subtasks.first(where: { $0.id == subtask.id })?.tmux
          {
            taskContexts[ticket.id] = recovered
            await recordAgentLaunch(
              subtask, ticketID: ticket.id, phase: "tmux-confirm", outcome: "recovered",
              message: "The running provider registered and saved its tmux pane while launch confirmation was waiting.",
              details: [
                "tmuxName": saved.name, "pane": saved.paneID,
                "panePID": String(saved.panePID), "terminal": saved.tty,
              ])
            do {
              let result = try await terminalController.openManagedAgentRuntime(
                saved, taskID: ticket.id, subtaskID: subtask.id,
                provider: provider, taskTitle: ticket.title,
                configuration: config.wezTerm)
              actionMessages[ticket.id] =
                "\(result.message) The provider process registered while tmux was still confirming its pane."
            } catch {
              actionMessages[ticket.id] =
                "The provider process is running and registered in tmux session \(saved.name), but WezTerm did not open its view. Click the subtask to retry. \(error.localizedDescription)"
            }
            return
          }
          let detail =
            "tmux accepted session \(name), but its pane process and terminal device were still changing after \(attempts) checks. The agent may be running. Focus Queue will not create another process. Click this subtask to retry opening the saved session."
          taskContexts[ticket.id] = try? await taskContextStore.updateProgress(
            ticketID: ticket.id, subtaskID: subtask.id, status: .working,
            summary: detail)
          actionMessages[ticket.id] =
            "Agent process requested; terminal confirmation is pending. \(detail) Open the document icon beside the subtask for the full launch log."
          await recordAgentLaunch(
            subtask, ticketID: ticket.id, phase: "tmux-confirm", outcome: "pending",
            message: detail,
            details: [
              "tmuxName": name, "executable": executable,
              "checks": String(attempts), "lastCheck": lastDetail,
            ])
          return
        }
        if let assignment {
          agentSessionErrors[
            Self.subtaskKey(ticketID: ticket.id, subtaskID: assignment.id)
          ] = error.localizedDescription
          taskContexts[ticket.id] = try? await taskContextStore.updateProgress(ticketID: ticket.id,
            subtaskID: assignment.id, status: runtimeStarted ? .working : .blocked,
            summary: !runtimeStarted
              ? "Agent did not start during \(phase): \(error.localizedDescription)"
              : "Agent is running; its terminal view did not open: \(error.localizedDescription)")
          await recordAgentLaunch(
            assignment, ticketID: ticket.id, phase: phase,
            outcome: runtimeStarted ? "view-failed" : "failed",
            message: error.localizedDescription,
            details: ["errorType": String(reflecting: type(of: error))])
        }
        actionMessages[ticket.id] = !runtimeStarted
          ? "Agent did not start. \(error.localizedDescription)\(assignment == nil ? "" : " Open the agent's launch log for details.")"
          : "The agent process started, but WezTerm did not open its view. Click the subtask to retry the exact saved process. \(error.localizedDescription) Open the document icon for the full launch log."
      }
    }
  }

  func launchDefaultAgent(
    for ticket: DashboardTicket, provider: AgentProvider? = nil,
    model: String? = nil, effort: String? = nil,
    subtaskID: String = UUID().uuidString,
    completion: (@MainActor (Bool) -> Void)? = nil
  ) {
    let provider = provider ?? defaultAgentProvider
    let existingTitles = Set(
      taskItems(for: ticket.id).map {
        $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      })
    let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
    let baseTitle = trimmedModel?.isEmpty == false
      ? "\(provider.displayName) \(trimmedModel ?? "")"
      : "\(provider.displayName) agent"
    var title = baseTitle
    var index = 2
    while existingTitles.contains(title.lowercased()) {
      title = "\(baseTitle) \(index)"
      index += 1
    }
    launchAgent(
      for: ticket, title: title, provider: provider,
      repositoryPath: defaultRepository(for: ticket), assignmentDescription: "",
      includePrompt: false, useTmux: true, initialPrompt: nil, tracksCompletion: true,
      subtaskID: subtaskID, modelName: model, effort: effort,
      workspacePolicy: .isolatedCommittedSnapshot,
      completion: completion)
  }

  var defaultAgentProvider: AgentProvider {
    config.agentProviderFallbackOrder.first ?? .codex
  }

  /// The next configured provider after the failing one whose CLI is installed.
  static func quotaFallbackProvider(
    for provider: AgentProvider,
    fallbackOrder: [AgentProvider],
    executableAvailable: (AgentProvider) -> Bool
  ) -> AgentProvider? {
    guard let index = fallbackOrder.firstIndex(of: provider) else {
      return fallbackOrder.first(where: executableAvailable)
    }
    return fallbackOrder.dropFirst(index + 1).first(where: executableAvailable)
  }

  static let quotaFallbackCooldownSeconds: TimeInterval = 300

  /// Guards quota fallback to one replacement per subtask and one per ticket
  /// inside the cooldown window, then claims both so a retry cannot loop.
  @discardableResult
  func claimQuotaFallback(
    ticketID: String, subtask: TaskSubtask, now: Date = Date(),
    executableAvailable: ((AgentProvider) -> Bool)? = nil
  ) -> AgentProvider? {
    let available = executableAvailable ?? providerExecutableAvailable
    let key = Self.subtaskKey(ticketID: ticketID, subtaskID: subtask.id)
    guard !quotaFallbackedSubtaskKeys.contains(key),
          subtask.isAgentVisible, subtask.status != .completed,
          subtask.attention == .quotaExhausted,
          now.timeIntervalSince(quotaFallbackAtByTicketID[ticketID] ?? .distantPast)
            >= Self.quotaFallbackCooldownSeconds,
          let next = Self.quotaFallbackProvider(
            for: subtask.provider, fallbackOrder: config.agentProviderFallbackOrder,
            executableAvailable: available)
    else { return nil }
    quotaFallbackedSubtaskKeys.insert(key)
    quotaFallbackAtByTicketID[ticketID] = now
    return next
  }

  /// Cross-provider resume is impossible, so the replacement is a fresh session.
  private func applyQuotaFallback(ticket: DashboardTicket, subtaskID: String) async {
    guard let context = taskContexts[ticket.id],
          let subtask = context.subtasks.first(where: { $0.id == subtaskID }),
          let next = claimQuotaFallback(ticketID: ticket.id, subtask: subtask)
    else { return }
    let note = "Quota exhausted on \(subtask.provider.displayName); falling back to \(next.displayName)."
    do {
      taskContexts[ticket.id] = try await taskContextStore.updateProgress(
        ticketID: ticket.id, subtaskID: subtask.id, status: .blocked, summary: note)
    } catch {
      actionMessages[ticket.id] = error.localizedDescription
      return
    }
    await recordAgentLaunch(
      subtask, ticketID: ticket.id, phase: "provider-fallback", outcome: "started",
      message: note,
      details: ["from": subtask.provider.rawValue, "to": next.rawValue])
    actionMessages[ticket.id] = note
    launchAgent(
      for: ticket, title: "\(subtask.title) · \(next.displayName) fallback",
      provider: next,
      repositoryPath: subtask.workspace?.repositoryPath ?? defaultRepository(for: ticket),
      assignmentDescription: subtask.assignmentDescription,
      includePrompt: true, useTmux: true,
      initialPrompt: subtask.initialPrompt, tracksCompletion: subtask.tracksCompletion)
  }

  /// The requested provider wins when its CLI is installed; otherwise the first
  /// available entry of the configured fallback order takes over.
  static func escalationProvider(
    requested: String?,
    fallbackOrder: [AgentProvider],
    executableAvailable: (AgentProvider) -> Bool
  ) -> AgentProvider? {
    if let name = requested?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
       !name.isEmpty, let provider = AgentProvider(rawValue: name),
       executableAvailable(provider) {
      return provider
    }
    return fallbackOrder.first(where: executableAvailable)
  }

  /// One auto-launch at a time; the remaining requests stay queued on disk.
  private func consumeEscalationLaunchRequests() async {
    guard config.agentEscalationAutoLaunch, !escalationAutoLaunchInFlight else { return }
    let inbox = AgentLaunchRequestInbox(directory: paths.launchRequestsDirectory)
    guard let requests = try? await inbox.pending(), !requests.isEmpty else { return }
    for request in requests {
      guard let ticket = dashboard.tickets.first(where: {
        $0.id.caseInsensitiveCompare(request.ticketId) == .orderedSame
      }) else { continue }
      let hasLiveAgent = launchingTaskIDs.contains(ticket.id)
        || visibleAgents(for: ticket.id).contains { $0.status != .completed }
      if hasLiveAgent {
        await inbox.consume(request)
        continue
      }
      guard let provider = Self.escalationProvider(
        requested: request.provider, fallbackOrder: config.agentProviderFallbackOrder,
        executableAvailable: providerExecutableAvailable)
      else { continue }
      escalationAutoLaunchInFlight = true
      await inbox.consume(request)
      let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
      launchAgent(
        for: ticket,
        title: title?.isEmpty == false ? title! : "Escalation \(ticket.id)",
        provider: provider,
        repositoryPath: defaultRepository(for: ticket),
        assignmentDescription: prompt ?? "",
        includePrompt: true, useTmux: true,
        initialPrompt: prompt?.isEmpty == false ? prompt : nil,
        modelName: request.model, effort: request.effort
      ) { [weak self] _ in
        self?.escalationAutoLaunchInFlight = false
      }
      break
    }
  }

  private func finalizeCompletedTask(_ ticket: DashboardTicket) async {
    do {
      let lease = try await TaskMaintenance.lease(ticketID: ticket.id, root: paths.supportDirectory)
      defer { lease.release() }
      let maintenance = TaskMaintenance(root: paths.supportDirectory)
      try await taskContextStore.archive(ticketID: ticket.id)
      if focusSubtasks(for: ticket.id).contains(where: { $0.tracksCompletion && $0.status != .completed }) {
        closureMessages[ticket.id] = "Completion needs review: some subtasks remain open."
        return
      }
      for subtask in subtasks(for: ticket.id) where subtask.hasManagedWorkspaces {
        guard subtask.status == .completed else {
          closureMessages[ticket.id] = "Workspace retained: an agent assignment is still open."
          return
        }
        try await maintenance.requireInactive(subtask)
        let cleanup = try await taskWorktreeManager.cleanupAgent(ticketID: ticket.id, subtask: subtask, store: taskContextStore)
        if !cleanup.removed { closureMessages[ticket.id] = cleanup.message; return }
      }
      let wasManaged = taskContexts[ticket.id]?.managedWorktree == true
      if wasManaged, let context = taskContexts[ticket.id], let path = context.worktreePath {
        var owner = TaskSubtask(id: "task-workspace", title: ticket.id)
        owner.workspace = AgentWorkspace(path: path, repositoryPath: context.repositoryPath ?? path, managed: true)
        try await maintenance.requireInactive(owner)
      }
      let result = try await taskWorktreeManager.cleanup(ticketID: ticket.id, store: taskContextStore)
      closureMessages[ticket.id] = wasManaged && !result.removed ? result.message : nil
      actionMessages[ticket.id] = result.message
      taskContexts[ticket.id] = try await taskContextStore.load(ticketID: ticket.id)
    } catch { closureMessages[ticket.id] = "Cleanup needs attention: \(error.localizedDescription)" }
  }

  func retryCleanup(for ticket: DashboardTicket) {
    Task { await finalizeCompletedTask(ticket) }
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
      .filter { $0.ticketID == ticketID && $0.subtaskID == nil }
      .max { $0.requestedAt < $1.requestedAt }
  }

  func ticketIsChecked(_ ticket: DashboardTicket) -> Bool {
    guard ticket.isOpen else { return true }
    guard let review = latestReview(for: ticket.id) else { return false }
    return [.pending, .running, .accepted].contains(review.status)
  }

  func requestCompletion(for ticket: DashboardTicket) {
    guard ticket.isOpen else { return }
    guard config.completionReviewEnabled else {
      skipReviewAndComplete(ticket)
      return
    }
    if let review = latestReview(for: ticket.id), [.pending, .running].contains(review.status) {
      actionMessages[ticket.id] = "Completion review is already \(review.status.rawValue)."
      return
    }

    let id = UUID()
    let requestURL = reviewArtifacts.requestURL(for: id)
    let request = CompletionRequest(id: id, ticketID: ticket.id, requestFilePath: requestURL.path,
      contextPath: taskContexts[ticket.id]?.contextDirectory.path,
      dashboardPath: config.dashboardPath, workspacePath: defaultRepository(for: ticket),
      taskTitle: ticket.title, doneWhen: ticket.doneWhen)
    localState.completionRequests.append(request)
    actionMessages[ticket.id] = "Completion review queued. The dashboard is unchanged."
    persistLocalState()
    scheduleReview(requestID: request.id)
  }

  func requestSubtaskCompletion(_ subtask: TaskSubtask, for ticket: DashboardTicket) {
    guard subtask.status != .completed else { return }
    guard config.completionReviewEnabled else {
      overrideCompletion(subtask, for: ticket)
      return
    }
    guard !localState.completionRequests.contains(where: {
      $0.ticketID == ticket.id && $0.subtaskID == subtask.id && [.pending, .running].contains($0.status)
    }) else { return }
    let id = UUID()
    let request = CompletionRequest(id: id, ticketID: ticket.id,
      requestFilePath: reviewArtifacts.requestURL(for: id).path, subtaskID: subtask.id,
      contextPath: taskContexts[ticket.id]?.contextDirectory.path,
      dashboardPath: config.dashboardPath,
      workspacePath: subtask.workspace?.path ?? defaultRepository(for: ticket),
      taskTitle: ticket.title, doneWhen: ticket.doneWhen)
    localState.completionRequests.append(request)
    actionMessages[ticket.id] = "Reviewing \(subtask.title) before recording completion."
    persistLocalState()
    scheduleReview(requestID: id)
  }

  func retryReview(for ticket: DashboardTicket) {
    guard config.completionReviewEnabled else {
      skipReviewAndComplete(ticket)
      return
    }
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

  func skipReviewAndComplete(_ ticket: DashboardTicket) {
    guard ticket.isOpen else { return }
    actionMessages[ticket.id] = "Marking complete by user override…"
    Task {
      do {
        try await validateCanonicalCompletion(
          ticketID: ticket.id, dashboardPath: config.dashboardPath)
        if let context = taskContexts[ticket.id] {
          let openAssignments = context.focusSubtasks.filter {
            $0.tracksCompletion && $0.status != .completed
          }
          for subtask in openAssignments {
            taskContexts[ticket.id] = try await taskContextStore.overrideCompletion(
              ticketID: ticket.id, subtaskID: subtask.id)
          }
        }
        let resolved = try await resolveCanonicalTicket(
          ticketID: ticket.id,
          dashboardPath: config.dashboardPath,
          reason: "Marked complete by explicit user override without completion review.",
          evidence: [],
          completedBy: "user-override")
        settleParentReviewsByOverride(ticketID: ticket.id)
        persistLocalState()
        if let resolved { await finalizeCompletedTask(resolved) }
        actionMessages[ticket.id] = "Task marked complete by user override."
      } catch {
        actionMessages[ticket.id] = "Could not mark complete: \(error.localizedDescription)"
      }
    }
  }

  func focusTerminal(for ticket: DashboardTicket) {
    let directory = defaultRepository(for: ticket)
    actionMessages[ticket.id] = "Finding a matching WezTerm pane…"
    Task {
      do {
        let result = try await terminalController.focusOrSpawn(
          directory: directory,
          taskID: ticket.id,
          taskTitle: ticket.title,
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

  func importAgentRegistrations() async {
    do {
      let pendingRecords = try await agentRegistrationInbox.pendingRecords()
      guard !pendingRecords.isEmpty else { return }
      await captureDurableState(localState)
      let external = try await ExternalAgentRegistry(root: paths.supportDirectory).registrations()
      var imported: [PendingAgentRegistration] = []
      for pending in pendingRecords {
        let registration = pending.session
        // CLI hooks can arrive before the app's next context poll or bootstrap.
        if let fresh = try await taskContextStore.load(ticketID: registration.ticketID),
          taskContexts[registration.ticketID] != fresh { taskContexts[registration.ticketID] = fresh }
        guard let subtaskID = registration.subtaskID,
          let subtask = taskContexts[registration.ticketID]?.subtasks.first(where: {
            $0.id == subtaskID && $0.provider == registration.provider && $0.isAgentVisible
          }),
          (external.contains(where: { $0.taskID == registration.ticketID && $0.subtaskID == subtaskID
            && $0.provider == registration.provider && $0.sessionID == registration.sessionID.lowercased()
            && subtask.sessionID?.lowercased() == $0.sessionID })
            || subtask.runtimeMode == .tmux
            && registration.tmux == subtask.tmux
            && registration.tmux.map { TmuxController.ownsSession(name: $0.name, taskID: registration.ticketID, subtaskID: subtaskID) } == true
            || subtask.runtimeMode == .terminal
            && registration.tmux == nil
            && registration.paneID == subtask.terminalPaneID)
        else { continue }
        upsertAgentSession(registration)
        await bindSubtask(to: registration)
        imported.append(pending)
        completeRouteHandoffIfObserved(
          taskID: registration.ticketID, subtaskID: subtaskID,
          sessionID: registration.sessionID)
        actionMessages[registration.ticketID] = subtask.runtimeMode == .tmux
          ? "\(registration.provider.displayName) is running and registered in tmux. Click \(subtask.title) to open its exact terminal session."
          : registration.paneID != nil
            ? "\(registration.provider.displayName) is running in its saved WezTerm pane. Click \(subtask.title) to focus it."
            : "Session tracked. Continue in its existing terminal; Focus Queue will check it before resuming."
      }
      try await stateStore.save(localState)
      await captureDurableState(localState)
      await agentRegistrationInbox.acknowledge(imported)
    } catch {
      loadError = "Could not import agent registration: \(error.localizedDescription)"
    }
  }

  /// A routed startup receipt whose successor registered through the inbox or
  /// the external registry completes its handoff here, even when the router
  /// that launched it exited before finalizing the receipt.
  private func completeRouteHandoffIfObserved(
    taskID: String, subtaskID: String?, sessionID: String?
  ) {
    guard let subtaskID, let sessionID else { return }
    try? AgentStartupReceiptStore(root: paths.supportDirectory)
      .completeObservedHandoff(taskID: taskID, subtaskID: subtaskID, sessionID: sessionID)
  }

  func importProvisionalAgentIntakes(_ receipts: [AgentIntakeReceipt]) async throws {
    for receipt in receipts {
      guard let taskID = receipt.taskID?.uppercased() else { continue }
      var context = try await taskContextStore.load(ticketID: taskID)
      if receipt.isTerminal {
        guard context != nil else { continue }
        context = try await taskContextStore.dismissTrackedLaunch(
          ticketID: taskID, launchID: receipt.launchID)
        taskContexts[taskID] = context
        continue
      }
      if context == nil {
        let ticket = dashboard.tickets.first { $0.id.caseInsensitiveCompare(taskID) == .orderedSame }
        context = try await taskContextStore.ensureTrackedLaunchContext(
          ticketID: taskID, title: ticket?.title ?? receipt.title ?? taskID,
          summary: ticket?.summary ?? "Tracked external agent launch.")
      }
      guard var context else { continue }
      guard !context.hasDismissedLaunch(receipt.launchID) else { continue }
      let effectiveSubtaskID = receipt.effectiveSubtaskID(in: context)
      if let sessionID = receipt.sessionID?.lowercased(), context.subtasks.contains(where: {
        $0.provider == .codex && $0.sessionID?.lowercased() == sessionID
          && $0.agentRemovedAt == nil && $0.id != effectiveSubtaskID
      }) { continue }
      let existing = context.subtasks.first(where: { $0.id == effectiveSubtaskID })
      let provisional = receipt.provisionalSubtask(
        subtaskID: effectiveSubtaskID, merging: existing,
        now: existing?.lastHeartbeatAt ?? Date())
      if let existing,
        existing.agentRemovedAt != nil
          || (existing.sessionID != nil
            && existing.sessionID?.caseInsensitiveCompare(receipt.sessionID ?? "") != .orderedSame)
      { continue }
      context = try await taskContextStore.upsertSubtask(ticketID: taskID, subtask: provisional)
      taskContexts[taskID] = context
      if let referenceKey = receipt.discoveryKey,
        labeledIntakeReferenceKeys.insert(referenceKey).inserted,
        let sessionID = provisional.sessionID
          ?? UUID(uuidString: effectiveSubtaskID)?.uuidString {
        let session = TaskAgentSession(ticketID: taskID, provider: .codex,
          sessionID: sessionID, tabTitle: provisional.title, taskTitle: context.title,
          workingDirectory: receipt.cwd, subtaskID: provisional.id,
          tmux: receipt.reference)
        if let reference = receipt.reference {
          await labelTmuxPane(reference, "Codex: \(provisional.title)")
        }
        try? await terminalController.labelTmuxClients(session: session,
          configuration: config.wezTerm)
      }
    }
  }

  func refreshExternalAgentRegistrations(force: Bool = false) async {
    let now = Date()
    guard force || lastExternalRegistrationRefresh.map({ now.timeIntervalSince($0) >= 10 }) ?? true else { return }
    lastExternalRegistrationRefresh = now
    let registry = ExternalAgentRegistry(root: paths.supportDirectory)
    do {
      let receipts = AgentIntakeStore.unresolved(root: paths.supportDirectory)
      try await importProvisionalAgentIntakes(receipts)
      let discoverableReceipts = receipts.filter(\.isReadyForDiscovery)
      let currentReferenceKeys = Set(discoverableReceipts.compactMap(\.discoveryKey))
      forcedIntakeReferenceKeys.formIntersection(currentReferenceKeys)
      labeledIntakeReferenceKeys.formIntersection(currentReferenceKeys)
      let unseenReferenceKeys = currentReferenceKeys.subtracting(forcedIntakeReferenceKeys)
      let shouldForceReferenceDiscovery = force && !unseenReferenceKeys.isEmpty
      if shouldForceReferenceDiscovery { forcedIntakeReferenceKeys.formUnion(unseenReferenceKeys) }
      let hasActiveVisibleAgents = dashboard.tickets.contains { ticket in
        visibleAgents(for: ticket.id).contains { $0.effectiveStatus() == .working }
      }
      // Idle polls recover half as often; active agents keep the fast cadence.
      let recoveryDue = lastExternalAgentDiscovery == nil
        || Date().timeIntervalSince(lastExternalAgentDiscovery!) >= (hasActiveVisibleAgents ? 15 : 30)
      if shouldForceReferenceDiscovery || recoveryDue {
        // A reference gets one immediate attempt. If it is too early to find
        // the provider UUID, the normal bounded recovery interval takes over.
        forcedIntakeReferenceKeys.formUnion(currentReferenceKeys)
        lastExternalAgentDiscovery = Date()
        let discovered = try await discoverExternalAgents()
        let sessionsByProcess = Dictionary(grouping: discovered, by: \.processID)
          .mapValues { Set($0.map { $0.sessionID.lowercased() }) }
        let tmuxPanes: [TmuxPaneSnapshot]
        if !discovered.isEmpty, let executable = config.tmuxExecutable ?? SetupEnvironment.executable("tmux") {
          tmuxPanes = (try? await TmuxController().panes(executable: executable)) ?? []
        } else { tmuxPanes = [] }
        let terminals = discovered.isEmpty ? [] : ((try? await terminalController.listAttachablePanes(configuration: config.wezTerm)) ?? [])
        for process in discovered {
          let tmux = process.tty.flatMap { tty in tmuxPanes.first { $0.reference.tty == tty }?.reference }
          let terminal = tmux == nil ? process.tty.flatMap { tty in terminals.first { $0.ttyName == tty } } : nil
          var prompt: String?
          let intake = AgentIntakeStore.match(process, tmux: tmux,
            receipts: discoverableReceipts, parents: [:],
            candidateSessionsForProcess: sessionsByProcess[process.processID] ?? [])
          if let intake { prompt = intake.title }
          if let tmux {
            if let metadata = try? ExternalAgentLaunchMetadata.load(
              matching: tmux, supportDirectory: paths.supportDirectory)
            { prompt = metadata.initialPrompt }
          }
          if prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            prompt = process.promptHint
          }
          let environment: [String: String] = intake.map { receipt in
            receipt.discoveryEnvironment(in:
              receipt.taskID.flatMap { taskContexts[$0.uppercased()] })
          } ?? [:]
          let registration = try await registry.register(ExternalAgentEvent(sessionID: process.sessionID,
            cwd: process.cwd, hookEventName: "ProcessDiscovery", prompt: prompt,
            parentSessionID: process.parentSessionID,
            discoveredAsSubagent: process.isSubagent), provider: process.provider,
            explicitTaskID: intake?.taskID, environment: environment,
            tmux: tmux, paneID: terminal?.paneID, socketPath: terminal?.socketPath)
          if var session = registration.session {
            if session.taskTitle == nil, let taskID = registration.taskID {
              session.taskTitle = taskContexts[taskID.uppercased()]?.title
            }
            try? await terminalController.labelTmuxClients(session: session,
              configuration: config.wezTerm)
          }
          if let intake { try AgentIntakeStore.resolve(intake, sessionID: process.sessionID, root: paths.supportDirectory) }
          if let taskID = registration.taskID {
            completeRouteHandoffIfObserved(
              taskID: taskID, subtaskID: registration.subtaskID,
              sessionID: registration.sessionID)
          }
        }
      }
      let records = try await registry.registrations()
      let unassigned = records.filter { $0.taskID == nil }
        + AgentIntakeStore.pending(root: paths.supportDirectory).filter { $0.taskID == nil }
      if unassignedAgentRegistrations != unassigned { unassignedAgentRegistrations = unassigned }
      if externalAgentRegistrationError != nil { externalAgentRegistrationError = nil }
      await importAgentRegistrations()
    } catch {
      // Existing hook receipts remain useful when process inspection is unavailable.
      if let records = try? await registry.registrations() {
        let unassigned = records.filter { $0.taskID == nil }
          + AgentIntakeStore.pending(root: paths.supportDirectory).filter { $0.taskID == nil }
        if unassignedAgentRegistrations != unassigned { unassignedAgentRegistrations = unassigned }
      }
      if externalAgentRegistrationError != error.localizedDescription {
        externalAgentRegistrationError = error.localizedDescription
      }
    }
  }

  func assignExternalAgent(_ registration: ExternalAgentRegistration, to ticket: DashboardTicket) {
    guard let sessionID = registration.sessionID else {
      actionMessages[ticket.id] = "This child has no resumable provider session ID yet."
      return
    }
    Task {
      do {
        _ = try await taskContextStore.ensureContext(ticket: ticket, project: project(for: ticket))
        _ = try await ExternalAgentRegistry(root: paths.supportDirectory).register(
          ExternalAgentEvent(sessionID: sessionID, cwd: registration.cwd, hookEventName: "ExplicitAttach", prompt: registration.title),
          provider: registration.provider, explicitTaskID: ticket.id, tmux: registration.tmux,
          paneID: registration.paneID, socketPath: registration.socketPath)
        await refreshExternalAgentRegistrations()
        actionMessages[ticket.id] = "Agent attached to this task."
      } catch { actionMessages[ticket.id] = error.localizedDescription }
    }
  }

  func viewAgent(_ session: TaskAgentSession, for ticket: DashboardTicket) {
    if let subtask = subtasks(for: ticket.id).first(where: {
      $0.id == session.subtaskID || ($0.provider == session.provider && $0.sessionID?.caseInsensitiveCompare(session.sessionID) == .orderedSame)
    }) { openSubtask(subtask, for: ticket, showResult: false); return }
    if session.tmux == nil {
      Task {
        do {
          _ = try await taskContextStore.ensureContext(ticket: ticket, project: project(for: ticket))
          var agent = TaskSubtask(id: session.subtaskID ?? session.id.uuidString, title: session.tabTitle,
            provider: session.provider, sessionID: session.sessionID, includeInitializationPrompt: false,
            runtimeMode: .terminal, terminalPaneID: session.paneID)
          agent.tracksCompletion = false
          agent.workspace = try await taskWorktreeManager.workspace(at: session.workingDirectory)
          taskContexts[ticket.id] = try await taskContextStore.upsertSubtask(ticketID: ticket.id, subtask: agent)
          openSubtask(agent, for: ticket)
        } catch { actionMessages[ticket.id] = error.localizedDescription }
      }
      return
    }
    let context = taskContexts[ticket.id]
    let subtask = subtasks(for: ticket.id).first { $0.id == session.subtaskID }
      ?? subtasks(for: ticket.id).first {
        $0.provider == session.provider
          && $0.sessionID?.lowercased() == session.sessionID.lowercased()
      }
    var session = context.map { session.withContext($0, subtask: subtask, supportDirectory: paths.supportDirectory) } ?? session
    if session.tmux == nil { session.tmux = subtask?.tmux }
    let openingKey = Self.openingKey(for: session)
    guard openingAgentSessionIDs.insert(openingKey).inserted else { return }
    if let subtask {
      let subtaskKey = Self.subtaskKey(ticketID: ticket.id, subtaskID: subtask.id)
      openingSubtaskIDs.insert(subtaskKey)
      agentSessionErrors[subtaskKey] = nil
    }
    let wasRegistered = agentSessions(for: ticket.id).contains {
      $0.provider == session.provider && $0.sessionID.caseInsensitiveCompare(session.sessionID) == .orderedSame
    }
    actionMessages[ticket.id] = "Opening \(subtask?.title ?? session.provider.displayName)…"
    Task {
      defer {
        openingAgentSessionIDs.remove(openingKey)
        if let subtask {
          openingSubtaskIDs.remove(
            Self.subtaskKey(ticketID: ticket.id, subtaskID: subtask.id))
        }
      }
      do {
        let result: TerminalActionResult
        if subtask?.runtimeMode == .terminal, let paneID = subtask?.terminalPaneID {
          result = try await terminalController.openDirectRuntime(
            paneID: paneID, socketPath: subtask?.terminalSocketPath,
            taskID: ticket.id, provider: session.provider, taskTitle: ticket.title,
            configuration: config.wezTerm)
        } else {
          result = try await terminalController.focusOrResume(
            session: session, taskID: ticket.id, configuration: config.wezTerm)
        }
        if wasRegistered && !agentSessions(for: ticket.id).contains(where: {
          $0.provider == session.provider && $0.sessionID.caseInsensitiveCompare(session.sessionID) == .orderedSame
        }) { return }
        if !wasRegistered, let subtask, !subtasks(for: ticket.id).contains(where: {
          $0.id == subtask.id && $0.provider == session.provider
            && $0.sessionID?.caseInsensitiveCompare(session.sessionID) == .orderedSame
        }) { return }
        var updatedSession = session.canonicalizedForTerminal()
        updatedSession.paneID = result.paneID
        upsertAgentSession(updatedSession)
        persistLocalState()
        let runtimeLabel = subtask?.runtimeMode == .terminal ? "Direct session" : "Managed session"
        actionMessages[ticket.id] =
          "\(result.message) \(runtimeLabel): \(subtask?.title ?? session.provider.displayName)."
      } catch {
        if let subtask {
          agentSessionErrors[
            Self.subtaskKey(ticketID: ticket.id, subtaskID: subtask.id)
          ] = error.localizedDescription
        }
        actionMessages[ticket.id] = error.localizedDescription
      }
    }
  }

  func archiveAgent(_ subtask: TaskSubtask, from ticket: DashboardTicket) {
    let agents = subtask.isAssignmentOnly ? self.agents(for: subtask, ticketID: ticket.id) : [subtask]
    Task { for agent in agents { await retireAgent(agent, for: ticket) } }
  }

  func removeAgent(_ subtask: TaskSubtask, from ticket: DashboardTicket) {
    archiveAgent(subtask, from: ticket)
  }

  private func retireAgent(_ subtask: TaskSubtask, for ticket: DashboardTicket, automatically: Bool = false) async {
    if automatically && !config.autoExitCompletedAgents { return }
    do {
      let lease = try await TaskMaintenance.lease(ticketID: ticket.id, root: paths.supportDirectory)
      defer { lease.release() }
      if automatically {
        guard let context = taskContexts[ticket.id], context.canAutomaticallyRetire(subtask) else { return }
        let terminal = try await taskAgentLauncher.finishRuntime(
          context: context, subtask: subtask, taskCompleted: ticket.isCompleted,
          configuration: config.wezTerm)
        switch terminal {
        case .managed(let reference):
          taskContexts[ticket.id] = try await taskContextStore.setManagedRuntime(
            ticketID: ticket.id, subtaskID: subtask.id, tmux: reference)
        case .direct(let receipt):
          taskContexts[ticket.id] = try await taskContextStore.setDirectRuntime(
            ticketID: ticket.id, subtaskID: subtask.id, paneID: receipt.paneID, socketPath: receipt.socketPath)
        case .absent: break
        }
      }
      taskContexts[ticket.id] = try await taskContextStore.archiveAgent(ticketID: ticket.id, subtaskID: subtask.id, automatically: automatically)
      localState.agentSessions.removeAll {
        $0.ticketID == ticket.id && ($0.subtaskID == subtask.id ||
          ($0.provider == subtask.provider && $0.sessionID.caseInsensitiveCompare(subtask.sessionID ?? "") == .orderedSame))
      }
      agentSessionErrors[Self.subtaskKey(ticketID: ticket.id, subtaskID: subtask.id)] = nil
      persistLocalState()
      actionMessages[ticket.id] = "Agent archived. Its assignment, conversation, and workspace history are retained."
      if automatically {
        actionMessages[ticket.id] = "Agent exited. Its terminal and workspace remain available to continue the conversation."
        return
      }
      // List removal is independent of process cleanup and completion approval.
      do { try await taskAgentLauncher.closeRuntime(subtask: subtask, configuration: config.wezTerm) }
      catch { actionMessages[ticket.id] = "Agent archived. \(error.localizedDescription)" }
      if subtask.status == .completed {
        let removed = taskContexts[ticket.id]?.subtasks.first { $0.id == subtask.id } ?? subtask
        try await TaskMaintenance(root: paths.supportDirectory).requireInactive(removed)
        let result = try await taskWorktreeManager.cleanupAgent(ticketID: ticket.id, subtask: removed, store: taskContextStore)
        if subtask.hasManagedWorkspaces && !result.removed { closureMessages[ticket.id] = result.message }
      }
    } catch { actionMessages[ticket.id] = error.localizedDescription }
  }

  func archiveAgent(_ session: TaskAgentSession, from ticket: DashboardTicket) {
    guard session.ticketID == ticket.id else { return }
    if let subtask = subtasks(for: ticket.id).first(where: {
      $0.id == session.subtaskID || ($0.provider == session.provider && $0.sessionID?.caseInsensitiveCompare(session.sessionID) == .orderedSame)
    }) { archiveAgent(subtask, from: ticket); return }
    localState.agentSessions.removeAll { $0.id == session.id }
    persistLocalState()
  }

  /// Visible agents across open tasks that match the stale-cleanup record
  /// criteria. Live-process ownership is proven only during the actual sweep.
  func staleAgentCandidates(now: Date = Date()) -> [(ticket: DashboardTicket, agent: TaskSubtask)] {
    openTickets.flatMap { ticket in
      taskItems(for: ticket.id)
        .filter { $0.hasAgent && $0.isStaleAgentCandidate(now: now) }
        .map { (ticket: ticket, agent: $0) }
    }
  }

  /// Archives every stale agent that no live process owns. Archiving is
  /// recallable under Archived agents; nothing is deleted. Returns the count.
  @discardableResult
  func cleanupStaleAgents(now: Date = Date()) async -> Int {
    let candidates = staleAgentCandidates(now: now)
    guard !candidates.isEmpty else { return 0 }
    let maintenance = TaskMaintenance(root: paths.supportDirectory)
    var archivedPerTicket: [String: Int] = [:]
    for candidate in candidates {
      // Uncertain ownership is a retain decision, never evidence for cleanup.
      let owned = (try? await maintenance.ownsLiveProcess(candidate.agent)) ?? true
      guard !owned else { continue }
      await retireAgent(candidate.agent, for: candidate.ticket)
      let archived = subtasks(for: candidate.ticket.id).first { $0.id == candidate.agent.id }?
        .agentRemovedAt != nil
      if archived { archivedPerTicket[candidate.ticket.id, default: 0] += 1 }
    }
    let total = archivedPerTicket.values.reduce(0, +)
    for (ticketID, count) in archivedPerTicket {
      actionMessages[ticketID] =
        "Archived \(count) stale \(count == 1 ? "agent" : "agents"). They stay recallable under Archived agents."
    }
    return total
  }

  private func runStaleAgentSweepIfDue() async {
    guard config.autoArchiveStaleAgents else { return }
    let now = Date()
    if let last = localState.lastStaleAgentSweepAt,
       now.timeIntervalSince(last) < 24 * 60 * 60 { return }
    localState.lastStaleAgentSweepAt = now
    persistLocalState()
    await cleanupStaleAgents(now: now)
  }

  func removeAgent(_ session: TaskAgentSession, from ticket: DashboardTicket) {
    archiveAgent(session, from: ticket)
  }

  func overrideCompletion(_ subtask: TaskSubtask, for ticket: DashboardTicket) {
    Task {
      do {
        taskContexts[ticket.id] = try await taskContextStore.overrideCompletion(ticketID: ticket.id, subtaskID: subtask.id)
        settleOverriddenReviews(ticketID: ticket.id)
        persistLocalState()
        closureMessages[ticket.id] = nil
        let completedAgents = taskContexts[ticket.id]?.agents(for: subtask.id, includingRemoved: true) ?? []
        for completed in completedAgents where completed.status == .completed {
          await retireAgent(completed, for: ticket, automatically: true)
        }
        actionMessages[ticket.id] = "Subtask marked complete. Review history saved."
        if presentedAgentUpdate?.ticketID == ticket.id { closeAgentUpdate() }
      } catch { actionMessages[ticket.id] = error.localizedDescription }
    }
  }

  private func upsertAgentSession(_ session: TaskAgentSession) {
    localState.upsertAgentSession(session)
  }

  private func bindSubtask(to session: TaskAgentSession) async {
    guard let ticket = dashboard.tickets.first(where: { $0.id == session.ticketID }) else { return }
    if taskContexts[ticket.id]?.subtasks.contains(where: {
      $0.sessionID?.lowercased() == session.sessionID.lowercased()
    }) == true { return }
    do {
      let context = try await taskContextStore.ensureContext(ticket: ticket, project: project(for: ticket))
      if context.subtasks.contains(where: { $0.sessionID?.lowercased() == session.sessionID.lowercased() }) {
        if taskContexts[ticket.id] != context { taskContexts[ticket.id] = context }
        return
      }
      // Managed agents are created with a descriptive title before launch.
      // Registrations without that assignment stay out of the queue.
      return
    } catch { actionMessages[ticket.id] = error.localizedDescription }
  }

  func clearAgentQueue() {
    Task {
      do {
        await captureDurableState(localState)
        await captureDurableContexts(Array(taskContexts.values))
        let registrations = try await agentRegistrationInbox.pendingRecords()
        for ticket in dashboard.tickets {
          for subtask in visibleAgents(for: ticket.id) { await retireAgent(subtask, for: ticket) }
        }
        localState.agentSessions.removeAll()
        try await stateStore.save(localState)
        await agentRegistrationInbox.acknowledge(registrations)
        await captureDurableState(localState)
        await captureDurableContexts(Array(taskContexts.values))
        actionMessages.removeAll()
      } catch {
        loadError = "Could not clear the current agent queue: \(error.localizedDescription)"
      }
    }
  }

  func clearAgentQueue(for ticket: DashboardTicket) {
    Task {
      for subtask in visibleAgents(for: ticket.id) { await retireAgent(subtask, for: ticket) }
      localState.agentSessions.removeAll { $0.ticketID == ticket.id }
      persistLocalState()
    }
  }

  private static func openingKey(for session: TaskAgentSession) -> String {
    "\(session.ticketID.lowercased()):\(session.provider.rawValue):\(session.sessionID.lowercased())"
  }

  private static func subtaskKey(ticketID: String, subtaskID: String) -> String {
    "\(ticketID.lowercased()):\(subtaskID.lowercased())"
  }

  func availableTerminals() async throws -> [WezTermPane] {
    try await terminalController.listAttachablePanes(configuration: config.wezTerm)
  }

  func attachTerminal(_ pane: WezTermPane, to ticket: DashboardTicket) async -> Bool {
    actionMessages[ticket.id] = "Attaching the selected WezTerm tab…"
    do {
      var terminalConfiguration = config.wezTerm
      terminalConfiguration.socketPath = pane.socketPath ?? terminalConfiguration.socketPath
      try await terminalController.attach(
        paneID: pane.paneID,
        tabTitle: AgentTerminalLabels.tabTitle(
          ticketID: ticket.id, paneID: pane.paneID, taskTitle: ticket.title),
        windowTitle: AgentTerminalLabels.windowTitle(ticketID: ticket.id, taskTitle: ticket.title),
        configuration: terminalConfiguration
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

  func setDailyReportPresented(_ presented: Bool) {
    if presented {
      isQueueChatInspectorPresented = false
      presentedAgentUpdate = nil
      presentedPlanTicketID = nil
      presentedPlanURL = nil
    }
    isDailyReportPresented = presented
    reportVisibilityHandler?(isInspectorPresented)
    if presented { markReportViewed() }
  }

  func toggleDailyReport() {
    setDailyReportPresented(!isDailyReportPresented)
  }

  func reloadDailyReport(preservingSelection: Bool = false) async {
    do {
      let report = try await dailyReportRepository.load()
      if let report, latestDailyReport != report {
        if latestDailyReport == nil || Self.reportDate(report.finishedAt) >= Self.reportDate(latestDailyReport!.finishedAt) {
          latestDailyReport = report
        }
      }
      if (!preservingSelection || dailyReport == nil), dailyReport != report { dailyReport = report }
      if dailyReportLoadError != nil { dailyReportLoadError = nil }
      await reloadReportHistory()
      if isDailyReportPresented { markReportViewed() }
    } catch {
      let message = "Could not load daily report: \(error.localizedDescription)"
      if dailyReportLoadError != message { dailyReportLoadError = message }
    }
  }

  func displayDailyReport(_ report: DailyReportDocument) {
    dailyReport = report
    if latestDailyReport == nil || Self.reportDate(report.finishedAt) >= Self.reportDate(latestDailyReport!.finishedAt) {
      latestDailyReport = report
    }
    dailyReportLoadError = nil
    if isDailyReportPresented { markReportViewed() }
    Task { await reloadReportHistory() }
  }

  func persistDailyReportConfiguration() async -> Bool {
    guard configurationIsLoaded else {
      loadError = "Daily report cannot run until the saved configuration loads successfully."
      return false
    }
    configurationSaveTask?.cancel()
    do {
      try await configurationRepository.save(config)
      return true
    } catch {
      loadError = "Could not save settings before the report: \(error.localizedDescription)"
      return false
    }
  }

  func runComprehensiveDailyReport() {
    guard !reportIsRunning else { return }
    let request = DailyReportRunRequest(
      trigger: .manual,
      platforms: config.dailyReport.enabledPlatforms,
      comprehensive: true,
      recheck: false
    )
    configurationSaveTask?.cancel()
    Task { [weak self] in
      guard let self else { return }
      _ = await self.dispatchDailyReport(request)
    }
  }

  func cancelDailyReport() {
    guard canCancelDailyReport, !isDailyReportCancellationRequested else { return }
    isDailyReportCancellationRequested = true
    dailyReportRunMessage = "Cancelling daily report…"
    dailyReportCancelHandler?()
    Task { [weak self] in
      guard let self else { return }
      do {
        let requested = try await reportHistoryRepository.requestCancellation()
        if isRecoveredDailyReportRunning, !requested {
          isDailyReportCancellationRequested = false
          dailyReportRunMessage = "The recovered report worker could not be cancelled safely."
        }
      } catch {
        if isRecoveredDailyReportRunning {
          isDailyReportCancellationRequested = false
          dailyReportRunMessage = "Could not cancel the recovered report: \(error.localizedDescription)"
        }
      }
    }
  }

  func respondToDailyReportApproval(run: Bool) {
    Task { await dailyReportApprovalHandler?(run) }
  }

  func setDailyReportRunState(
    isRunning: Bool,
    message: String? = nil,
    isError: Bool = false,
    reportID: String? = nil,
    finalPhase: DailyReportRunPhase? = nil
  ) {
    let wasRunning = isDailyReportRunning
    isDailyReportRunning = isRunning
    if isRunning { isRecoveredDailyReportRunning = false }
    if !isRunning || !wasRunning { isDailyReportCancellationRequested = false }
    dailyReportRunMessage = message
    dailyReportRunFailed = isError
    if !isError, let message {
      programLog.record(message, category: "Daily report")
    }
    guard isRunning || wasRunning || isError else { return }
    let priorSave = reportStateSaveTask
    reportStateSaveTask = Task {
      await priorSave?.value
      do {
        try await reportHistoryRepository.recordRun(isRunning: isRunning,
          message: message ?? (isRunning ? "Daily report running" : "Daily report finished"),
          isError: isError, reportID: reportID, finalPhase: finalPhase)
        await reloadReportHistory()
      } catch { reportHistoryError = error.localizedDescription }
    }
  }

  func setPendingDailyReportApproval(_ request: DailyReportApprovalRequest?) {
    pendingDailyReportApproval = request
  }

  func revealReportTask(_ taskID: String) {
    revealProject(for: taskID)
    requestedReportTaskID = taskID
    expandedTicketIDs.insert(taskID)
    setDailyReportPresented(false)
  }

  func clearRequestedReportTask() {
    requestedReportTaskID = nil
  }

  func setDailyReportSchedule(hour: Int, minute: Int) {
    guard (0...23).contains(hour), (0...59).contains(minute) else { return }
    config.dailyReport.scheduleHour = hour
    config.dailyReport.scheduleMinute = minute
    persistConfiguration()
  }

  func setAutomaticAgentRouting(_ enabled: Bool) {
    guard config.automaticAgentRouting != enabled else { return }
    config.automaticAgentRouting = enabled
    persistConfiguration()
  }

  func setDailyReportsEnabled(_ enabled: Bool) {
    guard config.dailyReport.enabled != enabled else { return }
    config.dailyReport.enabled = enabled
    if !enabled {
      pendingDailyReportApproval = nil
      if isDailyReportPresented { setDailyReportPresented(false) }
    }
    dailyReportsEnabledHandler?(enabled)
    persistConfiguration()
  }

  func setDailyReportMaximumTokens(_ maximumTokens: Int) {
    config.dailyReport.maximumTokens = min(max(maximumTokens, 10_000), 1_000_000)
    persistConfiguration()
  }

  func setDailyReportPlatform(_ platform: DailyReportPlatform, enabled: Bool) {
    var enabledPlatforms = Set(config.dailyReport.enabledPlatforms)
    if enabled {
      enabledPlatforms.insert(platform)
    } else {
      guard enabledPlatforms.count > 1 else {
        dailyReportRunMessage = "At least one report platform must stay enabled."
        return
      }
      enabledPlatforms.remove(platform)
    }
    config.dailyReport.enabledPlatforms = DailyReportPlatform.allCases.filter(
      enabledPlatforms.contains
    )
    persistConfiguration()
  }

  func runConnectorDiagnostics() {
    guard !isDiagnosingConnectors else { return }
    Task { await diagnoseConnectors() }
  }

  func diagnoseConnectors() async {
    guard !isDiagnosingConnectors else { return }
    isDiagnosingConnectors = true
    programLog.record("Connector diagnostics started.", category: "Connectors")
    connectorDiagnosticsError = nil
    defer { isDiagnosingConnectors = false }

    let script = paths.connectorDiagnosticsScript
    guard FileManager.default.isReadableFile(atPath: script.path) else {
      connectorDiagnosticsError =
        "Connector diagnostics are unavailable. Reinstall the daily report automation to restore the diagnostic script."
      return
    }
    do {
      let result = try await connectorDiagnosticsRunner.run(ProcessSpecification(
        executable: "/usr/bin/python3",
        arguments: [script.path, "--config", paths.ingestionConfigurationFile.path],
        workingDirectory: config.workspacePath,
        timeoutSeconds: 30,
        maximumOutputBytes: 128_000
      ))
      guard result.succeeded else {
        connectorDiagnosticsError = result.timedOut
          ? "Connector diagnostics timed out."
          : "Connector diagnostics could not read the local connector configuration."
        return
      }
      let snapshot = try JSONDecoder().decode(
        ConnectorDiagnosticsSnapshot.self,
        from: Data(result.standardOutput.utf8)
      )
      connectorDiagnostics = snapshot
      connectorDiagnosticsCheckedAt = Date()
      programLog.record("Connector diagnostics completed.", category: "Connectors")
    } catch is CancellationError {
      return
    } catch {
      connectorDiagnosticsError = "Connector diagnostics failed: \(error.localizedDescription)"
    }
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

  var isProgramLogWindowVisible: Bool { localState.programLogWindowVisible }

  func setProgramLogWindowVisible(_ visible: Bool) {
    guard localState.programLogWindowVisible != visible else { return }
    localState.programLogWindowVisible = visible
    programLogVisibilityHandler?(visible)
    persistLocalState()
    programLog.record(
      visible ? "Program Log window shown." : "Program Log window hidden.",
      category: "Lifecycle"
    )
  }

  func setPanelCollapsed(_ collapsed: Bool) {
    setPanelMode(collapsed ? .collapsed : .expanded)
  }

  func showTopTaskOnly() {
    setPanelMode(.topTask)
  }

  func minimize(using preference: QueueMinimizationPreference) {
    if localState.minimizationPreference != preference {
      localState.minimizationPreference = preference
      persistLocalState()
    }
    applyMinimization(preference)
  }

  func performPreferredMinimization() {
    applyMinimization(localState.minimizationPreference)
  }

  private func applyMinimization(_ preference: QueueMinimizationPreference) {
    switch preference {
    case .dock:
      minimizeHandler?()
    case .fq:
      setPanelMode(.collapsed)
    case .topTask:
      setPanelMode(.topTask)
    }
  }

  func setPanelMode(_ mode: QueuePanelMode) {
    guard panelMode != mode else { return }
    if mode != .expanded {
      closeAgentUpdate()
      closePlan()
      setQueueChatInspectorPresented(false)
    }
    if mode != .expanded, isDailyReportPresented {
      setDailyReportPresented(false)
    }
    panelMode = mode
    panelModeHandler?(mode)
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

  /// A hidden panel ticks slowly and skips terminal scraping; revealing it
  /// refreshes immediately so the queue is current.
  func setPanelVisible(_ visible: Bool) {
    let wasHidden = !panelVisible
    panelVisible = visible
    if visible, wasHidden {
      lastDashboardRead = nil
      lastExternalRegistrationRefresh = nil
      Task { await refresh() }
    }
  }

  private func startRefreshLoop() {
    refreshTask?.cancel()
    let interval = config.refreshIntervalSeconds
    refreshTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        try? await Task.sleep(for: .seconds(self.panelVisible ? interval : 30))
        guard !Task.isCancelled else { return }
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
    let activeProgress = recurringPRProgressByTicketID.filter {
      activeIDs.contains($0.key)
    }
    if recurringPRProgressByTicketID != activeProgress { recurringPRProgressByTicketID = activeProgress }
    let activeErrors = recurringPRProgressErrors.filter { activeIDs.contains($0.key) }
    if recurringPRProgressErrors != activeErrors { recurringPRProgressErrors = activeErrors }
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
        let message = "Add a GitHub repository link to load recurring PR progress."
        if recurringPRProgressErrors[ticket.id] != message { recurringPRProgressErrors[ticket.id] = message }
        continue
      }
      do {
        let snapshot = try await pullRequestQueueLoader.load(
          repository: repository,
          closedSince: closedSince
        )
        let progress = RecurringPullRequestProgress(snapshot: snapshot)
        if recurringPRProgressByTicketID[ticket.id] != progress { recurringPRProgressByTicketID[ticket.id] = progress }
        if recurringPRProgressErrors[ticket.id] != nil { recurringPRProgressErrors[ticket.id] = nil }
      } catch {
        if recurringPRProgressErrors[ticket.id] != error.localizedDescription {
          recurringPRProgressErrors[ticket.id] = error.localizedDescription
        }
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
    for ticketID in taskContexts.keys { settleOverriddenReviews(ticketID: ticketID) }
    persistLocalState()
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
    guard var request = localState.completionRequests.first(where: { $0.id == requestID }),
      request.status == .pending else {
      return
    }
    request.status = .running
    request.updatedAt = Date()
    replaceReview(request)
    do {
      taskContexts[request.ticketID] = try await taskContextStore.reconcileSubtasks(ticketID: request.ticketID)
      if completionSubtask(for: request)?.completionOverrideAt != nil {
        settleOverriddenReviews(ticketID: request.ticketID)
        try await stateStore.save(localState)
        return
      }
      try await reviewArtifacts.writeRequest(request)
      try await stateStore.save(localState)
      var reviewConfiguration = config.verifier
      reviewConfiguration.contextDirectory = request.contextPath
      reviewConfiguration.supportDirectory = paths.supportDirectory.path
      reviewConfiguration.projectScopeID = taskContexts[request.ticketID]?.projectID
      let result = try await verifier.verify(
        ticketID: request.ticketID,
        requestFile: URL(fileURLWithPath: request.requestFilePath),
        workspace: request.workspacePath
          ?? request.subtaskID.flatMap { id in subtasks(for: request.ticketID).first(where: { $0.id == id })?.workspace?.path }
          ?? taskContexts[request.ticketID]?.worktreePath ?? taskContexts[request.ticketID]?.projectRepositoryPath ?? config.workspacePath,
        configuration: reviewConfiguration
      )
      let logURL = try await reviewArtifacts.writeLog(result.log, for: request.id)
      guard localState.completionRequests.first(where: { $0.id == request.id })?.status == .running else {
        updateReview(request.id) {
          $0.logPath = logURL.path
          $0.updatedAt = Date()
        }
        if let settled = localState.completionRequests.first(where: { $0.id == request.id }) {
          try? await reviewArtifacts.writeRequest(settled)
        }
        try? await stateStore.save(localState)
        return
      }
      var completedTicket: DashboardTicket?
      if !result.succeeded {
        request.status = .failed
      } else if result.verdict == .needsWork {
        request.status = .needsWork
      } else if result.verdict == .accepted, let subtaskID = request.subtaskID {
        taskContexts[request.ticketID] = try await taskContextStore.updateProgress(
          ticketID: request.ticketID, subtaskID: subtaskID, status: .completed,
          summary: result.summary)
        request.status = .accepted
      } else if result.verdict == .accepted {
        let context = try await taskContextStore.reconcileSubtasks(ticketID: request.ticketID)
        taskContexts[request.ticketID] = context
        let unfinished = context.focusSubtasks.filter {
          $0.tracksCompletion && $0.status != .completed
        }
        if unfinished.isEmpty {
          let evidence = [request.contextPath.map { "\($0)/plan.md" },
            request.contextPath.map { "\($0)/agent-log.md" }, logURL.path]
            .compactMap { $0 }
          completedTicket = try await resolveCanonicalTicket(
            ticketID: request.ticketID,
            dashboardPath: request.dashboardPath ?? config.dashboardPath,
            reason: result.summary,
            evidence: evidence,
            completedBy: "completion-review")
          request.status = .accepted
        } else {
          request.status = .needsWork
          request.summary = "Completion review accepted the evidence, but \(unfinished.count) completion-tracked work item\(unfinished.count == 1 ? " is" : "s are") still open."
        }
      } else {
        request.status = .failed
      }
      if request.summary == nil { request.summary = result.summary }
      request.logPath = logURL.path
      request.updatedAt = Date()
      replaceReview(request)
      try await reviewArtifacts.writeRequest(request)
      try await stateStore.save(localState)
      actionMessages[request.ticketID] =
        request.status == .accepted
        ? (completionSubtask(for: request)?.completionOverrideAt != nil
          ? "Subtask marked complete. Review history saved." : "Completion evidence accepted.")
        : "Review needs attention: \(request.summary ?? result.summary)"
      if request.status == .accepted, request.subtaskID == nil, let completedTicket {
        await finalizeCompletedTask(completedTicket)
      } else if request.status == .accepted {
        closureMessages[request.ticketID] = nil
      } else if request.status != .accepted, request.subtaskID == nil {
        closureMessages[request.ticketID] = request.summary ?? result.summary
      }
    } catch {
      guard localState.completionRequests.first(where: { $0.id == request.id })?.status == .running else {
        return
      }
      if completionSubtask(for: request)?.completionOverrideAt != nil {
        settleOverriddenReviews(ticketID: request.ticketID)
        try? await stateStore.save(localState)
        return
      }
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

  func completionSubtask(for request: CompletionRequest) -> TaskSubtask? {
    guard let subtaskID = request.subtaskID, let context = taskContexts[request.ticketID] else { return nil }
    let canonicalID = context.canonicalSubtaskID(subtaskID)
    return context.subtasks.first { $0.id == canonicalID }
  }

  private func settleOverriddenReviews(ticketID: String) {
    for index in localState.completionRequests.indices {
      let request = localState.completionRequests[index]
      guard request.ticketID == ticketID, request.status != .accepted,
        completionSubtask(for: request)?.completionOverrideAt != nil else { continue }
      localState.completionRequests[index].status = .accepted
      localState.completionRequests[index].updatedAt = Date()
    }
  }

  private func settleParentReviewsByOverride(ticketID: String) {
    for index in localState.completionRequests.indices {
      guard localState.completionRequests[index].ticketID == ticketID,
        localState.completionRequests[index].subtaskID == nil,
        localState.completionRequests[index].status != .accepted else { continue }
      reviewTasks[localState.completionRequests[index].id]?.cancel()
      localState.completionRequests[index].status = .accepted
      localState.completionRequests[index].summary =
        "Completion review skipped by explicit user override."
      localState.completionRequests[index].updatedAt = Date()
    }
  }

  @discardableResult
  private func resolveCanonicalTicket(
    ticketID: String,
    dashboardPath: String,
    reason: String,
    evidence: [String],
    completedBy: String
  ) async throws -> DashboardTicket? {
    let url = URL(fileURLWithPath: dashboardPath)
    let snapshot = try await dashboardRepository.loadSnapshot(from: url)
    guard let ticket = snapshot.document.tickets.first(where: { $0.id == ticketID }) else {
      throw DashboardMutationError.ticketNotFound(ticketID)
    }
    if ticket.isCompleted { return ticket }
    let mergedPRs = Set(ticket.prs.filter(\.isMerged).map(\.number))
    let unmerged = Set(ticket.resolutionPrs).subtracting(mergedPRs)
    guard unmerged.isEmpty else {
      throw TaskContextError.commandFailed(
        "Required resolution PRs are not merged: \(unmerged.sorted().map(String.init).joined(separator: ", ")).")
    }
    let updated = try await dashboardRepository.resolveTicket(
      id: ticketID, reason: reason, evidence: evidence, completedBy: completedBy,
      in: url, expectedRevision: snapshot.revision)
    if URL(fileURLWithPath: config.dashboardPath).standardizedFileURL == url.standardizedFileURL {
      dashboard = updated.document
      await captureDurableDashboard(updated.document)
      lastDashboardStamp = nil
      lastDashboardRead = nil
    }
    return updated.document.tickets.first(where: { $0.id == ticketID })
  }

  private func validateCanonicalCompletion(
    ticketID: String,
    dashboardPath: String
  ) async throws {
    let snapshot = try await dashboardRepository.loadSnapshot(
      from: URL(fileURLWithPath: dashboardPath))
    guard let ticket = snapshot.document.tickets.first(where: { $0.id == ticketID }) else {
      throw DashboardMutationError.ticketNotFound(ticketID)
    }
    let mergedPRs = Set(ticket.prs.filter(\.isMerged).map(\.number))
    let unmerged = Set(ticket.resolutionPrs).subtracting(mergedPRs)
    guard unmerged.isEmpty else {
      throw TaskContextError.commandFailed(
        "Required resolution PRs are not merged: \(unmerged.sorted().map(String.init).joined(separator: ", ")).")
    }
  }

  private func replaceReview(_ request: CompletionRequest) {
    guard let index = localState.completionRequests.firstIndex(where: { $0.id == request.id })
    else { return }
    localState.completionRequests[index] = request
  }

  private func persistLocalState() {
    let snapshot = localState
    let priorSave = localStateSaveTask
    localStateSaveTask = Task {
      await priorSave?.value
      do {
        try await stateStore.save(snapshot)
        await captureDurableState(snapshot)
      } catch {
        loadError = "Could not save local state: \(error.localizedDescription)"
      }
    }
  }

  func retryDurableHistory() {
    durableRetryAfter.removeAll()
    Task { await reconcileDurableLibrary() }
  }

  private func reconcileDurableLibrary() async {
    do {
      let summary = try await durableLibrary.reconcile()
      lastDurableState = nil
      lastDurableDashboard = nil
      lastDurableContexts.removeAll()
      durableErrors.removeAll()
      durableRetryAfter.removeAll()
      recordImportWarnings(summary.warnings)
      await captureDurableState(localState)
      await captureDurableContexts(Array(taskContexts.values))
      await captureDurableDashboard(dashboard)
    } catch { recordDurableError(error, scope: "migration") }
  }

  private func captureDurableDashboard(_ snapshot: DashboardDocument) async {
    guard lastDurableDashboard != snapshot,
      durableRetryAfter["dashboard"].map({ $0 <= Date() }) ?? true else { return }
    do {
      try await durableLibrary.captureDashboard(snapshot)
      lastDurableDashboard = snapshot
      recordDurableError(nil, scope: "dashboard")
    } catch { recordDurableError(error, scope: "dashboard") }
  }

  private func captureDurableState(_ snapshot: LocalState) async {
    guard lastDurableState?.agentSessions != snapshot.agentSessions
      || lastDurableState?.completionRequests != snapshot.completionRequests else { return }
    guard durableRetryAfter["state"].map({ $0 <= Date() }) ?? true else { return }
    do {
      let summary = try await durableLibrary.reconcile(state: snapshot, contexts: [])
      lastDurableState = snapshot
      recordDurableError(nil, scope: "state")
      recordImportWarnings(summary.warnings)
    } catch { recordDurableError(error, scope: "state") }
  }

  private func captureDurableContexts(_ contexts: [TaskContext]) async {
    let changed = contexts.filter { lastDurableContexts[$0.ticketID] != $0 }
    if !changed.isEmpty, durableRetryAfter["contexts"].map({ $0 <= Date() }) ?? true {
      do {
        let summary = try await durableLibrary.reconcile(contexts: changed)
        for context in changed { lastDurableContexts[context.ticketID] = context }
        recordDurableError(nil, scope: "contexts")
        recordImportWarnings(summary.warnings)
      } catch { recordDurableError(error, scope: "contexts") }
    }
    // Only stat known plans; never scan archives or provider history on a poll.
    for context in contexts {
      let expected = paths.supportDirectory.appendingPathComponent("tasks")
        .appendingPathComponent(context.ticketID.uppercased()).appendingPathComponent("plan.md")
      guard context.ticketID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
        URL(fileURLWithPath: context.planPath).standardizedFileURL == expected.standardizedFileURL else {
        recordDurableError(DurableLibraryError.unsafePath(context.planPath),
          scope: "plan-location-\(context.ticketID)")
        continue
      }
      recordDurableError(nil, scope: "plan-location-\(context.ticketID)")
      await captureDurableDocument(at: expected,
        kind: "central-plan", ticketID: context.ticketID)
    }
  }

  private func captureDurableDocument(at url: URL, kind: String, ticketID: String? = nil) async {
    let scope = "document-\(url.path)"
    guard durableRetryAfter[scope].map({ $0 <= Date() }) ?? true else { return }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let stamp = DurableDocumentStamp(
        modifiedAt: attributes[.modificationDate] as? Date,
        size: (attributes[.size] as? NSNumber)?.uint64Value,
        inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
      guard durableDocumentStamps[url.path] != stamp else { return }
      try await durableLibrary.captureDocument(at: url, kind: kind, ticketID: ticketID)
      durableDocumentStamps[url.path] = stamp
      recordDurableError(nil, scope: scope)
    } catch { recordDurableError(error, scope: scope) }
  }

  private func recordDurableError(_ error: (any Error)?, scope: String) {
    if let error {
      durableErrors[scope] = "Durable history needs attention: \(error.localizedDescription)"
      durableRetryAfter[scope] = Date().addingTimeInterval(30)
    } else {
      durableErrors.removeValue(forKey: scope)
      durableRetryAfter.removeValue(forKey: scope)
    }
    let message = durableErrors.sorted { $0.key < $1.key }.first?.value
    if durableHistoryError != message { durableHistoryError = message }
  }

  private func recordImportWarnings(_ warnings: [String]) {
    let warning = warnings.isEmpty ? nil : NSError(domain: "ECCFocusQueue.DurableImport", code: 1,
      userInfo: [NSLocalizedDescriptionKey: warnings.prefix(3).joined(separator: "\n")])
    recordDurableError(warning, scope: "import-warnings")
  }

  func setAutoExitCompletedAgents(_ enabled: Bool) {
    config.autoExitCompletedAgents = enabled
    persistConfiguration()
  }

  func setCompletionReviewEnabled(_ enabled: Bool) {
    guard config.completionReviewEnabled != enabled else { return }
    config.completionReviewEnabled = enabled
    if !enabled {
      for index in localState.completionRequests.indices
      where [.pending, .running].contains(localState.completionRequests[index].status) {
        let request = localState.completionRequests[index]
        reviewTasks[request.id]?.cancel()
        localState.completionRequests[index].status = .failed
        localState.completionRequests[index].summary =
          "Completion review was disabled before it finished. Use the completion control to mark the task complete by user override."
        localState.completionRequests[index].updatedAt = Date()
      }
      persistLocalState()
    }
    persistConfiguration()
  }

  func setAutoArchiveStaleAgents(_ enabled: Bool) {
    guard config.autoArchiveStaleAgents != enabled else { return }
    config.autoArchiveStaleAgents = enabled
    persistConfiguration()
  }

  func setAgentUsageBarEnabled(_ enabled: Bool) {
    guard config.agentUsageBarEnabled != enabled else { return }
    config.agentUsageBarEnabled = enabled
    persistConfiguration()
    let visibleContexts = Array(taskContexts.values)
    let contextStore = taskContextStore
    let support = paths.supportDirectory
    Task { [taskAgentLauncher] in
      var contexts = Dictionary(uniqueKeysWithValues:
        ((try? await contextStore.loadAvailableForDiscovery()) ?? []).map { ($0.ticketID, $0) })
      for context in visibleContexts { contexts[context.ticketID] = context }
      for context in contexts.values where context.subtasks.contains(where: { $0.tmux != nil }) {
        try? await taskAgentLauncher.configureManagedPresentation(
          context: context, supportDirectory: support, usageBarEnabled: enabled)
      }
    }
  }

  private func persistConfiguration() {
    let snapshot = config
    configurationSaveTask?.cancel()
    configurationSaveTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled, let self else { return }
      do {
        try await self.configurationRepository.save(snapshot)
        self.dailyReportRunMessage = "Daily report settings saved."
        self.dailyReportRunFailed = false
      } catch {
        self.loadError = "Could not save settings: \(error.localizedDescription)"
      }
    }
  }

  private func logChangedError(_ message: String?, previous: String?, category: String) {
    guard let message, message != previous else { return }
    programLog.record(message, level: .error, category: category)
  }

  private func logChangedMessages(
    _ messages: [String: String], previous: [String: String], categoryPrefix: String
  ) {
    for (identifier, message) in messages where previous[identifier] != message {
      programLog.record(
        message,
        level: Self.logLevel(for: message),
        category: "\(categoryPrefix) \(identifier)"
      )
    }
  }

  private static func logLevel(for message: String) -> ProgramLogLevel {
    let normalized = message.lowercased()
    return ["could not", "failed", "error", "needs attention", "unavailable"]
      .contains(where: normalized.contains) ? .error : .info
  }

  private func runDailyReportFromChat(_ request: DailyReportRunRequest) {
    let priorReportID = dailyReport?.runID
    queueChatTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.isQueueAgentResponding = false
        self.respondingTicketID = nil
        let snapshot = self.queueChatMessages
        Task {
          do { try await self.conversationStore.save(snapshot, ticketID: nil) }
          catch { self.loadError = "Could not save report conversation: \(error.localizedDescription)" }
        }
      }
      guard self.dailyReportRunHandler != nil else {
        self.queueChatMessages.append(QueueChatMessage(
          role: .agent,
          text: "Daily report automation is unavailable in this app session."
        ))
        return
      }
      guard let report = await self.dispatchDailyReport(request) else {
        self.queueChatMessages.append(QueueChatMessage(
          role: .agent,
          text: self.dailyReportRunMessage ?? "The requested daily report did not complete."
        ))
        return
      }
      let requiredPlatforms = request.comprehensive
        ? self.config.dailyReport.enabledPlatforms
        : request.platforms
      let requiredPlatformNames = Set(requiredPlatforms.map(\.rawValue))
      let actualPlatformNames = Set(report.platforms.map { $0.platform.rawValue })
      guard report.runID != priorReportID,
        report.trigger == .chat,
        report.comprehensive == request.comprehensive,
        report.mode == (request.recheck ? .recheck : .unseenOnly),
        actualPlatformNames == requiredPlatformNames
      else {
        self.queueChatMessages.append(QueueChatMessage(
          role: .agent,
          text: self.dailyReportRunMessage ?? "The requested daily report did not complete."
        ))
        return
      }
      self.queueChatMessages.append(QueueChatMessage(
        role: .agent,
        text: Self.dailyReportChatSummary(report)
      ))
      await self.refresh()
    }
  }

  private func dispatchDailyReport(
    _ request: DailyReportRunRequest
  ) async -> DailyReportDocument? {
    guard !reportIsRunning else {
      dailyReportRunMessage = "A daily report is already running."
      return nil
    }
    guard await persistDailyReportConfiguration() else { return nil }
    return await dailyReportRunHandler?(request)
  }

  private static func dailyReportChatSummary(_ report: DailyReportDocument) -> String {
    let platformSummary = report.platforms.map {
      "\($0.platform.displayName): \($0.newCount) new, \($0.checkedCount) checked"
    }.joined(separator: "; ")
    let tokenCount = report.usage?.totalTokens.formatted() ?? "unavailable"
    var response = "\(report.summary)\n\n\(platformSummary). Exact token use: \(tokenCount)."
    if !report.errors.isEmpty {
      response += " Coverage was partial: \(report.errors.joined(separator: "; "))"
    }
    response += " Open the document button in the queue header for message and task links."
    return response
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
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static var startOfCurrentWeek: Date {
    Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start
      ?? Calendar.current.startOfDay(for: Date())
  }
}

private struct DurableDocumentStamp: Equatable {
  let modifiedAt: Date?
  let size: UInt64?
  let inode: UInt64?
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
