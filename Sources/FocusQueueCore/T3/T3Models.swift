import Foundation

/// Which runtime new agents use. nil in `AppConfiguration` means terminal.
public enum AgentRuntimeChoice: String, Codable, CaseIterable, Sendable {
    case terminal, t3
}

/// Whether Focus Queue can currently reach an agent's T3 Code thread.
public enum T3Reachability: String, Codable, CaseIterable, Sendable {
    case reachable, unreachable, threadMissing, otherServer
}

/// Checkout cleanup after a task with T3 agents completes.
public enum T3CleanupState: Codable, Equatable, Sendable {
    /// The agent is not yet confirmed stopped; the checkout is kept.
    case pending(reason: String)
    /// `TaskWorktreeManager.cleanupAgent` kept the checkout, with its reason.
    case retained(message: String)
    case removed

    private enum CodingKeys: String, CodingKey { case state, reason, message }
    private enum Tag: String, Codable { case pending, retained, removed }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Tag.self, forKey: .state) {
        case .pending: self = .pending(reason: try values.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case .retained: self = .retained(message: try values.decodeIfPresent(String.self, forKey: .message) ?? "")
        case .removed: self = .removed
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending(let reason):
            try values.encode(Tag.pending, forKey: .state)
            try values.encode(reason, forKey: .reason)
        case .retained(let message):
            try values.encode(Tag.retained, forKey: .state)
            try values.encode(message, forKey: .message)
        case .removed:
            try values.encode(Tag.removed, forKey: .state)
        }
    }

    public var isPending: Bool { if case .pending = self { true } else { false } }
}

/// A T3 Code agent's thread, bound to the T3 server (`environmentId`) it lives on.
public struct T3ThreadReference: Codable, Equatable, Sendable {
    public var environmentId: String
    public var threadId: String
    public var projectId: String
    public var link: String
    public var providerInstanceId: String
    public var model: String
    /// Last thread status from a snapshot.
    public var observedStatus: String?
    public var activeRunId: String?
    public var latestTerminalRunId: String?
    /// `completed|failed|interrupted|cancelled`
    public var latestTerminalOutcome: String?
    /// The terminal run the user has seen; drives unread.
    public var acknowledgedTerminalRunId: String?
    public var openQuestionIds: [String] = []
    public var pendingApprovalCount: Int = 0
    public var reachability: T3Reachability = .reachable
    public var cleanup: T3CleanupState?
    public var archivedAt: Date?
    public var lastSnapshotAt: Date?

    public init(environmentId: String, threadId: String, projectId: String, link: String,
                providerInstanceId: String, model: String, observedStatus: String? = nil,
                activeRunId: String? = nil, latestTerminalRunId: String? = nil,
                latestTerminalOutcome: String? = nil, acknowledgedTerminalRunId: String? = nil,
                openQuestionIds: [String] = [], pendingApprovalCount: Int = 0,
                reachability: T3Reachability = .reachable, cleanup: T3CleanupState? = nil,
                archivedAt: Date? = nil, lastSnapshotAt: Date? = nil) {
        self.environmentId = environmentId; self.threadId = threadId; self.projectId = projectId
        self.link = link; self.providerInstanceId = providerInstanceId; self.model = model
        self.observedStatus = observedStatus; self.activeRunId = activeRunId
        self.latestTerminalRunId = latestTerminalRunId; self.latestTerminalOutcome = latestTerminalOutcome
        self.acknowledgedTerminalRunId = acknowledgedTerminalRunId
        self.openQuestionIds = openQuestionIds; self.pendingApprovalCount = pendingApprovalCount
        self.reachability = reachability; self.cleanup = cleanup
        self.archivedAt = archivedAt; self.lastSnapshotAt = lastSnapshotAt
    }

    private enum CodingKeys: String, CodingKey {
        case environmentId, threadId, projectId, link, providerInstanceId, model, observedStatus
        case activeRunId, latestTerminalRunId, latestTerminalOutcome, acknowledgedTerminalRunId
        case openQuestionIds, pendingApprovalCount, reachability, cleanup, archivedAt, lastSnapshotAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        environmentId = try values.decode(String.self, forKey: .environmentId)
        threadId = try values.decode(String.self, forKey: .threadId)
        projectId = try values.decode(String.self, forKey: .projectId)
        link = try values.decodeIfPresent(String.self, forKey: .link) ?? ""
        providerInstanceId = try values.decodeIfPresent(String.self, forKey: .providerInstanceId) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        observedStatus = try values.decodeIfPresent(String.self, forKey: .observedStatus)
        activeRunId = try values.decodeIfPresent(String.self, forKey: .activeRunId)
        latestTerminalRunId = try values.decodeIfPresent(String.self, forKey: .latestTerminalRunId)
        latestTerminalOutcome = try values.decodeIfPresent(String.self, forKey: .latestTerminalOutcome)
        acknowledgedTerminalRunId = try values.decodeIfPresent(String.self, forKey: .acknowledgedTerminalRunId)
        openQuestionIds = try values.decodeIfPresent([String].self, forKey: .openQuestionIds) ?? []
        pendingApprovalCount = try values.decodeIfPresent(Int.self, forKey: .pendingApprovalCount) ?? 0
        reachability = try values.decodeIfPresent(T3Reachability.self, forKey: .reachability) ?? .reachable
        cleanup = try values.decodeIfPresent(T3CleanupState.self, forKey: .cleanup)
        archivedAt = try values.decodeIfPresent(Date.self, forKey: .archivedAt)
        lastSnapshotAt = try values.decodeIfPresent(Date.self, forKey: .lastSnapshotAt)
    }
}

public enum T3LaunchPhase: String, Codable, CaseIterable, Sendable {
    /// Saved before the remote call; found at startup it means the outcome is unknown.
    case sending
    /// The launch may or may not have reached T3 Code. Reconcile, never clean up.
    case unknown
}

/// A durable record of a launch, saved before `t3_thread_launch` is called.
public struct T3LaunchIntent: Codable, Equatable, Sendable {
    /// Sent as `clientRequestId`; never regenerated for the same launch.
    public var requestId: String
    public var environmentId: String
    public var projectId: String
    public var worktreePath: String
    public var title: String
    public var createdAt: Date
    public var phase: T3LaunchPhase
    public var lastError: String?
    /// The launch arguments, kept so a resend is the same launch.
    public var message: String?
    public var providerInstanceId: String?
    public var model: String?
    public var modelOptions: [String: JSONValue]?

    public init(requestId: String, environmentId: String, projectId: String, worktreePath: String,
                title: String, createdAt: Date, phase: T3LaunchPhase, lastError: String? = nil,
                message: String? = nil, providerInstanceId: String? = nil, model: String? = nil,
                modelOptions: [String: JSONValue]? = nil) {
        self.requestId = requestId; self.environmentId = environmentId; self.projectId = projectId
        self.worktreePath = worktreePath; self.title = title; self.createdAt = createdAt
        self.phase = phase; self.lastError = lastError; self.message = message
        self.providerInstanceId = providerInstanceId; self.model = model; self.modelOptions = modelOptions
    }
}

/// The access level the user approved on T3 Code's approval page.
public enum T3AccessLevel: String, Codable, CaseIterable, Sendable {
    case fullAccess, belowFullAccess

    /// T3 grants `settings:write` only at Full access.
    public static func from(grantedScope: String) -> T3AccessLevel {
        grantedScope.split(whereSeparator: \.isWhitespace).contains("settings:write") ? .fullAccess : .belowFullAccess
    }
}

/// Non-secret connection facts saved in `t3-connection.json`. The token lives in the Keychain.
public struct T3ConnectionState: Codable, Equatable, Sendable {
    public var serverURL: String
    public var environmentId: String?
    public var environmentLabel: String?
    public var serverVersion: String?
    public var clientId: String
    public var redirectURI: String
    public var grantedScope: String
    public var accessLevel: T3AccessLevel
    public var tokenExpiresAt: Date?
    /// environmentId → Focus Queue project id → T3 project id
    public var projectMaps: [String: [String: String]] = [:]
    public var lastConnectedAt: Date?

    public init(serverURL: String, environmentId: String? = nil, environmentLabel: String? = nil,
                serverVersion: String? = nil, clientId: String = "", redirectURI: String = "",
                grantedScope: String = "", accessLevel: T3AccessLevel = .belowFullAccess,
                tokenExpiresAt: Date? = nil, projectMaps: [String: [String: String]] = [:],
                lastConnectedAt: Date? = nil) {
        self.serverURL = serverURL; self.environmentId = environmentId
        self.environmentLabel = environmentLabel; self.serverVersion = serverVersion
        self.clientId = clientId; self.redirectURI = redirectURI; self.grantedScope = grantedScope
        self.accessLevel = accessLevel; self.tokenExpiresAt = tokenExpiresAt
        self.projectMaps = projectMaps; self.lastConnectedAt = lastConnectedAt
    }

    private enum CodingKeys: String, CodingKey {
        case serverURL, environmentId, environmentLabel, serverVersion, clientId, redirectURI
        case grantedScope, accessLevel, tokenExpiresAt, projectMaps, lastConnectedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try values.decode(String.self, forKey: .serverURL)
        environmentId = try values.decodeIfPresent(String.self, forKey: .environmentId)
        environmentLabel = try values.decodeIfPresent(String.self, forKey: .environmentLabel)
        serverVersion = try values.decodeIfPresent(String.self, forKey: .serverVersion)
        clientId = try values.decodeIfPresent(String.self, forKey: .clientId) ?? ""
        redirectURI = try values.decodeIfPresent(String.self, forKey: .redirectURI) ?? ""
        grantedScope = try values.decodeIfPresent(String.self, forKey: .grantedScope) ?? ""
        accessLevel = try values.decodeIfPresent(T3AccessLevel.self, forKey: .accessLevel) ?? .belowFullAccess
        tokenExpiresAt = try values.decodeIfPresent(Date.self, forKey: .tokenExpiresAt)
        projectMaps = try values.decodeIfPresent([String: [String: String]].self, forKey: .projectMaps) ?? [:]
        lastConnectedAt = try values.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }
}

public enum T3Defaults {
    public static let serverURL = "http://127.0.0.1:3773"
    public static let minimumVersion = "0.1.12"
    public static let protocolVersion = "2026-07-28"
}
