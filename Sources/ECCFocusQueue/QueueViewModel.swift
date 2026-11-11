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

/// One open-the-task-creator intent. Identifiable so `.sheet(item:)` reopens
/// even when two requests carry the same project.
struct NewTaskRequest: Equatable, Identifiable {
  let id = UUID()
  let projectID: String?
  let autofocusPrompt: Bool
}

/// Remembers one derived value for its inputs. Unchanged collections compare
/// by storage identity, so a hit costs far less than the sort or scan it saves.
private struct ProjectionMemo<Key: Equatable, Value> {
  private var entry: (key: Key, value: Value)?

  mutating func value(for key: Key, _ make: () -> Value) -> Value {
    if let entry, entry.key == key {
      // Equal inputs in new storage compare element by element. Adopting them
      // keeps the next comparison an identity check.
      self.entry = (key, entry.value)
      return entry.value
    }
    let value = make()
    entry = (key, value)
    return value
  }
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

enum DailyReportHeaderIndicator: Equatable {
  case none
  case running
  case ready
  case needsAttention
}

@MainActor
@Observable
final class QueueViewModel {
  private(set) var config: AppConfiguration
  private(set) var dashboard = DashboardDocument(tickets: [])
  private(set) var localState = LocalState()
  private(set) var savedQueueOverride: QueueOrderDocument?
  var queueScrollSnapshot: QueueScrollSnapshot {
    let tickets = openTickets
    return QueueScrollSnapshot(
      scopeID: showsAllProjects ? ProjectCatalog.allProjectsScopeID : config.selectedProjectID,
      orderedIDs: tickets.map(\.id),
      interactions: Dictionary(uniqueKeysWithValues: tickets.compactMap { ticket in
        taskContexts[ticket.id]?.latestInteractionAt.map { (ticket.id, $0) }
      }))
  }
  var savedQueueOrder: [String]? { savedQueueOverride?.orderedIDs }
  private var queueOrderStore: QueueOrderStore {
    QueueOrderStore(
      root: paths.supportDirectory,
      projectID: showsAllProjects ? ProjectCatalog.allProjectsScopeID : config.selectedProjectID)
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
        recordProgramLogChange(dailyReportRunMessage, level: .error, category: "Daily report")
      }
    }
  }
  private(set) var pendingDailyReportApproval: DailyReportApprovalRequest?
  private(set) var requestedReportTaskID: String?
  private(set) var newTaskRequest: NewTaskRequest?
  private(set) var newTaskHotkeyEnabled =
    UserDefaults.standard.bool(forKey: "voiceTaskHotkeyEnabled")
  /// On unless turned off; the key is unset until the user changes it.
  private(set) var qchatHotkeyEnabled =
    UserDefaults.standard.object(forKey: "qchatHotkeyEnabled") as? Bool ?? true
  private(set) var toggleMinimizationHotkeyEnabled =
    UserDefaults.standard.object(forKey: "toggleMinimizationHotkeyEnabled") as? Bool ?? true
  /// A recorded combo per action; a missing entry keeps the built-in shortcut.
  private(set) var hotkeyShortcuts: [HotkeyAction: HotkeyShortcut] = HotkeyAction.allCases
    .reduce(into: [:]) { shortcuts, action in
      if let data = UserDefaults.standard.data(forKey: action.shortcutDefaultsKey),
        let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data),
        shortcut != action.defaultShortcut {
        shortcuts[action] = shortcut
      }
    }
  /// Why a recorded combo could not be registered, shown under its field.
  private(set) var hotkeyErrors: [HotkeyAction: String] = [:]
  /// While a shortcut field records, every global hotkey pauses so the press reaches the field.
  var isRecordingHotkey = false {
    didSet { if oldValue != isRecordingHotkey { hotkeyConfigurationHandler?() } }
  }
  /// Bumped per QChat hotkey press; the view opens QChat and focuses its composer.
  private(set) var queueChatFocusRequest = 0
  private(set) var panelMode: QueuePanelMode = .expanded
  /// Counts returns from minimized, FQ, top-task, or hidden states.
  private(set) var panelRestoreCount = 0
  /// The first-run walkthrough while it runs; nil otherwise.
  private(set) var walkthrough: WalkthroughProgress?
  /// The task where the walkthrough's first agent launched.
  private(set) var walkthroughTicketID: String?
  private(set) var walkthroughMessage: String?
  /// Filled by `refreshProviderAccounts`; previews and recordings may seed it.
  var providerAccounts: [AgentProvider: ProviderAccountState] = [:]
  /// Set when every check failed to run and the user chose to continue anyway.
  private(set) var providerSignInDeferred = false
  /// Sign-in windows still open, by provider. One at a time per provider.
  private(set) var signInAttempts: [AgentProvider: SignInAttempt] = [:]
  private var signInStartedAt: [AgentProvider: Date] = [:]
  /// Providers whose sign-out is still running.
  private(set) var providersSigningOut: Set<AgentProvider> = []
  /// One report per provider per launch, so a retry loop cannot flood the tracker.
  private var reportedSignInFailures: Set<AgentProvider> = []
  private(set) var canSwitchMonitor = false
  private(set) var actionMessages: [String: String] = [:] {
    didSet { logChangedMessages(actionMessages, previous: oldValue, categoryPrefix: "Task") }
  }
  private(set) var recurringPRProgressByTicketID: [String: RecurringPullRequestProgress] = [:]
  private(set) var recurringPRProgressErrors: [String: String] = [:] {
    didSet {
      for (ticketID, message) in recurringPRProgressErrors where oldValue[ticketID] != message {
        recordProgramLogChange(message, level: .error, category: "Pull request \(ticketID)")
      }
    }
  }
  static let queueChatGreeting = QueueChatMessage(
    role: .agent,
    text:
      "The Queue agent can explain your task order and help with explicitly requested task changes when configured. The app orders tasks by priority and recency, plus your local drag overrides. Optional message sources need separate account setup and verified retrieval evidence. Basic queue viewing and terminal setup work independently of this agent."
  )
  /// QChat tabs, each its own conversation and tmux session.
  private(set) var queueChatTabs: [QueueChatTab] = [.main]
  private(set) var activeQueueChatTabID = QueueChatTab.mainID
  private(set) var queueChatTabMessages: [String: [QueueChatMessage]] = [
    QueueChatTab.mainID: [QueueViewModel.queueChatGreeting]
  ]
  /// The active QChat tab's transcript.
  var queueChatMessages: [QueueChatMessage] { queueChatTabMessages[activeQueueChatTabID] ?? [] }
  /// Conversations with a turn in flight. Tabs and task chats run in parallel.
  private(set) var respondingConversations: Set<QueueChatConversation> = []
  /// True while any chat turn runs; app-wide work such as the daily report waits for it.
  var isQueueAgentResponding: Bool { !respondingConversations.isEmpty }
  private(set) var taskChatMessages: [String: [QueueChatMessage]] = [:]
  private(set) var taskContexts: [String: TaskContext] = [:]
  /// Files agents saved in each open task's context folder, newest first.
  private(set) var taskOutputs: [String: [TaskOutputFile]] = [:]
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
  /// What the installed Codex offers this account; nil until it has been read.
  var codexCatalog: CodexCatalog?
  /// Models Codex refused during this run, even though it listed them.
  var unavailableCodexModels: Set<String> = []
  @ObservationIgnored private let loadCodexCatalog: @Sendable () async -> CodexCatalog?
  @ObservationIgnored private let isWezTermInstalled: @Sendable (String) -> Bool
  @ObservationIgnored private let checkProviderAccount: @Sendable (AgentProvider) async -> ProviderAccountState
  @ObservationIgnored private let signOutProviderAccount: @Sendable (AgentProvider) async -> String?
  @ObservationIgnored private let fileSignInFailure: @Sendable (SignInFailureContext) async -> SignInFailureReporter.Delivery
  private(set) var subtaskActivityRevision = 0
  /// Agents whose tmux or WezTerm pane the last refresh confirmed alive.
  @ObservationIgnored private var liveRuntimeSubtaskIDs: Set<String> = []
  @ObservationIgnored private var spinningRuntimeSubtaskIDs: Set<String> = []
  private(set) var isQueueChatInspectorPresented = false
  private(set) var isTokenAnalyticsPresented = false
  private(set) var presentedAgentUpdate: QueueAgentUpdate?
  private(set) var presentedPlanTicketID: String?
  /// The in-app document viewer for files opened outside a task plan, such as
  /// project files chosen in settings or evidence links with no task.
  private(set) var isDocumentViewerPresented = false
  private(set) var documentViewerScope: DocumentScope?
  private(set) var documentViewer = DocumentPaneState()
  /// Shared document cache: previews survive split-layout changes and follow
  /// on-disk writes, so an open file never sticks on a transient read error.
  let documentContentStore = DocumentContentStore()
  private(set) var presentedPlanURL: URL?
  /// Native UI Canvas sessions per task, read from tasks/<TASK-ID>/canvas.
  private(set) var uiCanvasSessions: [String: [UICanvasSession]] = [:]
  /// A canvas an agent just opened; the plan viewer selects its tab once.
  private(set) var requestedUICanvas: UICanvasRequest?
  /// Canvas tabs the human closed; an agent's next `canvas open` shows them again.
  private(set) var dismissedUICanvasKeys: Set<String> = []
  /// Ended canvases the human reopened from the task's context; they stay
  /// visible past the usual one-day review window until dismissed again.
  private(set) var reopenedUICanvasKeys: Set<String> = []
  @ObservationIgnored private var uiCanvasModels: [String: UICanvasModel] = [:]
  @ObservationIgnored private var uiCanvasReconnectTasks: [String: Task<Void, Never>] = [:]
  private(set) var presentedPlanMarkdown = ""
  private(set) var isPlanLoading = false
  private(set) var planError: String? {
    didSet { logChangedError(planError, previous: oldValue, category: "Plan") }
  }
  private(set) var planEditDrafts: [String: PlanEditDraft] = [:]
  private(set) var launchingTaskIDs: Set<String> = []
  /// Set when a managed agent's registration stayed incomplete past its
  /// post-launch window; QueueView presents it as a hard alert.
  private var reportedRegistrationIssueIDs: Set<String> = []
  private(set) var openingSubtaskIDs: Set<String> = []
  private(set) var pauseChangingSubtaskIDs: Set<String> = []
  private(set) var openingAgentSessionIDs: Set<String> = []
  private(set) var agentSessionErrors: [String: String] = [:] {
    didSet {
      for (key, message) in agentSessionErrors where oldValue[key] != message {
        recordProgramLogChange(message, level: .error, category: "Agent \(key)")
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
  @ObservationIgnored private var lastRecordedProgramLogMessages: [String: String] = [:]
  @ObservationIgnored private let configurationRepository: any ConfigurationLoading
  @ObservationIgnored private let dailyReportRepository: any DailyReportStoring
  @ObservationIgnored private let dailyReportApprovalRepository: any DailyReportApprovalStoring
  @ObservationIgnored private let dashboardRepository: any DashboardManaging
  @ObservationIgnored private let stateStore: any LocalStateStoring
  @ObservationIgnored private let terminalController: any WezTermControlling
  @ObservationIgnored private let agentRegistrationInbox: AgentRegistrationInbox
  @ObservationIgnored private var queueAgents: [AgentProvider: any QueueAgentChatting]
  @ObservationIgnored private let queueAgentFactory: @Sendable (AgentProvider) -> any QueueAgentChatting
  @ObservationIgnored private let pullRequestQueueLoader: any PullRequestQueueLoading
  @ObservationIgnored private let taskContextStore: TaskContextStore
  @ObservationIgnored private let taskWorktreeManager = TaskWorktreeManager()
  @ObservationIgnored private let taskAgentLauncher: TaskAgentLauncher
  @ObservationIgnored private let taskPlacementSuggester: any TaskPlacementSuggesting
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
  @ObservationIgnored private var lastDurableVolatileFlush: Date?
  static let durableVolatileFlushInterval: TimeInterval = 10 * 60
  @ObservationIgnored private var durableDocumentStamps: [String: DurableDocumentStamp] = [:]
  @ObservationIgnored private var lastContextRefresh: Date?
  @ObservationIgnored private var lastOutputScan: Date?
  @ObservationIgnored private var lastDashboardRead: Date?
  @ObservationIgnored private var lastDashboardStamp: DashboardFileStamp?
  @ObservationIgnored private var lastDurableContextScan: Date?
  @ObservationIgnored private var lastExternalRegistrationRefresh: Date?
  @ObservationIgnored private var reportStateSaveTask: Task<Void, Never>?
  @ObservationIgnored private var cleanupSignatures: [String: Date] = [:]
  @ObservationIgnored private var cleaningTaskIDs: Set<String> = []
  @ObservationIgnored private var lastStagingPurge: Date?
  @ObservationIgnored private var lastReportRefresh: Date?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var windowSaveTask: Task<Void, Never>?
  @ObservationIgnored private var localStateSaveTask: Task<Void, Never>?
  @ObservationIgnored private var chatTasks: [QueueChatConversation: Task<Void, Never>] = [:]
  @ObservationIgnored private var documentConversations: [String: DocumentConversation] = [:]
  @ObservationIgnored private var configurationSaveTask: Task<Void, Never>?
  @ObservationIgnored private var lastRecurringPRRefresh: Date?
  @ObservationIgnored private var bootstrapped = false
  @ObservationIgnored private(set) var bootstrapTail: Task<Void, Never>?
  @ObservationIgnored private var refreshInFlight = false
  @ObservationIgnored private var projectRefreshPending = false
  @ObservationIgnored private var followUpRefreshPending = false
  @ObservationIgnored private var lastActivityCheck = Date()
  @ObservationIgnored private let agentActivityObserver: AgentActivityObserver
  @ObservationIgnored private var quotaFallbackedSubtaskKeys: Set<String> = []
  @ObservationIgnored private var quotaFallbackAtByTicketID: [String: Date] = [:]
  @ObservationIgnored private var escalationAutoLaunchInFlight = false
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
  @ObservationIgnored var windowPinHandler: (() -> Void)?
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
  @ObservationIgnored var newTaskHotkeyEnabledHandler: ((Bool) -> Void)?
  @ObservationIgnored var qchatHotkeyEnabledHandler: ((Bool) -> Void)?
  /// Re-applies global hotkeys after a shortcut changes or recording starts or stops.
  @ObservationIgnored var hotkeyConfigurationHandler: (() -> Void)?

  init(
    paths: AppPaths = .live(),
    programLog: ProgramLogStore = ProgramLogStore(),
    configurationRepository: (any ConfigurationLoading)? = nil,
    dailyReportRepository: (any DailyReportStoring)? = nil,
    dailyReportApprovalRepository: (any DailyReportApprovalStoring)? = nil,
    dashboardRepository: any DashboardManaging = JSONDashboardRepository(),
    stateStore: (any LocalStateStoring)? = nil,
    terminalController: any WezTermControlling = WezTermController(),
    agentRegistrationInbox: AgentRegistrationInbox? = nil,
    queueAgent: any QueueAgentChatting = CodexQueueAgent(),
    queueAgentFactory: (@Sendable (AgentProvider) -> any QueueAgentChatting)? = nil,
    pullRequestQueueLoader: any PullRequestQueueLoading = GitHubPullRequestQueueLoader(),
    taskAgentLauncher: TaskAgentLauncher = TaskAgentLauncher(),
    taskPlacementSuggester: (any TaskPlacementSuggesting)? = nil,
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
    checkProviderAccount: @escaping @Sendable (AgentProvider) async -> ProviderAccountState = {
      await ProviderAccounts.check($0)
    },
    signOutProviderAccount: @escaping @Sendable (AgentProvider) async -> String? = {
      await ProviderAccounts.signOut($0)
    },
    loadCodexCatalog: @escaping @Sendable () async -> CodexCatalog? = { nil },
    isWezTermInstalled: @escaping @Sendable (String) -> Bool = { _ in true },
    fileSignInFailure: @escaping @Sendable (SignInFailureContext) async -> SignInFailureReporter.Delivery = {
      await SignInFailureReporter.file($0)
    },
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
    self.checkProviderAccount = checkProviderAccount
    self.signOutProviderAccount = signOutProviderAccount
    self.loadCodexCatalog = loadCodexCatalog
    self.isWezTermInstalled = isWezTermInstalled
    self.fileSignInFailure = fileSignInFailure
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
    self.terminalController = terminalController
    self.agentRegistrationInbox =
      agentRegistrationInbox ?? AgentRegistrationInbox(directory: paths.agentRegistrationsDirectory)
    self.queueAgents = [.codex: queueAgent]
    self.queueAgentFactory = queueAgentFactory ?? { provider in
      switch provider {
      case .codex: CodexQueueAgent()
      case .claude: ClaudeQueueAgent()
      case .kimi: KimiQueueAgent()
      }
    }
    self.pullRequestQueueLoader = pullRequestQueueLoader
    self.taskAgentLauncher = taskAgentLauncher
    self.taskPlacementSuggester = taskPlacementSuggester
      ?? ScriptTaskPlacementSuggester(supportDirectory: paths.supportDirectory)
    self.agentLaunchLogger = agentLaunchLogger
      ?? AgentLaunchLogger(supportDirectory: paths.supportDirectory)
    self.connectorDiagnosticsRunner = connectorDiagnosticsRunner
    self.agentActivityObserver = agentActivityObserver
    // An owner's save of a contract in the viewer is the sign-off: edits go live at once.
    documentContentStore.didSave = { [weak self] url, text in self?.agentContractSaved(url, text: text) }
  }

  var openTickets: [DashboardTicket] {
    allOpenTickets.filter { includesInProject($0) }
  }

  private struct OpenTicketsKey: Equatable {
    var tickets: [DashboardTicket]
    var deferredIDs: [String]
    var noBacklogIDs: Set<String>
    var lastPromptAt: [String: Date]
    var lastOutputAt: [String: Date]
    var pinnedAt: [String: Date]
    var mode: QueueActivitySortMode
    var phases: DevelopmentProcess?
    var override: QueueOrderDocument?
    var activityHour: Int?
  }

  /// Ticket cards, tab labels, and headers each read these lists, so one render
  /// used to sort the whole queue dozens of times. Inputs are still read on
  /// every call, which keeps observation tracking unchanged.
  @ObservationIgnored private var openTicketsMemo = ProjectionMemo<OpenTicketsKey, [DashboardTicket]>()
  @ObservationIgnored private var completedTicketsMemo =
    ProjectionMemo<CompletedTicketsKey, CompletedTicketLists>()
  @ObservationIgnored private var agentUpdatesMemo = ProjectionMemo<AgentUpdatesKey, [QueueAgentUpdate]>()

  private var allOpenTickets: [DashboardTicket] {
    projectedOpenTickets(override: savedQueueOverride)
  }

  private func projectedOpenTickets(override queueOverride: QueueOrderDocument?) -> [DashboardTicket] {
    let tickets = dashboard.tickets
    let lastPromptAt = taskContexts.compactMapValues(\.latestInteractionAt)
    let lastOutputAt = taskContexts.compactMapValues { context in
      context.subtasks.compactMap { $0.lastOutputAt ?? $0.resultAt }.max()
    }
    let mode = queueActivitySortMode
    let phases = mode == .phase ? queuePhaseProcess : nil
    let pinnedAt = taskContexts.compactMapValues(\.pinnedAt)
    // Tasks leave the recent-activity window with time alone, so the memo
    // re-sorts at least hourly in that mode.
    let activityHour = mode == .recentActivity ? Int(Date().timeIntervalSinceReferenceDate / 3600) : nil
    let key = OpenTicketsKey(
      tickets: tickets,
      deferredIDs: localState.deferredTicketIDs,
      noBacklogIDs: Set(recurringPRProgressByTicketID.compactMap { ticketID, progress in
        progress.openCount == 0 ? ticketID : nil
      }),
      lastPromptAt: lastPromptAt,
      lastOutputAt: lastOutputAt,
      pinnedAt: pinnedAt,
      mode: mode,
      phases: phases,
      override: queueOverride,
      activityHour: activityHour)
    return openTicketsMemo.value(for: key) {
      let ordered = DashboardOrdering.openTickets(in: tickets, deferredTicketIDs: key.deferredIDs)
      let baseline = ordered.filter { !key.noBacklogIDs.contains($0.id) }
        + ordered.filter { key.noBacklogIDs.contains($0.id) }
      let activityOrdered = QueueOrderStore.prioritizingActivity(
        baseline,
        mode: key.mode,
        lastPromptAtByTicketID: key.lastPromptAt,
        lastOutputAtByTicketID: key.lastOutputAt)
      let automatic = QueueOrderStore.prioritizingPins(
        activityOrdered, pinnedAtByTicketID: key.pinnedAt, phases: key.phases)
      let automaticOpenIDs = automatic.filter(\.isOpen).map(\.id)
      guard let override = key.override,
            override.applies(to: automaticOpenIDs, sortMode: key.mode)
      else { return automatic }
      var remaining = Dictionary(
        automatic.filter(\.isOpen).map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first })
      let explicitlyOrdered = override.orderedIDs.compactMap { remaining.removeValue(forKey: $0) }
      var reordered = (explicitlyOrdered + automatic.filter { remaining.removeValue(forKey: $0.id) != nil })
        .makeIterator()
      let manuallyOrdered = automatic.map { $0.isOpen ? reordered.next()! : $0 }
      // Placement can reorder only the unpinned tier. A move targeting a
      // pinned task is therefore a visible no-op and never changes pin order.
      return QueueOrderStore.prioritizingPins(
        manuallyOrdered, pinnedAtByTicketID: key.pinnedAt, phases: key.phases)
    }
  }

  /// Automatic presentation without a temporary manual adjustment. Moves
  /// capture these IDs as the invalidation baseline.
  private var automaticOpenTicketIDs: [String] {
    projectedOpenTickets(override: nil).filter(\.isOpen).map(\.id)
  }

  private struct CompletedTicketsKey: Equatable {
    var tickets: [DashboardTicket]
    var today: String
    var timeZone: TimeZone
  }

  private struct CompletedTicketLists {
    var all: [DashboardTicket]
    var today: [DashboardTicket]
    var past: [DashboardTicket]
  }

  private var completedTicketLists: CompletedTicketLists {
    let key = CompletedTicketsKey(tickets: projectTickets,
      today: Self.dayFormatter.string(from: Date()), timeZone: .current)
    return completedTicketsMemo.value(for: key) {
      // A completed task stays here even when its cleanup needs attention;
      // the card shows the cleanup message and a retry.
      let all = key.tickets
        .filter(\.isCompleted)
        .sorted {
          if $0.completionTimestamp != $1.completionTimestamp {
            return ($0.completionTimestamp ?? "") > ($1.completionTimestamp ?? "")
          }
          return $0.id > $1.id
        }
      return CompletedTicketLists(all: all,
        today: all.filter { $0.completionDay(in: key.timeZone) == key.today },
        past: all.filter { $0.completionDay(in: key.timeZone) != key.today })
    }
  }

  var completedTickets: [DashboardTicket] { completedTicketLists.all }

  var completedTodayTickets: [DashboardTicket] { completedTicketLists.today }

  var pastCompletedTickets: [DashboardTicket] { completedTicketLists.past }

  var blockedTicketCount: Int {
    openTickets.filter { $0.status.lowercased() == "blocked" }.count
  }

  var completedRoutineCount: Int {
    localState.completedRoutineIDs.intersection(Set(visibleRoutines.map(\.id))).count
  }

  var selectedProjectID: String? {
    config.selectedProjectID
  }
  /// The all-projects scope is the default; picking a single project opts out.
  var showsAllProjects: Bool { localState.showsAllProjects ?? true }
  var projectScopeName: String {
    showsAllProjects ? "All" : selectedProject?.name ?? "No project"
  }
  var activeProjects: [ProjectDefinition] { config.projects.filter { $0.archivedAt == nil } }
  var projectTickets: [DashboardTicket] { dashboard.tickets }
  var hasUnassignedTasks: Bool { false }
  var visibleRoutines: [DailyRoutine] {
    config.dailyRoutines.filter { routine in
      guard let owner = routine.projectID else { return true }
      return owner == selectedProjectID
    }
  }
  func project(for ticket: DashboardTicket) -> ProjectDefinition? {
    guard showsAllProjects else { return selectedProject }
    if let match = config.projects.first(where: { $0.id == ticket.projectID }) { return match }
    if let category = ticket.category,
       let match = config.projects.first(where: { $0.name == category }) { return match }
    return selectedProject
  }
  /// The dashboard file that owns a ticket. Single-project scope stays aligned
  /// with `config.dashboardPath`; the all-projects scope resolves per ticket.
  func dashboardPath(for ticket: DashboardTicket) -> String {
    let path = project(for: ticket)?.dashboardPath.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return path.isEmpty ? config.dashboardPath : path
  }
  func includesInProject(_ ticket: DashboardTicket) -> Bool { true }
  func revealProject(for ticketID: String) {}
  /// Empty repository fields mean "not configured"; skip them like a missing value.
  private static func firstConfiguredPath(_ candidates: String?...) -> String? {
    candidates.lazy.compactMap { $0 }.first { !$0.isEmpty }
  }
  func defaultRepository(for ticket: DashboardTicket) -> String {
    let context = taskContexts[ticket.id]
    let ticketProject = project(for: ticket)
    // New agents branch from the task's canonical project repository. An
    // existing agent worktree belongs only to that agent and must never become
    // the source checkout for the next one-click launch.
    // Focus Queue's data folder holds queue files, not code: a project without
    // its own folder (Other, the starter queue) starts agents in the home directory.
    return [context?.projectRepositoryPath, ticketProject?.repositoryPath,
            context?.repositoryPath, ticketProject?.workspacePath,
            ticket.worktree, context?.worktreePath, config.workspacePath]
      .compactMap { $0 }
      .first { !$0.isEmpty && !TaskWorktreeManager.isApplicationSupportPath($0, storeRoot: paths.supportDirectory) }
      ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
  }
  @discardableResult
  func saveProject(_ project: ProjectDefinition) async -> Bool {
    guard !isSavingProject else { return false }
    isSavingProject = true
    defer { isSavingProject = false }
    do {
      try await persistProject(project)
      projectError = nil
      return true
    } catch { projectError = error.localizedDescription; return false }
  }

  @discardableResult
  func deleteProject(id: String) async -> Bool {
    guard !isSavingProject else { return false }
    isSavingProject = true
    defer { isSavingProject = false }
    configurationSaveTask?.cancel()
    await configurationSaveTask?.value
    do {
      for url in documentViewer.tabs {
        guard documentContentStore.saveBeforeClose(url) else {
          throw TaskContextError.commandFailed("Save your open document edits before deleting this project.")
        }
      }
      config = try ProjectDeletion(supportDirectory: paths.supportDirectory,
        configurationURL: paths.configurationFile).delete(projectID: id)
      localState.selectedProjectID = config.selectedProjectID
      closeAgentUpdate()
      closePlan()
      closeDocumentViewer()
      lastContextRefresh = nil
      lastDashboardStamp = nil
      lastDashboardRead = nil
      await primePresentationFromDisk()
      await refresh()
      projectError = nil
      return true
    } catch { projectError = error.localizedDescription; return false }
  }

  /// The draft retains a newly created remote even if subsequent local persistence fails.
  func createProject(_ draft: inout ProjectSetupDraft,
                     service: ProjectSetupService = ProjectSetupService()) async -> Bool {
    guard !isSavingProject else { return false }
    isSavingProject = true
    defer { isSavingProject = false }
    do {
      let project = try await service.prepare(&draft, supportDirectory: paths.supportDirectory,
        projects: config.projects)
      try await persistProject(project)
      projectError = nil
      return true
    } catch { projectError = error.localizedDescription; return false }
  }

  private func persistProject(_ project: ProjectDefinition) async throws {
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
    _ = try projectContextStore.ensurePlan(for: project)
    lastContextRefresh = nil
    await refresh()
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
  var projectContextStore: ProjectContextStore { ProjectContextStore(root: paths.supportDirectory) }
  var developmentProcessStore: DevelopmentProcessStore {
    DevelopmentProcessStore(root: paths.supportDirectory)
  }
  /// The selected project's development process, nil when disabled or absent.
  /// Reloaded with the task contexts so agent edits to development.json appear.
  private(set) var developmentProcess: DevelopmentProcess?
  /// Enabled development processes of every project, for phase markers in the
  /// all-projects view. Reloaded with the task contexts.
  private(set) var phaseProcessesByProjectID: [String: DevelopmentProcess] = [:]
  /// Set from the last development-process mutation; surfaced in the Project tab.
  private(set) var developmentProcessError: String?
  /// The project whose background steward pass is running, if any.
  private(set) var developmentStewardProjectID: String?
  /// The selected project's agent contracts, refreshed with the process.
  private(set) var developmentContracts: [AgentContractStatus] = []
  /// The project whose contract generator is running, if any.
  private(set) var contractGenerationProjectID: String?
  @ObservationIgnored private var lastDevelopmentStewardCheck: Date?
  @ObservationIgnored var developmentStewardRunner: DevelopmentStewardRunner?
  var projects: [ProjectConfiguration] { config.projects }
  var selectedProject: ProjectConfiguration? { config.selectedProject }
  var windowSnapshot: WindowSnapshot? { localState.window }
  /// New installs start dark; the welcome card offers light.
  var appearance: QueueAppearance { localState.appearance ?? .dark }
  var accentStyle: QueueAccentStyle { localState.accentStyle ?? .vibrant }
  /// PDFs follow the app's appearance until the viewer's toggle picks a side for this run.
  private(set) var pdfDarkModeOverride: Bool?
  var isPDFDarkMode: Bool { pdfDarkModeOverride ?? (appearance == .dark) }
  func togglePDFDarkMode() { pdfDarkModeOverride = !isPDFDarkMode }
  var windowPlacement: QueueWindowPlacement {
    localState.window?.placement ?? config.defaultPlacement
  }

  var isPanelCollapsed: Bool { panelMode == .collapsed }
  var isTopTaskOnly: Bool { panelMode == .topTask }
  var minimizationPreference: QueueMinimizationPreference {
    localState.minimizationPreference
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
      let needsSetup = firstRun || config.setupCompleted == false
      configurationIsLoaded = true
      adoptInstalledTerminal()
      localState = try await stateStore.load()
      // A new install gets the walkthrough, which covers terminal setup; the
      // setup wizard stays available from Settings.
      if needsSetup, localState.walkthroughCompletedAt == nil { startWalkthrough() }
      else { isSetupPresented = needsSetup }
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
    // Checked at every launch so the sign-in gate covers installs that finished the tour without one.
    if walkthrough == nil {
      Task { @MainActor [weak self] in await self?.refreshProviderAccounts() }
    }
  }

  /// WezTerm is optional. Earlier versions chose it by default even when it was
  /// not installed, so that choice moves to macOS Terminal, which every Mac has.
  private func adoptInstalledTerminal() {
    guard config.wezTerm.terminalApp == .wezTerm, !isWezTermInstalled(config.wezTerm.executable) else { return }
    setManagedTerminal(.terminal)
  }

  /// Read-only disk load so agent boxes render before any reconciliation runs.
  private func primePresentationFromDisk() async {
    if showsAllProjects {
      if let merged = try? await loadAllProjectsDashboard() { dashboard = merged }
    } else {
      let dashboardURL = URL(fileURLWithPath: config.dashboardPath)
      if let document = try? await dashboardRepository.load(from: dashboardURL) {
        dashboard = document
      }
    }
    taskContexts = await availableTaskContexts()
    try? reloadApplicableQueueOverride()
  }

  /// Distinct dashboard files for every unarchived project, Other included.
  private var scopedDashboardURLs: [URL] {
    ProjectCatalog.mergedDashboardURLs(in: config.projects)
  }

  /// Merges every project dashboard into one presentation document. A damaged
  /// or missing project dashboard is skipped rather than failing the scope.
  private func loadAllProjectsDashboard() async throws -> DashboardDocument {
    try await loadAllProjectsDashboardSources().document
  }

  /// Also reports each loaded dashboard's ticket IDs by path, which seeds the
  /// viewed-task baseline per project rather than for the merged scope.
  private func loadAllProjectsDashboardSources() async throws
    -> (document: DashboardDocument, sources: [String: [String]])
  {
    var tickets: [DashboardTicket] = []
    var seenIDs = Set<String>()
    var updatedAt: String?
    var sources: [String: [String]] = [:]
    for url in scopedDashboardURLs {
      guard let document = try? await dashboardRepository.load(from: url) else { continue }
      if let stamp = document.updatedAt, stamp > (updatedAt ?? "") { updatedAt = stamp }
      sources[url.standardizedFileURL.path] = document.tickets.map(\.id)
      for ticket in document.tickets where seenIDs.insert(ticket.id).inserted {
        tickets.append(ticket)
      }
    }
    return (DashboardDocument(updatedAt: updatedAt, tickets: tickets), sources)
  }

  /// Replaces the merged dashboard after a per-project write in the
  /// all-projects scope; single-project scope updates the document directly.
  private func reloadMergedDashboard() async {
    guard let merged = try? await loadAllProjectsDashboard() else { return }
    dashboard = merged
    await captureDurableDashboard(merged)
  }

  private func allProjectsStamp() async throws -> DashboardFileStamp {
    var modifiedAt: Date?
    var size: UInt64 = 0
    var found = false
    for url in scopedDashboardURLs {
      let stamp = try? await Task.detached(priority: .utility) {
        try DashboardFileStamp.read(at: url)
      }.value
      guard let stamp else { continue }
      found = true
      if let date = stamp.modifiedAt, date > (modifiedAt ?? .distantPast) { modifiedAt = date }
      size += stamp.size ?? 0
    }
    guard found else { throw CocoaError(.fileReadNoSuchFile) }
    return DashboardFileStamp(modifiedAt: modifiedAt, size: size, inode: nil)
  }

  /// Tolerant read-only contexts. Swap whole dictionaries so the panel never
  /// shows an empty queue while replacement data is still loading.
  private func availableTaskContexts() async -> [String: TaskContext] {
    let discovered = (try? await taskContextStore.loadAvailableForDiscovery()) ?? []
    return Dictionary(discovered.map { ($0.ticketID, $0) }, uniquingKeysWith: { _, last in last })
  }

  private func finishBootstrap() async {
    do {
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
      try await loadQueueChatTabs()
      isRecoveredDailyReportRunning = try await reportHistoryRepository.reconcileInactiveRuns()
      // The first refresh retains report history; capturing it here delayed
      // that refresh and every queue update behind it.
      await reloadDailyReport(capturingHistory: false)
      if config.dailyReport.enabled,
        let approval = try await dailyReportApprovalRepository.load(),
        approval.status == .pending,
        approval.reportDate == Self.dayFormatter.string(from: Date())
      {
        pendingDailyReportApproval = approval
      }
      await importAgentRegistrations()
      resetDailyRoutinesIfNeeded()
      try await stateStore.save(localState)
      await refresh(forceRecurringPRProgress: true)
      startRefreshLoop()
      programLog.record(
        "Ready with project \(selectedProject?.name ?? "Unknown").",
        category: "Lifecycle"
      )
      // The full history import rescans every task folder. Polling already
      // captures each change, so the queue no longer waits for this sweep.
      await reconcileDurableLibrary()
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
        let snapshot = showsAllProjects ? nil : try await dashboardRepository.loadSnapshot(
          from: URL(fileURLWithPath: reloaded.dashboardPath))
        config = reloaded
        closeAgentUpdate()
        closePlan()
        setQueueChatInspectorPresented(false)
        setDailyReportPresented(false)
        if let snapshot {
          dashboard = snapshot.document
        } else if let merged = try? await loadAllProjectsDashboard() {
          dashboard = merged
        }
        savedQueueOverride = nil
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
        if let snapshot {
          await captureDurableDashboard(snapshot.document)
        } else {
          await captureDurableDashboard(dashboard)
        }
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
      for project in updated.projects { _ = try projectContextStore.ensurePlan(for: project) }
      setupError = nil
      isSetupPresented = false
      createStarterIngestionConfiguration()
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
  /// Switches the queue to the merged all-projects scope (the default view).
  func selectAllProjects() async {
    guard !showsAllProjects else { return }
    localState.showsAllProjects = true
    persistLocalState()
    closeAgentUpdate()
    closePlan()
    setQueueChatInspectorPresented(false)
    setDailyReportPresented(false)
    savedQueueOverride = nil
    sourceModificationDate = nil
    lastDashboardStamp = nil
    lastDashboardRead = nil
    lastSync = nil
    expandedTicketIDs.removeAll()
    if let merged = try? await loadAllProjectsDashboard() {
      dashboard = merged
      await captureDurableDashboard(merged)
    }
    taskContexts = await availableTaskContexts()
    reloadDevelopmentProcess()
    if refreshInFlight {
      projectRefreshPending = true
    } else {
      await refresh(forceRecurringPRProgress: true, userInitiated: true)
    }
  }

  func selectProject(id: String) async -> Bool {
    guard let project = config.projects.first(where: { $0.id == id }) else { return false }
    // Re-picking the persisted project still leaves the all-projects scope.
    guard showsAllProjects || config.selectedProjectID != id else { return true }

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
      localState.showsAllProjects = false
      persistLocalState()
      programLog.record("Selected project \(project.name).", category: "Projects")

      closeAgentUpdate()
      closePlan()
      setQueueChatInspectorPresented(false)
      setDailyReportPresented(false)
      dashboard = snapshot.document
      loadError = nil
      savedQueueOverride = nil
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
      reloadDevelopmentProcess()
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
    dueDate: Date? = nil, projectID: String? = nil
  ) async -> Bool {
    await createTicket(title: title, summary: summary, doneWhen: doneWhen, priority: priority,
      dueDate: dueDate, projectID: projectID) != nil
  }

  /// Creates the ticket and returns it, so a caller can launch an agent on it.
  /// `next` defaults to a clarification step when nothing more specific is known.
  func createTicket(
    title: String, summary: String, doneWhen: String, priority: String,
    dueDate: Date? = nil, projectID: String? = nil, next: String? = nil
  ) async -> DashboardTicket? {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      loadError = "Give the task a readable title."
      return nil
    }
    let targetID = projectID ?? config.selectedProjectID
    guard let project = config.projects.first(where: { $0.id == targetID }) else {
      loadError = "The selected project is no longer configured."
      return nil
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
        next: next.map { String($0.prefix(1_200)) } ?? "Clarify the next implementation step.",
        doneWhen: String(
          (trimmedDoneWhen.isEmpty
            ? TaskContext.genericSuccessCriteria
            : trimmedDoneWhen).prefix(900)),
        updatedAt: Self.dayFormatter.string(from: Date()),
        createdAt: Self.dayFormatter.string(from: Date()),
        dueDate: dueDate.map(TaskTriagePolicy.dateOnlyString),
        dueDateSource: dueDate == nil ? nil : "User specified"
      )
      let updated = try await dashboardRepository.createTicket(
        ticket, in: url, expectedRevision: snapshot.revision,
        checking: otherDashboards)
      if showsAllProjects {
        await reloadMergedDashboard()
      } else if config.selectedProjectID == project.id {
        dashboard = updated.document
        await captureDurableDashboard(updated.document)
      }
      actionMessages[ticket.id] = "Task added to \(project.name)."
      programLog.record("Created task \(ticket.id): \(ticket.title)", category: "Tasks")
      loadError = nil
      return ticket
    } catch {
      loadError = "Could not create task: \(error.localizedDescription)"
      return nil
    }
  }

  /// Defaults for the + task creator: the last agent the user launched, else
  /// the Settings default provider with its model and effort.
  var taskCreatorLaunchDefaults: AgentLaunchPreset {
    localState.lastAgentLaunch ?? lastAgentLaunch(for: defaultAgentProvider)
  }

  /// The provider's last user launch, else its Settings model and effort.
  func lastAgentLaunch(for provider: AgentProvider) -> AgentLaunchPreset {
    var preset = localState.lastAgentLaunch(for: provider) ?? AgentLaunchPreset(
      provider: provider, workspacePolicy: .isolatedCommittedSnapshot,
      useTmux: true, includePrompt: true)
    // A launch saved with "Default" names no model; show the one that will run.
    preset.model = preset.model ?? defaultAgentModel(for: provider)
    preset.effort = preset.effort ?? defaultAgentEffort(for: provider)
    return preset
  }

  /// Only launches the user starts update the creator's defaults; automatic
  /// relaunches such as quota fallback never do.
  func rememberAgentLaunch(_ preset: AgentLaunchPreset) {
    var updated = localState
    updated.rememberAgentLaunch(preset)
    guard updated != localState else { return }
    localState = updated
    persistLocalState()
  }

  /// Creates a task from the + creator and, unless the draft opts out,
  /// launches its first agent with full placement. The placement model fills
  /// blank fields and offers a matching open task before a duplicate is made.
  func submitTaskDraft(
    _ draft: TaskDraft, choice: TaskDraftChoice = .checkForMatch,
    suggestion cached: TaskPlacementSuggestion? = nil
  ) async -> TaskDraftResult {
    let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !description.isEmpty else { return .failed("Describe the task first.") }
    if case .join(let ticketID) = choice {
      guard let ticket = await findTicket(id: ticketID) else {
        return .failed("\(ticketID) is no longer in any dashboard.")
      }
      if draft.startsAgent { launchDraftAgent(draft, on: ticket, description: description) }
      return .joined(ticketID: ticket.id, launchedAgent: draft.startsAgent)
    }
    guard let project = config.projects.first(where: { $0.id == (draft.projectID ?? config.selectedProjectID) })
    else { return .failed("The selected project is no longer configured.") }
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayDescription = draft.displayDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    // Without an agent the New Task button always creates a task: there is
    // no launch to redirect, so a matching open task is never offered.
    let checksForMatch = choice == .checkForMatch && draft.startsAgent
    var suggestion = cached
    if suggestion == nil,
       checksForMatch || title.isEmpty || displayDescription.isEmpty || draft.priority == nil {
      suggestion = placementModelEnabled
        ? await taskPlacementSuggester.suggest(TaskPlacementQuery(
            description: description, provider: draft.agent.provider,
            cwd: project.repositoryPath.isEmpty ? project.workspacePath : project.repositoryPath,
            timeoutSeconds: placementTimeoutSeconds))
        : .unavailable("Task placement is off in Settings.")
    }
    if checksForMatch, let matchID = suggestion?.matchedTaskID,
       let match = await findTicket(id: matchID), let suggestion {
      return .matched(match, suggestion)
    }
    // The user's choice wins, then the placement model's; otherwise medium,
    // so declining to pick never blocks creating a task.
    let priority = draft.priority ?? suggestion?.priority ?? "medium"
    let ticketTitle = title.isEmpty
      ? (suggestion?.title ?? TaskSubtask.agentName(prompt: description, provider: draft.agent.provider))
      : title
    let summary = displayDescription.isEmpty ? (suggestion?.summary ?? description) : displayDescription
    // A short card summary must not lose the full description, even without an agent.
    guard let ticket = await createTicket(
      title: ticketTitle, summary: summary, doneWhen: draft.doneWhen, priority: priority,
      dueDate: draft.dueDate, projectID: project.id, next: summary == description ? nil : description)
    else { return .failed(loadError ?? "Could not create the task.") }
    if draft.startsAgent {
      launchDraftAgent(draft, on: ticket, description: description)
    } else {
      await saveInitialPrompt(description, for: ticket)
    }
    return .created(ticketID: ticket.id, launchedAgent: draft.startsAgent)
  }

  /// The task already exists, so a failed save is reported on its card
  /// instead of failing the draft and inviting a duplicate task.
  private func saveInitialPrompt(_ prompt: String, for ticket: DashboardTicket) async {
    do {
      let url = try await taskContextStore.saveInitialPrompt(prompt, ticket: ticket, project: project(for: ticket))
      taskContexts[ticket.id] = try await taskContextStore.load(ticketID: ticket.id)
      programLog.record("Saved the initial prompt for \(ticket.id) at \(url.path)", category: "Tasks")
    } catch {
      actionMessages[ticket.id] = "Task added, but its prompt was not saved: \(error.localizedDescription)"
    }
  }

  /// The prompt a task was created with, offered to its first agent.
  func savedInitialPrompt(for ticket: DashboardTicket) -> String? {
    guard subtasks(for: ticket.id).isEmpty else { return nil }
    return taskContexts[ticket.id]?.savedInitialPrompt
  }

  private func launchDraftAgent(_ draft: TaskDraft, on ticket: DashboardTicket, description: String) {
    launchPromptedAgent(for: ticket, prompt: description, title: ticket.title, preset: draft.agent)
  }

  /// Starts one agent on an existing task from a prompt and launch preset, as
  /// the card's New Agent sheet does. A blank title is derived from the prompt.
  func launchPromptedAgent(
    for ticket: DashboardTicket, prompt: String, title: String = "", preset: AgentLaunchPreset
  ) {
    let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }
    launchAgent(
      for: ticket,
      title: title.isEmpty ? TaskSubtask.agentName(prompt: prompt, provider: preset.provider) : title,
      provider: preset.provider,
      repositoryPath: defaultRepository(for: ticket), assignmentDescription: prompt,
      includePrompt: preset.includePrompt ?? true, useTmux: preset.useTmux ?? true,
      initialPrompt: prompt, modelName: preset.model, effort: preset.effort,
      workspacePolicy: preset.workspacePolicy ?? .isolatedCommittedSnapshot,
      pluginOverrides: preset.pluginOverrides ?? [:])
    rememberAgentLaunch(preset)
  }

  /// A placement match can name a task in any configured project.
  private func findTicket(id: String) async -> DashboardTicket? {
    let matches: (DashboardTicket) -> Bool = { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    if let ticket = dashboard.tickets.first(where: matches) { return ticket }
    for project in config.projects {
      let url = URL(fileURLWithPath: project.dashboardPath)
      if let ticket = try? await dashboardRepository.load(from: url).tickets.first(where: matches) {
        return ticket
      }
    }
    return nil
  }

  @discardableResult
  func renameTask(_ ticket: DashboardTicket, to title: String) async -> Bool {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, let project = project(for: ticket) ?? selectedProject else {
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
      let isVisibleScope = showsAllProjects || config.selectedProjectID == projectID
      if isVisibleScope {
        if showsAllProjects {
          await reloadMergedDashboard()
        } else {
          dashboard = updated.document
        }
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
            if isVisibleScope {
              taskContexts[ticket.id] = repaired
              await captureDurableContexts(Array(taskContexts.values))
            }
          } catch {
            contextRepairError = error.localizedDescription
          }
        }
      }
      if isVisibleScope {
        if !showsAllProjects {
          await captureDurableDashboard(updated.document)
        }
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

  @discardableResult
  func setTaskPriority(_ ticket: DashboardTicket, to priority: String) async -> Bool {
    let priority = Self.allowedPriority(priority)
    guard priority != ticket.priority.lowercased() else { return true }
    guard let project = project(for: ticket) ?? selectedProject else {
      actionMessages[ticket.id] = "Could not update priority: no owning project."
      return false
    }
    do {
      let url = URL(fileURLWithPath: project.dashboardPath)
      let snapshot = try await dashboardRepository.loadSnapshot(from: url)
      let updated = try await dashboardRepository.setTicketPriority(
        id: ticket.id, to: priority, in: url, expectedRevision: snapshot.revision)
      if showsAllProjects {
        await reloadMergedDashboard()
      } else if config.selectedProjectID == project.id {
        dashboard = updated.document
        await captureDurableDashboard(updated.document)
      }
      actionMessages[ticket.id] = "Priority updated."
      loadError = nil
      return true
    } catch {
      actionMessages[ticket.id] = "Could not update priority: \(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  func setTaskStatus(_ ticket: DashboardTicket, to status: String) async -> Bool {
    let status = TaskFieldChoices.normalizedStatus(status)
    guard !status.isEmpty, !TaskFieldChoices.closedStatuses.contains(status) else {
      actionMessages[ticket.id] = "Could not update status: mark the task complete or archive it to close it."
      return false
    }
    guard status != TaskFieldChoices.normalizedStatus(ticket.status) else { return true }
    guard let project = project(for: ticket) ?? selectedProject else {
      actionMessages[ticket.id] = "Could not update status: no owning project."
      return false
    }
    do {
      let url = URL(fileURLWithPath: project.dashboardPath)
      let snapshot = try await dashboardRepository.loadSnapshot(from: url)
      let updated = try await dashboardRepository.setTicketStatus(
        id: ticket.id, to: status, in: url, expectedRevision: snapshot.revision)
      if showsAllProjects {
        await reloadMergedDashboard()
      } else if config.selectedProjectID == project.id {
        dashboard = updated.document
        await captureDurableDashboard(updated.document)
      }
      actionMessages[ticket.id] = "Status updated."
      loadError = nil
      return true
    } catch {
      actionMessages[ticket.id] = "Could not update status: \(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  func markTaskIncomplete(_ ticket: DashboardTicket) async -> Bool {
    guard ticket.isCompleted else { return true }
    do {
      let url = URL(fileURLWithPath: dashboardPath(for: ticket))
      let snapshot = try await dashboardRepository.loadSnapshot(from: url)
      let updated = try await dashboardRepository.reopenTicket(
        id: ticket.id, in: url, expectedRevision: snapshot.revision)
      if showsAllProjects {
        await reloadMergedDashboard()
      } else {
        dashboard = updated.document
        await captureDurableDashboard(updated.document)
      }
      closureMessages[ticket.id] = nil
      cleanupSignatures[ticket.id] = nil
      if try await taskContextStore.load(ticketID: ticket.id) != nil {
        taskContexts[ticket.id] = try await taskContextStore.setPinned(ticketID: ticket.id, at: nil)
      }
      actionMessages[ticket.id] = "Task marked incomplete and returned to Focus."
      loadError = nil
      return true
    } catch {
      actionMessages[ticket.id] = "Could not mark task incomplete: \(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  func archiveWithoutCompletion(_ ticket: DashboardTicket) async -> Bool {
    guard ticket.isOpen else { return true }
    do {
      let url = URL(fileURLWithPath: dashboardPath(for: ticket))
      let snapshot = try await dashboardRepository.loadSnapshot(from: url)
      let updated = try await dashboardRepository.setTicketStatus(
        id: ticket.id, to: "cancelled", in: url, expectedRevision: snapshot.revision)
      if showsAllProjects {
        await reloadMergedDashboard()
      } else {
        dashboard = updated.document
        await captureDurableDashboard(updated.document)
      }
      closureMessages[ticket.id] = nil
      if try await taskContextStore.load(ticketID: ticket.id) != nil {
        taskContexts[ticket.id] = try await taskContextStore.setPinned(ticketID: ticket.id, at: nil)
      }
      actionMessages[ticket.id] = "Task archived without completion."
      loadError = nil
      return true
    } catch {
      actionMessages[ticket.id] = "Could not archive task: \(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  func setTaskHardDeadline(_ ticket: DashboardTicket, to dueDate: Date?) async -> Bool {
    guard let project = project(for: ticket) ?? selectedProject else {
      actionMessages[ticket.id] = "Could not update hard due date: no owning project."
      return false
    }
    do {
      let url = URL(fileURLWithPath: project.dashboardPath)
      let snapshot = try await dashboardRepository.loadSnapshot(from: url)
      let updated = try await dashboardRepository.setTicketDueDate(
        id: ticket.id,
        to: dueDate.map(TaskTriagePolicy.dateOnlyString),
        source: dueDate == nil ? nil : "User specified",
        in: url,
        expectedRevision: snapshot.revision)
      if showsAllProjects {
        await reloadMergedDashboard()
      } else if config.selectedProjectID == project.id {
        dashboard = updated.document
        await captureDurableDashboard(updated.document)
      }
      actionMessages[ticket.id] = dueDate == nil ? "Hard due date cleared." : "Hard due date updated."
      loadError = nil
      return true
    } catch {
      actionMessages[ticket.id] = "Could not update hard due date: \(error.localizedDescription)"
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
    return TaskFieldChoices.priorities.contains(value) ? value : "medium"
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
        followUpRefreshPending = false
        Task { @MainActor [weak self] in
          await self?.refresh(forceRecurringPRProgress: true, userInitiated: true)
        }
      } else if followUpRefreshPending {
        followUpRefreshPending = false
        lastDashboardRead = nil
        Task { @MainActor [weak self] in await self?.refresh() }
      }
    }
    do {
      let projectID = config.selectedProjectID
      let showingAll = showsAllProjects
      let now = Date()
      let stamp: DashboardFileStamp
      if showingAll {
        stamp = try await allProjectsStamp()
      } else {
        let dashboardURL = URL(fileURLWithPath: config.dashboardPath)
        stamp = try await Task.detached(priority: .utility) {
          try DashboardFileStamp.read(at: dashboardURL)
        }.value
      }
      let needsDashboardRead = userInitiated || lastDashboardStamp != stamp
        || lastDashboardRead.map { now.timeIntervalSince($0) >= 60 } ?? true
      if needsDashboardRead {
        if showingAll {
          let (merged, sources) = try await loadAllProjectsDashboardSources()
          guard showsAllProjects else { return }
          reconcileViewedTasks(sources: sources)
          if dashboard != merged { dashboard = merged }
          if lastDurableDashboard != merged { await captureDurableDashboard(merged) }
        } else {
          let dashboardURL = URL(fileURLWithPath: config.dashboardPath)
          let updatedDashboard = try await dashboardRepository.load(from: dashboardURL)
          guard projectID == config.selectedProjectID else { return }
          reconcileViewedTasks(sources: [
            dashboardURL.standardizedFileURL.path: updatedDashboard.tickets.map(\.id),
          ])
          if dashboard != updatedDashboard { dashboard = updatedDashboard }
          if lastDurableDashboard != updatedDashboard { await captureDurableDashboard(updatedDashboard) }
        }
        lastDashboardStamp = stamp
        lastDashboardRead = now
      }
      guard projectID == config.selectedProjectID else { return }
      let updatedOverride = try queueOrderStore.loadOverride()
      if savedQueueOverride != updatedOverride { savedQueueOverride = updatedOverride }
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
      await refreshTaskOutputs()
      try reloadApplicableQueueOverride()
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
      runDevelopmentStewardIfDue()
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
      markTicketViewed(ticketID)
    } else {
      expandedTicketIDs.remove(ticketID)
    }
  }

  /// The mode the queue sorts by now. A saved phase order applies only while
  /// a single project with an enabled development process is shown.
  var queueActivitySortMode: QueueActivitySortMode {
    (localState.queueActivitySortMode ?? .recentActivity).resolved(hasPhases: queuePhaseProcess != nil)
  }

  /// The shown project's development process when the queue can use phases:
  /// one project selected and its process enabled. Nil means criticality only.
  var queuePhaseProcess: DevelopmentProcess? {
    showsAllProjects ? nil : developmentProcess
  }

  /// Sort modes the menu offers; phase order only where phases exist.
  var availableQueueSortModes: [QueueActivitySortMode] {
    QueueActivitySortMode.allCases.filter {
      $0 != .manual && ($0 != .phase || queuePhaseProcess != nil)
    }
  }

  /// Phase markers replace priority markers wherever the task's project uses
  /// the development process, in any sort mode.
  func phaseProcess(for ticket: DashboardTicket) -> DevelopmentProcess? {
    guard let process = queuePhaseProcess ?? phaseProcessesByProjectID[project(for: ticket)?.id ?? ""]
    else { return nil }
    return process
  }

  func phaseGroup(for ticket: DashboardTicket) -> QueueOrderStore.PhaseGroup? {
    phaseProcess(for: ticket).map { QueueOrderStore.PhaseGroup(taskID: ticket.id, process: $0) }
  }

  /// The open tasks this task waits on, in queue order, then any others.
  func openPrerequisites(of ticket: DashboardTicket) -> [DashboardTicket] {
    guard let process = phaseProcess(for: ticket) else { return [] }
    let ids = Set(process.prerequisites(of: ticket.id))
    guard !ids.isEmpty else { return [] }
    return dashboard.tickets.filter { $0.isOpen && ids.contains($0.id.uppercased()) }
      .sorted { (openTicketPosition[$0.id] ?? .max) < (openTicketPosition[$1.id] ?? .max) }
  }

  private var openTicketPosition: [String: Int] {
    Dictionary(openTickets.enumerated().map { ($0.element.id, $0.offset) },
               uniquingKeysWith: { first, _ in first })
  }

  /// Other open tasks in the same project, offered as prerequisites.
  func prerequisiteCandidates(for ticket: DashboardTicket) -> [DashboardTicket] {
    let projectID = project(for: ticket)?.id
    return allOpenTickets.filter { $0.id != ticket.id && project(for: $0)?.id == projectID }
  }

  func dependsOn(_ ticket: DashboardTicket, prerequisite: DashboardTicket) -> Bool {
    phaseProcess(for: ticket)?.prerequisites(of: ticket.id).contains(prerequisite.id.uppercased()) == true
  }

  /// Adds or removes one prerequisite through the locked process store.
  func setDependency(_ ticket: DashboardTicket, on prerequisite: DashboardTicket, enabled: Bool) {
    guard let projectID = project(for: ticket)?.id, let process = phaseProcess(for: ticket) else { return }
    var ids = process.prerequisites(of: ticket.id)
    if enabled { ids.append(prerequisite.id) } else { ids.removeAll { $0 == prerequisite.id.uppercased() } }
    do {
      let updated = try developmentProcessStore.setDependencies(
        taskID: ticket.id, prerequisites: ids, projectID: projectID)
      publishPhaseProcess(updated, projectID: projectID)
      actionMessages[ticket.id] = enabled
        ? "\(ticket.id) now waits on \(prerequisite.id)." : "\(ticket.id) no longer waits on \(prerequisite.id)."
    } catch {
      actionMessages[ticket.id] = error.localizedDescription
    }
  }

  /// Links a task to a development step, or marks it outside the process.
  func setDevelopmentStep(_ ticket: DashboardTicket, step: String?) {
    guard let projectID = project(for: ticket)?.id else { return }
    do {
      let updated = try developmentProcessStore.link(taskID: ticket.id, step: step, projectID: projectID)
      publishPhaseProcess(updated, projectID: projectID)
    } catch {
      actionMessages[ticket.id] = error.localizedDescription
    }
  }

  private func publishPhaseProcess(_ updated: DevelopmentProcess, projectID: String) {
    let visible = updated.enabled ? updated : nil
    if projectID == selectedProject?.id, developmentProcess != visible { developmentProcess = visible }
    if phaseProcessesByProjectID[projectID] != visible { phaseProcessesByProjectID[projectID] = visible }
  }

  var queueActivitySortCaption: String {
    switch queueActivitySortMode {
    case .phase: "Development phase first · then dependency order"
    case .recentActivity: "Active in the last 2 days first · then by priority"
    case .recentInteraction: "Last task interaction first · deadlines cycle the rest"
    case .recentOutput: "Latest agent output first · deadlines cycle the rest"
    case .triage: "Hard due dates and rough triage targets"
    case .manual: "Your saved task order"
    }
  }

  /// Walks open tasks' context folders off the main actor. Each walk is
  /// bounded, so polling every few seconds keeps new outputs prompt and cheap.
  private func refreshTaskOutputs() async {
    guard lastOutputScan == nil || Date().timeIntervalSince(lastOutputScan!) >= 4 else { return }
    lastOutputScan = Date()
    let folders = dashboard.tickets.filter(\.isOpen).compactMap { ticket in
      taskContexts[ticket.id].map { (ticket.id, $0.contextDirectory) }
    }
    let scanned = await Task.detached(priority: .utility) {
      Dictionary(folders.map { ($0.0, TaskOutputs.scan($0.1)) }, uniquingKeysWith: { first, _ in first })
    }.value
    if taskOutputs != scanned { taskOutputs = scanned }
  }

  func outputs(for ticketID: String) -> [TaskOutputFile] { taskOutputs[ticketID] ?? [] }

  /// Outputs to announce on the task card until the user opens or dismisses them.
  func newOutputs(for ticketID: String) -> [TaskOutputFile] {
    taskContexts[ticketID]?.newOutputs(taskOutputs[ticketID] ?? []) ?? []
  }

  /// Opens an output and stops announcing it; the file stays in the context folder.
  /// HTML mockups open in the native UI canvas instead of an external browser:
  /// an existing session reopens its tab, otherwise a session is created so the
  /// agent can be reconnected to it.
  func openOutput(_ output: TaskOutputFile, ticketID: String) {
    if ["html", "htm"].contains(output.url.pathExtension.lowercased()),
      openUICanvasForArtifact(output.url, ticketID: ticketID) != nil {
      // Routed to the canvas tab.
    } else {
      open(output.url.path, ticketID: ticketID)
    }
    Task { await markOutputsReviewed([output], ticketID: ticketID) }
  }

  /// The canvas session for an HTML artifact: the existing one, or a fresh
  /// session on first open. A session the human ended stays ended; its tab
  /// shows the finished state until the human reconnects the agent.
  @discardableResult
  private func openUICanvasForArtifact(_ artifact: URL, ticketID: String) -> String? {
    let ticketID = ticketID.uppercased()
    guard dashboard.tickets.contains(where: { $0.id == ticketID }) else { return nil }
    let session: UICanvasSession?
    if let existing = uiCanvasStore.find(file: artifact.path, taskID: ticketID) {
      session = existing
    } else if case .opened(let created) = try? uiCanvasStore.open(
      file: artifact.path, taskID: ticketID, title: nil, viewport: nil, reopen: false, agentName: nil) {
      session = created
    } else {
      session = nil
    }
    guard let session else { return nil }
    openUICanvasSession(ticketID: ticketID, key: session.key)
    return session.key
  }

  func markOutputsReviewed(_ outputs: [TaskOutputFile], ticketID: String) async {
    guard !outputs.isEmpty else { return }
    do {
      taskContexts[ticketID] = try await taskContextStore.markOutputsReviewed(ticketID: ticketID, outputs: outputs)
    } catch {
      actionMessages[ticketID] = "Could not update new outputs: \(error.localizedDescription)"
    }
  }

  func isTicketPinned(_ ticketID: String) -> Bool {
    taskContexts[ticketID]?.pinnedAt != nil
  }

  @discardableResult
  func setTicketPinned(_ ticket: DashboardTicket, pinned: Bool) async -> Bool {
    guard !pinned || ticket.isOpen else { return false }
    do {
      if try await taskContextStore.load(ticketID: ticket.id) == nil {
        _ = try await taskContextStore.ensureContext(
          ticket: ticket, project: project(for: ticket))
      }
      taskContexts[ticket.id] = try await taskContextStore.setPinned(
        ticketID: ticket.id, at: pinned ? Date() : nil)
      try? reloadApplicableQueueOverride()
      actionMessages[ticket.id] = pinned ? "Task pinned to the top of Focus." : "Task unpinned."
      return true
    } catch {
      actionMessages[ticket.id] = "Could not update pin: \(error.localizedDescription)"
      return false
    }
  }

  func setQueueActivitySortMode(_ mode: QueueActivitySortMode) {
    let normalized = mode == .manual ? QueueActivitySortMode.recentActivity : mode
    guard (localState.queueActivitySortMode ?? .recentActivity) != normalized else { return }
    localState.queueActivitySortMode = normalized
    try? queueOrderStore.reset()
    savedQueueOverride = nil
    persistLocalState()
  }

  func isNewTicket(_ ticketID: String) -> Bool {
    guard let viewedTicketIDs = localState.viewedTicketIDs,
          localState.viewedTicketSources?.isEmpty == false else { return false }
    return !viewedTicketIDs.contains(ticketID)
  }

  func markTicketViewed(_ ticketID: String) {
    guard localState.viewedTicketIDs?.contains(ticketID) != true else { return }
    // A view before any dashboard loads starts fresh tracking, not a migration.
    if localState.viewedTicketIDs == nil, localState.viewedTicketSources == nil {
      localState.viewedTicketSources = []
    }
    localState.viewedTicketIDs = (localState.viewedTicketIDs ?? []).union([ticketID])
    persistLocalState()
  }

  /// A dashboard's existing tasks count as viewed the first time it loads, so
  /// NEW marks only tasks created after Focus Queue began showing it.
  private func reconcileViewedTasks(sources loaded: [String: [String]]) {
    let previouslyViewed = localState.viewedTicketIDs ?? []
    // Earlier builds seeded only the scope open at the time. A dashboard with
    // a viewed task was seeded then; the others are seeded now.
    let migrating = localState.viewedTicketSources == nil && localState.viewedTicketIDs != nil
    var viewed = previouslyViewed
    var sources = localState.viewedTicketSources ?? []
    for (source, ticketIDs) in loaded where !sources.contains(source) {
      sources.insert(source)
      if migrating, ticketIDs.contains(where: previouslyViewed.contains) { continue }
      viewed.formUnion(ticketIDs)
    }
    guard viewed != localState.viewedTicketIDs || sources != localState.viewedTicketSources else { return }
    localState.viewedTicketIDs = viewed
    localState.viewedTicketSources = sources
    persistLocalState()
  }

  func latestAgentOutput(for ticketID: String) -> Date? {
    taskContexts[ticketID]?.subtasks.compactMap { $0.lastOutputAt ?? $0.resultAt }.max()
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
      let automaticIDs = automaticOpenTicketIDs
      let currentIDs = allOpenTickets.filter(\.isOpen).map(\.id)
      _ = try queueOrderStore.move(ticketID, to: placement,
        tickets: dashboard.tickets, fallbackIDs: automaticIDs,
        visibleIDs: selectedProjectID.map { _ in Set(projectTickets.map(\.id)) },
        currentIDs: currentIDs,
        automaticBaselineIDs: automaticIDs,
        sortMode: queueActivitySortMode)
      savedQueueOverride = try queueOrderStore.loadOverride()
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
      savedQueueOverride = nil
    } catch { loadError = error.localizedDescription }
  }

  /// Refreshes now, or once more right after the refresh in flight. An agent
  /// reply must not be lost because the periodic poll happened to be running.
  func refreshSoon() async {
    lastDashboardRead = nil
    guard !refreshInFlight else {
      followUpRefreshPending = true
      return
    }
    await refresh()
  }

  /// Reads only the saved order file. Agents and the CLI change the order on
  /// demand, so the queue follows that signal instead of waiting for the next
  /// full refresh, which also polls processes, contexts, and reports.
  func reloadQueueOrder() {
    do {
      try reloadApplicableQueueOverride()
    } catch {
      // The next full refresh reports a persistent read failure.
    }
  }

  private func reloadApplicableQueueOverride() throws {
    _ = try queueOrderStore.applicableOrder(
      automaticIDs: automaticOpenTicketIDs,
      sortMode: queueActivitySortMode)
    let updated = try queueOrderStore.loadOverride()
    if savedQueueOverride != updated { savedQueueOverride = updated }
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
    _ rawMessage: String, ticketID: String? = nil, tabID: String? = nil,
    canvasSelection: PlanCanvasSelection? = nil
  ) -> Bool {
    let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    let conversation = chatConversation(ticketID: ticketID, tabID: tabID)
    guard !message.isEmpty, !respondingConversations.contains(conversation) else { return false }
    guard !reportIsRunning else {
      dailyReportRunMessage = "Wait for the daily report to finish before editing the queue."
      return false
    }

    // Each turn runs in a fresh provider session; this bounded recap replaces
    // the resumed history that grew with every tool result (FOC-075).
    let recap = QueueChatContext.recap(
      messages(in: conversation).map { (role: $0.role.rawValue, text: $0.text) })
    nameQueueChatTabIfNeeded(conversation, from: message)
    appendChat(
      QueueChatMessage(role: .user, text: message, canvasSelection: canvasSelection),
      to: conversation)
    respondingConversations.insert(conversation)
    if ticketID == nil,
      let reportRequest = DailyReportChatCommand.parse(
        message,
        enabledPlatforms: config.dailyReport.enabledPlatforms
      )
    {
      runDailyReportFromChat(reportRequest, conversation: conversation)
      return true
    }
    let visibleOrder = openTickets.map(\.id)
    let scopedTaskIDs = ticketID.map { [$0] } ?? projectTickets.map(\.id)
    // A project without a repository binding stores an empty repositoryPath.
    // Skip it like nil or the chat harness launches with no working directory.
    let chatWorkspace = ticketID.flatMap { id in dashboard.tickets.first { $0.id == id }.map(defaultRepository) }
      ?? Self.firstConfiguredPath(selectedProject?.repositoryPath, selectedProject?.workspacePath)
      ?? config.workspacePath
    let deferredTicketIDs = localState.deferredTicketIDs.filter { scopedTaskIDs.contains($0) }
    let scopedMessage: String
    let provider = defaultAgentProvider
    let chatModel = effectiveChatModel(for: provider)
    let chatEffort = Self.normalizedChatOption(config.chatEffort(for: provider))
    var agentConfiguration = config.verifier
    agentConfiguration.executable = config.chatExecutable(for: provider)
    agentConfiguration.supportDirectory = paths.supportDirectory.path
    // The turn runs in this conversation's tmux session with no run budget, so
    // long requests finish and survive an app restart (FOC-120).
    agentConfiguration.chatTurn = chatTurnTarget(for: conversation)
    // Central QChat can inspect every configured project. Task chat retains its
    // task's project scope for task-specific helpers.
    agentConfiguration.projectScopeID = ticketID.map { id in
      dashboard.tickets.first { $0.id == id }?.projectID ?? selectedProjectID
    } ?? nil
    agentConfiguration.contextDirectory =
      paths.supportDirectory.appendingPathComponent("tasks").path
    // The orchestrator edits tasks, projects, and settings through
    // focus-queue-session, which writes config.json, state.json, queue order,
    // task contexts, and project dashboards. The chat sandbox must allow those
    // writes or every mutation the agent attempts is silently denied.
    agentConfiguration.writableDirectories = Array(Set(
      [paths.supportDirectory.path]
        + config.projects.map {
          URL(fileURLWithPath: $0.dashboardPath).deletingLastPathComponent().path
        }
        + [URL(fileURLWithPath: config.dashboardPath).deletingLastPathComponent().path]
    )).sorted()
    let contextualMessage =
      canvasSelection?.orchestratorMessage(userRequest: message) ?? message
    let snapshotIDs = Array(
      Set((ticketID.map { [$0] } ?? []) + QueueChatContext.taskIDs(
        in: message, known: Set(taskContexts.keys).union(dashboard.tickets.map(\.id))))
    ).sorted()
    let turnContext = QueueChatContext.snapshot(
      taskIDs: snapshotIDs, contexts: taskContexts, tickets: dashboard.tickets) + recap
    let request = (turnContext.isEmpty ? "" : "\n" + turnContext)
      + QueueAgentPrompt.userRequestMarker + contextualMessage
    if let ticketID, let context = taskContexts[ticketID] {
      agentConfiguration.sessionName = "ecc-focus-queue-task-\(ticketID.lowercased())"
      agentConfiguration.contextDirectory = context.contextDirectory.path
      let taskScope = "Task scope: \(ticketID). Read its central plan at \(context.planPath). "
      let contextScope = """
        Context folder: \(context.contextDirectory.path).
        Apply changes only when requested.

        """
      // Task chat is the task's orchestrator: it carries the signed orchestrator contract.
      scopedMessage = taskScope + "Project: \(context.projectName ?? context.projectID ?? "Unassigned"). " + contextScope
        + (orchestratorContractScope(projectID: context.projectID) ?? "") + request
    } else {
      let catalog = config.projects.map { project in
        "- \(project.name) (\(project.id)): dashboard \(project.dashboardPath); workspace \(project.workspacePath)"
      }.joined(separator: "\n")
      var scope = "Selected project: \(projectScopeName) (\(selectedProjectID ?? ProjectCatalog.otherID)). Selected task IDs: \(projectTickets.map(\.id).joined(separator: ", ")).\nConfigured projects, all readable without changing the UI selection:\n\(catalog)\n"
      // The orchestrator routes work to the current phase, so it needs the
      // same process state the launch briefs carry. The All-projects scope
      // spans projects with different phases, so no single one applies.
      if let process = developmentProcess, !showsAllProjects {
        let pending = process.pendingSteps.map(\.title).prefix(3).joined(separator: ", ")
        scope += "Development process for \(projectScopeName): \(process.currentPhase.title) phase"
          + (pending.isEmpty ? " (all steps accepted)." : "; next steps: \(pending).")
          + " \(DevelopmentProcessCatalog.brief(for: process.currentPhase))"
          + " Change links, steps, or the phase with `focus-queue-session development`, never by editing development.json.\n"
        scope += orchestratorContractScope(projectID: selectedProjectID) ?? ""
      }
      scopedMessage = scope + "Read the dashboard for the project named in the user's request. Preserve projectID and unknown fields on edits to the selected dashboard." + request
    }
    chatTasks[conversation] = Task { [weak self] in
      guard let self else { return }
      defer { self.finishChatTurn(conversation) }
      do {
        for id in scopedTaskIDs.filter({ self.taskContexts[$0] != nil }) {
          self.taskContexts[id] = try await self.taskContextStore.reconcileSubtasks(ticketID: id)
        }
        let reply = try await self.queueAgent(for: provider).send(
          message: scopedMessage,
          dashboardPath: self.config.dashboardPath,
          workspace: chatWorkspace,
          visibleOrder: visibleOrder,
          deferredTicketIDs: deferredTicketIDs,
          configuration: agentConfiguration,
          model: chatModel,
          effort: chatEffort
        )
        if provider == .codex, let refused = CodexCatalog.unavailableModel(in: reply.log) {
          self.unavailableCodexModels.insert(refused)
        }
        self.appendChat(QueueChatMessage(role: .agent, text: reply.message), to: conversation)
        await self.reloadAfterChatReply()
      } catch is CancellationError {
        // User-cancelled; the defer above already reset the chat state.
      } catch {
        self.appendChat(
          QueueChatMessage(role: .agent, text: error.localizedDescription), to: conversation)
      }
    }
    return true
  }

  /// The agent edits the queue, dashboards, and settings through the CLI.
  /// Show its saved result now so the reply and the queue agree.
  private func reloadAfterChatReply() async {
    _ = await reloadConfigurationFromDisk()
    reloadQueueOrder()
    await refreshSoon()
    await reloadPresentedPlan()
    if dailyReport == nil {
      await reloadDailyReport()
    }
  }

  private func finishChatTurn(_ conversation: QueueChatConversation) {
    respondingConversations.remove(conversation)
    chatTasks[conversation] = nil
  }

  /// Task chat for a ticket; otherwise the given QChat tab, or the active one.
  func chatConversation(ticketID: String?, tabID: String? = nil) -> QueueChatConversation {
    if let ticketID { return .task(ticketID) }
    return .tab(tabID ?? activeQueueChatTabID)
  }

  func isChatResponding(ticketID: String?, tabID: String? = nil) -> Bool {
    respondingConversations.contains(chatConversation(ticketID: ticketID, tabID: tabID))
  }

  private var queueChatRoot: URL { paths.supportDirectory.appendingPathComponent("qchat") }

  private func chatTurnTarget(for conversation: QueueChatConversation) -> QueueChatTurnTarget {
    QueueChatTurnTarget(
      conversation: conversation.key, sessionName: conversation.tmuxSessionName,
      rootDirectory: queueChatRoot.path,
      tmuxExecutable: config.tmuxExecutable ?? SetupEnvironment.executable("tmux"),
      serverName: QueueChatSessions.serverName(supportDirectory: paths.supportDirectory))
  }

  func queueAgent(for provider: AgentProvider) -> any QueueAgentChatting {
    if let existing = queueAgents[provider] { return existing }
    let agent = queueAgentFactory(provider)
    queueAgents[provider] = agent
    return agent
  }

  /// Empty or whitespace-only settings launch the harness without the flag.
  private static func normalizedChatOption(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Stops the conversation's running turn and closes its tmux window.
  func cancelQueueAgentMessage(ticketID: String? = nil, tabID: String? = nil) {
    chatTasks[chatConversation(ticketID: ticketID, tabID: tabID)]?.cancel()
  }

  /// Clears the visible transcript, the saved conversation that feeds the next
  /// turn's recap, the conversation's tmux session, and every provider's
  /// harness session and saved transcript, so the next message starts with no
  /// prior history.
  func clearQueueChat(ticketID: String?, tabID: String? = nil) {
    let conversation = chatConversation(ticketID: ticketID, tabID: tabID)
    chatTasks[conversation]?.cancel()
    setMessages([], in: conversation)
    let closeSession = closeChatSession(conversation)
    let provider = defaultAgentProvider
    let resets = AgentProvider.allCases.map { candidate in
      var resetConfiguration = config.verifier
      resetConfiguration.executable = config.chatExecutable(for: candidate)
      resetConfiguration.supportDirectory = paths.supportDirectory.path
      resetConfiguration.contextDirectory =
        paths.supportDirectory.appendingPathComponent("tasks").path
      if let ticketID {
        resetConfiguration.sessionName = "ecc-focus-queue-task-\(ticketID.lowercased())"
        if let context = taskContexts[ticketID] {
          resetConfiguration.contextDirectory = context.contextDirectory.path
        }
      }
      return (candidate, queueAgent(for: candidate), resetConfiguration)
    }
    let scope = durableScope(conversation)
    Task { [weak self] in
      guard let self else { return }
      await closeSession()
      do {
        try await self.saveMessages([], in: conversation)
        self.recordDurableError(nil, scope: scope)
      } catch {
        self.recordDurableError(error, scope: scope)
      }
      for (candidate, agent, resetConfiguration) in resets {
        do {
          try await agent.reset(configuration: resetConfiguration)
        } catch where candidate == provider {
          self.loadError =
            "Could not reset the \(provider.displayName) chat session: \(error.localizedDescription)"
        } catch {
          // An inactive provider may not be installed; its stale session is harmless.
        }
      }
    }
  }

  /// Closes the conversation's tmux session, like completing a task closes its
  /// task session, and drops any turn files it left behind.
  private func closeChatSession(_ conversation: QueueChatConversation) -> @Sendable () async -> Void {
    let target = chatTurnTarget(for: conversation)
    let root = queueChatRoot
    return {
      await QueueChatSessions(serverName: target.serverName)
        .close(sessionName: target.sessionName, executable: target.tmuxExecutable)
      for turn in QueueChatSessions.pendingTurns(root: root) where turn.conversation == target.conversation {
        QueueChatSessions.discard(turn)
      }
    }
  }

  // MARK: QChat tabs

  func selectQueueChatTab(_ id: String) {
    guard queueChatTabs.contains(where: { $0.id == id }), activeQueueChatTabID != id else { return }
    activeQueueChatTabID = id
    UserDefaults.standard.set(id, forKey: Self.activeQueueChatTabKey)
    queueChatFocusRequest += 1
  }

  /// Opens a new, empty QChat tab with its own session and selects it.
  @discardableResult
  func addQueueChatTab() -> String {
    var id = String(UUID().uuidString.lowercased().prefix(8))
    while queueChatTabs.contains(where: { $0.id == id }) {
      id = String(UUID().uuidString.lowercased().prefix(8))
    }
    queueChatTabs.append(QueueChatTab(
      id: id, title: QueueChatTab.nextDefaultTitle(existing: queueChatTabs), titleIsAutomatic: true))
    queueChatTabMessages[id] = []
    saveQueueChatTabs()
    selectQueueChatTab(id)
    return id
  }

  /// Closes a tab: stops its turn, closes its tmux session, and deletes its
  /// transcript. The last tab is cleared instead, so QChat always has one.
  func closeQueueChatTab(_ id: String) {
    guard let index = queueChatTabs.firstIndex(where: { $0.id == id }) else { return }
    guard queueChatTabs.count > 1 else {
      clearQueueChat(ticketID: nil, tabID: id)
      return
    }
    let conversation = QueueChatConversation.tab(id)
    chatTasks[conversation]?.cancel()
    let closeSession = closeChatSession(conversation)
    queueChatTabs.remove(at: index)
    queueChatTabMessages[id] = nil
    if activeQueueChatTabID == id {
      let neighbor = queueChatTabs[min(index, queueChatTabs.count - 1)].id
      activeQueueChatTabID = neighbor
      UserDefaults.standard.set(neighbor, forKey: Self.activeQueueChatTabKey)
    }
    saveQueueChatTabs()
    // Turns are fresh provider runs, so no harness session needs a reset; the
    // tab's tmux session and transcript are all it owns.
    Task { [weak self, conversationStore] in
      await closeSession()
      do { try await conversationStore.removeTab(id) } catch {
        self?.loadError = "Could not delete the closed chat: \(error.localizedDescription)"
      }
    }
  }

  /// Opens a terminal attached to the conversation's tmux session, where its
  /// activity log and any running turn are visible.
  func openQueueChatSession(ticketID: String? = nil, tabID: String? = nil) {
    let target = chatTurnTarget(for: chatConversation(ticketID: ticketID, tabID: tabID))
    let configuration = config.wezTerm
    let title = ticketID.map { "\($0) chat" }
      ?? queueChatTabs.first { $0.id == (tabID ?? activeQueueChatTabID) }.map { "QChat · \($0.title)" }
      ?? "QChat"
    let support = paths.supportDirectory
    Task { [weak self] in
      do {
        let command = try await QueueChatSessions(serverName: target.serverName).attachCommand(target: target)
        try await TerminalCommandLauncher.open(
          command, configuration: configuration,
          titles: .init(tab: title, window: title), supportDirectory: support)
      } catch {
        self?.loadError = "Could not open the chat session: \(error.localizedDescription)"
      }
    }
  }

  static let activeQueueChatTabKey = "qchatActiveTab"

  private func nameQueueChatTabIfNeeded(_ conversation: QueueChatConversation, from message: String) {
    guard case .tab(let id) = conversation,
      let index = queueChatTabs.firstIndex(where: { $0.id == id }),
      queueChatTabs[index].titleIsAutomatic,
      !(queueChatTabMessages[id] ?? []).contains(where: { $0.role == .user }),
      let title = QueueChatTab.title(from: message)
    else { return }
    queueChatTabs[index].title = title
    queueChatTabs[index].titleIsAutomatic = false
    saveQueueChatTabs()
  }

  private func saveQueueChatTabs() {
    let tabs = queueChatTabs
    Task { [weak self, conversationStore] in
      do { try await conversationStore.saveTabs(tabs) } catch {
        self?.loadError = "Could not save chat tabs: \(error.localizedDescription)"
      }
    }
  }

  /// Restores the tabs and transcripts, then collects any turn that kept
  /// running in tmux while the app was closed.
  private func loadQueueChatTabs() async throws {
    let tabs = (try? await conversationStore.loadTabs()).flatMap { $0.isEmpty ? nil : $0 } ?? [.main]
    var messages: [String: [QueueChatMessage]] = [:]
    for tab in tabs {
      let saved = try await conversationStore.load(tabID: tab.id)
      if let saved, !saved.isEmpty {
        messages[tab.id] = saved
      } else {
        messages[tab.id] = tab.id == QueueChatTab.mainID ? [Self.queueChatGreeting] : []
      }
    }
    queueChatTabs = tabs
    queueChatTabMessages = messages
    let savedActive = UserDefaults.standard.string(forKey: Self.activeQueueChatTabKey)
    activeQueueChatTabID = tabs.first { $0.id == savedActive }?.id ?? tabs[0].id
    recoverQueueChatTurns()
  }

  private func recoverQueueChatTurns() {
    for turn in QueueChatSessions.pendingTurns(root: queueChatRoot) {
      guard let conversation = QueueChatConversation(key: turn.conversation),
        !respondingConversations.contains(conversation),
        conversationExists(conversation)
      else {
        QueueChatSessions.discard(turn)
        continue
      }
      respondingConversations.insert(conversation)
      chatTasks[conversation] = Task { [weak self] in
        guard let self else { return }
        defer { self.finishChatTurn(conversation) }
        do {
          let reply = try await self.queueAgent(for: turn.provider).resume(turn)
          self.appendChat(QueueChatMessage(role: .agent, text: reply.message), to: conversation)
          await self.reloadAfterChatReply()
        } catch is CancellationError {
        } catch {
          self.appendChat(
            QueueChatMessage(role: .agent, text: error.localizedDescription), to: conversation)
        }
      }
    }
  }

  private func conversationExists(_ conversation: QueueChatConversation) -> Bool {
    switch conversation {
    case .tab(let id): queueChatTabs.contains { $0.id == id }
    case .task: true
    }
  }

  var isInspectorPresented: Bool {
    isQueueChatInspectorPresented || isDailyReportPresented || presentedPlanTicketID != nil
      || presentedAgentUpdate != nil || isDocumentViewerPresented
      || isTokenAnalyticsPresented
  }

  func setTokenAnalyticsPresented(_ presented: Bool) {
    guard presented != isTokenAnalyticsPresented else { return }
    if presented {
      isQueueChatInspectorPresented = false
      presentedAgentUpdate = nil
      presentedPlanTicketID = nil
      presentedPlanURL = nil
      isDailyReportPresented = false
      isDocumentViewerPresented = false
    }
    isTokenAnalyticsPresented = presented
    reportVisibilityHandler?(isInspectorPresented)
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

  /// What the queue header's daily report button shows: a spinner while a
  /// report runs, then a badge until the finished report or failure is seen.
  var dailyReportHeaderIndicator: DailyReportHeaderIndicator {
    if reportIsRunning { return .running }
    if reportHasFailure {
      return localState.dismissedNotificationIDs.contains(reportNotificationID) ? .none : .needsAttention
    }
    guard let report = reportAttentionDocument, reportHistory.isUnread(report) else { return .none }
    return report.status == .success ? .ready : .needsAttention
  }

  /// The header button opens the newest report while it carries a badge, so
  /// opening it is what marks that report (or failed run) as seen.
  func openDailyReportFromHeader() {
    guard !isDailyReportPresented else {
      setDailyReportPresented(false)
      return
    }
    switch dailyReportHeaderIndicator {
    case .ready, .needsAttention:
      if reportHasFailure { dismissReportNotification() }
      showLatestDailyReport()
    case .none, .running:
      setDailyReportPresented(true)
    }
  }

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

  func reloadReportHistory(capturingHistory: Bool = true) async {
    do {
      let updatedHistory = try await reportHistoryRepository.load()
      if reportHistory != updatedHistory { reportHistory = updatedHistory }
      if reportHistoryError != nil { reportHistoryError = nil }
      guard capturingHistory else { return }
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
    documentConversation(for: url, scope: .task(ticketID))
  }

  func documentConversation(for url: URL, scope: DocumentScope) -> DocumentConversation? {
    guard let document = DocumentPaneLocation.normalized(url) else { return nil }
    let subject: DocumentConversationSubject
    var dashboardPath = config.dashboardPath
    switch scope {
    case .task(let ticketID):
      guard let context = taskContexts[ticketID] else { return nil }
      subject = DocumentConversationSubject(kind: .task(context))
    case .project(let projectID):
      guard let project = config.projects.first(where: { $0.id == projectID }),
            let plan = try? projectContextStore.ensurePlan(for: project) else { return nil }
      subject = DocumentConversationSubject(
        kind: .project(project, planPath: plan.path, directory: plan.deletingLastPathComponent()))
      if !project.dashboardPath.isEmpty { dashboardPath = project.dashboardPath }
    }
    let key = DocumentConversation.key(document: document, taskID: subject.scopeID)
    if let existing = documentConversations[key] { return existing }
    let provider = defaultAgentProvider
    let ticketID: String? = if case .task(let id) = scope { id } else { nil }
    let services = DocumentChatServices(
      agent: { [weak self] provider in self?.queueAgent(for: provider) ?? HarnessQueueAgent(provider: provider) },
      executable: { [weak self, fallback = config] provider in
        (self?.config ?? fallback).chatExecutable(for: provider)
      },
      resolveCreator: { [weak self] known in
        guard let self, let ticketID, document.isFileURL else { return nil }
        return await self.documentCreator(path: document.path, ticketID: ticketID, known: known)
      },
      modelChoices: { [weak self] provider in self?.agentModelChoices(for: provider) ?? [] })
    let conversation = DocumentConversation(document: document, subject: subject, support: paths.supportDirectory,
      services: services, configuration: config.verifier, dashboardPath: dashboardPath,
      workspace: config.workspacePath, provider: provider)
    documentConversations[key] = conversation
    return conversation
  }

  /// The task agent whose transcript wrote `path`, and whether its provider
  /// process still runs. Transcripts are read once; later calls pass `known`.
  private func documentCreator(path: String, ticketID: String, known: DocumentAuthor?) async -> DocumentChatCreator? {
    guard let context = taskContexts[ticketID] else { return nil }
    let author: DocumentAuthor
    if let known {
      author = known
    } else {
      var candidates: [(agent: TaskSubtask, transcript: URL)] = []
      for agent in context.subtasks where agent.sessionID != nil && !agent.isAssignmentOnly {
        if let transcript = await agentActivityObserver.transcriptURL(for: agent, refresh: true) {
          candidates.append((agent, transcript))
        }
      }
      let scanned = candidates
      let createdAt = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
      guard let found = await Task.detached(priority: .utility, operation: {
        DocumentAuthorship.author(of: path, agents: scanned, createdAt: createdAt)
      }).value else { return nil }
      author = found
    }
    guard let agent = context.subtasks.first(where: { $0.id == author.subtaskID }),
          agent.provider == author.provider,
          agent.sessionID?.caseInsensitiveCompare(author.sessionID) == .orderedSame else { return nil }
    // Kimi records may keep the bare UUID of a `session_<uuid>` session; a
    // Codex sub-agent thread forks through its lineage root, as it resumes.
    let forkSessionID = switch author.provider {
    case .kimi where UUID(uuidString: author.sessionID) != nil: "session_" + author.sessionID
    case .codex: CodexSessionLineage.root(of: author.sessionID)
    default: author.sessionID
    }
    // Completion and archive flags describe the task record, not whether its
    // exact provider conversation is still running or can be forked from disk.
    let running = try? await locateExistingAgent(author.provider, forkSessionID)
    let transcript = await agentActivityObserver.transcriptURL(for: agent, refresh: true)
    guard running != nil || transcript != nil else { return nil }
    let savedWorkspace = [agent.workspace?.path, context.worktreePath, context.repositoryPath,
      context.projectRepositoryPath, config.workspacePath]
      .compactMap { $0 }
      .first { FileManager.default.fileExists(atPath: $0) }
    return DocumentChatCreator(author: author, forkSessionID: forkSessionID,
      liveWorkspace: running?.cwd, savedWorkspace: savedWorkspace,
      model: Self.normalizedChatOption(agent.launchConfiguration?.model),
      effort: Self.normalizedChatOption(agent.launchConfiguration?.effort))
  }

  func chatMessages(ticketID: String?, tabID: String? = nil) -> [QueueChatMessage] {
    messages(in: chatConversation(ticketID: ticketID, tabID: tabID))
  }

  func messages(in conversation: QueueChatConversation) -> [QueueChatMessage] {
    switch conversation {
    case .task(let id): taskChatMessages[id] ?? []
    case .tab(let id): queueChatTabMessages[id] ?? []
    }
  }

  private func setMessages(_ messages: [QueueChatMessage], in conversation: QueueChatConversation) {
    switch conversation {
    case .task(let id): taskChatMessages[id] = messages
    case .tab(let id): queueChatTabMessages[id] = messages
    }
  }

  private func saveMessages(_ messages: [QueueChatMessage], in conversation: QueueChatConversation) async throws {
    switch conversation {
    case .task(let id): try await conversationStore.save(messages, ticketID: id)
    case .tab(let id): try await conversationStore.save(messages, tabID: id)
    }
  }

  /// Durable-error scope; the main tab keeps the original queue scope.
  private func durableScope(_ conversation: QueueChatConversation) -> String {
    switch conversation {
    case .task(let id): "conversation-\(id)"
    case .tab(let id): id == QueueChatTab.mainID ? "conversation-queue" : "conversation-tab-\(id)"
    }
  }

  /// Appends to the conversation that sent the turn, even after the user
  /// switched tabs. A reply for a closed tab is dropped with the tab.
  private func appendChat(_ message: QueueChatMessage, to conversation: QueueChatConversation) {
    guard conversationExists(conversation) else { return }
    var updated = messages(in: conversation)
    updated.append(message)
    setMessages(updated, in: conversation)
    let scope = durableScope(conversation)
    Task {
      do {
        try await saveMessages(updated, in: conversation)
        recordDurableError(nil, scope: scope)
      } catch let error as ConversationArchiveError {
        recordDurableError(error, scope: scope)
      } catch { loadError = "Could not save conversation: \(error.localizedDescription)" }
    }
  }

  private func refreshTaskContexts() async {
    guard lastContextRefresh == nil || Date().timeIntervalSince(lastContextRefresh!) >= 2 else { return }
    lastContextRefresh = Date()
    reloadDevelopmentProcess()
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
        Task { await finalizeCompletedTask(ticket) }
      }
    }
    if panelVisible, lastIdentityRefresh == nil || Date().timeIntervalSince(lastIdentityRefresh!) >= 15 {
      lastIdentityRefresh = Date()
      let observed = tickets.flatMap { ticket in
        visibleAgents(for: ticket.id).map { (ticketID: ticket.id, subtask: $0) }
      }
      // A finished agent keeps running and can be prompted again; only its
      // transcript shows that it went back to work. Older builds archived it
      // with its terminal kept open.
      let retained = tickets.filter(\.isOpen).flatMap { ticket in
        subtasks(for: ticket.id).filter {
          $0.status == .completed && $0.sessionID != nil && !$0.isAgentVisible
            && ($0.agentRemovedAt == nil || $0.completionTerminalRetained == true)
        }.map { (ticketID: ticket.id, subtask: $0) }
      }
      for entry in observed + retained {
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
      liveRuntimeSubtaskIDs = TaskAgentLauncher.liveRuntimeSubtaskIDs(
        subtasks: observed.map(\.subtask), configuration: config.wezTerm, snapshot: terminalSnapshot)
      spinningRuntimeSubtaskIDs = TaskAgentLauncher.spinningRuntimeSubtaskIDs(
        subtasks: observed.map(\.subtask), snapshot: terminalSnapshot)
      let attentions = await taskAgentLauncher.runtimeAttention(
        subtasks: observed.map(\.subtask), configuration: config.wezTerm, snapshot: terminalSnapshot)
      for entry in observed {
        guard let attention = attentions[entry.subtask.id],
             let latest = subtasks(for: entry.ticketID).first(where: { $0.id == entry.subtask.id }),
             latest.attention != attention else { continue }
        if attention == nil, latest.attention == .approval {
          // The probe recognizes approval dialogs, so one that is gone was answered.
          do {
            taskContexts[entry.ticketID] = try await taskContextStore.resolveApproval(
              ticketID: entry.ticketID, subtaskID: entry.subtask.id)
          } catch { actionMessages[entry.ticketID] = error.localizedDescription }
          continue
        }
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
      context.subtasks.contains { displayStatus($0, now: lastActivityCheck) != displayStatus($0, now: now) }
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

  /// Loads the selected project's development process off disk. A missing or
  /// disabled file publishes nil; a malformed one keeps the last good state.
  func reloadDevelopmentProcess() {
    reloadPhaseProcesses()
    guard let projectID = selectedProject?.id else {
      if developmentProcess != nil { developmentProcess = nil }
      return
    }
    do {
      let loaded = try developmentProcessStore.load(projectID: projectID)
      let visible = loaded?.enabled == true ? loaded : nil
      if developmentProcess != visible { developmentProcess = visible }
    } catch {
      developmentProcessError = "Development process: \(error.localizedDescription)"
    }
    reloadDevelopmentContracts()
  }

  /// Phase markers in the all-projects view read each project's process.
  /// Single-project scope uses `developmentProcess` alone, so it skips the reads.
  private func reloadPhaseProcesses() {
    var loaded: [String: DevelopmentProcess] = [:]
    if showsAllProjects {
      for project in config.projects where project.archivedAt == nil {
        if let process = try? developmentProcessStore.load(projectID: project.id), process.enabled {
          loaded[project.id] = process
        }
      }
    }
    if phaseProcessesByProjectID != loaded { phaseProcessesByProjectID = loaded }
  }

  /// One development-process mutation: run the store edit, publish the result,
  /// and surface any error in the Project tab instead of failing silently.
  private func mutateDevelopmentProcess(
    _ mutation: (DevelopmentProcessStore, String) throws -> DevelopmentProcess
  ) {
    guard let projectID = selectedProject?.id else { return }
    do {
      let updated = try mutation(developmentProcessStore, projectID)
      // A disabled process stays on disk but leaves the tab and briefs.
      developmentProcess = updated.enabled ? updated : nil
      developmentProcessError = nil
    } catch {
      developmentProcessError = error.localizedDescription
    }
    reloadDevelopmentContracts()
  }

  func setDevelopmentProcessEnabled(_ enabled: Bool) {
    mutateDevelopmentProcess { try $0.setEnabled(enabled, projectID: $1) }
    if enabled { lastDevelopmentStewardCheck = nil; runDevelopmentStewardIfDue() }
  }

  func setDevelopmentPhase(_ phase: DevelopmentPhase) {
    mutateDevelopmentProcess { try $0.setPhase(phase, projectID: $1) }
  }

  func setDevelopmentStepStatus(_ status: DevelopmentStepStatus, stepID: String) {
    mutateDevelopmentProcess { try $0.setStepStatus(status, stepID: stepID, projectID: $1) }
  }

  func addDevelopmentModule(name: String, file: String?) {
    mutateDevelopmentProcess { try $0.addModule(name: name, file: file, projectID: $1) }
  }

  /// Sequential by design: the store rejects module N+1 before module N.
  func acceptDevelopmentModuleCriteria(moduleID: String) {
    mutateDevelopmentProcess { try $0.acceptCriteria(moduleID: moduleID, projectID: $1) }
  }

  func setDevelopmentModuleImplemented(_ implemented: Bool, moduleID: String) {
    mutateDevelopmentProcess {
      try $0.setModuleImplemented(implemented, moduleID: moduleID, projectID: $1)
    }
  }

  func setDevelopmentModuleQAAccepted(_ accepted: Bool, moduleID: String) {
    mutateDevelopmentProcess {
      try $0.setModuleQAAccepted(accepted, moduleID: moduleID, projectID: $1)
    }
  }

  func dismissDevelopmentProcessError() { developmentProcessError = nil }

  /// The development-process artifact a viewer document belongs to, so the
  /// document pane can offer its review toggle. Only project-scoped documents
  /// inside the project folder of an enabled process qualify.
  func developmentArtifactReview(for document: URL) -> DevelopmentArtifactReview? {
    // Contracts are checked off by signing them; see `developmentContractControl`.
    guard AgentContractRole(fileName: document.lastPathComponent) == nil,
          case .project(let projectID) = documentViewerScope,
          let process = try? developmentProcessStore.load(projectID: projectID), process.enabled,
          // A project may keep a catalog document under its own name (`artifactNames`).
          let artifact = process.catalogArtifact(forFile: document.lastPathComponent),
          let step = DevelopmentProcessCatalog.step(
            forArtifact: artifact, includingGuidelineArtifacts: process.usesPlanningGuidelines),
          let artifactURL = try? developmentProcessStore.artifactURL(
            projectID: projectID, artifact: artifact, process: process),
          artifactURL.standardizedFileURL == document.standardizedFileURL
    else { return nil }
    return DevelopmentArtifactReview(projectID: projectID, stepID: step.id, stepTitle: step.title,
      artifact: artifact,
      checked: process.steps[step.id]?.checkedArtifacts.contains(artifact) ?? false)
  }

  /// The document check-off in the viewer; auto-completes the step once every
  /// artifact exists and is reviewed. Publishes the selected project's process.
  func setDevelopmentArtifactChecked(_ checked: Bool, review: DevelopmentArtifactReview) {
    do {
      let updated = try developmentProcessStore.setArtifactChecked(
        checked, stepID: review.stepID, artifact: review.artifact, projectID: review.projectID)
      if review.projectID == selectedProject?.id { developmentProcess = updated.enabled ? updated : nil }
      developmentProcessError = nil
    } catch {
      developmentProcessError = error.localizedDescription
    }
  }

  /// Where a step artifact of the selected project lives, beside its plan.
  func developmentArtifactURL(_ artifact: String) -> URL? {
    guard let projectID = selectedProject?.id else { return nil }
    return try? developmentProcessStore.artifactURL(projectID: projectID, artifact: artifact,
                                                    process: developmentProcess)
  }

  // MARK: - Planning guidelines (experimental)

  /// Opens a bundled planning guideline, installed read-only under the support folder.
  func openDevelopmentGuideline(_ name: String) {
    guard let projectID = selectedProject?.id else { return }
    do {
      openDocumentViewer(try DevelopmentGuidelines.url(name, root: paths.supportDirectory), scope: .project(projectID))
    } catch {
      developmentProcessError = "Planning guideline: \(error.localizedDescription)"
    }
  }

  /// Bundled guidelines are read-only: owner overrides and sign-off are not built yet.
  func isBundledGuideline(_ url: URL) -> Bool {
    DevelopmentGuidelines.isInstalledGuideline(url, root: paths.supportDirectory)
  }

  func planningGuidelinesEnabled(for projectID: String) -> Bool {
    (try? developmentProcessStore.load(projectID: projectID))??.usesPlanningGuidelines ?? false
  }

  func setPlanningGuidelinesEnabled(_ enabled: Bool, for projectID: String) {
    do {
      let updated = try developmentProcessStore.setPlanningGuidelines(enabled, projectID: projectID)
      if projectID == selectedProject?.id { developmentProcess = updated.enabled ? updated : nil }
      developmentProcessError = nil
    } catch {
      developmentProcessError = error.localizedDescription
    }
  }

  // MARK: - Agent contracts

  /// Refreshes the selected project's contract states from disk: sign-off, pending
  /// edits, drafts, and lint. Runs with every process reload and contract action.
  func reloadDevelopmentContracts() {
    guard let projectID = selectedProject?.id, let process = developmentProcess else {
      if !developmentContracts.isEmpty { developmentContracts = [] }
      return
    }
    let statuses = AgentContractRole.allCases.compactMap {
      try? developmentProcessStore.contractStatus(role: $0, projectID: projectID, process: process)
    }
    if statuses != developmentContracts { developmentContracts = statuses }
  }

  /// Opens a contract for review: the live file, beside its draft when one waits.
  func openAgentContract(_ status: AgentContractStatus) {
    guard let projectID = selectedProject?.id else { return }
    let live = FileManager.default.fileExists(atPath: status.fileURL.path)
    if live { openDocumentViewer(status.fileURL, scope: .project(projectID)) }
    if status.hasDraft {
      if live { documentViewer.open(status.draftURL, in: .secondary) }
      else { openDocumentViewer(status.draftURL, scope: .project(projectID)) }
    }
  }

  /// Drafts both contracts with the bundled prompt as one read-only turn on the
  /// QChat provider, then opens the drafts with the lint and review notes beside them.
  func generateAgentContracts() {
    guard let project = selectedProject, developmentProcess != nil, contractGenerationProjectID == nil else { return }
    let provider = defaultAgentProvider
    let model = effectiveChatModel(for: provider)
    let effort = Self.normalizedChatOption(config.chatEffort(for: provider))
    let generator = AgentContractGenerator(root: paths.supportDirectory, agent: queueAgentFactory(provider))
    let configuration = config
    contractGenerationProjectID = project.id
    developmentProcessError = nil
    Task { [weak self] in
      do {
        let result = try await generator.generate(
          project: project, configuration: configuration, provider: provider, model: model, effort: effort)
        guard let self else { return }
        self.contractGenerationProjectID = nil
        self.reloadDevelopmentContracts()
        guard self.selectedProject?.id == project.id, let first = result.files.first else { return }
        self.openDocumentViewer(first, scope: .project(project.id))
        for file in result.files.dropFirst() { self.documentViewer.open(file, in: .primary) }
        self.documentViewer.select(first)
        self.documentViewer.open(result.reviewURL, in: .secondary)
      } catch {
        self?.contractGenerationProjectID = nil
        self?.developmentProcessError = "Contract generator: \(error.localizedDescription)"
      }
    }
  }

  /// The sign-off control for a contract or its draft open in the viewer, in any
  /// scope: the file's folder names the project. Nil for every other document.
  func developmentContractControl(for document: URL) -> DevelopmentContractControl? {
    guard let role = AgentContractRole(fileName: document.lastPathComponent) else { return nil }
    let directory = document.deletingLastPathComponent().standardizedFileURL
    guard let project = config.projects.first(where: {
            (try? developmentProcessStore.contractDirectory(projectID: $0.id))?.standardizedFileURL == directory
          }),
          let process = try? developmentProcessStore.load(projectID: project.id), process.enabled
    else { return nil }
    let isDraft = document.lastPathComponent == role.draftFileName
    let status = AgentContract.status(role: role, directory: directory, signoff: process.contracts[role.rawValue])
    let text = documentContentStore.loadedText(for: document)
      ?? (try? String(contentsOf: document, encoding: .utf8)) ?? ""
    return DevelopmentContractControl(
      projectID: project.id, role: role, isDraft: isDraft, state: status.state,
      lint: AgentContract.lint(text, role: role, directory: directory))
  }

  /// Signs off exactly the text the viewer shows; a draft replaces the live file.
  func signAgentContract(_ control: DevelopmentContractControl, document: URL) {
    guard let text = documentContentStore.loadedText(for: document) else {
      developmentProcessError = "Wait for \(document.lastPathComponent) to load, then sign it off."
      return
    }
    signAgentContract(control, document: document, text: text)
  }

  private func signAgentContract(_ control: DevelopmentContractControl, document: URL, text: String) {
    do {
      let updated = control.isDraft
        ? try developmentProcessStore.promoteContractDraft(role: control.role, text: text, projectID: control.projectID)
        : try developmentProcessStore.signContract(role: control.role, text: text, projectID: control.projectID)
      if control.projectID == selectedProject?.id { developmentProcess = updated.enabled ? updated : nil }
      developmentProcessError = nil
      if control.isDraft, let live = try? developmentProcessStore.contractDirectory(projectID: control.projectID)
        .appendingPathComponent(control.role.fileName) {
        // The draft is gone; show the live contract it became.
        documentViewer.close(document)
        if isDocumentViewerPresented { documentViewer.open(live, in: .primary) }
        documentContentStore.reload(live)
      }
    } catch {
      developmentProcessError = error.localizedDescription
    }
    reloadDevelopmentContracts()
  }

  /// A save in the viewer is the owner's edit, so it signs off the saved text.
  private func agentContractSaved(_ url: URL, text: String) {
    guard let control = developmentContractControl(for: url) else { return }
    signAgentContract(control, document: url, text: text)
  }

  func revokeAgentContract(_ role: AgentContractRole) {
    mutateDevelopmentProcess { try $0.revokeContract(role: role, projectID: $1) }
  }

  func discardAgentContractDraft(_ status: AgentContractStatus) {
    guard let projectID = selectedProject?.id else { return }
    do { try developmentProcessStore.discardContractDraft(role: status.role, projectID: projectID) }
    catch { developmentProcessError = error.localizedDescription }
    if documentViewer.tabs.contains(status.draftURL) { documentViewer.close(status.draftURL) }
    reloadDevelopmentContracts()
  }

  /// The project's signed orchestrator contract for a chat turn, or nil.
  func orchestratorContractScope(projectID: String?) -> String? {
    guard let projectID, let process = try? developmentProcessStore.load(projectID: projectID), process.enabled,
          let directory = try? developmentProcessStore.contractDirectory(projectID: projectID),
          let injection = AgentContract.injection(role: .orchestrator, directory: directory, process: process)
    else { return nil }
    return injection.lines.joined(separator: "\n") + "\n"
  }

  /// Keeps every enabled project's process current without any agent's help.
  /// Each check (at most every 30 s, or on demand) reconciles step and module
  /// status from task status with no model call, then starts at most one
  /// background placement-model pass for a project whose new tasks or files
  /// changed its steward signature. `force` runs that pass for one project now.
  func runDevelopmentStewardIfDue(force projectID: String? = nil, now: Date = Date()) {
    guard projectID != nil || lastDevelopmentStewardCheck == nil
      || now.timeIntervalSince(lastDevelopmentStewardCheck!) >= 30 else { return }
    lastDevelopmentStewardCheck = now
    let store = developmentProcessStore
    for project in config.projects where project.archivedAt == nil {
      guard projectID == nil || projectID == project.id,
            let loaded = try? store.load(projectID: project.id), loaded.enabled else { continue }
      let tickets = developmentTickets(for: project)
      var process = loaded
      if process.reconcile(tickets: tickets, now: now) {
        process = (try? store.mutate(projectID: project.id) { $0.reconcile(tickets: tickets, now: now) })
          ?? process
      }
      guard developmentStewardProjectID == nil, config.placementModelEnabled != false,
            let directory = try? store.url(projectID: project.id).deletingLastPathComponent()
      else { continue }
      let files = DevelopmentSteward.projectFiles(directory: directory)
      let signature = DevelopmentSteward.signature(process: process, tickets: tickets, files: files)
      guard projectID == project.id || DevelopmentSteward.isDue(process: process, signature: signature, now: now)
      else { continue }
      let candidates = DevelopmentSteward.candidates(process: process, tickets: tickets)
      if candidates.isEmpty && files.isEmpty && projectID == nil {
        // Nothing a model could link or cite; remember the state without a call.
        _ = try? store.mutate(projectID: project.id) {
          $0.steward = DevelopmentStewardRun(signature: signature, ranAt: now,
            model: $0.steward?.model, summary: "No tasks or files to review.")
        }
        continue
      }
      startDevelopmentSteward(project: project, tickets: tickets)
    }
    reloadDevelopmentProcess()
  }

  /// Runs the Project tab's Sync button: the selected project's pass, now.
  func syncDevelopmentProcess() {
    guard let projectID = selectedProject?.id else { return }
    guard config.placementModelEnabled != false else {
      developmentProcessError = "Sync uses the placement model, which is off in Settings. Task status still updates linked steps."
      return
    }
    runDevelopmentStewardIfDue(force: projectID)
  }

  private func startDevelopmentSteward(project: ProjectConfiguration, tickets: [DevelopmentTicket]) {
    let provider = config.placementProvider ?? config.defaultAgentProvider
      ?? config.agentProviderFallbackOrder.first ?? .claude
    let installed = paths.supportDirectory.appendingPathComponent("shell/focus_queue_placement.py")
    let script = [ScriptTaskPlacementSuggester.bundledScript(), installed].compactMap { $0 }
      .first { FileManager.default.isReadableFile(atPath: $0.path) } ?? installed
    let runner = developmentStewardRunner ?? DevelopmentStewardRunner(
      script: script,
      environment: ScriptTaskPlacementSuggester.environment(
        supportDirectory: paths.supportDirectory, home: FileManager.default.homeDirectoryForCurrentUser))
    let store = developmentProcessStore
    developmentStewardProjectID = project.id
    Task { [weak self] in
      do {
        try await DevelopmentSteward.runPass(projectID: project.id, projectName: project.name, store: store,
                                             tickets: tickets, provider: provider, runner: runner)
      } catch {
        self?.developmentProcessError = "Development steward: \(error.localizedDescription)"
      }
      self?.developmentStewardProjectID = nil
      self?.reloadDevelopmentProcess()
    }
  }

  /// The project's tasks from its dashboard on disk, so projects other than the
  /// selected one stay current too.
  private func developmentTickets(for project: ProjectConfiguration) -> [DevelopmentTicket] {
    if project.id == selectedProject?.id, !dashboard.tickets.isEmpty {
      return dashboard.tickets.map(DevelopmentTicket.init)
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: project.dashboardPath)),
          let document = try? JSONDecoder().decode(DashboardDocument.self, from: data) else { return [] }
    return document.tickets.map(DevelopmentTicket.init)
  }

  /// Settings shows any project, not just the selected one; these keyed
  /// accessors keep that row independent of the Project tab's published state.
  func developmentProcessEnabled(for projectID: String) -> Bool {
    (try? developmentProcessStore.load(projectID: projectID))??.enabled ?? false
  }

  func setDevelopmentProcessEnabled(_ enabled: Bool, for projectID: String) {
    do {
      let updated = try developmentProcessStore.setEnabled(enabled, projectID: projectID)
      if projectID == selectedProject?.id { developmentProcess = updated.enabled ? updated : nil }
      developmentProcessError = nil
      if enabled { lastDevelopmentStewardCheck = nil; runDevelopmentStewardIfDue() }
    } catch {
      developmentProcessError = error.localizedDescription
    }
  }

  func openPlan(for ticket: DashboardTicket, sourceURL: URL? = nil) {
    isTokenAnalyticsPresented = false
    revealProject(for: ticket.id)
    markTicketViewed(ticket.id)
    isQueueChatInspectorPresented = false
    presentedAgentUpdate = nil
    isDailyReportPresented = false
    isDocumentViewerPresented = false
    presentedPlanTicketID = ticket.id
    presentedPlanURL = sourceURL
    presentedPlanMarkdown = ""
    isPlanLoading = true
    planError = nil
    let interactionAt = Date()
    let presentationID = UUID()
    planPresentationID = presentationID
    reportVisibilityHandler?(true)
    Task {
      do {
        taskContexts[ticket.id] = try await taskContextStore.ensureContext(ticket: ticket, project: project(for: ticket))
        taskContexts[ticket.id] = try await taskContextStore.recordInteraction(ticketID: ticket.id, at: interactionAt)
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

  private struct AgentUpdatesKey: Equatable {
    var tickets: [DashboardTicket]
    var closureMessages: [String: String]
    var dismissedNotificationIDs: Set<String>
    var taskContexts: [String: TaskContext]
  }

  /// Views read the update list several times per render, and each pass
  /// copied a whole task context per update.
  var agentUpdates: [QueueAgentUpdate] {
    let key = AgentUpdatesKey(tickets: projectTickets, closureMessages: closureMessages,
      dismissedNotificationIDs: localState.dismissedNotificationIDs, taskContexts: taskContexts)
    return agentUpdatesMemo.value(for: key) { computeAgentUpdates() }
  }

  private func computeAgentUpdates() -> [QueueAgentUpdate] {
    var updates: [QueueAgentUpdate] = []
    for ticket in projectTickets {
      if let message = closureMessages[ticket.id] {
        updates.append(QueueAgentUpdate(id: "cleanup-\(ticket.id)", ticketID: ticket.id,
          title: "Task closure needs attention", summary: message, isCleanup: true))
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

  func openAgentUpdate(_ update: QueueAgentUpdate) {
    isTokenAnalyticsPresented = false
    revealProject(for: update.ticketID)
    isQueueChatInspectorPresented = false
    presentedPlanTicketID = nil
    presentedPlanURL = nil
    isDailyReportPresented = false
    isDocumentViewerPresented = false
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
    guard let subtaskID = update.subtaskID else { return }
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
    guard update.subtaskID != nil else { return }
    Task { await acknowledgeAgentUpdate(update) }
  }

  func dismissReportNotification() {
    localState.dismissedNotificationIDs.insert(reportNotificationID)
    persistLocalState()
  }

  func focusTerminalPane(_ pane: WezTermPane) async throws {
    try await terminalController.focusPane(pane, configuration: config.wezTerm)
  }

  var uiCanvasStore: UICanvasStore { UICanvasStore(root: paths.supportDirectory) }

  /// Canvas tabs for a task: every open session, plus ended ones from the last
  /// day so a finished design stays reviewable until its tab is closed. A
  /// session the human reopened from the task's context stays until dismissed.
  func visibleUICanvases(ticketID: String) -> [UICanvasSession] {
    let cutoff = UICanvasStore.timestamp(Date().addingTimeInterval(-86_400))
    return (uiCanvasSessions[ticketID] ?? []).filter {
      !dismissedUICanvasKeys.contains($0.key)
        && (!$0.isEnded || $0.updatedAt > cutoff || reopenedUICanvasKeys.contains($0.key))
    }
  }

  func refreshUICanvases(ticketID: String) {
    let sessions = uiCanvasStore.sessions(taskID: ticketID)
    if uiCanvasSessions[ticketID] != sessions { uiCanvasSessions[ticketID] = sessions }
  }

  /// One model per session so stage state survives tab switches.
  func uiCanvasModel(ticketID: String, key: String) -> UICanvasModel {
    let id = "\(ticketID.uppercased())/\(key)"
    if let model = uiCanvasModels[id] { return model }
    let model = UICanvasModel(store: uiCanvasStore, taskID: ticketID.uppercased(), key: key)
    model.relayQueuedFeedback = { [weak self] in self?.relayUICanvasFeedback(ticketID: ticketID, key: key) }
    model.reconnectAgent = { [weak self] in self?.reconnectUICanvasAgent(ticketID: ticketID, key: key) }
    model.isAgentTurnRunning = uiCanvasReconnectTasks[id] != nil
    uiCanvasModels[id] = model
    return model
  }

  func dismissUICanvas(ticketID: String, key: String) {
    dismissedUICanvasKeys.insert(key)
    uiCanvasModels["\(ticketID.uppercased())/\(key)"]?.stop()
  }

  /// The human picked a session in the task's context: show its canvas tab the
  /// way a CLI `canvas open` does, even when the session ended long ago.
  func openUICanvasSession(ticketID: String, key: String) {
    let ticketID = ticketID.uppercased()
    dismissedUICanvasKeys.remove(key)
    reopenedUICanvasKeys.insert(key)
    refreshUICanvases(ticketID: ticketID)
    guard dashboard.tickets.contains(where: { $0.id == ticketID }) else { return }
    if panelMode != .expanded { setPanelMode(.expanded) }
    if presentedPlanTicketID != ticketID,
      let ticket = dashboard.tickets.first(where: { $0.id == ticketID }) {
      openPlan(for: ticket)
    }
    requestedUICanvas = UICanvasRequest(ticketID: ticketID, key: key)
  }

  /// Recalls the canvas creator's saved conversation, including completed or
  /// archived agents. Only an unknown creator starts a fresh task chat agent.
  /// An ended session the human reconnects is reopened first, matching the
  /// CLI's explicit-reopen rule. The reply lands in the canvas conversation.
  func reconnectUICanvasAgent(ticketID: String, key: String) {
    let ticketID = ticketID.uppercased()
    guard uiCanvasReconnectTasks["\(ticketID)/\(key)"] == nil,
      let session = try? uiCanvasStore.load(taskID: ticketID, key: key) else { return }
    openUICanvasSession(ticketID: ticketID, key: key)
    if session.isEnded {
      _ = try? uiCanvasStore.open(file: session.file, taskID: ticketID, title: nil, viewport: nil,
        reopen: true, agentName: nil)
      refreshUICanvases(ticketID: ticketID)
    }
    try? uiCanvasStore.setActivity(taskID: ticketID, key: key, state: "thinking")
    runUICanvasTurn(ticketID: ticketID, key: key, file: session.file, resetsNewAgent: true) { _ in
      Self.canvasReconnectPrompt(session: session)
    }
  }

  /// Delivers queued canvas feedback when no agent is parked in `canvas await`,
  /// so a reopened canvas reaches its agent without a terminal listener.
  func relayUICanvasFeedback(ticketID: String, key: String) {
    let ticketID = ticketID.uppercased()
    guard uiCanvasReconnectTasks["\(ticketID)/\(key)"] == nil,
      let session = try? uiCanvasStore.load(taskID: ticketID, key: key),
      UICanvasStore.needsRelay(session),
      let taken = try? uiCanvasStore.takeFeedback(taskID: ticketID, key: key),
      taken.status == .feedback else { return }
    runUICanvasTurn(ticketID: ticketID, key: key, file: session.file, resetsNewAgent: false) { creator in
      UICanvasRelayPrompt.build(session: session, items: taken.items, recap: creator == nil)
    }
  }

  /// One app-run turn for a canvas: a fork of the creator, otherwise the task's
  /// canvas chat agent. Its reply is posted to the canvas conversation.
  private func runUICanvasTurn(ticketID: String, key: String, file: String, resetsNewAgent: Bool,
                               prompt makePrompt: @escaping (DocumentChatCreator?) -> String) {
    let id = "\(ticketID)/\(key)"
    uiCanvasModels[id]?.isAgentTurnRunning = true
    uiCanvasReconnectTasks[id] = Task { [weak self] in
      guard let self else { return }
      // A long turn would outlive the thinking expiry and look abandoned.
      let heartbeat = Task { [store = uiCanvasStore] in
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: UInt64(UICanvasStore.thinkingExpiry / 3 * 1_000_000_000))
          if !Task.isCancelled { try? store.setActivity(taskID: ticketID, key: key, state: "thinking") }
        }
      }
      defer {
        heartbeat.cancel()
        uiCanvasReconnectTasks[id] = nil
        uiCanvasModels[id]?.isAgentTurnRunning = false
      }
      do {
        let creator = await documentCreator(path: file, ticketID: ticketID, known: nil)
        try Task.checkCancellation()
        let provider = creator?.author.provider ?? defaultAgentProvider
        var configuration = config.verifier
        configuration.executable = config.chatExecutable(for: provider)
        configuration.supportDirectory = paths.supportDirectory.path
        configuration.sessionName = "ecc-focus-queue-task-\(ticketID.lowercased())-canvas-\(key)"
        configuration.contextDirectory = taskContexts[ticketID]?.contextDirectory.path
        configuration.projectScopeID = dashboard.tickets.first { $0.id == ticketID }?.projectID
          ?? selectedProjectID
        configuration.writableDirectories = [URL(fileURLWithPath: file).deletingLastPathComponent().path]
        let agent = queueAgent(for: provider)
        var prompt = makePrompt(creator)
        let workspace: String
        if let creator {
          // A live or saved creator answers in a fork; its task stays complete.
          configuration.forkSourceSessionID = creator.forkSessionID
          prompt = Self.canvasForkPreamble + prompt
          workspace = creator.workspace ?? config.workspacePath
        } else {
          // A new route never inherits a session an earlier reconnect left behind.
          if resetsNewAgent { try await agent.reset(configuration: configuration) }
          workspace = dashboard.tickets.first { $0.id == ticketID }.map(defaultRepository)
            ?? config.workspacePath
        }
        try Task.checkCancellation()
        let reply = try await agent.send(
          message: prompt, dashboardPath: config.dashboardPath, workspace: workspace,
          visibleOrder: openTickets.map(\.id), deferredTicketIDs: [], configuration: configuration,
          model: creator?.model ?? effectiveChatModel(for: provider),
          effort: creator?.effort ?? Self.normalizedChatOption(config.chatEffort(for: provider)))
        try Task.checkCancellation()
        try uiCanvasStore.reply(taskID: ticketID, key: key, text: reply.message)
      } catch is CancellationError {
        // The app closed mid-turn; leave the transcript as it was.
        try? uiCanvasStore.setActivity(taskID: ticketID, key: key, state: "idle")
      } catch {
        try? uiCanvasStore.reply(taskID: ticketID, key: key,
          text: "Reconnect failed: \(error.localizedDescription)")
      }
      refreshUICanvases(ticketID: ticketID)
      uiCanvasModels[id]?.refresh()
    }
  }

  private static func canvasReconnectPrompt(session: UICanvasSession) -> String {
    """
    The user reopened the UI canvas "\(session.displayTitle)" (\(session.file)) in Focus Queue and \
    reconnected you. Focus Queue now delivers each canvas message to you as a turn, so do not run \
    `focus-queue-session canvas await` or `canvas open`. Reply in one or two sentences: confirm you are \
    reconnected and say what the mockup shows now or what you last changed.
    """
  }

  private static let canvasForkPreamble = """
    Focus Queue canvas reconnect: this turn runs in a fork of your conversation so the user can reopen a UI canvas you created. Your original terminal conversation continues separately and never sees this fork. Answer here. Do not report task progress, results, or completion with focus-queue-session from this fork, and change files only when the user asks.


    """

  /// The CLI changed a session. An `open` shows the task's plan viewer on that
  /// canvas, expanding the panel the way ECC's canvas opens a browser tab.
  /// Notifications from another support directory, such as a test clone, are ignored.
  func handleUICanvasChange(ticketID: String, key: String, event: String?, root: String?) {
    if let root, URL(fileURLWithPath: root).standardizedFileURL.path
      != paths.supportDirectory.standardizedFileURL.path { return }
    let ticketID = ticketID.uppercased()
    refreshUICanvases(ticketID: ticketID)
    uiCanvasModels["\(ticketID)/\(key)"]?.refresh()
    guard event == "open", let ticket = dashboard.tickets.first(where: { $0.id == ticketID }) else { return }
    dismissedUICanvasKeys.remove(key)
    if panelMode != .expanded { setPanelMode(.expanded) }
    if presentedPlanTicketID != ticketID { openPlan(for: ticket) }
    requestedUICanvas = UICanvasRequest(ticketID: ticketID, key: key)
  }

  func consumeUICanvasRequest(_ request: UICanvasRequest) {
    if requestedUICanvas == request { requestedUICanvas = nil }
  }

  func closePlan() {
    guard presentedPlanTicketID != nil else { return }
    presentedPlanTicketID = nil
    presentedPlanURL = nil
    isPlanLoading = false
    planPresentationID = UUID()
    reportVisibilityHandler?(isInspectorPresented)
  }

  /// Shows a file in the side document viewer. A new scope starts a fresh set
  /// of tabs; the same scope adds a tab and selects it.
  func openDocumentViewer(_ url: URL, scope: DocumentScope?) {
    guard let location = DocumentPaneLocation.normalized(url) else { return }
    isTokenAnalyticsPresented = false
    if documentViewerScope != scope || !isDocumentViewerPresented {
      if documentViewerScope != scope { documentViewer = DocumentPaneState() }
      documentViewerScope = scope
    }
    isQueueChatInspectorPresented = false
    presentedAgentUpdate = nil
    presentedPlanTicketID = nil
    presentedPlanURL = nil
    isDailyReportPresented = false
    documentViewer.open(location, in: .primary)
    // The viewer pairs a document with its chat; links open the split view.
    documentViewer.centralChatCollapsed = false
    isDocumentViewerPresented = true
    reportVisibilityHandler?(true)
  }

  /// Closing saves every pending edit first. A refused save keeps the viewer
  /// open on that document so its error and draft stay in view.
  func closeDocumentViewer() {
    guard isDocumentViewerPresented else { return }
    for url in documentViewer.tabs {
      guard documentContentStore.saveBeforeClose(url) else { documentViewer.select(url); return }
    }
    isDocumentViewerPresented = false
    documentViewer.dismiss()
    reportVisibilityHandler?(isInspectorPresented)
  }

  func closeDocumentViewerTab(_ url: URL) {
    guard documentContentStore.saveBeforeClose(url) else { return }
    documentViewer.close(url)
    if !documentViewer.isPresented { closeDocumentViewer() }
  }

  /// The task or project a link with no explicit owner belongs to: a file
  /// inside a task's context folder opens with that task; anything else opens
  /// under the project it lives in, or the selected project.
  func documentScope(for url: URL) -> DocumentScope? {
    let path = url.standardizedFileURL.path
    let tasks = paths.supportDirectory.appendingPathComponent("tasks", isDirectory: true).standardizedFileURL.path + "/"
    if path.hasPrefix(tasks),
       let ticketID = path.dropFirst(tasks.count).split(separator: "/").first.map(String.init),
       dashboard.tickets.contains(where: { $0.id == ticketID }) {
      return .task(ticketID)
    }
    let projectsRoot = paths.supportDirectory.appendingPathComponent("projects", isDirectory: true).standardizedFileURL.path + "/"
    if path.hasPrefix(projectsRoot),
       let projectID = path.dropFirst(projectsRoot.count).split(separator: "/").first.map(String.init),
       config.projects.contains(where: { $0.id == projectID }) {
      return .project(projectID)
    }
    if let project = activeProjects.first(where: {
      !$0.repositoryPath.isEmpty && path.hasPrefix(URL(fileURLWithPath: $0.repositoryPath).standardizedFileURL.path + "/")
    }) { return .project(project.id) }
    return (selectedProject ?? activeProjects.first).map { .project($0.id) }
  }

  func setQueueChatInspectorPresented(_ presented: Bool) {
    if presented {
      isTokenAnalyticsPresented = false
      presentedAgentUpdate = nil
      presentedPlanTicketID = nil
      presentedPlanURL = nil
      isDailyReportPresented = false
      isDocumentViewerPresented = false
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
    return displayStatus(subtask)
  }

  /// A long tool call writes no transcript records, so a live pane keeps
  /// Working longer before it reads as "No recent update".
  private func displayStatus(_ subtask: TaskSubtask, now: Date = Date()) -> TaskSubtaskStatus {
    subtask.effectiveStatus(now: now, heartbeatLifetime: subtask.heartbeatLifetime(
      liveRuntime: liveRuntimeSubtaskIDs.contains(subtask.id),
      runtimeShowsWork: spinningRuntimeSubtaskIDs.contains(subtask.id)))
  }

  /// Only a fresh conversation sent its initial prompt starts out Working.
  private static func launchStatus(_ subtask: TaskSubtask, includePrompt: Bool) -> TaskSubtaskStatus {
    subtask.sessionID == nil && includePrompt ? .working : .idle
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
      workingDirectory: Self.firstConfiguredPath(subtask.workspace?.path, context.worktreePath,
        context.repositoryPath, context.projectRepositoryPath) ?? config.workspacePath,
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

  /// Agents across every open task that saved a provider conversation but have
  /// no live process, most recently active first. Opening one resumes it.
  func recallableAgents() -> [(ticket: DashboardTicket, agent: TaskSubtask)] {
    allOpenTickets.flatMap { ticket in
      subtasks(for: ticket.id)
        .filter { $0.hasAgent && !$0.isAssignmentOnly && $0.sessionID != nil
          && !liveRuntimeSubtaskIDs.contains($0.id) }
        .map { (ticket: ticket, agent: $0) }
    }.sorted {
      ($0.agent.lastHeartbeatAt ?? .distantPast) > ($1.agent.lastHeartbeatAt ?? .distantPast)
    }
  }

  func focusSubtasks(for ticketID: String) -> [TaskSubtask] {
    taskContexts[ticketID]?.focusSubtasks ?? []
  }

  func taskItems(for ticketID: String) -> [TaskSubtask] {
    taskContexts[ticketID]?.taskItems ?? []
  }

  func isCompletionSeen(_ subtask: TaskSubtask, ticketID: String) -> Bool {
    taskContexts[ticketID]?.isCompletionSeen(subtask) ?? subtask.isCompletionSeen
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

  private func recordTaskInteraction(for ticket: DashboardTicket) {
    let date = Date()
    Task {
      do {
        _ = try await taskContextStore.ensureContext(ticket: ticket, project: project(for: ticket))
        taskContexts[ticket.id] = try await taskContextStore.recordInteraction(ticketID: ticket.id, at: date)
      } catch { actionMessages[ticket.id] = error.localizedDescription }
    }
  }

  func openSubtask(_ subtask: TaskSubtask, for ticket: DashboardTicket, showResult: Bool = true) {
    guard !subtask.isAssignmentOnly else {
      actionMessages[ticket.id] = "Choose an agent below this subtask, or use New agent to start one."
      return
    }
    if showResult && subtask.status == .completed && subtask.agentRemovedAt != nil {
      recordTaskInteraction(for: ticket)
      openAgentUpdate(QueueAgentUpdate(id: "subtask-\(ticket.id)-\(subtask.id)", ticketID: ticket.id,
        title: "\(subtask.title) completed", summary: subtask.resultSummary ?? subtask.progressSummary,
        subtaskID: subtask.id, date: subtask.resultAt ?? subtask.lastHeartbeatAt ?? .distantPast, resultID: subtask.resultID))
      return
    }
    let key = Self.subtaskKey(ticketID: ticket.id, subtaskID: subtask.id)
    guard openingSubtaskIDs.insert(key).inserted else { return }
    recordTaskInteraction(for: ticket)
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
        // provider process scan can authorize a new resume process. A Codex
        // sub-agent thread resumes through its lineage root, so the guard must
        // check the same identity the resume will use.
        if let sessionID = subtask.sessionID {
          let resumeIdentity = subtask.provider == .codex
            ? CodexSessionLineage.root(of: sessionID) : sessionID
          if let running = try await locateExistingAgent(subtask.provider, resumeIdentity) {
            throw TaskContextError.commandFailed(
              "This conversation is already running in \(running.cwd). Open its existing terminal. No second agent was started.")
          }
        }
        guard var context = try await taskContextStore.load(ticketID: ticket.id) else {
          throw TaskContextError.missingContext(ticket.id)
        }
        var assignment = context.subtasks.first(where: { $0.id == subtask.id }) ?? subtask
        // Codex resumes a sub-agent thread through its root conversation; keep
        // the saved record on the identity that later opens will observe live.
        if assignment.provider == .codex, let saved = assignment.sessionID {
          let root = CodexSessionLineage.root(of: saved)
          if root.caseInsensitiveCompare(saved) != .orderedSame { assignment.sessionID = root }
        }
        // Old records recover their original launch directory before inheriting a task default.
        if assignment.workspace == nil {
          let path = Self.firstConfiguredPath(session(for: subtask, ticketID: ticket.id)?.workingDirectory,
            context.worktreePath, context.repositoryPath, context.projectRepositoryPath) ?? config.workspacePath
          // Git is suggested, not required: recover plain directories as in-place workspaces.
          if let checkout = try await taskWorktreeManager.gitWorkspace(at: path) {
            assignment.workspace = checkout
          } else {
            assignment.workspace = try await taskWorktreeManager.plainWorkspace(at: path)
          }
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
            usageBarEnabled: config.agentUsageBarEnabled,
            codexSupportsNoDaemon: await codexSupportsNoDaemon(for: assignment.provider))
          // A resumed conversation is sent no prompt, so it waits for input.
          taskContexts[ticket.id] = try await taskContextStore.setManagedRuntime(
            ticketID: ticket.id, subtaskID: assignment.id, tmux: runtime,
            status: assignment.sessionID == nil ? .working : .idle)
          assignment.tmux = runtime
          _ = try await terminalController.openAgentRuntime(assignment, taskID: ticket.id, taskTitle: ticket.title, configuration: config.wezTerm)
        } else {
          assignment.runtimeMode = .terminal
          let receipt = try await taskAgentLauncher.launchDirect(context: context, subtask: assignment,
            configuration: config.wezTerm, supportDirectory: paths.supportDirectory)
          taskContexts[ticket.id] = try await taskContextStore.setDirectRuntime(
            ticketID: ticket.id, subtaskID: assignment.id, paneID: receipt.paneID, socketPath: receipt.socketPath,
            status: assignment.sessionID == nil ? .working : .idle)
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
    markTicketViewed(ticket.id)
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

  func launchAgent(
    for ticket: DashboardTicket, title: String, provider: AgentProvider,
    repositoryPath: String, assignmentDescription: String = "",
    includePrompt: Bool = true, useTmux: Bool = true,
    createWorktree: Bool = true, initialPrompt: String? = nil, tracksCompletion: Bool = true,
    subtaskID: String = UUID().uuidString, allowProjectRepositoryMismatch: Bool = false,
    parentSubtaskID: String? = nil, createAssignment: Bool = false,
    modelName: String? = nil, effort: String? = nil,
    workspacePolicy: AgentWorkspacePolicy? = nil,
    pluginOverrides: [String: Bool] = [:],
    role: AgentContractRole = .engineering,
    opensTerminal: Bool = true,
    completion: (@MainActor (Bool) -> Void)? = nil
  ) {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let suppliedDescription = assignmentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    let promptDescription = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let workDescription = String((suppliedDescription.isEmpty
      ? (promptDescription.isEmpty ? (includePrompt ? title : "") : promptDescription)
      : suppliedDescription).prefix(2_000))
    guard useTmux || !config.wezTerm.terminalApp.requiresTmux else {
      actionMessages[ticket.id] = "Agents run in tmux, which is not installed. Install it with brew install tmux, then try again."
      completion?(false)
      return
    }
    // A background launch never opens a window, so it needs tmux to keep the
    // agent running headless until the user opens it from the queue.
    guard opensTerminal || useTmux else {
      completion?(false)
      return
    }
    guard !title.isEmpty, launchingTaskIDs.insert(ticket.id).inserted else {
      completion?(false)
      return
    }
    recordTaskInteraction(for: ticket)
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
        let selectedModel = (modelName?.trimmingCharacters(in: .whitespacesAndNewlines))
          .flatMap { isUsableModel($0, for: provider) ? $0 : nil }
        let selectedEffort = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
        var launchConfiguration = AgentLaunchConfiguration(
          model: selectedModel?.isEmpty == false ? selectedModel : nil,
          effort: selectedEffort?.isEmpty == false ? selectedEffort : nil,
          pluginOverrides: pluginOverrides.isEmpty ? nil : pluginOverrides,
          role: role == .orchestrator ? AgentContractRole.orchestrator.rawValue : nil)
        if let parentSubtaskID {
          guard let parent = context.subtasks.first(where: { $0.id == parentSubtaskID }), parent.status != .completed else {
            throw TaskContextError.commandFailed("This subtask is already completed or no longer exists.")
          }
          subtask.parentSubtaskID = context.canonicalSubtaskID(parentSubtaskID)
          subtask.tracksCompletion = false
        }
        // The home directory is the fallback for projects without a folder; a
        // dotfiles repository there must never be forked into a worktree.
        let isHome = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
          == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        subtask.workspace = try await taskWorktreeManager.provisionAgent(ticketID: ticket.id,
          subtaskID: subtask.id, path: repositoryPath,
          policy: isHome ? .existingCheckout
            : workspacePolicy ?? (createWorktree ? .isolatedCleanCheckout : .existingCheckout),
          store: taskContextStore)
        if let previous {
          subtask.parentSubtaskID = previous.parentSubtaskID
          subtask.tracksCompletion = previous.tracksCompletion
          // A retried placeholder keeps its saved choices unless this launch names new ones.
          if let saved = previous.launchConfiguration {
            launchConfiguration.routeID = saved.routeID
            launchConfiguration.providerVersion = saved.providerVersion
            launchConfiguration.model = launchConfiguration.model ?? saved.model
            launchConfiguration.effort = launchConfiguration.effort ?? saved.effort
            launchConfiguration.pluginOverrides = launchConfiguration.pluginOverrides ?? saved.pluginOverrides
            launchConfiguration.role = launchConfiguration.role ?? saved.role
          }
        }
        // Agents started by the retired router already own a capsule under their route ID.
        if launchConfiguration.routeID == nil {
          launchConfiguration.launchID = UUID().uuidString.lowercased()
        }
        subtask.launchConfiguration = launchConfiguration
        _ = createAssignment // Retained for source compatibility; new launches are one task item.
        assignment = subtask
        agentSessionErrors[
          Self.subtaskKey(ticketID: ticket.id, subtaskID: subtask.id)
        ] = nil
        taskContexts[ticket.id] = try await taskContextStore.upsertSubtask(ticketID: ticket.id, subtask: subtask)
        if let launchID = subtask.launchConfiguration?.launchID,
           await !writePlacementCapsule(launchID: launchID, ticket: ticket, subtask: subtask) {
          subtask.launchConfiguration?.launchID = nil
          assignment = subtask
          taskContexts[ticket.id] = try await taskContextStore.upsertSubtask(ticketID: ticket.id, subtask: subtask)
        }
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
            "Starting \(provider.displayName) in tmux session \(expectedName). Waiting for the final pane process before opening \(terminalName)…"
          await recordAgentLaunch(
            subtask, ticketID: ticket.id, phase: "tmux-create", outcome: "started",
            message: "Requested one new tmux session.",
            details: ["tmuxName": expectedName, "executable": tmuxExecutable])
          let tmux = try await taskAgentLauncher.startManagedSession(
            context: context, subtask: subtask, supportDirectory: paths.supportDirectory,
            includePrompt: includePrompt, tmuxExecutable: tmuxExecutable,
            usageBarEnabled: config.agentUsageBarEnabled,
            codexSupportsNoDaemon: await codexSupportsNoDaemon(for: provider))
          runtimeStarted = true
          phase = "saving the confirmed tmux process"
          taskContexts[ticket.id] = try await taskContextStore.setManagedRuntime(
            ticketID: ticket.id, subtaskID: subtask.id, tmux: tmux,
            status: Self.launchStatus(subtask, includePrompt: includePrompt))
          if includePrompt {
            taskContexts[ticket.id] = try await taskContextStore.recordPrompt(
              ticketID: ticket.id, subtaskID: subtask.id)
          }
          subtask.tmux = tmux
          await recordAgentLaunch(
            subtask, ticketID: ticket.id, phase: "tmux-confirm", outcome: "succeeded",
            message: "tmux reported the same final pane process three times.",
            details: [
              "tmuxName": tmux.name, "serverPID": String(tmux.serverPID),
              "pane": tmux.paneID, "panePID": String(tmux.panePID), "terminal": tmux.tty,
            ])
          if opensTerminal {
            phase = "opening the \(terminalName) view"
            _ = try await terminalController.openAgentRuntime(
              subtask, taskID: ticket.id, taskTitle: ticket.title,
              configuration: config.wezTerm)
          }
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
            socketPath: receipt.socketPath,
            status: Self.launchStatus(subtask, includePrompt: includePrompt))
          if includePrompt {
            taskContexts[ticket.id] = try await taskContextStore.recordPrompt(
              ticketID: ticket.id, subtaskID: subtask.id)
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
        guard opensTerminal else {
          await recordAgentLaunch(
            subtask, ticketID: ticket.id, phase: "ready", outcome: "succeeded",
            message: "The provider process is running in tmux without a terminal window.")
          actionMessages[ticket.id] =
            "Started \(provider.displayName) for \(title) in the background. Click the subtask to open its terminal."
          return
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
            guard opensTerminal else {
              actionMessages[ticket.id] =
                "Started \(provider.displayName) for \(title) in the background. Click the subtask to open its terminal."
              return
            }
            do {
              let result = try await terminalController.openManagedAgentRuntime(
                saved, taskID: ticket.id, subtaskID: subtask.id,
                provider: provider, taskTitle: ticket.title,
                configuration: config.wezTerm)
              actionMessages[ticket.id] =
                "\(result.message) The provider process registered while tmux was still confirming its pane."
            } catch {
              actionMessages[ticket.id] =
                "The provider process is running and registered in tmux session \(saved.name), but \(terminalName) did not open its view. Click the subtask to retry. \(error.localizedDescription)"
            }
            return
          }
          let detail =
            "tmux accepted session \(name), but Focus Queue could not confirm its process after \(attempts) checks. Last check: \(lastDetail) The agent may be running. Focus Queue will not create another process. Click this subtask to retry opening the saved session."
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
            subtaskID: assignment.id,
            status: runtimeStarted ? Self.launchStatus(assignment, includePrompt: includePrompt) : .blocked,
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
          : "The agent process started, but \(terminalName) did not open its view. Click the subtask to retry the exact saved process. \(error.localizedDescription) Open the document icon for the full launch log."
      }
    }
  }

  /// Writes the placement capsule an app-launched agent reads from
  /// `$FOCUS_QUEUE_AGENT_CONTEXT`, through the same resolver `fq` and the
  /// shell entries use. Returns false when placement refuses the workspace,
  /// so the agent never starts pointed at a blocked capsule.
  private func writePlacementCapsule(
    launchID: String, ticket: DashboardTicket, subtask: TaskSubtask
  ) async -> Bool {
    guard let workspace = subtask.workspace?.path else { return false }
    do {
      let capsule = try await AgentPlacementResolver(root: paths.supportDirectory).resolve(
        AgentPlacementRequest(
          launchID: launchID, cwd: workspace,
          prompt: subtask.initialPrompt ?? subtask.assignmentDescription,
          explicitTaskID: ticket.id, assignmentID: subtask.id, provider: subtask.provider,
          createTaskIfNeeded: false, role: subtask.launchConfiguration?.role),
        configuration: config)
      await recordAgentLaunch(
        subtask, ticketID: ticket.id, phase: "placement", outcome: capsule.status.rawValue,
        message: capsule.reason ?? "Focus Queue wrote the agent's placement capsule.",
        details: ["capsule": capsule.capsulePath])
      return capsule.status == .placed
    } catch {
      await recordAgentLaunch(
        subtask, ticketID: ticket.id, phase: "placement", outcome: "skipped",
        message: "The placement capsule was not written: \(error.localizedDescription)")
      return false
    }
  }

  func launchDefaultAgent(
    for ticket: DashboardTicket, provider: AgentProvider? = nil,
    model: String? = nil, effort: String? = nil,
    subtaskID: String = UUID().uuidString,
    completion: (@MainActor (Bool) -> Void)? = nil
  ) {
    let provider = provider ?? defaultAgentProvider
    let model = model ?? defaultAgentModel(for: provider)
    let effort = effort ?? defaultAgentEffort(for: provider)
    rememberAgentLaunch(AgentLaunchPreset(
      provider: provider, model: model, effort: effort,
      workspacePolicy: .isolatedCommittedSnapshot, useTmux: true))
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
    // A task created without an agent saved its prompt for this launch; the +
    // creator promises the card's New Agent starts with it.
    let savedPrompt = savedInitialPrompt(for: ticket)
    launchAgent(
      for: ticket, title: title, provider: provider,
      repositoryPath: defaultRepository(for: ticket), assignmentDescription: savedPrompt ?? "",
      includePrompt: savedPrompt != nil, useTmux: true, initialPrompt: savedPrompt, tracksCompletion: true,
      subtaskID: subtaskID, modelName: model, effort: effort,
      workspacePolicy: .isolatedCommittedSnapshot,
      completion: completion)
  }

  var defaultAgentProvider: AgentProvider {
    config.defaultAgentProvider ?? config.agentProviderFallbackOrder.first ?? .codex
  }

  /// A configured default model; nil launches the provider without `--model`.
  /// The configured model, else the provider's standard one; never empty.
  func defaultAgentModel(for provider: AgentProvider) -> String? {
    config.agentModel(for: provider).flatMap { isUsableModel($0, for: provider) ? $0 : nil }
  }

  private var terminalName: String { config.wezTerm.terminalApp.displayName }

  /// False for a Codex model this account does not offer. The picker hides it,
  /// and a saved choice falls back to the account's default until it returns.
  func isUsableModel(_ model: String, for provider: AgentProvider) -> Bool {
    guard provider == .codex else { return true }
    return !unavailableCodexModels.contains(model) && codexCatalog?.offers(model) != false
  }

  /// The chat model that will run; nil uses the provider's default.
  func effectiveChatModel(for provider: AgentProvider) -> String? {
    Self.normalizedChatOption(config.chatModel(for: provider)).flatMap { isUsableModel($0, for: provider) ? $0 : nil }
  }

  private func codexSupportsNoDaemon(for provider: AgentProvider) async -> Bool {
    guard provider == .codex else { return true }
    if codexCatalog == nil { codexCatalog = await loadCodexCatalog() }
    return codexCatalog?.supportsNoDaemon ?? true
  }

  func defaultAgentEffort(for provider: AgentProvider) -> String? {
    config.agentEffort(for: provider)
  }

  /// Concrete models only: an older config's "Default" entry named no model.
  func agentModelChoices(for provider: AgentProvider) -> [AgentModelChoice] {
    let configured = config.agentModelChoices
    let choices = (configured.isEmpty ? AppConfiguration.defaultAgentModelChoices : configured)
      .filter { $0.provider == provider && $0.model != nil }
    guard provider == .codex else { return choices }
    return (codexCatalog?.choices(from: choices) ?? choices).filter {
      !unavailableCodexModels.contains($0.model ?? "")
    }
  }

  func setDefaultAgentProvider(_ provider: AgentProvider) {
    guard config.defaultAgentProvider != provider else { return }
    config.defaultAgentProvider = provider
    persistConfiguration()
  }

  func setDefaultAgentModel(_ model: String?, for provider: AgentProvider) {
    let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.flatMap { $0.isEmpty ? nil : $0 }
    guard config.defaultAgentModels[provider] != normalized else { return }
    config.defaultAgentModels[provider] = normalized
    persistConfiguration()
  }

  func setChatModel(_ model: String?, for provider: AgentProvider) {
    let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.flatMap { $0.isEmpty ? nil : $0 }
    guard config.chatModels[provider] != normalized else { return }
    config.chatModels[provider] = normalized
    persistConfiguration()
  }

  func setChatEffort(_ effort: String?, for provider: AgentProvider) {
    let trimmed = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.flatMap { $0.isEmpty ? nil : $0 }
    guard config.chatEfforts[provider] != normalized else { return }
    config.chatEfforts[provider] = normalized
    persistConfiguration()
  }

  func setDefaultAgentEffort(_ effort: String?, for provider: AgentProvider) {
    let trimmed = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.flatMap { $0.isEmpty ? nil : $0 }
    guard config.defaultAgentEfforts[provider] != normalized else { return }
    config.defaultAgentEfforts[provider] = normalized
    persistConfiguration()
  }

  /// `fq` placement runs unless the configuration explicitly turns it off.
  var placementModelEnabled: Bool { config.placementModelEnabled ?? true }

  var placementConfidenceThreshold: Double {
    config.placementConfidenceThreshold ?? AppConfiguration.defaultPlacementConfidenceThreshold
  }

  var placementTimeoutSeconds: Int {
    config.placementTimeoutSeconds ?? AppConfiguration.defaultPlacementTimeoutSeconds
  }

  /// Named models for one provider's placement picker; a configured model the
  /// menu does not list keeps its own entry so the picker can show it.
  func placementModelChoices(for provider: AgentProvider) -> [AgentModelChoice] {
    var choices = agentModelChoices(for: provider).filter { $0.model?.isEmpty == false }
    for model in [AppConfiguration.defaultPlacementModels[provider], config.placementModels[provider]] {
      if let model, !choices.contains(where: { $0.model == model }) {
        choices.append(AgentModelChoice(provider: provider, label: model, model: model))
      }
    }
    return choices
  }

  func setPlacementModelEnabled(_ enabled: Bool) {
    guard config.placementModelEnabled != enabled else { return }
    config.placementModelEnabled = enabled
    persistConfiguration()
  }

  /// nil runs placement on whichever provider `fq` launches.
  func setPlacementProvider(_ provider: AgentProvider?) {
    guard config.placementProvider != provider else { return }
    config.placementProvider = provider
    persistConfiguration()
  }

  /// A nil or blank model restores the provider's built-in placement model.
  func setPlacementModel(_ model: String?, for provider: AgentProvider) {
    let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.flatMap { $0.isEmpty ? nil : $0 }
    guard config.placementModels[provider] != normalized else { return }
    config.placementModels[provider] = normalized
    persistConfiguration()
  }

  /// A nil or blank effort restores the provider's built-in placement effort.
  func setPlacementEffort(_ effort: String?, for provider: AgentProvider) {
    let trimmed = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.flatMap { $0.isEmpty ? nil : $0 }
    guard config.placementEfforts[provider] != normalized else { return }
    config.placementEfforts[provider] = normalized
    persistConfiguration()
  }

  func setPlacementConfidenceThreshold(_ threshold: Double) {
    let clamped = (min(max(threshold, 0.5), 0.95) * 100).rounded() / 100
    guard config.placementConfidenceThreshold != clamped else { return }
    config.placementConfidenceThreshold = clamped
    persistConfiguration()
  }

  func setPlacementTimeoutSeconds(_ seconds: Int) {
    let clamped = min(max(seconds, 5), 60)
    guard config.placementTimeoutSeconds != clamped else { return }
    config.placementTimeoutSeconds = clamped
    persistConfiguration()
  }

  /// New Agent quick actions follow the configured default until the user
  /// explicitly picks a provider (only then is the AppStorage key written).
  func preferredNewAgentProvider(stored: AgentProvider?) -> AgentProvider {
    stored ?? defaultAgentProvider
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
        modelName: request.model, effort: request.effort,
        // Report escalations start unattended, often several in a row. They
        // run in tmux without a window so they never take focus or the cursor.
        opensTerminal: false
      ) { [weak self] _ in
        self?.escalationAutoLaunchInFlight = false
      }
      break
    }
  }

  /// Completion is final: tmux stops, worktrees move to a 7-day trash, and
  /// branches are deleted once their work is merged or archived. Tasks that
  /// were completed before this ran are left for an explicit, reviewed
  /// `focus-queue-session cleanup --completed`, never swept on launch.
  private func finalizeCompletedTask(_ ticket: DashboardTicket, force: Bool = false) async {
    guard cleaningTaskIDs.insert(ticket.id).inserted else { return }
    defer { cleaningTaskIDs.remove(ticket.id) }
    let completedAt = ticket.completionTimestamp.flatMap(Self.parseCompletionDate)
    if !force {
      if let saved = TaskCompletionCleanup.savedReport(ticketID: ticket.id, root: paths.supportDirectory),
         completedAt.map({ saved.finishedAt >= $0 }) ?? true {
        closureMessages[ticket.id] = saved.isClean ? nil : saved.summary
        return
      }
      guard let completedAt, Date().timeIntervalSince(completedAt) < 24 * 60 * 60 else { return }
    }
    let cleanup = TaskCompletionCleanup(root: paths.supportDirectory,
      projectRepositories: config.projects.flatMap { [$0.repositoryPath, $0.workspacePath] },
      tmuxExecutable: config.tmuxExecutable)
    let report = await cleanup.run(ticketID: ticket.id)
    closureMessages[ticket.id] = report.isClean ? nil : report.summary
    actionMessages[ticket.id] = report.summary
    if let context = try? await taskContextStore.load(ticketID: ticket.id) {
      taskContexts[ticket.id] = context
      cleanupSignatures[ticket.id] = context.updatedAt
    }
    if lastStagingPurge.map({ Date().timeIntervalSince($0) > 6 * 60 * 60 }) ?? true {
      lastStagingPurge = Date()
      _ = await cleanup.purgeExpiredStaging()
    }
  }

  private static func parseCompletionDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
  }

  func retryCleanup(for ticket: DashboardTicket) {
    Task { await finalizeCompletedTask(ticket, force: true) }
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

  /// Marks the task complete in its canonical dashboard, closing any open
  /// completion-tracked assignments first.
  func requestCompletion(for ticket: DashboardTicket) {
    Task { await completeTicket(ticket) }
  }

  /// Returns false when the task stays open, so the card can undo its
  /// completion animation and show the failure message.
  @discardableResult
  func completeTicket(_ ticket: DashboardTicket) async -> Bool {
    guard ticket.isOpen else { return false }
    actionMessages[ticket.id] = "Marking complete…"
    let ticketDashboardPath = dashboardPath(for: ticket)
    do {
      try await validateCanonicalCompletion(
        ticketID: ticket.id, dashboardPath: ticketDashboardPath)
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
        dashboardPath: ticketDashboardPath,
        reason: "Marked complete by the user.",
        evidence: [],
        completedBy: "user")
      if let resolved { await finalizeCompletedTask(resolved) }
      actionMessages[ticket.id] = "Task marked complete."
      return true
    } catch {
      actionMessages[ticket.id] = "Could not mark complete: \(error.localizedDescription)"
      return false
    }
  }

  func requestSubtaskCompletion(_ subtask: TaskSubtask, for ticket: DashboardTicket) {
    guard subtask.status != .completed else { return }
    overrideCompletion(subtask, for: ticket)
  }

  func focusTerminal(for ticket: DashboardTicket) {
    let directory = defaultRepository(for: ticket)
    actionMessages[ticket.id] = "Opening \(terminalName)…"
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

  /// Every tracked agent session, for reading usage from provider transcripts.
  var tokenAnalyticsSessions: [AgentTranscriptUsage.Session] {
    localState.agentSessions.map {
      AgentTranscriptUsage.Session(ticketID: $0.ticketID, provider: $0.provider.rawValue,
                                   sessionID: $0.sessionID, label: $0.taskTitle ?? $0.ticketID)
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
      let stateBeforeImport = localState
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
        let missing = AgentRegistrationValidator.missingFields(
          session: registration, subtask: subtask)
        if !missing.isEmpty {
          let key = Self.subtaskKey(ticketID: registration.ticketID, subtaskID: subtaskID)
          agentSessionErrors[key] = "Registration incomplete: missing \(missing.joined(separator: ", "))."
          reportRegistrationIssue(AgentRegistrationIssue(
            registrationID: registration.sessionID, title: subtask.title,
            taskID: registration.ticketID, subtaskID: subtaskID, missingFields: missing))
        }
        actionMessages[registration.ticketID] = subtask.runtimeMode == .tmux
          ? "\(registration.provider.displayName) is running and registered in tmux. Click \(subtask.title) to open its exact terminal session."
          : registration.paneID != nil
            ? "\(registration.provider.displayName) is running in its saved WezTerm pane. Click \(subtask.title) to focus it."
            : "Session tracked. Continue in its existing terminal; Focus Queue will check it before resuming."
      }
      // Hooks re-send unchanged registrations constantly. Rewriting identical
      // state here also rewrote durable history on every refresh.
      if localState != stateBeforeImport {
        try await stateStore.save(localState)
        await captureDurableState(localState)
      }
      await agentRegistrationInbox.acknowledge(imported)
    } catch {
      loadError = "Could not import agent registration: \(error.localizedDescription)"
    }
  }

  /// Managed launches are held to the completeness bar only after their
  /// post-launch registration window. External sessions discovered without a
  /// launch identity stay placeable inbox entries instead of errors.
  private static let registrationValidationWindow: TimeInterval = 45

  private func validateRegistrationCompleteness(records: [ExternalAgentRegistration]) {
    let now = Date()
    var hints: [LaunchHint]?
    var flaggedKeys: Set<String> = []
    for record in records {
      guard now.timeIntervalSince(record.registeredAt) >= Self.registrationValidationWindow
      else { continue }
      let subtask = record.taskID
        .flatMap { taskContexts[$0.uppercased()] }?
        .subtasks.first { $0.id == record.subtaskID }
      var managed = subtask.map {
        $0.runtimeMode == .tmux || $0.runtimeMode == .terminal || $0.workspace?.managed == true
      } ?? false
      if !managed, let sessionID = record.sessionID {
        let allHints = hints ?? LaunchHintStore.hints(root: paths.supportDirectory)
        hints = allHints
        managed = LaunchHintStore.match(
          sessionID: sessionID, provider: record.provider,
          tmux: record.tmux, hints: allHints) != nil
      }
      guard managed,
            let issue = AgentRegistrationValidator.issue(record: record, subtask: subtask)
      else { continue }
      if let taskID = issue.taskID, let subtaskID = issue.subtaskID {
        let key = Self.subtaskKey(ticketID: taskID, subtaskID: subtaskID)
        flaggedKeys.insert(key)
        let message = "Registration incomplete: missing \(issue.missingFields.joined(separator: ", "))."
        if agentSessionErrors[key] != message { agentSessionErrors[key] = message }
      }
      reportRegistrationIssue(issue)
    }
    // Clear self-raised errors once their record becomes complete again.
    let resolvedKeys = agentSessionErrors.filter {
      $0.value.hasPrefix("Registration incomplete:") && !flaggedKeys.contains($0.key)
    }.map(\.key)
    for key in resolvedKeys { agentSessionErrors[key] = nil }
  }

  private func reportRegistrationIssue(_ issue: AgentRegistrationIssue) {
    let identity = issue.registrationID + "|" + issue.missingFields.joined(separator: ",")
    guard reportedRegistrationIssueIDs.insert(identity).inserted else { return }
    // No modal: the dedupe set resets on every relaunch, so an alert re-raised
    // every stale taskless record after each install. The card error and the
    // program log carry the issue instead.
    programLog.record(
      "Agent registration incomplete: \(issue.summary). "
        + "Re-register the agent from its pane with focus-queue-session attach <TASK-ID>.",
      level: .error, category: "Agent registration")
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
      // A launch-keyed placeholder is provisional. Once the launch's placement
      // names a real agent row in this task, fold the placeholder into that row
      // instead of double-counting the work item — even if the row has since
      // completed, so it never lingers as a phantom "working" agent.
      if let agentID = receipt.agentID,
        agentID != receipt.launchID,
        context.subtasks.contains(where: { $0.id.caseInsensitiveCompare(agentID) == .orderedSame }),
        context.subtasks.contains(where: { $0.id == receipt.launchID && $0.agentRemovedAt == nil })
      {
        context = try await taskContextStore.mergeTrackedLaunch(
          ticketID: taskID, launchID: receipt.launchID, into: agentID)
        taskContexts[taskID] = context
      }
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
        visibleAgents(for: ticket.id).contains { displayStatus($0) == .working }
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
        let launchHints = discovered.isEmpty ? [] : LaunchHintStore.hints(root: paths.supportDirectory)
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
          // An app or fq launch fixes the task, agent, and objective in its
          // placement capsule before the provider session exists; bind discovery
          // to that identity so the agent registers promptly with a prompt-derived title.
          let launchHint = intake == nil
            ? LaunchHintStore.match(
              sessionID: process.sessionID, provider: process.provider,
              tmux: tmux, hints: launchHints)
            : nil
          if prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            prompt = launchHint?.promptHint
          }
          if prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            prompt = process.promptHint
          }
          let environment: [String: String] = intake.map { receipt in
            receipt.discoveryEnvironment(in:
              receipt.taskID.flatMap { taskContexts[$0.uppercased()] })
          } ?? launchHint.map {
            ["FOCUS_QUEUE_TASK_ID": $0.taskID, "FOCUS_QUEUE_SUBTASK_ID": $0.subtaskID]
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
        }
      }
      let records = try await registry.registrations()
      let unassigned = records.filter { $0.taskID == nil }
        + AgentIntakeStore.pending(root: paths.supportDirectory).filter { $0.taskID == nil }
      if unassignedAgentRegistrations != unassigned { unassignedAgentRegistrations = unassigned }
      if externalAgentRegistrationError != nil { externalAgentRegistrationError = nil }
      validateRegistrationCompleteness(records: records)
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
          // Git is suggested, not required: adopt plain directories in place.
          if let checkout = try await taskWorktreeManager.gitWorkspace(at: session.workingDirectory) {
            agent.workspace = checkout
          } else {
            agent.workspace = try await taskWorktreeManager.plainWorkspace(at: session.workingDirectory)
          }
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
    recordTaskInteraction(for: ticket)
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

  /// Only an explicit user action retires an agent. Completion never stops,
  /// replaces, or archives the provider; it keeps running in its pane.
  private func retireAgent(_ subtask: TaskSubtask, for ticket: DashboardTicket) async {
    do {
      let lease = try await TaskMaintenance.lease(ticketID: ticket.id, root: paths.supportDirectory)
      defer { lease.release() }
      taskContexts[ticket.id] = try await taskContextStore.archiveAgent(ticketID: ticket.id, subtaskID: subtask.id)
      localState.agentSessions.removeAll {
        $0.ticketID == ticket.id && ($0.subtaskID == subtask.id ||
          ($0.provider == subtask.provider && $0.sessionID.caseInsensitiveCompare(subtask.sessionID ?? "") == .orderedSame))
      }
      agentSessionErrors[Self.subtaskKey(ticketID: ticket.id, subtaskID: subtask.id)] = nil
      persistLocalState()
      actionMessages[ticket.id] = "Agent archived. Its assignment, conversation, and workspace history are retained."
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
        closureMessages[ticket.id] = nil
        actionMessages[ticket.id] = "Subtask marked complete."
        if presentedAgentUpdate?.ticketID == ticket.id { closeAgentUpdate() }
      } catch { actionMessages[ticket.id] = error.localizedDescription }
    }
  }

  /// Closing the window detaches its tmux client; the agent keeps running and
  /// Open brings the window back. Only tmux-backed agents apply: a direct
  /// WezTerm pane is the conversation, so closing it would end the agent.
  func canCloseTerminalWindow(_ subtask: TaskSubtask) -> Bool {
    subtask.tmux != nil && subtask.hasAgent && subtask.agentRemovedAt == nil
  }

  func closeAgentTerminalWindow(_ subtask: TaskSubtask, for ticket: DashboardTicket) {
    guard canCloseTerminalWindow(subtask) else { return }
    Task {
      do {
        let detached = try await taskAgentLauncher.detachWindowClients(subtask: subtask)
        actionMessages[ticket.id] = detached > 0
          ? "Closed \(subtask.title)'s terminal window. The agent keeps running; open it again anytime."
          : "\(subtask.title) had no terminal window attached. Its session is still running; open it to view it again."
      } catch TmuxError.stopped {
        actionMessages[ticket.id] = "\(subtask.title)'s session has already stopped, so there is no window to close."
      } catch {
        actionMessages[ticket.id] = error.localizedDescription
      }
    }
  }

  /// Pause and Resume drive the provider TUI through its managed tmux pane;
  /// WezTerm-only and external agents keep their own terminal controls.
  func canPause(_ subtask: TaskSubtask) -> Bool {
    subtask.tmux != nil && subtask.hasAgent && subtask.status != .completed && subtask.agentRemovedAt == nil
  }

  func isChangingPause(_ subtask: TaskSubtask, ticketID: String) -> Bool {
    pauseChangingSubtaskIDs.contains(Self.subtaskKey(ticketID: ticketID, subtaskID: subtask.id))
  }

  func pauseAgent(_ subtask: TaskSubtask, for ticket: DashboardTicket) {
    changePause(subtask, for: ticket, pause: true)
  }

  func resumeAgent(_ subtask: TaskSubtask, for ticket: DashboardTicket) {
    changePause(subtask, for: ticket, pause: false)
  }

  private func changePause(_ subtask: TaskSubtask, for ticket: DashboardTicket, pause: Bool) {
    let key = Self.subtaskKey(ticketID: ticket.id, subtaskID: subtask.id)
    guard pauseChangingSubtaskIDs.insert(key).inserted else { return }
    agentSessionErrors[key] = nil
    Task {
      defer { pauseChangingSubtaskIDs.remove(key) }
      let controller = AgentPauseController(store: taskContextStore)
      do {
        if pause {
          taskContexts[ticket.id] = try await controller.pause(ticketID: ticket.id, subtaskID: subtask.id)
          actionMessages[ticket.id] = "Paused \(subtask.title). Press Resume to continue the same conversation."
        } else {
          taskContexts[ticket.id] = try await controller.resume(ticketID: ticket.id, subtaskID: subtask.id)
          actionMessages[ticket.id] = "Resumed \(subtask.title)."
        }
      } catch TmuxError.stopped where !pause {
        // The pane closed while paused, for example after a restart. Clear the
        // pause and reopen the saved conversation in a new pane.
        taskContexts[ticket.id] = try? await taskContextStore.setPaused(
          ticketID: ticket.id, subtaskID: subtask.id, paused: false, promptSent: false)
        openSubtask(subtask, for: ticket, showResult: false)
        actionMessages[ticket.id] = "\(subtask.title)'s pane had closed, so Focus Queue reopened its saved conversation. Type continue in it to carry on."
      } catch TmuxError.stopped {
        actionMessages[ticket.id] = "\(subtask.title)'s pane has already closed, so nothing is running to pause."
      } catch {
        agentSessionErrors[key] = error.localizedDescription
        actionMessages[ticket.id] = error.localizedDescription
      }
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

  /// Local PDFs, Markdown, and text files open in Focus Queue's own viewer:
  /// beside the task plan when the link belongs to a task, otherwise in the
  /// side document viewer. Everything else goes to its default app.
  func open(_ rawValue: String, ticketID: String? = nil) {
    guard let url = ResourceLocator.url(for: rawValue) else { return }
    if let document = InAppDocument.fileURL(for: url) {
      let scope = ticketID.map { DocumentScope.task($0) } ?? documentScope(for: document)
      if case .task(let id) = scope, let ticket = dashboard.tickets.first(where: { $0.id == id }) {
        openPlan(for: ticket, sourceURL: document)
      } else {
        openDocumentViewer(document, scope: scope)
      }
      return
    }
    NSWorkspace.shared.open(url)
  }

  func openConfiguration() {
    NSWorkspace.shared.open(paths.configurationFile)
  }

  func setDailyReportPresented(_ presented: Bool) {
    if presented {
      isTokenAnalyticsPresented = false
      isQueueChatInspectorPresented = false
      presentedAgentUpdate = nil
      presentedPlanTicketID = nil
      presentedPlanURL = nil
      isDocumentViewerPresented = false
    }
    isDailyReportPresented = presented
    reportVisibilityHandler?(isInspectorPresented)
    if presented { markReportViewed() }
  }

  func toggleDailyReport() {
    setDailyReportPresented(!isDailyReportPresented)
  }

  func reloadDailyReport(preservingSelection: Bool = false, capturingHistory: Bool = true) async {
    do {
      let report = try await dailyReportRepository.load()
      if let report, latestDailyReport != report {
        if latestDailyReport == nil || Self.reportDate(report.finishedAt) >= Self.reportDate(latestDailyReport!.finishedAt) {
          latestDailyReport = report
        }
      }
      if (!preservingSelection || dailyReport == nil), dailyReport != report { dailyReport = report }
      if dailyReportLoadError != nil { dailyReportLoadError = nil }
      await reloadReportHistory(capturingHistory: capturingHistory)
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
    let provider = dailyReportAgentProvider
    let request = DailyReportRunRequest(
      trigger: .manual,
      platforms: config.dailyReport.enabledPlatforms,
      comprehensive: true,
      recheck: false,
      agentProvider: provider,
      agentModel: config.dailyReport.agentModel ?? defaultAgentModel(for: provider),
      agentEffort: config.dailyReport.agentEffort ?? defaultAgentEffort(for: provider)
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

  func requestNewTask(projectID: String? = nil, autofocusPrompt: Bool = false) {
    // An agent cannot start without a signed-in provider; the gate explains why.
    guard !requiresProviderSignIn else { return setPanelMode(.expanded) }
    newTaskRequest = NewTaskRequest(
      projectID: projectID ?? selectedProject?.id,
      autofocusPrompt: autofocusPrompt
    )
  }

  func clearNewTaskRequest() {
    newTaskRequest = nil
  }

  /// New task hotkey: cancels an open new task sheet, like its Cancel button, or opens one.
  func toggleNewTaskRequest() {
    if newTaskRequest != nil { clearNewTaskRequest() } else { requestNewTask(autofocusPrompt: true) }
  }

  func setNewTaskHotkeyEnabled(_ enabled: Bool) {
    guard newTaskHotkeyEnabled != enabled else { return }
    newTaskHotkeyEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: "voiceTaskHotkeyEnabled")
    newTaskHotkeyEnabledHandler?(enabled)
  }

  func isHotkeyEnabled(_ action: HotkeyAction) -> Bool {
    switch action {
    case .newTask: newTaskHotkeyEnabled
    case .qchat: qchatHotkeyEnabled
    case .toggleMinimization: toggleMinimizationHotkeyEnabled
    }
  }

  func hotkeyShortcut(for action: HotkeyAction) -> HotkeyShortcut {
    hotkeyShortcuts[action] ?? action.defaultShortcut
  }

  func setToggleMinimizationHotkeyEnabled(_ enabled: Bool) {
    guard toggleMinimizationHotkeyEnabled != enabled else { return }
    toggleMinimizationHotkeyEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: "toggleMinimizationHotkeyEnabled")
    hotkeyConfigurationHandler?()
  }

  /// nil restores the action's built-in shortcut. Recording the default stores nothing.
  func setHotkeyShortcut(_ shortcut: HotkeyShortcut?, for action: HotkeyAction) {
    let shortcut = shortcut == action.defaultShortcut ? nil : shortcut
    guard hotkeyShortcuts[action] != shortcut else { return }
    hotkeyShortcuts[action] = shortcut
    hotkeyErrors[action] = nil
    if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
      UserDefaults.standard.set(data, forKey: action.shortcutDefaultsKey)
    } else {
      UserDefaults.standard.removeObject(forKey: action.shortcutDefaultsKey)
    }
    hotkeyConfigurationHandler?()
  }

  func setHotkeyError(_ message: String?, for action: HotkeyAction) {
    guard hotkeyErrors[action] != message else { return }
    hotkeyErrors[action] = message
    if let message { programLog.record(message, level: .warning, category: "Hotkeys") }
  }

  func setQChatHotkeyEnabled(_ enabled: Bool) {
    guard qchatHotkeyEnabled != enabled else { return }
    qchatHotkeyEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: "qchatHotkeyEnabled")
    qchatHotkeyEnabledHandler?(enabled)
  }

  /// Opens the central QChat conversation beside the queue, like the side-panel
  /// button, with its composer focused.
  func requestQueueChatFocus() {
    setPanelMode(.expanded)
    setQueueChatInspectorPresented(true)
    queueChatFocusRequest += 1
  }

  func setDailyReportSchedule(hour: Int, minute: Int) {
    guard (0...23).contains(hour), (0...59).contains(minute) else { return }
    config.dailyReport.scheduleHour = hour
    config.dailyReport.scheduleMinute = minute
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

  func setDailyReportAgentProvider(_ provider: AgentProvider?) {
    guard config.dailyReport.agentProvider != provider else { return }
    config.dailyReport.agentProvider = provider
    persistConfiguration()
  }

  func setDailyReportAgentModel(_ model: String?) {
    let normalized = Self.normalizedChatOption(model)
    guard config.dailyReport.agentModel != normalized else { return }
    config.dailyReport.agentModel = normalized
    persistConfiguration()
  }

  func setDailyReportAgentEffort(_ effort: String?) {
    let normalized = Self.normalizedChatOption(effort)
    guard config.dailyReport.agentEffort != normalized else { return }
    config.dailyReport.agentEffort = normalized
    persistConfiguration()
  }

  /// The provider the sweep runs, following the default provider unless the
  /// daily-report settings pin a specific one.
  var dailyReportAgentProvider: AgentProvider {
    config.dailyReport.agentProvider ?? defaultAgentProvider
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

  /// Writes a starter ingestion.json when none exists, so each connector shows
  /// its own setup step. Never overwrites an existing file.
  @discardableResult
  func createStarterIngestionConfiguration() -> Bool {
    do {
      let created = try IngestionStarter.writeIfMissing(
        supportDirectory: paths.supportDirectory, dashboardPath: config.dashboardPath)
      if created { programLog.record("Created a starter ingestion.json.", category: "Connectors") }
      return created
    } catch {
      connectorDiagnosticsError = "Could not create ingestion.json: \(error.localizedDescription)"
      return false
    }
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

  var isWindowPinned: Bool { localState.isWindowPinned }

  func toggleWindowPin() {
    localState.isWindowPinned.toggle()
    windowPinHandler?()
    persistLocalState()
  }

  var minimizationHelp: String {
    let shortcut = hotkeyShortcut(for: .toggleMinimization).displayString
    let availability = toggleMinimizationHotkeyEnabled ? "" : " (disabled in Settings)"
    return "Toggle minimization: \(shortcut)\(availability); right-click to choose how"
  }

  func switchMonitor() {
    monitorSwitchHandler?()
  }

  func setCanSwitchMonitor(_ canSwitchMonitor: Bool) {
    self.canSwitchMonitor = canSwitchMonitor
  }

  func setAppearance(_ appearance: QueueAppearance) {
    localState.appearance = appearance
    pdfDarkModeOverride = nil
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

  func toggleMinimization(isMiniaturized: Bool = false) {
    if isMiniaturized || panelMode != .expanded {
      setPanelMode(.expanded)
    } else {
      performPreferredMinimization()
    }
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
      // First, so a detail opened from the list does not reopen it while closing.
      setTokenAnalyticsPresented(false)
      closeAgentUpdate()
      closePlan()
      setQueueChatInspectorPresented(false)
    }
    if mode != .expanded, isDailyReportPresented {
      setDailyReportPresented(false)
    }
    if mode == .expanded { panelRestoreCount += 1 }
    panelMode = mode
    panelModeHandler?(mode)
  }

  func quit() {
    quitHandler?()
  }

  // MARK: Walkthrough

  var walkthroughSnapshot: WalkthroughSnapshot {
    WalkthroughSnapshot(
      projectCount: config.projects.filter { $0.id != ProjectCatalog.otherID }.count,
      agentCount: taskContexts.values.reduce(0) { $0 + $1.subtasks.filter(\.hasAgent).count },
      panelRestoreCount: panelRestoreCount)
  }

  /// The open task whose controls the walkthrough points at: the one that got
  /// the tour's first agent, else the first task with an agent, else the top task.
  var walkthroughTicket: DashboardTicket? {
    let open = openTickets
    if let walkthroughTicketID, let ticket = open.first(where: { $0.id == walkthroughTicketID }) {
      return ticket
    }
    return open.first { !focusSubtasks(for: $0.id).filter(\.hasAgent).isEmpty } ?? open.first
  }

  func startWalkthrough() {
    setPanelMode(.expanded)
    walkthroughTicketID = nil
    walkthroughMessage = nil
    walkthrough = WalkthroughProgress(baseline: walkthroughSnapshot)
  }

  func advanceWalkthrough() {
    guard var progress = walkthrough else { return }
    walkthroughMessage = nil
    if progress.next(walkthroughSnapshot) { walkthrough = progress } else { finishWalkthrough() }
  }

  func retreatWalkthrough() {
    guard var progress = walkthrough else { return }
    walkthroughMessage = nil
    progress.back(walkthroughSnapshot)
    walkthrough = progress
  }

  /// Finishing and skipping both end the tour for good; the info menu replays it.
  func finishWalkthrough() {
    walkthrough = nil
    walkthroughMessage = nil
    localState.walkthroughCompletedAt = Date()
    persistLocalState()
    // A tour skipped before its sign-in step never checked the providers; the gate needs them.
    if providerAccounts.isEmpty { Task { await refreshProviderAccounts() } }
    if config.setupCompleted != true {
      config.setupCompleted = true
      persistConfiguration()
    }
  }

  /// Advances a step whose goal the user just completed.
  func checkWalkthroughGoal() {
    guard let progress = walkthrough, progress.isGoalMet(walkthroughSnapshot) else { return }
    if progress.step == .launchAgent {
      walkthroughTicketID = openTickets.max { left, right in
        latestAgentLaunch(left.id) < latestAgentLaunch(right.id)
      }?.id
    }
    advanceWalkthrough()
  }

  private func latestAgentLaunch(_ ticketID: String) -> Date {
    focusSubtasks(for: ticketID).filter(\.hasAgent)
      .compactMap { $0.lastHeartbeatAt ?? $0.lastPromptAt }.max() ?? .distantPast
  }

  /// Opens the example mockup as a UI Canvas tab on the tour's task, the same
  /// way `focus-queue-session canvas open` does for an agent.
  func openWalkthroughCanvasDemo() {
    guard let ticket = walkthroughTicket else { return }
    do {
      let file = try UICanvasDemo.install(supportDirectory: paths.supportDirectory, taskID: ticket.id)
      guard case .opened(let session) = try uiCanvasStore.open(
        file: file.path, taskID: ticket.id, title: UICanvasDemo.title, viewport: "desktop",
        reopen: true, agentName: "Demo")
      else { return }
      handleUICanvasChange(ticketID: ticket.id, key: session.key, event: "open", root: nil)
      walkthroughMessage = nil
    } catch {
      walkthroughMessage = "Could not open the demo canvas: \(error.localizedDescription)"
    }
  }

  func setManagedTerminal(_ app: ManagedTerminalApp) {
    guard config.wezTerm.applicationName != app.applicationName else { return }
    config.wezTerm.applicationName = app.applicationName
    if app == .wezTerm, let executable = SetupEnvironment.executable("wezterm") {
      config.wezTerm.executable = executable
    }
    persistConfiguration()
  }

  func refreshProviderAccounts(_ providers: [AgentProvider] = AgentProvider.allCases) async {
    for provider in providers where providerAccounts[provider] == nil {
      providerAccounts[provider] = .checking
    }
    await withTaskGroup(of: (AgentProvider, ProviderAccountState).self) { group in
      for provider in providers {
        group.addTask { [checkProviderAccount] in (provider, await checkProviderAccount(provider)) }
      }
      for await (provider, state) in group { providerAccounts[provider] = state }
    }
    await collectSignInOutcomes()
    if providers.contains(.codex), providerAccounts[.codex]?.isSignedIn == true,
       let catalog = await loadCodexCatalog() {
      codexCatalog = catalog
    }
  }

  var reportsSignInFailures: Bool { localState.reportsSignInFailures != false }

  func setReportsSignInFailures(_ enabled: Bool) {
    guard reportsSignInFailures != enabled else { return }
    localState.reportsSignInFailures = enabled
    persistLocalState()
  }

  /// Reads the result each finished sign-in window left behind. A success the
  /// status check does not confirm is a failure too, since the user is stuck.
  private func collectSignInOutcomes() async {
    for (provider, attempt) in signInAttempts {
      guard let outcome = attempt.outcome() else { continue }
      signInAttempts[provider] = nil
      signInStartedAt[provider] = nil
      attempt.remove()
      switch outcome {
      case .failed(127, _):
        continue // Not installed: the card offers Install instead.
      case .failed(let status, let errors):
        await reportSignInFailure(provider, exitStatus: status, errors: errors)
      case .succeeded:
        let state = await checkProviderAccount(provider)
        providerAccounts[provider] = state
        if !state.isSignedIn { await reportSignInFailure(provider, exitStatus: nil, errors: "") }
      }
    }
  }

  private func reportSignInFailure(_ provider: AgentProvider, exitStatus: Int32?, errors: String) async {
    let summary = "Sign-in to \(provider.displayName) did not finish"
      + (exitStatus.map { " (exit \($0))" } ?? "") + "."
    walkthroughMessage = summary + " Click Sign in to try again."
    guard reportsSignInFailures, reportedSignInFailures.insert(provider).inserted else { return }
    let state = providerAccounts[provider]
    let stateText = state.map { state in
      if case .failed(let reason) = state { return "\(state.label): \(reason)" }
      return state.label
    } ?? "not checked"
    let delivery = await fileSignInFailure(SignInFailureContext(
      provider: provider, exitStatus: exitStatus, errors: errors, accountState: stateText,
      terminal: config.wezTerm.terminalApp.displayName, environment: FeedbackDraft.environmentSummary))
    switch delivery {
    case .filed(let url):
      walkthroughMessage = summary + " The details were sent to the Focus Queue beta tracker (\(url.absoluteString)). Click Sign in to try again."
    case .openInBrowser(let url):
      NSWorkspace.shared.open(url)
      walkthroughMessage = summary + " A prefilled bug report opened in your browser: submit it to send us the details. Click Sign in to try again."
    }
  }

  /// No provider CLI is signed in, so the queue is covered by the sign-in gate.
  /// The walkthrough shows its own sign-in step instead.
  var requiresProviderSignIn: Bool {
    configurationIsLoaded && walkthrough == nil && !providerSignInDeferred
      && ProviderAccounts.signInRequired(providerAccounts)
  }

  var hasSignedInProvider: Bool { providerAccounts.values.contains(where: \.isSignedIn) }

  func continueWithoutVerifiedSignIn() {
    providerSignInDeferred = true
  }

  /// True while that provider's sign-in window is open, for up to two minutes.
  func isSigningIn(_ provider: AgentProvider) -> Bool {
    guard signInAttempts[provider] != nil, let started = signInStartedAt[provider] else { return false }
    return Date().timeIntervalSince(started) < 120
  }

  /// Signs the provider's CLI out on this Mac. The status check decides the
  /// result, because a CLI can exit cleanly and leave the account signed in.
  func signOut(from provider: AgentProvider) async {
    guard providersSigningOut.insert(provider).inserted else { return }
    defer { providersSigningOut.remove(provider) }
    let failure = await signOutProviderAccount(provider)
    let state = await checkProviderAccount(provider)
    providerAccounts[provider] = state
    walkthroughMessage = state == .signedOut
      ? "Signed out of \(provider.displayName)."
      : "Could not sign out of \(provider.displayName)" + (failure.map { ": \($0)" } ?? ".")
  }

  func signIn(to provider: AgentProvider) async {
    // Each click would otherwise open another window for the same sign-in.
    guard !isSigningIn(provider) else {
      walkthroughMessage = "Finish signing in to \(provider.displayName) in the window that is already open."
      return
    }
    signInAttempts.removeValue(forKey: provider)?.remove()
    let attempt = try? SignInAttempt(provider: provider, root: paths.supportDirectory)
    do {
      try await ProviderAccounts.openSignIn(provider, attempt: attempt, configuration: config.wezTerm)
      if let attempt {
        signInAttempts[provider] = attempt
        signInStartedAt[provider] = Date()
      }
      walkthroughMessage = "Finish signing in to \(provider.displayName) in \(config.wezTerm.terminalApp.displayName). This card updates when you're done."
    } catch {
      walkthroughMessage = error.localizedDescription
    }
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
      panelRestoreCount += 1
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
    if showsAllProjects {
      await reloadMergedDashboard()
      lastDashboardStamp = nil
      lastDashboardRead = nil
    } else if URL(fileURLWithPath: config.dashboardPath).standardizedFileURL == url.standardizedFileURL {
      dashboard = updated.document
      await captureDurableDashboard(updated.document)
      lastDashboardStamp = nil
      lastDashboardRead = nil
    }
    if try await taskContextStore.load(ticketID: ticketID) != nil {
      taskContexts[ticketID] = try await taskContextStore.setPinned(ticketID: ticketID, at: nil)
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
      lastDurableVolatileFlush = nil
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
    guard lastDurableState?.agentSessions != snapshot.agentSessions else { return }
    guard durableRetryAfter["state"].map({ $0 <= Date() }) ?? true else { return }
    do {
      let summary = try await durableLibrary.reconcile(state: snapshot, contexts: [])
      lastDurableState = snapshot
      recordDurableError(nil, scope: "state")
      recordImportWarnings(summary.warnings)
    } catch { recordDurableError(error, scope: "state") }
  }

  /// Meaningful changes reach history at once and heartbeats at the periodic
  /// flush. A bare `updatedAt` bump never does: idle tasks re-saved every few
  /// minutes added thousands of identical revisions to the manifest.
  static func needsDurableCapture(_ context: TaskContext, recorded: TaskContext?,
    flushVolatile: Bool) -> Bool {
    guard let recorded else { return true }
    guard recorded != context else { return false }
    if recorded.withoutVolatileFields != context.withoutVolatileFields { return true }
    var bumped = recorded
    bumped.updatedAt = context.updatedAt
    return flushVolatile && bumped != context
  }

  private func captureDurableContexts(_ contexts: [TaskContext]) async {
    // Heartbeats and `updatedAt` move on nearly every poll. Recording each
    // move rewrote the whole history manifest and added a revision per task
    // per minute, so volatile-only changes wait for a meaningful change or the
    // periodic flush.
    let now = Date()
    let flushVolatile = lastDurableVolatileFlush.map {
      now.timeIntervalSince($0) >= Self.durableVolatileFlushInterval
    } ?? true
    let changed = contexts.filter { context in
      Self.needsDurableCapture(context, recorded: lastDurableContexts[context.ticketID],
        flushVolatile: flushVolatile)
    }
    if changed.isEmpty, flushVolatile { lastDurableVolatileFlush = now }
    if !changed.isEmpty, durableRetryAfter["contexts"].map({ $0 <= Date() }) ?? true {
      do {
        let summary = try await durableLibrary.reconcile(contexts: changed)
        for context in changed { lastDurableContexts[context.ticketID] = context }
        if flushVolatile { lastDurableVolatileFlush = now }
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

  func setAutoArchiveStaleAgents(_ enabled: Bool) {
    guard config.autoArchiveStaleAgents != enabled else { return }
    config.autoArchiveStaleAgents = enabled
    persistConfiguration()
  }

  /// Off leaves escalation launch requests queued on disk until it is turned back on.
  func setAgentEscalationAutoLaunch(_ enabled: Bool) {
    guard config.agentEscalationAutoLaunch != enabled else { return }
    config.agentEscalationAutoLaunch = enabled
    persistConfiguration()
  }

  /// Active agent panes per tmux window tab; tmux layout reads it from config.json.
  var agentsPerWindow: Int { config.agentsPerWindow ?? TmuxPaneLayout.defaultMaximumPanes }

  func setAgentsPerWindow(_ count: Int) {
    let clamped = min(max(count, 1), 12)
    guard agentsPerWindow != clamped else { return }
    // Always explicit: a nil key would keep the previous value on disk.
    config.agentsPerWindow = clamped
    persistConfiguration()
  }

  /// Native prompt hooks extract durable project and task facts unless the user turned this off.
  var dataPlacementEnabled: Bool { config.dataPlacementEnabled != false }

  func setDataPlacementEnabled(_ enabled: Bool) {
    guard dataPlacementEnabled != enabled else { return }
    config.dataPlacementEnabled = enabled
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
    recordProgramLogChange(message, level: .error, category: category)
  }

  private func logChangedMessages(
    _ messages: [String: String], previous: [String: String], categoryPrefix: String
  ) {
    for (identifier, message) in messages where previous[identifier] != message {
      recordProgramLogChange(
        message,
        level: Self.logLevel(for: message),
        category: "\(categoryPrefix) \(identifier)"
      )
    }
  }

  func recordProgramLogChange(_ message: String, level: ProgramLogLevel, category: String) {
    guard !Self.programLogSkips(message) else { return }
    guard lastRecordedProgramLogMessages[category] != message else { return }
    lastRecordedProgramLogMessages[category] = message
    programLog.record(message, level: level, category: category)
  }

  static func programLogSkips(_ message: String) -> Bool {
    message.contains("is running and registered in tmux.")
  }

  private static func logLevel(for message: String) -> ProgramLogLevel {
    let normalized = message.lowercased()
    return ["could not", "failed", "error", "needs attention", "unavailable"]
      .contains(where: normalized.contains) ? .error : .info
  }

  private func runDailyReportFromChat(
    _ request: DailyReportRunRequest, conversation: QueueChatConversation
  ) {
    let priorReportID = dailyReport?.runID
    chatTasks[conversation] = Task { [weak self] in
      guard let self else { return }
      defer { self.finishChatTurn(conversation) }
      guard self.dailyReportRunHandler != nil else {
        self.appendChat(QueueChatMessage(
          role: .agent,
          text: "Daily report automation is unavailable in this app session."
        ), to: conversation)
        return
      }
      guard let report = await self.dispatchDailyReport(request) else {
        self.appendChat(QueueChatMessage(
          role: .agent,
          text: self.dailyReportRunMessage ?? "The requested daily report did not complete."
        ), to: conversation)
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
        self.appendChat(QueueChatMessage(
          role: .agent,
          text: self.dailyReportRunMessage ?? "The requested daily report did not complete."
        ), to: conversation)
        return
      }
      self.appendChat(QueueChatMessage(
        role: .agent,
        text: Self.dailyReportChatSummary(report)
      ), to: conversation)
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
      "\($0.platform.displayName): \($0.collectedCount) read, \($0.newCount) new, \($0.checkedCount) checked"
    }.joined(separator: "; ")
    let tokenCount = report.usage?.totalTokens.formatted() ?? "unavailable"
    var response = "\(report.summary)\n\n\(platformSummary). Exact token use: \(tokenCount)."
    if !report.errors.isEmpty {
      response += " Coverage was partial: \(report.errors.joined(separator: "; "))"
    }
    response += " Open the document button in the queue header for message and task links."
    return response
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

struct UICanvasRequest: Equatable {
  let id = UUID()
  let ticketID: String
  let key: String
}

/// The development-process step artifact a viewer document belongs to, with
/// the human's check-off state. Drives the document pane's review toggle.
struct DevelopmentArtifactReview: Equatable {
  let projectID: String
  let stepID: String
  let stepTitle: String
  let artifact: String
  let checked: Bool
}

/// The sign-off control the document viewer shows for a contract or its draft.
struct DevelopmentContractControl: Equatable {
  let projectID: String
  let role: AgentContractRole
  let isDraft: Bool
  let state: AgentContractState
  let lint: [AgentContractLintIssue]
}
