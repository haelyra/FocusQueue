import Foundation
import Testing
@testable import FocusQueueCore

@Suite("T3 agent identity and instructions")
struct T3AgentInstructionsTests {
    private let thread = ["T3CODE_THREAD_ID": "THREAD_1"]

    private func record(_ subtask: TaskSubtask, ticket: String = "FOC-1") -> T3SubtaskRecord {
        T3SubtaskRecord(location: T3SubtaskLocation(ticketID: ticket, subtaskID: subtask.id), subtask: subtask)
    }

    private func launching(_ id: String, worktree: String) -> TaskSubtask {
        var subtask = TaskSubtask(id: id, title: id, runtimeMode: .t3)
        subtask.t3Launch = T3LaunchIntent(requestId: "R_\(id)", environmentId: T3Samples.env, projectId: "P",
                                          worktreePath: worktree, title: id, createdAt: Date(), phase: .sending)
        return subtask
    }

    @Test("The T3 thread id identifies the agent, and fills in its task and agent IDs")
    func threadId() {
        let records = [record(T3Samples.t3Subtask(id: "SUB_0", thread: "THREAD_0")), record(T3Samples.t3Subtask())]
        #expect(T3AgentIdentity.resolve(environment: ["T3CODE_THREAD_ID": "thread_1"], cwd: "/", records: records)
                == T3SubtaskLocation(ticketID: "FOC-1", subtaskID: "SUB_1"))
        let environment = T3AgentIdentity.environment(thread, cwd: "/", records: records)
        #expect(environment["FOCUS_QUEUE_TASK_ID"] == "FOC-1")
        #expect(environment["FOCUS_QUEUE_SUBTASK_ID"] == "SUB_1")
        #expect(environment["FOCUS_QUEUE_RUNTIME"] == "t3")
    }

    @Test("Outside a T3 thread, or with Focus Queue IDs already exported, nothing changes")
    func untouched() {
        let records = [record(T3Samples.t3Subtask())]
        #expect(T3AgentIdentity.resolve(environment: [:], cwd: "/", records: records) == nil)
        let managed = ["T3CODE_THREAD_ID": "THREAD_1", "FOCUS_QUEUE_TASK_ID": "FOC-9"]
        #expect(T3AgentIdentity.environment(managed, cwd: "/", records: records) == managed)
        #expect(T3AgentIdentity.resolve(environment: ["T3CODE_THREAD_ID": "OTHER"], cwd: "/", records: records) == nil)
    }

    @Test("A removed agent is never matched")
    func removed() {
        var subtask = T3Samples.t3Subtask()
        subtask.agentRemovedAt = Date()
        #expect(T3AgentIdentity.resolve(environment: thread, cwd: "/", records: [record(subtask)]) == nil)
    }

    @Test("Before the launch is adopted, the only launch whose checkout holds the cwd matches")
    func launchingCheckout() {
        let one = [record(launching("SUB_A", worktree: "/tmp/fq-a")), record(launching("SUB_B", worktree: "/tmp/fq-b"))]
        #expect(T3AgentIdentity.resolve(environment: thread, cwd: "/tmp/fq-a/Sources", records: one)
                == T3SubtaskLocation(ticketID: "FOC-1", subtaskID: "SUB_A"))
        #expect(T3AgentIdentity.resolve(environment: thread, cwd: "/tmp/fq-ab", records: one) == nil)
        let twice = [record(launching("SUB_A", worktree: "/tmp/fq-a")), record(launching("SUB_C", worktree: "/tmp/fq-a"))]
        #expect(T3AgentIdentity.resolve(environment: thread, cwd: "/tmp/fq-a", records: twice) == nil)
    }

    @Test("T3 launch prompts carry explicit IDs and never ask the agent to attach")
    func prompts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t3-prompt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try await TaskContextStore(root: root)
            .ensureContext(ticket: DashboardTicket(id: "FOC-7", title: "T3 prompt", status: "open", summary: "s"))
        let t3 = T3Samples.t3Subtask(id: "SUB_7")
        let terminal = TaskSubtask(id: "SUB_8", title: "Terminal agent")
        for text in [context.agentPrompt(subtask: t3), context.agentBootstrap(subtask: t3)] {
            #expect(text.contains("FOC-7 SUB_7"))
            #expect(text.contains("do not run `focus-queue-session attach`"))
            #expect(!text.contains("Register with `focus-queue-session attach`"))
            #expect(!text.contains("Before anything else run `focus-queue-session attach`"))
        }
        #expect(!context.agentPrompt(subtask: t3).contains("attention approval|question"))
        #expect(context.agentPrompt(subtask: terminal).contains("Before anything else run `focus-queue-session attach`."))
        #expect(context.agentBootstrap(subtask: terminal).contains("Register with `focus-queue-session attach`"))
    }
}

@Suite("T3 server switching and read-only access")
struct T3ServerChoiceTests {
    @Test("Use this server adopts the new environment and connects")
    func useCurrentServer() async throws {
        let harness = try T3ConnHarness.stored()
        harness.transport.environmentId = "ENV_2"
        #expect(await harness.connection.connect() == .otherServer(expected: "ENV_1", actual: "ENV_2"))
        let status = try await harness.connection.useCurrentServer()
        #expect(status.connectedEnvironmentId == "ENV_2")
        #expect(try harness.stateStore.load()?.environmentId == "ENV_2")
    }

    @Test("Use this server does nothing unless the server differs")
    func useCurrentServerNoop() async throws {
        let harness = try T3ConnHarness.stored()
        #expect(await harness.connection.connect().connectedEnvironmentId == "ENV_1")
        #expect(try await harness.connection.useCurrentServer().connectedEnvironmentId == "ENV_1")
        #expect(try harness.stateStore.load()?.environmentId == "ENV_1")
    }

    @Test("Below Full access, existing agents stay readable but controls refuse")
    func readOnly() async throws {
        let harness = try T3ConnHarness.stored(access: .belowFullAccess)
        #expect(await harness.connection.connect() == .accessTooLow)
        #expect(await harness.connection.readableEnvironmentId() == "ENV_1")

        let tools = FakeT3Tools()
        let store = FakeT3Store([T3SubtaskRecord(location: T3SubtaskLocation(ticketID: "FOC-1", subtaskID: "SUB_1"),
                                                 subtask: T3Samples.t3Subtask())])
        let refresher = T3Refresher(tools: tools, store: store, connection: harness.connection)
        let watcher = T3Watcher(transport: harness.transport, tools: tools, target: refresher, store: store,
                                connection: harness.connection, clock: ManualT3Clock())
        let runtime = T3Runtime(connection: harness.connection, tools: tools, models: StubModelsForReadOnly(),
                                projects: StubProjectsForReadOnly(), worktrees: FakeT3Worktrees(), store: store,
                                dirty: refresher, clock: ManualT3Clock())
        let services = T3Services(connection: harness.connection, tools: tools,
                                  catalog: T3ProviderCatalog(tools: tools), refresher: refresher,
                                  watcher: watcher, runtime: runtime, store: store)
        await services.handle(.accessTooLow)
        #expect(await services.watcher.isRunning)
        #expect(await services.watcher.watchedProjectIds == ["PROJECT_1"])
        let location = T3SubtaskLocation(ticketID: "FOC-1", subtaskID: "SUB_1")
        await #expect(throws: T3Error.accessTooLow) { try await runtime.stop(location) }
        await services.stop()
    }
}

private struct StubModelsForReadOnly: T3ModelSelecting {
    func modelSelection(instanceId: String, model: String, options: [String: JSONValue]) async throws -> [String: JSONValue] {
        ["instanceId": .string(instanceId), "model": .string(model)]
    }
}

private struct StubProjectsForReadOnly: T3ProjectResolving {
    func projectId(for project: ProjectConfiguration, environmentId: String) async throws -> String { "PROJECT_1" }
}
