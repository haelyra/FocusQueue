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

public struct DailyRoutine: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let url: String?

  public init(id: String, title: String, url: String? = nil) {
    self.id = id
    self.title = title
    self.url = url
  }
}

public struct WezTermConfiguration: Codable, Equatable, Sendable {
  public var executable: String
  public var applicationName: String

  public init(executable: String, applicationName: String = "WezTerm") {
    self.executable = executable
    self.applicationName = applicationName
  }
}

public struct VerifierConfiguration: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var executable: String
  public var sessionName: String
  public var timeoutSeconds: Int
  public var maxTurns: Int

  public init(
    enabled: Bool,
    executable: String,
    sessionName: String,
    timeoutSeconds: Int = 120,
    maxTurns: Int = 24
  ) {
    self.enabled = enabled
    self.executable = executable
    self.sessionName = sessionName
    self.timeoutSeconds = timeoutSeconds
    self.maxTurns = maxTurns
  }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
  public var appName: String
  public var dashboardPath: String
  public var workspacePath: String
  public var defaultPlacement: QueueWindowPlacement
  public var refreshIntervalSeconds: Int
  public var dailyRoutines: [DailyRoutine]
  public var wezTerm: WezTermConfiguration
  public var verifier: VerifierConfiguration

  public init(
    appName: String,
    dashboardPath: String,
    workspacePath: String,
    defaultPlacement: QueueWindowPlacement,
    refreshIntervalSeconds: Int,
    dailyRoutines: [DailyRoutine],
    wezTerm: WezTermConfiguration,
    verifier: VerifierConfiguration
  ) {
    self.appName = appName
    self.dashboardPath = dashboardPath
    self.workspacePath = workspacePath
    self.defaultPlacement = defaultPlacement
    self.refreshIntervalSeconds = refreshIntervalSeconds
    self.dailyRoutines = dailyRoutines
    self.wezTerm = wezTerm
    self.verifier = verifier
  }

  public static func eccDefault(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Self {
    let home = homeDirectory.path
    let workspace = "\(home)/Documents/ECC"
    return Self(
      appName: "ECC Focus Queue",
      dashboardPath: "\(workspace)/ecc-dashboard/data/dashboard.json",
      workspacePath: workspace,
      defaultPlacement: .upperRight,
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
    guard (10...900).contains(verifier.timeoutSeconds), (1...100).contains(verifier.maxTurns) else {
      throw ConfigurationError.invalidVerifierBudget
    }
    return self
  }
}

public enum ConfigurationError: Error, LocalizedError, Equatable {
  case pathsMustBeAbsolute
  case invalidRefreshInterval
  case invalidVerifierBudget

  public var errorDescription: String? {
    switch self {
    case .pathsMustBeAbsolute:
      "Dashboard and workspace paths must be absolute."
    case .invalidRefreshInterval:
      "Refresh interval must be between 1 and 300 seconds."
    case .invalidVerifierBudget:
      "Agent timeout or turn budget is outside the supported range."
    }
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

public struct DashboardTicket: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let category: String?
  public let priority: String
  public let status: String
  public let summary: String
  public let next: String?
  public let doneWhen: String?
  public let updatedAt: String?
  public let completedAt: String?
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
    category: String? = nil,
    priority: String = "medium",
    status: String,
    summary: String,
    next: String? = nil,
    doneWhen: String? = nil,
    updatedAt: String? = nil,
    completedAt: String? = nil,
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
    self.category = category
    self.priority = priority
    self.status = status
    self.summary = summary
    self.next = next
    self.doneWhen = doneWhen
    self.updatedAt = updatedAt
    self.completedAt = completedAt
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
    case updatedAt, completedAt, taskType, recurrence, worktree, resolutionPrs, prs, links, steps
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
    category = try container.decodeIfPresent(String.self, forKey: .category)
    priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? "medium"
    status = try container.decodeIfPresent(String.self, forKey: .status) ?? "backlog"
    summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
    next = try container.decodeIfPresent(String.self, forKey: .next)
    doneWhen = try container.decodeIfPresent(String.self, forKey: .doneWhen)
    updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
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

  public init(
    id: UUID = UUID(),
    ticketID: String,
    requestedAt: Date = Date(),
    updatedAt: Date = Date(),
    status: CompletionReviewStatus = .pending,
    summary: String? = nil,
    logPath: String? = nil,
    requestFilePath: String
  ) {
    self.id = id
    self.ticketID = ticketID
    self.requestedAt = requestedAt
    self.updatedAt = updatedAt
    self.status = status
    self.summary = summary
    self.logPath = logPath
    self.requestFilePath = requestFilePath
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

  public var displayName: String {
    switch self {
    case .codex: "Codex"
    case .claude: "Claude"
    }
  }

  public var executableName: String { rawValue }

  public func resumeArguments(sessionID: String) -> [String] {
    switch self {
    case .codex: ["resume", sessionID]
    case .claude: ["--resume", sessionID]
    }
  }
}

public struct TaskAgentSession: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let ticketID: String
  public let provider: AgentProvider
  public let sessionID: String
  public var tabTitle: String
  public var workingDirectory: String
  public var windowID: Int?
  public var tabID: Int?
  public var paneID: Int?

  public init(
    id: UUID = UUID(),
    ticketID: String,
    provider: AgentProvider,
    sessionID: String,
    tabTitle: String,
    workingDirectory: String,
    windowID: Int? = nil,
    tabID: Int? = nil,
    paneID: Int? = nil
  ) {
    self.id = id
    self.ticketID = ticketID
    self.provider = provider
    self.sessionID = sessionID
    self.tabTitle = tabTitle
    self.workingDirectory = workingDirectory
    self.windowID = windowID
    self.tabID = tabID
    self.paneID = paneID
  }

  public var terminalWindowTitle: String {
    "\(ticketID) · \(provider.displayName) · \(sessionID)"
  }
}

public struct LocalState: Codable, Equatable, Sendable {
  public var routineDate: String
  public var completedRoutineIDs: Set<String>
  public var completionRequests: [CompletionRequest]
  public var deferredTicketIDs: [String]
  public var window: WindowSnapshot?
  public var appearance: QueueAppearance?
  public var accentStyle: QueueAccentStyle?
  public var agentSessions: [TaskAgentSession]

  public init(
    routineDate: String = "",
    completedRoutineIDs: Set<String> = [],
    completionRequests: [CompletionRequest] = [],
    deferredTicketIDs: [String] = [],
    window: WindowSnapshot? = nil,
    appearance: QueueAppearance? = nil,
    accentStyle: QueueAccentStyle? = nil,
    agentSessions: [TaskAgentSession] = []
  ) {
    self.routineDate = routineDate
    self.completedRoutineIDs = completedRoutineIDs
    self.completionRequests = completionRequests
    self.deferredTicketIDs = deferredTicketIDs
    self.window = window
    self.appearance = appearance
    self.accentStyle = accentStyle
    self.agentSessions = agentSessions
  }

  private enum CodingKeys: String, CodingKey {
    case routineDate
    case completedRoutineIDs
    case completionRequests
    case deferredTicketIDs
    case window
    case appearance
    case accentStyle
    case agentSessions
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    routineDate = try container.decodeIfPresent(String.self, forKey: .routineDate) ?? ""
    completedRoutineIDs =
      try container.decodeIfPresent(Set<String>.self, forKey: .completedRoutineIDs) ?? []
    completionRequests =
      try container.decodeIfPresent([CompletionRequest].self, forKey: .completionRequests) ?? []
    deferredTicketIDs =
      try container.decodeIfPresent([String].self, forKey: .deferredTicketIDs) ?? []
    window = try container.decodeIfPresent(WindowSnapshot.self, forKey: .window)
    appearance = try container.decodeIfPresent(QueueAppearance.self, forKey: .appearance)
    accentStyle = try container.decodeIfPresent(QueueAccentStyle.self, forKey: .accentStyle)
    agentSessions =
      try container.decodeIfPresent([TaskAgentSession].self, forKey: .agentSessions) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(routineDate, forKey: .routineDate)
    try container.encode(completedRoutineIDs, forKey: .completedRoutineIDs)
    try container.encode(completionRequests, forKey: .completionRequests)
    try container.encode(deferredTicketIDs, forKey: .deferredTicketIDs)
    try container.encodeIfPresent(window, forKey: .window)
    try container.encodeIfPresent(appearance, forKey: .appearance)
    try container.encodeIfPresent(accentStyle, forKey: .accentStyle)
    try container.encode(agentSessions, forKey: .agentSessions)
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
