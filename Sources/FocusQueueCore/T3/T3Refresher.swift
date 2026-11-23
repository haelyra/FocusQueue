import Foundation

/// Turns "this thread may have changed" into a saved row state derived from a fresh snapshot.
///
/// - `markDirty` debounces per thread, then refreshes.
/// - Refreshes for one thread run one at a time, in order. Each gets a generation number when it is
///   queued; a refresh whose generation is no longer the newest for its thread skips its call or
///   drops its result, so an older response never overwrites a newer saved state.
/// - Subtasks bound to another T3 server are marked `.otherServer` without any tool call.
public actor T3Refresher {
    private let tools: any T3ToolCalling
    private let store: any T3SubtaskStoring
    private let connection: any T3ConnectionProviding
    private let clock: any T3Clock
    private let debounceSeconds: Double
    private let maxConcurrent: Int

    private var locations: [String: T3SubtaskLocation] = [:]
    private var debouncing: [String: Task<Void, Never>] = [:]
    private var generations: [String: Int] = [:]
    /// The last queued refresh per thread and its generation; the next refresh awaits it.
    private var tails: [String: (generation: Int, task: Task<Void, Never>)] = [:]

    public init(tools: any T3ToolCalling, store: any T3SubtaskStoring, connection: any T3ConnectionProviding,
                clock: any T3Clock = SystemT3Clock(), debounceSeconds: Double = 0.25, maxConcurrent: Int = 4) {
        self.tools = tools; self.store = store; self.connection = connection; self.clock = clock
        self.debounceSeconds = debounceSeconds; self.maxConcurrent = max(1, maxConcurrent)
    }

    /// No debounce pending and no refresh queued or running.
    public var isIdle: Bool { debouncing.isEmpty && tails.isEmpty }

    // MARK: - Triggers

    /// Refreshes `threadId` after the debounce window. Calls inside the window coalesce into one refresh.
    public func markDirty(_ threadId: String) {
        guard debouncing[threadId] == nil else { return }
        let clock = clock, seconds = debounceSeconds
        debouncing[threadId] = Task { [weak self] in
            let fired: Bool
            do { try await clock.sleep(seconds: seconds); fired = true } catch { fired = false }
            await self?.debounceEnded(threadId, fire: fired)
        }
    }

    /// Refreshes `threadId` now, after any refresh already queued for it, and returns when done.
    public func refreshNow(_ threadId: String) async {
        await enqueue(threadId).value
    }

    /// Refreshes every T3 subtask that is not completed, at most `maxConcurrent` at a time.
    public func resyncAll() async {
        guard let records = try? await reloadIndex() else { return }
        var seen = Set<String>()
        let threadIds = records.compactMap { record -> String? in
            guard record.subtask.status != .completed, let id = record.subtask.t3?.threadId,
                  seen.insert(id).inserted else { return nil }
            return id
        }
        let limit = maxConcurrent
        await withTaskGroup(of: Void.self) { group in
            var pending = threadIds.makeIterator()
            for _ in 0..<limit {
                guard let id = pending.next() else { break }
                group.addTask { await self.refreshNow(id) }
            }
            while await group.next() != nil {
                if let id = pending.next() { group.addTask { await self.refreshNow(id) } }
            }
        }
    }

    /// Cancels pending debounces. Refreshes already running finish.
    public func cancelPending() {
        for task in debouncing.values { task.cancel() }
        debouncing.removeAll()
    }

    // MARK: - Reachability helpers (no tool calls)

    /// Marks every open T3 subtask on `environmentId` unreachable, e.g. when the connection drops.
    public func markUnreachable(environmentId: String) async {
        await markReachability(.unreachable) { $0 == environmentId }
    }

    /// Marks every open T3 subtask whose server is not `environmentId` with `reachability`,
    /// e.g. `.otherServer` after connecting to a different server.
    public func markReachability(_ reachability: T3Reachability, forEnvironmentOtherThan environmentId: String) async {
        await markReachability(reachability) { $0 != environmentId }
    }

    private func markReachability(_ reachability: T3Reachability, where matches: @Sendable (String) -> Bool) async {
        guard let records = try? await reloadIndex() else { return }
        for record in records {
            guard record.subtask.status != .completed, let reference = record.subtask.t3,
                  matches(reference.environmentId), reference.reachability != reachability else { continue }
            _ = try? await store.mutate(record.location) { subtask in
                guard subtask.status != .completed, subtask.t3 != nil else { return }
                subtask.t3?.reachability = reachability
            }
        }
    }

    // MARK: - Queueing

    private func debounceEnded(_ threadId: String, fire: Bool) {
        debouncing[threadId] = nil
        if fire { _ = enqueue(threadId) }
    }

    private func enqueue(_ threadId: String) -> Task<Void, Never> {
        let generation = (generations[threadId] ?? 0) + 1
        generations[threadId] = generation
        let previous = tails[threadId]?.task
        let task = Task {
            await previous?.value
            await self.refresh(threadId, generation: generation)
            self.finished(threadId, generation: generation)
        }
        tails[threadId] = (generation, task)
        return task
    }

    private func finished(_ threadId: String, generation: Int) {
        if tails[threadId]?.generation == generation { tails[threadId] = nil }
    }

    private func isCurrent(_ threadId: String, _ generation: Int) -> Bool {
        generations[threadId] == generation
    }

    // MARK: - Refresh

    private func refresh(_ threadId: String, generation: Int) async {
        guard isCurrent(threadId, generation),
              let (location, reference) = await locate(threadId) else { return }
        guard let environmentId = await connection.currentStatus().connectedEnvironmentId else { return }
        guard reference.environmentId == environmentId else {
            guard reference.reachability != .otherServer else { return }
            await save(location, environmentId: reference.environmentId) { $0.t3?.reachability = .otherServer }
            return
        }

        let snapshot: T3ThreadSnapshot
        let questionIds: [String]
        do {
            snapshot = try await tools.snapshot(threadId: threadId)
            questionIds = snapshot.thread.pendingRequestCount > 0 ? try await tools.questionIds(threadId: threadId) : []
        } catch let error as T3Error {
            await handle(error, location: location, environmentId: environmentId, generation: generation, threadId: threadId)
            return
        } catch {
            return
        }

        guard isCurrent(threadId, generation) else { return }
        let now = clock.now()
        await save(location, environmentId: environmentId) { subtask in
            guard let previous = subtask.t3 else { return }
            let derived = T3StateDeriver.derive(snapshot: snapshot, questionIds: questionIds, previous: previous,
                                                pausedAt: subtask.pausedAt, now: now)
            subtask.t3 = derived.reference
            subtask.status = derived.status
            subtask.attention = derived.attention
            if derived.markUnread { subtask.completionUnread = true }
            // `TaskSubtask.effectiveStatus` decays `.working` without a recent heartbeat.
            if derived.status == .working { subtask.lastHeartbeatAt = now }
        }
    }

    private func handle(_ error: T3Error, location: T3SubtaskLocation, environmentId: String,
                        generation: Int, threadId: String) async {
        switch error {
        case .threadNotFound:
            guard isCurrent(threadId, generation) else { return }
            await save(location, environmentId: environmentId) { $0.t3?.reachability = .threadMissing }
        case .notRunning, .outcomeUnknown, .unauthorized:
            await connection.report(error)
        default:
            break // A definite rejection or bad response: keep the last good state.
        }
    }

    /// Applies `change` unless the subtask is completed or no longer bound to `environmentId`.
    private func save(_ location: T3SubtaskLocation, environmentId: String,
                      _ change: @escaping @Sendable (inout TaskSubtask) -> Void) async {
        _ = try? await store.mutate(location) { subtask in
            guard subtask.status != .completed, subtask.t3?.environmentId == environmentId else { return }
            change(&subtask)
        }
    }

    // MARK: - Index

    /// The open subtask bound to `threadId`, reloading the index on a miss or a stale entry.
    private func locate(_ threadId: String) async -> (T3SubtaskLocation, T3ThreadReference)? {
        if let location = locations[threadId], let found = await check(location, threadId) { return found }
        guard (try? await reloadIndex()) != nil, let location = locations[threadId] else { return nil }
        return await check(location, threadId)
    }

    private func check(_ location: T3SubtaskLocation, _ threadId: String) async -> (T3SubtaskLocation, T3ThreadReference)? {
        guard let subtask = try? await store.subtask(location), subtask.status != .completed,
              let reference = subtask.t3, reference.threadId == threadId else { return nil }
        return (location, reference)
    }

    @discardableResult
    private func reloadIndex() async throws -> [T3SubtaskRecord] {
        let records = try await store.t3Subtasks()
        var index: [String: T3SubtaskLocation] = [:]
        for record in records {
            guard let threadId = record.subtask.t3?.threadId else { continue }
            // Prefer the open subtask when a thread id appears more than once.
            if index[threadId] == nil || record.subtask.status != .completed { index[threadId] = record.location }
        }
        locations = index
        return records
    }
}
