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
        executable: "\(home)/.local/bin/hermes",
        sessionName: "ecc-focus-queue-verifier"
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
      "Hermes timeout or turn budget is outside the supported range."
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
    self.worktree = worktree
    self.resolutionPrs = resolutionPrs
    self.prs = prs
    self.links = links
    self.steps = steps
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, category, priority, status, summary, next, doneWhen
    case updatedAt, worktree, resolutionPrs, prs, links, steps
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
    worktree = try container.decodeIfPresent(String.self, forKey: .worktree)
    resolutionPrs = try container.decodeIfPresent([Int].self, forKey: .resolutionPrs) ?? []
    prs = try container.decodeIfPresent([DashboardPR].self, forKey: .prs) ?? []
    links = try container.decodeIfPresent([DashboardLink].self, forKey: .links) ?? []
    steps = try container.decodeIfPresent([DashboardStep].self, forKey: .steps) ?? []
  }

  public var isOpen: Bool {
    !["resolved", "cancelled"].contains(status.lowercased())
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

  public init(x: Double, y: Double, width: Double, height: Double, placement: QueueWindowPlacement)
  {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.placement = placement
  }
}

public struct LocalState: Codable, Equatable, Sendable {
  public var routineDate: String
  public var completedRoutineIDs: Set<String>
  public var completionRequests: [CompletionRequest]
  public var window: WindowSnapshot?
  public var appearance: QueueAppearance?
  public var accentStyle: QueueAccentStyle?

  public init(
    routineDate: String = "",
    completedRoutineIDs: Set<String> = [],
    completionRequests: [CompletionRequest] = [],
    window: WindowSnapshot? = nil,
    appearance: QueueAppearance? = nil,
    accentStyle: QueueAccentStyle? = nil
  ) {
    self.routineDate = routineDate
    self.completedRoutineIDs = completedRoutineIDs
    self.completionRequests = completionRequests
    self.window = window
    self.appearance = appearance
    self.accentStyle = accentStyle
  }
}
