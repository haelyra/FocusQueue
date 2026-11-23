import Foundation

/// What the watcher asks of the refresher. `T3Refresher` conforms.
public protocol T3RefreshTarget: T3DirtyMarking {
    /// Refreshes every active T3 agent from a fresh snapshot.
    func resyncAll() async
}

/// Turns T3 Code's events and a per-project thread-list poll into refresh
/// requests. Events are fast but say nothing when a turn starts elsewhere; the
/// poll catches those. Neither carries state: refreshes read fresh snapshots.
public actor T3Watcher {
    public static let backoffSeconds: [Double] = [1, 2, 4, 8, 16, 30]
    public static let heartbeatMs = 15_000

    private let transport: any T3MCPTransporting
    private let tools: any T3ToolCalling
    private let target: any T3RefreshTarget
    private let store: any T3SubtaskStoring
    private let connection: any T3ConnectionProviding
    private let clock: any T3Clock
    private let pollSeconds: Double
    private let silenceSeconds: Double

    private var environmentId: String?
    private var projectIds: [String] = []
    private var generation = 0
    private var supervisors: [String: Task<Void, Never>] = [:]
    private var connections: [String: Task<Bool, Never>] = [:]
    private var pollTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var activeStreams: Set<String> = []
    private var initialResyncDone = false
    private var epochs: [String: String] = [:]
    private var lastMessageAt: [String: Date] = [:]
    private var lastRows: [String: RowState] = [:]
    private(set) public var isRunning = false

    public static let heartbeatTouchSeconds: Double = 60
    private var heartbeatTouchedAt: [String: Date] = [:]

    private func touchHeartbeat(_ location: T3SubtaskLocation, threadId: String) async {
        let now = clock.now()
        if let last = heartbeatTouchedAt[threadId], now.timeIntervalSince(last) < Self.heartbeatTouchSeconds { return }
        heartbeatTouchedAt[threadId] = now
        _ = try? await store.mutate(location) { subtask in
            guard subtask.status == .working else { return }
            subtask.lastHeartbeatAt = now
        }
    }

    private struct RowState: Equatable {
        var status: String
        var latestRunId: String?
        var updatedAt: String?
    }

    public init(transport: any T3MCPTransporting, tools: any T3ToolCalling, target: any T3RefreshTarget,
                store: any T3SubtaskStoring, connection: any T3ConnectionProviding,
                clock: any T3Clock = SystemT3Clock(), pollSeconds: Double = 5, silenceSeconds: Double = 30) {
        self.transport = transport; self.tools = tools; self.target = target; self.store = store
        self.connection = connection; self.clock = clock
        self.pollSeconds = pollSeconds; self.silenceSeconds = silenceSeconds
    }

    /// Opens the three event streams, resyncs once all are active, and starts the list poll.
    public func start(environmentId: String, projectIds: [String]) {
        stop()
        generation += 1
        isRunning = true
        self.environmentId = environmentId
        self.projectIds = Array(Set(projectIds)).sorted()
        let current = generation
        for name in T3EventName.watched {
            supervisors[name] = Task { await self.supervise(name, generation: current) }
        }
        pollTask = Task { await self.pollLoop(generation: current) }
        watchdogTask = Task { await self.watchdogLoop(generation: current) }
    }

    /// Restarts streams for a new project set, resyncing again once they are active.
    public func updateProjects(_ projectIds: [String]) {
        guard let environmentId else { return }
        let next = Array(Set(projectIds)).sorted()
        guard next != self.projectIds || !isRunning else { return }
        start(environmentId: environmentId, projectIds: next)
    }

    public var watchedProjectIds: [String] { projectIds }

    public func stop() {
        generation += 1
        isRunning = false
        for task in supervisors.values { task.cancel() }
        for task in connections.values { task.cancel() }
        pollTask?.cancel(); watchdogTask?.cancel()
        supervisors = [:]; connections = [:]; pollTask = nil; watchdogTask = nil
        activeStreams = []; initialResyncDone = false; epochs = [:]; lastMessageAt = [:]; lastRows = [:]
    }

    // MARK: - Streams

    private func supervise(_ name: String, generation: Int) async {
        var attempt = 0
        while generation == self.generation, !Task.isCancelled {
            let arguments: JSONValue = ["projectIds": .array(projectIds.map(JSONValue.string))]
            let stream = await transport.stream(name: name, arguments: arguments, heartbeatMs: Self.heartbeatMs)
            guard generation == self.generation else { return }
            lastMessageAt[name] = clock.now()
            let connection = Task { await self.consume(stream, name: name, generation: generation) }
            connections[name] = connection
            let becameActive = await connection.value
            guard generation == self.generation, !Task.isCancelled else { return }
            activeStreams.remove(name)
            if becameActive { attempt = 0 }
            let delay = Self.backoffSeconds[min(attempt, Self.backoffSeconds.count - 1)]
            attempt += 1
            do { try await clock.sleep(seconds: delay) } catch { return }
        }
    }

    /// Consumes one connection. Returns whether it reached `active`.
    private func consume(_ stream: AsyncThrowingStream<T3StreamMessage, any Error>, name: String,
                         generation: Int) async -> Bool {
        var becameActive = false
        do {
            for try await message in stream {
                guard generation == self.generation, !Task.isCancelled else { return becameActive }
                lastMessageAt[name] = clock.now()
                switch message {
                case .active(let cursor, _, _):
                    becameActive = true
                    activated(name, cursor: cursor)
                case .event(let occurrence):
                    if let epoch = T3Cursor(occurrence.cursor)?.epoch, let known = epochs[name], known != epoch {
                        // The server's event buffer restarted: reconnect and resync.
                        epochs[name] = nil
                        return becameActive
                    }
                    if let threadId = occurrence.threadId { await target.markDirty(threadId) }
                case .heartbeat:
                    break
                case .error, .terminated:
                    return becameActive
                }
            }
        } catch let error as T3Error {
            if error == .unauthorized || error == .notRunning {
                stop()
                await connection.report(error)
            }
        } catch {}
        return becameActive
    }

    /// The first resync waits for all three streams. After that, every `active`
    /// is a reconnect, which can hide missed events (a truncated buffer or a new
    /// epoch included), so it resyncs too. Snapshots make extra resyncs harmless.
    private func activated(_ name: String, cursor: String) {
        if let epoch = T3Cursor(cursor)?.epoch { epochs[name] = epoch }
        activeStreams.insert(name)
        if !initialResyncDone {
            guard activeStreams.count == T3EventName.watched.count else { return }
            initialResyncDone = true
        }
        resync()
    }

    private func resync() {
        let target = self.target
        Task { await target.resyncAll() }
    }

    /// Restarts any stream silent for longer than `silenceSeconds`.
    private func watchdogLoop(generation: Int) async {
        let interval = max(1, silenceSeconds / 3)
        while generation == self.generation, !Task.isCancelled {
            do { try await clock.sleep(seconds: interval) } catch { return }
            guard generation == self.generation else { return }
            let now = clock.now()
            for (name, last) in lastMessageAt where now.timeIntervalSince(last) > silenceSeconds {
                lastMessageAt[name] = now
                connections[name]?.cancel()
            }
        }
    }

    // MARK: - List poll

    private func pollLoop(generation: Int) async {
        while generation == self.generation, !Task.isCancelled {
            await pollOnce(generation: generation)
            do { try await clock.sleep(seconds: pollSeconds) } catch { return }
        }
    }

    private func pollOnce(generation: Int) async {
        guard !projectIds.isEmpty else { return }
        var locations: [String: T3SubtaskLocation] = [:]
        for record in (try? await store.t3Subtasks()) ?? [] {
            guard let reference = record.subtask.t3, reference.environmentId == environmentId,
                  record.subtask.status != .completed else { continue }
            locations[reference.threadId] = record.location
        }
        let known = Set(locations.keys)
        for projectId in projectIds {
            let rows: [T3ThreadRow]
            do { rows = try await tools.list(projectId: projectId) }
            catch let error as T3Error {
                if error == .unauthorized || error == .notRunning {
                    stop()
                    await connection.report(error)
                    return
                }
                continue
            } catch { continue }
            guard generation == self.generation else { return }
            for row in rows {
                let state = RowState(status: row.status, latestRunId: row.latestRunId, updatedAt: row.updatedAt)
                let previous = lastRows.updateValue(state, forKey: row.threadId)
                if let previous, previous != state, known.contains(row.threadId) {
                    await target.markDirty(row.threadId)
                }
                // A long turn can run silently. Its row still says running, so keep
                // the agent's heartbeat fresh without reading the thread.
                if T3RunStatus.active.contains(row.status), let location = locations[row.threadId] {
                    await touchHeartbeat(location, threadId: row.threadId)
                }
            }
        }
    }
}
extension T3Refresher: T3RefreshTarget {}
