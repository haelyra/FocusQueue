import Foundation

/// The provider, model, and options a T3 agent launches with.
public typealias T3LaunchChoice = T3ModelChoice

/// Validates a launch choice against what T3 Code currently offers. `T3ProviderCatalog` conforms.
public protocol T3ModelSelecting: Sendable {
    /// Returns `{instanceId, model, options?}` or throws `.rejected(code: "model_unavailable", …)`.
    func modelSelection(instanceId: String, model: String, options: [String: JSONValue]) async throws -> [String: JSONValue]
}

/// Maps a Focus Queue project to its T3 project. `T3ProjectResolver` conforms.
public protocol T3ProjectResolving: Sendable {
    func projectId(for project: ProjectConfiguration, environmentId: String) async throws -> String
}

/// Asks for a fresh snapshot of a thread. `T3Refresher` conforms.
public protocol T3DirtyMarking: Sendable {
    func markDirty(_ threadId: String) async
}

/// Everything a T3 launch needs from the caller.
public struct T3LaunchInput: Sendable {
    public var ticketID: String
    /// The unsaved agent record: id, title, provider, descriptions, launch configuration.
    public var subtask: TaskSubtask
    /// The first message, built like the terminal runtime's initial prompt.
    public var prompt: String
    public var project: ProjectConfiguration
    /// The repository the checkout is forked from.
    public var repositoryPath: String
    public var choice: T3LaunchChoice
    public init(ticketID: String, subtask: TaskSubtask, prompt: String, project: ProjectConfiguration,
                repositoryPath: String, choice: T3LaunchChoice) {
        self.ticketID = ticketID; self.subtask = subtask; self.prompt = prompt; self.project = project
        self.repositoryPath = repositoryPath; self.choice = choice
    }
}

/// Runs Focus Queue agents in T3 Code threads. Focus Queue keeps the checkout
/// and its lifecycle; T3 Code runs the conversation.
public actor T3Runtime {
    public static let resumePrompt = "Continue where you left off."
    public static let stopConfirmationSeconds: Double = 30
    public static let reconcileIntervalSeconds: Double = 30
    /// Threads created up to this long before the intent was saved still count as candidates.
    public static let reconcileClockSkewSeconds: Double = 60

    private let connection: any T3ConnectionProviding
    private let tools: any T3ToolCalling
    private let models: any T3ModelSelecting
    private let projects: any T3ProjectResolving
    private let worktrees: any T3WorktreeManaging
    private let store: any T3SubtaskStoring
    private let dirty: (any T3DirtyMarking)?
    /// Returns the T3-managed folder that would contain a checkout path, or nil.
    private let checkoutGuard: @Sendable (String) -> String?
    private let clock: any T3Clock
    private let log: @Sendable (String) -> Void
    /// Launches running in this process; reconcile leaves their intents alone.
    private var inFlightRequestIds: Set<String> = []

    public init(connection: any T3ConnectionProviding, tools: any T3ToolCalling, models: any T3ModelSelecting,
                projects: any T3ProjectResolving, worktrees: any T3WorktreeManaging, store: any T3SubtaskStoring,
                dirty: (any T3DirtyMarking)? = nil,
                checkoutGuard: @escaping @Sendable (String) -> String? = { _ in nil },
                clock: any T3Clock = SystemT3Clock(),
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.connection = connection; self.tools = tools; self.models = models; self.projects = projects
        self.worktrees = worktrees; self.store = store; self.dirty = dirty
        self.checkoutGuard = checkoutGuard; self.clock = clock; self.log = log
    }

    // MARK: - Launch (Task 13)

    /// Launches a T3 thread in a new Focus Queue checkout. Nothing is created
    /// unless T3 Code is connected with Full access, the model is available, and
    /// the checkout would sit outside T3's managed worktree folders.
    @discardableResult
    public func launch(_ input: T3LaunchInput) async throws -> TaskSubtask {
        let environmentId = try await requireLaunchableConnection()
        let selection = try await models.modelSelection(
            instanceId: input.choice.instanceId, model: input.choice.model, options: input.choice.options)
        let projectId = try await projects.projectId(for: input.project, environmentId: environmentId)
        let planned = worktrees.plannedPath(repositoryPath: input.repositoryPath, ticketID: input.ticketID,
                                            subtaskID: input.subtask.id)
        if let folder = checkoutGuard(planned) { throw T3Error.checkoutInManagedFolder(folder) }

        let workspace = try await worktrees.provision(ticketID: input.ticketID, subtaskID: input.subtask.id,
                                                      repositoryPath: input.repositoryPath)
        let location = T3SubtaskLocation(ticketID: input.ticketID, subtaskID: input.subtask.id)
        let intent = T3LaunchIntent(
            requestId: UUID().uuidString.lowercased(), environmentId: environmentId, projectId: projectId,
            worktreePath: workspace.path, title: input.subtask.title, createdAt: clock.now(), phase: .sending,
            message: input.prompt, providerInstanceId: input.choice.instanceId, model: input.choice.model,
            modelOptions: input.choice.options.isEmpty ? nil : input.choice.options)
        var record = input.subtask
        record.workspace = workspace
        record.runtimeMode = .t3
        record.t3 = nil
        record.t3Launch = intent
        record.status = .queued
        do {
            try await store.insert(record, ticketID: input.ticketID)
        } catch {
            // Nothing reached T3 Code yet, so the new checkout can go.
            _ = try? await worktrees.cleanup(ticketID: input.ticketID, subtaskID: input.subtask.id)
            throw error
        }

        inFlightRequestIds.insert(intent.requestId)
        defer { inFlightRequestIds.remove(intent.requestId) }
        let request = Self.request(for: intent, selection: selection)
        let result: T3LaunchResult
        do {
            result = try await tools.launch(request)
        } catch let error as T3Error where Self.isDefiniteRejection(error) {
            try await abandonLaunch(location, reason: error.localizedDescription)
            throw error
        } catch {
            let detail: String
            if case T3Error.outcomeUnknown(let raw)? = error as? T3Error { detail = raw }
            else { detail = error.localizedDescription }
            await markLaunchUnknown(location, detail: detail)
            if let t3 = error as? T3Error, t3.isConnectivity { await connection.report(t3) }
            throw T3Error.outcomeUnknown(detail)
        }
        do {
            return try await adopt(location, intent: intent, threadId: result.threadId, link: result.link,
                                   projectId: result.projectId.isEmpty ? intent.projectId : result.projectId)
        } catch {
            await markLaunchUnknown(location, detail: "Focus Queue could not save the launched thread: \(error.localizedDescription)")
            throw T3Error.outcomeUnknown(error.localizedDescription)
        }
    }

    private static func request(for intent: T3LaunchIntent, selection: [String: JSONValue]) -> T3LaunchRequest {
        T3LaunchRequest(
            title: intent.title, projectId: intent.projectId, message: intent.message ?? "",
            instanceId: selection["instanceId"]?.stringValue ?? intent.providerInstanceId ?? "",
            model: selection["model"]?.stringValue ?? intent.model ?? "",
            options: selection["options"]?.objectValue ?? intent.modelOptions,
            worktreePath: intent.worktreePath, clientRequestId: intent.requestId)
    }

    /// Only these prove the launch never took effect.
    private static func isDefiniteRejection(_ error: T3Error) -> Bool {
        switch error {
        case .rejected, .unauthorized, .accessTooLow, .serverTooOld: true
        default: false
        }
    }

    private func requireLaunchableConnection() async throws -> String {
        switch await connection.currentStatus() {
        case .connected(let environmentId, _):
            guard await connection.currentAccessLevel() == .fullAccess else { throw T3Error.accessTooLow }
            return environmentId
        case .accessTooLow: throw T3Error.accessTooLow
        case .unauthorized: throw T3Error.unauthorized
        case .serverTooOld(let version): throw T3Error.serverTooOld(version)
        case .otherServer(let expected, let actual): throw T3Error.otherServer(expected: expected, actual: actual)
        case .disconnected, .signingIn, .unreachable: throw T3Error.notRunning
        }
    }

    @discardableResult
    private func adopt(_ location: T3SubtaskLocation, intent: T3LaunchIntent, threadId: String, link: String,
                       projectId: String) async throws -> TaskSubtask {
        let now = clock.now()
        return try await store.mutate(location) { subtask in
            subtask.t3 = T3ThreadReference(
                environmentId: intent.environmentId, threadId: threadId, projectId: projectId, link: link,
                providerInstanceId: intent.providerInstanceId ?? "", model: intent.model ?? "")
            subtask.t3Launch = nil
            subtask.runtimeMode = .t3
            if subtask.status != .completed {
                subtask.status = .working
                subtask.attention = nil
            }
            subtask.lastPromptAt = now
            subtask.lastHeartbeatAt = now
        }
    }

    private func abandonLaunch(_ location: T3SubtaskLocation, reason: String) async throws {
        let result = try? await worktrees.cleanup(ticketID: location.ticketID, subtaskID: location.subtaskID)
        let now = clock.now()
        try await store.mutate(location) { subtask in
            subtask.t3Launch = nil
            subtask.progressSummary = String("T3 Code rejected the launch: \(reason)".prefix(2_000))
            subtask.status = .idle
            subtask.attention = .failed
            if subtask.t3 == nil { subtask.agentRemovedAt = now }
        }
        if let result, !result.removed { log("T3 launch rejected; checkout kept: \(result.message)") }
    }

    private func markLaunchUnknown(_ location: T3SubtaskLocation, detail: String) async {
        do {
            try await store.mutate(location) { subtask in
                subtask.t3Launch?.phase = .unknown
                subtask.t3Launch?.lastError = String(detail.prefix(500))
            }
        } catch {
            // The saved intent stays `.sending`, which reconcile also treats as unknown.
            log("T3 launch outcome unknown and not saved: \(error.localizedDescription)")
        }
    }

    // MARK: - Reconcile (Task 14)

    /// Links or relaunches every launch whose outcome is unknown. Never creates
    /// a new request id and never removes a checkout for an unknown outcome.
    public func reconcileLaunches() async {
        guard let environmentId = await connection.currentStatus().connectedEnvironmentId else { return }
        let records: [T3SubtaskRecord]
        do { records = try await store.t3Subtasks() } catch { log("T3 reconcile: \(error.localizedDescription)"); return }
        for record in records {
            guard let intent = record.subtask.t3Launch, record.subtask.t3 == nil,
                  intent.environmentId == environmentId,
                  !inFlightRequestIds.contains(intent.requestId) else { continue }
            do {
                try await reconcile(record.location, intent: intent)
            } catch {
                log("T3 reconcile \(record.location.subtaskID): \(error.localizedDescription)")
            }
        }
    }

    public var hasUnresolvedLaunches: Bool {
        get async {
            ((try? await store.t3Subtasks()) ?? []).contains {
                $0.subtask.t3 == nil && $0.subtask.t3Launch.map { !inFlightRequestIds.contains($0.requestId) } == true
            }
        }
    }

    /// Reconciles every 30 s while any launch outcome is unknown. Runs until cancelled.
    public func runPeriodicReconcile() async {
        while !Task.isCancelled {
            do { try await clock.sleep(seconds: Self.reconcileIntervalSeconds) } catch { return }
            if await hasUnresolvedLaunches { await reconcileLaunches() }
        }
    }

    private func reconcile(_ location: T3SubtaskLocation, intent: T3LaunchIntent) async throws {
        inFlightRequestIds.insert(intent.requestId)
        defer { inFlightRequestIds.remove(intent.requestId) }
        let earliest = intent.createdAt.addingTimeInterval(-Self.reconcileClockSkewSeconds)
        do {
            let rows = try await tools.list(projectId: intent.projectId)
            let candidates = rows.filter { $0.title == intent.title && ($0.createdAt.map { $0 >= earliest } ?? true) }
            let wanted = Self.standardized(intent.worktreePath)
            for row in candidates {
                let snapshot: T3ThreadSnapshot
                do { snapshot = try await tools.snapshot(threadId: row.threadId) }
                catch T3Error.threadNotFound { continue }
                guard let path = snapshot.thread.worktreePath, Self.standardized(path) == wanted else { continue }
                try await adopt(location, intent: intent, threadId: row.threadId, link: row.link ?? "",
                                projectId: intent.projectId)
                await dirty?.markDirty(row.threadId)
                return
            }
            guard intent.message != nil, intent.providerInstanceId != nil, intent.model != nil else {
                await markLaunchUnknown(location, detail: "No thread found and the launch details were not saved.")
                return
            }
            let selection: [String: JSONValue] = [
                "instanceId": .string(intent.providerInstanceId ?? ""), "model": .string(intent.model ?? ""),
            ].merging(intent.modelOptions.map { ["options": JSONValue.object($0)] } ?? [:]) { first, _ in first }
            let result = try await tools.launch(Self.request(for: intent, selection: selection))
            try await adopt(location, intent: intent, threadId: result.threadId, link: result.link,
                            projectId: result.projectId.isEmpty ? intent.projectId : result.projectId)
            await dirty?.markDirty(result.threadId)
        } catch let error as T3Error where Self.isDefiniteRejection(error) {
            if case .unauthorized = error { await connection.report(error); return }
            try await abandonLaunch(location, reason: error.localizedDescription)
        } catch let error as T3Error {
            if error.isConnectivity { await connection.report(error) }
            await markLaunchUnknown(location, detail: error.localizedDescription)
        }
    }

    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Controls (Task 15)

    /// Sends a follow-up. An idle agent starts a turn; a working one gets it
    /// mid-turn when possible, otherwise as its next turn (`auto`).
    public func sendPrompt(_ location: T3SubtaskLocation, text: String) async throws {
        let reference = try await connectedReference(location)
        try await call(location) {
            try await self.tools.send(threadId: reference.threadId, message: text, mode: .auto,
                                      clientRequestId: UUID().uuidString.lowercased())
        }
        let now = clock.now()
        try await store.mutate(location) { subtask in
            subtask.lastPromptAt = now
            subtask.pausedAt = nil
            if subtask.status != .completed {
                subtask.status = .working
                subtask.lastHeartbeatAt = now
            }
        }
        await dirty?.markDirty(reference.threadId)
    }

    /// Interrupts the current turn and keeps the conversation.
    public func pause(_ location: T3SubtaskLocation) async throws {
        let reference = try await connectedReference(location)
        _ = try await call(location) {
            try await self.tools.interrupt(threadId: reference.threadId, stop: false, reason: "Paused from Focus Queue")
        }
        let now = clock.now()
        try await store.mutate(location) { $0.pausedAt = now }
        await dirty?.markDirty(reference.threadId)
    }

    public func resume(_ location: T3SubtaskLocation) async throws {
        let reference = try await connectedReference(location)
        try await call(location) {
            try await self.tools.send(threadId: reference.threadId, message: Self.resumePrompt, mode: .auto,
                                      clientRequestId: UUID().uuidString.lowercased())
        }
        let now = clock.now()
        try await store.mutate(location) { subtask in
            subtask.pausedAt = nil
            subtask.lastPromptAt = now
        }
        await dirty?.markDirty(reference.threadId)
    }

    /// Halts the current turn and holds queued follow-ups. An idle agent is a silent no-op.
    public func stop(_ location: T3SubtaskLocation) async throws {
        let reference = try await connectedReference(location)
        _ = try await call(location) {
            try await self.tools.interrupt(threadId: reference.threadId, stop: true, reason: "Stopped from Focus Queue")
        }
        await dirty?.markDirty(reference.threadId)
    }

    public nonisolated func openURL(_ subtask: TaskSubtask) -> URL? {
        guard let link = subtask.t3?.link, !link.isEmpty else { return nil }
        return URL(string: link)
    }

    /// The user has seen the latest finished turn.
    public func acknowledge(_ location: T3SubtaskLocation) async throws {
        try await store.mutate(location) { subtask in
            let latest = subtask.t3?.latestTerminalRunId
            subtask.t3?.acknowledgedTerminalRunId = latest
            subtask.completionUnread = false
        }
    }

    /// The agent's reference, after checking it belongs to the connected server.
    private func connectedReference(_ location: T3SubtaskLocation) async throws -> T3ThreadReference {
        guard let subtask = try await store.subtask(location), let reference = subtask.t3 else {
            throw T3Error.invalidResponse("This agent has no T3 Code thread yet.")
        }
        switch await connection.currentStatus() {
        case .connected(let environmentId, _):
            guard environmentId == reference.environmentId else {
                throw T3Error.otherServer(expected: reference.environmentId, actual: environmentId)
            }
            return reference
        case .unauthorized: throw T3Error.unauthorized
        case .otherServer(let expected, let actual): throw T3Error.otherServer(expected: expected, actual: actual)
        default: throw T3Error.notRunning
        }
    }

    /// Runs one tool call, recording a missing thread and reporting connectivity failures.
    @discardableResult
    private func call<T: Sendable>(_ location: T3SubtaskLocation, _ body: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch T3Error.threadNotFound(let id) {
            try? await store.mutate(location) { $0.t3?.reachability = .threadMissing }
            throw T3Error.threadNotFound(id)
        } catch let error as T3Error {
            if error.isConnectivity || error == .unauthorized { await connection.report(error) }
            throw error
        }
    }

    // MARK: - Finish (Task 16)

    public struct StopConfirmation: Equatable, Sendable {
        public var confirmed: Bool
        public var reason: String
        public static let ok = StopConfirmation(confirmed: true, reason: "")
        public static func failed(_ reason: String) -> StopConfirmation { StopConfirmation(confirmed: false, reason: reason) }
    }

    /// Stops the agent and confirms T3 Code reports no run and no background work.
    public func confirmStopped(_ location: T3SubtaskLocation,
                               timeout: Double = T3Runtime.stopConfirmationSeconds) async -> StopConfirmation {
        guard let subtask = try? await store.subtask(location), let reference = subtask.t3 else {
            return .failed("This agent has no T3 Code thread")
        }
        do {
            let interrupt = try await tools.interrupt(threadId: reference.threadId, stop: true,
                                                      reason: "Task completed in Focus Queue")
            if let runId = interrupt.runId {
                let waited = try await tools.wait(threadId: reference.threadId, runId: runId,
                                                  timeoutMs: Int(timeout * 1_000))
                guard !waited.timedOut, T3RunStatus.terminal.contains(waited.status) else {
                    return .failed("the stop was not confirmed within \(Int(timeout)) seconds")
                }
            }
            let snapshot = try await tools.snapshot(threadId: reference.threadId)
            guard snapshot.thread.activeRunId == nil else { return .failed("a run is still active") }
            let rows = try await tools.list(projectId: reference.projectId)
            guard let row = rows.first(where: { $0.threadId == reference.threadId }) else {
                return .failed("T3 Code did not list the thread, so background work could not be checked")
            }
            guard row.pendingBackgroundTasks.isEmpty, !row.blockedOnThreadWait else {
                return .failed("background work is still running")
            }
            return .ok
        } catch T3Error.threadNotFound {
            // A deleted thread runs nothing.
            try? await store.mutate(location) { $0.t3?.reachability = .threadMissing }
            return .ok
        } catch let error as T3Error {
            if error.isConnectivity || error == .unauthorized { await connection.report(error) }
            return .failed(error.isConnectivity ? "T3 Code is unreachable" : error.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Stops the agent, then cleans up its checkout only once T3 confirms it
    /// stopped, then archives the thread. Otherwise cleanup stays pending.
    @discardableResult
    public func finish(_ location: T3SubtaskLocation) async -> T3CleanupState? {
        guard let subtask = try? await store.subtask(location), let reference = subtask.t3 else { return nil }
        if case .removed = reference.cleanup, reference.archivedAt != nil { return .removed }
        let status = await connection.currentStatus()
        let confirmation: StopConfirmation
        switch status {
        case .connected(let environmentId, _) where environmentId == reference.environmentId:
            confirmation = await confirmStopped(location)
        case .connected, .otherServer:
            confirmation = .failed("the agent is on another T3 Code server")
        case .unauthorized:
            confirmation = .failed("T3 Code access expired or was revoked")
        default:
            confirmation = .failed("T3 Code is unreachable")
        }
        guard confirmation.confirmed else {
            let state = T3CleanupState.pending(reason: confirmation.reason)
            try? await store.mutate(location) { $0.t3?.cleanup = state }
            return state
        }
        let state: T3CleanupState
        do {
            let result = try await worktrees.cleanup(ticketID: location.ticketID, subtaskID: location.subtaskID)
            state = result.removed ? .removed : .retained(message: result.message)
        } catch {
            state = .retained(message: "Agent worktree retained: \(error.localizedDescription)")
        }
        try? await store.mutate(location) { $0.t3?.cleanup = state }
        do {
            try await tools.archive(threadId: reference.threadId)
            let now = clock.now()
            try? await store.mutate(location) { $0.t3?.archivedAt = now }
        } catch {
            log("T3 archive \(reference.threadId): \(error.localizedDescription)")
        }
        return state
    }

    /// Finishes every agent whose cleanup is pending. Run after each reconnect.
    public func retryPendingCleanups() async {
        guard let records = try? await store.t3Subtasks() else { return }
        for record in records where record.subtask.t3?.cleanup?.isPending == true {
            await finish(record.location)
        }
    }

    /// Checkout paths that must not be touched yet: agents whose stop is not confirmed.
    public func protectedCheckouts(ticketID: String) async -> Set<String> {
        guard let records = try? await store.t3Subtasks() else { return [] }
        return Set(records.filter { record in
            record.location.ticketID.caseInsensitiveCompare(ticketID) == .orderedSame
                && (record.subtask.t3?.cleanup?.isPending == true
                    || (record.subtask.t3Launch != nil && record.subtask.t3 == nil))
        }.compactMap { $0.subtask.workspace?.path })
    }
}

extension T3ProjectResolver: T3ProjectResolving {}
extension T3ProviderCatalog: T3ModelSelecting {}
