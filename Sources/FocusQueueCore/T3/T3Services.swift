import Foundation

/// Every T3 Code component, wired together, plus the connection lifecycle:
/// each transition to `connected` starts live updates, reconciles unknown
/// launches, and retries pending cleanups, without an app restart.
public actor T3Services {
    public let connection: T3Connection
    public let tools: any T3ToolCalling
    public let catalog: T3ProviderCatalog
    public let refresher: T3Refresher
    public let watcher: T3Watcher
    public let runtime: T3Runtime
    private let store: any T3SubtaskStoring
    private var lifecycleTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private(set) public var lastHandledStatus: T3ConnectionStatus?

    public init(connection: T3Connection, tools: any T3ToolCalling, catalog: T3ProviderCatalog,
                refresher: T3Refresher, watcher: T3Watcher, runtime: T3Runtime, store: any T3SubtaskStoring) {
        self.connection = connection; self.tools = tools; self.catalog = catalog
        self.refresher = refresher; self.watcher = watcher; self.runtime = runtime; self.store = store
    }

    /// The production graph for one T3 Code server.
    public static func live(serverURL: String?, supportDirectory: URL, contextStore: TaskContextStore,
                            worktreeManager: TaskWorktreeManager, clientVersion: String,
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            log: @escaping @Sendable (String) -> Void = { _ in }) -> T3Services {
        let server = serverURL ?? T3Defaults.serverURL
        let stateStore = T3ConnectionStateStore(supportDirectory: supportDirectory)
        let connection = T3Connection(
            serverURL: server, credentials: KeychainT3CredentialStore(), stateStore: stateStore,
            makeTransport: { base, token in
                T3McpTransport(baseURL: base, token: token, clientVersion: clientVersion)
            })
        let tools = T3ToolClient(transport: connection.currentTransport())
        let catalog = T3ProviderCatalog(tools: tools)
        let refresher = T3Refresher(tools: tools, store: contextStore, connection: connection)
        let watcher = T3Watcher(transport: connection.currentTransport(), tools: tools, target: refresher,
                                store: contextStore, connection: connection)
        let resolver = T3ProjectResolver(tools: tools, stateStore: stateStore, serverURL: server)
        let runtime = T3Runtime(
            connection: connection, tools: tools, models: catalog, projects: resolver,
            worktrees: TaskWorktreeT3Adapter(manager: worktreeManager, store: contextStore),
            store: contextStore, dirty: refresher,
            checkoutGuard: { path in
                guard let folders = T3ManagedFolders.resolve(serverURL: server, environment: environment,
                                                             fileAccessor: SystemFileAccessor()) else {
                    log("T3 Code's worktree folders could not be read; launching without the folder check.")
                    return nil
                }
                return T3ManagedFolders.violation(checkoutPath: path, folders: folders)
            },
            log: log)
        return T3Services(connection: connection, tools: tools, catalog: catalog, refresher: refresher,
                          watcher: watcher, runtime: runtime, store: contextStore)
    }

    /// Follows connection transitions until `stop()`. Resumes a saved connection first.
    public func start(resumeSavedConnection: Bool = true) async {
        guard lifecycleTask == nil else { return }
        let transitions = await connection.transitions()
        lifecycleTask = Task { [weak self] in
            for await status in transitions {
                guard let self else { return }
                await self.handle(status)
            }
        }
        if resumeSavedConnection, await connection.currentState()?.clientId.isEmpty == false {
            Task { _ = await connection.connect() }
        }
    }

    public func stop() async {
        lifecycleTask?.cancel(); lifecycleTask = nil
        reconcileTask?.cancel(); reconcileTask = nil
        await watcher.stop()
        await refresher.cancelPending()
    }

    /// Applies one connection status. Public for tests and for callers that already know it.
    public func handle(_ status: T3ConnectionStatus) async {
        guard status != lastHandledStatus else { return }
        lastHandledStatus = status
        switch status {
        case .connected(let environmentId, _):
            await watcher.start(environmentId: environmentId, projectIds: await watchedProjects(environmentId))
            await refresher.markReachability(.otherServer, forEnvironmentOtherThan: environmentId)
            await runtime.reconcileLaunches()
            await runtime.retryPendingCleanups()
            reconcileTask?.cancel()
            let runtime = self.runtime
            reconcileTask = Task { await runtime.runPeriodicReconcile() }
        case .otherServer(_, let actual):
            await stopLiveUpdates()
            await refresher.markReachability(.otherServer, forEnvironmentOtherThan: actual)
        case .unreachable, .unauthorized, .disconnected, .serverTooOld, .accessTooLow:
            await stopLiveUpdates()
            if let environmentId = await connection.currentState()?.environmentId {
                await refresher.markUnreachable(environmentId: environmentId)
            }
        case .signingIn:
            break
        }
    }

    private func stopLiveUpdates() async {
        reconcileTask?.cancel(); reconcileTask = nil
        await watcher.stop()
        await refresher.cancelPending()
    }

    /// T3 projects with agents on this server that still need watching.
    private func watchedProjects(_ environmentId: String) async -> [String] {
        let records = (try? await store.t3Subtasks()) ?? []
        return Array(Set(records.compactMap { record -> String? in
            if let reference = record.subtask.t3, reference.environmentId == environmentId,
               record.subtask.status != .completed || reference.cleanup?.isPending == true {
                return reference.projectId
            }
            if let intent = record.subtask.t3Launch, intent.environmentId == environmentId { return intent.projectId }
            return nil
        })).sorted()
    }

    /// Call after a launch, so a newly used project is watched too.
    public func watchProjectsAgain() async {
        guard case .connected(let environmentId, _) = await connection.currentStatus() else { return }
        let projects = await watchedProjects(environmentId)
        let watched = await watcher.watchedProjectIds
        let running = await watcher.isRunning
        if Set(projects) != Set(watched) || !running {
            await watcher.start(environmentId: environmentId, projectIds: projects)
        }
    }
}
