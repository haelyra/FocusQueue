import Foundation
import Testing
@testable import FocusQueueCore

/// A one-shot latch a fake tool call can wait on until the test opens it.
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Tracks how many fake calls run at once.
private actor ConcurrencyMeter {
    private(set) var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

/// A scripted T3 thread whose state the dirty triggers change.
private actor FakeThreadServer {
    var questions: [String] = []
    var activeRunId: String? = "R1"
    var status = "running"
    var runs = [T3Run(runId: "R1", ordinal: 1, status: "running")]
    private(set) var snapshotCount = 0

    enum Trigger: CaseIterable, Sendable { case needsInput, inputResolved, runSettled }

    func apply(_ trigger: Trigger) {
        switch trigger {
        case .needsInput: questions = ["Q1"]
        case .inputResolved: questions = []
        case .runSettled:
            activeRunId = nil
            status = "idle"
            runs = [T3Run(runId: "R1", ordinal: 1, status: "completed")]
        }
    }

    func snapshot() -> (T3ThreadSnapshot, Int) {
        snapshotCount += 1
        return (T3Samples.snapshot(status: status, active: activeRunId, pending: questions.count, runs: runs), snapshotCount)
    }
    func currentSnapshot() -> T3ThreadSnapshot {
        T3Samples.snapshot(status: status, active: activeRunId, pending: questions.count, runs: runs)
    }
}

@Suite("T3Refresher")
struct T3RefresherTests {
    let clock = ManualT3Clock()
    let tools = FakeT3Tools()
    let connection = FakeT3Connection()
    let location = T3SubtaskLocation(ticketID: "FOC-1", subtaskID: "SUB_1")

    private func makeStore(_ subtasks: [(T3SubtaskLocation, TaskSubtask)]? = nil) -> FakeT3Store {
        let records = (subtasks ?? [(location, T3Samples.t3Subtask())]).map { T3SubtaskRecord(location: $0.0, subtask: $0.1) }
        return FakeT3Store(records)
    }

    private func makeRefresher(_ store: FakeT3Store) -> T3Refresher {
        T3Refresher(tools: tools, store: store, connection: connection, clock: clock)
    }

    private func snapshotCalls() async -> Int {
        await tools.callCount { if case .snapshot = $0 { true } else { false } }
    }

    /// Advances the manual clock in small steps, letting woken work run between steps.
    private func step(_ seconds: Double, by increment: Double = 0.05) async {
        var elapsed = 0.0
        while elapsed < seconds - 1e-9 {
            await clock.advance(by: increment)
            try? await Task.sleep(nanoseconds: 1_000_000)
            elapsed += increment
        }
    }

    /// Waits until the debounce task is sleeping on the clock, so advancing time reaches it.
    private func debounceStarted(_ count: Int = 1) async {
        let clock = clock
        _ = await eventually(timeout: 10) { clock.pendingSleepers >= count }
    }

    /// Advances the clock until every debounce and refresh has finished.
    private func drain(_ refresher: T3Refresher) async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            await clock.settle()
            if await refresher.isIdle { return true }
            await clock.advance(by: 0.05)
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await refresher.isIdle
    }

    private func expectMatches(_ subtask: TaskSubtask?, _ expected: T3Derived,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        guard let subtask, var saved = subtask.t3 else {
            Issue.record("missing subtask", sourceLocation: sourceLocation); return
        }
        var reference = expected.reference
        saved.lastSnapshotAt = nil
        reference.lastSnapshotAt = nil
        #expect(saved == reference, sourceLocation: sourceLocation)
        #expect(subtask.status == expected.status, sourceLocation: sourceLocation)
        #expect(subtask.attention == expected.attention, sourceLocation: sourceLocation)
    }

    // MARK: Ordering

    fileprivate static let orderings: [[FakeThreadServer.Trigger]] = [
        [.needsInput, .inputResolved, .runSettled],
        [.needsInput, .runSettled, .inputResolved],
        [.inputResolved, .needsInput, .runSettled],
        [.inputResolved, .runSettled, .needsInput],
        [.runSettled, .needsInput, .inputResolved],
        [.runSettled, .inputResolved, .needsInput],
    ]

    @Test(arguments: Array(0..<6))
    func everyTriggerOrderingSavesTheNewestSnapshot(index: Int) async throws {
        let ordering = Self.orderings[index]
        let server = FakeThreadServer()
        let store = makeStore()
        let refresher = makeRefresher(store)
        // Each snapshot takes a different time; rotate the pattern per ordering.
        let pattern: [Double] = [1.0, 0.1, 0.6, 0.3]
        let delays = Array(pattern[(index % pattern.count)...] + pattern[..<(index % pattern.count)])
        let clock = clock
        await tools.set {
            $0.onSnapshot = { _ in
                let (snapshot, count) = await server.snapshot()
                try await clock.sleep(seconds: delays[(count - 1) % delays.count])
                return snapshot
            }
            $0.onQuestionIds = { _ in await server.questions }
        }

        for trigger in ordering {
            await server.apply(trigger)
            let sleeping = clock.pendingSleepers
            await refresher.markDirty("THREAD_1")
            _ = await eventually(timeout: 10) { clock.pendingSleepers > sleeping }
            await step(0.3)
        }
        #expect(await drain(refresher))

        let expected = T3StateDeriver.derive(snapshot: await server.currentSnapshot(), questionIds: await server.questions,
                                             previous: T3Samples.reference(), pausedAt: nil)
        expectMatches(await store.records[location], expected)
        #expect(await snapshotCalls() >= 1)
    }

    // MARK: Debounce

    @Test func twoMarksInsideTheWindowMakeOneSnapshotCall() async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        await tools.set { $0.onSnapshot = { _ in T3Samples.snapshot(status: "running", active: "R1") } }

        await refresher.markDirty("THREAD_1")
        await debounceStarted()
        await step(0.1)
        await refresher.markDirty("THREAD_1")
        #expect(await drain(refresher))
        #expect(await snapshotCalls() == 1)
        #expect(clock.sleepRequests == [0.25])

        // A mark after the window refreshes again.
        await refresher.markDirty("THREAD_1")
        #expect(await drain(refresher))
        #expect(await snapshotCalls() == 2)
    }

    @Test func noSnapshotBeforeTheDebounceElapses() async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        await tools.set { $0.onSnapshot = { _ in T3Samples.snapshot() } }
        await refresher.markDirty("THREAD_1")
        await debounceStarted()
        await step(0.2)
        #expect(await snapshotCalls() == 0)
        #expect(await drain(refresher))
        #expect(await snapshotCalls() == 1)
    }

    @Test func cancelPendingDropsTheDebouncedRefresh() async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        await refresher.markDirty("THREAD_1")
        await refresher.cancelPending()
        #expect(await drain(refresher))
        #expect(await snapshotCalls() == 0)
    }

    // MARK: Stale responses

    @Test func slowOlderResponseNeverOverwritesNewerState() async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        let gate = Gate()
        await tools.set {
            $0.onSnapshot = { _ in
                // The first call is slow and returns the older "running" state.
                if await self.snapshotCalls() == 1 {
                    await gate.wait()
                    return T3Samples.snapshot(status: "running", active: "R1")
                }
                return T3Samples.snapshot(runs: [T3Run(runId: "R1", ordinal: 1, status: "completed")])
            }
        }

        await refresher.markDirty("THREAD_1")
        await debounceStarted()
        await step(0.3)
        #expect(await eventually(timeout: 10) { await snapshotCalls() == 1 })

        // A newer trigger is queued while the old snapshot is in flight.
        let newer = Task { await refresher.refreshNow("THREAD_1") }
        await clock.settle()
        await gate.release()
        await newer.value
        #expect(await drain(refresher))

        let saved = await store.savedValues()
        #expect(saved.count == 1)
        #expect(saved.allSatisfy { $0.status == .idle })
        let record = await store.records[location]
        #expect(record?.status == .idle)
        #expect(record?.t3?.latestTerminalRunId == "R1")
        #expect(record?.completionUnread == true)
    }

    @Test func queuedOlderRefreshIsSkippedWithoutACall() async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        let gate = Gate()
        await tools.set {
            $0.onSnapshot = { _ in
                if await self.snapshotCalls() == 1 { await gate.wait() }
                return T3Samples.snapshot(status: "running", active: "R1")
            }
        }
        let first = Task { await refresher.refreshNow("THREAD_1") }
        #expect(await eventually(timeout: 10) { await snapshotCalls() == 1 })
        let second = Task { await refresher.refreshNow("THREAD_1") }
        let third = Task { await refresher.refreshNow("THREAD_1") }
        await clock.settle()
        await gate.release()
        _ = await (first.value, second.value, third.value)
        // The first was in flight; the second was superseded by the third before it started.
        #expect(await snapshotCalls() == 2)
        #expect(await store.savedValues().count == 1)
    }

    // MARK: Server binding and errors

    @Test func otherServerSubtaskMakesNoToolCalls() async throws {
        let store = makeStore([(location, T3Samples.t3Subtask(env: "ENV_OTHER"))])
        let refresher = makeRefresher(store)
        await refresher.refreshNow("THREAD_1")
        #expect(await tools.calls.isEmpty)
        #expect(await store.records[location]?.t3?.reachability == .otherServer)
        #expect(await store.records[location]?.status == .working)

        // Already marked: no further write.
        await refresher.refreshNow("THREAD_1")
        #expect(await store.savedValues().count == 1)
    }

    @Test func threadNotFoundMarksThreadMissing() async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        await tools.set { $0.onSnapshot = { id in throw T3Error.threadNotFound(id) } }
        await refresher.refreshNow("THREAD_1")
        let record = await store.records[location]
        #expect(record?.t3?.reachability == .threadMissing)
        #expect(record?.status == .working)
        #expect(await connection.reported.isEmpty)
    }

    @Test(arguments: [T3Error.notRunning, .outcomeUnknown("timeout"), .unauthorized])
    func connectivityErrorsLeaveStateAndReport(error: T3Error) async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        await tools.set { $0.onSnapshot = { _ in throw error } }
        await refresher.refreshNow("THREAD_1")
        #expect(await store.savedValues().isEmpty)
        #expect(await connection.reported == [error])
    }

    @Test func otherErrorsLeaveStateWithoutReporting() async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        await tools.set { $0.onSnapshot = { _ in throw T3Error.rejected(code: "x", message: "no") } }
        await refresher.refreshNow("THREAD_1")
        await tools.set { $0.onSnapshot = { _ in throw CancellationError() } }
        await refresher.refreshNow("THREAD_1")
        #expect(await store.savedValues().isEmpty)
        #expect(await connection.reported.isEmpty)
    }

    @Test func questionListFailureIsHandledLikeSnapshotFailure() async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        await tools.set {
            $0.onSnapshot = { _ in T3Samples.snapshot(pending: 1) }
            $0.onQuestionIds = { _ in throw T3Error.notRunning }
        }
        await refresher.refreshNow("THREAD_1")
        #expect(await store.savedValues().isEmpty)
        #expect(await connection.reported == [.notRunning])
    }

    @Test func notConnectedMakesNoCalls() async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        await connection.setStatus(.unreachable)
        await refresher.refreshNow("THREAD_1")
        #expect(await tools.calls.isEmpty)
        #expect(await store.savedValues().isEmpty)
    }

    @Test func completedSubtaskIsNeverTouched() async throws {
        let store = makeStore([(location, T3Samples.t3Subtask(status: .completed))])
        let refresher = makeRefresher(store)
        await tools.set { $0.onSnapshot = { _ in T3Samples.snapshot(status: "running", active: "R1") } }
        await refresher.refreshNow("THREAD_1")
        #expect(await tools.calls.isEmpty)
        #expect(await store.savedValues().isEmpty)
    }

    @Test func subtaskCompletedDuringTheCallIsNotOverwritten() async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        let location = location
        await tools.set {
            $0.onSnapshot = { _ in
                var done = T3Samples.t3Subtask(status: .completed)
                done.completionUnread = false
                await store.put(location, done)
                return T3Samples.snapshot(status: "running", active: "R1")
            }
        }
        await refresher.refreshNow("THREAD_1")
        #expect(await store.records[location]?.status == .completed)
        #expect(await store.records[location]?.t3?.lastSnapshotAt == nil)
    }

    @Test func unknownThreadMakesNoCalls() async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        await refresher.refreshNow("THREAD_NOPE")
        #expect(await tools.calls.isEmpty)
    }

    // MARK: Applying the derived state

    @Test func questionIdsAreOnlyFetchedWhenRequestsArePending() async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        await tools.set {
            $0.onSnapshot = { _ in T3Samples.snapshot(status: "running", active: "R1") }
            $0.onQuestionIds = { _ in ["Q1"] }
        }
        await refresher.refreshNow("THREAD_1")
        #expect(await tools.calls == [.snapshot("THREAD_1")])

        await tools.set { $0.onSnapshot = { _ in T3Samples.snapshot(status: "running", active: "R1", pending: 2) } }
        await refresher.refreshNow("THREAD_1")
        #expect(await tools.calls.suffix(2) == [.snapshot("THREAD_1"), .questionIds("THREAD_1")])
        let record = await store.records[location]
        #expect(record?.status == .blocked)
        #expect(record?.attention == .question)
        #expect(record?.t3?.openQuestionIds == ["Q1"])
        #expect(record?.t3?.pendingApprovalCount == 1)
    }

    @Test func workingRefreshKeepsTheHeartbeatFresh() async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        await tools.set { $0.onSnapshot = { _ in T3Samples.snapshot(status: "running", active: "R1") } }
        await refresher.refreshNow("THREAD_1")
        let first = await store.records[location]
        #expect(first?.lastHeartbeatAt == clock.now())
        #expect(first?.t3?.lastSnapshotAt == clock.now())
        #expect(first?.effectiveStatus(now: clock.now()) == .working)

        await clock.advance(by: 600)
        await refresher.refreshNow("THREAD_1")
        let second = await store.records[location]
        #expect(second?.lastHeartbeatAt == clock.now())
        #expect(second?.effectiveStatus(now: clock.now()) == .working)
    }

    @Test func idleRefreshDoesNotTouchTheHeartbeat() async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        await tools.set { $0.onSnapshot = { _ in T3Samples.snapshot() } }
        await refresher.refreshNow("THREAD_1")
        #expect(await store.records[location]?.lastHeartbeatAt == nil)
        #expect(await store.records[location]?.status == .idle)
    }

    @Test func newCompletedRunSetsUnreadOnce() async throws {
        let store = makeStore()
        let refresher = makeRefresher(store)
        await tools.set { $0.onSnapshot = { _ in T3Samples.snapshot(runs: [T3Run(runId: "R1", ordinal: 1, status: "completed")]) } }
        await refresher.refreshNow("THREAD_1")
        #expect(await store.records[location]?.completionUnread == true)

        // The user reads it; the same snapshot does not mark it again.
        try await store.mutate(location) { $0.completionUnread = false }
        await refresher.refreshNow("THREAD_1")
        #expect(await store.records[location]?.completionUnread == false)
    }

    @Test func storedPauseSuppressesInterruptedAttention() async throws {
        var paused = T3Samples.t3Subtask()
        paused.pausedAt = Date(timeIntervalSince1970: 1)
        let store = makeStore([(location, paused)])
        let refresher = makeRefresher(store)
        await tools.set { $0.onSnapshot = { _ in T3Samples.snapshot(runs: [T3Run(runId: "R1", ordinal: 1, status: "interrupted")]) } }
        await refresher.refreshNow("THREAD_1")
        let record = await store.records[location]
        #expect(record?.status == .idle)
        #expect(record?.attention == nil)
        #expect(record?.pausedAt == Date(timeIntervalSince1970: 1))
    }

    @Test func indexReloadsOnMissAndAfterAMove() async throws {
        let store = makeStore([])
        let refresher = makeRefresher(store)
        await tools.set { $0.onSnapshot = { _ in T3Samples.snapshot() } }
        await refresher.refreshNow("THREAD_1")
        #expect(await tools.calls.isEmpty)

        await store.put(location, T3Samples.t3Subtask())
        await refresher.refreshNow("THREAD_1")
        #expect(await snapshotCalls() == 1)
        #expect(await store.records[location]?.t3?.lastSnapshotAt != nil)

        // The thread is rebound to another subtask; the cached location is stale.
        let moved = T3SubtaskLocation(ticketID: "FOC-2", subtaskID: "SUB_2")
        await store.put(location, T3Samples.t3Subtask(thread: "THREAD_OLD"))
        await store.put(moved, T3Samples.t3Subtask(id: "SUB_2"))
        await refresher.refreshNow("THREAD_1")
        #expect(await snapshotCalls() == 2)
        #expect(await store.records[moved]?.t3?.lastSnapshotAt != nil)
    }

    // MARK: resyncAll

    @Test func resyncAllRefreshesOpenSubtasksFourAtATime() async throws {
        var entries: [(T3SubtaskLocation, TaskSubtask)] = (1...6).map { n in
            (T3SubtaskLocation(ticketID: "FOC-1", subtaskID: "SUB_\(n)"), T3Samples.t3Subtask(id: "SUB_\(n)", thread: "T\(n)"))
        }
        let done = T3SubtaskLocation(ticketID: "FOC-1", subtaskID: "SUB_7")
        let elsewhere = T3SubtaskLocation(ticketID: "FOC-1", subtaskID: "SUB_8")
        entries.append((done, T3Samples.t3Subtask(id: "SUB_7", thread: "T7", status: .completed)))
        entries.append((elsewhere, T3Samples.t3Subtask(id: "SUB_8", thread: "T8", env: "ENV_OTHER")))
        let store = makeStore(entries)
        let refresher = makeRefresher(store)
        let meter = ConcurrencyMeter()
        let clock = clock
        await tools.set {
            $0.onSnapshot = { id in
                await meter.enter()
                try? await clock.sleep(seconds: 1)
                await meter.leave()
                return T3Samples.snapshot(id, status: "running", active: "R1")
            }
        }

        let resync = Task { await refresher.resyncAll() }
        #expect(await eventually(timeout: 10) { await meter.current == 4 })
        await clock.settle()
        #expect(await meter.current == 4)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let calls = await snapshotCalls()
            let running = await meter.current
            if calls == 6 && running == 0 { break }
            await clock.advance(by: 1)
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await resync.value

        #expect(await meter.peak == 4)
        #expect(await snapshotCalls() == 6)
        #expect(await tools.calls.contains(.snapshot("T7")) == false)
        #expect(await tools.calls.contains(.snapshot("T8")) == false)
        for n in 1...6 {
            let record = await store.records[T3SubtaskLocation(ticketID: "FOC-1", subtaskID: "SUB_\(n)")]
            #expect(record?.t3?.observedStatus == "running")
        }
        #expect(await store.records[done]?.t3?.lastSnapshotAt == nil)
        #expect(await store.records[elsewhere]?.t3?.reachability == .otherServer)
        #expect(await refresher.isIdle)
    }

    // MARK: Reachability helpers

    @Test func reachabilityHelpersMarkOpenSubtasksByServer() async throws {
        let mine = location
        let other = T3SubtaskLocation(ticketID: "FOC-1", subtaskID: "SUB_2")
        let done = T3SubtaskLocation(ticketID: "FOC-1", subtaskID: "SUB_3")
        let store = makeStore([
            (mine, T3Samples.t3Subtask()),
            (other, T3Samples.t3Subtask(id: "SUB_2", thread: "T2", env: "ENV_OTHER")),
            (done, T3Samples.t3Subtask(id: "SUB_3", thread: "T3", status: .completed)),
        ])
        let refresher = makeRefresher(store)

        await refresher.markUnreachable(environmentId: T3Samples.env)
        #expect(await store.records[mine]?.t3?.reachability == .unreachable)
        #expect(await store.records[other]?.t3?.reachability == .reachable)
        #expect(await store.records[done]?.t3?.reachability == .reachable)

        await refresher.markReachability(.otherServer, forEnvironmentOtherThan: T3Samples.env)
        #expect(await store.records[mine]?.t3?.reachability == .unreachable)
        #expect(await store.records[other]?.t3?.reachability == .otherServer)
        #expect(await store.records[done]?.t3?.reachability == .reachable)
        #expect(await tools.calls.isEmpty)

        // Already marked: no extra writes.
        let writes = await store.savedValues().count
        await refresher.markUnreachable(environmentId: T3Samples.env)
        #expect(await store.savedValues().count == writes)
    }

    @Test func successfulRefreshRestoresReachability() async throws {
        var unreachable = T3Samples.t3Subtask()
        unreachable.t3?.reachability = .unreachable
        let store = makeStore([(location, unreachable)])
        let refresher = makeRefresher(store)
        await tools.set { $0.onSnapshot = { _ in T3Samples.snapshot(status: "running", active: "R1") } }
        await refresher.refreshNow("THREAD_1")
        #expect(await store.records[location]?.t3?.reachability == .reachable)
    }
}
