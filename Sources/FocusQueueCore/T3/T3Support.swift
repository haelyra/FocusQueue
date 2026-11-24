import Foundation

/// Injectable time, so watcher, refresher, reconcile, and backoff timing are testable.
public protocol T3Clock: Sendable {
    func now() -> Date
    /// Throws `CancellationError` when the calling task is cancelled.
    func sleep(seconds: Double) async throws
}

public struct SystemT3Clock: T3Clock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// Connection states, following the state machine in `.spec/plan.md`.
public enum T3ConnectionStatus: Equatable, Sendable {
    case disconnected
    case signingIn
    case connected(environmentId: String, version: String)
    case accessTooLow
    case unreachable
    case unauthorized
    case serverTooOld(String?)
    case otherServer(expected: String, actual: String)

    public var connectedEnvironmentId: String? {
        if case .connected(let environmentId, _) = self { return environmentId }
        return nil
    }
}

/// What the refresher, watcher, and runtime need from `T3Connection`.
public protocol T3ConnectionProviding: Sendable {
    func currentStatus() async -> T3ConnectionStatus
    func currentAccessLevel() async -> T3AccessLevel?
    /// A call failed with a connectivity or authorization error; the connection decides the transition.
    func report(_ error: T3Error) async
    /// The server whose agents may be read: the connected one, or the saved one when the
    /// approved access is below Full access. Agents are then shown live but cannot be controlled.
    func readableEnvironmentId() async -> String?
}

extension T3ConnectionProviding {
    public func readableEnvironmentId() async -> String? { await currentStatus().connectedEnvironmentId }
}

/// Where a subtask lives.
public struct T3SubtaskLocation: Hashable, Sendable {
    public var ticketID: String
    public var subtaskID: String
    public init(ticketID: String, subtaskID: String) { self.ticketID = ticketID; self.subtaskID = subtaskID }
}

public struct T3SubtaskRecord: Equatable, Sendable {
    public var location: T3SubtaskLocation
    public var subtask: TaskSubtask
    public init(location: T3SubtaskLocation, subtask: TaskSubtask) { self.location = location; self.subtask = subtask }
}

/// Subtask persistence the T3 runtime needs. `TaskContextStore` conforms; tests use fakes
/// that can fail or record write order.
public protocol T3SubtaskStoring: Sendable {
    /// Every subtask that runs on T3 (`t3` or `t3Launch` set) in open and recently completed tasks.
    func t3Subtasks() async throws -> [T3SubtaskRecord]
    func subtask(_ location: T3SubtaskLocation) async throws -> TaskSubtask?
    /// Saves a new subtask, or replaces one with the same id.
    func insert(_ subtask: TaskSubtask, ticketID: String) async throws
    @discardableResult
    func mutate(_ location: T3SubtaskLocation, _ change: @Sendable (inout TaskSubtask) throws -> Void) async throws -> TaskSubtask
}

extension TaskSubtask {
    public var isT3: Bool { runtimeMode == .t3 || t3 != nil || t3Launch != nil }
}

extension TaskContextStore: T3SubtaskStoring {
    public func t3Subtasks() async throws -> [T3SubtaskRecord] {
        try loadAvailableForDiscovery().flatMap { context in
            context.subtasks.filter(\.isT3).map {
                T3SubtaskRecord(location: T3SubtaskLocation(ticketID: context.ticketID, subtaskID: $0.id), subtask: $0)
            }
        }
    }

    public func subtask(_ location: T3SubtaskLocation) async throws -> TaskSubtask? {
        try load(ticketID: location.ticketID)?.subtasks.first { $0.id == location.subtaskID }
    }

    public func insert(_ subtask: TaskSubtask, ticketID: String) async throws {
        try upsertSubtask(ticketID: ticketID, subtask: subtask)
    }

    @discardableResult
    public func mutate(_ location: T3SubtaskLocation,
                       _ change: @Sendable (inout TaskSubtask) throws -> Void) async throws -> TaskSubtask {
        try mutateSubtask(ticketID: location.ticketID, subtaskID: location.subtaskID, change)
    }
}

/// Checkout operations, so launch and finish can be tested without git.
public protocol T3WorktreeManaging: Sendable {
    /// The checkout path `provision` would create.
    func plannedPath(repositoryPath: String, ticketID: String, subtaskID: String) -> String
    func provision(ticketID: String, subtaskID: String, repositoryPath: String) async throws -> AgentWorkspace
    func cleanup(ticketID: String, subtaskID: String) async throws -> TaskWorktreeCleanupResult
}

/// `TaskWorktreeManager` plus the store it needs.
public struct TaskWorktreeT3Adapter: T3WorktreeManaging {
    public let manager: TaskWorktreeManager
    public let store: TaskContextStore
    public init(manager: TaskWorktreeManager, store: TaskContextStore) { self.manager = manager; self.store = store }

    public func plannedPath(repositoryPath: String, ticketID: String, subtaskID: String) -> String {
        TaskWorktreeManager.agentDestination(repositoryPath: repositoryPath, ticketID: ticketID, subtaskID: subtaskID).path
    }

    public func provision(ticketID: String, subtaskID: String, repositoryPath: String) async throws -> AgentWorkspace {
        try await manager.provisionAgent(ticketID: ticketID, subtaskID: subtaskID, path: repositoryPath,
                                         policy: .isolatedCleanCheckout, store: store)
    }

    public func cleanup(ticketID: String, subtaskID: String) async throws -> TaskWorktreeCleanupResult {
        guard let subtask = try await store.subtask(T3SubtaskLocation(ticketID: ticketID, subtaskID: subtaskID)) else {
            return TaskWorktreeCleanupResult(removed: false, message: "Agent record not found.")
        }
        return try await manager.cleanupAgent(ticketID: ticketID, subtask: subtask, store: store)
    }
}
