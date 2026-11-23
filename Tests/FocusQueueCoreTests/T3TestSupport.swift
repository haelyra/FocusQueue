import Foundation
import Testing
@testable import FocusQueueCore

/// A clock whose time only moves when a test advances it. Sleepers wake in deadline order.
final class ManualT3Clock: T3Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleepers: [(id: UUID, deadline: Date, continuation: CheckedContinuation<Void, any Error>)] = []
    private(set) var sleepRequests: [Double] = []

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    func now() -> Date { lock.withLock { current } }

    func sleep(seconds: Double) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ready: Bool = lock.withLock {
                    sleepRequests.append(seconds)
                    if Task.isCancelled { return false }
                    if seconds <= 0 { return true }
                    sleepers.append((id, current.addingTimeInterval(seconds), continuation))
                    return false
                }
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if ready { continuation.resume() }
            }
        } onCancel: {
            let removed = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index).continuation
            }
            removed?.resume(throwing: CancellationError())
        }
    }

    var pendingSleepers: Int { lock.withLock { sleepers.count } }

    /// Moves time forward and wakes every sleeper whose deadline passed.
    func advance(by seconds: Double) async {
        let due: [CheckedContinuation<Void, any Error>] = lock.withLock {
            current = current.addingTimeInterval(seconds)
            let ready = sleepers.filter { $0.deadline <= current }.sorted { $0.deadline < $1.deadline }
            sleepers.removeAll { $0.deadline <= current }
            return ready.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
        await settle()
    }

    /// Lets woken tasks run.
    func settle(rounds: Int = 20) async {
        for _ in 0..<rounds { await Task.yield() }
    }
}

/// Polls until a condition holds, yielding to other tasks. Real time, bounded.
func eventually(timeout: Double = 2, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

/// A scripted `T3ToolCalling`. Each method calls its handler, or fails with
/// `invalidResponse` when the test did not script it. Every call is logged.
actor FakeT3Tools: T3ToolCalling {
    enum Call: Equatable, Sendable {
        case launch(T3LaunchRequest)
        case send(threadId: String, message: String, mode: T3SendMode)
        case interrupt(threadId: String, stop: Bool)
        case wait(threadId: String, runId: String, timeoutMs: Int)
        case snapshot(String)
        case list(String)
        case questionIds(String)
        case question(String, String)
        case answer(String, String, [String: String])
        case listProjects
        case createProject(String, String)
        case archive(String)
        case providers
        case environment
    }

    private(set) var calls: [Call] = []
    var onLaunch: (@Sendable (T3LaunchRequest) async throws -> T3LaunchResult)?
    var onSend: (@Sendable (String, String, T3SendMode) async throws -> Void)?
    var onInterrupt: (@Sendable (String, Bool) async throws -> T3InterruptResult)?
    var onWait: (@Sendable (String, String, Int) async throws -> T3WaitResult)?
    var onSnapshot: (@Sendable (String) async throws -> T3ThreadSnapshot)?
    var onList: (@Sendable (String) async throws -> [T3ThreadRow])?
    var onQuestionIds: (@Sendable (String) async throws -> [String])?
    var onQuestion: (@Sendable (String, String) async throws -> T3PendingRequest)?
    var onAnswer: (@Sendable (String, String, [String: String]) async throws -> Void)?
    var onListProjects: (@Sendable () async throws -> [T3Project])?
    var onCreateProject: (@Sendable (String, String) async throws -> T3Project)?
    var onArchive: (@Sendable (String) async throws -> Void)?
    var onProviders: (@Sendable () async throws -> [T3ProviderInfo])?
    var onEnvironment: (@Sendable () async throws -> T3Environment)?

    func set(_ update: @Sendable (isolated FakeT3Tools) -> Void) { update(self) }
    func callCount(where match: @Sendable (Call) -> Bool) -> Int { calls.filter(match).count }
    func clearCalls() { calls.removeAll() }

    private func unscripted(_ name: String) -> T3Error { .invalidResponse("unscripted \(name)") }

    func launch(_ request: T3LaunchRequest) async throws -> T3LaunchResult {
        calls.append(.launch(request))
        guard let onLaunch else { throw unscripted("launch") }
        return try await onLaunch(request)
    }
    func send(threadId: String, message: String, mode: T3SendMode, clientRequestId: String?) async throws {
        calls.append(.send(threadId: threadId, message: message, mode: mode))
        guard let onSend else { throw unscripted("send") }
        try await onSend(threadId, message, mode)
    }
    func interrupt(threadId: String, stop: Bool, reason: String?) async throws -> T3InterruptResult {
        calls.append(.interrupt(threadId: threadId, stop: stop))
        guard let onInterrupt else { throw unscripted("interrupt") }
        return try await onInterrupt(threadId, stop)
    }
    func wait(threadId: String, runId: String, timeoutMs: Int) async throws -> T3WaitResult {
        calls.append(.wait(threadId: threadId, runId: runId, timeoutMs: timeoutMs))
        guard let onWait else { throw unscripted("wait") }
        return try await onWait(threadId, runId, timeoutMs)
    }
    func snapshot(threadId: String) async throws -> T3ThreadSnapshot {
        calls.append(.snapshot(threadId))
        guard let onSnapshot else { throw unscripted("snapshot") }
        return try await onSnapshot(threadId)
    }
    func list(projectId: String) async throws -> [T3ThreadRow] {
        calls.append(.list(projectId))
        guard let onList else { throw unscripted("list") }
        return try await onList(projectId)
    }
    func questionIds(threadId: String) async throws -> [String] {
        calls.append(.questionIds(threadId))
        guard let onQuestionIds else { return [] }
        return try await onQuestionIds(threadId)
    }
    func question(threadId: String, requestId: String) async throws -> T3PendingRequest {
        calls.append(.question(threadId, requestId))
        guard let onQuestion else { throw unscripted("question") }
        return try await onQuestion(threadId, requestId)
    }
    func answer(threadId: String, requestId: String, answers: [String: String]) async throws {
        calls.append(.answer(threadId, requestId, answers))
        guard let onAnswer else { throw unscripted("answer") }
        try await onAnswer(threadId, requestId, answers)
    }
    func listProjects() async throws -> [T3Project] {
        calls.append(.listProjects)
        guard let onListProjects else { throw unscripted("listProjects") }
        return try await onListProjects()
    }
    func createProject(path: String, title: String) async throws -> T3Project {
        calls.append(.createProject(path, title))
        guard let onCreateProject else { throw unscripted("createProject") }
        return try await onCreateProject(path, title)
    }
    func archive(threadId: String) async throws {
        calls.append(.archive(threadId))
        guard let onArchive else { return }
        try await onArchive(threadId)
    }
    func providers() async throws -> [T3ProviderInfo] {
        calls.append(.providers)
        guard let onProviders else { throw unscripted("providers") }
        return try await onProviders()
    }
    func environment() async throws -> T3Environment {
        calls.append(.environment)
        guard let onEnvironment else { throw unscripted("environment") }
        return try await onEnvironment()
    }
}

/// A connection that reports a fixed status and records reported errors.
actor FakeT3Connection: T3ConnectionProviding {
    var status: T3ConnectionStatus
    var accessLevel: T3AccessLevel?
    private(set) var reported: [T3Error] = []
    init(status: T3ConnectionStatus = .connected(environmentId: "ENV_1", version: "0.1.12"),
         accessLevel: T3AccessLevel? = .fullAccess) {
        self.status = status; self.accessLevel = accessLevel
    }
    func setStatus(_ status: T3ConnectionStatus) { self.status = status }
    func currentStatus() async -> T3ConnectionStatus { status }
    func currentAccessLevel() async -> T3AccessLevel? { accessLevel }
    func report(_ error: T3Error) async { reported.append(error) }
}

/// In-memory subtask store. Records each saved value in order and can fail chosen saves.
actor FakeT3Store: T3SubtaskStoring {
    private(set) var records: [T3SubtaskLocation: TaskSubtask] = [:]
    private(set) var writes: [(T3SubtaskLocation, TaskSubtask)] = []
    /// Called before each save with the value about to be saved; throw to fail it.
    var failSave: (@Sendable (TaskSubtask) -> (any Error)?)?

    init(_ records: [T3SubtaskRecord] = []) {
        for record in records { self.records[record.location] = record.subtask }
    }
    func put(_ location: T3SubtaskLocation, _ subtask: TaskSubtask) { records[location] = subtask }
    func setFailSave(_ fail: (@Sendable (TaskSubtask) -> (any Error)?)?) { failSave = fail }
    func savedValues() -> [TaskSubtask] { writes.map(\.1) }

    func t3Subtasks() async throws -> [T3SubtaskRecord] {
        records.filter { $0.value.isT3 }
            .map { T3SubtaskRecord(location: $0.key, subtask: $0.value) }
            .sorted { $0.location.subtaskID < $1.location.subtaskID }
    }
    func subtask(_ location: T3SubtaskLocation) async throws -> TaskSubtask? { records[location] }
    func insert(_ subtask: TaskSubtask, ticketID: String) async throws {
        if let error = failSave?(subtask) { throw error }
        let location = T3SubtaskLocation(ticketID: ticketID, subtaskID: subtask.id)
        records[location] = subtask
        writes.append((location, subtask))
    }
    @discardableResult
    func mutate(_ location: T3SubtaskLocation, _ change: @Sendable (inout TaskSubtask) throws -> Void) async throws -> TaskSubtask {
        guard var value = records[location] else { throw TaskContextError.missingSubtask(location.subtaskID) }
        try change(&value)
        if let error = failSave?(value) { throw error }
        records[location] = value
        writes.append((location, value))
        return value
    }
}

/// Checkout operations without git.
actor FakeT3Worktrees: T3WorktreeManaging {
    private(set) var provisioned: [String] = []
    private(set) var cleaned: [String] = []
    var cleanupResult = TaskWorktreeCleanupResult(removed: true, message: "Agent worktree removed.")
    var provisionError: (any Error)?
    func setCleanupResult(_ result: TaskWorktreeCleanupResult) { cleanupResult = result }
    func setProvisionError(_ error: (any Error)?) { provisionError = error }

    nonisolated func plannedPath(repositoryPath: String, ticketID: String, subtaskID: String) -> String {
        "\(repositoryPath)/.worktrees/\(ticketID.lowercased())/agents/\(subtaskID.lowercased())"
    }
    func provision(ticketID: String, subtaskID: String, repositoryPath: String) async throws -> AgentWorkspace {
        if let provisionError { throw provisionError }
        let path = plannedPath(repositoryPath: repositoryPath, ticketID: ticketID, subtaskID: subtaskID)
        provisioned.append(path)
        return AgentWorkspace(path: path, repositoryPath: repositoryPath,
                              branch: "focus-queue/\(ticketID.lowercased())-\(subtaskID.lowercased())", managed: true)
    }
    func cleanup(ticketID: String, subtaskID: String) async throws -> TaskWorktreeCleanupResult {
        cleaned.append(subtaskID)
        return cleanupResult
    }
}

enum T3Samples {
    static let env = "ENV_1"
    static func reference(thread: String = "THREAD_1", env: String = T3Samples.env) -> T3ThreadReference {
        T3ThreadReference(environmentId: env, threadId: thread, projectId: "PROJECT_1",
                          link: "t3code://threads/\(thread)", providerInstanceId: "claude", model: "claude-haiku-5-5")
    }
    static func snapshot(_ thread: String = "THREAD_1", status: String = "idle", active: String? = nil,
                         pending: Int = 0, runs: [T3Run] = [], worktree: String? = nil) -> T3ThreadSnapshot {
        T3ThreadSnapshot(threadId: thread,
                         thread: T3ThreadState(status: status, activeRunId: active, pendingRequestCount: pending,
                                               worktreePath: worktree),
                         recentRuns: runs)
    }
    static func t3Subtask(id: String = "SUB_1", thread: String = "THREAD_1", env: String = T3Samples.env,
                          status: TaskSubtaskStatus = .working) -> TaskSubtask {
        var subtask = TaskSubtask(id: id, title: "Agent \(id)", provider: .claude, status: status, runtimeMode: .t3)
        subtask.t3 = reference(thread: thread, env: env)
        return subtask
    }
}
