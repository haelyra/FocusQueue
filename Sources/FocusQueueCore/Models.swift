import Foundation

public enum QueueWindowPlacement: String, Codable, CaseIterable, Sendable {
  case upperLeft = "upper-left"
  case upperRight = "upper-right"
  case center
}

public enum QueueAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
  case light
  case dark

  public var id: String { rawValue }

  public var displayName: String {
    rawValue.capitalized
  }
}

public enum QueueAccentStyle: String, Codable, CaseIterable, Identifiable, Sendable {
  case muted
  case pastel
  case monochrome
  case vibrant

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .muted: "Muted"
    case .pastel: "Pastel"
    case .monochrome: "No Color"
    case .vibrant: "Vibrant"
    }
  }
}

public enum QueueMinimizationPreference: String, Codable, CaseIterable, Identifiable, Sendable {
  case dock
  case fq
  case topTask = "top-task"

  public var id: String { rawValue }
}

public struct DailyRoutine: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let url: String?
  public var projectID: String?

  public init(id: String, title: String, url: String? = nil, projectID: String? = nil) {
    self.id = id
    self.title = title
    self.url = url
    self.projectID = projectID
  }
}

public struct WezTermConfiguration: Codable, Equatable, Sendable {
  public var executable: String
  public var applicationName: String
  public var socketPath: String?

  public var cliEnvironment: [String: String]? {
    socketPath.map { ["WEZTERM_UNIX_SOCKET": $0] }
  }

  public init(executable: String, applicationName: String = "WezTerm", socketPath: String? = nil) {
    self.executable = executable
    self.applicationName = applicationName
    self.socketPath = socketPath
  }
}

public struct VerifierConfiguration: Codable, Equatable, Sendable {
  public var projectScopeID: String?
  public var enabled: Bool
  public var executable: String
  public var sessionName: String
  public var timeoutSeconds: Int
  public var maxTurns: Int
  public var contextDirectory: String?
  public var supportDirectory: String?
  /// Extra directories the chat sandbox may write (dashboards, config, state).
  public var writableDirectories: [String]?

  public init(
    enabled: Bool,
    executable: String,
    sessionName: String,
    timeoutSeconds: Int = 120,
    maxTurns: Int = 24,
    contextDirectory: String? = nil,
    supportDirectory: String? = nil,
    writableDirectories: [String]? = nil
  ) {
    self.enabled = enabled
    self.executable = executable
    self.sessionName = sessionName
    self.timeoutSeconds = timeoutSeconds
    self.maxTurns = maxTurns
    self.contextDirectory = contextDirectory
    self.supportDirectory = supportDirectory
    self.writableDirectories = writableDirectories
  }
}

public enum DailyReportPlatform: String, Codable, CaseIterable, Identifiable, Sendable {
  case discord
  case telegram
  case email
  case github
  case gmail
  case slack

  /// Sources a report reads when nothing is configured. Gmail and Slack need
  /// credentials first; enabling them unconfigured makes every report partial.
  public static let defaultEnabled: [DailyReportPlatform] = [.discord, .telegram, .email, .github]

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .discord: "Discord"
    case .telegram: "Telegram"
    case .email: "Mail"
    case .github: "GitHub"
    case .gmail: "Gmail"
    case .slack: "Slack"
    }
  }
}

public struct DailyReportConfiguration: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var scheduleHour: Int
  public var scheduleMinute: Int
  public var maximumTokens: Int
  public var enabledPlatforms: [DailyReportPlatform]
  /// An explicit sweep provider; nil follows the default agent provider.
  public var agentProvider: AgentProvider?
  public var agentModel: String?
  public var agentEffort: String?

  public init(
    enabled: Bool = true,
    scheduleHour: Int = 8,
    scheduleMinute: Int = 0,
    maximumTokens: Int = 75_000,
    enabledPlatforms: [DailyReportPlatform] = DailyReportPlatform.defaultEnabled,
    agentProvider: AgentProvider? = nil,
    agentModel: String? = nil,
    agentEffort: String? = nil
  ) {
    self.enabled = enabled
    self.scheduleHour = scheduleHour
    self.scheduleMinute = scheduleMinute
    self.maximumTokens = maximumTokens
    self.enabledPlatforms = enabledPlatforms
    self.agentProvider = agentProvider
    self.agentModel = agentModel
    self.agentEffort = agentEffort
  }

  private enum CodingKeys: String, CodingKey {
    case enabled, scheduleHour, scheduleMinute, maximumTokens, enabledPlatforms
    case agentProvider, agentModel, agentEffort
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    scheduleHour = try container.decodeIfPresent(Int.self, forKey: .scheduleHour) ?? 8
    scheduleMinute = try container.decodeIfPresent(Int.self, forKey: .scheduleMinute) ?? 0
    maximumTokens = try container.decodeIfPresent(Int.self, forKey: .maximumTokens) ?? 75_000
    enabledPlatforms =
      try container.decodeIfPresent([DailyReportPlatform].self, forKey: .enabledPlatforms)
      ?? DailyReportPlatform.defaultEnabled
    agentProvider = try container.decodeIfPresent(String.self, forKey: .agentProvider)
      .flatMap { AgentProvider(rawValue: $0.lowercased()) }
    agentModel = try container.decodeIfPresent(String.self, forKey: .agentModel)
    agentEffort = try container.decodeIfPresent(String.self, forKey: .agentEffort)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(enabled, forKey: .enabled)
    try container.encode(scheduleHour, forKey: .scheduleHour)
    try container.encode(scheduleMinute, forKey: .scheduleMinute)
    try container.encode(maximumTokens, forKey: .maximumTokens)
    try container.encode(enabledPlatforms, forKey: .enabledPlatforms)
    try container.encodeIfPresent(agentProvider?.rawValue, forKey: .agentProvider)
    try container.encodeIfPresent(agentModel, forKey: .agentModel)
    try container.encodeIfPresent(agentEffort, forKey: .agentEffort)
  }
}

public struct ProjectConfiguration: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var dashboardPath: String
  public var workspacePath: String
  public var taskPrefix: String
  public var repositoryPath: String
  public var remote: String?
  public var remoteAliases: [String]
  public var archivedAt: Date?

  public init(
    id: String, name: String, dashboardPath: String, workspacePath: String,
    taskPrefix: String? = nil, repositoryPath: String? = nil,
    remote: String? = nil, remoteAliases: [String] = [], archivedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.dashboardPath = dashboardPath
    self.workspacePath = workspacePath
    self.taskPrefix = (taskPrefix ?? ProjectCatalog.suggestedPrefix(name: name, id: id)).uppercased()
    self.repositoryPath = repositoryPath ?? Self.inferredRepositoryPath(workspacePath)
    self.remote = remote
    self.remoteAliases = remoteAliases
    self.archivedAt = archivedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, dashboardPath, workspacePath, taskPrefix, repositoryPath
    case remote, remoteAliases, archivedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    dashboardPath = try container.decode(String.self, forKey: .dashboardPath)
    workspacePath = try container.decode(String.self, forKey: .workspacePath)
    taskPrefix = (try container.decodeIfPresent(String.self, forKey: .taskPrefix)
      ?? ProjectCatalog.suggestedPrefix(name: name, id: id)).uppercased()
    repositoryPath = try container.decodeIfPresent(String.self, forKey: .repositoryPath)
      ?? Self.inferredRepositoryPath(workspacePath)
    remote = try container.decodeIfPresent(String.self, forKey: .remote)
    remoteAliases = try container.decodeIfPresent([String].self, forKey: .remoteAliases) ?? []
    archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
  }

  private static func inferredRepositoryPath(_ workspacePath: String) -> String {
    let gitEntry = URL(fileURLWithPath: workspacePath, isDirectory: true)
      .appendingPathComponent(".git")
    return FileManager.default.fileExists(atPath: gitEntry.path) ? workspacePath : ""
  }
}

private struct LegacyProjectConfigurationShape: Decodable {
  var dashboardPath: String?
  var workspacePath: String?
  var repositoryPath: String?
}

/// One entry in the New Agent provider/model menu. A nil or empty model
/// launches the provider without a `--model` argument (the provider default).
public struct AgentModelChoice: Codable, Equatable, Sendable, Identifiable {
  public var provider: AgentProvider
  public var label: String
  public var model: String?
  public var effort: String?

  public init(provider: AgentProvider, label: String, model: String? = nil, effort: String? = nil) {
    self.provider = provider
    self.label = label
    self.model = model
    self.effort = effort
  }

  public var id: String { "\(provider.rawValue)/\(label)" }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
  public var appName: String
  public var dashboardPath: String {
    didSet { alignSelectedProjectWithLegacyPaths() }
  }
  public var workspacePath: String {
    didSet { alignSelectedProjectWithLegacyPaths(previousWorkspacePath: oldValue) }
  }
  public var defaultPlacement: QueueWindowPlacement
  public var refreshIntervalSeconds: Int
  public var dailyRoutines: [DailyRoutine]
  public var wezTerm: WezTermConfiguration
  public var verifier: VerifierConfiguration
  public var dailyReport: DailyReportConfiguration
  public var projects: [ProjectConfiguration] {
    didSet {
      if selectedProjectID == nil || !projects.contains(where: { $0.id == selectedProjectID }) {
        selectedProjectID = projects.first?.id
      }
    }
  }
  public var selectedProjectID: String? {
    didSet { alignLegacyPathsWithSelection() }
  }
  public var persistentTerminals: Bool?
  public var tmuxExecutable: String?
  public var setupCompleted: Bool?
  public var automaticAgentRouting: Bool
  public var completionReviewEnabled: Bool
  public var autoExitCompletedAgents: Bool
  public var agentUsageBarEnabled: Bool
  public var agentProviderFallbackOrder: [AgentProvider]
  public var agentEscalationAutoLaunch: Bool
  /// Maximum active agent panes per tmux window tab; nil keeps the default of 4.
  public var agentsPerWindow: Int?
  /// Runs the small-model placement call for `fq` launches; nil keeps it on.
  public var placementModelEnabled: Bool?
  /// Provider that runs the placement call; nil uses the launched provider.
  public var placementProvider: AgentProvider?
  /// Per-provider placement models; a missing value uses `defaultPlacementModels`.
  public var placementModels: [AgentProvider: String]
  /// Per-provider placement efforts; a missing value uses `defaultPlacementEfforts`.
  public var placementEfforts: [AgentProvider: String]
  /// Minimum model confidence to join an existing task; below it a new task is created.
  public var placementConfidenceThreshold: Double?
  /// Seconds the placement call may take before `fq` falls back to heuristics.
  public var placementTimeoutSeconds: Int?

  public static let defaultAgentProviderFallbackOrder: [AgentProvider] = [.codex, .claude]
  public var agentModelChoices: [AgentModelChoice]
  public var autoArchiveStaleAgents: Bool
  /// An explicit default provider; nil keeps the legacy fallback-order default.
  public var defaultAgentProvider: AgentProvider?
  /// Per-provider default models; a missing or empty value launches without `--model`.
  public var defaultAgentModels: [AgentProvider: String]
  /// Per-provider default efforts; a missing or empty value launches without an effort flag.
  public var defaultAgentEfforts: [AgentProvider: String]
  /// Chat harness executable overrides; Codex chat keeps using `verifier.executable`.
  public var claudeChatExecutable: String?
  public var kimiChatExecutable: String?

  /// Newest models first within each provider group. Mirrors the current
  /// Codex, Claude Code, and Kimi Code lineups (Kimi aliases match the managed
  /// `kimi provider list` entries).
  public static let defaultAgentModelChoices: [AgentModelChoice] = [
    AgentModelChoice(provider: .codex, label: "Default"),
    AgentModelChoice(provider: .codex, label: "gpt-6-astra", model: "gpt-6-astra"),
    AgentModelChoice(provider: .codex, label: "gpt-6-sol", model: "gpt-6-sol"),
    AgentModelChoice(provider: .codex, label: "gpt-6-luna", model: "gpt-6-luna"),
    AgentModelChoice(provider: .codex, label: "gpt-5.6-sol", model: "gpt-5.6-sol"),
    AgentModelChoice(provider: .codex, label: "gpt-5.6-terra", model: "gpt-5.6-terra"),
    AgentModelChoice(provider: .codex, label: "gpt-5.6-luna", model: "gpt-5.6-luna"),
    AgentModelChoice(provider: .codex, label: "gpt-5.5-pro", model: "gpt-5.5-pro"),
    AgentModelChoice(provider: .codex, label: "gpt-5.5", model: "gpt-5.5"),
    AgentModelChoice(provider: .codex, label: "gpt-5.4", model: "gpt-5.4"),
    AgentModelChoice(provider: .codex, label: "gpt-5.2", model: "gpt-5.2"),
    AgentModelChoice(provider: .claude, label: "Default"),
    AgentModelChoice(provider: .claude, label: "opus-5.5", model: "claude-opus-5-5"),
    AgentModelChoice(provider: .claude, label: "sonnet-5.5", model: "claude-sonnet-5-5"),
    AgentModelChoice(provider: .claude, label: "opus-5", model: "claude-opus-5"),
    AgentModelChoice(provider: .claude, label: "sonnet-5", model: "claude-sonnet-5"),
    AgentModelChoice(provider: .claude, label: "haiku-4.5", model: "claude-haiku-4-5"),
    AgentModelChoice(provider: .claude, label: "opus", model: "opus"),
    AgentModelChoice(provider: .claude, label: "sonnet", model: "sonnet"),
    AgentModelChoice(provider: .claude, label: "haiku", model: "haiku"),
    AgentModelChoice(provider: .kimi, label: "Default"),
    AgentModelChoice(provider: .kimi, label: "K3", model: "kimi-code/k3"),
    AgentModelChoice(provider: .kimi, label: "K3-256k", model: "kimi-code/k3-256k"),
    AgentModelChoice(provider: .kimi, label: "K2.8 Preview", model: "kimi-code/kimi-for-coding"),
    AgentModelChoice(provider: .kimi, label: "K2.7 Code Highspeed", model: "kimi-code/kimi-for-coding-highspeed"),
  ]

  /// Built-in choices lead in newest-first order; configured entries whose
  /// provider/label pair is not built in keep their place afterward, so older
  /// configs gain new providers and models without losing custom entries.
  public static func mergedAgentModelChoices(_ configured: [AgentModelChoice]) -> [AgentModelChoice] {
    let defaults = Self.defaultAgentModelChoices
    let builtInIDs = Set(defaults.map(\.id))
    return defaults + configured.filter { !builtInIDs.contains($0.id) }
  }

  /// Effort levels accepted by agent launches (Codex `model_reasoning_effort`,
  /// Claude `--effort`). Kimi has no launch-time effort flag and ignores these.
  public static let agentEffortLevels = ["low", "medium", "high", "xhigh", "max"]

  /// The fastest subscription model per provider. Keep in sync with
  /// `DEFAULT_MODELS` in Scripts/focus_queue_placement.py.
  public static let defaultPlacementModels: [AgentProvider: String] = [
    .claude: "haiku", .codex: "gpt-6-luna", .kimi: "kimi-code/kimi-for-coding-highspeed",
  ]
  public static let defaultPlacementEfforts: [AgentProvider: String] = [.claude: "low", .codex: "low"]
  public static let defaultPlacementConfidenceThreshold = 0.85
  public static let defaultPlacementTimeoutSeconds = 20

  public func placementModel(for provider: AgentProvider) -> String? {
    placementModels[provider] ?? Self.defaultPlacementModels[provider]
  }

  /// Kimi has no effort flag, so it never reports one.
  public func placementEffort(for provider: AgentProvider) -> String? {
    guard provider != .kimi else { return nil }
    return placementEfforts[provider] ?? Self.defaultPlacementEfforts[provider]
  }

  /// The chat harness for a provider. Codex reuses the verifier harness;
  /// Claude and Kimi fall back to their managed `~/.local/bin` launchers.
  public func chatExecutable(for provider: AgentProvider) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    switch provider {
    case .codex: return verifier.executable
    case .claude: return claudeChatExecutable ?? "\(home)/.local/bin/focus-queue-claude"
    case .kimi: return kimiChatExecutable ?? "\(home)/.local/bin/focus-queue-kimi"
    }
  }

  public init(
    appName: String,
    dashboardPath: String,
    workspacePath: String,
    defaultPlacement: QueueWindowPlacement,
    refreshIntervalSeconds: Int,
    dailyRoutines: [DailyRoutine],
    wezTerm: WezTermConfiguration,
    verifier: VerifierConfiguration,
    dailyReport: DailyReportConfiguration = DailyReportConfiguration(),
    projects: [ProjectConfiguration]? = nil,
    selectedProjectID: String? = nil
  ) {
    self.appName = appName
    self.dashboardPath = dashboardPath
    self.workspacePath = workspacePath
    self.defaultPlacement = defaultPlacement
    self.refreshIntervalSeconds = refreshIntervalSeconds
    self.dailyRoutines = dailyRoutines
    self.wezTerm = wezTerm
    self.verifier = verifier
    self.dailyReport = dailyReport
    self.automaticAgentRouting = false
    self.completionReviewEnabled = true
    self.autoExitCompletedAgents = true
    self.agentUsageBarEnabled = true
    self.agentProviderFallbackOrder = Self.defaultAgentProviderFallbackOrder
    self.agentEscalationAutoLaunch = true
    self.agentsPerWindow = nil
    self.placementModelEnabled = nil
    self.placementProvider = nil
    self.placementModels = [:]
    self.placementEfforts = [:]
    self.placementConfidenceThreshold = nil
    self.placementTimeoutSeconds = nil
    self.agentModelChoices = Self.defaultAgentModelChoices
    self.autoArchiveStaleAgents = false
    self.defaultAgentProvider = nil
    self.defaultAgentModels = [:]
    self.defaultAgentEfforts = [:]
    self.claudeChatExecutable = nil
    self.kimiChatExecutable = nil
    let effectiveProjects = projects ?? [Self.legacyProject(
      appName: appName,
      dashboardPath: dashboardPath,
      workspacePath: workspacePath
    )]
    self.projects = effectiveProjects
    self.selectedProjectID = selectedProjectID ?? effectiveProjects.first?.id
    alignLegacyPathsWithSelection()
  }

  private enum CodingKeys: String, CodingKey {
    case appName, dashboardPath, workspacePath, defaultPlacement, refreshIntervalSeconds
    case dailyRoutines, wezTerm, verifier, dailyReport, persistentTerminals, tmuxExecutable, setupCompleted
    case automaticAgentRouting
    case completionReviewEnabled
    case autoExitCompletedAgents
    case agentUsageBarEnabled
    case agentProviderFallbackOrder
    case agentEscalationAutoLaunch
    case agentsPerWindow
    case placementModelEnabled, placementProvider, placementModels, placementEfforts
    case placementConfidenceThreshold, placementTimeoutSeconds
    case agentModelChoices
    case autoArchiveStaleAgents
    case defaultAgentProvider, defaultAgentModels, defaultAgentEfforts
    case claudeChatExecutable, kimiChatExecutable
    case focusQueueProjects, focusQueueSelectedProjectID, projects, selectedProjectID
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    appName = try container.decode(String.self, forKey: .appName)
    dashboardPath = try container.decode(String.self, forKey: .dashboardPath)
    workspacePath = try container.decode(String.self, forKey: .workspacePath)
    defaultPlacement = try container.decode(QueueWindowPlacement.self, forKey: .defaultPlacement)
    refreshIntervalSeconds = try container.decode(Int.self, forKey: .refreshIntervalSeconds)
    dailyRoutines = try container.decode([DailyRoutine].self, forKey: .dailyRoutines)
    wezTerm = try container.decode(WezTermConfiguration.self, forKey: .wezTerm)
    verifier = try container.decode(VerifierConfiguration.self, forKey: .verifier)
    persistentTerminals = try container.decodeIfPresent(Bool.self, forKey: .persistentTerminals)
    tmuxExecutable = try container.decodeIfPresent(String.self, forKey: .tmuxExecutable)
    setupCompleted = try container.decodeIfPresent(Bool.self, forKey: .setupCompleted)
    automaticAgentRouting = try container.decodeIfPresent(Bool.self, forKey: .automaticAgentRouting) ?? false
    completionReviewEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .completionReviewEnabled) ?? true
    autoExitCompletedAgents = try container.decodeIfPresent(Bool.self, forKey: .autoExitCompletedAgents) ?? true
    agentUsageBarEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentUsageBarEnabled) ?? true
    // Unknown providers (for example from a newer build) are skipped, never fatal.
    var seenProviders = Set<AgentProvider>()
    let fallbackOrder = (try container.decodeIfPresent([String].self, forKey: .agentProviderFallbackOrder) ?? [])
      .compactMap { AgentProvider(rawValue: $0.lowercased()) }
      .filter { seenProviders.insert($0).inserted }
    agentProviderFallbackOrder = fallbackOrder.isEmpty ? Self.defaultAgentProviderFallbackOrder : fallbackOrder
    agentEscalationAutoLaunch =
      try container.decodeIfPresent(Bool.self, forKey: .agentEscalationAutoLaunch) ?? true
    agentsPerWindow = try container.decodeIfPresent(Int.self, forKey: .agentsPerWindow)
    placementModelEnabled = try container.decodeIfPresent(Bool.self, forKey: .placementModelEnabled)
    placementProvider = try container.decodeIfPresent(String.self, forKey: .placementProvider)
      .flatMap { AgentProvider(rawValue: $0.lowercased()) }
    placementModels = Self.providerValues(
      try container.decodeIfPresent([String: String].self, forKey: .placementModels))
    placementEfforts = Self.providerValues(
      try container.decodeIfPresent([String: String].self, forKey: .placementEfforts))
    placementConfidenceThreshold =
      try container.decodeIfPresent(Double.self, forKey: .placementConfidenceThreshold)
    placementTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .placementTimeoutSeconds)
    agentModelChoices = Self.mergedAgentModelChoices(
      (try container.decodeIfPresent([AgentModelChoice].self, forKey: .agentModelChoices)) ?? [])
    autoArchiveStaleAgents = try container.decodeIfPresent(Bool.self, forKey: .autoArchiveStaleAgents) ?? false
    defaultAgentProvider = try container.decodeIfPresent(String.self, forKey: .defaultAgentProvider)
      .flatMap { AgentProvider(rawValue: $0.lowercased()) }
    defaultAgentModels = Self.providerValues(
      try container.decodeIfPresent([String: String].self, forKey: .defaultAgentModels))
    defaultAgentEfforts = Self.providerValues(
      try container.decodeIfPresent([String: String].self, forKey: .defaultAgentEfforts))
    claudeChatExecutable = try container.decodeIfPresent(String.self, forKey: .claudeChatExecutable)
    kimiChatExecutable = try container.decodeIfPresent(String.self, forKey: .kimiChatExecutable)
    dailyReport =
      try container.decodeIfPresent(DailyReportConfiguration.self, forKey: .dailyReport)
      ?? DailyReportConfiguration()
    if let configuredProjects =
      try container.decodeIfPresent([ProjectConfiguration].self, forKey: .focusQueueProjects)
    {
      projects = configuredProjects
      let requestedProjectID =
        try container.decodeIfPresent(String.self, forKey: .focusQueueSelectedProjectID)
      selectedProjectID = requestedProjectID.flatMap { requested in
        projects.contains(where: { $0.id == requested }) ? requested : nil
      } ?? projects.first?.id
    } else {
      let legacyShapes =
        try container.decodeIfPresent([LegacyProjectConfigurationShape].self, forKey: .projects)
        ?? []
      let isRepositoryCatalog = !legacyShapes.isEmpty && legacyShapes.allSatisfy {
        $0.repositoryPath != nil && $0.dashboardPath == nil && $0.workspacePath == nil
      }
      if !legacyShapes.isEmpty && !isRepositoryCatalog {
        projects = try container.decode([ProjectConfiguration].self, forKey: .projects)
      } else {
        projects = []
      }
      let requestedProjectID =
        try container.decodeIfPresent(String.self, forKey: .focusQueueSelectedProjectID)
        ?? (!legacyShapes.isEmpty && !isRepositoryCatalog
          ? try container.decodeIfPresent(String.self, forKey: .selectedProjectID)
          : nil)
      selectedProjectID = requestedProjectID.flatMap { requested in
        projects.contains(where: { $0.id == requested }) ? requested : nil
      } ?? projects.first?.id
    }
    if projects.isEmpty {
      projects = [Self.legacyProject(
        appName: appName,
        dashboardPath: dashboardPath,
        workspacePath: workspacePath
      )]
      selectedProjectID = projects.first?.id
    }
    alignLegacyPathsWithSelection()
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    let effectiveProject = selectedProject
    try container.encode(appName, forKey: .appName)
    try container.encode(effectiveProject?.dashboardPath ?? dashboardPath, forKey: .dashboardPath)
    try container.encode(effectiveProject?.workspacePath ?? workspacePath, forKey: .workspacePath)
    try container.encode(defaultPlacement, forKey: .defaultPlacement)
    try container.encode(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
    try container.encode(dailyRoutines, forKey: .dailyRoutines)
    try container.encode(wezTerm, forKey: .wezTerm)
    try container.encode(verifier, forKey: .verifier)
    try container.encode(dailyReport, forKey: .dailyReport)
    try container.encode(projects, forKey: .focusQueueProjects)
    try container.encodeIfPresent(selectedProjectID, forKey: .focusQueueSelectedProjectID)
    try container.encodeIfPresent(persistentTerminals, forKey: .persistentTerminals)
    try container.encodeIfPresent(tmuxExecutable, forKey: .tmuxExecutable)
    try container.encodeIfPresent(setupCompleted, forKey: .setupCompleted)
    try container.encode(automaticAgentRouting, forKey: .automaticAgentRouting)
    try container.encode(completionReviewEnabled, forKey: .completionReviewEnabled)
    try container.encode(autoExitCompletedAgents, forKey: .autoExitCompletedAgents)
    try container.encode(agentUsageBarEnabled, forKey: .agentUsageBarEnabled)
    try container.encode(agentProviderFallbackOrder, forKey: .agentProviderFallbackOrder)
    try container.encode(agentEscalationAutoLaunch, forKey: .agentEscalationAutoLaunch)
    try container.encodeIfPresent(agentsPerWindow, forKey: .agentsPerWindow)
    try container.encodeIfPresent(placementModelEnabled, forKey: .placementModelEnabled)
    try container.encodeIfPresent(placementProvider, forKey: .placementProvider)
    try container.encode(Self.rawProviderValues(placementModels), forKey: .placementModels)
    try container.encode(Self.rawProviderValues(placementEfforts), forKey: .placementEfforts)
    try container.encodeIfPresent(placementConfidenceThreshold, forKey: .placementConfidenceThreshold)
    try container.encodeIfPresent(placementTimeoutSeconds, forKey: .placementTimeoutSeconds)
    try container.encode(agentModelChoices, forKey: .agentModelChoices)
    try container.encode(autoArchiveStaleAgents, forKey: .autoArchiveStaleAgents)
    try container.encodeIfPresent(defaultAgentProvider, forKey: .defaultAgentProvider)
    try container.encode(Self.rawProviderValues(defaultAgentModels), forKey: .defaultAgentModels)
    try container.encode(Self.rawProviderValues(defaultAgentEfforts), forKey: .defaultAgentEfforts)
    try container.encodeIfPresent(claudeChatExecutable, forKey: .claudeChatExecutable)
    try container.encodeIfPresent(kimiChatExecutable, forKey: .kimiChatExecutable)
  }

  /// Unknown providers (for example from a newer build) and blank values are skipped.
  private static func providerValues(_ raw: [String: String]?) -> [AgentProvider: String] {
    (raw ?? [:]).reduce(into: [:]) { values, pair in
      guard let provider = AgentProvider(rawValue: pair.key.lowercased()) else { return }
      let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { values[provider] = value }
    }
  }

  private static func rawProviderValues(_ values: [AgentProvider: String]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
  }

  public var selectedProject: ProjectConfiguration? {
    guard let selectedProjectID else { return nil }
    return projects.first { $0.id == selectedProjectID }
  }

  @discardableResult
  public mutating func selectProject(id: String) -> Bool {
    guard projects.contains(where: { $0.id == id }) else { return false }
    selectedProjectID = id
    return true
  }

  private mutating func alignLegacyPathsWithSelection() {
    guard let selectedProject else { return }
    dashboardPath = selectedProject.dashboardPath
    workspacePath = selectedProject.workspacePath
  }

  private mutating func alignSelectedProjectWithLegacyPaths(
    previousWorkspacePath: String? = nil
  ) {
    guard let selectedProjectID,
      let index = projects.firstIndex(where: { $0.id == selectedProjectID })
    else { return }
    if let previousWorkspacePath,
      projects[index].repositoryPath == previousWorkspacePath
    {
      projects[index].repositoryPath = workspacePath
    }
    projects[index].dashboardPath = dashboardPath
    projects[index].workspacePath = workspacePath
  }

  private static func legacyProject(
    appName: String,
    dashboardPath: String,
    workspacePath: String
  ) -> ProjectConfiguration {
    let workspaceName = URL(fileURLWithPath: workspacePath).lastPathComponent
    let name = workspaceName.isEmpty ? appName : workspaceName
    let slug = name.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: "-")
    return ProjectConfiguration(
      id: slug.isEmpty ? "default" : slug,
      name: name,
      dashboardPath: dashboardPath,
      workspacePath: workspacePath
    )
  }

  public static func eccDefault(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Self {
    let home = homeDirectory.path
    let workspace = "\(home)/Documents/ECC"
    return Self(
      appName: "Focus Queue",
      dashboardPath: "\(workspace)/ecc-dashboard/data/dashboard.json",
      workspacePath: workspace,
      defaultPlacement: .upperLeft,
      refreshIntervalSeconds: 2,
      dailyRoutines: [
        DailyRoutine(
          id: "review-prs",
          title: "Review the open pull-request queue",
          url: "https://github.com/affaan-m/ECC/pulls"
        ),
        DailyRoutine(
          id: "triage-issues",
          title: "Triage the open issue queue",
          url: "https://github.com/affaan-m/ECC/issues"
        ),
        DailyRoutine(id: "respond-discord", title: "Check and respond in Discord"),
        DailyRoutine(id: "agent-followups", title: "Review agent and maintainer follow-ups"),
      ],
      wezTerm: WezTermConfiguration(executable: "\(home)/.local/bin/wezterm"),
      verifier: VerifierConfiguration(
        enabled: true,
        executable: "\(home)/.local/bin/focus-queue-codex",
        sessionName: "ecc-focus-queue-codex-verifier"
      )
    )
  }

  public func validated() throws -> Self {
    guard dashboardPath.hasPrefix("/"), workspacePath.hasPrefix("/") else {
      throw ConfigurationError.pathsMustBeAbsolute
    }
    guard (1...300).contains(refreshIntervalSeconds) else {
      throw ConfigurationError.invalidRefreshInterval
    }
    guard !projects.isEmpty,
      projects.allSatisfy({
        !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && $0.dashboardPath.hasPrefix("/")
          && $0.workspacePath.hasPrefix("/")
      })
    else {
      throw ConfigurationError.invalidProject
    }
    guard Set(projects.map { $0.id.lowercased() }).count == projects.count else {
      throw ConfigurationError.duplicateProjectID
    }
    try ProjectCatalog.validate(projects)
    guard let selectedProjectID,
      projects.contains(where: { $0.id == selectedProjectID })
    else {
      throw ConfigurationError.invalidSelectedProject
    }
    if persistentTerminals == true, tmuxExecutable?.hasPrefix("/") != true {
      throw ConfigurationError.invalidTerminalSettings
    }
    guard (10...900).contains(verifier.timeoutSeconds), (1...100).contains(verifier.maxTurns) else {
      throw ConfigurationError.invalidVerifierBudget
    }
    guard (0...23).contains(dailyReport.scheduleHour),
      (0...59).contains(dailyReport.scheduleMinute),
      (10_000...1_000_000).contains(dailyReport.maximumTokens),
      !dailyReport.enabledPlatforms.isEmpty,
      Set(dailyReport.enabledPlatforms).count == dailyReport.enabledPlatforms.count
    else {
      throw ConfigurationError.invalidDailyReportSettings
    }
    return self
  }
}

public enum ConfigurationError: Error, LocalizedError, Equatable {
  case pathsMustBeAbsolute
  case invalidRefreshInterval
  case invalidVerifierBudget
  case invalidDailyReportSettings
  case invalidTerminalSettings
  case invalidProject
  case duplicateProjectID
  case invalidSelectedProject

  public var errorDescription: String? {
    switch self {
    case .pathsMustBeAbsolute:
      "Dashboard and workspace paths must be absolute."
    case .invalidRefreshInterval:
      "Refresh interval must be between 1 and 300 seconds."
    case .invalidVerifierBudget:
      "Agent timeout or turn budget is outside the supported range."
    case .invalidDailyReportSettings:
      "Daily report time, token target, or enabled platforms are invalid."
    case .invalidTerminalSettings:
      "Persistent terminals require an absolute path to the tmux executable."
    case .invalidProject:
      "Projects require a name, identifier, and absolute dashboard and workspace paths."
    case .duplicateProjectID:
      "Project identifiers must be unique."
    case .invalidSelectedProject:
      "The selected project must refer to a configured project."
    }
  }
}

public enum DailyReportTrigger: String, Codable, Equatable, Sendable {
  case scheduled
  case manual
  case chat
}

public struct DailyReportRunRequest: Equatable, Sendable {
  public let trigger: DailyReportTrigger
  public let platforms: [DailyReportPlatform]
  public let comprehensive: Bool
  public let recheck: Bool
  /// Resolved sweep agent selection; nil follows the configured daily-report or
  /// default provider settings at run time.
  public let agentProvider: AgentProvider?
  public let agentModel: String?
  public let agentEffort: String?

  public init(
    trigger: DailyReportTrigger,
    platforms: [DailyReportPlatform],
    comprehensive: Bool,
    recheck: Bool,
    agentProvider: AgentProvider? = nil,
    agentModel: String? = nil,
    agentEffort: String? = nil
  ) {
    self.trigger = trigger
    self.platforms = platforms
    self.comprehensive = comprehensive
    self.recheck = recheck
    self.agentProvider = agentProvider
    self.agentModel = agentModel
    self.agentEffort = agentEffort
  }
}

public enum DailyReportChatCommand {
  public static func parse(
    _ message: String,
    enabledPlatforms: [DailyReportPlatform]
  ) -> DailyReportRunRequest? {
    var command = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .replacingOccurrences(of: "’", with: "'")
    let politePrefixes = ["please ", "can you ", "could you ", "would you "]
    var removedPrefix = true
    while removedPrefix {
      removedPrefix = false
      for prefix in politePrefixes where command.hasPrefix(prefix) {
        command.removeFirst(prefix.count)
        command = command.trimmingCharacters(in: .whitespaces)
        removedPrefix = true
        break
      }
    }

    let reportPhrases = [
      "daily report", "daily message report", "daily update report",
      "daily message and update report", "message report", "focus report", "focus queue report",
    ]
    let escapedPhrases = reportPhrases.map(NSRegularExpression.escapedPattern).joined(separator: "|")
    let directReportAction = command.range(
      of: "^(?:run|generate|create|update)\\s+(?:(?:the|my|a)\\s+)?(?:comprehensive\\s+)?(?:\(escapedPhrases))\\b",
      options: .regularExpression
    ) != nil
    let directComprehensiveAction = command.range(
      of: "^(?:run|generate|create|update)\\s+(?:(?:the|my|a)\\s+)?comprehensive\\s+report\\b",
      options: .regularExpression
    ) != nil
    let platformCheckAction = command.range(
      of: "^(?:check|scan)\\s+.+\\s+for\\s+(?:(?:the|my|a)\\s+)?(?:\(escapedPhrases))\\b",
      options: .regularExpression
    ) != nil
    guard directReportAction || directComprehensiveAction || platformCheckAction else {
      return nil
    }

    let requested = DailyReportPlatform.allCases.filter { platform in
      switch platform {
      case .email:
        return containsWord("email", in: command) || containsWord("mail", in: command)
      default:
        return containsWord(platform.rawValue, in: command)
      }
    }
    let rejectsAll = command.range(
      of: "\\b(?:not|without)\\s+(?:all|every|comprehensive)\\b|\\b(?:not|without)\\s+(?:all|every)\\s+platforms?\\b",
      options: .regularExpression
    ) != nil
    let asksForAll = !rejectsAll && command.range(
      of: "\\b(?:all|every)\\s+platforms?\\b|\\bcomprehensive\\b",
      options: .regularExpression
    ) != nil
    let hasPlatformExclusion = command.range(
      of: "\\b(?:except|excluding|exclude)\\b[^.!?]{0,80}\\b(?:discord|telegram|email|mail|github|gmail|slack)\\b|\\b(?:without|not)\\s+(?:discord|telegram|email|mail|github|gmail|slack)\\b|\\b(?:do\\s+not|don't|dont|with\\s+no|no)\\s+(?:(?:check|scan)\\s+)?(?:discord|telegram|email|mail|github|gmail|slack)\\b",
      options: .regularExpression
    ) != nil
    guard !hasPlatformExclusion, !(rejectsAll && requested.isEmpty) else { return nil }
    let hasUnsupportedTarget = command.range(
      of: "\\b(?:for|on|using|via)\\s+",
      options: .regularExpression
    ) != nil
      && requested.isEmpty
      && !asksForAll
      && command.range(
        of: "\\bfor\\s+(?:today|now|this\\s+(?:morning|afternoon|evening))\\b",
        options: .regularExpression
      ) == nil
    let hasNamedUnsupportedPlatform = command.range(
      of: "\\b(?:microsoft\\s+teams|teams|whatsapp|signal|imessage|sms|outlook)\\b",
      options: .regularExpression
    ) != nil
    guard !hasUnsupportedTarget, !hasNamedUnsupportedPlatform else { return nil }
    let comprehensive = requested.isEmpty || asksForAll
    let requestsRecheck = command.range(
      of: "\\brecheck(?:ing)?\\b|\\breprocess(?:ing)?\\b|\\bcheck(?:ing)?(?:\\s+them)?\\s+again\\b|\\binclud(?:e|ing)\\s+(?:already\\s+)?(?:processed|checked)\\b",
      options: .regularExpression
    ) != nil
    let rejectsRecheck = command.range(
      of: "\\b(?:do\\s+not|don't|dont|without|not)\\b[^.!?]{0,50}\\b(?:recheck(?:ing)?|reprocess(?:ing)?|check(?:ing)?(?:\\s+them)?\\s+(?:again|already)|includ(?:e|ing)\\s+(?:already\\s+)?(?:processed|checked))\\b",
      options: .regularExpression
    ) != nil
    let recheck = requestsRecheck && !rejectsRecheck
    return DailyReportRunRequest(
      trigger: .chat,
      platforms: comprehensive ? enabledPlatforms : requested,
      comprehensive: comprehensive,
      recheck: recheck
    )
  }

  private static func containsWord(_ word: String, in value: String) -> Bool {
    value.range(
      of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
      options: .regularExpression
    ) != nil
  }
}

public enum DailyReportMode: String, Codable, Equatable, Sendable {
  case unseenOnly = "unseen-only"
  case recheck
}

public enum DailyReportStatus: String, Codable, Equatable, Sendable {
  case success
  case partial
  case failed
  case skipped

  public var satisfiesDailySchedule: Bool { self == .success }
}

public struct DailyReportTokenUsage: Codable, Equatable, Sendable {
  public let inputTokens: Int
  public let cachedInputTokens: Int
  public let outputTokens: Int
  public let reasoningOutputTokens: Int
  public let totalTokens: Int

  public init(
    inputTokens: Int,
    cachedInputTokens: Int,
    outputTokens: Int,
    reasoningOutputTokens: Int,
    totalTokens: Int
  ) {
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
    self.reasoningOutputTokens = reasoningOutputTokens
    self.totalTokens = totalTokens
  }
}

public struct DailyReportTaskReference: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String

  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

public struct DailyReportMessage: Codable, Identifiable, Equatable, Sendable {
  public var id: String { sourceKey }
  public let sourceKey: String
  public let title: String
  public let summary: String
  public let timestamp: String?
  public let url: String?
  public let unavailableReason: String?
  public let tasks: [DailyReportTaskReference]

  public init(
    sourceKey: String,
    title: String,
    summary: String,
    timestamp: String? = nil,
    url: String? = nil,
    unavailableReason: String? = nil,
    tasks: [DailyReportTaskReference] = []
  ) {
    self.sourceKey = sourceKey
    self.title = title
    self.summary = summary
    self.timestamp = timestamp
    self.url = url
    self.unavailableReason = unavailableReason
    self.tasks = tasks
  }
}

public struct DailyReportPlatformSection: Codable, Identifiable, Equatable, Sendable {
  public var id: DailyReportPlatform { platform }
  public let platform: DailyReportPlatform
  public let status: String
  public let collectedCount: Int
  public let newCount: Int
  public let alreadyProcessedCount: Int
  public let checkedCount: Int
  public let deferredCount: Int
  /// Messages the pre-filter skipped as promotional or automated. Reports
  /// written before this field existed decode it as nil.
  public let triagedAwayCount: Int?
  public let messages: [DailyReportMessage]

  public init(
    platform: DailyReportPlatform,
    status: String,
    collectedCount: Int,
    newCount: Int,
    alreadyProcessedCount: Int,
    checkedCount: Int,
    deferredCount: Int,
    triagedAwayCount: Int? = nil,
    messages: [DailyReportMessage]
  ) {
    self.platform = platform
    self.status = status
    self.collectedCount = collectedCount
    self.newCount = newCount
    self.alreadyProcessedCount = alreadyProcessedCount
    self.checkedCount = checkedCount
    self.deferredCount = deferredCount
    self.triagedAwayCount = triagedAwayCount
    self.messages = messages
  }
}

public struct DailyReportDocument: Codable, Identifiable, Equatable, Sendable {
  public var id: String { runID }
  public let version: Int
  public let runID: String
  public let reportDate: String?
  public let trigger: DailyReportTrigger
  public let comprehensive: Bool?
  public let mode: DailyReportMode
  public let startedAt: String
  public let finishedAt: String
  public let status: DailyReportStatus
  public let summary: String
  public let tokenBudget: Int
  public let usage: DailyReportTokenUsage?
  public let platforms: [DailyReportPlatformSection]
  public let errors: [String]

  public init(
    version: Int = 1,
    runID: String,
    reportDate: String? = nil,
    trigger: DailyReportTrigger,
    comprehensive: Bool? = nil,
    mode: DailyReportMode,
    startedAt: String,
    finishedAt: String,
    status: DailyReportStatus,
    summary: String,
    tokenBudget: Int,
    usage: DailyReportTokenUsage?,
    platforms: [DailyReportPlatformSection],
    errors: [String]
  ) {
    self.version = version
    self.runID = runID
    self.reportDate = reportDate
    self.trigger = trigger
    self.comprehensive = comprehensive
    self.mode = mode
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.status = status
    self.summary = summary
    self.tokenBudget = tokenBudget
    self.usage = usage
    self.platforms = platforms
    self.errors = errors
  }

  public func covers(_ requiredPlatforms: [DailyReportPlatform]) -> Bool {
    let reportedPlatforms = Set(platforms.map(\.platform))
    return Set(requiredPlatforms).isSubset(of: reportedPlatforms)
  }
}

public enum DailyReportApprovalStatus: String, Codable, Equatable, Sendable {
  case pending
  case approved
  case declined
}

public struct DailyReportApprovalRequest: Codable, Identifiable, Equatable, Sendable {
  public let version: Int
  public let id: UUID
  public let reportDate: String
  public let requestedAt: String
  public var status: DailyReportApprovalStatus

  public init(
    version: Int = 1,
    id: UUID = UUID(),
    reportDate: String,
    requestedAt: String,
    status: DailyReportApprovalStatus = .pending
  ) {
    self.version = version
    self.id = id
    self.reportDate = reportDate
    self.requestedAt = requestedAt
    self.status = status
  }

  public func isCurrent(reportDate currentReportDate: String) -> Bool {
    reportDate == currentReportDate
  }
}

public struct DashboardDocument: Codable, Equatable, Sendable {
  public let updatedAt: String?
  public let tickets: [DashboardTicket]

  public init(updatedAt: String? = nil, tickets: [DashboardTicket]) {
    self.updatedAt = updatedAt
    self.tickets = tickets
  }
}

public struct DashboardStep: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public let label: String
  public let status: String
  public let evidence: [String]

  public init(id: String, label: String, status: String, evidence: [String] = []) {
    self.id = id
    self.label = label
    self.status = status
    self.evidence = evidence
  }

  public var isDone: Bool { status.lowercased() == "done" }
}

public struct DashboardLink: Codable, Identifiable, Equatable, Sendable {
  public var id: String { "\(label)|\(url)" }
  public let label: String
  public let url: String
  public let type: String?

  public init(label: String, url: String, type: String? = nil) {
    self.label = label
    self.url = url
    self.type = type
  }
}

public struct DashboardPR: Codable, Identifiable, Equatable, Sendable {
  public var id: Int { number }
  public let number: Int
  public let title: String
  public let url: String
  public let state: String?
  public let mergedAt: String?
  public let closedAt: String?

  public init(
    number: Int,
    title: String,
    url: String,
    state: String? = nil,
    mergedAt: String? = nil,
    closedAt: String? = nil
  ) {
    self.number = number
    self.title = title
    self.url = url
    self.state = state
    self.mergedAt = mergedAt
    self.closedAt = closedAt
  }

  public var isMerged: Bool {
    mergedAt != nil || state?.uppercased() == "MERGED"
  }
}

public struct DashboardRecurrence: Codable, Equatable, Sendable {
  public let kind: String
  public let cadence: String
  public let repository: String?

  public init(kind: String, cadence: String, repository: String? = nil) {
    self.kind = kind
    self.cadence = cadence
    self.repository = repository
  }
}

/// Optional completion facts supplied by the canonical dashboard.
///
/// The queue displays these values as-is and never creates them locally.
public struct DashboardCompletion: Codable, Equatable, Sendable {
  public let outcome: String?
  public let reason: String?
  public let resolutionPrs: [Int]
  public let evidence: [String]
  public let completedBy: String?

  public init(
    outcome: String? = nil,
    reason: String? = nil,
    resolutionPrs: [Int] = [],
    evidence: [String] = [],
    completedBy: String? = nil
  ) {
    self.outcome = outcome
    self.reason = reason
    self.resolutionPrs = resolutionPrs
    self.evidence = evidence
    self.completedBy = completedBy
  }

  private enum CodingKeys: String, CodingKey {
    case outcome, reason, resolutionPrs, evidence, completedBy
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
    reason = try container.decodeIfPresent(String.self, forKey: .reason)
    resolutionPrs = try container.decodeIfPresent([Int].self, forKey: .resolutionPrs) ?? []
    evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
    completedBy = try container.decodeIfPresent(String.self, forKey: .completedBy)
  }
}

public struct DashboardTicket: Codable, Identifiable, Equatable, Sendable {
  public let projectID: String?
  public let id: String
  public let title: String
  public let category: String?
  public let priority: String
  public let status: String
  public let summary: String
  public let next: String?
  public let doneWhen: String?
  public let updatedAt: String?
  public let createdAt: String?
  public let dueDate: String?
  public let dueDateSource: String?
  public let completedAt: String?
  public let completion: DashboardCompletion?
  public let taskType: String?
  public let recurrence: DashboardRecurrence?
  public let worktree: String?
  public let resolutionPrs: [Int]
  public let prs: [DashboardPR]
  public let links: [DashboardLink]
  public let steps: [DashboardStep]

  public init(
    id: String,
    title: String,
    projectID: String? = nil,
    category: String? = nil,
    priority: String = "medium",
    status: String,
    summary: String,
    next: String? = nil,
    doneWhen: String? = nil,
    updatedAt: String? = nil,
    createdAt: String? = nil,
    dueDate: String? = nil,
    dueDateSource: String? = nil,
    completedAt: String? = nil,
    completion: DashboardCompletion? = nil,
    taskType: String? = nil,
    recurrence: DashboardRecurrence? = nil,
    worktree: String? = nil,
    resolutionPrs: [Int] = [],
    prs: [DashboardPR] = [],
    links: [DashboardLink] = [],
    steps: [DashboardStep] = []
  ) {
    self.id = id
    self.title = title
    self.projectID = projectID
    self.category = category
    self.priority = priority
    self.status = status
    self.summary = summary
    self.next = next
    self.doneWhen = doneWhen
    self.updatedAt = updatedAt
    self.createdAt = createdAt
    self.dueDate = dueDate
    self.dueDateSource = dueDateSource
    self.completedAt = completedAt
    self.completion = completion
    self.taskType = taskType
    self.recurrence = recurrence
    self.worktree = worktree
    self.resolutionPrs = resolutionPrs
    self.prs = prs
    self.links = links
    self.steps = steps
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, category, priority, status, summary, next, doneWhen
    case projectID
    case updatedAt, createdAt, dueDate, dueDateSource, completedAt, completion, taskType, recurrence, worktree, resolutionPrs, prs, links, steps
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
    category = try container.decodeIfPresent(String.self, forKey: .category)
    priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? "medium"
    status = try container.decodeIfPresent(String.self, forKey: .status) ?? "backlog"
    summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
    next = try container.decodeIfPresent(String.self, forKey: .next)
    doneWhen = try container.decodeIfPresent(String.self, forKey: .doneWhen)
    updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    dueDate = try container.decodeIfPresent(String.self, forKey: .dueDate)
    dueDateSource = try container.decodeIfPresent(String.self, forKey: .dueDateSource)
    completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
    completion = try container.decodeIfPresent(DashboardCompletion.self, forKey: .completion)
    taskType = try container.decodeIfPresent(String.self, forKey: .taskType)
    recurrence = try container.decodeIfPresent(DashboardRecurrence.self, forKey: .recurrence)
    worktree = try container.decodeIfPresent(String.self, forKey: .worktree)
    resolutionPrs = try container.decodeIfPresent([Int].self, forKey: .resolutionPrs) ?? []
    prs = try container.decodeIfPresent([DashboardPR].self, forKey: .prs) ?? []
    links = try container.decodeIfPresent([DashboardLink].self, forKey: .links) ?? []
    steps = try container.decodeIfPresent([DashboardStep].self, forKey: .steps) ?? []
  }

  public var isOpen: Bool {
    !["resolved", "cancelled"].contains(status.lowercased())
  }

  public var isCompleted: Bool { !isOpen }

  public var completionTimestamp: String? { completedAt ?? updatedAt }

  public var completionDay: String? {
    completionTimestamp.map { String($0.prefix(10)) }
  }

  public var isRecurringPullRequestTask: Bool {
    if taskType?.lowercased() == "recurring",
      recurrence?.kind.lowercased() == "pull-request-resolution"
    {
      return true
    }
    let normalizedTitle = title.lowercased().replacingOccurrences(of: "-", with: " ")
    return normalizedTitle.contains("weekly")
      && normalizedTitle.contains("pull request")
      && (normalizedTitle.contains("resolution") || normalizedTitle.contains("steward"))
  }

  public var pullRequestRepository: String? {
    if let repository = recurrence?.repository, !repository.isEmpty { return repository }
    for link in links {
      guard let url = URL(string: link.url), url.host?.lowercased() == "github.com" else {
        continue
      }
      let components = url.path.split(separator: "/")
      if components.count >= 2 {
        return "\(components[0])/\(components[1])"
      }
    }
    return nil
  }

  public var priorityRank: Int {
    switch priority.lowercased() {
    case "critical": 0
    case "high": 1
    case "medium": 2
    case "low": 3
    default: 4
    }
  }

  public var progressLabel: String {
    if !steps.isEmpty {
      return "\(steps.filter(\.isDone).count)/\(steps.count)"
    }
    if !resolutionPrs.isEmpty {
      let merged = Set(prs.filter(\.isMerged).map(\.number))
      return "\(resolutionPrs.filter { merged.contains($0) }.count)/\(resolutionPrs.count) PRs"
    }
    return status.replacingOccurrences(of: "-", with: " ").capitalized
  }
}

public struct PullRequestResolution: Codable, Identifiable, Equatable, Sendable {
  public var id: Int { number }
  public let number: Int
  public let title: String
  public let url: String
  public let state: String
  public let mergedAt: String?
  public let closedAt: String?

  public init(
    number: Int,
    title: String,
    url: String,
    state: String,
    mergedAt: String? = nil,
    closedAt: String? = nil
  ) {
    self.number = number
    self.title = title
    self.url = url
    self.state = state
    self.mergedAt = mergedAt
    self.closedAt = closedAt
  }

  public var resolvedAt: String? { mergedAt ?? closedAt }
  public var isMerged: Bool { mergedAt != nil || state.uppercased() == "MERGED" }
}

public struct PullRequestQueueSnapshot: Equatable, Sendable {
  public let repository: String
  public let openCount: Int
  public let resolvedThisWeek: [PullRequestResolution]
  public let fetchedAt: Date

  public init(
    repository: String,
    openCount: Int,
    resolvedThisWeek: [PullRequestResolution],
    fetchedAt: Date = Date()
  ) {
    self.repository = repository
    self.openCount = openCount
    self.resolvedThisWeek = resolvedThisWeek
    self.fetchedAt = fetchedAt
  }
}

public struct RecurringPullRequestProgress: Equatable, Sendable {
  public let repository: String
  public let openCount: Int
  public let dailyTarget: Int
  public let weeklyTarget: Int
  public let resolvedToday: [PullRequestResolution]
  public let resolvedThisWeek: [PullRequestResolution]
  public let fetchedAt: Date

  public init(
    snapshot: PullRequestQueueSnapshot,
    now: Date = Date(),
    calendar: Calendar = .current
  ) {
    repository = snapshot.repository
    openCount = snapshot.openCount
    resolvedThisWeek = snapshot.resolvedThisWeek.sorted {
      ($0.resolvedAt ?? "") > ($1.resolvedAt ?? "")
    }
    let parser = ISO8601DateFormatter()
    resolvedToday = resolvedThisWeek.filter { resolution in
      guard let rawDate = resolution.resolvedAt, let date = parser.date(from: rawDate) else {
        return false
      }
      return calendar.isDate(date, inSameDayAs: now)
    }
    dailyTarget = PullRequestTargetPolicy.dailyTarget(openCount: snapshot.openCount)
    weeklyTarget = PullRequestTargetPolicy.weeklyTarget(
      openCount: snapshot.openCount,
      resolvedThisWeek: resolvedThisWeek.count
    )
    fetchedAt = snapshot.fetchedAt
  }

  public var dailyFraction: Double {
    guard dailyTarget > 0 else { return 0 }
    return min(1, Double(resolvedToday.count) / Double(dailyTarget))
  }

  public var weeklyFraction: Double {
    guard weeklyTarget > 0 else { return 0 }
    return min(1, Double(resolvedThisWeek.count) / Double(weeklyTarget))
  }
}

public enum PullRequestTargetPolicy {
  public static func dailyTarget(openCount: Int) -> Int {
    switch max(0, openCount) {
    case 0: 0
    case 1...5: openCount
    case 6...25: 5
    case 26...50: 10
    default: 15
    }
  }

  public static func weeklyTarget(openCount: Int, resolvedThisWeek: Int) -> Int {
    let daily = dailyTarget(openCount: openCount)
    guard daily > 0 else { return 0 }
    return min(max(0, openCount) + max(0, resolvedThisWeek), daily * 5)
  }
}

public enum CompletionReviewStatus: String, Codable, Sendable, CaseIterable {
  case pending
  case running
  case needsWork = "needs-work"
  case accepted
  case failed
}

public struct CompletionRequest: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let ticketID: String
  public let requestedAt: Date
  public var updatedAt: Date
  public var status: CompletionReviewStatus
  public var summary: String?
  public var logPath: String?
  public let requestFilePath: String
  public let subtaskID: String?
  public let contextPath: String?
  public let dashboardPath: String?
  public let workspacePath: String?
  public let taskTitle: String?
  public let doneWhen: String?

  public init(
    id: UUID = UUID(),
    ticketID: String,
    requestedAt: Date = Date(),
    updatedAt: Date = Date(),
    status: CompletionReviewStatus = .pending,
    summary: String? = nil,
    logPath: String? = nil,
    requestFilePath: String,
    subtaskID: String? = nil,
    contextPath: String? = nil,
    dashboardPath: String? = nil,
    workspacePath: String? = nil,
    taskTitle: String? = nil,
    doneWhen: String? = nil
  ) {
    self.id = id
    self.ticketID = ticketID
    self.requestedAt = requestedAt
    self.updatedAt = updatedAt
    self.status = status
    self.summary = summary
    self.logPath = logPath
    self.requestFilePath = requestFilePath
    self.subtaskID = subtaskID
    self.contextPath = contextPath
    self.dashboardPath = dashboardPath
    self.workspacePath = workspacePath
    self.taskTitle = taskTitle
    self.doneWhen = doneWhen
  }
}

public struct WindowSnapshot: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public var placement: QueueWindowPlacement
  public var displayIdentifier: String?

  public init(
    x: Double,
    y: Double,
    width: Double,
    height: Double,
    placement: QueueWindowPlacement,
    displayIdentifier: String? = nil
  )
  {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.placement = placement
    self.displayIdentifier = displayIdentifier
  }
}

public enum AgentProvider: String, Codable, CaseIterable, Equatable, Sendable {
  case codex
  case claude
  case kimi

  public var displayName: String {
    switch self {
    case .codex: "Codex"
    case .claude: "Claude"
    case .kimi: "Kimi"
    }
  }

  public var executableName: String { rawValue }

  /// A bundled system symbol keeps provider identity visible without external image assets.
  public var symbolName: String {
    switch self {
    case .codex: "chevron.left.forwardslash.chevron.right"
    case .claude: "sparkles"
    case .kimi: "moon.stars"
    }
  }

  public func resumeArguments(sessionID: String) -> [String] {
    switch self {
    case .codex: ["resume", sessionID]
    case .claude: ["--resume", sessionID]
    case .kimi: ["--session", sessionID]
    }
  }

  /// Codex and Claude thread IDs are UUIDs. Kimi sessions are ULIDs or, in
  /// current releases, `session_`-prefixed UUID directory names.
  public func isValidSessionID(_ sessionID: String) -> Bool {
    switch self {
    case .codex, .claude:
      return UUID(uuidString: sessionID) != nil
    case .kimi:
      if sessionID.hasPrefix("session_"),
         UUID(uuidString: String(sessionID.dropFirst("session_".count))) != nil {
        return true
      }
      let crockfordBase32 = Set("0123456789abcdefghjkmnpqrstvwxyz")
      return sessionID.count == 26
        && sessionID.lowercased().allSatisfy(crockfordBase32.contains)
    }
  }

  /// Kimi has no reasoning-effort flag, so an effort choice is dropped there.
  public func effortArguments(effort: String) -> [String] {
    switch self {
    case .codex: ["-c", "model_reasoning_effort=\(effort)"]
    case .claude: ["--effort", effort]
    case .kimi: []
    }
  }
}

public enum AgentTerminalLabels {
  /// Task titles are user-authored text. Strip control characters, collapse
  /// whitespace, and cap the length before placing one in a terminal title.
  /// A blank title keeps the ticket-ID label.
  public static func readableTaskTitle(_ title: String, fallback: String) -> String {
    let clean = title.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
      .joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return String((clean.isEmpty ? fallback : clean).prefix(120))
  }

  public static func windowTitle(ticketID: String, taskTitle: String = "") -> String {
    readableTaskTitle(taskTitle, fallback: ticketID)
  }

  public static func tabTitle(
    ticketID: String,
    provider: AgentProvider,
    sessionID: String,
    taskTitle: String = ""
  ) -> String {
    let label = readableTaskTitle(taskTitle, fallback: ticketID)
    return "\(label) · \(provider.displayName) · \(sessionID.suffix(6).lowercased())"
  }

  public static func tabTitle(ticketID: String, paneID: Int, taskTitle: String = "") -> String {
    "\(readableTaskTitle(taskTitle, fallback: ticketID)) · Tab \(paneID)"
  }

  public static func managedTabTitle(ticketID: String, taskTitle: String = "") -> String {
    "\(readableTaskTitle(taskTitle, fallback: ticketID.uppercased())) · tmux"
  }
}

public struct TaskAgentSession: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let ticketID: String
  public let provider: AgentProvider
  public let sessionID: String
  public var tabTitle: String
  public var taskTitle: String?
  public var workingDirectory: String
  public var windowID: Int?
  public var tabID: Int?
  public var paneID: Int?
  public var subtaskID: String?
  public var contextDirectory: String?
  public var supportDirectory: String?
  public var resumePrompt: String?
  public var tmux: TmuxSessionReference?

  public init(
    id: UUID = UUID(),
    ticketID: String,
    provider: AgentProvider,
    sessionID: String,
    tabTitle: String,
    taskTitle: String? = nil,
    workingDirectory: String,
    windowID: Int? = nil,
    tabID: Int? = nil,
    paneID: Int? = nil,
    subtaskID: String? = nil,
    contextDirectory: String? = nil,
    supportDirectory: String? = nil,
    resumePrompt: String? = nil,
    tmux: TmuxSessionReference? = nil
  ) {
    self.id = id
    self.ticketID = ticketID
    self.provider = provider
    self.sessionID = sessionID
    self.tabTitle = tabTitle
    self.taskTitle = taskTitle
    self.workingDirectory = workingDirectory
    self.windowID = windowID
    self.tabID = tabID
    self.paneID = paneID
    self.subtaskID = subtaskID
    self.contextDirectory = contextDirectory
    self.supportDirectory = supportDirectory
    self.resumePrompt = resumePrompt
    self.tmux = tmux
  }

  public var terminalWindowTitle: String {
    AgentTerminalLabels.windowTitle(ticketID: ticketID, taskTitle: taskTitle ?? "")
  }

  public var terminalTabTitle: String {
    AgentTerminalLabels.tabTitle(
      ticketID: ticketID,
      provider: provider,
      sessionID: sessionID,
      taskTitle: taskTitle ?? ""
    )
  }

  public func canonicalizedForTerminal() -> TaskAgentSession {
    TaskAgentSession(
      id: id,
      ticketID: ticketID,
      provider: provider,
      sessionID: sessionID,
      tabTitle: terminalTabTitle,
      taskTitle: taskTitle,
      workingDirectory: workingDirectory,
      windowID: windowID,
      tabID: tabID,
      paneID: paneID,
      subtaskID: subtaskID,
      contextDirectory: contextDirectory,
      supportDirectory: supportDirectory,
      resumePrompt: nil,
      tmux: tmux
    )
  }

  public func withContext(_ context: TaskContext, subtask: TaskSubtask?, supportDirectory: URL) -> TaskAgentSession {
    var enriched = self
    // The session's launch directory is authoritative. Task context can move to
    // a new worktree without moving an older provider conversation.
    if workingDirectory.isEmpty {
      enriched.workingDirectory = context.worktreePath ?? context.repositoryPath ?? workingDirectory
    }
    enriched.subtaskID = subtask?.id
    if !context.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      enriched.taskTitle = context.title
    }
    enriched.contextDirectory = context.contextDirectory.path
    enriched.supportDirectory = supportDirectory.path
    // Legacy state can still decode resumePrompt, but managed recall never sends
    // another provider prompt or reconstructs a provider conversation.
    enriched.resumePrompt = nil
    return enriched
  }
}

public enum QueueActivitySortMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case recentInteraction
  case recentOutput
  case triage
  case manual

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .recentInteraction: "Recent interaction"
    case .recentOutput: "Recent output"
    case .triage: "Triage deadlines"
    case .manual: "Manual order"
    }
  }
}

public struct LocalState: Codable, Equatable, Sendable {
  public var selectedProjectID: String?
  /// Nil falls back to the all-projects scope, the default queue view.
  public var showsAllProjects: Bool?
  public var routineDate: String
  public var completedRoutineIDs: Set<String>
  public var completionRequests: [CompletionRequest]
  public var deferredTicketIDs: [String]
  public var dismissedNotificationIDs: Set<String>
  public var window: WindowSnapshot?
  public var appearance: QueueAppearance?
  public var accentStyle: QueueAccentStyle?
  public var minimizationPreference: QueueMinimizationPreference
  public var programLogWindowVisible: Bool
  public var agentSessions: [TaskAgentSession]
  public var lastStaleAgentSweepAt: Date?
  public var viewedTicketIDs: Set<String>?
  public var queueActivitySortMode: QueueActivitySortMode?

  public init(
    routineDate: String = "",
    completedRoutineIDs: Set<String> = [],
    completionRequests: [CompletionRequest] = [],
    deferredTicketIDs: [String] = [],
    dismissedNotificationIDs: Set<String> = [],
    window: WindowSnapshot? = nil,
    appearance: QueueAppearance? = nil,
    accentStyle: QueueAccentStyle? = nil,
    minimizationPreference: QueueMinimizationPreference = .fq,
    programLogWindowVisible: Bool = false,
    agentSessions: [TaskAgentSession] = [],
    lastStaleAgentSweepAt: Date? = nil,
    viewedTicketIDs: Set<String>? = nil,
    queueActivitySortMode: QueueActivitySortMode? = nil
  ) {
    self.routineDate = routineDate
    self.completedRoutineIDs = completedRoutineIDs
    self.completionRequests = completionRequests
    self.deferredTicketIDs = deferredTicketIDs
    self.dismissedNotificationIDs = dismissedNotificationIDs
    self.window = window
    self.appearance = appearance
    self.accentStyle = accentStyle
    self.minimizationPreference = minimizationPreference
    self.programLogWindowVisible = programLogWindowVisible
    self.agentSessions = agentSessions
    self.lastStaleAgentSweepAt = lastStaleAgentSweepAt
    self.viewedTicketIDs = viewedTicketIDs
    self.queueActivitySortMode = queueActivitySortMode
  }

  public mutating func upsertAgentSession(_ session: TaskAgentSession) {
    let matchesIdentity: (TaskAgentSession) -> Bool = {
      $0.provider == session.provider
        && $0.sessionID.caseInsensitiveCompare(session.sessionID) == .orderedSame
    }
    let position = agentSessions.firstIndex(where: matchesIdentity)
    let previous = position.map { agentSessions[$0] }
    let persistedID = previous?.id ?? session.id
    let sameTask = previous?.ticketID == session.ticketID ? previous : nil
    let updated = TaskAgentSession(
      id: persistedID,
      ticketID: session.ticketID,
      provider: session.provider,
      sessionID: session.sessionID,
      tabTitle: session.terminalTabTitle,
      taskTitle: session.taskTitle ?? sameTask?.taskTitle,
      workingDirectory: session.workingDirectory,
      windowID: session.windowID,
      tabID: session.tabID,
      paneID: session.paneID,
      subtaskID: session.subtaskID ?? sameTask?.subtaskID,
      contextDirectory: session.contextDirectory ?? sameTask?.contextDirectory,
      supportDirectory: session.supportDirectory ?? sameTask?.supportDirectory,
      resumePrompt: nil,
      tmux: session.tmux ?? previous?.tmux
    )
    // Replace in place. Re-registering an unchanged session must leave the
    // saved state identical, or every hook event rewrites state and history.
    guard let position else {
      agentSessions.append(updated)
      return
    }
    agentSessions[position] = updated
    var index = agentSessions.index(after: position)
    while index < agentSessions.endIndex {
      if matchesIdentity(agentSessions[index]) { agentSessions.remove(at: index) } else { index += 1 }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case routineDate
    case selectedProjectID
    case showsAllProjects
    case completedRoutineIDs
    case completionRequests
    case deferredTicketIDs
    case dismissedNotificationIDs
    case window
    case appearance
    case accentStyle
    case minimizationPreference
    case programLogWindowVisible
    case agentSessions
    case viewedTicketIDs
    case queueActivitySortMode
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    routineDate = try container.decodeIfPresent(String.self, forKey: .routineDate) ?? ""
    selectedProjectID = try container.decodeIfPresent(String.self, forKey: .selectedProjectID)
    showsAllProjects = try container.decodeIfPresent(Bool.self, forKey: .showsAllProjects)
    completedRoutineIDs =
      try container.decodeIfPresent(Set<String>.self, forKey: .completedRoutineIDs) ?? []
    completionRequests =
      try container.decodeIfPresent([CompletionRequest].self, forKey: .completionRequests) ?? []
    deferredTicketIDs =
      try container.decodeIfPresent([String].self, forKey: .deferredTicketIDs) ?? []
    dismissedNotificationIDs =
      try container.decodeIfPresent(Set<String>.self, forKey: .dismissedNotificationIDs) ?? []
    window = try container.decodeIfPresent(WindowSnapshot.self, forKey: .window)
    appearance = try container.decodeIfPresent(QueueAppearance.self, forKey: .appearance)
    accentStyle = try container.decodeIfPresent(QueueAccentStyle.self, forKey: .accentStyle)
    minimizationPreference =
      try container.decodeIfPresent(QueueMinimizationPreference.self, forKey: .minimizationPreference)
      ?? .fq
    programLogWindowVisible =
      try container.decodeIfPresent(Bool.self, forKey: .programLogWindowVisible) ?? false
    agentSessions =
      try container.decodeIfPresent([TaskAgentSession].self, forKey: .agentSessions) ?? []
    viewedTicketIDs = try container.decodeIfPresent(Set<String>.self, forKey: .viewedTicketIDs)
    queueActivitySortMode = try container.decodeIfPresent(QueueActivitySortMode.self, forKey: .queueActivitySortMode)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(routineDate, forKey: .routineDate)
    try container.encodeIfPresent(selectedProjectID, forKey: .selectedProjectID)
    try container.encodeIfPresent(showsAllProjects, forKey: .showsAllProjects)
    try container.encode(completedRoutineIDs, forKey: .completedRoutineIDs)
    try container.encode(completionRequests, forKey: .completionRequests)
    try container.encode(deferredTicketIDs, forKey: .deferredTicketIDs)
    try container.encode(dismissedNotificationIDs, forKey: .dismissedNotificationIDs)
    try container.encodeIfPresent(window, forKey: .window)
    try container.encodeIfPresent(appearance, forKey: .appearance)
    try container.encodeIfPresent(accentStyle, forKey: .accentStyle)
    try container.encode(minimizationPreference, forKey: .minimizationPreference)
    try container.encode(programLogWindowVisible, forKey: .programLogWindowVisible)
    try container.encode(agentSessions, forKey: .agentSessions)
    try container.encodeIfPresent(viewedTicketIDs, forKey: .viewedTicketIDs)
    try container.encodeIfPresent(queueActivitySortMode, forKey: .queueActivitySortMode)
  }
}

public enum DashboardOrdering {
  public static func openTickets(
    in tickets: [DashboardTicket],
    deferredTicketIDs: [String] = []
  ) -> [DashboardTicket] {
    let canonical = tickets.filter(\.isOpen).sorted(by: canonicalOrder)
    let deferredSet = Set(deferredTicketIDs)
    let regular = canonical.filter { !deferredSet.contains($0.id) }
    var ticketsByID: [String: DashboardTicket] = [:]
    for ticket in canonical where ticketsByID[ticket.id] == nil {
      ticketsByID[ticket.id] = ticket
    }
    var emittedDeferredIDs: Set<String> = []
    let deferred: [DashboardTicket] = deferredTicketIDs.compactMap { ticketID in
      guard emittedDeferredIDs.insert(ticketID).inserted else { return nil }
      return ticketsByID[ticketID]
    }
    return regular + deferred
  }

  private static func canonicalOrder(_ left: DashboardTicket, _ right: DashboardTicket) -> Bool {
    if left.priorityRank != right.priorityRank {
      return left.priorityRank < right.priorityRank
    }
    if left.updatedAt != right.updatedAt {
      return (left.updatedAt ?? "") > (right.updatedAt ?? "")
    }
    return left.id < right.id
  }
}
