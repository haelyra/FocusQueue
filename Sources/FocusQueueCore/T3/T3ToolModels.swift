import Foundation

// Typed shapes of the T3 Code MCP tools Focus Queue calls. Field names follow
// the verified contract in `.spec/plan.md`. Unknown fields are ignored.

public struct T3LaunchRequest: Equatable, Sendable {
    public var title: String
    public var projectId: String
    public var message: String
    public var instanceId: String
    public var model: String
    public var options: [String: JSONValue]?
    /// A Focus Queue checkout; sent as `workspaceStrategy: {type: "existing_worktree", worktreePath}`.
    public var worktreePath: String
    public var clientRequestId: String
    /// T3 runtime mode, such as `full-access` or `approval-required`; nil uses the thread default.
    public var runtimeMode: String?

    public init(title: String, projectId: String, message: String, instanceId: String, model: String,
                options: [String: JSONValue]? = nil, worktreePath: String, clientRequestId: String,
                runtimeMode: String? = nil) {
        self.title = title; self.projectId = projectId; self.message = message
        self.instanceId = instanceId; self.model = model; self.options = options
        self.worktreePath = worktreePath; self.clientRequestId = clientRequestId; self.runtimeMode = runtimeMode
    }
}

public struct T3LaunchResult: Codable, Equatable, Sendable {
    public var threadId: String
    public var link: String
    public var projectId: String
    public init(threadId: String, link: String, projectId: String) {
        self.threadId = threadId; self.link = link; self.projectId = projectId
    }
}

public enum T3SendMode: String, Codable, Sendable {
    case auto, queue, steer, restart
}

public struct T3InterruptResult: Equatable, Sendable {
    /// nil when there was no active run.
    public var runId: String?
    /// `interrupt_requested`, or `no_active_run` for an idle thread.
    public var status: String
    public init(runId: String?, status: String) { self.runId = runId; self.status = status }
    public static let noActiveRun = "no_active_run"
}

public struct T3WaitResult: Equatable, Sendable {
    public var runId: String
    public var status: String
    public var timedOut: Bool
    public init(runId: String, status: String, timedOut: Bool) {
        self.runId = runId; self.status = status; self.timedOut = timedOut
    }
}

public enum T3RunStatus {
    public static let terminal: Set<String> = ["completed", "failed", "interrupted", "cancelled"]
    public static let active: Set<String> = ["preparing", "running"]
}

public struct T3Run: Codable, Equatable, Sendable {
    public var runId: String
    public var ordinal: Int
    public var status: String
    public var requestedAt: String?
    public var startedAt: String?
    public var completedAt: String?
    public init(runId: String, ordinal: Int, status: String, requestedAt: String? = nil,
                startedAt: String? = nil, completedAt: String? = nil) {
        self.runId = runId; self.ordinal = ordinal; self.status = status
        self.requestedAt = requestedAt; self.startedAt = startedAt; self.completedAt = completedAt
    }
    public var isTerminal: Bool { T3RunStatus.terminal.contains(status) }
}

public struct T3ThreadState: Equatable, Sendable {
    public var status: String
    public var activeRunId: String?
    /// Questions plus approvals.
    public var pendingRequestCount: Int
    public var worktreePath: String?
    public var branch: String?
    public var archived: Bool
    public var settled: Bool
    public init(status: String, activeRunId: String? = nil, pendingRequestCount: Int = 0,
                worktreePath: String? = nil, branch: String? = nil, archived: Bool = false, settled: Bool = false) {
        self.status = status; self.activeRunId = activeRunId; self.pendingRequestCount = pendingRequestCount
        self.worktreePath = worktreePath; self.branch = branch; self.archived = archived; self.settled = settled
    }
}

/// `t3_thread_read {threadId, limit: 1, runLimit: 5}`.
public struct T3ThreadSnapshot: Equatable, Sendable {
    public var threadId: String
    public var thread: T3ThreadState
    public var recentRuns: [T3Run]
    public init(threadId: String, thread: T3ThreadState, recentRuns: [T3Run] = []) {
        self.threadId = threadId; self.thread = thread; self.recentRuns = recentRuns
    }
}

/// One row of `t3_thread_list`.
public struct T3ThreadRow: Equatable, Sendable {
    public var threadId: String
    public var title: String
    public var status: String
    public var latestRunId: String?
    public var createdAt: Date?
    public var updatedAt: String?
    public var link: String?
    public var providerInstanceId: String?
    public var model: String?
    public var settled: Bool?
    public var pendingBackgroundTasks: [JSONValue]
    public var blockedOnThreadWait: Bool
    public init(threadId: String, title: String, status: String, latestRunId: String? = nil,
                createdAt: Date? = nil, updatedAt: String? = nil, link: String? = nil,
                providerInstanceId: String? = nil, model: String? = nil, settled: Bool? = nil,
                pendingBackgroundTasks: [JSONValue] = [], blockedOnThreadWait: Bool = false) {
        self.threadId = threadId; self.title = title; self.status = status; self.latestRunId = latestRunId
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.link = link
        self.providerInstanceId = providerInstanceId; self.model = model; self.settled = settled
        self.pendingBackgroundTasks = pendingBackgroundTasks; self.blockedOnThreadWait = blockedOnThreadWait
    }
}

public struct T3QuestionOption: Codable, Equatable, Sendable {
    public var label: String
    public var description: String?
    public init(label: String, description: String? = nil) { self.label = label; self.description = description }
}

public struct T3Question: Codable, Equatable, Sendable {
    public var id: String
    public var header: String?
    public var question: String
    public var options: [T3QuestionOption]
    public var multiSelect: Bool
    public init(id: String, header: String? = nil, question: String, options: [T3QuestionOption] = [],
                multiSelect: Bool = false) {
        self.id = id; self.header = header; self.question = question; self.options = options
        self.multiSelect = multiSelect
    }
    private enum CodingKeys: String, CodingKey { case id, header, question, options, multiSelect }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        header = try values.decodeIfPresent(String.self, forKey: .header)
        question = try values.decodeIfPresent(String.self, forKey: .question) ?? ""
        options = try values.decodeIfPresent([T3QuestionOption].self, forKey: .options) ?? []
        multiSelect = try values.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
    }
}

/// `t3_pending_request {action: "read"}`.
public struct T3PendingRequest: Codable, Equatable, Sendable {
    public var requestId: String
    public var questions: [T3Question]
    public init(requestId: String, questions: [T3Question]) { self.requestId = requestId; self.questions = questions }
}

public struct T3Project: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var workspaceRoot: String
    public init(id: String, title: String, workspaceRoot: String) {
        self.id = id; self.title = title; self.workspaceRoot = workspaceRoot
    }
}

public struct T3ModelOption: Codable, Equatable, Sendable {
    public var id: String
    public var values: [JSONValue]
    public var `default`: JSONValue?
    public init(id: String, values: [JSONValue], default: JSONValue? = nil) {
        self.id = id; self.values = values; self.default = `default`
    }
    private enum CodingKeys: String, CodingKey { case id, values, `default` }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        values = try container.decodeIfPresent([JSONValue].self, forKey: .values) ?? []
        `default` = try container.decodeIfPresent(JSONValue.self, forKey: .default)
    }
}

public struct T3ModelInfo: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var options: [T3ModelOption]
    public init(id: String, label: String, options: [T3ModelOption] = []) {
        self.id = id; self.label = label; self.options = options
    }
    private enum CodingKeys: String, CodingKey { case id, label, options }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? id
        options = try container.decodeIfPresent([T3ModelOption].self, forKey: .options) ?? []
    }
}

public struct T3ProviderInfo: Equatable, Sendable {
    public var providerInstanceId: String
    public var driverKind: String
    public var displayName: String
    public var models: [T3ModelInfo]
    public var constraints: [String]
    /// A provider with any constraint (for example "Provider instance is disabled.") is not offered.
    public var available: Bool { constraints.isEmpty }
    public init(providerInstanceId: String, driverKind: String, displayName: String,
                models: [T3ModelInfo], constraints: [String] = []) {
        self.providerInstanceId = providerInstanceId; self.driverKind = driverKind
        self.displayName = displayName; self.models = models; self.constraints = constraints
    }
}

/// `t3_environment_read`.
public struct T3Environment: Equatable, Sendable {
    public var environmentId: String
    public var label: String?
    public var serverVersion: String?
    public init(environmentId: String, label: String? = nil, serverVersion: String? = nil) {
        self.environmentId = environmentId; self.label = label; self.serverVersion = serverVersion
    }
}

/// `server/discover`.
public struct T3ServerInfo: Equatable, Sendable {
    public var version: String?
    public var eventsSupported: Bool
    public init(version: String?, eventsSupported: Bool) { self.version = version; self.eventsSupported = eventsSupported }
}

/// Everything `T3ToolClient` does, so runtime, refresher, and watcher can be tested with fakes.
public protocol T3ToolCalling: Sendable {
    func launch(_ request: T3LaunchRequest) async throws -> T3LaunchResult
    func send(threadId: String, message: String, mode: T3SendMode, clientRequestId: String?) async throws
    func interrupt(threadId: String, stop: Bool, reason: String?) async throws -> T3InterruptResult
    func wait(threadId: String, runId: String, timeoutMs: Int) async throws -> T3WaitResult
    func snapshot(threadId: String) async throws -> T3ThreadSnapshot
    func list(projectId: String) async throws -> [T3ThreadRow]
    func questionIds(threadId: String) async throws -> [String]
    func question(threadId: String, requestId: String) async throws -> T3PendingRequest
    func answer(threadId: String, requestId: String, answers: [String: String]) async throws
    func listProjects() async throws -> [T3Project]
    func createProject(path: String, title: String) async throws -> T3Project
    func archive(threadId: String) async throws
    func providers() async throws -> [T3ProviderInfo]
    func environment() async throws -> T3Environment
}
