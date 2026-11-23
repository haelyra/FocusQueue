import Foundation
import Testing
@testable import FocusQueueCore

private struct StubModels: T3ModelSelecting {
    var unavailable = false
    func modelSelection(instanceId: String, model: String, options: [String: JSONValue]) async throws -> [String: JSONValue] {
        if unavailable { throw T3Error.rejected(code: "model_unavailable", message: "\(model) is not available in T3 Code") }
        var value: [String: JSONValue] = ["instanceId": .string(instanceId), "model": .string(model)]
        if !options.isEmpty { value["options"] = .object(options) }
        return value
    }
}

private struct StubProjects: T3ProjectResolving {
    func projectId(for project: ProjectConfiguration, environmentId: String) async throws -> String { "PROJECT_1" }
}

private actor DirtyLog: T3DirtyMarking {
    private(set) var threads: [String] = []
    func markDirty(_ threadId: String) async { threads.append(threadId) }
}

private struct SaveFailure: Error {}

/// A fake T3 server that de-duplicates launches by request id, like T3 Code does.
private actor FakeServer {
    var threadsByRequest: [String: String] = [:]
    var worktreeByThread: [String: String] = [:]
    var titleByThread: [String: String] = [:]
    var dropReplies = 0
    func launch(_ request: T3LaunchRequest) throws -> T3LaunchResult {
        let id = threadsByRequest[request.clientRequestId] ?? "THREAD_\(threadsByRequest.count + 1)"
        threadsByRequest[request.clientRequestId] = id
        worktreeByThread[id] = request.worktreePath
        titleByThread[id] = request.title
        if dropReplies > 0 { dropReplies -= 1; throw T3Error.outcomeUnknown("reply lost") }
        return T3LaunchResult(threadId: id, link: "t3code://threads/\(id)", projectId: request.projectId)
    }
    func setDropReplies(_ count: Int) { dropReplies = count }
    func rows() -> [T3ThreadRow] {
        worktreeByThread.keys.sorted().map {
            T3ThreadRow(threadId: $0, title: titleByThread[$0] ?? "", status: "running",
                        createdAt: Date(timeIntervalSince1970: 1_800_000_000), link: "t3code://threads/\($0)")
        }
    }
    func snapshot(_ id: String) throws -> T3ThreadSnapshot {
        guard let path = worktreeByThread[id] else { throw T3Error.threadNotFound(id) }
        return T3Samples.snapshot(id, status: "running", worktree: path)
    }
    var threadCount: Int { worktreeByThread.count }
}

private struct Harness {
    let tools = FakeT3Tools()
    let store = FakeT3Store()
    let worktrees = FakeT3Worktrees()
    let connection: FakeT3Connection
    let clock = ManualT3Clock()
    let dirty = DirtyLog()
    let server = FakeServer()
    let runtime: T3Runtime

    init(status: T3ConnectionStatus = .connected(environmentId: T3Samples.env, version: "0.1.12"),
         access: T3AccessLevel = .fullAccess, models: StubModels = StubModels(),
         guardFolder: String? = nil) {
        connection = FakeT3Connection(status: status, accessLevel: access)
        runtime = T3Runtime(connection: connection, tools: tools, models: models, projects: StubProjects(),
                            worktrees: worktrees, store: store, dirty: dirty,
                            checkoutGuard: { _ in guardFolder }, clock: clock)
    }

    func scriptServer() async {
        let server = self.server
        await tools.set {
            $0.onLaunch = { try await server.launch($0) }
            $0.onList = { _ in await server.rows() }
            $0.onSnapshot = { try await server.snapshot($0) }
        }
    }

    static let location = T3SubtaskLocation(ticketID: "FOC-1", subtaskID: "SUB_1")

    func input() -> T3LaunchInput {
        let project = ProjectConfiguration(id: "fq", name: "Focus", dashboardPath: "/d", workspacePath: "/REPO",
                                           repositoryPath: "/REPO")
        return T3LaunchInput(ticketID: "FOC-1",
                             subtask: TaskSubtask(id: "SUB_1", title: "Add a README", provider: .claude, runtimeMode: .t3),
                             prompt: "Add a README", project: project, repositoryPath: "/REPO",
                             choice: T3LaunchChoice(instanceId: "claude", model: "claude-haiku-5-5", options: ["effort": "high"]))
    }
}

@Suite("T3 runtime launch")
struct T3RuntimeLaunchTests {
    @Test("A successful launch links the thread in the same save that clears the intent")
    func success() async throws {
        let h = Harness()
        await h.scriptServer()
        let saved = try await h.runtime.launch(h.input())
        #expect(saved.t3?.threadId == "THREAD_1")
        #expect(saved.t3Launch == nil)
        #expect(saved.runtimeMode == .t3)
        #expect(saved.status == .working)
        let writes = await h.store.savedValues()
        #expect(writes.count == 2)
        #expect(writes[0].t3Launch?.phase == .sending && writes[0].t3 == nil)
        #expect(writes[1].t3 != nil && writes[1].t3Launch == nil)
        let calls = await h.tools.calls
        guard case .launch(let request) = calls.first else { Issue.record("no launch"); return }
        #expect(request.worktreePath == "/REPO/.worktrees/foc-1/agents/sub_1")
        #expect(request.clientRequestId == writes[0].t3Launch?.requestId)
        #expect(request.message == "Add a README")
        #expect(request.options == ["effort": "high"])
    }

    @Test("A definite rejection removes the new checkout once")
    func rejected() async throws {
        let h = Harness()
        await h.tools.set { $0.onLaunch = { _ in
            throw T3Error.rejected(code: "invalid_request", message: "worktreePath must be one of the project's git worktrees.")
        } }
        await #expect(throws: T3Error.self) { try await h.runtime.launch(h.input()) }
        #expect(await h.worktrees.cleaned == ["SUB_1"])
        let saved = try await h.store.subtask(Harness.location)
        #expect(saved?.t3Launch == nil)
        #expect(saved?.progressSummary.contains("git worktrees") == true)
    }

    @Test("An unknown outcome keeps the checkout and the intent")
    func timeout() async throws {
        let h = Harness()
        await h.tools.set { $0.onLaunch = { _ in throw T3Error.outcomeUnknown("timed out") } }
        await #expect(throws: T3Error.outcomeUnknown("timed out")) { try await h.runtime.launch(h.input()) }
        #expect(await h.worktrees.cleaned.isEmpty)
        let saved = try await h.store.subtask(Harness.location)
        #expect(saved?.t3Launch?.phase == .unknown)
        #expect(await h.connection.reported == [.outcomeUnknown("timed out")])
    }

    @Test("A save failure after a successful launch keeps the intent and checkout")
    func saveFailure() async throws {
        let h = Harness()
        await h.scriptServer()
        await h.store.setFailSave { $0.t3 != nil ? SaveFailure() : nil }
        await #expect(throws: T3Error.self) { try await h.runtime.launch(h.input()) }
        #expect(await h.worktrees.cleaned.isEmpty)
        let saved = try await h.store.subtask(Harness.location)
        #expect(saved?.t3Launch?.phase == .unknown)
        #expect(saved?.t3 == nil)
    }

    @Test("Preflight failures create no checkout", arguments: [0, 1, 2, 3])
    func preflight(_ scenario: Int) async throws {
        let h: Harness
        switch scenario {
        case 0: h = Harness(access: .belowFullAccess)
        case 1: h = Harness(models: StubModels(unavailable: true))
        case 2: h = Harness(guardFolder: "/HOME/.t3/worktrees")
        default: h = Harness(status: .unreachable)
        }
        await #expect(throws: T3Error.self) { try await h.runtime.launch(h.input()) }
        #expect(await h.worktrees.provisioned.isEmpty)
        #expect(await h.store.savedValues().isEmpty)
        #expect(await h.tools.calls.isEmpty)
    }

    @Test("Unreachable T3 Code says it is not running")
    func notRunning() async {
        let h = Harness(status: .unreachable)
        await #expect(throws: T3Error.notRunning) { try await h.runtime.launch(h.input()) }
        #expect(T3Error.notRunning.localizedDescription == "T3 Code is not running")
    }
}

@Suite("T3 launch reconciliation")
struct T3LaunchReconcileTests {
    @Test("A thread already bound to the checkout is adopted without relaunching")
    func adopts() async throws {
        let h = Harness()
        await h.scriptServer()
        await h.server.setDropReplies(1)
        await #expect(throws: T3Error.self) { try await h.runtime.launch(h.input()) }
        await h.tools.clearCalls()
        await h.runtime.reconcileLaunches()
        let saved = try await h.store.subtask(Harness.location)
        #expect(saved?.t3?.threadId == "THREAD_1")
        #expect(saved?.t3Launch == nil)
        #expect(await h.tools.callCount { if case .launch = $0 { true } else { false } } == 0)
        #expect(await h.server.threadCount == 1)
        #expect(await h.dirty.threads == ["THREAD_1"])
    }

    @Test("With no thread, reconcile resends the same request id")
    func resends() async throws {
        let h = Harness()
        await h.scriptServer()
        await h.tools.set { $0.onLaunch = { _ in throw T3Error.notRunning } }
        await #expect(throws: T3Error.self) { try await h.runtime.launch(h.input()) }
        let requestId = try await h.store.subtask(Harness.location)?.t3Launch?.requestId
        await h.scriptServer()
        await h.runtime.reconcileLaunches()
        let calls = await h.tools.calls
        let launches = calls.compactMap { if case .launch(let r) = $0 { r.clientRequestId } else { nil } }
        #expect(launches.count == 2)
        #expect(Set(launches) == [requestId])
        #expect(try await h.store.subtask(Harness.location)?.t3?.threadId == "THREAD_1")
        #expect(await h.server.threadCount == 1)
        #expect(await h.worktrees.cleaned.isEmpty)
    }

    @Test("A rejected resend cleans up and records the reason")
    func rejectedResend() async throws {
        let h = Harness()
        await h.tools.set { $0.onLaunch = { _ in throw T3Error.outcomeUnknown("x") } }
        _ = try? await h.runtime.launch(h.input())
        await h.tools.set {
            $0.onList = { _ in [] }
            $0.onLaunch = { _ in throw T3Error.rejected(code: "invalid_request", message: "nope") }
        }
        await h.runtime.reconcileLaunches()
        #expect(await h.worktrees.cleaned == ["SUB_1"])
        let saved = try await h.store.subtask(Harness.location)
        #expect(saved?.t3Launch == nil)
        #expect(saved?.progressSummary.contains("nope") == true)
    }

    @Test("A still-unknown resend leaves the intent for the next attempt")
    func stillUnknown() async throws {
        let h = Harness()
        await h.tools.set { $0.onLaunch = { _ in throw T3Error.outcomeUnknown("x") } }
        _ = try? await h.runtime.launch(h.input())
        await h.tools.set { $0.onList = { _ in throw T3Error.notRunning } }
        await h.runtime.reconcileLaunches()
        let saved = try await h.store.subtask(Harness.location)
        #expect(saved?.t3Launch?.phase == .unknown)
        #expect(await h.worktrees.cleaned.isEmpty)
    }

    /// Boundaries: 0 before the intent save, 1 after it, 2 after the reply, 3 after the reference save.
    @Test("A crash at each launch boundary recovers to exactly one thread", arguments: [0, 1, 2, 3])
    func crashBoundaries(_ boundary: Int) async throws {
        let h = Harness()
        await h.scriptServer()
        switch boundary {
        case 0:
            await h.store.setFailSave { _ in SaveFailure() }
            _ = try? await h.runtime.launch(h.input())
            await h.store.setFailSave(nil)
            #expect(await h.server.threadCount == 0)
            #expect(await h.tools.calls.isEmpty)
            // The user retries the launch after the restart.
            _ = try await h.runtime.launch(h.input())
        case 1:
            // Crash after the intent save and before the reply: the request may or may not have arrived.
            await h.tools.set { $0.onLaunch = { _ in throw CancellationError() } }
            _ = try? await h.runtime.launch(h.input())
            await h.scriptServer()
        case 2:
            await h.store.setFailSave { $0.t3 != nil ? SaveFailure() : nil }
            _ = try? await h.runtime.launch(h.input())
            await h.store.setFailSave(nil)
        default:
            _ = try await h.runtime.launch(h.input())
        }
        // Restart: a fresh runtime over the same store and server.
        let restarted = T3Runtime(connection: h.connection, tools: h.tools, models: StubModels(), projects: StubProjects(),
                                  worktrees: h.worktrees, store: h.store, clock: h.clock)
        await restarted.reconcileLaunches()
        let saved = try await h.store.subtask(Harness.location)
        #expect(saved?.t3?.threadId == "THREAD_1")
        #expect(saved?.t3Launch == nil)
        #expect(await h.server.threadCount == 1)
        // Only a launch that never reached T3 Code may remove its checkout.
        #expect(await h.worktrees.cleaned == (boundary == 0 ? ["SUB_1"] : []))
    }

    @Test("Periodic reconcile runs every 30 seconds while an outcome is unknown")
    func periodic() async throws {
        let h = Harness()
        await h.tools.set { $0.onLaunch = { _ in throw T3Error.outcomeUnknown("x") } }
        _ = try? await h.runtime.launch(h.input())
        await h.scriptServer()
        let task = Task { await h.runtime.runPeriodicReconcile() }
        #expect(await eventually { h.clock.pendingSleepers == 1 })
        await h.clock.advance(by: 30)
        #expect(await eventually { (try? await h.store.subtask(Harness.location))??.t3 != nil })
        task.cancel()
    }
}

@Suite("T3 runtime controls")
struct T3RuntimeControlTests {
    private func seeded(env: String = T3Samples.env) async -> Harness {
        let h = Harness()
        await h.store.put(Harness.location, T3Samples.t3Subtask(env: env, status: .idle))
        await h.tools.set {
            $0.onSend = { _, _, _ in }
            $0.onInterrupt = { _, _ in T3InterruptResult(runId: "RUN_1", status: "interrupt_requested") }
        }
        return h
    }

    @Test("Pause interrupts without stopping, Stop holds queued turns, Resume and prompts use auto")
    func modes() async throws {
        let h = await seeded()
        try await h.runtime.pause(Harness.location)
        #expect(try await h.store.subtask(Harness.location)?.pausedAt != nil)
        try await h.runtime.resume(Harness.location)
        #expect(try await h.store.subtask(Harness.location)?.pausedAt == nil)
        try await h.runtime.stop(Harness.location)
        try await h.runtime.sendPrompt(Harness.location, text: "Now add tests")
        let calls = await h.tools.calls
        #expect(calls == [
            .interrupt(threadId: "THREAD_1", stop: false),
            .send(threadId: "THREAD_1", message: T3Runtime.resumePrompt, mode: .auto),
            .interrupt(threadId: "THREAD_1", stop: true),
            .send(threadId: "THREAD_1", message: "Now add tests", mode: .auto),
        ])
        #expect(await h.dirty.threads == ["THREAD_1", "THREAD_1", "THREAD_1", "THREAD_1"])
        #expect(try await h.store.subtask(Harness.location)?.status == .working)
    }

    @Test("Stop on an idle agent is silent")
    func stopIdle() async throws {
        let h = await seeded()
        await h.tools.set { $0.onInterrupt = { _, _ in T3InterruptResult(runId: nil, status: T3InterruptResult.noActiveRun) } }
        try await h.runtime.stop(Harness.location)
    }

    @Test("An agent from another server is never sent commands")
    func otherServer() async throws {
        let h = await seeded(env: "ENV_OLD")
        await #expect(throws: T3Error.otherServer(expected: "ENV_OLD", actual: T3Samples.env)) {
            try await h.runtime.stop(Harness.location)
        }
        #expect(await h.tools.calls.isEmpty)
    }

    @Test("A missing thread is recorded")
    func threadMissing() async throws {
        let h = await seeded()
        await h.tools.set { $0.onSend = { id, _, _ in throw T3Error.threadNotFound(id) } }
        await #expect(throws: T3Error.threadNotFound("THREAD_1")) {
            try await h.runtime.sendPrompt(Harness.location, text: "hi")
        }
        #expect(try await h.store.subtask(Harness.location)?.t3?.reachability == .threadMissing)
    }

    @Test("Acknowledging marks the latest finished turn seen")
    func acknowledge() async throws {
        let h = await seeded()
        await h.store.put(Harness.location, {
            var s = T3Samples.t3Subtask(status: .idle)
            s.t3?.latestTerminalRunId = "RUN_9"; s.completionUnread = true
            return s
        }())
        try await h.runtime.acknowledge(Harness.location)
        let saved = try await h.store.subtask(Harness.location)
        #expect(saved?.t3?.acknowledgedTerminalRunId == "RUN_9")
        #expect(saved?.completionUnread == false)
        #expect(h.runtime.openURL(saved!)?.absoluteString == "t3code://threads/THREAD_1")
    }
}

@Suite("T3 finish")
struct T3FinishTests {
    private func seeded(row: T3ThreadRow? = T3ThreadRow(threadId: "THREAD_1", title: "t", status: "interrupted"),
                        wait: T3WaitResult = T3WaitResult(runId: "RUN_1", status: "interrupted", timedOut: false),
                        active: String? = nil) async -> Harness {
        let h = Harness()
        await h.store.put(Harness.location, T3Samples.t3Subtask())
        await h.tools.set {
            $0.onInterrupt = { _, _ in T3InterruptResult(runId: "RUN_1", status: "interrupt_requested") }
            $0.onWait = { _, _, _ in wait }
            $0.onSnapshot = { _ in T3Samples.snapshot(active: active) }
            $0.onList = { _ in row.map { [$0] } ?? [] }
        }
        return h
    }

    @Test("Confirmed stop cleans up, then archives, in order")
    func confirmed() async throws {
        let h = await seeded()
        await h.worktrees.setCleanupResult(TaskWorktreeCleanupResult(
            removed: false, message: "Agent worktree retained: its commits have not been merged into main."))
        let state = await h.runtime.finish(Harness.location)
        #expect(state == .retained(message: "Agent worktree retained: its commits have not been merged into main."))
        let calls = await h.tools.calls
        #expect(calls == [.interrupt(threadId: "THREAD_1", stop: true),
                          .wait(threadId: "THREAD_1", runId: "RUN_1", timeoutMs: 30_000),
                          .snapshot("THREAD_1"), .list("PROJECT_1"), .archive("THREAD_1")])
        #expect(await h.worktrees.cleaned == ["SUB_1"])
        let saved = try await h.store.subtask(Harness.location)
        #expect(saved?.t3?.archivedAt != nil)
        #expect(saved?.t3?.cleanup == state)
    }

    @Test("Unconfirmed stops keep the checkout", arguments: [0, 1, 2, 3, 4])
    func unconfirmed(_ scenario: Int) async throws {
        let h: Harness
        switch scenario {
        case 0: h = await seeded(wait: T3WaitResult(runId: "RUN_1", status: "running", timedOut: true))
        case 1: h = await seeded(active: "RUN_2")
        case 2: h = await seeded(row: T3ThreadRow(threadId: "THREAD_1", title: "t", status: "idle",
                                                  pendingBackgroundTasks: ["task"]))
        case 3:
            h = await seeded()
            await h.tools.set { $0.onInterrupt = { _, _ in throw T3Error.notRunning } }
        default:
            h = await seeded()
            await h.connection.setStatus(.unreachable)
        }
        let state = await h.runtime.finish(Harness.location)
        #expect(state?.isPending == true)
        #expect(await h.worktrees.cleaned.isEmpty)
        #expect(await h.runtime.protectedCheckouts(ticketID: "foc-1").isEmpty) // no workspace in sample
    }

    @Test("Pending cleanup completes after reconnecting")
    func retry() async throws {
        let h = await seeded()
        await h.connection.setStatus(.unreachable)
        #expect(await h.runtime.finish(Harness.location)?.isPending == true)
        await h.connection.setStatus(.connected(environmentId: T3Samples.env, version: "0.1.12"))
        await h.runtime.retryPendingCleanups()
        #expect(try await h.store.subtask(Harness.location)?.t3?.cleanup == .removed)
        #expect(await h.worktrees.cleaned == ["SUB_1"])
    }

    @Test("An archive failure still records the cleanup")
    func archiveFailure() async throws {
        let h = await seeded()
        await h.tools.set { $0.onArchive = { _ in throw T3Error.notRunning } }
        let state = await h.runtime.finish(Harness.location)
        #expect(state == .removed)
        let saved = try await h.store.subtask(Harness.location)
        #expect(saved?.t3?.cleanup == .removed)
        #expect(saved?.t3?.archivedAt == nil)
    }

    @Test("Pending agents protect their checkouts from task cleanup")
    func protectedPaths() async throws {
        let h = await seeded()
        var subtask = T3Samples.t3Subtask()
        subtask.workspace = AgentWorkspace(path: "/REPO/.worktrees/foc-1/agents/sub_1", repositoryPath: "/REPO", managed: true)
        await h.store.put(Harness.location, subtask)
        await h.connection.setStatus(.unreachable)
        _ = await h.runtime.finish(Harness.location)
        #expect(await h.runtime.protectedCheckouts(ticketID: "FOC-1") == ["/REPO/.worktrees/foc-1/agents/sub_1"])
    }
}
