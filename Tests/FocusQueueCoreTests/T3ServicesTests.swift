import Foundation
import Testing
@testable import FocusQueueCore

private struct StubModelsForServices: T3ModelSelecting {
    func modelSelection(instanceId: String, model: String, options: [String: JSONValue]) async throws -> [String: JSONValue] {
        ["instanceId": .string(instanceId), "model": .string(model)]
    }
}
private struct StubProjectsForServices: T3ProjectResolving {
    func projectId(for project: ProjectConfiguration, environmentId: String) async throws -> String { "PROJECT_1" }
}

@Suite("T3 services lifecycle")
struct T3ServicesTests {
    private func make() throws -> (T3Services, FakeT3Tools, FakeT3Store, FakeT3Worktrees) {
        let harness = try T3ConnHarness()
        let tools = FakeT3Tools()
        var pending = T3Samples.t3Subtask()
        pending.t3?.cleanup = .pending(reason: "T3 Code is unreachable")
        let store = FakeT3Store([T3SubtaskRecord(location: T3SubtaskLocation(ticketID: "FOC-1", subtaskID: "SUB_1"),
                                                 subtask: pending)])
        let worktrees = FakeT3Worktrees()
        let connection = FakeT3Connection()
        let refresher = T3Refresher(tools: tools, store: store, connection: connection)
        let watcher = T3Watcher(transport: harness.transport, tools: tools, target: refresher, store: store,
                                connection: connection, clock: ManualT3Clock())
        let runtime = T3Runtime(connection: connection, tools: tools, models: StubModelsForServices(),
                                projects: StubProjectsForServices(), worktrees: worktrees, store: store,
                                dirty: refresher, clock: ManualT3Clock())
        let services = T3Services(connection: harness.connection, tools: tools,
                                  catalog: T3ProviderCatalog(tools: tools), refresher: refresher,
                                  watcher: watcher, runtime: runtime, store: store)
        return (services, tools, store, worktrees)
    }

    @Test("Connecting starts live updates and retries pending cleanup; disconnecting stops them")
    func connectAndDisconnect() async throws {
        let (services, tools, store, worktrees) = try make()
        await tools.set {
            $0.onInterrupt = { _, _ in T3InterruptResult(runId: nil, status: T3InterruptResult.noActiveRun) }
            $0.onSnapshot = { _ in T3Samples.snapshot() }
            $0.onList = { _ in [T3ThreadRow(threadId: "THREAD_1", title: "t", status: "idle")] }
        }
        await services.handle(.connected(environmentId: T3Samples.env, version: "0.1.12"))
        #expect(await services.watcher.isRunning)
        #expect(await services.watcher.watchedProjectIds == ["PROJECT_1"])
        #expect(await worktrees.cleaned == ["SUB_1"])
        let location = T3SubtaskLocation(ticketID: "FOC-1", subtaskID: "SUB_1")
        #expect(try await store.subtask(location)?.t3?.cleanup == .removed)

        await services.handle(.disconnected)
        #expect(await services.watcher.isRunning == false)

        // Reconnecting, without rebuilding anything, starts live updates again.
        await services.handle(.connected(environmentId: T3Samples.env, version: "0.1.12"))
        #expect(await services.watcher.isRunning)
        await services.stop()
    }
}
